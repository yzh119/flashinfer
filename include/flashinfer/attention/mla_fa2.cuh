/*
 * Copyright (c) 2023 by FlashInfer team.
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
#ifndef FLASHINFER_MLA_FA2_CUH_
#define FLASHINFER_MLA_FA2_CUH_
#include <cstdint>

#include "mla_params.cuh"
#include "prefill.cuh"
#include "variant_helper.cuh"

namespace flashinfer {

namespace mla {

struct StandardAttention : AttentionVariantBase {
  float sm_scale_log2;

  template <typename Params>
  __device__ __host__ StandardAttention(const Params& params, uint32_t batch_idx,
                                        uint8_t* smem_ptr) {
    sm_scale_log2 = params.sm_scale * math::log2e;
  }
};

template <uint32_t NUM_STAGES, uint32_t CTA_TILE_Q, uint32_t CTA_TILE_KV, uint32_t HEAD_DIM_CKV,
          uint32_t HEAD_DIM_KPE, typename DTypeQ, typename DTypeKV, typename DTypeO>
struct SharedStorageQKVO {
  union {
    struct {
      alignas(16) DTypeQ q_smem_nope[CTA_TILE_Q * HEAD_DIM_CKV];
      alignas(16) DTypeQ q_smem_pe[CTA_TILE_Q * HEAD_DIM_KPE];
      alignas(16) DTypeKV ckv_smem[NUM_STAGES][CTA_TILE_KV * HEAD_DIM_CKV];
      union {
        alignas(16) DTypeKV kpe[CTA_TILE_KV * HEAD_DIM_KPE];
        alignas(16) DTypeKV p[CTA_TILE_Q * HEAD_DIM_KPE];
        alignas(16) float m_wg[2][CTA_TILE_Q];  // cross warpgroup synchronization
        alignas(16) float d_wg[2][CTA_TILE_Q];  // cross warpgroup synchronization
      } aux_smem[NUM_STAGES];
    };
    alignas(16) DTypeO o_smem[CTA_TILE_Q * HEAD_DIM_CKV];
  };
};

template <bool CAUSAL_, uint32_t NUM_STAGES_, uint32_t HEAD_DIM_CKV_, uint32_t HEAD_DIM_KPE_,
          uint32_t CTA_TILE_Q_, uint32_t CTA_TILE_KV_, typename DTypeQ_, typename DTypeKV_,
          typename DTypeO_, typename IdType_>
struct KernelTraits {
  static constexpr bool CAUSAL = CAUSAL_;
  static constexpr uint32_t NUM_STAGES = NUM_STAGES_;
  static constexpr uint32_t NUM_MMA_KV = CTA_TILE_KV_ / 16;
  static constexpr uint32_t HEAD_DIM_CKV = HEAD_DIM_CKV_;
  static constexpr uint32_t HEAD_DIM_KPE = HEAD_DIM_KPE_;
  static constexpr uint32_t HEAD_DIM_ALL = HEAD_DIM_CKV + HEAD_DIM_KPE;
  static constexpr uint32_t NUM_MMA_D_CKV = HEAD_DIM_CKV / 16;
  static constexpr uint32_t NUM_MMA_D_KPE = HEAD_DIM_KPE / 16;
  static constexpr uint32_t NUM_THREADS = 256;
  static constexpr uint32_t CTA_TILE_Q = CTA_TILE_Q_;
  static constexpr uint32_t CTA_TILE_KV = CTA_TILE_KV_;

  static constexpr SwizzleMode SWIZZLE_MODE_Q_NOPE = SwizzleMode::k128B;
  static constexpr SwizzleMode SWIZZLE_MODE_Q_PE = SwizzleMode::k128B;
  static constexpr SwizzleMode SWIZZLE_MODE_CKV = SwizzleMode::k128B;
  static constexpr SwizzleMode SWIZZLE_MODE_KPE = SwizzleMode::k128B;
  static constexpr SwizzleMode SWIZZLE_MODE_P = SwizzleMode::k128B;
  static constexpr SwizzleMode SWIZZLE_MODE_O = SwizzleMode::k128B;
  static constexpr uint32_t KV_THR_LAYOUT_ROW = 4;
  static constexpr uint32_t KV_THR_LAYOUT_COL = 8;
  static constexpr uint32_t UPCAST_STRIDE_Q_NOPE = HEAD_DIM_CKV / upcast_size<DTypeQ_>();
  static constexpr uint32_t UPCAST_STRIDE_Q_PE = HEAD_DIM_KPE / upcast_size<DTypeQ_>();
  static constexpr uint32_t UPCAST_STRIDE_CKV = HEAD_DIM_CKV / upcast_size<DTypeKV_>();
  static constexpr uint32_t UPCAST_STRIDE_KPE = HEAD_DIM_KPE / upcast_size<DTypeKV_>();
  static constexpr uint32_t UPCAST_STRIDE_FINAL_O = HEAD_DIM_CKV / upcast_size<DTypeO_>();
  static constexpr uint32_t UPCAST_STRIDE_P = CTA_TILE_KV_ / upcast_size<DTypeKV_>();
  static constexpr uint32_t UPCAST_STRIDE_PARTIAL_O = HEAD_DIM_CKV / upcast_size<float>();

  using DTypeQ = DTypeQ_;
  using DTypeKV = DTypeKV_;
  using DTypeO = DTypeO_;
  using IdType = IdType_;
  using DTypeQKAccum = float;

  using SharedStorage = SharedStorageQKVO<NUM_STAGES, CTA_TILE_Q, CTA_TILE_KV, HEAD_DIM_CKV,
                                          HEAD_DIM_KPE, DTypeQ, DTypeKV, DTypeO>;
  using AttentionVariant = StandardAttention;

  static constexpr DTypeQKAccum MaskFillValue = -math::inf;
};

template <typename KTraits>
__device__ __forceinline__ void init_states_(float (*o_frag)[8], typename KTraits::DTypeQKAccum* m,
                                             float* d) {
#pragma unroll
  for (uint32_t mma_d = 0; mma_d < KTraits::NUM_MMA_D_CKV / 2; ++mma_d) {
#pragma unroll
    for (uint32_t reg_id = 0; reg_id < 8; ++reg_id) {
      o_frag[mma_d][reg_id] = 0.f;
    }
  }

#pragma unroll
  for (uint32_t j = 0; j < 2; ++j) {
    m[j] = typename KTraits::DTypeQKAccum(-math::inf);
    d[j] = 1.f;
  }
}

template <typename KTraits>
__device__ __forceinline__ void load_q(
    typename KTraits::SharedStorage* smem_storage, typename KTraits::DTypeQ* q_nope,
    typename KTraits::DTypeQ* q_pe, const uint32_t q_nope_stride_n, const uint32_t q_nope_stride_h,
    const uint32_t q_pe_stride_n, const uint32_t q_pe_stride_h, const uint32_t q_len,
    const uint32_t packed_offset, const uint_fastdiv& num_heads) {
  using DTypeQ = typename KTraits::DTypeQ;
  constexpr uint32_t UPCAST_STRIDE_Q_NOPE = KTraits::UPCAST_STRIDE_Q_NOPE;
  constexpr uint32_t UPCAST_STRIDE_Q_PE = KTraits::UPCAST_STRIDE_Q_PE;
  constexpr uint32_t NUM_MMA_D_CKV = KTraits::NUM_MMA_D_CKV;
  constexpr uint32_t NUM_MMA_D_KPE = KTraits::NUM_MMA_D_KPE;
  const uint32_t lane_idx = threadIdx.x;
  const uint32_t warpgroup_idx = threadIdx.z;
  const uint32_t warp_idx_in_wg = threadIdx.y;

  smem_t<KTraits::SWIZZLE_MODE_Q_NOPE> q_smem_nope(smem_storage->q_smem_nope);
  smem_t<KTraits::SWIZZLE_MODE_Q_PE> q_smem_pe(smem_storage->q_smem_pe);

  uint32_t q_smem_nope_offset_w = q_smem_nope.template get_permuted_offset<UPCAST_STRIDE_Q_NOPE>(
      warpgroup_idx * 16 + warp_idx_in_wg * 4 + lane_idx / 8, lane_idx % 8);
  uint32_t q_smem_pe_offset_w = q_smem_pe.template get_permuted_offset<UPCAST_STRIDE_Q_PE>(
      warpgroup_idx * 16 + warp_idx_in_wg * 4 + lane_idx / 8, lane_idx % 8);

#pragma unroll
  for (uint32_t mma_q = 0; mma_q < 2; ++mma_q) {
    uint32_t q, r;
    num_heads.divmod(
        packed_offset + lane_idx / 8 + (warpgroup_idx + mma_q * 2) * 16 + warp_idx_in_wg * 4, q, r);
    DTypeQ* q_nope_ptr =
        q_nope + q * q_nope_stride_n + r * q_nope_stride_h + (lane_idx % 8) * upcast_size<DTypeQ>();
    DTypeQ* q_pe_ptr =
        q_pe + q * q_pe_stride_n + r * q_pe_stride_h + (lane_idx % 8) * upcast_size<DTypeQ>();
#pragma unroll
    for (uint32_t mma_d = 0; mma_d < KTraits::NUM_MMA_D_CKV / 4; ++mma_d) {
      q_smem_nope.load_128b_async<SharedMemFillMode::kFillZero>(q_smem_nope_offset_w, q_nope_ptr,
                                                                q < q_len);
      q_smem_nope_offset_w =
          q_smem_nope.template advance_offset_by_column<8>(q_smem_nope_offset_w, mma_d);
      q_nope_ptr += 8 * upcast_size<DTypeQ>();
    }
    q_smem_nope_offset_w =
        q_smem_nope.template advance_offset_by_row<32, UPCAST_STRIDE_Q_NOPE>(q_smem_nope_offset_w) -
        2 * NUM_MMA_D_CKV;
#pragma unroll
    for (uint32_t mma_d = 0; mma_d < KTraits::NUM_MMA_D_KPE / 4; ++mma_d) {
      q_smem_pe.load_128b_async<SharedMemFillMode::kFillZero>(q_smem_pe_offset_w, q_pe_ptr,
                                                              q < q_len);
      q_smem_pe_offset_w =
          q_smem_pe.template advance_offset_by_column<8>(q_smem_pe_offset_w, mma_d);
      q_pe_ptr += 8 * upcast_size<DTypeQ>();
    }
    q_smem_pe_offset_w =
        q_smem_pe.template advance_offset_by_row<32, UPCAST_STRIDE_Q_PE>(q_smem_pe_offset_w) -
        2 * NUM_MMA_D_KPE;
  }
}

template <typename KTraits>
__device__ __forceinline__ void load_kv(
    typename KTraits::SharedStorage* smem_storage, typename KTraits::DTypeKV* ckv,
    typename KTraits::DTypeKV* kpe, typename KTraits::IdType* indices, const uint32_t ckv_stride_n,
    const uint32_t ckv_stride_page, const uint32_t kpe_stride_n, const uint32_t kpe_stride_page,
    const uint32_t kv_len, const uint32_t packed_block_iter_base, const uint_fastdiv& block_size,
    const uint32_t stage_idx) {
  using DTypeKV = typename KTraits::DTypeKV;
  constexpr uint32_t UPCAST_STRIDE_CKV = KTraits::UPCAST_STRIDE_CKV;
  constexpr uint32_t UPCAST_STRIDE_KPE = KTraits::UPCAST_STRIDE_KPE;
  constexpr uint32_t NUM_MMA_D_CKV = KTraits::NUM_MMA_D_CKV;
  constexpr uint32_t NUM_MMA_D_KPE = KTraits::NUM_MMA_D_KPE;
  const uint32_t lane_idx = threadIdx.x;
  const uint32_t warpgroup_idx = threadIdx.z;
  const uint32_t warp_idx_in_wg = threadIdx.y;

  smem_t<KTraits::SWIZZLE_MODE_CKV> ckv_smem(smem_storage->ckv_smem[stage_idx]);
  smem_t<KTraits::SWIZZLE_MODE_KPE> kpe_smem(smem_storage->aux_smem[stage_idx].kpe);

  uint32_t ckv_smem_offset_w = ckv_smem.template get_permuted_offset<UPCAST_STRIDE_CKV>(
      warpgroup_idx * 16 + warp_idx_in_wg * 4 + lane_idx / 8, lane_idx % 8);
  uint32_t kpe_smem_offset_w = kpe_smem.template get_permuted_offset<UPCAST_STRIDE_KPE>(
      warpgroup_idx * 16 + warp_idx_in_wg * 4 + lane_idx / 8, lane_idx % 8);
#pragma unroll
  for (uint32_t mma_kv = 0; mma_kv < KTraits::NUM_MMA_KV / 2; ++mma_kv) {
    uint32_t q, r;

    block_size.divmod(packed_block_iter_base + lane_idx / 8 + (warpgroup_idx + mma_kv * 2) * 16 +
                          warp_idx_in_wg * 4,
                      q, r);
    DTypeKV* ckv_ptr = ckv + indices[q] * ckv_stride_page + r * ckv_stride_n +
                       (lane_idx % 8) * upcast_size<DTypeKV>();
    DTypeKV* kpe_ptr = kpe + indices[q] * kpe_stride_page + r * kpe_stride_n +
                       (lane_idx % 8) * upcast_size<DTypeKV>();

#pragma unroll
    for (uint32_t mma_d = 0; mma_d < KTraits::NUM_MMA_D_CKV / 4; ++mma_d) {
      ckv_smem.load_128b_async<SharedMemFillMode::kFillZero>(ckv_smem_offset_w, ckv_ptr,
                                                             q < kv_len);
      ckv_smem_offset_w = ckv_smem.template advance_offset_by_column<8>(ckv_smem_offset_w, mma_d);
      ckv_ptr += 8 * upcast_size<DTypeKV>();
    }
    ckv_smem_offset_w =
        ckv_smem.template advance_offset_by_row<32, UPCAST_STRIDE_CKV>(ckv_smem_offset_w) -
        2 * NUM_MMA_D_CKV;

#pragma unroll
    for (uint32_t mma_d = 0; mma_d < KTraits::NUM_MMA_D_KPE / 4; ++mma_d) {
      kpe_smem.load_128b_async<SharedMemFillMode::kFillZero>(kpe_smem_offset_w, kpe_ptr,
                                                             q < kv_len);
      kpe_smem_offset_w = kpe_smem.template advance_offset_by_column<8>(kpe_smem_offset_w, mma_d);
      kpe_ptr += 8 * upcast_size<DTypeKV>();
    }
    kpe_smem_offset_w =
        kpe_smem.template advance_offset_by_row<32, UPCAST_STRIDE_KPE>(kpe_smem_offset_w) -
        2 * NUM_MMA_D_KPE;
  }
}

template <bool init, typename KTraits, uint32_t NUM_MMA_D_QK, uint32_t UPCAST_STRIDE_Q,
          uint32_t UPCAST_STRIDE_K, SwizzleMode SWIZZLE_MODE_Q, SwizzleMode SWIZZLE_MODE_KV>
__device__ __forceinline__ void compute_qk_(smem_t<SWIZZLE_MODE_Q> q_smem, uint32_t q_smem_offset_r,
                                            smem_t<SWIZZLE_MODE_KV> k_smem,
                                            uint32_t k_smem_offset_r,
                                            typename KTraits::DTypeQKAccum (*s_frag)[8]) {
  uint32_t a_frag[4], b_frag[4];
  // compute q*k^T
#pragma unroll
  for (uint32_t mma_d = 0; mma_d < NUM_MMA_D_QK; ++mma_d) {
    q_smem.ldmatrix_m8n8x4(q_smem_offset_r, a_frag);
    q_smem_offset_r = q_smem.template advance_offset_by_column<2>(q_smem_offset_r, mma_d);

#pragma unroll
    for (uint32_t mma_kv = 0; mma_kv < KTraits::NUM_MMA_KV / 2; ++mma_kv) {
      k_smem.ldmatrix_m8n8x4(k_smem_offset_r, b_frag);
      k_smem_offset_r = k_smem.template advance_offset_by_row<16, UPCAST_STRIDE_K>(k_smem_offset_r);

      if (init && mma_d == 0) {
        mma::mma_sync_m16n16k16_row_col_f16f16f32<typename KTraits::DTypeQ, MMAMode::kInit>(
            s_frag[mma_kv], a_frag, b_frag);
      } else {
        mma::mma_sync_m16n16k16_row_col_f16f16f32<typename KTraits::DTypeQ>(s_frag[mma_kv], a_frag,
                                                                            b_frag);
      }
    }
    k_smem_offset_r = k_smem.template advance_offset_by_column<2>(k_smem_offset_r, mma_d) -
                      (KTraits::NUM_MMA_KV / 2) * 16 * UPCAST_STRIDE_K;
  }
}

template <typename KTraits>
__device__ __forceinline__ void logits_mask_(const uint32_t qo_packed_idx_base,
                                             const uint32_t kv_idx_base, const uint32_t qo_len,
                                             const uint32_t kv_len, const uint32_t chunk_end,
                                             const uint_fastdiv num_heads,
                                             typename KTraits::DTypeQKAccum (*s_frag)[8]) {
  const uint32_t lane_idx = threadIdx.x, warpgroup_idx = threadIdx.z, warp_idx_in_wg = threadIdx.y;
  constexpr uint32_t NUM_MMA_KV = KTraits::NUM_MMA_KV;
  using DTypeQKAccum = typename KTraits::DTypeQKAccum;
  uint32_t q[2];
#pragma unroll
  for (uint32_t j = 0; j < 2; ++j) {
    q[j] = (qo_packed_idx_base + warp_idx_in_wg * 16 + lane_idx / 4 + 8 * j) / num_heads;
  }

#pragma unroll
  for (uint32_t mma_kv = 0; mma_kv < NUM_MMA_KV / 2; ++mma_kv) {
#pragma unroll
    for (uint32_t reg_id = 0; reg_id < 8; ++reg_id) {
      const uint32_t q_idx = q[(reg_id % 4) / 2],
                     kv_idx = kv_idx_base + warpgroup_idx * (NUM_MMA_KV / 2) * 16 + mma_kv * 16 +
                              2 * (lane_idx % 4) + 8 * (reg_id / 4) + reg_id % 2;
      const bool mask =
          (!(KTraits::CAUSAL ? (kv_idx + qo_len > kv_len + q_idx || (kv_idx >= chunk_end))
                             : kv_idx >= chunk_end));
      s_frag[mma_kv][reg_id] = (mask) ? s_frag[mma_kv][reg_id] : (KTraits::MaskFillValue);
    }
  }
}

template <typename KTraits>
__device__ __forceinline__ void update_mdo_states_(typename KTraits::SharedStorage* smem_storage,
                                                   const uint32_t stage_idx,
                                                   typename KTraits::AttentionVariant variant,
                                                   typename KTraits::DTypeQKAccum (*s_frag)[8],
                                                   float (*o_frag)[8],
                                                   typename KTraits::DTypeQKAccum* m, float* d) {
  using DTypeQKAccum = typename KTraits::DTypeQKAccum;
  using AttentionVariant = typename KTraits::AttentionVariant;
  const float sm_scale = variant.sm_scale_log2;
  const uint32_t warpgroup_idx = threadIdx.z, lane_idx = threadIdx.x, warp_idx_in_wg = threadIdx.y;
  float m_prev[2];
#pragma unroll
  for (uint32_t j = 0; j < 2; ++j) {
    m_prev[j] = m[j];
#pragma unroll
    for (uint32_t mma_kv = 0; mma_kv < KTraits::NUM_MMA_KV / 2; ++mma_kv) {
      float m_local = max(max(s_frag[mma_kv][j * 2 + 0], s_frag[mma_kv][j * 2 + 1]),
                          max(s_frag[mma_kv][j * 2 + 4], s_frag[mma_kv][j * 2 + 5]));
      m[j] = max(m[j], m_local);
    }
    m[j] = max(m[j], math::shfl_xor_sync(m[j], 0x2));
    m[j] = max(m[j], math::shfl_xor_sync(m[j], 0x1));
    if (lane_idx % 4 == 0) {
      smem_storage->aux_smem[stage_idx]
          .m_wg[warpgroup_idx][warp_idx_in_wg * 16 + j * 8 + lane_idx / 4] = m[j];
    }
  }

  __syncthreads();

#pragma unroll
  for (uint32_t j = 0; j < 2; ++j) {
    m[j] = max(smem_storage->aux_smem[stage_idx]
                   .m_wg[1 - warpgroup_idx][warp_idx_in_wg * 16 + j * 8 + lane_idx / 4],
               m[j]);
    float o_scale = math::ptx_exp2(m_prev[j] * sm_scale - m[j] * sm_scale);
    d[j] *= o_scale;
#pragma unroll
    for (uint32_t mma_d = 0; mma_d < KTraits::NUM_MMA_D_CKV / 2; ++mma_d) {
      o_frag[mma_d][j * 2 + 0] *= o_scale;
      o_frag[mma_d][j * 2 + 1] *= o_scale;
      o_frag[mma_d][j * 2 + 4] *= o_scale;
      o_frag[mma_d][j * 2 + 5] *= o_scale;
    }
#pragma unroll
    for (uint32_t mma_kv = 0; mma_kv < KTraits::NUM_MMA_KV / 2; ++mma_kv) {
      s_frag[mma_kv][j * 2 + 0] =
          math::ptx_exp2(s_frag[mma_kv][j * 2 + 0] * sm_scale - m[j] * sm_scale);
      s_frag[mma_kv][j * 2 + 1] =
          math::ptx_exp2(s_frag[mma_kv][j * 2 + 1] * sm_scale - m[j] * sm_scale);
      s_frag[mma_kv][j * 2 + 4] =
          math::ptx_exp2(s_frag[mma_kv][j * 2 + 4] * sm_scale - m[j] * sm_scale);
      s_frag[mma_kv][j * 2 + 5] =
          math::ptx_exp2(s_frag[mma_kv][j * 2 + 5] * sm_scale - m[j] * sm_scale);
    }
  }
}

template <typename KTraits>
__device__ __forceinline__ void store_p_smem(typename KTraits::SharedStorage* smem_storage,
                                             const uint32_t stage_idx,
                                             typename KTraits::DTypeQKAccum (*s_frag)[8],
                                             typename KTraits::DTypeQKAccum* d) {
  const uint32_t lane_idx = threadIdx.x, warpgroup_idx = threadIdx.z, warp_idx_in_wg = threadIdx.y;
  typename KTraits::DTypeKV p_f16[KTraits::NUM_MMA_KV][8];
#pragma unroll
  for (uint32_t mma_kv = 0; mma_kv < KTraits::NUM_MMA_KV / 2; ++mma_kv) {
    vec_cast<typename KTraits::DTypeKV, float>::cast<8>(p_f16[mma_kv], s_frag[mma_kv]);
    mma::m16k16_rowsum_f16f16f32(d, p_f16[mma_kv]);
  }

  __syncthreads();
  smem_t<KTraits::SWIZZLE_MODE_P> p_smem(smem_storage->aux_smem[stage_idx].p);
#pragma unroll
  for (uint32_t mma_kv = 0; mma_kv < KTraits::NUM_MMA_KV / 2; ++mma_kv) {
#ifdef FLASHINFER_STMATRIX_M8N8X4_ENABLED
    uint32_t p_smem_offset_w = p_smem.template get_permuted_offset<KTraits::UPCAST_STRIDE_P>(
        warp_idx_in_wg * 16 + lane_idx % 16,
        warpgroup_idx * KTraits::NUM_MMA_KV + mma_kv * 2 + lane_idx / 16);
    p_smem.stmatrix_m8n8x4(p_smem_offset_w, (uint32_t*)p_f16[mma_kv]);
#else
    static_assert(false, "Not implemented yet");
#endif
  }
}

template <typename KTraits>
__device__ __forceinline__ void compute_mla_qk(typename KTraits::SharedStorage* smem_storage,
                                               const uint32_t stage_idx,
                                               typename KTraits::DTypeQKAccum (*s_frag)[8]) {
  constexpr uint32_t UPCAST_STRIDE_Q_NOPE = KTraits::UPCAST_STRIDE_Q_NOPE;
  constexpr uint32_t UPCAST_STRIDE_Q_PE = KTraits::UPCAST_STRIDE_Q_PE;
  constexpr uint32_t UPCAST_STRIDE_CKV = KTraits::UPCAST_STRIDE_CKV;
  constexpr uint32_t UPCAST_STRIDE_KPE = KTraits::UPCAST_STRIDE_KPE;
  constexpr uint32_t NUM_MMA_KV = KTraits::NUM_MMA_KV;
  smem_t<KTraits::SWIZZLE_MODE_Q_NOPE> q_smem_nope(smem_storage->q_smem_nope);
  smem_t<KTraits::SWIZZLE_MODE_Q_PE> q_smem_pe(smem_storage->q_smem_pe);
  smem_t<KTraits::SWIZZLE_MODE_CKV> ckv_smem(smem_storage->ckv_smem[stage_idx]);
  smem_t<KTraits::SWIZZLE_MODE_KPE> kpe_smem(smem_storage->aux_smem[stage_idx].kpe);
  const uint32_t lane_idx = threadIdx.x, warpgroup_idx = threadIdx.z, warp_idx_in_wg = threadIdx.y;
  uint32_t q_smem_nope_offset_r = q_smem_nope.template get_permuted_offset<UPCAST_STRIDE_Q_NOPE>(
      warp_idx_in_wg * 16 + lane_idx % 16, lane_idx / 16);
  uint32_t q_smem_pe_offset_r = q_smem_pe.template get_permuted_offset<UPCAST_STRIDE_Q_PE>(
      warp_idx_in_wg * 16 + lane_idx % 16, lane_idx / 16);
  uint32_t ckv_smem_offset_r = ckv_smem.template get_permuted_offset<UPCAST_STRIDE_CKV>(
      warpgroup_idx * (NUM_MMA_KV / 2) * 16 + 8 * (lane_idx / 16) + lane_idx % 8,
      (lane_idx % 16) / 8);
  uint32_t kpe_smem_offset_r = kpe_smem.template get_permuted_offset<UPCAST_STRIDE_KPE>(
      warpgroup_idx * (NUM_MMA_KV / 2) * 16 + 8 * (lane_idx / 16) + lane_idx % 8,
      (lane_idx % 16) / 8);
  compute_qk_</*init=*/true, KTraits, KTraits::NUM_MMA_D_KPE, KTraits::UPCAST_STRIDE_Q_PE,
              KTraits::UPCAST_STRIDE_KPE>(q_smem_pe, q_smem_pe_offset_r, kpe_smem,
                                          kpe_smem_offset_r, s_frag);
  compute_qk_</*init=*/false, KTraits, KTraits::NUM_MMA_D_CKV, KTraits::UPCAST_STRIDE_Q_NOPE,
              KTraits::UPCAST_STRIDE_CKV>(q_smem_nope, q_smem_nope_offset_r, ckv_smem,
                                          ckv_smem_offset_r, s_frag);
}

template <typename KTraits>
__device__ __forceinline__ void compute_mla_pk(typename KTraits::SharedStorage* smem_storage,
                                               const uint32_t stage_idx, float (*o_frag)[8]) {
  constexpr uint32_t UPCAST_STRIDE_P = KTraits::UPCAST_STRIDE_P;
  constexpr uint32_t UPCAST_STRIDE_CKV = KTraits::UPCAST_STRIDE_CKV;
  constexpr uint32_t NUM_MMA_KV = KTraits::NUM_MMA_KV;
  constexpr uint32_t NUM_MMA_D_CKV = KTraits::NUM_MMA_D_CKV;
  smem_t<KTraits::SWIZZLE_MODE_P> p_smem(smem_storage->aux_smem[stage_idx].p);
  smem_t<KTraits::SWIZZLE_MODE_CKV> ckv_smem(smem_storage->ckv_smem[stage_idx]);
  const uint32_t lane_idx = threadIdx.x, warpgroup_idx = threadIdx.z, warp_idx_in_wg = threadIdx.y;
  uint32_t p_smem_offset_r = p_smem.template get_permuted_offset<UPCAST_STRIDE_P>(
      warp_idx_in_wg * 16 + lane_idx % 16, lane_idx / 16);
  uint32_t ckv_smem_offset_r = ckv_smem.template get_permuted_offset<UPCAST_STRIDE_CKV>(
      lane_idx % 16, warpgroup_idx * NUM_MMA_D_CKV + lane_idx / 16);

  // wait for p_smem to be filled
  __syncthreads();

#pragma unroll
  for (uint32_t mma_kv = 0; mma_kv < NUM_MMA_KV; ++mma_kv) {
    uint32_t p_frag[4];
    p_smem.ldmatrix_m8n8x4(p_smem_offset_r, p_frag);
    p_smem_offset_r = p_smem.template advance_offset_by_column<2>(p_smem_offset_r, mma_kv);

#pragma unroll
    for (uint32_t mma_d = 0; mma_d < NUM_MMA_D_CKV / 2; ++mma_d) {
      uint32_t v_frag[4];
      ckv_smem.ldmatrix_m8n8x4_trans(ckv_smem_offset_r, v_frag);
      mma::mma_sync_m16n16k16_row_col_f16f16f32<typename KTraits::DTypeKV>(o_frag[mma_d], p_frag,
                                                                           v_frag);
      ckv_smem_offset_r = ckv_smem.template advance_offset_by_column<2>(ckv_smem_offset_r, mma_d);
    }
    ckv_smem_offset_r =
        ckv_smem.template advance_offset_by_row<16, UPCAST_STRIDE_CKV>(ckv_smem_offset_r) -
        NUM_MMA_D_CKV;
  }
}

template <typename KTraits>
__device__ __forceinline__ void normalize_d_(typename KTraits::SharedStorage* smem_storage,
                                             const uint32_t stage_idx, float (*o_frag)[8],
                                             typename KTraits::DTypeQKAccum* m, float* d) {
  const uint32_t warpgroup_idx = threadIdx.z, lane_idx = threadIdx.x, warp_idx_in_wg = threadIdx.y;
#pragma unroll
  for (uint32_t j = 0; j < 2; ++j) {
    if (lane_idx % 4 == 0) {
      smem_storage->aux_smem[stage_idx]
          .d_wg[warpgroup_idx][warp_idx_in_wg * 16 + j * 8 + lane_idx / 4] = d[j];
    }
  }
  __syncthreads();
#pragma unroll
  for (uint32_t j = 0; j < 2; ++j) {
    d[j] = max(smem_storage->aux_smem[stage_idx]
                   .d_wg[1 - warpgroup_idx][warp_idx_in_wg * 16 + j * 8 + lane_idx / 4],
               d[j]);
  }

  float d_rcp[2];
  // compute reciprocal of d
#pragma unroll
  for (uint32_t j = 0; j < 2; ++j) {
    d_rcp[j] = (m[j] != typename KTraits::DTypeQKAccum(-math::inf)) ? math::ptx_rcp(d[j]) : 0.f;
  }

#pragma unroll
  for (uint32_t mma_d = 0; mma_d < KTraits::NUM_MMA_D_CKV / 2; ++mma_d) {
#pragma unroll
    for (uint32_t reg_id = 0; reg_id < 8; ++reg_id) {
      o_frag[mma_d][reg_id] = o_frag[mma_d][reg_id] * d_rcp[(reg_id % 4) / 2];
    }
  }
}

template <typename KTraits>
__device__ __forceinline__ void write_o(typename KTraits::SharedStorage* smem_storage,
                                        typename KTraits::DTypeO* final_o, float* final_lse,
                                        float* partial_o, float* partial_lse, float (*o_frag)[8],
                                        typename KTraits::DTypeQKAccum* m, float* d,
                                        const uint32_t o_stride_n, const uint32_t o_stride_h,
                                        const uint32_t q_len, const uint32_t packed_offset,
                                        const uint_fastdiv& num_heads) {
  using DTypeO = typename KTraits::DTypeO;
  constexpr uint32_t NUM_MMA_D_CKV = KTraits::NUM_MMA_D_CKV;
  constexpr uint32_t HEAD_DIM_CKV = KTraits::HEAD_DIM_CKV;
  constexpr uint32_t UPCAST_STRIDE_FINAL_O = KTraits::UPCAST_STRIDE_FINAL_O;
  const uint32_t lane_idx = threadIdx.x, warpgroup_idx = threadIdx.z, warp_idx_in_wg = threadIdx.y;

  if (false) {
    // TOOD(Zihao): write to partial
  } else {
    // write to final_o
    smem_t<KTraits::SWIZZLE_MODE_O> o_smem(smem_storage->o_smem);

    // step 0. rmem to smem
#pragma unroll
    for (uint32_t mma_d = 0; mma_d < NUM_MMA_D_CKV / 2; ++mma_d) {
      uint32_t o_frag_f16[8 / 2];
      vec_cast<DTypeO, float>::cast<8>((DTypeO*)o_frag_f16, o_frag[mma_d]);
#ifdef FLASHINFER_STMATRIX_M8N8X4_ENABLED
      uint32_t o_smem_offset_w = o_smem.template get_permuted_offset<UPCAST_STRIDE_FINAL_O>(
          warp_idx_in_wg * 16 + lane_idx % 16,
          warpgroup_idx * NUM_MMA_D_CKV + mma_d * 2 + lane_idx / 16);
      o_smem.template stmatrix_m8n8x4(o_smem_offset_w, o_frag_f16);
#else
      uint32_t o_smem_offset_w = o_smem.template get_permuted_offset<UPCAST_STRIDE_FINAL_O>(
          warp_idx_in_wg * 16 + lane_idx / 4, warpgroup_idx * NUM_MMA_D_CKV + mma_d * 2);
      ((uint32_t*)(o_smem.base + o_smem_offset_w))[lane_idx % 4] = o_frag_f16[0];
      ((uint32_t*)(o_smem.base + o_smem_offset_w + 8 * UPCAST_STRIDE_FINAL_O))[lane_idx % 4] =
          o_frag_f16[1];
      ((uint32_t*)(o_smem.base + (o_smem_offset_w ^ 0x1)))[lane_idx % 4] = o_frag_f16[2];
      ((uint32_t*)(o_smem.base + (o_smem_offset_w ^ 0x1) +
                   8 * UPCAST_STRIDE_FINAL_O))[lane_idx % 4] = o_frag_f16[3];
#endif
    }

    // step 1. smem to gmem
    uint32_t o_smem_offset_w = o_smem.template get_permuted_offset<UPCAST_STRIDE_FINAL_O>(
        warp_idx_in_wg * 16 + lane_idx / 8, warpgroup_idx * NUM_MMA_D_CKV + lane_idx % 8);
#pragma unroll
    for (uint32_t j = 0; j < 4; ++j) {
      uint32_t q, r;
      num_heads.divmod(packed_offset + warp_idx_in_wg * 16 + 4 * j + lane_idx / 8, q, r);
      DTypeO* o_final_ptr = final_o + q * o_stride_n + r * o_stride_h +
                            warpgroup_idx * (HEAD_DIM_CKV / 2) +
                            (lane_idx % 8) * upcast_size<DTypeO>();
#pragma unroll
      for (uint32_t mma_d = 0; mma_d < NUM_MMA_D_CKV / 8; ++mma_d) {
        if (q < q_len) {
          o_smem.template store_128b(o_smem_offset_w, o_final_ptr);
        }
        o_final_ptr += 8 * upcast_size<DTypeO>();
        o_smem_offset_w = o_smem.template advance_offset_by_column<8>(o_smem_offset_w, mma_d);
      }
      o_smem_offset_w =
          o_smem.template advance_offset_by_row<4, UPCAST_STRIDE_FINAL_O>(o_smem_offset_w) -
          NUM_MMA_D_CKV;
    }
  }
}

template <typename KTraits, typename Params>
__global__ __launch_bounds__(KTraits::NUM_THREADS) void BatchMLAPageAttentionKernel(
    const __grid_constant__ Params params) {
  using DTypeQ = typename Params::DTypeQ;
  using DTypeKV = typename Params::DTypeKV;
  using DTypeO = typename Params::DTypeO;
  using IdType = typename Params::IdType;

  extern __shared__ uint8_t smem[];
  auto& smem_storage = reinterpret_cast<typename KTraits::SharedStorage&>(smem);

  typename KTraits::AttentionVariant variant(params, blockIdx.y, smem);

  [[maybe_unused]] constexpr SwizzleMode SWIZZLE_MODE_Q_NOPE = KTraits::SWIZZLE_MODE_Q_NOPE;
  [[maybe_unused]] constexpr SwizzleMode SWIZZLE_MODE_Q_PE = KTraits::SWIZZLE_MODE_Q_PE;
  [[maybe_unused]] constexpr SwizzleMode SWIZZLE_MODE_CKV = KTraits::SWIZZLE_MODE_CKV;
  [[maybe_unused]] constexpr SwizzleMode SWIZZLE_MODE_KPE = KTraits::SWIZZLE_MODE_KPE;
  [[maybe_unused]] constexpr uint32_t KV_THR_LAYOUT_ROW = KTraits::KV_THR_LAYOUT_ROW;
  [[maybe_unused]] constexpr uint32_t KV_THR_LAYOUT_COL = KTraits::KV_THR_LAYOUT_COL;
  [[maybe_unused]] constexpr uint32_t NUM_MMA_KV = KTraits::NUM_MMA_KV;
  [[maybe_unused]] constexpr uint32_t NUM_MMA_D_CKV = KTraits::NUM_MMA_D_CKV;
  [[maybe_unused]] constexpr uint32_t CTA_TILE_Q = KTraits::CTA_TILE_Q;
  [[maybe_unused]] constexpr uint32_t CTA_TILE_KV = KTraits::CTA_TILE_KV;
  [[maybe_unused]] constexpr uint32_t NUM_STAGES = KTraits::NUM_STAGES;
  [[maybe_unused]] constexpr bool CAUSAL = KTraits::CAUSAL;

  DTypeQ* q_nope = params.q_nope;
  DTypeQ* q_pe = params.q_pe;
  DTypeKV* ckv = params.ckv;
  DTypeKV* kpe = params.kpe;
  IdType* kv_indices = params.kv_indices;
  float* partial_o = params.partial_o;
  float* partial_lse = params.partial_lse;
  DTypeO* final_o = params.final_o;
  float* final_lse = params.final_lse;
  IdType* work_indptr = params.work_indptr;
  // IdType* indices = params.indices;

  float s_frag[NUM_MMA_KV / 2][8];
  alignas(16) float o_frag[NUM_MMA_D_CKV / 2][8];
  float m[2];
  float d[2];

  const uint_fastdiv& num_heads = params.num_heads;
  const uint_fastdiv& block_size = params.block_size;
  const uint32_t q_nope_stride_n = params.q_nope_stride_n;
  const uint32_t q_nope_stride_h = params.q_nope_stride_h;
  const uint32_t q_pe_stride_n = params.q_pe_stride_n;
  const uint32_t q_pe_stride_h = params.q_pe_stride_h;
  const uint32_t ckv_stride_page = params.ckv_stride_page;
  const uint32_t ckv_stride_n = params.ckv_stride_n;
  const uint32_t kpe_stride_page = params.kpe_stride_page;
  const uint32_t kpe_stride_n = params.kpe_stride_n;
  const uint32_t o_stride_n = params.o_stride_n;
  const uint32_t o_stride_h = params.o_stride_h;
  const uint32_t cluster_tile_q = blockDim.x * KTraits::CTA_TILE_Q;

#pragma unroll 1
  for (IdType work_idx = work_indptr[blockIdx.y]; work_idx < work_indptr[blockIdx.y + 1];
       ++work_idx) {
    const uint32_t q_indptr = params.q_indptr[work_idx];
    const uint32_t kv_indptr = params.kv_indptr[work_idx];
    const uint32_t q_len = params.q_len[work_idx];
    const uint32_t kv_len = params.kv_len[work_idx];
    const uint32_t packed_qo_start = params.q_start[work_idx];
    const uint32_t kv_start = params.kv_start[work_idx];
    const uint32_t kv_end = params.kv_end[work_idx];

    const uint32_t qo_packed_idx_base = packed_qo_start + blockIdx.x * KTraits::CTA_TILE_Q;

    init_states_<KTraits>(o_frag, m, d);

    load_q<KTraits>(&smem_storage, q_nope + q_indptr * q_nope_stride_n,
                    q_pe + q_indptr * q_pe_stride_n, q_nope_stride_n, q_nope_stride_h,
                    q_pe_stride_n, q_pe_stride_h, q_len, qo_packed_idx_base, params.num_heads);

    cp_async::commit_group();
    cp_async::wait_group<0>();
    __syncthreads();

    int kv_tile_idx =
        (CAUSAL ? min(kv_end, kv_len - q_len + (packed_qo_start + cluster_tile_q) / num_heads)
                : kv_end) /
        CTA_TILE_KV;
    // CTA_TILE_KV);

    int mask_tile_idx =  // ceil_div(
        (CAUSAL ? min(kv_end, kv_len - q_len + packed_qo_start / num_heads) : kv_end) / CTA_TILE_KV;

    int start_tile_idx = kv_start / CTA_TILE_KV;  // ceil_div(kv_start, CTA_TILE_KV);
    uint32_t block_iter_base = (kv_indptr + kv_start) * block_size;

    // last kv tile
    load_kv<KTraits>(&smem_storage, ckv, kpe, kv_indices, ckv_stride_n, ckv_stride_page,
                     kpe_stride_n, kpe_stride_page, kv_len,
                     block_iter_base + kv_tile_idx * CTA_TILE_KV, block_size,
                     kv_tile_idx % NUM_STAGES);
    cp_async::commit_group();
    if (kv_tile_idx - 1 >= start_tile_idx) {
      load_kv<KTraits>(&smem_storage, ckv, kpe, kv_indices, ckv_stride_n, ckv_stride_page,
                       kpe_stride_n, kpe_stride_page, kv_len,
                       block_iter_base + (kv_tile_idx - 1) * CTA_TILE_KV, block_size,
                       (kv_tile_idx - 1) % NUM_STAGES);
      cp_async::commit_group();
    }

#pragma unroll 1
    for (; kv_tile_idx >= mask_tile_idx; --kv_tile_idx) {
      cp_async::wait_group<1>();
      __syncthreads();

      // compute mla qk
      compute_mla_qk<KTraits>(&smem_storage, kv_tile_idx % NUM_STAGES, s_frag);

      // logits mask
      logits_mask_<KTraits>(qo_packed_idx_base, kv_start + kv_tile_idx * CTA_TILE_KV, q_len, kv_len,
                            kv_end, num_heads, s_frag);

      // compute m,d states in online softmax
      update_mdo_states_<KTraits>(&smem_storage, kv_tile_idx % NUM_STAGES, variant, s_frag, o_frag,
                                  m, d);
      store_p_smem<KTraits>(&smem_storage, kv_tile_idx % NUM_STAGES, s_frag, d);

      // compute sfm * v
      compute_mla_pk<KTraits>(&smem_storage, kv_tile_idx % NUM_STAGES, o_frag);

      if (kv_tile_idx - 2 >= start_tile_idx) {
        __syncthreads();
        load_kv<KTraits>(&smem_storage, ckv, kpe, kv_indices, ckv_stride_n, ckv_stride_page,
                         kpe_stride_n, kpe_stride_page, kv_len,
                         block_iter_base + (kv_tile_idx - 2) * CTA_TILE_KV, block_size,
                         (kv_tile_idx - 2) % NUM_STAGES);
        cp_async::commit_group();
      }
    }

#pragma unroll 1
    for (; kv_tile_idx > start_tile_idx + 1; --kv_tile_idx) {
      cp_async::wait_group<1>();
      __syncthreads();

      // compute mla qk
      compute_mla_qk<KTraits>(&smem_storage, kv_tile_idx % NUM_STAGES, s_frag);

      // compute m,d states in online softmax
      update_mdo_states_<KTraits>(&smem_storage, kv_tile_idx % NUM_STAGES, variant, s_frag, o_frag,
                                  m, d);
      store_p_smem<KTraits>(&smem_storage, kv_tile_idx % NUM_STAGES, s_frag, d);

      // compute sfm * v
      compute_mla_pk<KTraits>(&smem_storage, kv_tile_idx % NUM_STAGES, o_frag);

      __syncthreads();
      load_kv<KTraits>(&smem_storage, ckv, kpe, kv_indices, ckv_stride_n, ckv_stride_page,
                       kpe_stride_n, kpe_stride_page, kv_len,
                       block_iter_base + (kv_tile_idx - 2) * CTA_TILE_KV, block_size,
                       (kv_tile_idx - 2) % NUM_STAGES);
      cp_async::commit_group();
    }
    cp_async::wait_group<0>();
    __syncthreads();

#pragma unroll
    for (; kv_tile_idx >= start_tile_idx; --kv_tile_idx) {
      // compute mla qk
      compute_mla_qk<KTraits>(&smem_storage, kv_tile_idx % NUM_STAGES, s_frag);

      // compute m,d states in online softmax
      update_mdo_states_<KTraits>(&smem_storage, kv_tile_idx % NUM_STAGES, variant, s_frag, o_frag,
                                  m, d);
      store_p_smem<KTraits>(&smem_storage, kv_tile_idx % NUM_STAGES, s_frag, d);

      // compute sfm * v
      compute_mla_pk<KTraits>(&smem_storage, kv_tile_idx % NUM_STAGES, o_frag);
    }

    // normalize and write back
    normalize_d_<KTraits>(&smem_storage, 0 % NUM_STAGES, o_frag, m, d);
    write_o<KTraits>(&smem_storage, final_o + q_indptr * o_stride_n, final_lse, partial_o,
                     partial_lse, o_frag, m, d, o_stride_n, o_stride_h, q_len, qo_packed_idx_base,
                     num_heads);
  }
}

template <MaskMode MASK_MODE, uint32_t HEAD_DIM_CKV, uint32_t HEAD_DIM_KPE, typename Params>
cudaError_t BatchMLAPageAttention(Params params, uint32_t num_blks_x, uint32_t num_blks_y,
                                  cudaStream_t stream) {
  using DTypeQ = typename Params::DTypeQ;
  using DTypeKV = typename Params::DTypeKV;
  using DTypeO = typename Params::DTypeO;
  using IdType = typename Params::IdType;
  if (MASK_MODE == MaskMode::kCustom) {
    return cudaErrorNotSupported;
  }
  constexpr bool CAUSAL = MASK_MODE == MaskMode::kCausal;

  using DTypeQ = typename Params::DTypeQ;
  using DTypeKV = typename Params::DTypeKV;
  using DTypeO = typename Params::DTypeO;

  dim3 nblks(num_blks_x, num_blks_y);
  dim3 nthrs(32, 4, 2);

  using KTraits =
      KernelTraits<CAUSAL, /*NUM_STAGES_=*/2, HEAD_DIM_CKV, HEAD_DIM_KPE, /*CTA_TILE_Q_=*/64,
                   /*CTA_TILE_KV_=*/64, DTypeQ, DTypeKV, DTypeO, IdType>;
  size_t smem_size = sizeof(typename KTraits::SharedStorage);

  auto kernel = BatchMLAPageAttentionKernel<KTraits, Params>;
  void* args[] = {(void*)&params};

  FLASHINFER_CUDA_CALL(
      cudaFuncSetAttribute(kernel, cudaFuncAttributeMaxDynamicSharedMemorySize, smem_size));
  FLASHINFER_CUDA_CALL(cudaLaunchKernel((void*)kernel, nblks, nthrs, args, smem_size, stream));
  return cudaSuccess;
}

}  // namespace mla

}  // namespace flashinfer

#endif  // FLASHINFER_MLA_FA2_CUH_
