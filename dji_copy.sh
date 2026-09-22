#!/bin/bash
# Copies DJI .WAV files to ~/temp/dji, merges split recordings, converts to MP3,
# transcribes them, and ejects the DJI volume.
# Usage: dji_copy.sh [delay_seconds]  (default: 10)
#
# Only the startup section aborts on error. Once the pipeline begins, every
# stage tolerates failure: a bad file or a missing tool produces a warning and
# the remaining stages still run. The one exception is a failed move off the
# card, where continuing risks losing recordings.

set -uo pipefail

notify() {
  osascript -e "display notification \"$2\" with title \"$1\"" || true
}

WARN_COUNT=0
WARN_SUMMARY=""

# Records a problem in the log and the end-of-run summary without interrupting
# the user. Use for per-file problems, which can be numerous.
note() {
  echo "WARN stage=$STAGE: $1" >&2
  (( WARN_COUNT++ )) || true
  WARN_SUMMARY+="  - [$STAGE] $1"$'\n'
}

# As note(), plus a desktop notification. Use for stage-level problems.
warn() {
  note "$1"
  notify "DJI Copy Warning" "$1"
}

LOCK_DIR=/tmp/dji-copy.lock
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  notify "DJI Copy Skipped" "Another copy is already running"
  exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

LOG=/tmp/dji-log.txt
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

STAGE="startup"
set -e
on_err() {
  local exit_code=$?
  local line=$1
  echo "ERROR: stage=$STAGE line=$line exit=$exit_code" >&2
  notify "DJI Copy Failed" "stage=$STAGE line=$line exit=$exit_code (see $LOG)"
  exit "$exit_code"
}
trap 'on_err $LINENO' ERR

echo "=== dji_copy.sh started $(date) pid=$$ ==="

DELAY=${1:-10}
SRC="/Volumes/NO NAME/DJI_Audio_001"
DEST="$HOME/temp/dji"
VOLUME="/Volumes/NO NAME"

# Mic records timestamps in UTC; adjust filename to local time.
# Negative = subtract from the mic-reported time.
FILE_TZ_HOURS_SHIFT=-15
FILE_MIN_DRIFT_SHIFT=1

# Gap (seconds) between end of one part and start of next that still counts
# as the same recording session. Accounts for device split overhead + drift.
GAP_THRESHOLD_SECONDS=5

# End of the startup section: from here on, stages report failures and continue.
trap - ERR
set +e

STAGE="initial-sleep"
sleep "$DELAY"

STAGE="check-source"
SRC_PRESENT=true
if [[ ! -d "$SRC" ]]; then
  echo "STAGE check-source: source not mounted at $SRC — skipping move/eject"
  SRC_PRESENT=false
fi

if ! mkdir -p "$DEST"; then
  echo "ERROR: cannot create $DEST" >&2
  notify "DJI Copy Failed" "Cannot create $DEST"
  exit 1
fi

if $SRC_PRESENT; then
  shopt -s nullglob
  wav_files=("$SRC"/*.WAV)
  echo "STAGE move: ${#wav_files[@]} source .WAV file(s) found"

  if [[ ${#wav_files[@]} -eq 0 ]]; then
    notify "DJI Copy" "No .WAV files found in $SRC"
  else
    STAGE="move-files"
    hours_flag=$(printf -- "-v%+dH" "$FILE_TZ_HOURS_SHIFT")
    min_flag=$(printf -- "-v%+dM" "$FILE_MIN_DRIFT_SHIFT")
    moved=0
    for src_file in "${wav_files[@]}"; do
      base=$(basename "$src_file")
      # Strip the _XX_ track number and shift timestamp from mic-UTC to local.
      # DJI_01_20251116_040052.WAV → DJI_<shifted YYYYMMDD>_<shifted HHMMSS>.WAV
      if [[ "$base" =~ ^DJI_[0-9]+_([0-9]{8})_([0-9]{6})\.WAV$ ]]; then
        date_part="${BASH_REMATCH[1]}"
        time_part="${BASH_REMATCH[2]}"
        adjusted=$(date -j "$hours_flag" "$min_flag" -f "%Y%m%d %H%M%S" "$date_part $time_part" "+%Y%m%d_%H%M%S")
        new_name="DJI_${adjusted}.WAV"
      else
        new_name=$(sed -E 's/^DJI_[0-9]+_/DJI_/' <<< "$base")
      fi
      if mv "$src_file" "$DEST/$new_name"; then
        (( moved++ )) || true
      else
        notify "DJI Copy Failed" "Could not move $base"
        exit 1
      fi
    done
    notify "DJI Copy" "Moved $moved .WAV file(s) to $DEST"
  fi
fi

# Merge contiguous parts of the same recording session.
# Two files belong to the same session when next.start - prev.end <= GAP_THRESHOLD_SECONDS.
# Runs against ALL un-merged DJI_YYYYMMDD_HHMMSS.WAV files in $DEST so leftover
# groups from a prior run also get merged before transcription.
STAGE="merge-scan"
PARTS_DIR="$DEST/parts"
shopt -s nullglob
mergeable=()
for f in "$DEST"/DJI_*.WAV; do
  fname=$(basename "$f")
  [[ "$fname" =~ ^DJI_[0-9]{8}_[0-9]{6}\.WAV$ ]] || continue
  mergeable+=("$f")
done
echo "STAGE merge-scan: ${#mergeable[@]} candidate file(s)"

if (( ${#mergeable[@]} > 1 )) && ! mkdir -p "$PARTS_DIR"; then
  warn "Cannot create $PARTS_DIR; skipping merge"
  mergeable=()
fi

if (( ${#mergeable[@]} > 1 )); then
  STAGE="merge-probe"
  entries=()
  for path in "${mergeable[@]}"; do
    fname=$(basename "$path")
    [[ "$fname" =~ ^DJI_([0-9]{8})_([0-9]{6})\.WAV$ ]] || continue
    d="${BASH_REMATCH[1]}"
    t="${BASH_REMATCH[2]}"
    if ! start_epoch=$(date -j -f "%Y%m%d %H%M%S" "$d $t" "+%s"); then
      note "unparsable timestamp, skipping: $fname"
      continue
    fi
    # ffprobe failures are tolerated: the file is left out of the merge and
    # still reaches the MP3 and transcription stages on its own.
    dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$path" | awk '{printf "%.0f", $1}') || dur=""
    if [[ -z "$dur" || "$dur" == "0" ]]; then
      note "no duration, excluded from merge: $fname"
      continue
    fi
    entries+=("$start_epoch|$dur|$path")
  done

  echo "STAGE merge-probe: ${#entries[@]} probed file(s)"
  sorted=()
  if (( ${#entries[@]} > 0 )); then
    IFS=$'\n' sorted=($(printf '%s\n' "${entries[@]}" | sort -n))
    unset IFS
  else
    note "no probeable files; skipping merge"
  fi

  # Walk sorted list, accumulating groups and flushing inline.
  group=()
  group_end=0
  merged_count=0
  # Extra entry to force the final flush. The ${a[@]+"${a[@]}"} form is needed
  # because bash 3.2 (the macOS /bin/bash) treats an empty array as unset under
  # set -u.
  sorted_plus=(${sorted[@]+"${sorted[@]}"} "SENTINEL")

  for entry in "${sorted_plus[@]}"; do
    if [[ "$entry" == "SENTINEL" ]]; then
      start=$(( group_end + GAP_THRESHOLD_SECONDS + 1 ))
      dur=0
      path=""
    else
      IFS='|' read -r start dur path <<< "$entry"
    fi

    if (( ${#group[@]} > 0 )) && (( start - group_end > GAP_THRESHOLD_SECONDS )); then
      # Flush the current group.
      if (( ${#group[@]} > 1 )); then
        first="${group[0]}"
        first_stem=$(basename "$first" .WAV)
        merged="$DEST/${first_stem}-merged.WAV"
        STAGE="merge-ffmpeg:${first_stem}"
        if ! list=$(mktemp -t dji_concat); then
          warn "mktemp failed; cannot merge ${first_stem}"
        else
          for p in "${group[@]}"; do
            printf "file '%s'\n" "$p" >> "$list"
          done
          echo "STAGE merge-ffmpeg: merging ${#group[@]} part(s) into $merged"
          if ffmpeg -f concat -safe 0 -i "$list" -c copy -y "$merged"; then
            for p in "${group[@]}"; do
              mv "$p" "$PARTS_DIR/" || note "could not move part to $PARTS_DIR: $p"
            done
            (( merged_count++ )) || true
          else
            warn "Merge failed for ${first_stem}"
          fi
          rm -f "$list"
        fi
      fi
      group=()
    fi

    if [[ -n "$path" ]]; then
      group+=("$path")
      group_end=$(( start + dur ))
    fi
  done

  if (( merged_count > 0 )); then
    notify "DJI Copy" "Merged $merged_count session(s); parts in $PARTS_DIR"
  fi
fi

# Eject the volume (only if the drive was actually present this run)
STAGE="eject"
if $SRC_PRESENT; then
  if diskutil eject "$VOLUME"; then
    notify "DJI Copy" "Volume ejected"
  else
    warn "Could not eject $VOLUME"
  fi
fi

# Convert any .WAV files missing an .mp3 counterpart
STAGE="mp3-convert"
shopt -s nullglob
converted=0
failed=0
for wav in "$DEST"/*.WAV; do
  mp3="${wav%.WAV}.mp3"
  if [[ ! -f "$mp3" ]]; then
    if ffmpeg -i "$wav" -b:a 128k -y "$mp3" &>/dev/null; then
      (( converted++ )) || true
    else
      # Discard the partial output so the next run retries this file.
      rm -f "$mp3"
      note "MP3 conversion failed: $(basename "$wav")"
      (( failed++ )) || true
    fi
  fi
done

if (( failed > 0 )); then
  notify "DJI Copy Warning" "MP3 conversion failed for $failed file(s)"
fi
if (( converted > 0 )); then
  notify "DJI Copy" "Converted $converted .WAV file(s) to MP3"
fi

# Transcribe any .WAV files missing a .md counterpart
STAGE="transcribe"
TRANSCRIBE="$HOME/git.dmg/transcription_scripts/transcribe.py"

# Language is auto-detected per file: recordings may be English, Spanish or
# Japanese. Detection costs a few seconds and is unreliable on silence, but the
# duration gate below keeps silent artifacts out of the pipeline entirely.
# Diarization stays on: some sessions have several speakers, and a missed
# speaker cannot be recovered from the transcript afterwards. transcribe.py has
# a --no-diarize flag for manual one-off runs, but it does not belong here.
TRANSCRIBE_ARGS=()

# A recording shorter than this is a mic-on artifact, not a session. Running the
# full pipeline on one wastes minutes and yields hallucinated text, because
# Whisper invents confident boilerplate when fed silence.
MIN_TRANSCRIBE_SECONDS=30

transcribed=0
tr_failed=0
tr_skipped=0
if [[ ! -x "$TRANSCRIBE" ]]; then
  warn "$TRANSCRIBE not executable; skipping transcription"
else
  for wav in "$DEST"/*.WAV; do
    md="${wav%.WAV}.md"
    if [[ ! -f "$md" ]]; then
      dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$wav" | awk '{printf "%.0f", $1}')
      if [[ -n "$dur" ]] && (( dur < MIN_TRANSCRIBE_SECONDS )); then
        echo "STAGE transcribe: skipping $(basename "$wav") (${dur}s < ${MIN_TRANSCRIBE_SECONDS}s)"
        (( tr_skipped++ )) || true
        continue
      fi
      # ${a[@]+"${a[@]}"} as elsewhere: bash 3.2 treats the empty array as unset under set -u.
      if "$TRANSCRIBE" "$wav" ${TRANSCRIBE_ARGS[@]+"${TRANSCRIBE_ARGS[@]}"} --output-dir "$DEST"; then
        (( transcribed++ )) || true
      else
        note "transcription failed: $(basename "$wav")"
        (( tr_failed++ )) || true
      fi
    fi
  done
fi

if (( tr_failed > 0 )); then
  notify "DJI Copy Warning" "Transcription failed for $tr_failed file(s)"
fi
if (( transcribed > 0 )); then
  notify "DJI Copy" "Transcribed $transcribed .WAV file(s)"
fi

STAGE="done"
if (( WARN_COUNT > 0 )); then
  echo "=== $WARN_COUNT warning(s) ==="
  printf '%s' "$WARN_SUMMARY"
fi
echo "=== dji_copy.sh finished $(date) with $WARN_COUNT warning(s) ==="
