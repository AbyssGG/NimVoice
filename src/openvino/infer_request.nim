import c_api
import tensor

type
  InferRequestObj* = object
    pReq*: ptr OvInferRequest
  InferRequest* = ref InferRequestObj

  ProfilingInfo* = object
    status*: int          # 0=NOT_RUN, 1=OPTIMIZED_OUT, 2=EXECUTED
    realTimeUs*: int64    # device wall time spent in this node (microseconds)
    cpuTimeUs*: int64     # host CPU time spent in this node (microseconds)
    nodeName*: string
    execType*: string
    nodeType*: string

proc `=destroy`*(req: var InferRequestObj) =
  if req.pReq != nil:
    ov_infer_request_free(req.pReq)
    req.pReq = nil

proc setInputTensor*(req: InferRequest, idx: int, t: Tensor) =
  let status = ov_infer_request_set_input_tensor_by_index(req.pReq, idx.csize_t, t.pTensor)
  if status != OK:
    raise newException(Exception, "Failed to set input tensor by index: " & $status)

proc getOutputTensor*(req: InferRequest, idx: int): Tensor =
  var pTensor: ptr OvTensor
  let status = ov_infer_request_get_output_tensor_by_index(req.pReq, idx.csize_t, addr pTensor)
  if status != OK:
    raise newException(Exception, "Failed to get output tensor by index: " & $status)
  new(result)
  result.pTensor = pTensor

proc infer*(req: InferRequest) =
  let status = ov_infer_request_infer(req.pReq)
  if status != OK:
    raise newException(Exception, "Failed to infer: " & $status)

proc getProfilingInfo*(req: InferRequest): seq[ProfilingInfo] =
  ## Collect per-layer profiling counters from the most recent infer() call.
  ## Returns an empty seq if profiling was not enabled at compile time or the
  ## device plugin does not populate counters. The caller MUST NOT interpret
  ## an empty list as zero usage; the device may have simply not reported.
  var infoList: OvProfilingInfoList
  let status = ov_infer_request_get_profiling_info(req.pReq, addr infoList)
  if status != OK:
    raise newException(Exception, "Failed to get profiling info: " & $status)
  try:
    result = newSeq[ProfilingInfo](int(infoList.size))
    for i in 0 ..< int(infoList.size):
      let p = addr infoList.profilingInfos[i]
      result[i] = ProfilingInfo(
        status: int(p.status),
        realTimeUs: p.realTime,
        cpuTimeUs: p.cpuTime,
        nodeName: if p.nodeName != nil: $p.nodeName else: "",
        execType: if p.execType != nil: $p.execType else: "",
        nodeType: if p.nodeType != nil: $p.nodeType else: ""
      )
  finally:
    if infoList.size > 0:
      ov_profiling_info_list_free(addr infoList)
