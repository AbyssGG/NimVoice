import app
import std/os
import std/strutils

# Compile the PERF_COUNT C wrapper directly into the executable. This avoids
# shipping an extra DLL and, more importantly, gives us a non-variadic C
# entry point that the Nim FFI can call without fighting the x64 Windows
# variadic ABI.
{.compile: "openvino/perf_count_wrapper.c".}

proc main() =
  let args = commandLineParams()
  var command = "speak"
  var requestedDevice = "AUTO"
  var text = DefaultText
  var warmRuns = 2
  var volume = 1.0
  var speed = 1.0
  var pitch = 1.0
  var lang = "en"

  var startIndex = 0
  if args.len > 0 and args[0].toLowerAscii() == "bench":
    command = "bench"
    startIndex = 1

  var i = startIndex
  while i < args.len:
    let arg = args[i]
    if arg.startsWith("--device="):
      requestedDevice = arg.split("=", 1)[1].toUpperAscii()
    elif arg == "--device" and i + 1 < args.len:
      requestedDevice = args[i + 1].toUpperAscii()
      i += 1
    elif arg.startsWith("--warm-runs="):
      try:
        warmRuns = max(0, parseInt(arg.split("=", 1)[1]))
      except ValueError:
        discard
    elif arg == "--warm-runs" and i + 1 < args.len:
      try:
        warmRuns = max(0, parseInt(args[i + 1]))
      except ValueError:
        discard
      i += 1
    elif arg.startsWith("--volume="):
      try: volume = parseFloat(arg.split("=", 1)[1])
      except ValueError: discard
    elif arg.startsWith("--speed="):
      try: speed = parseFloat(arg.split("=", 1)[1])
      except ValueError: discard
    elif arg.startsWith("--pitch="):
      try: pitch = parseFloat(arg.split("=", 1)[1])
      except ValueError: discard
    elif arg.startsWith("--lang="):
      lang = arg.split("=", 1)[1]
    else:
      text = arg
    i += 1

  # Top-level error funnel: any exception (preflight miss, OpenVINO init
  # failure, runtime synthesis error) is caught here and reported as a
  # single clear message. Without this, a missing model file would show up
  # as a stack trace dump which is hostile to non-developer users.
  try:
    if command == "bench":
      runBenchmarkCommand(text, warmRuns, lang)
    else:
      runSynthesisCommand(text, requestedDevice, DefaultOutputPath, volume, speed, pitch, lang)
  except ValueError as e:
    # User-input / preflight errors: print and exit cleanly.
    echo "[ERROR] ", e.msg
    quit(2)
  except CatchableError as e:
    echo "[ERROR] Internal failure: ", e.msg
    echo "Run `bin\\nimvoice.exe bench --warm-runs=0` to confirm hardware health."
    quit(1)

when isMainModule:
  main()
