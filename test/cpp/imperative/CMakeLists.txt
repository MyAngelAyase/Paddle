if(WIN32)
  cc_test(
    nccl_context_test
    SRCS nccl_context_test.cc
    DEPS device_context)
else()
  if(WITH_GLOO AND (WITH_NCCL OR WITH_RCCL))
    cc_test(
      nccl_context_test
      SRCS nccl_context_test.cc
      DEPS nccl_context)
    cc_test(
      heter_ccl_context_test
      SRCS heter_ccl_context_test.cc
      DEPS heter_ccl_context
           nccl_context
           imperative_gloo_context
           gloo_context
           gloo_wrapper
           gloo
           fs
           shell)
    #set_tests_properties(heter_ccl_context_test PROPERTIES LABELS "RUN_TYPE=DIST")
  endif()
  if(WITH_XPU_BKCL)
    cc_test(
      bkcl_context_test
      SRCS bkcl_context_test.cc
      DEPS bkcl_context)
  endif()
endif()

cc_test(
  test_gradient_accmulator
  SRCS test_gradient_accmulator.cc
  DEPS memcpy selected_rows_utils gradient_accumulator phi phi_utils)
cc_test(
  test_layer
  SRCS test_layer.cc
  DEPS layer
       proto_desc
       operator
       op_registry
       variable_helper
       mul_op
       memcpy)
cc_test(
  test_prepare_op
  SRCS test_prepare_op.cc
  DEPS prepared_operator
       op_info
       split_op
       layer
       concat_and_split
       activation_op
       place)
cc_test(
  test_tracer
  SRCS test_tracer.cc
  DEPS tracer
       layer
       proto_desc
       operator
       op_registry
       variable_helper
       mul_op
       generated_static_op
       elementwise_add_op
       memcpy)
cc_test(
  test_hooks
  SRCS test_hooks.cc
  DEPS tracer
       basic_engine
       layer
       proto_desc
       operator
       op_registry
       variable_helper
       mul_op
       elementwise_add_op
       memcpy)
cc_test(
  test_eager
  SRCS test_eager.cc
  DEPS tracer layer prepared_operator mul_op)
if(WITH_NCCL
   OR WITH_RCCL
   OR WITH_XPU_BKCL)
  cc_test(
    test_group
    SRCS test_group.cc
    DEPS reducer concat_and_split memcpy)
endif()
