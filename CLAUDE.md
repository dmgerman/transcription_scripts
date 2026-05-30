# Transcription

Audio transcription with speaker diarization using WhisperX + pyannote.

## Environment

All dependencies are isolated in `.venv/`. The shebang in `transcribe.py` points directly to `.venv/bin/python3` — do not change it to the system Python or dependencies will break.

The venv uses torch 2.8 (pinned by whisperx 3.8.6). The system Python uses torch 2.10. Do not run `pip install` outside the venv in this project.

## HuggingFace token

Read at runtime from `~/.authinfo.gpg` (entry: `machine huggingface.co login dmg`). Never hardcode it.

The following HuggingFace model agreements must be accepted by the account associated with the token:
- https://huggingface.co/pyannote/speaker-diarization-3.1
- https://huggingface.co/pyannote/segmentation-3.0
- https://huggingface.co/pyannote/speaker-diarization-community-1

## Known API quirks (whisperx 3.8.6)

- `DiarizationPipeline` is at `whisperx.diarize.DiarizationPipeline`, not `whisperx.DiarizationPipeline`
- Constructor takes `token=` not `use_auth_token=`
- Constructor takes `model_name=` — must pass `"pyannote/speaker-diarization-3.1"` explicitly, otherwise it defaults to the restricted `speaker-diarization-community-1`

## torchcodec warning

On startup pyannote warns that torchcodec cannot load because FFmpeg 8 is installed but torchcodec only supports FFmpeg 4–7. This is harmless — audio is loaded via soundfile/librosa instead.

## Usage

```bash
# Transcribe one or more files (output alongside input)
./transcribe.py ~/temp/dji/DJI_20260522_235201.WAV

# Transcribe to a specific output directory
./transcribe.py ~/temp/dji/*.WAV --output-dir /tmp

# Options
./transcribe.py --help
```

Output is a `.md` file with `**SPEAKER_00**:` / `**SPEAKER_01**:` labels. Files are skipped if a transcript already exists.

## Pending

- Add checkpoint saving between pipeline steps (transcription → alignment → diarization) to avoid re-doing work on re-runs.
