"""
Copyright (c) 2023 by FlashInfer team.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
"""

import pytest
import torch
from jit_utils import jit_prefill_attention_func_args

import flashinfer


@pytest.fixture(autouse=True, scope="module")
def warmup_jit():
    if flashinfer.jit.has_prebuilt_ops:
        yield
    else:
        try:
            flashinfer.jit.parallel_load_modules(
                jit_prefill_attention_func_args(
                    [torch.float16],  # q_dtypes
                    [
                        torch.float16,
                        torch.float8_e4m3fn,
                        torch.float8_e5m2,
                    ],  # kv_dtypes
                    [128, 256],  # head_dims
                    [0, 1, 2],  # pos_encoding_modes
                    [False],  # use_sliding_windows
                    [False, True],  # use_logits_soft_caps
                    [False],  # use_fp16_qk_reductions
                )
            )
        except Exception as e:
            # abort the test session if warmup fails
            pytest.exit(str(e))
        finally:
            yield

@pytest.mark.parametrize("batch_size_d", [12, 17])
@pytest.mark.parametrize("kv_len_p", [54, 97])
@pytest.mark.parametrize("qo_len_p", [37, 17])
@pytest.mark.parametrize("num_kv_heads", [4])
@pytest.mark.parametrize("num_qo_heads", [4, 32])
@pytest.mark.parametrize("head_dim", [128, 256])
@pytest.mark.parametrize("causal", [False, True])
@pytest.mark.parametrize("pos_encoding_mode", ["NONE", "ROPE_LLAMA", "ALIBI"])
@pytest.mark.parametrize("logits_soft_cap", [0.0, 30.0])
def test_pod_with_paged_kv_cache(
    # Prefill params
    kv_len_p,
    qo_len_p,
    causal,
    # Decode params
    batch_size_d,
    kv_len_d,
    page_size_d,
    kv_layout_d,
    # Shared params
    num_kv_heads,
    num_qo_heads,
    head_dim,
    pos_encoding_mode,
    logits_soft_cap,
    q_dtype,
    kv_dtype,
    contiguous_kv,
):
    return_lse = False
    batch_size_p = 1
    kv_layout_p = "NHD"
    q_p = torch.randn(batch_size_p * qo_len_p, num_qo_heads, head_dim).to(0).half()
    q_indptr_p = torch.arange(0, batch_size_p + 1).to(0).int() * qo_len_p

    k_p = torch.randn(batch_size_p * kv_len_p, num_kv_heads, head_dim).to(0).half()
    v_p = torch.randn(batch_size_p * kv_len_p, num_kv_heads, head_dim).to(0).half()
    kv_indptr_p = torch.arange(0, batch_size_p + 1).to(0).int() * kv_len_p

    workspace_buffer = torch.empty(128 * 1024 * 1024, dtype=torch.int8).to(0)

    wrapper = flashinfer.prefill.BatchPrefillWithRaggedKVCacheWrapper(
        workspace_buffer, kv_layout_p
    )
    wrapper.plan(
        q_indptr_p,
        kv_indptr_p,
        num_qo_heads,
        num_kv_heads,
        head_dim,
        causal=causal,
        pos_encoding_mode=pos_encoding_mode,
        logits_soft_cap=logits_soft_cap,
    )
    if return_lse:
        o_ref_p, _ = wrapper.run(q_p, k_p, v_p, return_lse=True)
    else:
        o_ref_p = wrapper.run(q_p, k_p, v_p)
    
    q_d = torch.randn(batch_size_d, num_qo_heads, head_dim).to(0).to(q_dtype)
    num_pages_per_seq = (kv_len_d + page_size_d - 1) // page_size_d
    total_num_pages = num_pages_per_seq * batch_size_d
    if kv_layout_d == "HND":
        kv_shape = [total_num_pages, 2, num_kv_heads, page_size_d, head_dim]
    else:
        kv_shape = [total_num_pages, 2, page_size_d, num_kv_heads, head_dim]
    if not contiguous_kv:
        tmp = [kv_shape[0]]
        for v_d in kv_shape[1:]:
            tmp.append(2)
            tmp.append(v_d)
        kv_shape = tmp
        kv_data_fp32 = torch.randn(*kv_shape, dtype=torch.float32).to(0)
        kv_data = kv_data_fp32.to(kv_dtype)
        kv_data = kv_data[:, 1, :, 1, :, 1, :, 1, :]
        kv_data_fp32 = kv_data_fp32[:, 1, :, 1, :, 1, :, 1, :]
        # actual data is stored in non-contiguous memory
        assert (
            kv_data.stride(-4)
            != kv_data.shape[-3] * kv_data.shape[-2] * kv_data.shape[-1]
        )
    else:
        kv_data_fp32 = torch.randn(*kv_shape, dtype=torch.float32).to(0)
        kv_data = kv_data_fp32.to(kv_dtype)
    kv_indptr_d = torch.arange(0, batch_size_d + 1).to(0).int() * num_pages_per_seq
    kv_indices_d = torch.arange(0, total_num_pages).to(0).int()
    kv_last_page_len = torch.full(
        (batch_size_d,), (kv_len_d - 1) % page_size_d + 1, dtype=torch.int32
    ).to(0)

    workspace_buffer = torch.empty(32 * 1024 * 1024, dtype=torch.int8).to(0)
    wrapper = flashinfer.PODWithPagedKVCacheWrapper(
        workspace_buffer, kv_layout_d
    )
    wrapper.plan(
        kv_indptr_d,
        kv_indices_d,
        kv_last_page_len,
        num_qo_heads,
        num_kv_heads,
        head_dim,
        page_size_d,
        logits_soft_cap=logits_soft_cap,
        pos_encoding_mode=pos_encoding_mode,
        data_type=kv_dtype,
        q_data_type=q_dtype,
    )

    # Generate decode reference output
    new_workspace_buffer = torch.empty(32 * 1024 * 1024, dtype=torch.int8).to(0)
    decode_wrapper = flashinfer.decode.BatchDecodeWithPagedKVCacheWrapper(
        new_workspace_buffer, kv_layout_d
    )
    decode_wrapper.plan(
        kv_indptr_d,
        kv_indices_d,
        kv_last_page_len,
        num_qo_heads,
        num_kv_heads,
        head_dim,
        page_size_d,
        logits_soft_cap=logits_soft_cap,
        pos_encoding_mode=pos_encoding_mode,
        data_type=kv_dtype,
        q_data_type=q_dtype,
    )
    if return_lse:
        o_ref_d, _ = decode_wrapper.run(q_d, kv_data, return_lse=True)
    else:
        o_ref_d = decode_wrapper.run(q_d, kv_data)

    for i in range(batch_size_p):
        if return_lse:
            o_i_p, o_i_d = wrapper.run(
                q_p[q_indptr_p[i] : q_indptr_p[i + 1]],
                k_p[kv_indptr_p[i] : kv_indptr_p[i + 1]],
                v_p[kv_indptr_p[i] : kv_indptr_p[i + 1]],
                q_d, kv_data,
                causal_p=causal,
                pos_encoding_mode_d=pos_encoding_mode,
                logits_soft_cap_d=logits_soft_cap,
                pos_encoding_mode_p=pos_encoding_mode,
                logits_soft_cap_p=logits_soft_cap,
                return_lse_p=True)
        else:
            o_i_p, o_i_d = wrapper.run(
                q_p[q_indptr_p[i] : q_indptr_p[i + 1]],
                k_p[kv_indptr_p[i] : kv_indptr_p[i + 1]],
                v_p[kv_indptr_p[i] : kv_indptr_p[i + 1]], 
                q_d, kv_data,
                pos_encoding_mode_p=pos_encoding_mode,
                logits_soft_cap_p=logits_soft_cap,
                causal_p=causal)
        # Prefill is run with batch size 1
        o_ref_i_p = o_ref_p[q_indptr_p[i] : q_indptr_p[i + 1]]
        torch.testing.assert_close(o_i_p, o_ref_i_p, rtol=1e-3, atol=1e-3, msg="Prefill mismatch")
        # Decode uses all batches at once.
        torch.testing.assert_close(o_i_d, o_ref_d, rtol=1e-3, atol=1e-3, msg="Decode mismatch")

if __name__ == "__main__":
    test_pod_with_paged_kv_cache(
        # Prefill params
        13824 * 2, 13824 * 2, True, 
        # Decode params
        32, 13824, 1, "HND",
        # Other shared params
        8, 8, 128, "NONE", 0.0, torch.float16, torch.float16, True,
    )
    print("Test(s) passed!")