#!/usr/bin/env /Users/dmg/git.dmg/transcription_scripts/.venv/bin/python3
"""Transcribe audio files with speaker diarization using WhisperX + pyannote."""

import argparse
import json
import subprocess
import sys
from pathlib import Path


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


def transcribe(audio_path: Path, hf_token: str, model: str, device: str, min_speakers: int | None, max_speakers: int | None, checkpoint_dir: Path, force: bool = False) -> str:
    import whisperx

    checkpoint_dir.mkdir(parents=True, exist_ok=True)
    asr_checkpoint = checkpoint_dir / f"{audio_path.stem}_asr.json"
    aligned_checkpoint = checkpoint_dir / f"{audio_path.stem}_aligned.json"

    audio = whisperx.load_audio(str(audio_path))

    if not force and asr_checkpoint.exists():
        print(f"Loading ASR checkpoint: {asr_checkpoint}")
        asr_result = json.loads(asr_checkpoint.read_text())
    else:
        print(f"Loading model {model}...")
        asr_model = whisperx.load_model(model, device, compute_type="float32")
        print(f"Transcribing {audio_path.name}...")
        asr_result = asr_model.transcribe(audio, batch_size=8)
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

    print("Running speaker diarization...")
    from whisperx.diarize import DiarizationPipeline
    diarize_model = DiarizationPipeline(model_name="pyannote/speaker-diarization-3.1", token=hf_token, device=device)
    diarize_kwargs = {}
    if min_speakers is not None:
        diarize_kwargs["min_speakers"] = min_speakers
    if max_speakers is not None:
        diarize_kwargs["max_speakers"] = max_speakers
    diarize_segments = diarize_model(audio, **diarize_kwargs)
    result = whisperx.assign_word_speakers(diarize_segments, result)

    return format_transcript(result["segments"])


def format_transcript(segments: list) -> str:
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
            transcript = transcribe(audio_path, hf_token, args.model, args.device, args.min_speakers, args.max_speakers, args.checkpoint_dir, args.force)
            out_path.write_text(transcript)
            print(f"Saved: {out_path}")
        except Exception as e:
            print(f"Failed {audio_path.name}: {e}", file=sys.stderr)


if __name__ == "__main__":
    main()
