# Validation

Validated on an Apple Silicon Mac with 16GB memory. The macOS 14 deployment target does not imply testing on every supported OS release.

- Clean source build using the pinned upstream whisper.cpp revision.
- Audio pipeline self-tests and polishing queue/context/naming tests pass.
- Model catalog validates the known digest and rejects an incorrect digest.
- Native settings UI exposes both model catalogs; switching Small to Tiny and back successfully updates the active speech engine.
- Whisper Tiny downloaded, verified, loaded and ran offline inference.
- The alternative Qwen 2.5 1.5B model downloaded through Ollama, verified its layers and generated a valid short context name.
- Small and Qwen3 4B were previously exercised with synthetic Chinese, English and mixed-language speech.
- Base is offered with its upstream checksum; its accuracy and runtime have not been independently benchmarked here.

Downloads and inference tests use synthetic inputs only. Runtime logs, model weights, saved contexts and recordings are not part of this repository. A microphone permission grant and actual speaking test must be performed locally by the user.

Switching controls are disabled while their engine is in use. Failed candidate preparation leaves the previous selection active. Multi-hour endurance, all dialects, power consumption and thermal performance have not been tested.
