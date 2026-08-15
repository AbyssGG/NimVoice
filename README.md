# NimVoice

NimVoice is a fully offline local AI Text-to-Speech project built primarily in **Nim** and accelerated through the **Intel OpenVINO C API**.

Its core goal is simple:

- native executable
- no Python runtime for end users
- real Intel NPU acceleration
- practical local TTS on Windows AI PCs

## Current Open-Source Status

The current open-source baseline focuses on the stable English pipeline.

- Runtime synthesis is fully offline.
- The application is written around Nim + OpenVINO C API integration.
- Intel NPU support is treated as a first-class requirement.
- The current public build defaults to `--lang=en`.
- Chinese synthesis is temporarily disabled in the open-source build while the multilingual path is being stabilized.

## Why This Project Exists

- **Why Nim?** Nim compiles to native code and makes it practical to build a standalone app with explicit control over FFI, memory, and deployment.
- **Why OpenVINO C API?** It keeps the runtime boundary small and predictable while still unlocking CPU, GPU, and NPU backends.
- **Why Intel NPU?** NimVoice is designed for real AI PC deployment, not just CPU-only demos.
- **Why no Python runtime?** End users should not need `pip`, `venv`, `PyTorch`, or background scripting layers just to synthesize speech.

## Runtime Architecture

To work around the NPU's static-shape requirements while preserving a usable TTS pipeline, NimVoice uses a heterogeneous CPU + NPU design:

```text
             Nim (Native App)
              │
        Text Normalization (Pure Nim)
              │
              ▼
    ┌───────────────────────────┐
    │ SpeechT5 Frontend         │
    │ Backend: Intel CPU        │
    │ Autoregressive Decoder    │
    └─────────┬─────────────────┘
              │ Mel-Spectrogram
              ▼
    ┌───────────────────────────┐
    │ HiFi-GAN Vocoder          │
    │ Backend: Intel NPU        │
    │ Static Graph [1, 128, 80] │
    └─────────┬─────────────────┘
              │
       WAV Audio Output
```

## Repository Layout

```text
src/            Nim runtime and OpenVINO integration
models/         model files and compiled cache
electron-gui/   Electron + React frontend
benchmark/      benchmark outputs
build.cmd       main build entrypoint
run.cmd         CLI entrypoint
run-gui.cmd     GUI entrypoint
```

## Requirements

- Windows 11 x64
- Nim 2.x
- MinGW / TDM-GCC toolchain
- Intel OpenVINO runtime DLLs
- Optional: Node.js for building the Electron GUI

## Build

From the project root:

```cmd
build.cmd
```

This script:

1. builds the Electron GUI if `npm` is available
2. compiles `resources.rc`
3. builds `src/main.nim` into `bin/nimvoice.exe`
4. copies OpenVINO runtime DLLs into `bin/`

## Run

### GUI

```cmd
run-gui.cmd
```

### CLI synthesis

```cmd
run.cmd "Hello world from NimVoice."
```

The output WAV is written to `bin/output.wav`.

### Benchmark

```cmd
bin\nimvoice.exe bench --warm-runs=0
```

Benchmark results are written to `benchmark/results.md` and `benchmark/results.json`.

## Performance Notes

NimVoice uses real OpenVINO `PERF_COUNT` profiling rather than placeholder counters. A dedicated C wrapper is used to bridge Windows x64 variadic ABI differences safely.

The project also supports compiled-model `.blob` caching for the NPU path, which significantly reduces repeated startup cost after the first compile.

## Open-Source Boundaries

This repository contains the application layer:

- TTS pipeline logic
- GUI integration
- benchmark tooling
- model orchestration

The lower-level OpenVINO wrapper layer is being separated as the standalone `Resonance` library.

## Related Files

- [TROUBLESHOOTING.md](./TROUBLESHOOTING.md)
- [MODEL_LICENSES.md](./MODEL_LICENSES.md)
- [DEVLOG.md](./DEVLOG.md)
- [CONTRIBUTING.md](./CONTRIBUTING.md)
- [README.zh-CN.md](./README.zh-CN.md)

## License

NimVoice is licensed under the [MIT License](./LICENSE).

Third-party model and runtime licensing information remains documented separately in [MODEL_LICENSES.md](./MODEL_LICENSES.md).
