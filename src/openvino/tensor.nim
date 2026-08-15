import c_api

type
  TensorObj* = object
    pTensor*: ptr OvTensor
  Tensor* = ref TensorObj

proc `=destroy`*(t: var TensorObj) =
  if t.pTensor != nil:
    ov_tensor_free(t.pTensor)
    t.pTensor = nil

proc newTensor*(typ: OvElementType, dims: seq[int64], data: pointer): Tensor =
  var shapeDims = dims
  var shape = OvShape(rank: dims.len.int64, dims: addr shapeDims[0])
  var pTensor: ptr OvTensor
  let status = ov_tensor_create_from_host_ptr(typ, shape, data, addr pTensor)
  if status != OK:
    raise newException(Exception, "Failed to create tensor from host ptr, status: " & $status)
  new(result)
  result.pTensor = pTensor

proc getData*[T](t: Tensor, typedesc: typedesc[T]): ptr UncheckedArray[T] =
  var p: pointer
  let status = ov_tensor_data(t.pTensor, addr p)
  if status != OK:
    raise newException(Exception, "Failed to get tensor data, status: " & $status)
  result = cast[ptr UncheckedArray[T]](p)

proc setShape*(t: Tensor, dims: seq[int64]) =
  ## Reshape an existing tensor that was created from a host pointer. The new
  ## shape's total element count MUST NOT exceed the buffer's capacity. The
  ## underlying host buffer is reused; only the logical view of the shape
  ## changes. This lets callers reuse a single tensor across iterations of a
  ## variable-length loop (e.g. the autoregressive decoder), saving one
  ## `ov_tensor_create_from_host_ptr` call per step.
  var shapeDims = dims
  var shape = OvShape(rank: dims.len.int64, dims: addr shapeDims[0])
  let status = ov_tensor_set_shape(t.pTensor, addr shape)
  if status != OK:
    raise newException(Exception, "Failed to set tensor shape, status: " & $status)

proc getSize*(t: Tensor): int =
  var shape: OvShape
  let status = ov_tensor_get_shape(t.pTensor, addr shape)
  if status != OK:
    raise newException(Exception, "Failed to get tensor shape, status: " & $status)
  
  result = 1
  for i in 0 ..< shape.rank:
    let dimPtr = cast[ptr int64](cast[uint](shape.dims) + uint(i * sizeof(int64)))
    result *= int(dimPtr[])
    
  discard ov_shape_free(addr shape)
