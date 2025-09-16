#!/bin/bash

#
# Title:        Episode Publishing Script
# Description:  Takes a generated WAV file, adds a specific intro and outro,
#               normalizes the audio, and encodes it as a final MP3 episode.
# Author:       Jules
#

# --- Rigorous Error Handling ---
set -eo pipefail

# --- Configuration ---
WORK_DIR="/home/make-sftp/JH"
JINGLE_DIR="${WORK_DIR}/jingles"
EPISODE_DIR="${WORK_DIR}/episode"

# --- Helper Functions ---
log() {
    echo >&2 "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $@"
}

normalize_audio() {
    local input_file="$1"
    local output_file="$2"

    log "Normalizing '$input_file' using 2-pass EBU R128 loudnorm..."

    # 1. First pass: Analyze the audio and get stats from ffmpeg's stderr
    local loudnorm_stats
    loudnorm_stats=$(ffmpeg -i "$input_file" -af loudnorm=I=-16:LRA=11:TP=-1.5:print_format=json -f null - 2>&1)

    if [[ -z "$loudnorm_stats" ]]; then
        log "FATAL: ffmpeg loudnorm first pass produced no output for '$input_file'."
        return 1
    fi

    # 2. Parse the stats with jq
    local measured_i
    measured_i=$(echo "$loudnorm_stats" | jq -r .input_i)
    local measured_lra
    measured_lra=$(echo "$loudnorm_stats" | jq -r .input_lra)
    local measured_tp
    measured_tp=$(echo "$loudnorm_stats" | jq -r .input_tp)
    local measured_thresh
    measured_thresh=$(echo "$loudnorm_stats" | jq -r .input_thresh)
    local target_offset
    target_offset=$(echo "$loudnorm_stats" | jq -r .target_offset)

    # 3. Second pass: Apply the normalization filters
    if ! ffmpeg -y -v error -i "$input_file" -af "loudnorm=I=-16:LRA=11:TP=-1.5:measured_I=${measured_i}:measured_LRA=${measured_lra}:measured_TP=${measured_tp}:measured_thresh=${measured_thresh}:offset=${target_offset}" \
        -ar 44100 -c:a pcm_s16le "$output_file"; then
        log "FATAL: ffmpeg loudnorm second pass failed for '$input_file'."
        return 1
    fi
    log "Normalization successful for '$output_file'."
    return 0
}


# --- Main Script Logic ---
main() {
    local main_content_wav="$1"

    if [[ -z "$main_content_wav" ]]; then
        log "FATAL: No input WAV file provided to the publishing script."
        exit 1
    fi

    if [ ! -f "$main_content_wav" ]; then
        log "FATAL: Input WAV file not found: '$main_content_wav'"
        exit 1
    fi

    log "--- Starting publishing process for: $main_content_wav ---"

    local base_filename
    base_filename=$(basename "$main_content_wav" .wav | sed 's/^OpenAI_//')

    # Dynamically determine intro and outro file paths
    local intro_file="${JINGLE_DIR}/Intro-${base_filename}.wav"
    local outro_file="${JINGLE_DIR}/${base_filename}_outro.wav"
    local final_mp3_output="${EPISODE_DIR}/${base_filename}.mp3"

    # Check for existence of all required audio files
    for f in "$intro_file" "$main_content_wav" "$outro_file"; do
        if [ ! -f "$f" ]; then
            log "FATAL: Required audio file not found: '$f'"
            exit 1
        fi
    done

    local tmp_dir
    tmp_dir=$(mktemp -d -t episode_publisher_XXXXXX)
    trap "log 'Cleaning up publisher temporary directory...'; rm -rf -- '$tmp_dir'" EXIT

    local concat_list_file="${tmp_dir}/concat_list.txt"
    rm -f "$concat_list_file"

    log "Normalizing audio components..."
    local files_to_process=("$intro_file" "$main_content_wav" "$outro_file")
    local i=0
    for file_path in "${files_to_process[@]}"; do
        ((i++))
        local norm_wav="${tmp_dir}/part_${i}_normalized.wav"

        normalize_audio "$file_path" "$norm_wav"

        echo "file '$norm_wav'" >> "$concat_list_file"
    done

    log "Concatenating normalized parts and encoding to MP3..."
    if ! ffmpeg -y -v error -f concat -safe 0 -i "$concat_list_file" -b:a 128k -acodec libmp3lame "$final_mp3_output"; then
        log "FATAL: Final concatenation and MP3 encoding failed."
        exit 1
    fi

    log "--- SUCCESS ---"
    log "Final episode created at: $final_mp3_output"

    echo "$final_mp3_output"
}

main "$@"
