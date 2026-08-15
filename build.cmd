@echo off
setlocal
set "ROOT=%~dp0"
set "NPM_CMD="
set "PORTABLE_NODE_DIR=%ROOT%node-v20.11.1-win-x64"

pushd "%ROOT%"

echo ========================================================
echo Building NimVoice - Pure Nim TTS with Intel NPU Support
echo ========================================================

if not exist "bin" mkdir "bin"

where npm >nul 2>nul
if %ERRORLEVEL% equ 0 (
    set "NPM_CMD=npm"
) else if exist "%PORTABLE_NODE_DIR%\npm.cmd" (
    set "NPM_CMD=%PORTABLE_NODE_DIR%\npm.cmd"
    set "PATH=%PORTABLE_NODE_DIR%;%PATH%"
)

echo [1/4] Building Electron GUI ...
if exist "%ROOT%electron-gui" (
    if defined NPM_CMD (
        pushd "%ROOT%electron-gui"
        call "%NPM_CMD%" install
        if %ERRORLEVEL% neq 0 (
            popd
            goto :build_failed
        )
        call "%NPM_CMD%" run build
        if %ERRORLEVEL% neq 0 (
            popd
            goto :build_failed
        )
        popd
    ) else (
        echo [WARN] npm was not found. Skipping Electron GUI build.
        echo [WARN] Install Node.js or keep portable Node at node-v20.11.1-win-x64 to enable GUI packaging.
    )
) else (
    echo [INFO] electron-gui folder not found. Skipping GUI build.
)

echo [2/4] Compiling resources ...
windres resources.rc -O coff -o resources.res
if %ERRORLEVEL% neq 0 goto :build_failed

echo [3/4] Compiling src/main.nim ...
nim c -d:release -d:danger --nimcache:nimcache --passL:resources.res -o:bin/nimvoice.exe src/main.nim
if %ERRORLEVEL% neq 0 goto :build_failed

echo [4/4] Copying OpenVINO runtime DLLs ...
copy /Y ".venv\Lib\site-packages\openvino\libs\*.dll" "bin\" >nul
if %ERRORLEVEL% neq 0 goto :build_failed

echo.
echo ========================================================
echo Build Successful!
echo Executable is located at: bin\nimvoice.exe
echo You can now use run.cmd to generate speech.
echo ========================================================
popd
exit /b 0

:build_failed
echo.
echo [ERROR] Build failed! Please check the output above.
popd
exit /b 1
