#!/bin/bash
# Records audio playing on this computer (Zoom, Teams, browser) plus the
# microphone, into ~/temp/dji/local with a local_ prefix, mirroring the DJI
# naming so the same tooling can pick the files up later.
#
#   local_YYYYMMDD_HHMMSS_remote.WAV   what the computer plays: every other
#                                      participant, captured via BlackHole
#   local_YYYYMMDD_HHMMSS_me.WAV       the microphone: one known speaker
#
# Recording only — transcription is a separate step. Keeping the two tracks
# apart means diarization only has to separate the remote speakers, and the
# microphone track needs no diarization at all.
#
# Both tracks come from ONE aggregate device (BlackHole 2ch + the microphone,
# 3 channels), so they share a clock and cannot drift apart over a meeting.
#
# ffmpeg captures it, not sox. sox's CoreAudio driver refuses three channels
# ("can't set 3 channels; using 2") and then reads 2 of the 3 interleaved
# channels, which misaligns the frame stride and leaves every channel carrying
# the same mixture of all three. An earlier "Cannot use Aggregate Device" from
# ffmpeg was the terminal missing its microphone permission, not a limitation
# of AVFoundation: granted, ffmpeg reads the aggregate correctly.
#
# Unrelated to dji_copy.sh, which handles the external field recorder. The
# local/ subdirectory keeps these files out of that script's *.WAV glob.
#
# Usage:
#   ./local_record.sh                 record until Ctrl-C
#   ./local_record.sh <name>          record, adding <name> to the filenames
#   ./local_record.sh -s 10 test      record 10 seconds (for checking setup)
#   ./local_record.sh transcribe      transcribe and merge the newest recording
#   ./local_record.sh transcribe <id> same, for local_YYYYMMDD_HHMMSS[_name]
#   ./local_record.sh devices         show the device and its channel layout

set -uo pipefail

# --- configuration -----------------------------------------------------------

DEST="${LOCAL_DEST:-$HOME/temp/dji/local}"
PREFIX="local_"

# Used by the transcribe subcommand. The mic track is one known person, so it
# gets a fixed label instead of a SPEAKER_nn from diarization.
TRANSCRIBE="${LOCAL_TRANSCRIBE:-$HOME/git.dmg/transcription_scripts/transcribe.py}"
MY_LABEL="${LOCAL_MY_LABEL:-DMG}"

# How to capture:
#   aggregate - ONE device holding both tracks, so they share a clock. Default.
#   devices   - BlackHole and the microphone opened as two separate devices.
#               Needs no aggregate, but they run on two clocks and drift apart
#               over the length of a meeting. Kept only for comparison.
#
# The aggregate must be built from BlackHole 2ch, not BlackHole 16ch: mic +
# 16ch BlackHole is 17 channels, which no capture path here reads reliably.
# BlackHole 2ch + the mic is 3 channels, measured clean (c0/c1 digital silence
# when nothing is playing, c2 carrying the microphone).
MODE="${LOCAL_MODE:-aggregate}"

# Used in devices mode.
REMOTE_DEVICE="${LOCAL_REMOTE_DEVICE:-BlackHole 2ch}"
MIC_DEVICE="${LOCAL_MIC_DEVICE:-MacBook Pro Microphone}"

# Used in aggregate mode.
DEVICE="${LOCAL_DEVICE:-aggregate.dmg}"

# Whisper resamples to 16 kHz anyway, so writing at 16 kHz keeps an hour near
# 100 MB rather than a gigabyte.
RATE="${LOCAL_RATE:-16000}"

# Matches dji_copy.sh. Well above transparent for a 16 kHz track, but keeping
# the two workflows identical is worth more than the saved megabytes.
MP3_BITRATE="${LOCAL_MP3_BITRATE:-128k}"

# Channel offsets, worked out from the device's channel count below: BlackHole
# 2ch first and the mic after it gives remote c0+c1 and mic on the last
# channel. Set these to override if your aggregate is ordered differently.
REMOTE_LEFT="${LOCAL_REMOTE_LEFT:-}"
REMOTE_RIGHT="${LOCAL_REMOTE_RIGHT:-}"

# Set to an audio file to exercise the split without a live device.
TEST_INPUT="${LOCAL_TEST_INPUT:-}"

SECONDS_LIMIT=""

die() { echo "ERROR: $1" >&2; exit 1; }

# Input channel count of $DEVICE, per the system audio inventory.
detect_channels() {
  system_profiler SPAudioDataType 2>/dev/null | awk -v want="$DEVICE" '
    /^ {8}[A-Za-z]/ { name=$0; gsub(/^ +|:$/,"",name) }
    /Input Channels/ { if (name == want) { print $NF; exit } }'
}

# A Multi-Output Device has outputs but no inputs, so it cannot be recorded
# from. Distinguishing that from a missing device saves a confusing hunt.
detect_output_only() {
  system_profiler SPAudioDataType 2>/dev/null | awk -v want="$DEVICE" '
    /^ {8}[A-Za-z]/ { name=$0; gsub(/^ +|:$/,"",name) }
    /Output Channels/ { if (name == want) { found=1 } }
    END { if (found) print "yes" }'
}

# Explains the aggregate-vs-multi-output distinction, which the Audio MIDI
# Setup "+" menu offers side by side for opposite purposes.
explain_missing_device() {
  if [[ -n "$(detect_output_only)" ]]; then
    echo "  \"$DEVICE\" exists but has NO INPUT channels — it is an output-only"
    echo "  device (a Multi-Output Device), so nothing can be recorded from it."
  else
    echo "  \"$DEVICE\" not found."
  fi
  echo
  echo "  Two different devices are needed, both from the + menu in Audio MIDI Setup:"
  echo "    Create Aggregate Device    -> HAS INPUTS. This is what gets recorded."
  echo "                                  Add BlackHole 2ch, then the microphone:"
  echo "                                  3 channels total, which reads cleanly."
  echo "                                  Enable Drift Correction on the mic."
  echo "    Create Multi-Output Device -> OUTPUT ONLY. Lets you hear audio while"
  echo "                                  copying it to BlackHole. Never recorded from."
}

# --- devices -----------------------------------------------------------------

list_devices() {
  echo "=== input devices and channel counts ==="
  system_profiler SPAudioDataType 2>/dev/null \
    | awk '/^ {8}[A-Za-z]/{n=$0} /Input Channels/{gsub(/^ +|:$/,"",n); gsub(/^ +/,"",$0); print "  " n "  " $0}'
  echo
  local ch
  ch=$(detect_channels)
  echo "=== \"$DEVICE\" ==="
  if [[ -z "$ch" ]]; then
    explain_missing_device
  else
    echo "  $ch input channels"
    if (( ch < 3 )); then
      echo "  The microphone is NOT in it — the me track would be silent."
      echo "  Add it in Audio MIDI Setup; with BlackHole 2ch the count should be 3."
    else
      echo "  Microphone present (channel c$((ch - 1)))."
    fi
  fi
  echo
  echo "For the remote track to carry sound, system output must reach BlackHole:"
  echo "build a Multi-Output Device (speakers/AirPods + BlackHole 2ch), select it"
  echo "as output, and set Zoom's speaker to it."
  if [[ -n "$ch" ]] && (( ch > 3 )); then
    echo
    echo "NOTE: $ch channels is more than the expected 3. That usually means the"
    echo "aggregate still holds BlackHole 16ch instead of BlackHole 2ch."
    echo "Run '$0 probe' to see which channels actually carry signal."
  fi
}

# Records a few seconds and reports the level of every channel, so the real
# layout of an aggregate device can be identified rather than guessed.
do_probe() {
  local secs="${1:-5}"
  local ch
  ch=$(detect_channels)
  if [[ -z "$ch" ]]; then
    explain_missing_device >&2
    die "no recordable device named \"$DEVICE\""
  fi
  echo "Probing \"$DEVICE\": $ch channels, ${secs}s."
  echo "Talk into the microphone and play some audio, so both show up."
  echo

  # Captured and measured with ffmpeg throughout. sox cannot be trusted here:
  # it silently reduces the channel count it cannot honour and then reads the
  # interleaved stream at the wrong stride, which makes every channel report
  # the same level and hides exactly the fault this probe exists to find.
  local tmp
  tmp=$(mktemp -t localprobe).wav
  ffmpeg -hide_banner -v error -f avfoundation -i ":$DEVICE" \
    -filter_complex "[0:a]asetpts=PTS-STARTPTS,atrim=duration=$secs[o]" -map "[o]" -y "$tmp" \
    || die "could not capture from \"$DEVICE\""

  local i level
  for ((i = 0; i < ch; i++)); do
    level=$(ffmpeg -hide_banner -i "$tmp" -af "pan=mono|c0=c$i,astats" -f null - 2>&1 \
      | awk -F': ' '/RMS level dB/{print $2; exit}')
    printf "  c%-2s RMS=%-12s%s\n" "$i" "$level" \
      "$(awk -v r="$level" 'BEGIN{ if (r == "-inf") print "<-- digital silence"; else if (r+0 > -70) print "<-- SIGNAL"; else print "<-- faint"; }')"
  done
  rm -f "$tmp"
  echo
  echo "An idle BlackHole channel reads -inf: nothing is being routed to it."
  echo "Set LOCAL_MIC_CHANNEL / LOCAL_REMOTE_LEFT / LOCAL_REMOTE_RIGHT accordingly."
}

# Two devices recorded over the same wall-clock span should hold the same
# number of samples; the difference is accumulated clock drift. Reported in ppm
# and extrapolated, since drift only matters once it approaches a second.
drift_report() {
  local a="$1" b="$2"
  [[ -s "$a" && -s "$b" ]] || return 0
  local da db
  da=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$a")
  db=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$b")
  [[ -n "$da" && -n "$db" ]] || return 0
  awk -v da="$da" -v db="$db" '
    BEGIN {
      d = da - db; ad = (d < 0 ? -d : d);
      printf "\n  drift: remote %.3fs vs me %.3fs  ->  %.3fs apart", da, db, ad;
      if (da > 0) {
        ppm = ad / da * 1000000;
        printf "  (%.0f ppm)\n", ppm;
        printf "         extrapolated: %.2fs per hour, %.2fs over 3h\n", ppm * 3600 / 1000000, ppm * 10800 / 1000000;
        if (ppm * 3600 / 1000000 < 1)
          print "         below 1s/hour — invisible in a [HH:MM:SS] transcript.";
        else
          print "         over 1s/hour — lines could sort out of order; consider aggregate mode.";
      } else print "\n";
    }'
}

# --- record ------------------------------------------------------------------

do_record() {
  local name="${1:-}"
  local stamp base
  stamp=$(date "+%Y%m%d_%H%M%S")
  base="${PREFIX}${stamp}${name:+_$name}"

  mkdir -p "$DEST" || die "cannot create $DEST"
  local remote="$DEST/${base}_remote.WAV"
  local me="$DEST/${base}_me.WAV"

  # devices mode needs no aggregate: ffmpeg opens the two real devices itself.
  if [[ "$MODE" == devices && -z "$TEST_INPUT" ]]; then
    echo "Recording to $DEST"
    echo "  remote: $(basename "$remote")   [\"$REMOTE_DEVICE\" c0+c1]"
    echo "  me:     $(basename "$me")   [\"$MIC_DEVICE\"]"
    echo "  mode:   devices (two clocks; run '$0 drift <file> <file>' afterwards)"
    if [[ -n "$SECONDS_LIMIT" ]]; then
      echo "  stopping after ${SECONDS_LIMIT}s"
    else
      echo
      echo "Press Ctrl-C to stop."
    fi
    echo
    # A capture device held open by a stray process delivers nothing to the new
    # reader, which looks exactly like a routing problem. Say so up front.
    local holders
    holders=$(pgrep -f "avfoundation|rec -q -c" | grep -v "^$$\$" | tr '\n' ' ')
    if [[ -n "${holders// /}" ]]; then
      echo "  WARN: other capture processes are running ($holders)." >&2
      echo "        They can hold the devices open and starve this recording." >&2
      echo
    fi

    # -t is unreliable here: avfoundation timestamps start at the device's host
    # clock rather than zero, so the limit never fires. Normalising the PTS and
    # trimming inside the graph does the right thing per output.
    local lim=""
    [[ -n "$SECONDS_LIMIT" ]] && lim=",atrim=duration=$SECONDS_LIMIT"
    # BlackHole presents 16 channels but only the first pair carries audio.
    ffmpeg -hide_banner -f avfoundation -i ":$REMOTE_DEVICE" \
                        -f avfoundation -i ":$MIC_DEVICE" \
      -filter_complex "[0:a]pan=stereo|c0=c0|c1=c1,asetpts=PTS-STARTPTS${lim}[remote];[1:a]pan=mono|c0=c0,asetpts=PTS-STARTPTS${lim}[me]" \
      -map "[remote]" -ar "$RATE" -y "$remote" \
      -map "[me]" -ar "$RATE" -y "$me" &
    local ff=$!
    # Without this, killing the wrapper leaves ffmpeg holding both devices.
    trap 'kill -INT $ff 2>/dev/null' INT TERM
    wait $ff
    trap - INT TERM
    echo
    report "$remote" remote
    report "$me" me
    drift_report "$remote" "$me"
    return
  fi

  local channels mic_channel
  if [[ -n "$TEST_INPUT" ]]; then
    channels=$(ffprobe -v error -show_entries stream=channels -of csv=p=0 "$TEST_INPUT")
  else
    channels=$(detect_channels)
    if [[ -z "$channels" ]]; then
      explain_missing_device >&2
      die "no recordable device named \"$DEVICE\""
    fi
  fi

  mic_channel="${LOCAL_MIC_CHANNEL:-c$((channels - 1))}"
  REMOTE_LEFT="${REMOTE_LEFT:-c0}"
  REMOTE_RIGHT="${REMOTE_RIGHT:-c1}"

  echo "Recording to $DEST"
  echo "  remote: $(basename "$remote")   [$REMOTE_LEFT + $REMOTE_RIGHT]"
  echo "  me:     $(basename "$me")   [$mic_channel]"
  if [[ -n "$TEST_INPUT" ]]; then
    echo "  input:  $TEST_INPUT (test mode, ${channels}ch)"
  else
    echo "  device: \"$DEVICE\" ${channels}ch -> ${RATE} Hz"
    # BlackHole 2ch alone is 2 channels; the mic adds a third. Anything less
    # means the mic never made it into the aggregate.
    if (( channels < 3 )); then
      echo "  WARN: only ${channels} channels — the microphone is probably not in" >&2
      echo "        this aggregate, so the me track will be silent." >&2
    fi
  fi
  if [[ -n "$SECONDS_LIMIT" ]]; then
    echo "  stopping after ${SECONDS_LIMIT}s"
  else
    echo
    echo "Press Ctrl-C to stop."
  fi
  echo

  # Split once, then take a stereo pair for the remote track and one channel for
  # the microphone. The split is explicit so a duration trim can be applied to
  # the source once rather than per branch.
  local filter="[r]pan=stereo|c0=${REMOTE_LEFT}|c1=${REMOTE_RIGHT}[remote];[m]pan=mono|c0=${mic_channel}[me]"

  if [[ -n "$TEST_INPUT" ]]; then
    ffmpeg -hide_banner -v error -i "$TEST_INPUT" ${SECONDS_LIMIT:+-t "$SECONDS_LIMIT"} \
      -filter_complex "[0:a]asplit[r][m];$filter" \
      -map "[remote]" -ar "$RATE" -y "$remote" \
      -map "[me]" -ar "$RATE" -y "$me"
  else
    # ffmpeg reads the aggregate directly. sox is not used: its CoreAudio driver
    # refuses three channels ("can't set 3 channels; using 2") and then reads 2
    # of the 3 interleaved channels, which misaligns the frame stride and turns
    # every channel into the same mixture of all three. ffmpeg keeps them apart:
    # measured on this aggregate, c0/c1 read digital silence while c2 carried
    # the microphone at -43 dB.
    #
    # -t does not work on an avfoundation input, whose timestamps start at the
    # device host clock, so the deadline never arrives. Resetting the PTS and
    # trimming inside the filter graph does stop it.
    local head=""
    [[ -n "$SECONDS_LIMIT" ]] && head="asetpts=PTS-STARTPTS,atrim=duration=$SECONDS_LIMIT,"
    ffmpeg -hide_banner -v error -f avfoundation -i ":$DEVICE" \
      -filter_complex "[0:a]${head}asplit[r][m];$filter" \
      -map "[remote]" -ar "$RATE" -y "$remote" \
      -map "[me]" -ar "$RATE" -y "$me" &
    local ff=$!
    # Ctrl-C has to reach ffmpeg itself. Killing only this wrapper leaves ffmpeg
    # holding the device open, which truncates both files and starves the next
    # recording of the microphone.
    trap 'kill -INT $ff 2>/dev/null' INT TERM
    wait "$ff"
    trap - INT TERM
  fi

  echo
  report "$remote" remote
  report "$me" me

  echo
  echo "Mixing to MP3..."
  to_mp3 "$remote" "$me" "${remote%_remote.WAV}.mp3"
}

# Mixes both tracks into one MP3 for listening, mirroring the mp3-convert stage
# of dji_copy.sh: same bitrate, the WAVs are kept, an existing .mp3 is left
# alone, and a partial file from a failed run is removed so the next attempt
# retries rather than skipping.
#
# The tracks stay separate as WAVs because that is what makes the transcript
# work: diarization only has to tell the remote speakers apart, and the mic
# track needs no diarization at all. Mixing is purely for playback.
to_mp3() {
  local remote="$1" me="$2" mp3="$3"
  if [[ -f "$mp3" ]]; then
    echo "  $(basename "$mp3") already exists"
    return 0
  fi

  # normalize=0 keeps each input at its recorded level; amix otherwise divides
  # by the input count and leaves the result noticeably quiet. Both tracks sit
  # around -30 dB mean, so there is ample headroom before clipping.
  local ok=1
  if [[ -s "$remote" && -s "$me" ]]; then
    ffmpeg -hide_banner -v error -i "$remote" -i "$me" \
      -filter_complex "[1:a]aformat=channel_layouts=stereo[mic];[0:a][mic]amix=inputs=2:duration=longest:normalize=0[out]" \
      -map "[out]" -b:a "$MP3_BITRATE" -y "$mp3" 2>/dev/null || ok=0
  else
    # One track missing: still produce the MP3 from whatever was captured.
    local only="$remote"; [[ -s "$only" ]] || only="$me"
    [[ -s "$only" ]] || return 0
    ffmpeg -hide_banner -v error -i "$only" -b:a "$MP3_BITRATE" -y "$mp3" 2>/dev/null || ok=0
  fi

  if (( ok )); then
    printf "  %-46s %s\n" "$(basename "$mp3")" "$(du -h "$mp3" | awk '{print $1}')"
  else
    rm -f "$mp3"
    echo "WARN: MP3 conversion failed for $(basename "$mp3")" >&2
  fi
}

# Prints duration and level, and explains a silent track rather than leaving it
# to be discovered after the meeting.
report() {
  local f="$1" kind="$2"
  if [[ ! -s "$f" ]]; then
    echo "WARN: $(basename "$f") is empty" >&2
    return
  fi
  local vol
  vol=$(ffmpeg -hide_banner -i "$f" -af volumedetect -f null - 2>&1 \
    | awk -F': ' '/mean_volume/{gsub(/ dB/,"",$2); print $2}')
  printf "  %-46s %6.1f min  mean %s dB\n" "$(basename "$f")" \
    "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$f" | awk '{print $1/60}')" "$vol"
  if [[ -n "$vol" ]] && (( ${vol%.*} < -70 )); then
    if [[ "$kind" == remote ]]; then
      echo "      SILENT: system audio is not reaching BlackHole. Select a" >&2
      echo "      Multi-Output Device (speakers + BlackHole 2ch) as output." >&2
    else
      echo "      SILENT: no microphone signal. Check that the aggregate device" >&2
      echo "      includes the mic ($0 devices) and Privacy & Security > Microphone." >&2
    fi
  fi
}

# --- transcribe and merge ----------------------------------------------------

# Transcribes both tracks of one recording and interleaves them into a single
# conversation. The two tracks came from one device on one clock, so their
# timestamps are directly comparable and the merge is a sort.
do_transcribe() {
  local stamp="${1:-}"
  [[ -x "$TRANSCRIBE" ]] || die "$TRANSCRIBE is not executable"

  # With no argument, take the newest recording in DEST.
  if [[ -z "$stamp" ]]; then
    local newest
    newest=$(ls -t "$DEST"/${PREFIX}*_remote.WAV 2>/dev/null | head -1)
    [[ -n "$newest" ]] || die "no recordings in $DEST"
    stamp=$(basename "$newest"); stamp="${stamp%_remote.WAV}"
  fi
  stamp="$(basename "$stamp")"
  stamp="${stamp%_remote.WAV}"; stamp="${stamp%_me.WAV}"; stamp="${stamp%.WAV}"

  local remote="$DEST/${stamp}_remote.WAV" me="$DEST/${stamp}_me.WAV"
  [[ -s "$remote" || -s "$me" ]] || die "no tracks found for $stamp in $DEST"

  # The remote track holds every other participant, so it gets full diarization
  # and reports however many speakers pyannote finds.
  if [[ -s "$remote" ]]; then
    echo "=== remote participants (diarized) ==="
    "$TRANSCRIBE" "$remote" --timestamps --output-dir "$DEST" --overwrite \
      || echo "WARN: remote track failed" >&2
  fi

  # The microphone is one known person: diarization would only cost time and
  # risk splitting a single speaker into several.
  if [[ -s "$me" ]]; then
    echo "=== my microphone (single speaker) ==="
    "$TRANSCRIBE" "$me" --timestamps --no-diarize --label "$MY_LABEL" \
      --output-dir "$DEST" --overwrite || echo "WARN: mic track failed" >&2
  fi

  # Both transcripts are one [HH:MM:SS]-prefixed line per segment, so putting
  # the conversation back in order is a lexicographic sort.
  local merged="$DEST/${stamp}.md"
  if [[ -s "$DEST/${stamp}_remote.md" || -s "$DEST/${stamp}_me.md" ]]; then
    cat "$DEST/${stamp}_remote.md" "$DEST/${stamp}_me.md" 2>/dev/null \
      | grep -E "^\[" | sort > "$merged"
    echo
    echo "Merged transcript: $merged"
    echo "  lines:    $(wc -l < "$merged" | tr -d ' ')"
    # Anchor on the line's own label. Matching bare **...** anywhere would also
    # pick up asterisks inside the transcribed text, such as a censored word.
    echo "  speakers: $(sed -n 's/^\[[0-9:]*\] \*\*\([^*]*\)\*\*:.*/\1/p' "$merged" | sort -u | tr '\n' ' ')"
  else
    die "no transcripts were produced"
  fi

  # Last: the mixed MP3, transcribed as one stream. The merged transcript above
  # knows which track each line came from, so it can never mistake you for a
  # remote participant; this one has to work it out from the audio alone, and
  # sees both voices in one conversation. Useful as a cross-check, and it picks
  # up overlapping speech that the per-track pass splits apart.
  local mixed="$DEST/${stamp}.mp3"
  [[ -f "$mixed" ]] || to_mp3 "$remote" "$me" "$mixed"
  if [[ -s "$mixed" ]]; then
    echo
    echo "=== mixed audio (diarized as one stream) ==="
    # transcribe.py names its output after the input stem, which here collides
    # with the merged transcript, so it writes to a scratch directory first.
    local tmpdir
    tmpdir=$(mktemp -d -t localjoint)
    if "$TRANSCRIBE" "$mixed" --timestamps --output-dir "$tmpdir" --overwrite; then
      mv "$tmpdir/${stamp}.md" "$DEST/${stamp}-joint.md"
      echo
      echo "Joint transcript: $DEST/${stamp}-joint.md"
      echo "  lines:    $(wc -l < "$DEST/${stamp}-joint.md" | tr -d ' ')"
      echo "  speakers: $(sed -n 's/^\[[0-9:]*\] \*\*\([^*]*\)\*\*:.*/\1/p' "$DEST/${stamp}-joint.md" | sort -u | tr '\n' ' ')"
    else
      echo "WARN: mixed-audio transcription failed" >&2
    fi
    rm -rf "$tmpdir"
  fi
}

# --- main --------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--seconds) SECONDS_LIMIT="${2:-}"; [[ -n "$SECONDS_LIMIT" ]] || die "-s needs a value"; shift 2 ;;
    devices)      list_devices; exit 0 ;;
    probe)        do_probe "${2:-5}"; exit 0 ;;
    drift)        [[ $# -ge 3 ]] || die "usage: $0 drift <remote.WAV> <me.WAV>"
                  drift_report "$2" "$3"; exit 0 ;;
    transcribe)   do_transcribe "${2:-}"; exit 0 ;;
    -h|--help)    sed -n '2,33p' "$0"; exit 0 ;;
    *)            break ;;
  esac
done

do_record "${1:-}"
