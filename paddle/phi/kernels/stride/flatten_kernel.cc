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
#include "paddle/phi/kernels/flatten_kernel.h"
#include "paddle/phi/backends/all_context.h"
#include "paddle/phi/core/kernel_registry.h"
#include "paddle/phi/kernels/reshape_kernel.h"

namespace phi {

template <typename Context>
void FlattenInferStridedKernel(const Context& dev_ctx,
                               const DenseTensor& x,
                               int start_axis UNUSED,
                               int stop_axis UNUSED,
                               DenseTensor* out) {
  ReshapeStridedKernel<Context>(
      dev_ctx, x, IntArray(phi::vectorize<int64_t>(out->dims())), out, nullptr);
}

template <typename Context>
void FlattenStridedKernel(const Context& dev_ctx,
                          const DenseTensor& x,
                          int start_axis,
                          int stop_axis,
                          DenseTensor* out,
                          DenseTensor* xshape UNUSED) {
  FlattenInferStridedKernel<Context>(dev_ctx, x, start_axis, stop_axis, out);
}

}  // namespace phi
PD_REGISTER_KERNEL_FOR_ALL_BACKEND_DTYPE_EXCEPT_CUSTOM(
    flatten_infer, STRIDED, phi::FlattenInferStridedKernel) {}

PD_REGISTER_KERNEL_FOR_ALL_BACKEND_DTYPE_EXCEPT_CUSTOM(
    flatten, STRIDED, phi::FlattenStridedKernel) {}
