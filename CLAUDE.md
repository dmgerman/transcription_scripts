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

On startup pyannote prints a long traceback about `libtorchcodec` failing to load: it looks for `libavutil.56` through `.59` (FFmpeg 4–7) and the installed FFmpeg is 9. This is harmless — audio is loaded via soundfile/librosa instead.

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

## Performance defaults

Measured on a 60-second clip with full diarization: 86.8s originally, 41.4s
after these changes, with byte-identical transcript text.

- `--compute-type int8` (default). Peak memory 5.01 GB against 8.55 GB for
  float32, with no change to the output.
- `--threads` defaults to `cpu_count - 2`. whisperx itself defaults to 4
  regardless of machine size.
- Diarization runs on **mps** by default and falls back to cpu on failure:
  9.5s against 37.8s for one minute of audio. pyannote is plain torch, so it
  can use the Apple GPU; the ctranslate2 ASR stage cannot and stays on cpu.
- Language is **auto-detected per file** — recordings may be English, Spanish
  or Japanese. Pinning `--language` is faster but wrong here.
- Diarization is **always on**. Some recordings have one speaker and some have
  several, and a speaker missed at transcription time cannot be recovered
  afterwards.

Checkpoints for the ASR and alignment stages are written to `/tmp/transcribe`,
so a re-run skips work already done. They are keyed on the filename only, not
on the settings, so `--force` is required after changing model or compute type.

Whisper hallucinates on silence — a silent clip reliably produces YouTube
subtitle boilerplate such as `谢谢大家`. `dji_copy.sh` therefore skips files
shorter than 30 seconds.

## On-computer recording

`local_record.sh` records Zoom/Teams/browser meetings as two tracks in
`~/temp/dji/local`, named `local_YYYYMMDD_HHMMSS[_name]_{remote,me}.WAV` to
mirror the DJI naming. Separate from `dji_copy.sh`, which handles the field
recorder; the `local/` subdirectory keeps these out of that script's glob.

The macOS side needs two devices, both from the `+` menu in Audio MIDI Setup:

- **`aggregate.dmg`** (has inputs — this is what gets recorded): BlackHole 2ch
  first, then MacBook Pro Microphone. Three channels total, so remote is
  `c0+c1` and the mic is `c2`. Enable Drift Correction on the mic.
- **`multioutput.dmg`** (output only — this is what you hear): headphones or
  AirPods plus BlackHole 2ch. Select it as the system output.

The system **input** must be MacBook Pro Microphone. Selecting the AirPods mic
forces Bluetooth into the headset profile, which is mono and narrowband in both
directions.

Constraints found by measurement, which the script's comments also record:

- It must be BlackHole **2ch**, not 16ch. Mic + 16ch BlackHole is 17 channels,
  and no capture path here reads that reliably.
- Capture is **ffmpeg**, not sox. sox's CoreAudio driver refuses three channels
  (`can't set 3 channels; using 2`) and then reads the interleaved stream at
  the wrong stride, so every channel comes back as the same mixture.
- `-t` does not stop an avfoundation input: its timestamps start at the device
  host clock, so the deadline never arrives. The script trims inside the filter
  graph with `asetpts=PTS-STARTPTS,atrim=duration=N`.
- Ctrl-C must reach ffmpeg itself. Killing only the wrapper leaves ffmpeg
  holding the device open, which truncates the files and starves the next
  recording of the microphone.
- The terminal app needs microphone permission in Privacy & Security. Without
  it macOS reports `Cannot use Aggregate Device` or hands back digital silence,
  neither of which looks like a permissions problem.

Check the setup with `./local_record.sh devices` and `./local_record.sh probe`.

At the end of a recording the two tracks are mixed into a single
`local_<stamp>.mp3` for listening, at the same 128k as `dji_copy.sh`. The
WAVs are kept: they are what the transcript is built from, and keeping them
apart is what lets diarization work on the remote speakers alone. `amix` runs
with `normalize=0`, since the default divides by the input count and leaves the
mix noticeably quiet.

`./local_record.sh transcribe [id]` transcribes both tracks of a recording and
merges them into `local_<stamp>.md`. The remote track gets full diarization
(`SPEAKER_00`, `SPEAKER_01`, ...); the mic track is one known person, so it
runs `--no-diarize --label DMG`. Both use `--timestamps`, which emits one
`[HH:MM:SS]`-prefixed line per segment, so the merge is a lexicographic sort —
valid only because the two tracks share one clock.

It then transcribes the mixed MP3 as a single stream into `<stamp>-joint.md`.
This is a cross-check, not the primary output: diarizing one mixed stream is
strictly harder than using the track each voice came from, and it shows —
on a 2.5-minute sample the per-track merge resolved five speakers where the
joint pass collapsed them into two. Its value is overlapping speech, which the
per-track pass splits into separate lines. `transcribe.py` names its output
after the input stem, which would collide with the merged transcript, so the
joint run writes to a scratch directory and the result is moved into place.
