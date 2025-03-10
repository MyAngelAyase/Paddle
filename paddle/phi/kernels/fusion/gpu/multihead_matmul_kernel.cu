// Copyright (c) 2023 PaddlePaddle Authors. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include <algorithm>
#include <type_traits>

#include "paddle/phi/common/float16.h"
#include "paddle/phi/core/enforce.h"
#include "paddle/phi/core/errors.h"
#include "paddle/phi/core/kernel_registry.h"
#include "paddle/phi/core/tensor_utils.h"
#include "paddle/phi/kernels/funcs/blas/blas.h"
#include "paddle/phi/kernels/funcs/multihead_matmul_functor.h"

namespace phi {
namespace fusion {

template <typename T>
__global__ void transpose(T *src,
                          T *dst,
                          const int batch_size,
                          const int seq_len,
                          const int head_num,
                          const int size_per_head) {
  int batch_id = blockIdx.x / (head_num * seq_len);
  int seq_id = blockIdx.x % seq_len;
  int head_id = (blockIdx.x % (head_num * seq_len)) / seq_len;
  dst[batch_id * (head_num * seq_len * size_per_head) +
      seq_id * head_num * size_per_head + head_id * size_per_head +
      threadIdx.x] = src[blockIdx.x * size_per_head + threadIdx.x];
}

template <typename T>
inline __device__ T add_func(T a, T b);

template <>
__device__ float add_func<float>(float a, float b) {
  return a + b;
}

template <>
__device__ float2 add_func<float2>(float2 a, float2 b) {
  float2 c;
  c.x = a.x + b.x;
  c.y = a.y + b.y;
  return c;
}

template <>
__device__ float4 add_func<float4>(float4 a, float4 b) {
  float4 c;
  c.x = a.x + b.x;
  c.y = a.y + b.y;
  c.z = a.z + b.z;
  c.w = a.w + b.w;
  return c;
}
#if defined(PADDLE_WITH_CUDA)
template <>
__device__ half2 add_func<half2>(half2 a, half2 b) {
#if __CUDA_ARCH__ >= 530
  return __hadd2(a, b);
#else
  return half2(__float2half(__half2float(a.x) + __half2float(b.x)),
               __float2half(__half2float(b.x) + __half2float(b.y)));
#endif
}

template <>
__device__ half add_func<half>(half a, half b) {
#if __CUDA_ARCH__ >= 530
  return __hadd(a, b);
#else
  return __float2half(__half2float(a) + __half2float(b));
#endif
}
#endif

template <typename T>
__global__ void TransposeQkvKernel(const int H,
                                   const T *input,
                                   const T *bias,
                                   T *output) {
  // Input: BxSx3xNxH
  // Bias: 3xNxH
  // Output: 3xBxNxSxH
  int n = threadIdx.y;
  int s = blockIdx.x;
  int b = blockIdx.y;
  int m = blockIdx.z;

  const int N = blockDim.y;
  const int S = gridDim.x;
  const int B = gridDim.y;

  const int NH = N * H;
  const int NHS = NH * S;
  const int in_offset = n * H + m * NH + s * 3 * NH + b * NHS * 3;
  const int bias_offset = m * NH + n * H;
  const int out_offset = s * H + n * S * H + b * NHS + m * NHS * B;

  const int i = threadIdx.x;
  output[out_offset + i] =
      add_func(input[in_offset + i], bias[bias_offset + i]);
}

template <typename T>
void TransQKVWithBias(const int batch,
                      const int seq_len,
                      const int head_size,
                      const int head_num,
                      const T *input,
                      const T *bias,
                      T *output,
                      gpuStream_t stream);

template <>
void TransQKVWithBias(const int batch,
                      const int seq_len,
                      const int head_size,
                      const int head_num,
                      const float *input,
                      const float *bias,
                      float *output,
                      gpuStream_t stream) {
  // BxSx3xNxH + 3xNxH -> 3xBxNxSxH
  int scratch_size = batch * head_num * seq_len * seq_len;
  const dim3 grid(seq_len, batch, 3);
  // scratch % 4 == 0 to ensure the alignment
  if (head_size % 4 == 0 && scratch_size % 4 == 0) {
    const int h = head_size / 4;
    const float4 *input4 = reinterpret_cast<const float4 *>(input);
    const float4 *bias4 = reinterpret_cast<const float4 *>(bias);
    float4 *output4 = reinterpret_cast<float4 *>(output);
    const dim3 block(h, head_num, 1);

    // limit h * head_num to max block size(1024).
    PADDLE_ENFORCE_LE(h * head_num,
                      1024,
                      phi::errors::InvalidArgument(
                          "head_num (%d) * head_size (%d) should <= %d",
                          head_num,
                          head_size,
                          1024 * 4));
    TransposeQkvKernel<float4>
        <<<grid, block, 0, stream>>>(h, input4, bias4, output4);
  } else if (head_size % 2 == 0 && scratch_size % 2 == 0) {
    const int h = head_size / 2;
    const float2 *input2 = reinterpret_cast<const float2 *>(input);
    const float2 *bias2 = reinterpret_cast<const float2 *>(bias);
    float2 *output2 = reinterpret_cast<float2 *>(output);
    const dim3 block(h, head_num, 1);
    // limit h * head_num to max block size(1024).
    PADDLE_ENFORCE_LE(h * head_num,
                      1024,
                      phi::errors::InvalidArgument(
                          "head_num (%d) * head_size (%d) should <= %d",
                          head_num,
                          head_size,
                          1024 * 2));
    TransposeQkvKernel<float2>
        <<<grid, block, 0, stream>>>(h, input2, bias2, output2);
  } else {
    const dim3 block(head_size, head_num, 1);
    // limit head_size * head_num to max block size(1024).
    PADDLE_ENFORCE_LE(head_size * head_num,
                      1024,
                      phi::errors::InvalidArgument(
                          "head_num (%d) * head_size (%d) should <= %d",
                          head_num,
                          head_size,
                          1024));
    TransposeQkvKernel<float>
        <<<grid, block, 0, stream>>>(head_size, input, bias, output);
  }
}

#if defined(PADDLE_WITH_CUDA)
template <>
void TransQKVWithBias(const int batch,
                      const int seq_len,
                      const int head_size,
                      const int head_num,
                      const phi::dtype::float16 *input,
                      const phi::dtype::float16 *bias,
                      phi::dtype::float16 *output,
                      gpuStream_t stream) {
  // BxSx3xNxH + 3xNxH -> 3xBxNxSxH
  int scratch_size = batch * head_num * seq_len * seq_len;
  const dim3 grid(seq_len, batch, 3);
  if (head_size % 2 == 0 && scratch_size % 2 == 0) {
    const int h = head_size / 2;
    const half2 *input2 = reinterpret_cast<const half2 *>(input);
    const half2 *bias2 = reinterpret_cast<const half2 *>(bias);
    half2 *output2 = reinterpret_cast<half2 *>(output);
    const dim3 block(h, head_num, 1);
    // limit h * head_num to max block size(1024).
    PADDLE_ENFORCE_LE(h * head_num,
                      1024,
                      phi::errors::InvalidArgument(
                          "head_num (%d) * head_size (%d) should <= %d",
                          head_num,
                          head_size,
                          1024 * 2));
    TransposeQkvKernel<half2>
        <<<grid, block, 0, stream>>>(h, input2, bias2, output2);
  } else {
    const dim3 block(head_size, head_num, 1);
    const half *input_half = reinterpret_cast<const half *>(input);
    const half *bias_half = reinterpret_cast<const half *>(bias);
    half *output_half = reinterpret_cast<half *>(output);

    // limit head_size * head_num to max block size(1024).
    PADDLE_ENFORCE_LE(head_size * head_num,
                      1024,
                      phi::errors::InvalidArgument(
                          "head_num (%d) * head_size (%d) should <= %d",
                          head_num,
                          head_size,
                          1024));
    TransposeQkvKernel<half><<<grid, block, 0, stream>>>(
        head_size, input_half, bias_half, output_half);
  }
}
#endif

inline int round_up(int seq_len, int multiple = 32) {
  PADDLE_ENFORCE_GT(
      multiple,
      0,
      phi::errors::InvalidArgument(
          "multiple should be a positive number, but it's (%d)", multiple));
  return ((seq_len + multiple - 1) / multiple) * multiple;
}

template <typename T>
__global__ void broadcast(const T *src,
                          T *dst,
                          const int seq_len,
                          const int head_num) {
  int batch_id = blockIdx.x / (head_num * seq_len);
  int dst_offset = blockIdx.x * seq_len;
  if (threadIdx.x < seq_len) {
    dst[threadIdx.x + dst_offset] = src[threadIdx.x + batch_id * seq_len];
  }
}

template <typename T>
__global__ void broadcast_batch_head_number(const T *src,
                                            T *dst,
                                            const int batch_size,
                                            const int seq_len,
                                            const int head_num) {
  int src_seq_id = blockIdx.x % seq_len;
  int dst_offset = blockIdx.x * seq_len;
  if (threadIdx.x < seq_len) {
    dst[threadIdx.x + dst_offset] = src[threadIdx.x + src_seq_id * seq_len];
  }
}

template <typename T, typename Context>
void MultiheadMatmulKernel(const Context &dev_ctx,
                           const DenseTensor &input,
                           const DenseTensor &w,
                           const DenseTensor &bias,
                           const paddle::optional<DenseTensor> &bias_qk,
                           const bool transpose_q,
                           const bool transpose_k,
                           const bool transpose_v,
                           const float alpha,
                           const int head_number,
                           DenseTensor *out) {
  auto *input_d = input.data<T>();
  auto *w_d = w.data<T>();
  auto *bias_d = bias.data<T>();
  auto *bias_qk_d = bias_qk ? bias_qk->data<T>() : nullptr;
  T scale = static_cast<T>(alpha);

  // compute q*k with eltadd
  auto stream = dev_ctx.stream();
  // should be (B * S * hidden)
  auto input_dims = input.dims();
  // shouble be (hidden * 3 * all_head_size)
  auto w_dims = w.dims();
  int batch = input_dims[0];
  int seq_len = input_dims[1];
  int hidden = input_dims[2];
  phi::DenseTensor temp_bias_tensor;
  // if bias_qk is[batch, 1, 1, seq_len], the bias_qk_d need to be broadcasted
  if (bias_qk && bias_qk->numel() == (batch * seq_len)) {
    VLOG(4) << "Do broadcasted bias_qk from [batch, 1, 1, seq_len]";
    temp_bias_tensor.Resize({batch * head_number * seq_len * seq_len});
    auto *temp_qk_bias = dev_ctx.template Alloc<T>(
        &temp_bias_tensor, temp_bias_tensor.numel() * sizeof(T));
    int grid = batch * head_number * seq_len;
    int block = round_up(seq_len);
    broadcast<<<grid, block, 0, stream>>>(
        bias_qk_d, temp_qk_bias, seq_len, head_number);
    bias_qk_d = static_cast<const T *>(temp_qk_bias);
  }
  // if bias_qk is[1, 1, seq_len, seq_len], the bias_qk_d need to be
  // broadcasted
  if (bias_qk && bias_qk->numel() == (1 * seq_len * seq_len)) {
    VLOG(4) << "do broadcasted bias_qk from  [1, 1, seq_len, seq_len]";
    temp_bias_tensor.Resize({batch * head_number * seq_len * seq_len});
    auto *temp_qk_bias = dev_ctx.template Alloc<T>(
        &temp_bias_tensor, temp_bias_tensor.numel() * sizeof(T));
    int grid = batch * head_number * seq_len;
    int block = round_up(seq_len);
    broadcast_batch_head_number<<<grid, block, 0, stream>>>(
        bias_qk_d, temp_qk_bias, batch, seq_len, head_number);
    bias_qk_d = static_cast<const T *>(temp_qk_bias);
  }
  if (!bias_qk) {
    int size = batch * head_number * seq_len * seq_len;
    temp_bias_tensor.Resize({size});
    auto *temp_qk_bias = dev_ctx.template Alloc<T>(
        &temp_bias_tensor, temp_bias_tensor.numel() * sizeof(T));
#ifdef PADDLE_WITH_HIP
    hipMemset(temp_qk_bias, 0, sizeof(float) * size);
#else
    cudaMemset(temp_qk_bias, 0, sizeof(float) * size);
#endif
    bias_qk_d = static_cast<const T *>(temp_qk_bias);
  }
  int all_head_size = w_dims[2];
  int head_size = all_head_size / head_number;

  out->Resize({batch, seq_len, all_head_size});
  auto *output_d = dev_ctx.template Alloc<T>(out, out->numel() * sizeof(T));

  // (B*S, hidden)
  const phi::DenseTensor input_matrix =
      phi::ReshapeToMatrix(input, 2 /*x_num_col_dims */);
  // (hidden, 3 * all_head_size)
  const phi::DenseTensor w_matrix =
      phi::ReshapeToMatrix(w, 1 /*y_num_col_dims*/);

  phi::DenseTensor temp_out_tensor;
  auto temp_out_dims =
      phi::make_ddim({batch, seq_len, 3, head_number, head_size});
  temp_out_tensor.Resize(
      {batch * seq_len, phi::product(temp_out_dims) / (batch * seq_len)});
  auto *temp_out_data = dev_ctx.template Alloc<T>(
      &temp_out_tensor, temp_out_tensor.numel() * sizeof(T));

  // (B * S, hidden) * (hidden, 3 * N * H) -> (B * S * 3 * N * H)
  auto blas = phi::funcs::GetBlas<phi::GPUContext, T>(dev_ctx);
  blas.MatMul(input_matrix, w_matrix, &temp_out_tensor);
  VLOG(2) << "(B * S, hidden) * (hidden, 3 * N * H) -> (B * S * 3 * N * H)";
  // temp_out_tensor.Resize(temp_out_dims);

  phi::DenseTensor multihead_temp_tensor;
  // B * head_number * S * S * 1 + B * S * 3 * N * H
  int scratch_size = batch * head_number * seq_len * seq_len * 1;
  multihead_temp_tensor.Resize({scratch_size + temp_out_tensor.numel()});
  auto *multihead_temp_data = dev_ctx.template Alloc<T>(
      &multihead_temp_tensor, multihead_temp_tensor.numel() * sizeof(T));

  auto *qkptr = multihead_temp_data;
  auto *tptr = multihead_temp_data + scratch_size;

  // Do the transpose with bias.
  // BxSx3xNxH => tptr: 3xBxNxSxH.
  TransQKVWithBias(batch,
                   seq_len,
                   head_size,
                   head_number,
                   temp_out_data,
                   bias_d,
                   tptr,
                   stream);
  if (std::is_same<T, phi::dtype::float16>::value) {
    phi::funcs::MultiheadGPUComputeFunctor<half> multihead_compute_func;
    multihead_compute_func(dev_ctx,
                           batch,
                           seq_len,
                           head_number,
                           head_size,
                           reinterpret_cast<half *>(qkptr),
                           reinterpret_cast<const half *>(bias_qk_d),
                           false,
                           reinterpret_cast<half *>(tptr),
                           __float2half(static_cast<float>(scale)),
                           __float2half(0.0));
  } else {
    phi::funcs::MultiheadGPUComputeFunctor<T> multihead_compute_func;
    multihead_compute_func(dev_ctx,
                           batch,
                           seq_len,
                           head_number,
                           head_size,
                           qkptr,
                           bias_qk_d,
                           false,
                           tptr,
                           scale,
                           T(0.0));
  }

  int grid = batch * head_number * seq_len;
  int block = head_size;
  transpose<T><<<grid, block, 0, stream>>>(
      tptr, output_d, batch, seq_len, head_number, head_size);
}

}  // namespace fusion
}  // namespace phi

#if defined(PADDLE_WITH_CUDA) && CUDA_VERSION >= 10000
PD_REGISTER_KERNEL(multihead_matmul,
                   GPU,
                   ALL_LAYOUT,
                   phi::fusion::MultiheadMatmulKernel,
                   float,
                   phi::dtype::float16) {}
#else
PD_REGISTER_KERNEL(multihead_matmul,
                   GPU,
                   ALL_LAYOUT,
                   phi::fusion::MultiheadMatmulKernel,
                   float) {}
#endif
