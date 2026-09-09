# Talkist

Talkist is a local-only push-to-talk dictation utility. Hold a global hotkey,
speak, release it, and the transcript is pasted at the cursor.

The current Linux build uses NVIDIA Parakeet through sherpa-onnx. There are no
accounts, cloud transcription, agents, or telemetry.

## Current platform

- Debian 13, amd64
- GNOME X11
- Default hotkey: `F9`

The model downloads on first launch and runs entirely on the local machine.
