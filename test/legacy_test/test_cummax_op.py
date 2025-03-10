#   Copyright (c) 2023 PaddlePaddle Authors. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import sys
import unittest

import numpy as np
from eager_op_test import OpTest

import paddle
from paddle import base
from paddle.base import core


def cummax_dim2(arr, axis=None):
    if axis is None:
        arr = arr.flatten()
        cummax = np.maximum.accumulate(arr)
        shape = arr.shape
        indices = np.zeros(shape).astype('int32')
        max_val = -sys.maxsize
        max_ind = 0
        for i in range(shape[0]):
            if arr[i] >= max_val:
                max_val = max(arr[i], max_val)
                max_ind = i
                indices[i] = i
            else:
                indices[i] = max_ind
    else:
        cummax = np.maximum.accumulate(arr, axis)
        shape = arr.shape
        indices = np.zeros(shape).astype('int32')
        if axis < 0:
            axis = axis + len(shape)
        if axis == 0:
            for j in range(shape[1]):
                max_ind = 0
                max_val = -sys.maxsize
                for i in range(shape[0]):
                    if arr[i][j] >= max_val:
                        max_val = arr[i][j]
                        max_ind = i
                        indices[i][j] = i
                    else:
                        indices[i][j] = max_ind
        elif axis == 1:
            for i in range(shape[0]):
                max_ind = 0
                max_val = -sys.maxsize
                for j in range(shape[1]):
                    if arr[i][j] >= max_val:
                        max_val = arr[i][j]
                        max_ind = j
                        indices[i][j] = j
                    else:
                        indices[i][j] = max_ind
        else:
            raise Exception("unfeasible axis")
    return cummax, indices


class TestCummaxOp(OpTest):
    def setUp(self):
        self.op_type = "cummax"
        self.python_api = paddle.cummax
        self.dtype = np.float64
        self.axis = -1
        self.indices_type = 3
        self.input_data = np.random.random((10, 10)).astype(self.dtype)
        self.set_attrs()

        self.inputs = {'x': self.input_data}
        self.attrs = {'axis': self.axis, 'dtype': self.indices_type}
        self.np_res, self.np_ind = cummax_dim2(self.input_data, axis=self.axis)
        self.outputs = {'out': self.np_res, 'indices': self.np_ind}

    def set_attrs(self):
        pass

    def test_check_output(self):
        paddle.enable_static()
        self.check_output()

    def test_check_grad(self):
        paddle.enable_static()
        self.check_grad(['x'], 'out')


class TestCummaxOpAxis1(TestCummaxOp):
    def set_attrs(self):
        self.axis = 0


class TestCummaxOpAxis2(TestCummaxOp):
    def set_attrs(self):
        self.axis = -2


class TestCummaxOpIndexType(TestCummaxOp):
    def set_attrs(self):
        self.indices_type = 2


class TestCummaxAPI(unittest.TestCase):
    def run_cases(self):
        data_np = np.random.random((100, 100)).astype(np.float32)
        data = paddle.to_tensor(data_np)

        y, indices = paddle.cummax(data)
        z, ind = cummax_dim2(data_np)
        np.testing.assert_array_equal(z, y.numpy())
        np.testing.assert_array_equal(ind, indices.numpy())

        y, indices = paddle.cummax(data, axis=0)
        z, ind = cummax_dim2(data_np, axis=0)
        np.testing.assert_array_equal(z, y.numpy())
        np.testing.assert_array_equal(ind, indices.numpy())

        y, indices = paddle.cummax(data, axis=-1)
        z, ind = cummax_dim2(data_np, axis=-1)
        np.testing.assert_array_equal(z, y.numpy())
        np.testing.assert_array_equal(ind, indices.numpy())

        y, indices = paddle.cummax(data, axis=-2)
        z, ind = cummax_dim2(data_np, axis=-2)
        np.testing.assert_array_equal(z, y.numpy())
        np.testing.assert_array_equal(ind, indices.numpy())

        y, indices = paddle.cummax(data, axis=-2, dtype='int32')
        z, ind = cummax_dim2(data_np, axis=-2)
        np.testing.assert_array_equal(z, y.numpy())
        np.testing.assert_array_equal(ind, indices.numpy())
        self.assertTrue(indices.dtype == core.VarDesc.VarType.INT32)

        data_np = np.random.randint(0, 10, size=(100, 100)).astype(np.int32)
        data = paddle.to_tensor(data_np)
        y, indices = paddle.cummax(data, axis=0)
        z, ind = cummax_dim2(data_np, axis=0)
        np.testing.assert_array_equal(z, y.numpy())
        np.testing.assert_array_equal(ind, indices.numpy())

    def run_static(self, use_gpu=False):
        with base.program_guard(base.Program()):
            data_np = np.random.random((100, 100)).astype(np.float32)
            x = paddle.static.data('x', [100, 100])
            y1, indices1 = paddle.cummax(x)
            y2, indices2 = paddle.cummax(x, axis=0)
            y3, indices3 = paddle.cummax(x, axis=-1)
            y4, indices4 = paddle.cummax(x, axis=-2)
            y5, indices5 = paddle.cummax(x, axis=-2, dtype=np.int32)

            place = base.CUDAPlace(0) if use_gpu else base.CPUPlace()
            exe = base.Executor(place)
            exe.run(base.default_startup_program())
            out = exe.run(
                feed={'x': data_np},
                fetch_list=[
                    y1.name,
                    indices1.name,
                    y2.name,
                    indices2.name,
                    y3.name,
                    indices3.name,
                    y4.name,
                    indices4.name,
                    y5.name,
                    indices5.name,
                ],
            )

            z, ind = cummax_dim2(data_np)
            np.testing.assert_allclose(z, out[0], rtol=1e-05)
            np.testing.assert_allclose(ind, out[1], rtol=1e-05)

            z, ind = cummax_dim2(data_np, axis=0)
            np.testing.assert_allclose(z, out[2], rtol=1e-05)
            np.testing.assert_allclose(ind, out[3], rtol=1e-05)

            z, ind = cummax_dim2(data_np, axis=-1)
            np.testing.assert_allclose(z, out[4], rtol=1e-05)
            np.testing.assert_allclose(ind, out[5], rtol=1e-05)

            z, ind = cummax_dim2(data_np, axis=-2)
            np.testing.assert_allclose(z, out[6], rtol=1e-05)
            np.testing.assert_allclose(ind, out[7], rtol=1e-05)

            z, ind = cummax_dim2(data_np, axis=-2)
            np.testing.assert_allclose(z, out[8], rtol=1e-05)
            np.testing.assert_allclose(ind, out[9], rtol=1e-05)

    def test_cpu(self):
        paddle.disable_static(paddle.base.CPUPlace())
        self.run_cases()
        paddle.enable_static()
        self.run_static()

    def test_gpu(self):
        if not base.core.is_compiled_with_cuda():
            return
        paddle.disable_static(paddle.base.CUDAPlace(0))
        self.run_cases()
        paddle.enable_static()
        self.run_static(use_gpu=True)

    def test_errors(self):
        paddle.enable_static()
        with base.program_guard(base.Program()):

            def test_x_type():
                data = [1, 2, 3]
                y, indices = paddle.cummax(data, axis=0)

            self.assertRaises(TypeError, test_x_type)
        paddle.disable_static()

        def test_indices_type():
            data_np = np.random.random((10, 10)).astype(np.float32)
            data = paddle.to_tensor(data_np)
            y, indices = paddle.cummax(data, dtype='float32')

        self.assertRaises(ValueError, test_indices_type)

        def test_axis_outrange():
            data_np = np.random.random(100).astype(np.float32)
            data = paddle.to_tensor(data_np)
            y, indices = paddle.cummax(data, axis=-2)

        self.assertRaises(IndexError, test_axis_outrange)


if __name__ == '__main__':
    unittest.main()
