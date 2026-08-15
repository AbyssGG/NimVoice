# Troubleshooting Guide

This guide helps you resolve common issues when building or running **NimVoice**.

## Exit Codes

The `nimvoice.exe` CLI tool uses specific exit codes to help scripts and CI environments identify the nature of a failure:

*   **Exit Code 0:** Success. Audio generated successfully or benchmark completed.
*   **Exit Code 1:** System/Internal Error. (e.g., OpenVINO runtime failure, memory allocation error, driver crash).
*   **Exit Code 2:** User/Input Error. (e.g., missing model files, text exceeds maximum length, empty text).

---

## Common Issues & Solutions

### 1. Preflight Check Failed (Missing Files)
**Error Message:** 
`[ERROR] Preflight failed. Missing required files (working dir must be the project root): ...`

**Cause:** NimVoice relies on a strict directory structure. You are likely running the executable from the wrong working directory, or you haven't downloaded the required ONNX models and vocabulary files.

**Solution:**
1. Ensure you always run the program from the **project root directory** (e.g., `C:\nim\NimVoice`), not from inside the `bin/` folder.
2. Use the provided `run.cmd` script, which automatically handles directory navigation.
3. Check the `models/` directory to ensure all `speecht5_*.onnx`, `hifigan-static.onnx`, and `.raw` embedding files exist.

### 2. Input Text Truncation / Saturation
**Error Message:** 
`[ERROR] Input text is N characters, which exceeds the safety cap of 1024.`

**Cause:** The SpeechT5 model uses static positional encoding which saturates at around 10 seconds of speech. Inputting a massive block of text will cause the model to lose track of time and generate 30+ seconds of pure silence or noise. To protect the user from "silent failures", NimVoice enforces a strict 1024 character limit.

**Solution:** 
Split your text into shorter sentences or paragraphs and run the synthesis command multiple times, concatenating the resulting WAV files if necessary.

### 3. Missing `openvino_c.dll` or Runtime Errors
**Error Message:**
System dialog stating a DLL is missing, or `[ERROR] Internal failure: ...` related to loading models.

**Cause:** The OpenVINO runtime libraries are missing from the `bin/` directory or the PATH.

**Solution:**
Ensure that all required Intel OpenVINO DLLs (e.g., `openvino_c.dll`, `openvino_intel_npu_plugin.dll`, `tbb.dll`) are placed right next to `nimvoice.exe` inside the `bin/` folder.

### 4. "Profiling hint was rejected at compile time" (NPU Usage is `-`)
**Observation:** In the benchmark results (`benchmark/results.md`), the NPU Usage % is marked as `-` and the note says the profiling hint was rejected.

**Cause:** This is a known behavior of the Intel NPU driver. NimVoice caches compiled NPU models (`.blob` files) to accelerate startup times (from 13.5s down to 850ms). However, the NPU driver does not allow enabling hardware profiling (`PERF_COUNT=YES`) on a model that was loaded from a cached `.blob`.

**Solution:** 
If you strictly need to measure real per-layer NPU hardware metrics, delete the `.blob` cache file:
`del models\.cache\compiled\hifigan-static.NPU.blob`
Then run `bench` again. The first run will recompile the graph and successfully capture hardware metrics.

### 5. NPU Backend Fallback
**Error Message:**
The app runs successfully, but the logs indicate it fell back to the `CPU` or `GPU` backend despite requesting the NPU.

**Cause:**
*   You are not running on an Intel Core Ultra (or compatible) processor with an NPU.
*   Your Intel NPU driver is severely outdated.
*   The `openvino_intel_npu_plugin.dll` is missing.

**Solution:**
1. Check Windows Device Manager under "Neural Processors" to verify the NPU is active.
2. Update your Intel NPU drivers via Intel's official driver assistant.

### 6. Garbled/Drill Noise at the end of Audio
**Cause:** Older versions of the application padded the Mel-spectrogram with `0.0`, which represents extreme white noise in Log-Mel space.

**Solution:** This was fixed in Phase 10+. Ensure you have compiled the latest version of `src/main.nim` which correctly pads empty frames with `-3.6` (silence). Run `build.cmd` to rebuild.
