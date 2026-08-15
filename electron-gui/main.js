import { app, BrowserWindow, ipcMain } from 'electron';
import path from 'path';
import { exec } from 'child_process';
import fs from 'fs';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const isDev = process.env.NODE_ENV === 'development';

let mainWindow;

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1280,
    height: 900,
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false
    }
  });

  if (isDev) {
    mainWindow.loadURL('http://localhost:5173');
    mainWindow.webContents.openDevTools();
  } else {
    mainWindow.loadFile(path.join(__dirname, 'dist', 'index.html'));
  }
}

app.whenReady().then(() => {
  createWindow();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

// IPC handler for fetching voices (offline, dummy for now)
ipcMain.handle('get-edge-voices', async () => {
  return { success: true, voices: [] };
});

// IPC handler for TTS synthesis
ipcMain.handle('synthesize', async (event, { text, device, volume, speed, pitch, language }) => {
  return new Promise(async (resolve, reject) => {
    // Pure offline NPU NimVoice engine
    const runCmdPath = path.join(__dirname, '..', 'run.cmd');
    
    let command = `"${runCmdPath}" "${text.replace(/"/g, '\\"')}" --device=${device || 'NPU'}`;
    if (volume !== undefined) command += ` --volume=${volume}`;
    if (speed !== undefined) command += ` --speed=${speed}`;
    if (pitch !== undefined) command += ` --pitch=${pitch}`;
    // Open-source release is temporarily English-only on the synthesis path.
    command += ` --lang=en`;
    
    console.log(`Executing: ${command}`);
    
    exec(command, { cwd: path.join(__dirname, '..') }, (error, stdout, stderr) => {
      if (error) {
        console.error(`Error: ${error.message}`);
        resolve({ success: false, error: error.message, stdout, stderr });
        return;
      }
      
      const wavPath = path.join(__dirname, '..', 'bin', 'output.wav');
      let audioData = null;
      if (fs.existsSync(wavPath)) {
        const buffer = fs.readFileSync(wavPath);
        audioData = `data:audio/wav;base64,${buffer.toString('base64')}`;
      }
      
      resolve({ success: true, stdout, stderr, audioData });
    });
  });
});
