#   Copyright (c) 2018 PaddlePaddle Authors. All Rights Reserved.
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

import unittest

import numpy as np
from eager_op_test import OpTest

import paddle
import paddle.nn.functional as F
from paddle.base import core

paddle.enable_static()
np.random.seed(1)


def maxout_forward_naive(x, groups, channel_axis):
    s0, s1, s2, s3 = x.shape
    if channel_axis == 1:
        return np.ndarray(
            [s0, s1 // groups, groups, s2, s3], buffer=x, dtype=x.dtype
        ).max(axis=2)
    return np.ndarray(
        [s0, s1, s2, s3 // groups, groups], buffer=x, dtype=x.dtype
    ).max(axis=4)


class TestMaxOutOp(OpTest):
    def setUp(self):
        self.op_type = "maxout"
        self.python_api = paddle.nn.functional.maxout
        self.dtype = 'float64'
        self.shape = [3, 6, 2, 4]
        self.groups = 2
        self.axis = 1
        self.set_attrs()

        x = np.random.uniform(-1, 1, self.shape).astype(self.dtype)
        out = maxout_forward_naive(x, self.groups, self.axis)

        self.inputs = {'X': x}
        self.attrs = {'groups': self.groups, 'axis': self.axis}
        self.outputs = {'Out': out}

    def set_attrs(self):
        pass

    def test_check_output(self):
        self.check_output()

    def test_check_grad(self):
        self.check_grad(['X'], 'Out')


class TestMaxOutOpAxis0(TestMaxOutOp):
    def set_attrs(self):
        self.axis = -1


class TestMaxOutOpAxis1(TestMaxOutOp):
    def set_attrs(self):
        self.axis = 3


class TestMaxOutOpFP32(TestMaxOutOp):
    def set_attrs(self):
        self.dtype = 'float32'


class TestMaxOutOpGroups(TestMaxOutOp):
    def set_attrs(self):
        self.groups = 3


class TestMaxoutAPI(unittest.TestCase):
    # test paddle.nn.Maxout, paddle.nn.functional.maxout
    def setUp(self):
        self.x_np = np.random.uniform(-1, 1, [2, 6, 5, 4]).astype(np.float64)
        self.groups = 2
        self.axis = 1
        self.place = (
            paddle.CUDAPlace(0)
            if core.is_compiled_with_cuda()
            else paddle.CPUPlace()
        )

    def test_static_api(self):
        with paddle.static.program_guard(paddle.static.Program()):
            x = paddle.static.data('X', self.x_np.shape, self.x_np.dtype)
            out1 = F.maxout(x, self.groups, self.axis)
            m = paddle.nn.Maxout(self.groups, self.axis)
            out2 = m(x)
            exe = paddle.static.Executor(self.place)
            res = exe.run(feed={'X': self.x_np}, fetch_list=[out1, out2])
        out_ref = maxout_forward_naive(self.x_np, self.groups, self.axis)
        for r in res:
            np.testing.assert_allclose(out_ref, r, rtol=1e-05)

    def test_dygraph_api(self):
        paddle.disable_static(self.place)
        x = paddle.to_tensor(self.x_np)
        out1 = F.maxout(x, self.groups, self.axis)
        m = paddle.nn.Maxout(self.groups, self.axis)
        out2 = m(x)
        out_ref = maxout_forward_naive(self.x_np, self.groups, self.axis)
        for r in [out1, out2]:
            np.testing.assert_allclose(out_ref, r.numpy(), rtol=1e-05)

        out3 = F.maxout(x, self.groups, -1)
        out3_ref = maxout_forward_naive(self.x_np, self.groups, -1)
        np.testing.assert_allclose(out3_ref, out3.numpy(), rtol=1e-05)
        paddle.enable_static()

    def test_errors(self):
        with paddle.static.program_guard(paddle.static.Program()):
            # The input type must be Variable.
            self.assertRaises(TypeError, F.maxout, 1)
            # The input dtype must be float16, float32, float64.
            x_int32 = paddle.static.data(
                name='x_int32', shape=[2, 4, 6, 8], dtype='int32'
            )
            self.assertRaises(TypeError, F.maxout, x_int32)

            x_float32 = paddle.static.data(name='x_float32', shape=[2, 4, 6, 8])
            self.assertRaises(ValueError, F.maxout, x_float32, 2, 2)


class TestMaxOutOpFP16(TestMaxOutOp):
    def set_attrs(self):
        self.dtype = 'float16'


class TestMaxoutFP16Case1(TestMaxOutOpFP16):
    def set_attrs(self):
        self.axis = -1


class TestMaxoutFP16Case2(TestMaxOutOpFP16):
    def set_attrs(self):
        self.axis = 3


@unittest.skipIf(
    not core.is_compiled_with_cuda(), "core is not compiled with CUDA"
)
class TestMaxoutStaticAPIFP16(unittest.TestCase):
    def setUp(self):
        self.x_np = np.random.uniform(-1, 1, [2, 6, 5, 4]).astype(np.float16)
        self.groups = 2
        self.axis = 1
        self.place = paddle.CUDAPlace(0)

    def test_static_api(self):
        with paddle.static.program_guard(paddle.static.Program()):
            x = paddle.static.data('X', self.x_np.shape, self.x_np.dtype)
            out = F.maxout(x, self.groups, self.axis)
            exe = paddle.static.Executor(self.place)
            res = exe.run(feed={'X': self.x_np}, fetch_list=[out])
        out_ref = maxout_forward_naive(self.x_np, self.groups, self.axis)
        np.testing.assert_allclose(out_ref, res[0], rtol=1e-05)


if __name__ == '__main__':
    unittest.main()
