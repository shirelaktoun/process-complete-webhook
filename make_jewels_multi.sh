#!/bin/bash

#
# Title:        Podcast Raw Audio Generator Script
# Description:  Creates a raw podcast WAV file from a text script using a selected TTS provider.
#               This script is intended to be called by a wrapper script.
# Author:       Jules & User
#

# --- Rigorous Error Handling ---
set -eo pipefail

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
TTS_PROVIDER=""
LANG=""

# Audio processing settings
INTRO_DURATION=5
FADE_DURATION=3
BACKGROUND_VOLUME=0.1


# --- Helper Functions ---

log() {
    echo >&2 "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $@"
}

check_dependencies() {
    for cmd in curl jq ffmpeg ffprobe sox bc gcloud; do
        if ! command -v "$cmd" &> /dev/null; then
            log "FATAL: Required command '$cmd' is not installed."
            exit 1
        fi
    done
}

generate_tts_google() {
    local text="$1"
    local voice="$2"
    local output_file="$3" # Expecting a .wav filename
    local json_payload

    json_payload=$(jq -n --arg text "$text" --arg voice "$voice" --arg lang_code "$Lang_Code" \
        '{"input": {"text": $text}, "voice": {"languageCode": $lang_code, "name": $voice}, "audioConfig": {"audioEncoding": "LINEAR16", "sampleRateHertz": 44100}}')

    local response
    response=$(curl -s -X POST \
        -H "Authorization: Bearer $(gcloud auth application-default print-access-token)" \
        -H "Content-Type: application/json; charset=utf-8" \
        -H "X-Goog-User-Project: $GCLOUD_PROJECT" \
        -d "$json_payload" "$TTS_API_ENDPOINT")

    if echo "$response" | jq -e '.error' > /dev/null; then
        log "ERROR: Google TTS API call failed."
        echo "$response" | jq '.error' >&2
        return 1
    fi
    echo "$response" | jq -r '.audioContent' | base64 --decode > "$output_file"
    log "Successfully saved speech to '$output_file' using Google."
    return 0
}

generate_tts_openai() {
    local text="$1"
    local voice="$2"
    local output_wav_file="$3"
    local model="tts-1" # Can be tts-1 or tts-1-hd

    local json_text
    json_text=$(jq -R -s '.' <<< "$text")

    local json_payload
    json_payload=$(jq -n \
        --arg model "$model" \
        --argjson input "$json_text" \
        --arg voice "$voice" \
        '{"model": $model, "input": $input, "voice": $voice}')

    local max_retries=3
    local retry_count=0
    local success=false

    local temp_mp3_file="${output_wav_file%.*}.mp3"

    while [ $retry_count -lt $max_retries ] && [ "$success" = false ]; do
        response_code=$(curl -s -w "%{http_code}" -X POST "https://api.openai.com/v1/audio/speech" \
            -H "Authorization: Bearer $OPENAI_API_KEY" \
            -H "Content-Type: application/json" \
            -d "$json_payload" \
            --output "$temp_mp3_file")

        if [ "$response_code" -eq 200 ] && [ -s "$temp_mp3_file" ]; then
            success=true
        else
            log "WARNING: OpenAI API call failed with HTTP code $response_code. Attempt $((retry_count + 1)) of $max_retries."
            rm -f "$temp_mp3_file"
            ((retry_count++))
            sleep 1
        fi
    done

    if [ "$success" = false ]; then
        log "ERROR: Failed to generate valid audio from OpenAI after $max_retries attempts."
        return 1
    fi

    if ! ffmpeg -y -v error -i "$temp_mp3_file" -ar 44100 "$output_wav_file"; then
        log "ERROR: Failed to convert OpenAI MP3 output to WAV."
        rm -f "$temp_mp3_file"
        return 1
    fi

    rm -f "$temp_mp3_file"
    log "Successfully saved speech to '$output_wav_file' using OpenAI."
    return 0
}

generate_tts() {
    if [[ "$TTS_PROVIDER" == "openai" ]]; then
        generate_tts_openai "$@"
    else
        generate_tts_google "$@"
    fi
}

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

    log "--- Processing Section $section_num (TTS Provider: $TTS_PROVIDER) ---"
    log "Using background music: $bg_music_file"

    local section_speech_parts=()
    local line_num=0
    for line in "${lines_ref[@]}"; do
        ((line_num++))
        local text voice speaker dialogue
        if [[ "$line" =~ ^([^:]+):(.*)$ ]]; then
            speaker="${BASH_REMATCH[1]}"
            dialogue="${BASH_REMATCH[2]}"

            if [[ "$TTS_PROVIDER" == "openai" ]]; then
                case "$speaker" in
                    Ελένη|Eleni|Deborah|Azra) voice="alloy" ;;
                    Barış|Baris|Kieran) voice="onyx" ;;
                    *)
                        log "WARNING: L${line_num} in Sec${section_num} has unknown speaker '$speaker' for OpenAI. Skipping."
                        continue
                        ;;
                esac
            else
                case "$LANG" in
                    "tr")
                        case "$speaker" in
                            ş|ış|rış|arış|Barış) voice="$VOICE_BARIS" ;;
                            a|ra|zra|Azra) voice="$VOICE_AZRA" ;;
                            *)
                                log "WARNING: L${line_num} in Sec${section_num} has unknown speaker '$speaker' for Turkish. Skipping."
                                continue
                                ;;
                        esac
                        ;;
                    "gr")
                        case "$speaker" in
                            Eleni) voice="$VOICE_ELENI" ;;
                            Barış|Baris)
                                if [[ -z "$VOICE_BARIS" ]]; then
                                    log "WARNING: No male Greek voice is available from Google for speaker '$speaker'. Skipping. Use the 'OpenAI_' prefix on your filename to use OpenAI TTS."
                                    continue
                                fi
                                voice="$VOICE_BARIS"
                                ;;
                            *)
                                log "WARNING: L${line_num} in Sec${section_num} has unknown speaker '$speaker' for Greek. Skipping."
                                continue
                                ;;
                        esac
                        ;;
                    "en"|*)
                        case "$speaker" in
                            n|an|ran|eran|ieran|Kieran) voice="$VOICE_KIERAN" ;;
                            h|ah|rah|orah|borah|eborah|Deborah) voice="$VOICE_DEBORAH" ;;
                            *)
                                log "WARNING: L${line_num} in Sec${section_num} has unknown speaker '$speaker' for English. Skipping."
                                continue
                                ;;
                        esac
                        ;;
                esac
            fi

            text=$(trim_whitespace "$dialogue")
            if [[ -z "$text" ]]; then continue; fi

            local speech_part_file="$tmp_dir/section_${section_num}_speech_${line_num}.wav"
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

    local concatenated_speech_file="$tmp_dir/section_${section_num}_full_speech.wav"
    sox "${section_speech_parts[@]}" "$concatenated_speech_file"

    local section_output_file="$tmp_dir/section_${section_num}_final.wav"

    if [ "$NO_MUSIC" = true ]; then
        log "Section $section_num: Generating speech-only audio."
        cp "$concatenated_speech_file" "$section_output_file"
    else
        local temp_bg_wav="$tmp_dir/section_${section_num}_bg.wav"
        log "Converting background music '$bg_music_file' to temporary WAV file..."
        if ! ffmpeg -y -v error -i "$bg_music_file" -ar 44100 "$temp_bg_wav"; then
            log "WARNING: Failed to convert background music to WAV. Generating this section without music."
            cp "$concatenated_speech_file" "$section_output_file"
        else
            log "Section $section_num: Mixing speech with background audio."
            local speech_duration
            speech_duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$concatenated_speech_file")
            local speech_delay_s=$((INTRO_DURATION + FADE_DURATION))
            local speech_delay_ms=$((speech_delay_s * 1000))
            local total_duration
            total_duration=$(echo "$speech_duration + $speech_delay_s" | bc -l)

            ffmpeg -y -v error -i "$concatenated_speech_file" -stream_loop -1 -i "$temp_bg_wav" \
            -filter_complex \
"[1:a]volume=eval=frame:volume='if(lt(t,${INTRO_DURATION}),1,if(lt(t,${speech_delay_s}),1-((t-${INTRO_DURATION})*${fade_slope}),${BACKGROUND_VOLUME}))'[bg]; [0:a]adelay=${speech_delay_ms}|${speech_delay_ms}[fg]; [bg][fg]amix=inputs=2:duration=longest" \
            -t "$total_duration" -ar 44100 "$section_output_file"
        fi
    fi

    final_section_audio_files+=("$section_output_file")
}

# --- Main Script Logic ---
main() {
    if [[ "$(basename "$input_file")" == OpenAI_* ]]; then
        log "OpenAI TTS provider requested."
        TTS_PROVIDER="openai"
    else
        TTS_PROVIDER="google"
    fi

    case "$input_file" in
        *_gr*.txt)
            log "Greek language file detected from suffix."
            LANG="gr"
            ;;
        *_t*.txt)
            log "Turkish language file detected from suffix."
            LANG="tr"
            ;;
        *_en*.txt)
            log "English language file detected from suffix."
            LANG="en"
            ;;
        *)
            log "No specific language suffix detected. Defaulting to English."
            LANG="en"
            ;;
    esac

    if [[ "$TTS_PROVIDER" == "google" ]]; then
        TTS_API_ENDPOINT="https://eu-texttospeech.googleapis.com/v1/text:synthesize"
        case "$LANG" in
            "tr")
                Lang_Code="tr-TR"
                VOICE_AZRA="tr-TR-Chirp3-HD-Leda"
                VOICE_BARIS="tr-TR-Chirp3-HD-Rasalgethi"
                ;;
            "gr")
                Lang_Code="el-GR"
                VOICE_ELENI="el-GR-Wavenet-B"
                VOICE_BARIS=""
                ;;
            "en"|*)
                Lang_Code="en-GB"
                VOICE_DEBORAH="en-GB-Chirp3-HD-Leda"
                VOICE_KIERAN="en-GB-Chirp3-HD-Rasalgethi"
                ;;
        esac
    fi

    local base_filename
    base_filename=$(basename "$input_file" .txt)
    local output_file="$OUTPUT_DIR/${base_filename}.wav"
    if [ "$NO_MUSIC" = true ]; then
        output_file="$OUTPUT_DIR/${base_filename}_speech_only.wav"
    fi
    local failed_lines_file="$OUTPUT_DIR/${base_filename}_failed_lines.txt"

    check_dependencies

    if [ ! -f "$ENV_FILE" ]; then log "FATAL: Env file not found: '$ENV_FILE'"; exit 1; fi
    source "$ENV_FILE"

    if [[ "$TTS_PROVIDER" == "openai" ]]; then
        if [ -z "$OPENAI_API_KEY" ]; then log "FATAL: OPENAI_API_KEY not set in $ENV_FILE"; exit 1; fi
    else
        if [ -z "$GCLOUD_PROJECT" ]; then log "FATAL: GCLOUD_PROJECT not set in $ENV_FILE"; exit 1; fi
        if [ -z "$GOOGLE_APPLICATION_CREDENTIALS" ]; then log "FATAL: GOOGLE_APPLICATION_CREDENTIALS not set in $ENV_FILE"; exit 1; fi
    fi

    if [ ! -f "$input_file" ]; then log "FATAL: Input file not found: '$input_file'"; exit 1; fi

    mkdir -p "$OUTPUT_DIR"
    rm -f "$failed_lines_file"

    tmp_dir=$(mktemp -d -t podcast_generator_XXXXXX)
    trap "log 'Cleaning up generator temporary directory...'; rm -rf -- '$tmp_dir'" EXIT

    fade_slope=$(echo "(1 - $BACKGROUND_VOLUME) / $FADE_DURATION" | bc -l)

    # The main processing logic is wrapped in a group command to prevent
    # the `while read` loop from running in a subshell, which would cause
    # variables modified inside the loop to be lost.
    {
        local current_bg_music="$DEFAULT_MUSIC"
        local current_section_lines=()

        while IFS= read -r line; do
            line=$(trim_whitespace "$line")
            if [[ "$line" =~ ^\[Background\ music\ -\ ([0-9]+)\.mp3\]$ ]]; then
                local music_num_from_line="${BASH_REMATCH[1]}"
                process_section "$current_bg_music" "current_section_lines" "$failed_lines_file"
                current_section_lines=()
                local music_num_decimal=$((10#$music_num_from_line))
                local next_music_file="$MUSIC_DIR/$(printf "%02d" "$music_num_decimal").mp3"
                if [ -f "$next_music_file" ]; then
                    current_bg_music="$next_music_file"
                else
                    log "WARNING: Music file not found: '$next_music_file'. Using default."
                    current_bg_music="$DEFAULT_MUSIC"
                fi
            else
                if [[ -n "$line" ]]; then
                    current_section_lines+=("$line")
                fi
            fi
        done

        # Process the final section of the file
        process_section "$current_bg_music" "current_section_lines" "$failed_lines_file"

        if [ ${#final_section_audio_files[@]} -eq 0 ]; then
            log "FATAL: No audio sections were successfully processed."
            exit 1
        fi

        log "Concatenating all processed sections into final output..."
        local concat_list_file="$tmp_dir/concat_list.txt"
        for f in "${final_section_audio_files[@]}"; do
            echo "file '$f'" >> "$concat_list_file"
        done

        if ! ffmpeg -y -v error -f concat -safe 0 -i "$concat_list_file" "$output_file"; then
            log "FATAL: Failed to concatenate final audio."
            exit 1
        fi

        log "--- RAW WAV GENERATION SUCCESS ---"
        log "Final podcast audio created at: $output_file"
        if [ -f "$failed_lines_file" ]; then
            log "NOTE: Some lines failed to process. See: $failed_lines_file"
        fi
    } < "$input_file"
}

# --- Argument Parsing ---
input_file=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --no-music)
            NO_MUSIC=true
            shift
            ;;
        *)
            if [[ -z "$input_file" ]]; then
                input_file="$1"
            else
                log "FATAL: Too many arguments. Please provide only one input file."
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$input_file" ]]; then
    log "FATAL: No input file provided. Usage: $0 [--no-music] <path_to_input_file>"
    exit 1
fi

main
