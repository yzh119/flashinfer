/*
 * Copyright (c) 2023-2025 by FlashInfer team.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#include "batch_decode_generated_config.inc"
#include "pytorch_extension_utils.h"

std::vector<int64_t> BatchDecodeWithPagedKVCachePlan(
    at::Tensor float_workspace_buffer, at::Tensor int_workspace_buffer,
    at::Tensor page_locked_int_workspace_buffer, at::Tensor indptr, unsigned int batch_size,
    unsigned int num_qo_heads, unsigned int num_kv_heads, unsigned int page_size,
    bool enable_cuda_graph, bool use_logits_soft_cap, unsigned int head_dim,
    at::Tensor empty_q_data, at::Tensor empty_kv_data, int64_t cuda_stream);

void BatchDecodeWithPagedKVCacheRun(
    at::Tensor float_workspace_buffer, at::Tensor int_workspace_buffer,
    std::vector<int64_t> plan_info_vec, at::Tensor q, at::Tensor paged_k_cache,
    at::Tensor paged_v_cache, at::Tensor paged_kv_indptr, at::Tensor paged_kv_indices,
    at::Tensor paged_kv_last_page_len, at::Tensor o, std::optional<at::Tensor> maybe_lse,
    unsigned int kv_layout_code, int window_left ADDITIONAL_FUNC_PARAMS, int64_t cuda_stream);

PYBIND11_MODULE(TORCH_EXTENSION_NAME, m) {
  m.def("plan", &BatchDecodeWithPagedKVCachePlan, "Batched decode with paged KV-Cache plan");
  m.def("run", &BatchDecodeWithPagedKVCacheRun, "Batched decode with paged KV-Cache run");
}
