import flashinfer
import torch


def test_append_paged_kv_cache():
    nnz_kv = 100
    num_kv_heads = 32
    head_dim = 128
    k_append = torch.randn(nnz_kv, num_kv_heads, head_dim).half().to(0)
    v_append = torch.randn(nnz_kv, num_kv_heads, head_dim).half().to(0)
    # 45 + 8 + 25 + 22 = nnz_kv
    kv_append_length = torch.tensor([45, 8, 25, 22], dtype=torch.int32, device="cuda:0")
    kv_append_indptr = torch.cat(
        [torch.zeros(1).int().to(0), torch.cumsum(kv_append_length, dim=0)]
    ).int()
    max_num_pages = 1000
    page_size = 16
    paged_kv_cache = (
        torch.randn(max_num_pages, 2, page_size, num_kv_heads, head_dim).half().to(0)
    )
    num_pages_per_req = torch.tensor([3, 1, 2, 2], dtype=torch.int32, device="cuda:0")
    kv_page_indptr = torch.cat(
        [torch.zeros(1).int().to(0), torch.cumsum(num_pages_per_req, dim=0)]
    ).int()
    # use first 8 pages in the paged-kv
    kv_page_indices = torch.arange(8, dtype=torch.int32, device="cuda:0")
    # 45 = (3 - 1) * 16 + 13
    # 8 = (1 - 1) * 16 + 8
    # 25 = (2 - 1) * 16 + 9
    # 22 = (2 - 1) * 16 + 6
    kv_last_page_len = torch.tensor([13, 8, 9, 6], dtype=torch.int32, device="cuda:0")

    flashinfer.page.append_paged_kv_cache(
        k_append,
        v_append,
        kv_append_indptr,
        paged_kv_cache,
        kv_page_indices,
        kv_page_indptr,
        kv_last_page_len,
    )
