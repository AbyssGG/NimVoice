@echo off
if not exist "bin\nimvoice.exe" (
    echo [ERROR] nimvoice.exe not found! Please compile the project first.
    exit /b 1
)

set "MODE=%~1"

if "%MODE%"=="" (
    echo No arguments provided. Starting modern GUI...
    call run-gui.cmd
    exit /b %ERRORLEVEL%
)

echo Running NimVoice...
echo Args: %*

cd bin
nimvoice.exe %*
set "EXITCODE=%ERRORLEVEL%"
cd ..

if not "%EXITCODE%"=="0" (
    exit /b %EXITCODE%
)

if /I not "%MODE%"=="bench" if exist "bin\output.wav" (
    echo.
    echo ========================================================
    echo Generation Complete!
    echo Output audio saved to: bin\output.wav
    echo ========================================================
)

if /I "%MODE%"=="bench" if exist "benchmark\results.md" (
    echo.
    echo ========================================================
    echo Benchmark Complete!
    echo Benchmark report saved to: benchmark\results.md
    echo ========================================================
)
