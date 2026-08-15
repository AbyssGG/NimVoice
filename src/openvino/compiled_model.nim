import c_api
import infer_request

type
  CompiledModelObj* = object
    pCompiledModel*: ptr OvCompiledModel
  CompiledModel* = ref CompiledModelObj

proc `=destroy`*(m: var CompiledModelObj) =
  if m.pCompiledModel != nil:
    ov_compiled_model_free(m.pCompiledModel)
    m.pCompiledModel = nil

proc createInferRequest*(m: CompiledModel): InferRequest =
  var pReq: ptr OvInferRequest
  let status = ov_compiled_model_create_infer_request(m.pCompiledModel, addr pReq)
  if status != OK:
    raise newException(Exception, "Failed to create infer request: " & $status)
  new(result)
  result.pReq = pReq

proc exportModelToFile*(m: CompiledModel, path: string) =
  ## Serialize a compiled model directly to a file. The resulting `.blob`
  ## can be reloaded with `core.importModel` to skip the slow
  ## device-specific compile pipeline (on NPU, ~13 s for HiFi-GAN).
  let status = ov_compiled_model_export_model(m.pCompiledModel, path.cstring)
  if status != OK:
    raise newException(Exception, "Failed to export compiled model to " & path & ", status: " & $status)
