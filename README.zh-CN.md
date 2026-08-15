# NimVoice

NimVoice 是一个完全离线运行的本地 AI 文本转语音项目，主要使用 **Nim** 编写，并通过 **Intel OpenVINO C API** 获得硬件加速能力。

它的核心目标很直接：

- 原生可执行文件
- 终端用户运行时不依赖 Python
- 必须支持真实 Intel NPU 加速
- 面向 Windows AI PC 的本地 TTS

## 当前开源状态

当前开源基线优先聚焦在稳定的英文链路。

- 运行时语音合成是完全离线的。
- 整个应用围绕 Nim + OpenVINO C API 构建。
- Intel NPU 支持被视为一等需求。
- 当前公开构建默认使用 `--lang=en`。
- 中文合成在开源版本里暂时关闭，等待多语言链路进一步稳定后再恢复。

## 为什么做这个项目

- **为什么是 Nim？** Nim 可以编译成原生代码，便于在 FFI、内存和部署层面做更直接的控制。
- **为什么是 OpenVINO C API？** 它让运行时边界更小、更可控，同时还能接入 CPU、GPU、NPU 后端。
- **为什么必须要 NPU？** NimVoice 不是只跑 CPU 的演示程序，而是面向真实 AI PC 部署。
- **为什么不要 Python 运行时？** 终端用户不应该为了用一个 TTS 程序还去安装 `pip`、`venv`、`PyTorch` 或脚本桥接层。

## 运行时架构

为了绕开 NPU 对静态 shape 的要求，同时保留可用的 TTS 能力，NimVoice 采用了 CPU + NPU 异构设计：

```text
             Nim (Native App)
              │
         文本归一化 (Pure Nim)
              │
              ▼
    ┌───────────────────────────┐
    │ SpeechT5 Frontend         │
    │ Backend: Intel CPU        │
    │ 自回归 Decoder            │
    └─────────┬─────────────────┘
              │ Mel-Spectrogram
              ▼
    ┌───────────────────────────┐
    │ HiFi-GAN Vocoder          │
    │ Backend: Intel NPU        │
    │ Static Graph [1, 128, 80] │
    └─────────┬─────────────────┘
              │
          WAV 音频输出
```

## 仓库结构

```text
src/            Nim 运行时和 OpenVINO 集成
models/         模型文件与编译缓存
electron-gui/   Electron + React 前端
benchmark/      benchmark 输出
build.cmd       主构建入口
run.cmd         CLI 入口
run-gui.cmd     GUI 入口
```

## 环境要求

- Windows 11 x64
- Nim 2.x
- MinGW / TDM-GCC 工具链
- Intel OpenVINO runtime DLL
- 可选：Node.js，用于构建 Electron GUI

## 构建

在项目根目录执行：

```cmd
build.cmd
```

这个脚本会依次：

1. 如果检测到 `npm`，先构建 Electron GUI
2. 编译 `resources.rc`
3. 把 `src/main.nim` 构建为 `bin/nimvoice.exe`
4. 把 OpenVINO runtime DLL 复制到 `bin/`

## 运行

### GUI

```cmd
run-gui.cmd
```

### CLI 合成

```cmd
run.cmd "Hello world from NimVoice."
```

输出 WAV 会写到 `bin/output.wav`。

### Benchmark

```cmd
bin\nimvoice.exe bench --warm-runs=0
```

Benchmark 结果会写入 `benchmark/results.md` 和 `benchmark/results.json`。

## 性能说明

NimVoice 使用真实的 OpenVINO `PERF_COUNT` profiling，而不是占位统计。项目里还包含一个专门的 C 包装层，用来安全处理 Windows x64 下 variadic ABI 的兼容问题。

此外，NPU 路径支持编译后 `.blob` 缓存，可以显著降低首次编译之后的重复启动开销。

## 开源边界

这个仓库承载的是应用层：

- TTS 流水线逻辑
- GUI 集成
- benchmark 工具
- 模型编排

更底层的 OpenVINO 封装层正在拆分为独立的 `Resonance` 库。

## 署名

本项目使用到的底层 Nim OpenVINO C API 封装与绑定工作，必须署名到 `Resonance`：

https://github.com/AbyssGG/Resonance/tree/main

## 相关文件

- [README.md](./README.md)
- [TROUBLESHOOTING.md](./TROUBLESHOOTING.md)
- [MODEL_LICENSES.md](./MODEL_LICENSES.md)
- [DEVLOG.md](./DEVLOG.md)
- [CONTRIBUTING.md](./CONTRIBUTING.md)

## 许可证

NimVoice 使用 [MIT License](./LICENSE)。

第三方模型和运行时许可证信息见 [MODEL_LICENSES.md](./MODEL_LICENSES.md)。
