import i18n from 'i18next';
import { initReactI18next } from 'react-i18next';

const resources = {
  en: {
    translation: {
      title: "NimVoice TTS",
      enterText: "Enter text to synthesize:",
      device: "Vocoder Device:",
      synthesize: "Synthesize to WAV",
      synthesizing: "Synthesizing... Please wait.",
      play: "Play Audio",
      done: "Done! Audio saved.",
      error: "Error",
      ready: "Ready.",
      noAudio: "Output file not found. Please synthesize first.",
      language: "Language",
    }
  },
  zh: {
    translation: {
      title: "NimVoice 语音合成",
      enterText: "输入要合成的文本：",
      device: "Vocoder 推理设备：",
      synthesize: "合成语音",
      synthesizing: "正在合成...请稍候。",
      play: "播放音频",
      done: "完成！音频已保存。",
      error: "错误",
      ready: "就绪。",
      noAudio: "未找到输出文件。请先合成语音。",
      language: "语言",
    }
  }
};

i18n
  .use(initReactI18next)
  .init({
    resources,
    lng: "zh",
    fallbackLng: "en",
    interpolation: {
      escapeValue: false
    }
  });

export default i18n;
