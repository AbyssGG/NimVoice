# Model Licenses

The **NimVoice** source code itself is licensed under the MIT License. However, the AI models and vocabularies used by this application to generate speech are subject to their own respective licenses.

When distributing or using NimVoice, you must comply with the licenses of the models you choose to load into the `models/` directory.

## 1. SpeechT5 (Frontend)
SpeechT5 is used as the acoustic model (Text-to-Mel) in this project. The model architecture and original pre-trained weights were released by Microsoft.

*   **Original Creators:** Microsoft
*   **License:** [MIT License](https://github.com/microsoft/SpeechT5/blob/main/LICENSE)
*   **Source:** [Microsoft SpeechT5 on GitHub](https://github.com/microsoft/SpeechT5) / Hugging Face Model Hub

## 2. HiFi-GAN (Vocoder)
HiFi-GAN is used as the vocoder (Mel-to-Wav) backend, executed on the Intel NPU.

*   **Original Creators:** Jungil Kong, Jaehyeon Kim, and Jaekyoung Bae
*   **License:** [MIT License](https://github.com/jik876/hifi-gan/blob/master/LICENSE)
*   **Source:** [HiFi-GAN on GitHub](https://github.com/jik876/hifi-gan)

## 3. Speaker Embeddings
The default `speaker_embedding.raw` (derived from CMU ARCTIC or similar open datasets) is typically intended for research and educational purposes. If you substitute this with your own extracted speaker embeddings, ensure you have the rights or consent to use the voice data of the target speaker.

## 4. Piper / VITS (Alternative Models)
During the early development phases (Phase 3), the project experimented with Piper VITS models (e.g., `en-us-lessac-medium`). If you choose to use these models via the CPU fallback, please note:

*   **Dataset:** Blizzard Challenge 2013 (Lessac)
*   **License Restrictions:** Often restricted to non-commercial, academic, or personal use depending on the voice dataset. Please check `models/MODEL_CARD` for specific dataset terms.

---

**Disclaimer:** 
The developers of NimVoice do not claim ownership of any of the AI models. The `.onnx` files provided or generated for use with this software are derived works of the original repositories and are subject to their original licenses. Always verify the license of the specific weights you download from Hugging Face or other model hubs before using NimVoice in a commercial setting.
