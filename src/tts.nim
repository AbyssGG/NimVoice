import openvino/core
import openvino/compiled_model
import openvino/infer_request
import openvino/tensor
import audio
import text
import std/algorithm
import std/math
import std/os
import std/strutils
import std/tables
import std/times

{.emit: """
#include <xmmintrin.h>
#include <pmmintrin.h>
""".}

proc getMXCSR(): cuint {.importc: "_mm_getcsr", header: "<xmmintrin.h>".}
proc setMXCSR(i: cuint) {.importc: "_mm_setcsr", header: "<xmmintrin.h>".}

proc disableDenormalsAreZero() =
  var csr = getMXCSR()
  csr = csr and not (0x8040'u32) # Clear FTZ (15) and DAZ (6)
  setMXCSR(csr)

const
  SampleRate* = 16000
  MelBins = 80
  DecoderHiddenSize = 768
  SpeakerEmbeddingSize = 512
  VocoderChunkFrames* = 128
  SamplesPerFrame = 256
  DefaultMaxDecoderSteps* = 200
  MaxAdaptiveDecoderSteps = 512
  # Where to keep device-specific compiled-model blobs (`.blob` cache). On NPU
  # the compile pipeline takes ~13 s; importing a previously serialized blob
  # takes <100 ms. The directory is created on demand.
  VocoderBlobCacheDir* = "../models/.cache/compiled"

type
  LanguageAssets = object
    langTag: string
    modelDir: string
    vocabPath: string
    speakerEmbeddingPath: string
    feedbackFrameOffset: int
    minStopStepExclusive: int
    usePostnet: bool

  DeviceAttempt* = object
    requestedBase*: string
    actualDevice*: string
    success*: bool
    message*: string

  CompileReport* = object
    requestedDevice*: string
    actualDevice*: string
    attempts*: seq[DeviceAttempt]

  SessionInitMetrics* = object
    modelLoadMs*: float
    modelCompileMs*: float

  RuntimeSnapshot = object
    cpuSeconds: float
    workingSetBytes: float
    peakWorkingSetBytes: float

  VocoderProfiling* = object
    ## Aggregated NPU per-layer profiling counters collected across all vocoder
    ## chunks of a single synthesis. Times are in microseconds.
    enabled*: bool                 # whether compileModelWithProfiling succeeded
    layerCount*: int               # count of EXECUTED nodes reported
    totalRealTimeUs*: int64        # sum of real_time across EXECUTED nodes
    totalCpuTimeUs*: int64         # sum of cpu_time across EXECUTED nodes
    wallClockUs*: int64            # total wall-clock time spent in vocoder.infer()
    hotLayers*: seq[HotLayer]
    collectedFromNpu*: bool        # whether any layer had a non-CPU exec_type

  HotLayer* = object
    nodeName*: string
    nodeType*: string
    realTimeUs*: int64

  SynthesisMetrics* = object
    encoderMs*: float
    autoregressiveMs*: float
    postnetMs*: float
    vocoderMs*: float
    totalMs*: float
    audioDurationSec*: float
    rtf*: float
    avgCpuUsagePercent*: float
    workingSetMB*: float
    peakMemoryMB*: float
    frameCount*: int
    sampleCount*: int
    stopStep*: int
    vocoderProfiling*: VocoderProfiling

  BenchmarkEntry* = object
    requestedDevice*: string
    actualDevice*: string
    status*: string
    errorMessage*: string
    modelLoadMs*: float
    modelCompileMs*: float
    firstInferenceLatencyMs*: float
    averageInferenceLatencyMs*: float
    audioGenerationTimeMs*: float
    audioDurationSec*: float
    rtf*: float
    avgCpuUsagePercent*: float
    workingSetMB*: float
    peakMemoryMB*: float
    npuUsageNote*: string
    npuLayerCount*: int
    npuTotalRealTimeUs*: int64
    npuTotalCpuTimeUs*: int64
    npuWallClockUs*: int64
    npuUsagePercent*: float
    npuProfilingAvailable*: bool
    npuHotLayers*: seq[HotLayer]
    # Per-phase breakdown of the first inference run, in milliseconds. These
    # are the headline numbers for Phase 13's "where is the time really going"
    # diagnostic. CPU frontend (encoder + autoregressive + postnet) usually
    # dominates over the NPU vocoder on the current machine.
    encoderMs*: float
    autoregressiveMs*: float
    postnetMs*: float
    vocoderMs*: float
    vocoderBlobCacheHit*: bool  # whether the vocoder was loaded from a cached .blob

  TtsSession* = ref object
    ovCore*: Core
    vocab*: Table[string, int64]
    speakerEmbeddingData*: seq[float32]
    speakerEmbeddingTensor*: Tensor
    feedbackFrameOffset*: int
    minStopStepExclusive*: int
    usePostnet*: bool
    encoderModel*: CompiledModel
    prenetModel*: CompiledModel
    decoderModel*: CompiledModel
    featModel*: CompiledModel
    postnetModel*: CompiledModel
    vocoderModel*: CompiledModel
    vocoderCompile*: CompileReport
    maxDecoderSteps*: int
    vocoderProfilingEnabled*: bool  # whether enable_profiling was passed at compile time

when defined(windows):
  type
    ProcessMemoryCounters = object
      cb: uint32
      PageFaultCount: uint32
      PeakWorkingSetSize: csize_t
      WorkingSetSize: csize_t
      QuotaPeakPagedPoolUsage: csize_t
      QuotaPagedPoolUsage: csize_t
      QuotaPeakNonPagedPoolUsage: csize_t
      QuotaNonPagedPoolUsage: csize_t
      PagefileUsage: csize_t
      PeakPagefileUsage: csize_t

  proc GetCurrentProcess(): pointer {.stdcall, dynlib: "kernel32", importc.}
  proc GetProcessMemoryInfo(
    process: pointer,
    counters: ptr ProcessMemoryCounters,
    cb: uint32
  ): int32 {.stdcall, dynlib: "psapi", importc.}

proc elapsedMs(startTime: float): float =
  (epochTime() - startTime) * 1000.0

proc getProcessorCount(): int =
  try:
    result = max(1, parseInt(getEnv("NUMBER_OF_PROCESSORS", "1")))
  except ValueError:
    result = 1

proc captureRuntimeSnapshot(): RuntimeSnapshot =
  result.cpuSeconds = cpuTime()
  when defined(windows):
    var counters = ProcessMemoryCounters(cb: uint32(sizeof(ProcessMemoryCounters)))
    if GetProcessMemoryInfo(GetCurrentProcess(), addr counters, counters.cb) != 0:
      result.workingSetBytes = float(counters.WorkingSetSize)
      result.peakWorkingSetBytes = float(counters.PeakWorkingSetSize)

proc applyRuntimeMetrics(metrics: var SynthesisMetrics, startSnapshot, endSnapshot: RuntimeSnapshot) =
  let elapsedSeconds = metrics.totalMs / 1000.0
  if elapsedSeconds > 0.0:
    let cpuDelta = max(0.0, endSnapshot.cpuSeconds - startSnapshot.cpuSeconds)
    metrics.avgCpuUsagePercent = (cpuDelta / elapsedSeconds) * 100.0 / float(getProcessorCount())
  metrics.workingSetMB = endSnapshot.workingSetBytes / (1024.0 * 1024.0)
  metrics.peakMemoryMB = endSnapshot.peakWorkingSetBytes / (1024.0 * 1024.0)

proc mergeProfilingLayer(
  profiling: var VocoderProfiling,
  layer: ProfilingInfo
) =
  ## Update aggregated counters with one layer's profiling entry. Layers that
  ## were optimized out or not run contribute zero. exec_type hints whether
  ## the device plugin actually executed on the NPU; we use it to mark
  ## "profiling came from NPU" vs plain CPU.
  if layer.status != 2:  # 2 == EXECUTED
    return
  profiling.layerCount.inc
  profiling.totalRealTimeUs += layer.realTimeUs
  profiling.totalCpuTimeUs += layer.cpuTimeUs
  if layer.execType.len > 0 and layer.execType != "CPU":
    profiling.collectedFromNpu = true
  # Record the layer for later top-N selection.
  profiling.hotLayers.add(HotLayer(
    nodeName: layer.nodeName,
    nodeType: layer.nodeType,
    realTimeUs: layer.realTimeUs
  ))

proc hotLayerCmpDesc(a, b: HotLayer): int {.noSideEffect.} =
  ## Sort comparator: descending by realTimeUs.
  cmp(b.realTimeUs, a.realTimeUs)

proc finalizeHotLayers(profiling: var VocoderProfiling, topN: int = 5) =
  ## Sort the collected layers by real_time and keep only the top N.
  profiling.hotLayers.sort(hotLayerCmpDesc)
  if profiling.hotLayers.len > topN:
    profiling.hotLayers.setLen(topN)

proc computeNpuUsagePercent*(profiling: VocoderProfiling): float =
  ## NPU usage % = sum(real_time of executed nodes) / wall_clock * 100.
  ## Returns 0.0 if there is no wall clock or no executed layers.
  if profiling.wallClockUs <= 0 or profiling.layerCount == 0:
    return 0.0
  let pct = (profiling.totalRealTimeUs.float / profiling.wallClockUs.float) * 100.0
  # Clamp to [0, 100]: real_time may exceed wall_clock on some plugins that
  # double-count or that report parallel kernel time instead of serial time.
  return min(100.0, max(0.0, pct))

proc actualDeviceName(availableDevices: seq[string], deviceBase: string): string =
  for device in availableDevices:
    if device.startsWith(deviceBase):
      return device

proc normalizeSupportedLanguage(lang: string): string =
  let normalized = lang.strip().toLowerAscii()
  if normalized.len == 0 or normalized == "en" or normalized == "en-us":
    return "en"
  if normalized == "zh" or normalized == "zh-cn":
    raise newException(
      ValueError,
      "Chinese synthesis is temporarily disabled in the open-source build. Use `--lang=en` for now."
    )
  raise newException(
    ValueError,
    "Unsupported language `" & lang & "`. The current open-source build only supports English (`--lang=en`)."
  )

proc resolveLanguageAssets(lang: string): LanguageAssets =
  discard normalizeSupportedLanguage(lang)
  LanguageAssets(
    langTag: "en",
    modelDir: "../models/speecht5_en_legacy",
    vocabPath: "../speecht5_vocab.json",
    # Keep English on the original known-good asset path that the project
    # used before Chinese support landed.
    speakerEmbeddingPath: "../models/speaker_embedding.raw",
    # The legacy English-only export expects the second frame from the
    # reduction-factor=2 output as decoder feedback.
    feedbackFrameOffset: MelBins,
    minStopStepExclusive: 12,
    usePostnet: true
  )

proc targetDevices(requestedDevice: string, allowFallback: bool): seq[string] =
  let priority = @["NPU", "GPU", "CPU"]
  if not allowFallback:
    return @[requestedDevice]
  if requestedDevice == "AUTO":
    return priority

  result = @[requestedDevice]
  for device in priority:
    if device != requestedDevice:
      result.add(device)

proc compileModelWithPolicy*(
  ovCore: Core,
  model: Model,
  requestedDevice: string,
  allowFallback: bool,
  enableProfiling: bool = false,
  blobCachePath: string = ""
): tuple[compiledModel: CompiledModel, report: CompileReport, cacheHit: bool] =
  result.report.requestedDevice = requestedDevice
  let availableDevices = ovCore.getAvailableDevices()

  for deviceBase in targetDevices(requestedDevice, allowFallback):
    let actualDevice = actualDeviceName(availableDevices, deviceBase)
    if actualDevice.len == 0:
      result.report.attempts.add(DeviceAttempt(
        requestedBase: deviceBase,
        actualDevice: "",
        success: false,
        message: "Device not available"
      ))
      continue

    # Try loading a cached compiled-model blob first when a cache path is
    # configured. This is the NPU fast path: skipping the 13 s device-specific
    # compile cuts cold-start time by an order of magnitude.
    if blobCachePath.len > 0 and fileExists(blobCachePath):
      try:
        result.compiledModel = ovCore.importModel(blobCachePath, actualDevice)
        # `ov_core_import_model` reads the blob but does NOT re-apply the
        # `PERF_COUNT` property that may have been active at export time.
        # If the caller asked for profiling we have to opt back in via
        # `set_property` (the variadic entry point goes through our C
        # wrapper because of the same ABI issue as `compile_model`).
        if enableProfiling:
          let enableStatus = nv_enable_perf_count(result.compiledModel.pCompiledModel)
          if enableStatus != OK:
            echo "[WARN] PERF_COUNT could not be re-enabled on the imported model (status=", $ord(enableStatus), "). Bench will fall back to no profiling."
        result.report.actualDevice = actualDevice
        result.report.attempts.add(DeviceAttempt(
          requestedBase: deviceBase,
          actualDevice: actualDevice,
          success: true,
          message: "Loaded from compiled-model cache (" & blobCachePath & ")"
        ))
        result.cacheHit = true
        return result
      except CatchableError as e:
        result.report.attempts.add(DeviceAttempt(
          requestedBase: deviceBase,
          actualDevice: actualDevice,
          success: false,
          message: "Blob cache import failed (will fall back to compile): " & e.msg
        ))
        # Stale or incompatible blob - fall through to compile and overwrite.

    # Try the profiling-enabled compile first when requested. Fall back to the
    # plain compile so a single device's quirk (e.g. NPU rejecting the
    # PERF_COUNT hint on a given driver) does not break the whole benchmark.
    if enableProfiling:
      try:
        result.compiledModel = ovCore.compileModelWithProfiling(model, actualDevice)
        result.report.actualDevice = actualDevice
        result.report.attempts.add(DeviceAttempt(
          requestedBase: deviceBase,
          actualDevice: actualDevice,
          success: true,
          message: "Compiled with profiling (PERF_COUNT=YES)"
        ))
        if blobCachePath.len > 0:
          try:
            result.compiledModel.exportModelToFile(blobCachePath)
          except CatchableError as e:
            echo "[WARN] Failed to persist compiled-model cache: ", e.msg
        return result
      except CatchableError as e:
        result.report.attempts.add(DeviceAttempt(
          requestedBase: deviceBase,
          actualDevice: actualDevice,
          success: false,
          message: "Profiling compile failed: " & e.msg & " (will fall back to plain compile)"
        ))
        # Fall through to plain compile below.

    try:
      result.compiledModel = ovCore.compileModel(model, actualDevice)
      result.report.actualDevice = actualDevice
      result.report.attempts.add(DeviceAttempt(
        requestedBase: deviceBase,
        actualDevice: actualDevice,
        success: true,
        message: if enableProfiling: "Compiled without profiling (fallback)" else: "Compiled successfully"
      ))
      if blobCachePath.len > 0:
        try:
          result.compiledModel.exportModelToFile(blobCachePath)
        except CatchableError as e:
          echo "[WARN] Failed to persist compiled-model cache: ", e.msg
      return result
    except Exception as e:
      result.report.attempts.add(DeviceAttempt(
        requestedBase: deviceBase,
        actualDevice: actualDevice,
        success: false,
        message: e.msg
      ))

  var messages = newSeq[string]()
  for attempt in result.report.attempts:
    let actual = if attempt.actualDevice.len > 0: attempt.actualDevice else: "N/A"
    messages.add(attempt.requestedBase & " -> " & actual & ": " & attempt.message)
  raise newException(Exception, "Failed to compile model for " & requestedDevice & ". " & messages.join(" | "))

proc preflightCheck*(lang: string) =
  ## Verify that every resource the runtime needs is present on disk BEFORE
  ## we touch OpenVINO. Without this check a missing model file would surface
  ## as a low-level `ov_core_read_model` status code deep in init, which is
  ## very hard to diagnose. We instead fail fast with a clear, actionable
  ## message.
  let assets = resolveLanguageAssets(lang)
  
  let required = @[
    assets.vocabPath,
    assets.speakerEmbeddingPath,
    assets.modelDir & "/speecht5_encoder.onnx",
    assets.modelDir & "/speecht5_prenet.onnx",
    assets.modelDir & "/speecht5_decoder.onnx",
    assets.modelDir & "/speecht5_feat_out.onnx",
    assets.modelDir & "/speecht5_postnet.onnx",
    "../models/hifigan-static.onnx"
  ]
  var missing: seq[string] = @[]
  for path in required:
    if not fileExists(path):
      missing.add(path)
  if missing.len > 0:
    raise newException(
      ValueError,
      "Preflight failed. Missing required files (working dir must be the project root): " & missing.join(", ")
    )

proc validateText*(text: string) =
  ## Defensive text validation. The tokenizer would crash on an empty input
  ## (zero-length encoder sequence) and silently produces a 2-second silent
  ## audio on inputs that exceed what the static positional encoding can
  ## encode. Catching these here gives a clear error instead of either a
  ## raw Nim exception or a 30-second silent wav.
  const
    MaxTextChars = 1024
  let trimmed = text.strip()
  if trimmed.len == 0:
    raise newException(ValueError, "Input text is empty. Pass a non-empty string to synthesize.")
  if text.len > MaxTextChars:
    raise newException(
      ValueError,
      "Input text is " & $text.len & " characters, which exceeds the safety cap of " &
      $MaxTextChars & ". SpeechT5 positional encoding saturates around ~10 s of speech; " &
      "longer inputs would silently truncate. Split your text into shorter chunks."
    )

proc initTtsSession*(
  requestedVocoderDevice: string = "AUTO",
  allowFallback: bool = true,
  maxDecoderSteps: int = DefaultMaxDecoderSteps,
  enableVocoderProfiling: bool = false,
  vocoderBlobCachePath: string = "",
  lang: string = "en"
): tuple[session: TtsSession, initMetrics: SessionInitMetrics, vocoderCacheHit: bool] =
  preflightCheck(lang)
  let assets = resolveLanguageAssets(lang)
  new(result.session)
  result.session.maxDecoderSteps = maxDecoderSteps
  result.vocoderCacheHit = false
  result.session.vocoderProfilingEnabled = enableVocoderProfiling
  result.session.feedbackFrameOffset = assets.feedbackFrameOffset
  result.session.minStopStepExclusive = assets.minStopStepExclusive
  result.session.usePostnet = assets.usePostnet
  result.session.vocab = loadVocab(assets.vocabPath)
  result.session.speakerEmbeddingData = readRawFile(assets.speakerEmbeddingPath)
  result.session.speakerEmbeddingTensor = newTensor(
    F32,
    @[1'i64, SpeakerEmbeddingSize.int64],
    addr result.session.speakerEmbeddingData[0]
  )
  result.session.ovCore = newCore()

  echo "[DEBUG] Initializing TTS session for language: ", assets.langTag
  echo "[DEBUG] Loading models from: ", assets.modelDir
  echo "[DEBUG] Speaker embedding path: ", assets.speakerEmbeddingPath

  let loadStart = epochTime()
  let encoderBaseModel = result.session.ovCore.readModel(assets.modelDir & "/speecht5_encoder.onnx")
  let prenetBaseModel = result.session.ovCore.readModel(assets.modelDir & "/speecht5_prenet.onnx")
  let decoderBaseModel = result.session.ovCore.readModel(assets.modelDir & "/speecht5_decoder.onnx")
  let featBaseModel = result.session.ovCore.readModel(assets.modelDir & "/speecht5_feat_out.onnx")
  let postnetBaseModel = result.session.ovCore.readModel(assets.modelDir & "/speecht5_postnet.onnx")
  let vocoderBaseModel = result.session.ovCore.readModel("../models/hifigan-static.onnx")
  result.initMetrics.modelLoadMs = elapsedMs(loadStart)

  let compileStart = epochTime()

  # Check speaker embedding sum
  var seSum = 0.0
  for i in 0 ..< SpeakerEmbeddingSize:
    seSum += result.session.speakerEmbeddingData[i]
  echo "[DEBUG] Speaker embedding sum: ", seSum

  # Make sure the cache directory exists before the compile policy tries to
  # write a blob into it.
  if vocoderBlobCachePath.len > 0:
    let cacheDir = vocoderBlobCachePath.splitFile().dir
    if cacheDir.len > 0 and not dirExists(cacheDir):
      createDir(cacheDir)

  let vocoderCompilation = compileModelWithPolicy(
    result.session.ovCore,
    vocoderBaseModel,
    requestedVocoderDevice,
    allowFallback,
    enableVocoderProfiling,
    vocoderBlobCachePath
  )
  result.session.vocoderModel = vocoderCompilation.compiledModel
  result.session.vocoderCompile = vocoderCompilation.report
  result.vocoderCacheHit = vocoderCompilation.cacheHit

  result.session.encoderModel = result.session.ovCore.compileModel(encoderBaseModel, "CPU")
  result.session.prenetModel = result.session.ovCore.compileModel(prenetBaseModel, "CPU")
  result.session.decoderModel = result.session.ovCore.compileModel(decoderBaseModel, "CPU")
  result.session.featModel = result.session.ovCore.compileModel(featBaseModel, "CPU")
  result.session.postnetModel = result.session.ovCore.compileModel(postnetBaseModel, "CPU")
  # If the profiling compile failed and we fell back to plain compile, mark
  # the session accordingly so callers do not attempt to read empty counters.
  if enableVocoderProfiling:
    let firstAttempt = vocoderCompilation.report.attempts[0]
    if firstAttempt.message.startsWith("Profiling compile failed"):
      result.session.vocoderProfilingEnabled = false
  result.initMetrics.modelCompileMs = elapsedMs(compileStart)

proc synthesizeToPcm*(session: TtsSession, text: string): tuple[pcmData: seq[float32], metrics: SynthesisMetrics] =
  disableDenormalsAreZero()
  validateText(text)
  let totalStart = epochTime()
  let startSnapshot = captureRuntimeSnapshot()

  let inputIds = tokenize(text, session.vocab)
  let effectiveMaxDecoderSteps = max(
    session.maxDecoderSteps,
    min(MaxAdaptiveDecoderSteps, max(64, inputIds.len * 4))
  )
  let inputLen = int64(inputIds.len)
  let inputIdsTensor = newTensor(I64, @[1'i64, inputLen], addr inputIds[0])

  let encoderStart = epochTime()
  let encoderReq = session.encoderModel.createInferRequest()
  encoderReq.setInputTensor(0, inputIdsTensor)
  echo "[DEBUG] Encoder infer..."
  echo "[DEBUG] Token IDs length: ", inputIds.len
  var tokenStr = ""
  for t in inputIds: tokenStr.add($t & " ")
  echo "[DEBUG] Token IDs: ", tokenStr
  encoderReq.infer()
  # We used to copy the encoder output into a Nim seq and rebuild a Tensor
  # from it. That's a ~inputLen*768-float memcpy for no functional reason -
  # the decoder only needs an F32 tensor of shape [1, inputLen, 768] and
  # OpenVINO already gives us one via getOutputTensor. Keep the request alive
  # so the underlying buffer is not freed.
  let encoderOutTensor = encoderReq.getOutputTensor(0)
  
  var encSum = 0.0
  let encData = encoderOutTensor.getData(float32)
  for i in 0 ..< (inputLen * DecoderHiddenSize): encSum += encData[i]
  echo "[DEBUG] Encoder out sum: ", encSum
  
  result.metrics.encoderMs = elapsedMs(encoderStart)

  let autoregressiveStart = epochTime()
  var outSeq = newSeq[float32](MelBins)
  var spectrogramData = newSeq[float32]()
  let prenetReq = session.prenetModel.createInferRequest()
  let decoderReq = session.decoderModel.createInferRequest()
  let featReq = session.featModel.createInferRequest()
  result.metrics.stopStep = effectiveMaxDecoderSteps - 1

  # --- Autoregressive loop: reuse pre-allocated tensors across iterations ---
  # The Prenet input shape grows as [1, idx+1, 80] every step. We allocate
  # the underlying buffer once at the maximum size and call `setShape` each
  # iteration to expose only the leading `idx+1` rows to the model. This
  # removes ~maxDecoderSteps calls to `ov_tensor_create_from_host_ptr`
  # which on the hot path costs measurable FFI overhead.
  let prenetInBuffer = newSeq[float32](int64(effectiveMaxDecoderSteps) * MelBins.int64)
  let prenetInTensor = newTensor(
    F32,
    @[1'i64, int64(effectiveMaxDecoderSteps), MelBins.int64],
    addr prenetInBuffer[0]
  )
  # The Feat input is a fixed [1, 1, 768] slice. One allocation for the whole
  # loop is enough; we just copy the latest decoder row into its host buffer
  # before each `infer()`.
  let featInBuffer = newSeq[float32](DecoderHiddenSize)
  let featInTensor = newTensor(
    F32,
    @[1'i64, 1'i64, DecoderHiddenSize.int64],
    addr featInBuffer[0]
  )
  let prenetInPtr = prenetInTensor.getData(float32)
  let featInPtr = featInTensor.getData(float32)

  for idx in 0 ..< effectiveMaxDecoderSteps:
    let seqLen = idx + 1
    # Copy outSeq[0..seqLen*MelBins] into prenetInBuffer and shrink the shape.
    # The buffer past `seqLen*MelBins` is intentionally left untouched; the
    # model never sees those elements because of the shape.
    for i in 0 ..< (seqLen * MelBins):
      prenetInPtr[i] = outSeq[i]
    if idx == 0 or idx == 1:
      echo "[DEBUG] Step ", idx, " prenetIn first 2: ", prenetInPtr[0], ", ", prenetInPtr[1]
      echo "[DEBUG] Step ", idx, " prenetIn first row last 2: ", prenetInPtr[MelBins - 2], ", ", prenetInPtr[MelBins - 1]
      if seqLen > 1:
        echo "[DEBUG] Step ", idx, " prenetIn second row first 2: ", prenetInPtr[MelBins], ", ", prenetInPtr[MelBins + 1]
        echo "[DEBUG] Step ", idx, " prenetIn second row last 2: ", prenetInPtr[2 * MelBins - 2], ", ", prenetInPtr[2 * MelBins - 1]

    prenetInTensor.setShape(@[1'i64, int64(seqLen), MelBins.int64])

    prenetReq.setInputTensor(0, prenetInTensor)
    prenetReq.setInputTensor(1, session.speakerEmbeddingTensor)
    echo "[DEBUG] Prenet infer..."
    disableDenormalsAreZero()
    prenetReq.infer()

    let prenetOutTensor = prenetReq.getOutputTensor(0)
    if idx == 0 or idx == 1:
      let prenetOut = prenetOutTensor.getData(float32)
      var pSum = 0.0
      for i in 0 ..< prenetOutTensor.getSize(): pSum += prenetOut[i]
      echo "[DEBUG] Step ", idx, " prenetOut sum: ", pSum
    if idx == 0 or idx == 1:
      var encSum = 0.0
      let encData = encoderOutTensor.getData(float32)
      for i in 0 ..< (inputLen * DecoderHiddenSize): encSum += encData[i]
      echo "[DEBUG] Step ", idx, " encoderOut sum before decoder: ", encSum
      echo "[DEBUG] Step ", idx, " prenetOut size: ", prenetOutTensor.getSize()
      echo "[DEBUG] Step ", idx, " encoderOut size: ", encoderOutTensor.getSize()

    decoderReq.setInputTensor(0, prenetOutTensor)
    decoderReq.setInputTensor(1, encoderOutTensor)
    disableDenormalsAreZero()
    decoderReq.infer()

    let decoderOutTensor = decoderReq.getOutputTensor(0)
    let decoderOut = decoderOutTensor.getData(float32)
    if idx == 0 or idx == 1:
      var dSum = 0.0
      for i in 0 ..< (seqLen * DecoderHiddenSize): dSum += decoderOut[i]
      echo "[DEBUG] Step ", idx, " decoderOut sum: ", dSum
    let decoderOffset = (seqLen - 1) * DecoderHiddenSize
    var featInSum = 0.0
    for i in 0 ..< DecoderHiddenSize:
      featInPtr[i] = decoderOut[decoderOffset + i]
      featInSum += featInPtr[i]

    if idx == 0 or idx == 1:
      echo "[DEBUG] Step ", idx, " feat_in sum: ", featInSum
      echo "[DEBUG] Step ", idx, " feat_in first 2: ", featInPtr[0], ", ", featInPtr[1]

    featReq.setInputTensor(0, featInTensor)
    disableDenormalsAreZero()
    featReq.infer()

    let spectrumOutTensor = featReq.getOutputTensor(0)
    let probabilityOutTensor = featReq.getOutputTensor(1)
    let spectrumOut = spectrumOutTensor.getData(float32)
    let probabilityOut = probabilityOutTensor.getData(float32)

    if idx == 0 or idx == 1:
      let out0Shape = spectrumOutTensor.getSize()
      let out1Shape = probabilityOutTensor.getSize()
      echo "[DEBUG] feat_out output 0 size: ", out0Shape
      echo "[DEBUG] feat_out output 1 size: ", out1Shape
      var specSum = 0.0
      for i in 0 ..< (2 * MelBins): specSum += spectrumOut[i]
      echo "[DEBUG] Step ", idx, " probability: ", probabilityOut[0], ", ", probabilityOut[1]
      echo "[DEBUG] Step ", idx, " spectrum sum: ", specSum
      echo "[DEBUG] Step ", idx, " spectrum first 2: ", spectrumOut[0], ", ", spectrumOut[1]

    for i in 0 ..< (2 * MelBins):
      spectrogramData.add(spectrumOut[i])

    for i in 0 ..< MelBins:
      outSeq.add(spectrumOut[session.feedbackFrameOffset + i])

    let stopProbability0 = 1.0 / (1.0 + exp(-probabilityOut[0]))
    let stopProbability1 = 1.0 / (1.0 + exp(-probabilityOut[1]))
    if idx mod 20 == 0:
      echo "[DEBUG] Step ", idx, " stop prob: ", stopProbability0 + stopProbability1
    if (stopProbability0 + stopProbability1) >= 0.5 and idx > session.minStopStepExclusive:
      result.metrics.stopStep = idx
      break
  result.metrics.autoregressiveMs = elapsedMs(autoregressiveStart)

  let currentFrames = spectrogramData.len div MelBins
  result.metrics.frameCount = currentFrames

  let postnetStart = epochTime()
  var finalMelTensor: Tensor = nil
  var finalMelData: ptr UncheckedArray[float32]
  if session.usePostnet:
    let unpaddedSpecTensor = newTensor(
      F32,
      @[1'i64, int64(currentFrames), MelBins.int64],
      addr spectrogramData[0]
    )
    let postReq = session.postnetModel.createInferRequest()
    postReq.setInputTensor(0, unpaddedSpecTensor)
    echo "[DEBUG] Postnet infer..."
    postReq.infer()
    finalMelTensor = postReq.getOutputTensor(0)
    finalMelData = finalMelTensor.getData(float32)
  else:
    # English path temporary recovery: bypass the exported ONNX postnet because
    # it shifts the mel spectrogram too far downward and collapses volume.
    finalMelData = cast[ptr UncheckedArray[float32]](addr spectrogramData[0])
  result.metrics.postnetMs = elapsedMs(postnetStart)

  let vocoderStart = epochTime()
  result.metrics.vocoderProfiling.enabled = session.vocoderProfilingEnabled
  # --- Vocoder chunking: reuse the padded chunk buffer + tensor ---
  # The chunk shape is fixed at [1, 128, 80] for every iteration. We allocate
  # the host buffer and the OpenVINO tensor once, then on each iteration
  # only refill the buffer (mel slice + -3.6 padding) and re-use the same
  # tensor. Saves ~numChunks allocations per inference.
  let paddedChunk = newSeq[float32](VocoderChunkFrames * MelBins)
  let chunkTensor = newTensor(
    F32,
    @[1'i64, VocoderChunkFrames.int64, MelBins.int64],
    addr paddedChunk[0]
  )
  let chunkDataPtr = chunkTensor.getData(float32)
  let melPadValue: float32 = -3.6
  var chunkStart = 0
  while chunkStart < currentFrames:
    var chunkFrames = currentFrames - chunkStart
    let srcBase = chunkStart * MelBins
    if chunkFrames >= VocoderChunkFrames:
      for i in 0 ..< (VocoderChunkFrames * MelBins):
        chunkDataPtr[i] = finalMelData[srcBase + i]
      chunkFrames = VocoderChunkFrames
    else:
      let validElems = chunkFrames * MelBins
      for i in 0 ..< validElems:
        chunkDataPtr[i] = finalMelData[srcBase + i]
      for i in validElems ..< (VocoderChunkFrames * MelBins):
        chunkDataPtr[i] = melPadValue

    let vocoderReq = session.vocoderModel.createInferRequest()
    vocoderReq.setInputTensor(0, chunkTensor)
    let chunkInferStart = epochTime()
    echo "[DEBUG] Vocoder infer..."
    vocoderReq.infer()
    result.metrics.vocoderProfiling.wallClockUs.inc(int64((epochTime() - chunkInferStart) * 1_000_000.0))
    if session.vocoderProfilingEnabled:
      try:
        let layers = vocoderReq.getProfilingInfo()
        for layer in layers:
          result.metrics.vocoderProfiling.mergeProfilingLayer(layer)
      except CatchableError:
        # If profiling retrieval fails mid-run we mark the session as having
        # no profiling and continue. The error message is captured in the
        # benchmarking path; here we just stop trying.
        session.vocoderProfilingEnabled = false

    let outputTensor = vocoderReq.getOutputTensor(0)
    let outputPtr = outputTensor.getData(float32)
    let validSamples = chunkFrames * SamplesPerFrame
    for i in 0 ..< validSamples:
      result.pcmData.add(outputPtr[i])

    chunkStart += VocoderChunkFrames
  result.metrics.vocoderMs = elapsedMs(vocoderStart)
  result.metrics.vocoderProfiling.finalizeHotLayers()

  result.metrics.sampleCount = result.pcmData.len
  result.metrics.totalMs = elapsedMs(totalStart)
  result.metrics.audioDurationSec = result.pcmData.len.float / SampleRate.float
  if result.metrics.audioDurationSec > 0.0:
    result.metrics.rtf = (result.metrics.totalMs / 1000.0) / result.metrics.audioDurationSec

  let endSnapshot = captureRuntimeSnapshot()
  applyRuntimeMetrics(result.metrics, startSnapshot, endSnapshot)

proc synthesizeToWav*(
  session: TtsSession,
  text: string,
  outputPath: string,
  volume: float = 1.0,
  speed: float = 1.0,
  pitch: float = 1.0
): SynthesisMetrics =
  let synthesis = synthesizeToPcm(session, text)
  writeWav(outputPath, synthesis.pcmData, SampleRate, volume, speed, pitch)
  result = synthesis.metrics

proc runBenchmark*(
  text: string,
  warmRuns: int = 2,
  vocoderBlobCacheDir: string = "",
  lang: string = "en"
): seq[BenchmarkEntry] =
  for requestedDevice in ["CPU", "GPU", "NPU"]:
    var entry = BenchmarkEntry(
      requestedDevice: requestedDevice,
      status: "failed",
      npuUsageNote: "Profiling not yet executed."
    )
    try:
      # Always enable profiling at compile time on every device so the NPU
      # usage % columns can be filled in even for CPU/GPU baselines. The
      # vocoder blob cache (when configured) lets the NPU path skip its
      # 13 s device compile on every bench run.
      let cachePath = if vocoderBlobCacheDir.len > 0:
        vocoderBlobCacheDir / "hifigan-static." & requestedDevice & ".blob"
      else: ""
      let initialized = initTtsSession(
        requestedDevice,
        allowFallback = false,
        enableVocoderProfiling = true,
        vocoderBlobCachePath = cachePath,
        lang = lang
      )
      let session = initialized.session
      entry.actualDevice = session.vocoderCompile.actualDevice
      entry.modelLoadMs = initialized.initMetrics.modelLoadMs
      entry.modelCompileMs = initialized.initMetrics.modelCompileMs
      entry.vocoderBlobCacheHit = initialized.vocoderCacheHit
      if not session.vocoderProfilingEnabled:
        # Pull the most informative attempt message out of the compile
        # report so the bench table shows WHY profiling was dropped.
        if session.vocoderCompile.attempts.len > 0:
          let firstAttempt = session.vocoderCompile.attempts[0]
          entry.npuUsageNote = "Profiling hint was rejected at compile time: " & firstAttempt.message
        else:
          entry.npuUsageNote = "Profiling hint was rejected at compile time; falling back to plain compile."

      let firstRun = synthesizeToPcm(session, text)
      entry.status = "ok"
      entry.firstInferenceLatencyMs = firstRun.metrics.totalMs
      entry.audioGenerationTimeMs = firstRun.metrics.totalMs
      entry.audioDurationSec = firstRun.metrics.audioDurationSec
      entry.rtf = firstRun.metrics.rtf
      entry.avgCpuUsagePercent = firstRun.metrics.avgCpuUsagePercent
      entry.workingSetMB = firstRun.metrics.workingSetMB
      entry.peakMemoryMB = firstRun.metrics.peakMemoryMB
      # Per-phase timing is the headline diagnostic of Phase 13: it tells us
      # exactly where the wall-clock time is going.
      entry.encoderMs = firstRun.metrics.encoderMs
      entry.autoregressiveMs = firstRun.metrics.autoregressiveMs
      entry.postnetMs = firstRun.metrics.postnetMs
      entry.vocoderMs = firstRun.metrics.vocoderMs
      let firstProf = firstRun.metrics.vocoderProfiling
      entry.npuProfilingAvailable = firstProf.enabled and firstProf.layerCount > 0
      entry.npuLayerCount = firstProf.layerCount
      entry.npuTotalRealTimeUs = firstProf.totalRealTimeUs
      entry.npuTotalCpuTimeUs = firstProf.totalCpuTimeUs
      entry.npuWallClockUs = firstProf.wallClockUs
      entry.npuUsagePercent = firstProf.computeNpuUsagePercent()
      entry.npuHotLayers = firstProf.hotLayers
      if entry.npuProfilingAvailable:
        if firstProf.collectedFromNpu:
          entry.npuUsageNote = "Real per-layer counters from NPU driver (PERF_COUNT=YES)."
        else:
          entry.npuUsageNote = "Per-layer counters reported by " & entry.actualDevice & " (CPU path)."

      if warmRuns > 0:
        var totalWarmLatencyMs = 0.0
        for _ in 0 ..< warmRuns:
          let warmRun = synthesizeToPcm(session, text)
          totalWarmLatencyMs += warmRun.metrics.totalMs
          entry.avgCpuUsagePercent = max(entry.avgCpuUsagePercent, warmRun.metrics.avgCpuUsagePercent)
          entry.workingSetMB = max(entry.workingSetMB, warmRun.metrics.workingSetMB)
          entry.peakMemoryMB = max(entry.peakMemoryMB, warmRun.metrics.peakMemoryMB)
        entry.averageInferenceLatencyMs = totalWarmLatencyMs / float(warmRuns)
      else:
        entry.averageInferenceLatencyMs = entry.firstInferenceLatencyMs
    except Exception as e:
      entry.errorMessage = e.msg

    result.add(entry)
