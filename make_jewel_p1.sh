#!/bin/bash

#
# Title:        Podcast Generator Script
# Description:  Creates a podcast from a text script using Google TTS and ffmpeg,
#               with background music specified in the script itself.
# Author:       Jules & User
#

# --- Rigorous Error Handling ---
# We are not using `set -e` due to server environment constraints.
# Instead, critical commands are checked for failure, and a `die` function is called.

# --- Configuration ---
ENV_FILE="/home/make-sftp/JH/.env"
DEFAULT_MUSIC="/home/make-sftp/music/bg/history.mp3"
MUSIC_DIR="/home/make-sftp/music/bg"
OUTPUT_DIR="/home/make-sftp/JH/output"


# --- Global Variables ---
tmp_dir=""
fade_slope=""
processed_section_count=0
final_section_audio_files=()
NO_MUSIC=false
TURKISH=false


# Audio processing settings
INTRO_DURATION=5
FADE_DURATION=3
BACKGROUND_VOLUME=0.1



if [ "$TURKISH" = false ]; then
    # Google Cloud TTS settings ENGLISH
    TTS_API_ENDPOINT="https://eu-texttospeech.googleapis.com/v1/text:synthesize"
    VOICE_DEBORAH="en-GB-Chirp3-HD-Leda"
    VOICE_KIERAN="en-GB-Chirp3-HD-Rasalgethi"
    Lang_Code="en-GB"
else
    # Google Cloud TTS settings TURKISH
    TTS_API_ENDPOINT="https://eu-texttospeech.googleapis.com/v1/text:synthesize"
    VOICE_AZRA="tr-TR-Chirp3-HD-Leda"
    VOICE_BARIS="tr-TR-Chirp3-HD-Rasalgethi"
    Lang_Code="tr-TR"
fi


# --- Helper Functions ---

log() {
    echo >&2 "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $@"
}

send_webhook_notification() {
    local status="$1"
    local source_script="$2"
    local output_file="$3"
    local error_message="$4"
    local json_payload

    log "Sending ${status} webhook notification..."

    if [[ -z "$MAKE_WEBHOOK_URL" ]]; then
        log "WARNING: MAKE_WEBHOOK_URL is not set in .env file. Skipping webhook notification."
        return
    fi

    json_payload=$(jq -n \
        --arg status "$status" \
        --arg source_script "$source_script" \
        --arg output_file "$output_file" \
        --arg error_message "$error_message" \
        '{status: $status, source_script: $source_script, output_file: $output_file, error_message: $error_message}')

    # Send the webhook, but don't let it crash the script if curl fails.
    curl -s -X POST -H "Content-Type: application/json" -d "$json_payload" "$MAKE_WEBHOOK_URL" || log "WARNING: Webhook curl command failed."
    log "Webhook notification sent."
}

die() {
    local error_message="$1"
    # The global variable 'input_file' should be set by main().
    send_webhook_notification "failure" "${input_file:-"N/A"}" "" "$error_message"
    log "FATAL: $error_message"
    # Clean up temp dir before exiting
    if [[ -n "$tmp_dir" && -d "$tmp_dir" ]]; then
        rm -rf -- "$tmp_dir"
    fi
    exit 1
}

check_dependencies() {
    for cmd in curl jq ffmpeg ffprobe sox bc gcloud; do
        if ! command -v "$cmd" &> /dev/null; then
            die "Required command '$cmd' is not installed."
        fi
    done
}

generate_tts() {
    local text="$1"
    local voice="$2"
    local output_file="$3"
    local json_payload
    if [ "$TURKISH" = false ]; then
        json_payload=$(jq -n --arg text "$text" --arg voice "$voice"         '{"input": {"text": $text}, "voice": {"languageCode": "en-GB", "name": $voice}, "audioConfig": {"audioEncoding": "MP3"}}')
    else
        json_payload=$(jq -n --arg text "$text" --arg voice "$voice"         '{"input": {"text": $text}, "voice": {"languageCode": "tr-TR", "name": $voice}, "audioConfig": {"audioEncoding": "MP3"}}')
    fi
    local response
    response=$(curl -s -X POST         -H "Authorization: Bearer $(gcloud auth application-default print-access-token)"         -H "Content-Type: application/json; charset=utf-8"         -H "X-Goog-User-Project: $GCLOUD_PROJECT"         -d "$json_payload" "$TTS_API_ENDPOINT")
    if echo "$response" | jq -e '.error' > /dev/null; then
        log "ERROR: Google TTS API call failed."
        echo "$response" | jq '.error' >&2
        return 1
    fi
    echo "$response" | jq -r '.audioContent' | base64 --decode > "$output_file"
    log "Successfully saved speech to '$output_file'"
}

# A pure-bash function to trim leading/trailing whitespace.
trim_whitespace() {
    local var="$1"
    shopt -s extglob
    var="${var##+([[:space:]])}"
    var="${var%%+([[:space:]])}"
    shopt -u extglob
    echo "$var"
}

process_section() {
    local bg_music_file="$1"
    local -n lines_ref="$2"
    local failed_lines_file="$3"

    ((processed_section_count++))
    local section_num=$processed_section_count

    if [ ${#lines_ref[@]} -eq 0 ]; then return; fi

    log "--- Processing Section $section_num ---"
    log "Using background music: $bg_music_file"

    local section_speech_parts=()
    local line_num=0
    for line in "${lines_ref[@]}"; do
        ((line_num++))
        local text voice speaker dialogue
        if [[ "$line" =~ ^([^:]+):(.*)$ ]]; then
            speaker="${BASH_REMATCH[1]}"
            dialogue="${BASH_REMATCH[2]}"

            if [ "$TURKISH" = false ]; then

                case "$speaker" in
                    n|an|ran|eran|ieran|Kieran) voice="$VOICE_KIERAN" ;;
                    h|ah|rah|orah|borah|eborah|Deborah) voice="$VOICE_DEBORAH" ;;
                    *)
                        log "WARNING: L${line_num} in Sec${section_num} has unknown speaker '$speaker'. Skipping."
                        continue
                        ;;
                esac

            else

                case "$speaker" in
                    ş|ış|rış|arış|Barış) voice="$VOICE_BARIS" ;;
                    a|ra|zra|Azra) voice="$VOICE_AZRA" ;;
                    *)
                        log "WARNING: L${line_num} in Sec${section_num} has unknown speaker '$speaker'. Skipping."
                        continue
                        ;;
                esac
            fi

            text=$(trim_whitespace "$dialogue")
            if [[ -z "$text" ]]; then continue; fi

            local speech_part_file="$tmp_dir/section_${section_num}_speech_${line_num}.mp3"
            if ! generate_tts "$text" "$voice" "$speech_part_file"; then
                log "WARNING: Failed to generate speech for line. Writing to failure log."
                echo "$line" >> "$failed_lines_file"
                continue
            fi
            section_speech_parts+=("$speech_part_file")
        else
            log "WARNING: L${line_num} in Sec${section_num} is not in 'Speaker: Dialogue' format. Skipping."
        fi
    done

    if [ ${#section_speech_parts[@]} -eq 0 ]; then
        log "WARNING: No speech was generated for section $section_num. Skipping."
        return
    fi

    local concatenated_speech_file="$tmp_dir/section_${section_num}_full_speech.mp3"
    sox "${section_speech_parts[@]}" "$concatenated_speech_file"

    local section_output_file="$tmp_dir/section_${section_num}_final.wav"

    if [ "$NO_MUSIC" = true ]; then
        log "Section $section_num: Generating speech-only audio."
        ffmpeg -y -v error -i "$concatenated_speech_file" -ar 44100 "$section_output_file"
    else
        log "Section $section_num: Mixing speech with background audio."
        local speech_duration
        speech_duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$concatenated_speech_file")
        local speech_delay_s=$((INTRO_DURATION + FADE_DURATION))
        local speech_delay_ms=$((speech_delay_s * 1000))
        local total_duration
        total_duration=$(echo "$speech_duration + $speech_delay_s" | bc -l)

        ffmpeg -y -v error -i "$concatenated_speech_file" -stream_loop -1 -i "$bg_music_file" \
-filter_complex \
"[1:a]volume=eval=frame:volume='if(lt(t,${INTRO_DURATION}),1,if(lt(t,${speech_delay_s}),1-((t-${INTRO_DURATION})*${fade_slope}),${BACKGROUND_VOLUME}))'[bg]; [0:a]adelay=${speech_delay_ms}|${speech_delay_ms}[fg]; [bg][fg]amix=inputs=2:duration=longest" \
-t "$total_duration" -ar 44100 "$section_output_file"
    fi

    final_section_audio_files+=("$section_output_file")
}

# --- Main Script Logic ---

# Make input_file a global so 'die' can access it.
input_file=""

main() {
    # Parse command-line arguments
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --no-music)
                NO_MUSIC=true
                log "Running in --no-music mode. Background audio will be omitted."
                shift
                ;;
            *)
                if [[ -z "$input_file" ]]; then
                    input_file="$1"
                else
                    die "Too many arguments. Please provide only one input file."
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$input_file" ]]; then
        die "No input file provided. Usage: $0 [--no-music] <path_to_input_file>"
    fi

    local base_filename
    base_filename=$(basename "$input_file" .txt)
    local output_file="$OUTPUT_DIR/${base_filename}.wav"
    if [ "$NO_MUSIC" = true ]; then
        output_file="$OUTPUT_DIR/${base_filename}_speech_only.wav"
    fi
    local failed_lines_file="$OUTPUT_DIR/${base_filename}_failed_lines.txt"

    check_dependencies

    if [ ! -f "$ENV_FILE" ]; then die "Env file not found: '$ENV_FILE'"; fi
    source "$ENV_FILE"
    # The :? operator will cause the script to exit if the variable is not set.
    # This is a good thing.
    : "${GCLOUD_PROJECT?$(die "GCLOUD_PROJECT not set in $ENV_FILE")}"
    : "${GOOGLE_APPLICATION_CREDENTIALS?$(die "GOOGLE_APPLICATION_CREDENTIALS not set in $ENV_FILE")}"
    if [ ! -f "$input_file" ]; then die "Input file not found: '$input_file'"; fi

    mkdir -p "$OUTPUT_DIR" || die "Could not create output directory: $OUTPUT_DIR"
    rm -f "$failed_lines_file"

    tmp_dir=$(mktemp -d -t podcast_generator_XXXXXX)
    trap "log 'Cleaning up temporary directory...'; rm -rf -- '$tmp_dir'" EXIT

    fade_slope=$(echo "(1 - $BACKGROUND_VOLUME) / $FADE_DURATION" | bc -l)

    local current_bg_music="$DEFAULT_MUSIC"
    local current_section_lines=()

    while IFS= read -r line; do
        line=$(trim_whitespace "$line")
        if [[ "$line" =~ ^\[Background\ music\ -\ ([0-9]+)\.mp3\]$ ]]; then
            local music_num_from_line="${BASH_REMATCH[1]}"
            # Process the section we've collected so far
            process_section "$current_bg_music" "current_section_lines" "$failed_lines_file"

            # Start a new section
            current_section_lines=()
            local music_num="${music_num_from_line}"
            local next_music_file="$MUSIC_DIR/$(printf "%02d" "$music_num").mp3"

            if [ -f "$next_music_file" ]; then
                current_bg_music="$next_music_file"
            else
                log "WARNING: Music file not found: '$next_music_file'. Using default."
                current_bg_music="$DEFAULT_MUSIC"
            fi
        else
            # Add dialogue line to the current section
            if [[ -n "$line" ]]; then
                current_section_lines+=("$line")
            fi
        fi
    done < "$input_file"

    process_section "$current_bg_music" "current_section_lines" "$failed_lines_file"

    if [ ${#final_section_audio_files[@]} -eq 0 ]; then
        die "No audio sections were successfully processed."
    fi

    log "Concatenating all processed sections into final output..."
    local concat_list_file="$tmp_dir/concat_list.txt"
    for f in "${final_section_audio_files[@]}"; do
        echo "file '$f'" >> "$concat_list_file"
    done

    ffmpeg -y -v error -f concat -safe 0 -i "$concat_list_file" -c copy "$output_file" || die "Failed to concatenate final audio."

    send_webhook_notification "success" "$input_file" "$output_file" ""

    log "--- SUCCESS ---"
    log "Final podcast audio created at: $output_file"
    if [ -f "$failed_lines_file" ]; then
        log "NOTE: Some lines failed to process. See: $failed_lines_file"
    fi
}

main "$@"
