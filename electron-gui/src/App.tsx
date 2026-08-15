import { useState, useRef, useEffect } from 'react';
import { useTranslation } from 'react-i18next';

function App() {
  const { t, i18n } = useTranslation();
  const [text, setText] = useState('');
  const [logs, setLogs] = useState([t('ready') || 'Ready']);
  const [isSynthesizing, setIsSynthesizing] = useState(false);
  const [audioUrl, setAudioUrl] = useState<string | null>(null);
  
  // Offline Options
  const [language] = useState('en-US');
  const [voice, setVoice] = useState('default');
  const [quality, setQuality] = useState('high');
  const [emotion, setEmotion] = useState('neutral');
  const [pauseDelay, setPauseDelay] = useState(1.0);
  const [emotionIntensity, setEmotionIntensity] = useState(1.0);
  const [volume, setVolume] = useState(1.0);
  const [speed, setSpeed] = useState(1.0);
  const [pitch, setPitch] = useState(1.0);

  const logEndRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    logEndRef.current?.scrollIntoView({ behavior: 'smooth' });
  }, [logs]);

  const toggleLanguage = () => {
    i18n.changeLanguage(i18n.language === 'zh' ? 'en' : 'zh');
    setLogs(prev => [...prev, i18n.language === 'zh' ? 'Language switched to English' : '已切换至中文']);
  };

  const appendLog = (msg: string) => {
    setLogs(prev => [...prev, msg]);
  };

  const handleSynthesize = async () => {
    if (!text.trim()) return;
    
    setIsSynthesizing(true);
    setAudioUrl(null);
    appendLog(t('synthesizing') || 'Synthesizing...');

    try {
      // @ts-expect-error window.api is injected via preload
      const result = await window.api.synthesize({
        text, 
        device: 'NPU',
        volume,
        speed,
        pitch,
        language
      });
      if (result.success) {
        appendLog(result.stdout);
        appendLog(t('done') || 'Done');
        if (result.audioData) {
          setAudioUrl(result.audioData);
        }
      } else {
        appendLog(`${t('error') || 'Error'}: ${result.error}\n${result.stderr}`);
      }
    } catch (err: unknown) {
      appendLog(`${t('error') || 'Error'}: ${(err as Error).message}`);
    } finally {
      setIsSynthesizing(false);
    }
  };

  return (
    <div className="h-screen bg-gray-50 flex flex-col items-center p-4 overflow-hidden">
      <div className="w-full max-w-6xl h-full bg-white rounded-xl shadow-lg p-6 flex flex-col space-y-4">
        
        {/* Header */}
        <div className="flex justify-between items-center border-b pb-4">
          <h1 className="text-2xl font-bold text-gray-800">{t('title') || 'NimVoice (Pure Offline NPU)'}</h1>
          <button 
            onClick={toggleLanguage}
            className="px-4 py-2 text-sm font-medium text-blue-600 bg-blue-50 rounded-lg hover:bg-blue-100 transition"
          >
            {i18n.language === 'zh' ? 'English' : '中文'}
          </button>
        </div>

        <div className="flex flex-row space-x-6 flex-1 min-h-0">
          
          {/* Main Area: Text and Options */}
          <div className="flex-1 flex flex-col space-y-4 overflow-y-auto pr-2">
            
            {/* Options Grid */}
            <div className="grid grid-cols-2 md:grid-cols-3 gap-4 p-4 bg-gray-50 rounded-lg border">
              
              <div className="flex flex-col">
                <label className="text-xs font-semibold text-gray-600 mb-1">引擎 (Engine)</label>
                <select disabled className="p-1 border rounded text-sm bg-gray-100 text-gray-500">
                  <option>Offline - NimVoice NPU</option>
                </select>
              </div>

              <div className="flex flex-col">
                <label className="text-xs font-semibold text-gray-600 mb-1">语言 (Language)</label>
                <select value={language} disabled className="p-1 border rounded text-sm bg-gray-100 text-gray-500">
                  <option value="en-US">English Only (Open Source)</option>
                </select>
              </div>

              <div className="flex flex-col">
                <label className="text-xs font-semibold text-gray-600 mb-1">语音/音色 (Voice)</label>
                <select value={voice} onChange={e => setVoice(e.target.value)} className="p-1 border rounded text-sm">
                  <option value="default">Default</option>
                </select>
              </div>

              <div className="flex flex-col">
                <label className="text-xs font-semibold text-gray-600 mb-1">音频质量 (Quality)</label>
                <select value={quality} onChange={e => setQuality(e.target.value)} className="p-1 border rounded text-sm">
                  <option value="high">High</option>
                  <option value="medium">Medium</option>
                  <option value="low">Low</option>
                </select>
              </div>

              <div className="flex flex-col">
                <label className="text-xs font-semibold text-gray-600 mb-1">感情 (Emotion)</label>
                <select value={emotion} onChange={e => setEmotion(e.target.value)} className="p-1 border rounded text-sm">
                  <option value="neutral">Neutral</option>
                  <option value="happy">Happy</option>
                  <option value="sad">Sad</option>
                  <option value="angry">Angry</option>
                </select>
              </div>

              <div className="flex flex-col">
                <label className="text-xs font-semibold text-gray-600 mb-1">情感强度 (Emotion Int.)</label>
                <input type="range" min="0" max="2" step="0.1" value={emotionIntensity} onChange={e => setEmotionIntensity(parseFloat(e.target.value))} />
                <span className="text-xs text-right text-gray-500">{emotionIntensity.toFixed(1)}</span>
              </div>

              <div className="flex flex-col">
                <label className="text-xs font-semibold text-gray-600 mb-1">标点停顿 (Pause Delay)</label>
                <input type="range" min="0" max="3" step="0.1" value={pauseDelay} onChange={e => setPauseDelay(parseFloat(e.target.value))} />
                <span className="text-xs text-right text-gray-500">{pauseDelay.toFixed(1)}s</span>
              </div>

              <div className="flex flex-col">
                <label className="text-xs font-semibold text-gray-600 mb-1">音量 (Volume)</label>
                <input type="range" min="0" max="2" step="0.1" value={volume} onChange={e => setVolume(parseFloat(e.target.value))} />
                <span className="text-xs text-right text-gray-500">{volume.toFixed(1)}</span>
              </div>

              <div className="flex flex-col">
                <label className="text-xs font-semibold text-gray-600 mb-1">语速 (Speed)</label>
                <input type="range" min="0.5" max="2" step="0.1" value={speed} onChange={e => setSpeed(parseFloat(e.target.value))} />
                <span className="text-xs text-right text-gray-500">{speed.toFixed(1)}x</span>
              </div>

              <div className="flex flex-col">
                <label className="text-xs font-semibold text-gray-600 mb-1">音调 (Pitch)</label>
                <input type="range" min="0.5" max="2" step="0.1" value={pitch} onChange={e => setPitch(parseFloat(e.target.value))} />
                <span className="text-xs text-right text-gray-500">{pitch.toFixed(1)}x</span>
              </div>

            </div>

            {/* Text Input */}
            <div className="flex-none space-y-2">
              <label className="block text-sm font-medium text-gray-700">{t('enterText') || 'Enter text'}</label>
              <textarea 
                className="w-full h-32 p-4 text-lg border border-gray-300 rounded-lg focus:ring-2 focus:ring-blue-500 focus:border-blue-500 resize-none outline-none"
                value={text}
                onChange={(e) => setText(e.target.value)}
                placeholder="Hello world!"
              />
            </div>

            {/* Controls */}
            <div className="flex-none flex justify-end">
              <button 
                onClick={handleSynthesize}
                disabled={isSynthesizing || !text.trim()}
                className="w-full sm:w-auto px-6 py-3 bg-blue-600 text-white font-medium rounded-lg hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed transition flex items-center justify-center"
              >
                {isSynthesizing ? (
                  <svg className="animate-spin -ml-1 mr-3 h-5 w-5 text-white" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                    <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"></circle>
                    <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                  </svg>
                ) : null}
                {t('synthesize') || 'Synthesize'}
              </button>
            </div>

            {/* Audio Player */}
            <div className="flex-none space-y-2 pt-4 border-t">
              <label className="block text-sm font-medium text-gray-700">{t('play') || 'Play Audio'}</label>
              <div className="bg-gray-50 p-4 rounded-lg border border-gray-200 flex items-center justify-center">
                {audioUrl ? (
                  <audio controls src={audioUrl} className="w-full max-w-md" />
                ) : (
                  <span className="text-gray-400 text-sm">{t('noAudio') || 'No audio generated yet'}</span>
                )}
              </div>
            </div>

          </div>

          {/* Logs Panel */}
          <div className="w-1/3 flex flex-col border-l pl-4">
            <label className="block text-sm font-medium text-gray-700 flex-none pb-2">Logs</label>
            <div className="flex-1 bg-gray-900 text-green-400 p-4 rounded-lg overflow-y-auto font-mono text-sm whitespace-pre-wrap">
              {logs.map((log, idx) => (
                <div key={idx}>{log}</div>
              ))}
              <div ref={logEndRef} />
            </div>
          </div>
        </div>

      </div>
    </div>
  );
}

export default App;
