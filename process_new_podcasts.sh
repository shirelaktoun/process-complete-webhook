#!/bin/bash

#
# Title:        Podcast Processing Wrapper Script
# Description:  Finds new podcast text files, processes them using the main script,
#               and archives them.
# Author:       Jules
#

# --- Configuration ---
# The directory where new podcast scripts are uploaded.
INCOMING_DIR="/home/make-sftp/JH/incoming"

# The directory to move processed scripts to.
ARCHIVE_DIR="/home/make-sftp/JH/archive"

# The main podcast generator script to run.
# It is assumed this script is in the same directory as the wrapper.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
SCRIPT_TO_RUN="$SCRIPT_DIR/make_jewel_p1.sh"

# --- Main Logic ---

log() {
    echo >&2 "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $@"
}

log "Starting podcast processing run..."

# Ensure the archive directory exists.
mkdir -p "$ARCHIVE_DIR" || { log "FATAL: Could not create archive directory: $ARCHIVE_DIR"; exit 1; }

# Find and process new text files.
# Use find to handle cases where there are no files gracefully.
find "$INCOMING_DIR" -maxdepth 1 -type f -name "*.txt" -print0 | while IFS= read -r -d '' file; do
    log "--- Found new file: $file ---"

    # Run the main processing script.
    # The main script will handle its own logging and notifications.
    if "$SCRIPT_TO_RUN" "$file"; then
        log "Script processing successful for: $file"
        # Move the file to the archive directory on success.
        mv "$file" "$ARCHIVE_DIR/"
        log "Archived file to: $ARCHIVE_DIR/$(basename "$file")"
    else
        log "ERROR: Script processing failed for: $file"
        # Optionally, move to a 'failed' directory instead of archiving.
        # For now, we leave it in the incoming directory for manual inspection.
    fi
    log "--- Finished processing: $file ---"
done

log "Podcast processing run finished."
