#!/bin/bash

# Script to rsync folders one by one, handling space constraints
# Usage: ./rsync_with_space_check.sh -s <source_dir> -t <target_dir> [-b <starting_folder>]
# Example: ./rsync_with_space_check.sh -s /Volumes/Stuff/Kahn/Audiophile/ALAC/ -t /Volumes/PASSPORT/ -b "Gentle Giant"

echo "DEBUG: Script started"

# Less strict error handling to see what's happening
set -e

# Trap handler for clean exit on Ctrl-C
trap 'echo ""; log_warning "Script interrupted by user (Ctrl-C)"; log_info "Log file: ${LOG_FILE:-<not created yet>}"; exit 130' INT TERM

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to get available space in bytes
get_available_space() {
    local path="$1"
    # Use -k to force 1K blocks, get the available space (4th column)
    df -k "$path" | awk 'NR==2 {print $4 * 1024}'
}

# Function to get directory size in bytes
get_dir_size() {
    local path="$1"
    # Use -s for summary, -k for kilobytes
    du -sk "$path" 2>/dev/null | awk '{print $1 * 1024}'
}

# Function to format bytes to human readable
format_bytes() {
    local bytes=$1
    local gb=$((bytes / 1073741824))
    local mb=$((bytes / 1048576))
    local kb=$((bytes / 1024))
    
    if [ $bytes -lt 1024 ]; then
        echo "${bytes}B"
    elif [ $bytes -lt 1048576 ]; then
        echo "${kb}KB"
    elif [ $bytes -lt 1073741824 ]; then
        echo "${mb}MB"
    else
        # For GB, show with one decimal place
        local gb_int=$((bytes / 1073741824))
        local remainder=$((bytes % 1073741824))
        local decimal=$((remainder * 10 / 1073741824))
        echo "${gb_int}.${decimal}GB"
    fi
}

# Function to clean up partial copy
cleanup_partial() {
    local dest_path="$1"
    local folder_name="$2"
    
    if [ -d "$dest_path/$folder_name" ]; then
        log_warning "Cleaning up partial copy: $folder_name"
        rm -rf "$dest_path/$folder_name"
        log_info "Cleanup complete"
    fi
}

# Function to show usage
usage() {
    echo "Usage: $0 -s <source_dir> -t <target_dir> [-b <starting_folder>]"
    echo ""
    echo "Options:"
    echo "  -s  Source directory containing folders to copy (required)"
    echo "  -t  Target/destination directory (required)"
    echo "  -b  Beginning folder name to start from (optional, alphabetically)"
    echo "  -h  Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 -s /Volumes/Stuff/Kahn/Audiophile/ALAC/ -t /Volumes/PASSPORT/"
    echo "  $0 -s /Volumes/Stuff/Kahn/Audiophile/ALAC/ -t /Volumes/PASSPORT/ -b \"Gentle Giant\""
    exit 1
}

# Initialize variables
SOURCE_DIR=""
DEST_DIR=""
START_FOLDER=""

echo "DEBUG: Parsing arguments: $@"

# Parse command line options
while getopts "s:t:b:h" opt; do
    case $opt in
        s)
            SOURCE_DIR="${OPTARG%/}"  # Remove trailing slash
            ;;
        t)
            DEST_DIR="${OPTARG%/}"    # Remove trailing slash
            ;;
        b)
            START_FOLDER="$OPTARG"
            ;;
        h)
            usage
            ;;
        \?)
            echo "Error: Invalid option: -$OPTARG" >&2
            usage
            ;;
        :)
            echo "Error: Option -$OPTARG requires an argument" >&2
            usage
            ;;
    esac
done

# Check required arguments
if [ -z "$SOURCE_DIR" ] || [ -z "$DEST_DIR" ]; then
    echo "Error: Both -s (source) and -t (target) are required" >&2
    echo ""
    usage
fi

echo "DEBUG: Source: $SOURCE_DIR"
echo "DEBUG: Target: $DEST_DIR"
echo "DEBUG: Start folder: ${START_FOLDER:-<none>}"

# Validate source directory
if [ ! -d "$SOURCE_DIR" ]; then
    echo "Error: Source directory does not exist: $SOURCE_DIR" >&2
    exit 1
fi

# Validate destination directory
if [ ! -d "$DEST_DIR" ]; then
    echo "Error: Destination directory does not exist: $DEST_DIR" >&2
    exit 1
fi

# Create log file
LOG_FILE="${DEST_DIR}/rsync_log_$(date +%Y%m%d_%H%M%S).txt"
log_info "Logging to: $LOG_FILE"

# Initialize counters
COPIED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0
STOPPED_FOLDER=""

# Get list of folders sorted alphabetically
log_info "Scanning source directory: $SOURCE_DIR"

echo "DEBUG: Running find command..."
FOLDERS=()
while IFS= read -r folder; do
    FOLDERS+=("$folder")
done < <(find "$SOURCE_DIR" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; 2>&1 | sort)

echo "DEBUG: Found ${#FOLDERS[@]} folders"

if [ ${#FOLDERS[@]} -eq 0 ]; then
    log_error "No folders found in source directory"
    exit 1
fi

log_info "Found ${#FOLDERS[@]} folders"

# Find starting position
START_INDEX=0
if [ -n "$START_FOLDER" ]; then
    log_info "Looking for starting folder: $START_FOLDER"
    for i in "${!FOLDERS[@]}"; do
        if [ "${FOLDERS[$i]}" = "$START_FOLDER" ]; then
            START_INDEX=$i
            log_success "Starting from folder: $START_FOLDER (index $START_INDEX)"
            break
        fi
    done
    
    if [ $START_INDEX -eq 0 ] && [ "${FOLDERS[0]}" != "$START_FOLDER" ]; then
        log_warning "Starting folder not found, starting from beginning"
    fi
fi

# Initial space check
echo "DEBUG: df output for $DEST_DIR:"
df -k "$DEST_DIR"
INITIAL_SPACE=$(get_available_space "$DEST_DIR")
echo "DEBUG: Initial space in bytes: $INITIAL_SPACE"
log_info "Initial available space on destination: $(format_bytes $INITIAL_SPACE)"
echo ""

# Process each folder
for i in $(seq $START_INDEX $((${#FOLDERS[@]} - 1))); do
    FOLDER="${FOLDERS[$i]}"
    SOURCE_PATH="$SOURCE_DIR/$FOLDER"
    
    log_info "[$((i+1))/${#FOLDERS[@]}] Processing: $FOLDER"
    
    # Get folder size
    FOLDER_SIZE=$(get_dir_size "$SOURCE_PATH")
    log_info "  Folder size: $(format_bytes $FOLDER_SIZE)"
    
    # Check available space
    AVAILABLE_SPACE=$(get_available_space "$DEST_DIR")
    log_info "  Available space: $(format_bytes $AVAILABLE_SPACE)"
    
    # Add 10% buffer for safety
    REQUIRED_SPACE=$(( FOLDER_SIZE * 110 / 100 ))
    
    if [ $AVAILABLE_SPACE -lt $REQUIRED_SPACE ]; then
        log_warning "  Insufficient space for this folder (need $(format_bytes $REQUIRED_SPACE))"
        log_warning "  STOPPING: Not enough space to continue"
        STOPPED_FOLDER="$FOLDER"
        echo "STOPPED_AT: $FOLDER" >> "$LOG_FILE"
        break
    fi
    
    # Perform rsync
    log_info "  Starting rsync..."
    
    if rsync -avzx --progress "$SOURCE_PATH/" "$DEST_DIR/$FOLDER/" 2>&1 | tee -a "$LOG_FILE"; then
        log_success "  ✓ Successfully copied: $FOLDER"
        echo "SUCCESS: $FOLDER" >> "$LOG_FILE"
        COPIED_COUNT=$((COPIED_COUNT + 1))
    else
        RSYNC_EXIT=$?
        
        # Check if user interrupted (Ctrl-C)
        if [ $RSYNC_EXIT -eq 130 ] || [ $RSYNC_EXIT -eq 20 ]; then
            log_warning "  Rsync interrupted by user"
            cleanup_partial "$DEST_DIR" "$FOLDER"
            echo "INTERRUPTED_AT: $FOLDER" >> "$LOG_FILE"
            log_info "Cleaning up and exiting..."
            exit 130
        fi
        
        log_error "  ✗ Failed to copy: $FOLDER (exit code: $RSYNC_EXIT)"
        
        # Check if it was a space issue
        SPACE_AFTER=$(get_available_space "$DEST_DIR")
        if [ $SPACE_AFTER -lt $(( FOLDER_SIZE / 10 )) ]; then
            log_warning "  Detected space issue during copy"
            cleanup_partial "$DEST_DIR" "$FOLDER"
            STOPPED_FOLDER="$FOLDER"
            echo "STOPPED_AT: $FOLDER (space issue)" >> "$LOG_FILE"
            break
        else
            log_error "  Copy failed for unknown reason"
            echo "FAILED: $FOLDER" >> "$LOG_FILE"
            FAILED_COUNT=$((FAILED_COUNT + 1))
            # Optionally cleanup partial copy
            cleanup_partial "$DEST_DIR" "$FOLDER"
        fi
    fi
    
    echo ""
done

# Final summary
echo ""
echo "========================================="
log_info "COPY SUMMARY"
echo "========================================="
log_success "Successfully copied: $COPIED_COUNT folders"
if [ $FAILED_COUNT -gt 0 ]; then
    log_error "Failed: $FAILED_COUNT folders"
fi

FINAL_SPACE=$(get_available_space "$DEST_DIR")
USED_SPACE=$((INITIAL_SPACE - FINAL_SPACE))
log_info "Space used: $(format_bytes $USED_SPACE)"
log_info "Space remaining: $(format_bytes $FINAL_SPACE)"

if [ -n "$STOPPED_FOLDER" ]; then
    echo ""
    log_warning "Stopped at folder: $STOPPED_FOLDER"
    log_info "To continue on next drive, use:"
    echo ""
    echo "  $0 -s \"$SOURCE_DIR\" -t /path/to/next/drive -b \"$STOPPED_FOLDER\""
    echo ""
fi

log_info "Complete log saved to: $LOG_FILE"
echo "========================================="

