import torch
from flashinfer import bmm_fp8

input = torch.randn([16, 48, 64], device="cuda", dtype=torch.bfloat16)
input_fp8 = input.to(torch.float8_e4m3fn)
mat2 = torch.randn([16, 64, 80], device="cuda", dtype=torch.bfloat16)
# mat2 row major -> column major
mat2_fp8 = mat2.to(torch.float8_e4m3fn).transpose(-1, -2).contiguous()
# make original shape unchanged
mat2_fp8 = mat2_fp8.transpose(-1, -2)

res = torch.empty([16, 48, 80], device="cuda", dtype=torch.bfloat16)
bmm_fp8(input_fp8, mat2_fp8, res)
res_bf16 = input @ mat2

torch.testing.assert_close(
    res.float().cpu(), res_bf16.float().cpu(), rtol=1e-1, atol=1e-1
)
