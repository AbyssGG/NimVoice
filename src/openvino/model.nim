import c_api

type
  ModelObj* = object
    pModel*: ptr OvModel
  Model* = ref ModelObj

proc `=destroy`*(m: var ModelObj) =
  if m.pModel != nil:
    ov_model_free(m.pModel)
    m.pModel = nil
