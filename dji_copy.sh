#!/bin/bash
# Copies DJI .WAV files to ~/temp/dji, launches TypeWhisper, and ejects the DJI volume.
# Usage: dji_copy.sh [delay_seconds]  (default: 10)

set -euo pipefail

DELAY=${1:-10}
SRC="/Volumes/NO NAME/DJI_Audio_001"
DEST="$HOME/temp/dji"
VOLUME="/Volumes/NO NAME"
BUNDLE_ID="com.typewhisper.mac"

# Mic records timestamps in UTC; adjust filename to local time.
# Negative = subtract from the mic-reported time.
FILE_TZ_HOURS_SHIFT=-15
FILE_MIN_DRIFT_SHIFT=1

# Gap (seconds) between end of one part and start of next that still counts
# as the same recording session. Accounts for device split overhead + drift.
GAP_THRESHOLD_SECONDS=5

notify() {
  osascript -e "display notification \"$2\" with title \"$1\""
}

sleep "$DELAY"

if [[ ! -d "$SRC" ]]; then
  notify "DJI Copy Failed" "Source not found: $SRC"
  exit 1
fi

mkdir -p "$DEST"

shopt -s nullglob
wav_files=("$SRC"/*.WAV)

if [[ ${#wav_files[@]} -eq 0 ]]; then
  notify "DJI Copy" "No .WAV files found in $SRC"
else
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

# Merge contiguous parts of the same recording session.
# Two files belong to the same session when next.start - prev.end <= GAP_THRESHOLD_SECONDS.
# Runs against ALL un-merged DJI_YYYYMMDD_HHMMSS.WAV files in $DEST so leftover
# groups from a prior run also get merged before transcription.
PARTS_DIR="$DEST/parts"
shopt -s nullglob
mergeable=()
for f in "$DEST"/DJI_*.WAV; do
  fname=$(basename "$f")
  [[ "$fname" =~ ^DJI_[0-9]{8}_[0-9]{6}\.WAV$ ]] || continue
  mergeable+=("$f")
done

if (( ${#mergeable[@]} > 1 )); then
  mkdir -p "$PARTS_DIR"

  entries=()
  for path in "${mergeable[@]}"; do
    fname=$(basename "$path")
    [[ "$fname" =~ ^DJI_([0-9]{8})_([0-9]{6})\.WAV$ ]] || continue
    d="${BASH_REMATCH[1]}"
    t="${BASH_REMATCH[2]}"
    start_epoch=$(date -j -f "%Y%m%d %H%M%S" "$d $t" "+%s")
    dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$path" 2>/dev/null | awk '{printf "%.0f", $1}')
    [[ -z "$dur" || "$dur" == "0" ]] && continue
    entries+=("$start_epoch|$dur|$path")
  done
  IFS=$'\n' sorted=($(printf '%s\n' "${entries[@]}" | sort -n))
  unset IFS

  # Walk sorted list, accumulating groups and flushing inline.
  group=()
  group_end=0
  merged_count=0
  sorted_plus=("${sorted[@]}" "SENTINEL")  # extra entry to force final flush

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
        list=$(mktemp -t dji_concat)
        for p in "${group[@]}"; do
          printf "file '%s'\n" "$p" >> "$list"
        done
        if ffmpeg -f concat -safe 0 -i "$list" -c copy -y "$merged" &>/dev/null; then
          for p in "${group[@]}"; do
            mv "$p" "$PARTS_DIR/"
          done
          (( merged_count++ )) || true
        else
          notify "DJI Copy Warning" "Merge failed for ${first_stem}"
        fi
        rm -f "$list"
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

# Launch TypeWhisper if not already running
if ! osascript -e "tell application \"System Events\" to (name of processes) contains \"TypeWhisper\"" | grep -q true; then
  open -b "$BUNDLE_ID"
fi

# Eject the volume
if diskutil eject "$VOLUME" &>/dev/null; then
  notify "DJI Copy" "Volume ejected"
else
  notify "DJI Copy Warning" "Could not eject volume"
fi

# Convert any .WAV files missing an .mp3 counterpart
shopt -s nullglob
converted=0
failed=0
for wav in "$DEST"/*.WAV; do
  mp3="${wav%.WAV}.mp3"
  if [[ ! -f "$mp3" ]]; then
    if ffmpeg -i "$wav" -b:a 128k -y "$mp3" &>/dev/null; then
      (( converted++ )) || true
    else
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
TRANSCRIBE="$HOME/git.dmg/transcription/transcribe.py"
transcribed=0
tr_failed=0
for wav in "$DEST"/*.WAV; do
  md="${wav%.WAV}.md"
  if [[ ! -f "$md" ]]; then
    if "$TRANSCRIBE" "$wav" --output-dir "$DEST"; then
      (( transcribed++ )) || true
    else
      (( tr_failed++ )) || true
    fi
  fi
done

if (( tr_failed > 0 )); then
  notify "DJI Copy Warning" "Transcription failed for $tr_failed file(s)"
fi
if (( transcribed > 0 )); then
  notify "DJI Copy" "Transcribed $transcribed .WAV file(s)"
fi
