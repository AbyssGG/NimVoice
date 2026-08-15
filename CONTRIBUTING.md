# Contributing to NimVoice

Thanks for your interest in contributing.

## Project Principles

- Keep runtime inference fully offline.
- Do not introduce a Python runtime dependency for end users.
- Treat Intel NPU support as a first-class requirement.
- Prefer small, explicit changes over broad rewrites.
- Avoid mixing app logic with low-level OpenVINO wrapper concerns.

## Development Expectations

- Keep the repository clean and do not commit local build outputs.
- Do not commit `bin/`, `.venv/`, `node_modules/`, `.dbg/`, or `nimcache/`.
- Update documentation when behavior or build steps change.
- Keep English as the primary documentation language in the repository root.

## Before Opening a Pull Request

1. Build the native app with `build.cmd`.
2. Smoke-test the CLI path with `run.cmd "Hello world"`.
3. If you touched benchmarking or profiling logic, verify `bench` mode still runs.
4. If you changed model behavior, document any known limitations in `README.md` or `TROUBLESHOOTING.md`.

## Scope Boundaries

Contributions are welcome for:

- Nim runtime code
- OpenVINO integration
- Intel NPU support
- GUI integration
- documentation and build tooling

Please avoid unrelated dependency churn or introducing cloud-only features.
