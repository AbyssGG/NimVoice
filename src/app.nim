import tts
import std/json
import std/os
import std/strutils
import std/times

const
  DefaultText* = "Hello world! This is a test of NimVoice."
  DefaultOutputPath* = "output.wav"
  DefaultBenchmarkDir* = "../benchmark"

proc formatMetric(value: float): string =
  formatFloat(value, ffDecimal, 2)

proc formatMicros(value: int64): string =
  if value <= 0: "0"
  else: $value

proc metricOrDash(value: string): string =
  if value.len > 0: value else: "-"

proc hotLayersToJson(layers: seq[HotLayer]): JsonNode =
  let arr = newJArray()
  for layer in layers:
    arr.add(%*{
      "node_name": layer.nodeName,
      "node_type": layer.nodeType,
      "real_time_us": layer.realTimeUs
    })
  arr

proc benchmarkEntryToJson(entry: BenchmarkEntry): JsonNode =
  %*{
    "requested_device": entry.requestedDevice,
    "actual_device": entry.actualDevice,
    "status": entry.status,
    "error_message": entry.errorMessage,
    "model_load_ms": entry.modelLoadMs,
    "model_compile_ms": entry.modelCompileMs,
    "vocoder_blob_cache_hit": entry.vocoderBlobCacheHit,
    "first_inference_latency_ms": entry.firstInferenceLatencyMs,
    "average_inference_latency_ms": entry.averageInferenceLatencyMs,
    "audio_generation_time_ms": entry.audioGenerationTimeMs,
    "audio_duration_sec": entry.audioDurationSec,
    "rtf": entry.rtf,
    "avg_cpu_usage_percent": entry.avgCpuUsagePercent,
    "working_set_mb": entry.workingSetMB,
    "peak_memory_mb": entry.peakMemoryMB,
    # Per-phase breakdown of the first inference (ms). On this machine the
    # CPU frontend (encoder + autoregressive + postnet) is the dominant
    # contributor; the NPU vocoder only adds a few hundred ms.
    "encoder_ms": entry.encoderMs,
    "autoregressive_ms": entry.autoregressiveMs,
    "postnet_ms": entry.postnetMs,
    "vocoder_ms": entry.vocoderMs,
    "npu_usage_note": entry.npuUsageNote,
    "npu_profiling_available": entry.npuProfilingAvailable,
    "npu_layer_count": entry.npuLayerCount,
    "npu_total_real_time_us": entry.npuTotalRealTimeUs,
    "npu_total_cpu_time_us": entry.npuTotalCpuTimeUs,
    "npu_wall_clock_us": entry.npuWallClockUs,
    "npu_usage_percent": entry.npuUsagePercent,
    "npu_hot_layers": hotLayersToJson(entry.npuHotLayers)
  }

proc writeBenchmarkArtifacts*(
  text: string,
  entries: seq[BenchmarkEntry],
  warmRuns: int,
  outputDir: string = DefaultBenchmarkDir
) =
  createDir(outputDir)

  var resultsJson = newJObject()
  resultsJson["generated_at"] = %($now())
  resultsJson["text"] = %text
  resultsJson["warm_runs"] = %warmRuns
  resultsJson["sample_rate"] = %SampleRate

  var runsNode = newJArray()
  for entry in entries:
    runsNode.add(benchmarkEntryToJson(entry))
  resultsJson["results"] = runsNode

  writeFile(outputDir / "results.json", pretty(resultsJson, 2))

  var markdown = newSeq[string]()
  markdown.add("# NimVoice Benchmark Results")
  markdown.add("")
  markdown.add("- Generated At: " & $now())
  markdown.add("- Text: `" & text & "`")
  markdown.add("- Warm Runs: " & $warmRuns)
  markdown.add("- Frontend Pipeline: SpeechT5 components on CPU")
  markdown.add("- Compared Backend: HiFi-GAN Vocoder backend (`CPU` / `GPU` / `NPU`)")
  markdown.add("- Phase 13: per-phase timing + NPU blob cache are wired in; PERF_COUNT=YES still on for `bench` so NPU usage % is real.")
  markdown.add("")
  markdown.add("## Summary")
  markdown.add("")
  markdown.add("| Backend | Status | Device | Cache | Encoder ms | Autoreg ms | Postnet ms | Vocoder ms | First ms | RTF | NPU usage % | Note |")
  markdown.add("| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |")

  for entry in entries:
    if entry.status == "ok":
      let npuUsageStr = if entry.npuProfilingAvailable: formatMetric(entry.npuUsagePercent) else: "-"
      let cacheStr = if entry.vocoderBlobCacheHit: "HIT" else: "miss"
      markdown.add(
        "| " & entry.requestedDevice &
        " | OK" &
        " | " & metricOrDash(entry.actualDevice) &
        " | " & cacheStr &
        " | " & formatMetric(entry.encoderMs) &
        " | " & formatMetric(entry.autoregressiveMs) &
        " | " & formatMetric(entry.postnetMs) &
        " | " & formatMetric(entry.vocoderMs) &
        " | " & formatMetric(entry.firstInferenceLatencyMs) &
        " | " & formatMetric(entry.rtf) &
        " | " & npuUsageStr &
        " | " & entry.npuUsageNote & " |"
      )
    else:
      markdown.add(
        "| " & entry.requestedDevice &
        " | FAILED" &
        " | " & metricOrDash(entry.actualDevice) &
        " | - | - | - | - | - | - | - | - | " &
        entry.errorMessage.replace("|", "\\|") & " |"
      )

  markdown.add("")
  markdown.add("## Per-Layer NPU / Vocoder Hot Spots")
  markdown.add("")
  markdown.add("Top-5 layers by `real_time` (microseconds) from the first inference run. Empty table means the device did not report per-layer counters.")
  markdown.add("")
  markdown.add("| Backend | Node name | Node type | Real time us |")
  markdown.add("| --- | --- | --- | ---: |")
  for entry in entries:
    if entry.status == "ok" and entry.npuHotLayers.len > 0:
      for layer in entry.npuHotLayers:
        markdown.add(
          "| " & entry.requestedDevice &
          " | " & layer.nodeName.replace("|", "\\|") &
          " | " & layer.nodeType.replace("|", "\\|") &
          " | " & $layer.realTimeUs & " |"
        )

  writeFile(outputDir / "results.md", markdown.join("\n") & "\n")

proc runSynthesisCommand*(
  text: string,
  requestedDevice: string = "AUTO",
  outputPath: string = DefaultOutputPath,
  volume: float = 1.0,
  speed: float = 1.0,
  pitch: float = 1.0,
  lang: string = "en"
) =
  echo "NimVoice Phase 13 - Quick Wins (profiling off in production)"
  echo "--------------------------------------------------"
  echo "Input Text: ", text
  echo "Requested Vocoder Device: ", requestedDevice
  echo "Volume: ", volume, " Speed: ", speed, " Pitch: ", pitch
  echo "--------------------------------------------------"

  # Per-layer profiling is now OFF by default in the production (synth) path.
  # The 1-5% overhead of PERF_COUNT=YES is not worth paying when the caller
  # is just going to play the audio. The `bench` command enables profiling
  # explicitly so it can populate the NPU usage % columns.
  let wantProfiling = false
  # Use a per-device blob cache so subsequent runs skip the NPU/GPU
  # compile pipeline. The cache is created on first compile and refreshed
  # transparently when the underlying model changes.
  let cachePath = VocoderBlobCacheDir / ("hifigan-static." & requestedDevice & ".blob")
  let initialized = initTtsSession(
    requestedDevice,
    allowFallback = true,
    enableVocoderProfiling = wantProfiling,
    vocoderBlobCachePath = cachePath,
    lang = lang
  )
  let session = initialized.session
  echo "Vocoder actual device: ", session.vocoderCompile.actualDevice
  echo "Model load time: ", formatMetric(initialized.initMetrics.modelLoadMs), " ms"
  echo "Model compile time: ", formatMetric(initialized.initMetrics.modelCompileMs), " ms"
  echo "Vocoder blob cache: ", (if initialized.vocoderCacheHit: "HIT" else: "MISS (will write on exit)")
  if session.vocoderProfilingEnabled:
    echo "Per-layer profiling: ENABLED (PERF_COUNT=YES)"
  else:
    echo "Per-layer profiling: disabled (compile-time hint rejected or device = CPU)"

  let metrics = synthesizeToWav(session, text, outputPath, volume, speed, pitch)
  echo "Audio generation time: ", formatMetric(metrics.totalMs), " ms"
  echo "Audio duration: ", formatMetric(metrics.audioDurationSec), " s"
  echo "RTF: ", formatMetric(metrics.rtf)
  echo "Peak memory: ", formatMetric(metrics.peakMemoryMB), " MB"
  echo "Estimated CPU usage: ", formatMetric(metrics.avgCpuUsagePercent), " %"
  if metrics.vocoderProfiling.enabled and metrics.vocoderProfiling.layerCount > 0:
    let prof = metrics.vocoderProfiling
    echo "NPU profile (vocoder only):"
    echo "  Executed layers: ", prof.layerCount
    echo "  Sum real_time: ", prof.totalRealTimeUs, " us"
    echo "  Sum cpu_time:  ", prof.totalCpuTimeUs, " us"
    echo "  Wall clock:    ", prof.wallClockUs, " us"
    echo "  NPU usage %:   ", formatMetric(prof.computeNpuUsagePercent())
    echo "  Top-5 hot layers:"
    for layer in prof.hotLayers:
      echo "    - ", layer.nodeName, " (", layer.nodeType, ") ", layer.realTimeUs, " us"
  echo "Done! Audio saved to ", outputPath

proc runBenchmarkCommand*(
  text: string,
  warmRuns: int = 2,
  lang: string = "en",
  outputDir: string = DefaultBenchmarkDir
) =
  echo "NimVoice Phase 13 - Benchmark Runner with Real NPU Profiling"
  echo "--------------------------------------------------"
  echo "Benchmark Text: ", text
  echo "Warm Runs per backend: ", warmRuns
  echo "--------------------------------------------------"

  # Use the same blob cache directory as the synth path so a NPU run that
  # follows a previous bench can skip the 13 s device compile.
  let entries = runBenchmark(text, warmRuns, vocoderBlobCacheDir = VocoderBlobCacheDir, lang = lang)
  writeBenchmarkArtifacts(text, entries, warmRuns, outputDir)

  for entry in entries:
    if entry.status == "ok":
      let extra = if entry.npuProfilingAvailable:
        " npu=" & formatMetric(entry.npuUsagePercent) & "% layers=" & $entry.npuLayerCount
      else:
        " npu=-"
      let cacheNote = if entry.vocoderBlobCacheHit: " [blob cache HIT]" else: ""
      echo entry.requestedDevice, ": OK (", entry.actualDevice, ") first=", formatMetric(entry.firstInferenceLatencyMs),
        " ms avg=", formatMetric(entry.averageInferenceLatencyMs), " ms rtf=", formatMetric(entry.rtf), extra, cacheNote
    else:
      echo entry.requestedDevice, ": FAILED - ", entry.errorMessage

  echo "Benchmark artifacts saved to ", outputDir
