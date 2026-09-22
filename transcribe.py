#!/usr/bin/env /Users/dmg/git.dmg/transcription_scripts/.venv/bin/python3
"""Transcribe audio files with speaker diarization using WhisperX + pyannote."""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

# whisperx defaults to 4 threads regardless of machine size; leave two cores
# for the OS and for the torch-based alignment and diarization stages.
DEFAULT_THREADS = max(1, (os.cpu_count() or 4) - 2)


def get_hf_token() -> str:
    result = subprocess.run(
        ["gpg", "--decrypt", str(Path.home() / ".authinfo.gpg")],
        capture_output=True, text=True
    )
    for line in result.stdout.splitlines():
        parts = line.split()
        if "huggingface.co" in parts:
            idx = parts.index("password")
            return parts[idx + 1]
    raise RuntimeError("HuggingFace token not found in ~/.authinfo.gpg")


def transcribe(audio_path: Path, hf_token: str, model: str, device: str, min_speakers: int | None, max_speakers: int | None, checkpoint_dir: Path, force: bool = False, compute_type: str = "int8", threads: int = 4, language: str | None = None, batch_size: int = 8, diarize: bool = True, diarize_device: str | None = None, timestamps: bool = False, label: str = "SPEAKER") -> str:
    import whisperx

    checkpoint_dir.mkdir(parents=True, exist_ok=True)
    asr_checkpoint = checkpoint_dir / f"{audio_path.stem}_asr.json"
    aligned_checkpoint = checkpoint_dir / f"{audio_path.stem}_aligned.json"

    audio = whisperx.load_audio(str(audio_path))

    if not force and asr_checkpoint.exists():
        print(f"Loading ASR checkpoint: {asr_checkpoint}")
        asr_result = json.loads(asr_checkpoint.read_text())
    else:
        print(f"Loading model {model} ({compute_type}, {threads} threads)...")
        # Passing language= skips per-file detection, which costs several
        # seconds and misfires badly on files that open with silence.
        asr_model = whisperx.load_model(model, device, compute_type=compute_type,
                                        threads=threads, language=language)
        print(f"Transcribing {audio_path.name}...")
        asr_result = asr_model.transcribe(audio, batch_size=batch_size)
        asr_checkpoint.write_text(json.dumps(asr_result))
        print(f"  Checkpoint saved: {asr_checkpoint}")

    if not force and aligned_checkpoint.exists():
        print(f"Loading alignment checkpoint: {aligned_checkpoint}")
        result = json.loads(aligned_checkpoint.read_text())
    else:
        print("Aligning timestamps...")
        align_model, metadata = whisperx.load_align_model(
            language_code=asr_result["language"], device=device
        )
        result = whisperx.align(asr_result["segments"], align_model, metadata, audio, device)
        aligned_checkpoint.write_text(json.dumps(result))
        print(f"  Checkpoint saved: {aligned_checkpoint}")

    # Diarization is the most expensive stage by far — roughly half the runtime
    # on a one-minute clip, and it scales worse than linearly. Skip it for
    # single-speaker recordings.
    if not diarize:
        print("Skipping speaker diarization (--no-diarize)")
        return format_transcript(result["segments"], with_speakers=False, timestamps=timestamps, label=label)

    # pyannote runs in plain torch, so unlike the ctranslate2 ASR stage it can
    # use the Apple GPU: measured 9.5s on mps against 37.8s on cpu for one
    # minute of audio, with identical segments and speakers.
    import torch
    if diarize_device is None:
        diarize_device = "mps" if torch.backends.mps.is_available() else device

    from whisperx.diarize import DiarizationPipeline
    diarize_kwargs = {}
    if min_speakers is not None:
        diarize_kwargs["min_speakers"] = min_speakers
    if max_speakers is not None:
        diarize_kwargs["max_speakers"] = max_speakers

    for attempt_device in [diarize_device, device] if diarize_device != device else [device]:
        print(f"Running speaker diarization on {attempt_device}...")
        try:
            diarize_model = DiarizationPipeline(model_name="pyannote/speaker-diarization-3.1", token=hf_token, device=attempt_device)
            diarize_segments = diarize_model(audio, **diarize_kwargs)
            break
        except Exception as e:
            # An unsupported op on mps must not cost the transcript: fall back
            # to cpu, which is slower but always works.
            print(f"  Diarization failed on {attempt_device} ({type(e).__name__}: {e}); retrying on {device}", file=sys.stderr)
    else:
        raise RuntimeError("diarization failed on all devices")

    result = whisperx.assign_word_speakers(diarize_segments, result)

    return format_transcript(result["segments"], timestamps=timestamps, label=label)


def format_timestamp(seconds: float) -> str:
    total = int(seconds)
    return f"{total // 3600:02d}:{total % 3600 // 60:02d}:{total % 60:02d}"


def format_transcript(segments: list, with_speakers: bool = True, timestamps: bool = False, label: str = "SPEAKER") -> str:
    if timestamps:
        # One line per segment rather than per speaker run, so transcripts of
        # two tracks recorded together can be interleaved by sorting on time.
        lines = []
        for seg in segments:
            text = seg.get("text", "").strip()
            if not text:
                continue
            who = seg.get("speaker", label) if with_speakers else label
            lines.append(f"[{format_timestamp(seg.get('start', 0))}] **{who}**: {text}")
        return "\n".join(lines) + "\n" if lines else ""

    if not with_speakers:
        text = " ".join(
            seg.get("text", "").strip() for seg in segments if seg.get("text", "").strip()
        )
        return text + "\n" if text else ""

    lines = []
    current_speaker = None
    current_text = []

    for seg in segments:
        speaker = seg.get("speaker", "UNKNOWN")
        text = seg.get("text", "").strip()
        if not text:
            continue
        if speaker != current_speaker:
            if current_text:
                lines.append(f"**{current_speaker}**: {' '.join(current_text)}\n")
            current_speaker = speaker
            current_text = [text]
        else:
            current_text.append(text)

    if current_text:
        lines.append(f"**{current_speaker}**: {' '.join(current_text)}\n")

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Transcribe audio with speaker diarization")
    parser.add_argument("files", nargs="+", type=Path, help="Audio files to transcribe")
    parser.add_argument("--model", default="large-v2", help="Whisper model (default: large-v2)")
    parser.add_argument("--device", default="cpu", help="Device: cpu or cuda (default: cpu)")
    parser.add_argument("--compute-type", default="int8",
                        help="ctranslate2 compute type: int8, float16, float32 (default: int8). "
                             "int8 measured ~41%% less peak RAM than float32 on CPU with no output change")
    parser.add_argument("--threads", type=int, default=DEFAULT_THREADS,
                        help=f"CPU threads for ASR (default: {DEFAULT_THREADS}; whisperx itself defaults to 4)")
    parser.add_argument("--language", help="Language code, e.g. en (default: auto-detect per file). "
                                          "Pinning it skips detection, which is slow and unreliable on files that start with silence")
    parser.add_argument("--batch-size", type=int, default=8,
                        help="ASR batch size (default: 8). Lower it to cut peak memory")
    parser.add_argument("--no-diarize", action="store_true",
                        help="Skip speaker diarization, the slowest stage. Output has no speaker labels")
    parser.add_argument("--diarize-device",
                        help="Device for diarization (default: mps when available, else --device). "
                             "pyannote is ~4x faster on the Apple GPU; falls back to cpu on failure")
    parser.add_argument("--timestamps", action="store_true",
                        help="Prefix each segment with [HH:MM:SS]. One line per segment, so "
                             "transcripts of two tracks recorded together can be merged by time")
    parser.add_argument("--label", default="SPEAKER",
                        help="Speaker label to use when diarization is off (default: SPEAKER)")
    parser.add_argument("--output-dir", type=Path, help="Output directory (default: same as input)")
    parser.add_argument("--min-speakers", type=int, help="Minimum number of speakers (default: auto)")
    parser.add_argument("--max-speakers", type=int, help="Maximum number of speakers (default: auto)")
    parser.add_argument("--checkpoint-dir", type=Path, default=Path("/tmp/transcribe"),
                        help="Directory for intermediate checkpoints (default: /tmp/transcribe)")
    parser.add_argument("--force", action="store_true",
                        help="Ignore and overwrite existing checkpoints")
    parser.add_argument("--overwrite", action="store_true",
                        help="Overwrite existing transcript output files")
    args = parser.parse_args()

    hf_token = get_hf_token()

    audio_extensions = {".wav", ".mp3", ".m4a", ".flac", ".ogg", ".opus", ".aac", ".wma"}

    for audio_path in args.files:
        if not audio_path.exists():
            print(f"Error: {audio_path}: file not found", file=sys.stderr)
            continue
        if not audio_path.is_file():
            print(f"Error: {audio_path}: is a directory, not an audio file", file=sys.stderr)
            continue
        if audio_path.suffix.lower() not in audio_extensions:
            print(f"Error: {audio_path}: not a recognized audio file (got {audio_path.suffix!r}, expected one of {', '.join(sorted(audio_extensions))})", file=sys.stderr)
            continue

        out_dir = args.output_dir or audio_path.parent
        out_path = out_dir / (audio_path.stem + ".md")

        if out_path.exists() and not args.overwrite:
            print(f"Skipping {audio_path.name}: transcript already exists at {out_path} (use --overwrite to replace)")
            continue

        try:
            transcript = transcribe(audio_path, hf_token, args.model, args.device, args.min_speakers, args.max_speakers, args.checkpoint_dir, args.force,
                                    compute_type=args.compute_type, threads=args.threads,
                                    language=args.language, batch_size=args.batch_size,
                                    diarize=not args.no_diarize, diarize_device=args.diarize_device,
                                    timestamps=args.timestamps, label=args.label)
            out_path.write_text(transcript)
            print(f"Saved: {out_path}")
        except Exception as e:
            print(f"Failed {audio_path.name}: {e}", file=sys.stderr)


if __name__ == "__main__":
    main()
