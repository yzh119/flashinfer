/*
 * Copyright (c) 2024 by FlashInfer team.
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
#ifndef FLASHINFER_QUANTIZATION_CUH_
#define FLASHINFER_QUANTIZATION_CUH_
#include <cuda_runtime.h>
#include <cuda_runtime_api.h>

#include "utils.cuh"

namespace flashinfer {
namespace quantization {

enum class BitOrder { kBig = 0U, kLittle = 1U };

#define DISPATCH_BITORDER(bitorder, BITORDER, ...)   \
  if (bitorder == BitOrder::kBig) {                  \
    constexpr BitOrder BITORDER = BitOrder::kBig;    \
    __VA_ARGS__                                      \
  } else {                                           \
    constexpr BitOrder BITORDER = BitOrder::kLittle; \
    __VA_ARGS__                                      \
  }

template <BitOrder BITORDER>
__global__ void PackBitsKernel(bool* input, uint8_t* output, int64_t num_elements) {
  int64_t idx = blockIdx.x * blockDim.x + threadIdx.x;
  uint8_t ret = 0;
  uint8_t input_vec[8];
  for (uint32_t i = 0; i < 8; ++i) {
    input_vec[i] = 0;
  }
  if ((idx + 1) * 8 <= num_elements) {
    *(uint2*)input_vec = *(uint2*)(input + idx * 8);
  } else {
#pragma unroll
    for (uint32_t i = 0; i < 8; ++i) {
      input_vec[i] = (idx * 8 + i < num_elements) ? input[idx * 8 + i] : false;
    }
  }

  if constexpr (BITORDER == BitOrder::kBig) {
    ret = (input_vec[0] << 7) | (input_vec[1] << 6) | (input_vec[2] << 5) | (input_vec[3] << 4) |
          (input_vec[4] << 3) | (input_vec[5] << 2) | (input_vec[6] << 1) | input_vec[7];
  } else {
    ret = (input_vec[7] << 7) | (input_vec[6] << 6) | (input_vec[5] << 5) | (input_vec[4] << 4) |
          (input_vec[3] << 3) | (input_vec[2] << 2) | (input_vec[1] << 1) | input_vec[0];
  }
  output[idx] = ret;
}

// NOTE(Zihao): this implementation is not efficient, but this kernel is not a bottleneck
// at the moment. We can optimize it later if needed.
template <BitOrder BITORDER, typename IdType>
__global__ void SegmentPackBitsKernel(bool* input, uint8_t* output, IdType* input_indptr,
                                      IdType* output_indptr) {
  int64_t bx = blockIdx.x, tx = threadIdx.x;
  for (uint32_t j = tx; j < output_indptr[bx + 1] - output_indptr[bx]; j += blockDim.x) {
    int64_t num_elements = input_indptr[bx + 1] - input_indptr[bx];
    uint8_t ret = 0;
    uint8_t input_vec[8];
#pragma unroll
    for (uint32_t i = 0; i < 8; ++i) {
      input_vec[i] = (j * 8 + i < num_elements) ? input[input_indptr[bx] + j * 8 + i] : false;
    }

    if constexpr (BITORDER == BitOrder::kBig) {
      ret = (input_vec[0] << 7) | (input_vec[1] << 6) | (input_vec[2] << 5) | (input_vec[3] << 4) |
            (input_vec[4] << 3) | (input_vec[5] << 2) | (input_vec[6] << 1) | input_vec[7];
    } else {
      ret = (input_vec[7] << 7) | (input_vec[6] << 6) | (input_vec[5] << 5) | (input_vec[4] << 4) |
            (input_vec[3] << 3) | (input_vec[2] << 2) | (input_vec[1] << 1) | input_vec[0];
    }
    output[output_indptr[bx] + j] = ret;
  }
}

cudaError_t PackBits(bool* input, uint8_t* output, int64_t num_elements, BitOrder bitorder,
                     cudaStream_t stream) {
  DISPATCH_BITORDER(bitorder, BITORDER, {
    auto kernel = PackBitsKernel<BITORDER>;
    const dim3 nthrs(256);
    const dim3 nblks(ceil_div(num_elements, nthrs.x * 8));
    void* args[] = {&input, &output, &num_elements};
    FLASHINFER_CUDA_CALL(cudaLaunchKernel((void*)kernel, nblks, nthrs, args, 0, stream));
  });
  return cudaSuccess;
}

template <typename IdType>
cudaError_t SegmentPackBits(bool* input, uint8_t* output, IdType* input_indptr,
                            IdType* output_indptr, uint32_t batch_size, BitOrder bitorder,
                            cudaStream_t stream) {
  DISPATCH_BITORDER(bitorder, BITORDER, {
    auto kernel = SegmentPackBitsKernel<BITORDER, IdType>;
    const dim3 nthrs(256);
    const dim3 nblks(batch_size);
    void* args[] = {&input, &output, &input_indptr, &output_indptr};
    FLASHINFER_CUDA_CALL(cudaLaunchKernel((void*)kernel, nblks, nthrs, args, 0, stream));
  });
  return cudaSuccess;
}

}  // namespace quantization
}  // namespace flashinfer

#endif  // FLASHINFER_QUANTIZATION_CUH_