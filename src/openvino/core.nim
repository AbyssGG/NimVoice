import c_api
import tensor, infer_request, model, compiled_model

# Re-export modules so that users of core only need to import openvino/core
export c_api.OvElementType
export c_api.OvStatus
export c_api.OvProfilingStatus
export c_api.OvProfilingInfo
# Re-export the perf_count wrapper entry points so callers (e.g. the TTS
# session) can re-enable `PERF_COUNT=YES` on a compiled model that was
# loaded from a cached `.blob` without having to import c_api themselves.
export c_api.nv_compile_model_with_perf_count
export c_api.nv_enable_perf_count
export model.Model
export compiled_model.CompiledModel
export tensor.Tensor
export infer_request.InferRequest
export infer_request.ProfilingInfo

type
  CoreObj* = object
    pCore*: ptr OvCore
  Core* = ref CoreObj

proc `=destroy`*(core: var CoreObj) =
  if core.pCore != nil:
    ov_core_free(core.pCore)
    core.pCore = nil

proc newCore*(): Core =
  var pCore: ptr OvCore
  let status = ov_core_create(addr pCore)
  if status != OK:
    raise newException(Exception, "Failed to create OpenVINO core: " & $status)
  new(result)
  result.pCore = pCore

proc getAvailableDevices*(core: Core): seq[string] =
  var devices: OvAvailableDevices
  let status = ov_core_get_available_devices(core.pCore, addr devices)
  if status != OK:
    raise newException(Exception, "Failed to get available devices: " & $status)

  result = newSeq[string]()
  for i in 0 ..< devices.size:
    result.add($devices.devices[i])

  ov_available_devices_free(addr devices)

proc readModel*(core: Core, modelPath: string, binPath: string = ""): Model =
  var pModel: ptr OvModel
  let bp: cstring = if binPath.len > 0: binPath.cstring else: nil
  let status = ov_core_read_model(core.pCore, modelPath.cstring, bp, addr pModel)
  if status != OK:
    raise newException(Exception, "Failed to read model: " & $status)
  new(result)
  result.pModel = pModel

proc compileModel*(core: Core, model: Model, deviceName: string): CompiledModel =
  var pCompiledModel: ptr OvCompiledModel
  let status = ov_core_compile_model(core.pCore, model.pModel, deviceName.cstring, 0, addr pCompiledModel)
  if status != OK:
    raise newException(Exception, "Failed to compile model for device " & deviceName & ": " & $status)
  new(result)
  result.pCompiledModel = pCompiledModel

proc compileModelWithProfiling*(
  core: Core,
  model: Model,
  deviceName: string
): CompiledModel =
  ## Compile a model with per-layer profiling counters enabled. After
  ## inference, callers may use `infer_request.getProfilingInfo` to read
  ## `real_time` / `cpu_time` for every node that ran on the device.
  ##
  ## Implementation note: the underlying `ov_core_compile_model` is a C
  ## variadic function, which is fragile to call from Nim's FFI on x64
  ## Windows. We go through the `nv_compile_model_with_perf_count` C
  ## wrapper (compiled into the executable itself) which passes the
  ## `PERF_COUNT=YES` pair on the caller's behalf.
  var pCompiledModel: ptr OvCompiledModel
  let status = nv_compile_model_with_perf_count(
    core.pCore,
    model.pModel,
    deviceName.cstring,
    addr pCompiledModel
  )
  if status != OK:
    let errMsg = $ov_get_last_err_msg()
    let detail = if errMsg.len > 0: " (" & errMsg & ")" else: ""
    raise newException(Exception, "Failed to compile model for device " & deviceName & " (with profiling): status=" & $ord(status) & detail)
  new(result)
  result.pCompiledModel = pCompiledModel

proc importModel*(
  core: Core,
  path: string,
  deviceName: string
): CompiledModel =
  ## Load a previously compiled model (a `.blob` produced by
  ## `ov_compiled_model_export_model` or by `CompiledModel.exportModelToFile`)
  ## on the given device, bypassing the full compile pipeline. This is the
  ## hot path for the NPU vocoder when the model is already cached on disk.
  let blob = readFile(path)
  var pCompiledModel: ptr OvCompiledModel
  let status = ov_core_import_model(
    core.pCore,
    if blob.len > 0: unsafeAddr blob[0] else: nil,
    blob.len.csize_t,
    deviceName.cstring,
    addr pCompiledModel
  )
  if status != OK:
    let errMsg = $ov_get_last_err_msg()
    let detail = if errMsg.len > 0: " (" & errMsg & ")" else: ""
    raise newException(Exception, "Failed to import compiled model for device " & deviceName & ": status=" & $ord(status) & detail)
  new(result)
  result.pCompiledModel = pCompiledModel
