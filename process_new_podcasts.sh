#!/bin/bash

#
# Title:        Podcast Processing Wrapper Script
# Description:  Finds new podcast text files, processes them, publishes them,
#               and archives them.
# Author:       Jules
#

# --- Configuration ---
WORK_DIR="/home/make-sftp/JH"
INCOMING_DIR="${WORK_DIR}/incoming"
ARCHIVE_DIR="${WORK_DIR}/archive"
OUTPUT_DIR="${WORK_DIR}/output"
EPISODE_DIR="${WORK_DIR}/episode"

# Define script paths
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
GENERATION_SCRIPT="${SCRIPT_DIR}/make_jewels_multi.sh"
PUBLISH_SCRIPT="${SCRIPT_DIR}/publish_episode.sh"

# --- Helper Functions ---
log() {
    echo >&2 "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $@"
}

send_final_webhook() {
    local status="$1"
    local source_script="$2"
    local output_file="$3"
    local error_message="$4"

    # Load webhook URL from the main .env file
    local env_file="${WORK_DIR}/.env"
    if [ -f "$env_file" ]; then
        # Use a subshell to avoid polluting the script's environment
        (source "$env_file" && \

        if [[ -z "$MAKE_WEBHOOK_URL" ]]; then
            log "WARNING: MAKE_WEBHOOK_URL is not set in .env file. Skipping webhook notification."
            return
        fi

        log "Sending final ${status} webhook notification..."

        local timestamp
        timestamp=$(date -u --iso-8601=seconds)

        local json_payload
        json_payload=$(jq -n \
            --arg status "$status" \
            --arg source_script "$source_script" \
            --arg output_file "$output_file" \
            --arg error_message "$error_message" \
            --arg timestamp "$timestamp" \
            '{status: $status, source_script: $source_script, output_file: $output_file, error_message: $error_message, timestamp: $timestamp}')

        curl -s -X POST -H "Content-Type: application/json" -d "$json_payload" "$MAKE_WEBHOOK_URL" || log "WARNING: Final webhook curl command failed."
        log "Final webhook notification sent.")
    else
        log "WARNING: .env file not found at '$env_file'. Cannot send webhook."
    fi
}

# --- Main Logic ---
log "Starting podcast processing and publishing run..."

# Ensure necessary directories exist.
mkdir -p "$ARCHIVE_DIR" || { log "FATAL: Could not create archive directory: $ARCHIVE_DIR"; exit 1; }
mkdir -p "$OUTPUT_DIR" || { log "FATAL: Could not create output directory: $OUTPUT_DIR"; exit 1; }
mkdir -p "$EPISODE_DIR" || { log "FATAL: Could not create episode directory: $EPISODE_DIR"; exit 1; }


for file in "$INCOMING_DIR"/*.txt; do
    if [ ! -f "$file" ]; then
        continue
    fi

    log "--- Found new file: $file ---"

    # Step 1: Generate the raw WAV file
    if "$GENERATION_SCRIPT" "$file"; then
        log "WAV generation successful for: $file"

        # Step 2: Publish the final MP3 episode
        # Construct the expected output WAV file path.
        # The generation script creates the WAV with the same full basename as the input txt file.
        base_txt_filename_with_ext=$(basename "$file")
        generated_wav_file="${OUTPUT_DIR}/${base_txt_filename_with_ext%.*}.wav"

        if [ ! -f "$generated_wav_file" ]; then
            log "ERROR: Expected WAV file was not found after generation: $generated_wav_file"
            send_final_webhook "failure" "$file" "" "Generated WAV file was not found post-processing."
        elif final_mp3_path=$("$PUBLISH_SCRIPT" "$generated_wav_file"); then
            log "Publishing successful. Final episode: $final_mp3_path"
            send_final_webhook "success" "$file" "$final_mp3_path" ""
        else
            log "ERROR: Publishing script failed for: $generated_wav_file"
            send_final_webhook "failure" "$file" "" "The publishing script failed for $generated_wav_file."
        fi

        # Step 3: Archive the original text file after all processing attempts
        mv "$file" "$ARCHIVE_DIR/"
        log "Archived source file to: $ARCHIVE_DIR/$(basename "$file")"
    else
        log "ERROR: WAV generation script failed for: $file"
        # Failure webhook is already sent by the 'die' function in the generation script
        # Move the failed file to archive to prevent reprocessing loops
        mv "$file" "$ARCHIVE_DIR/"
        log "Archived failed source file to: $ARCHIVE_DIR/$(basename "$file")"
    fi
    log "--- Finished processing: $file ---"
done

log "Podcast processing and publishing run finished."
