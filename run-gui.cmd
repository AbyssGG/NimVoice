@echo off
echo Starting NimVoice Electron GUI...

:: Set Node.js path for the portable version we downloaded
set "PATH=%CD%\node-v20.11.1-win-x64;%PATH%"

cd electron-gui
if not exist "node_modules" (
    echo [INFO] Installing dependencies for the first time...
    npm install
)

if not exist "dist" (
    echo [INFO] Building frontend for the first time...
    npm run build
)

set NODE_ENV=production
npx electron .
