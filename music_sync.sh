#!/bin/bash
# music_sync.sh — Flash drive music sync
#
# Scans a source music library (one subfolder per artist), allocates artists
# across drives by cumulative size, then syncs one drive at a time.
#
# State lives in ~/.musicsync/ and is copied to <drive>/.musicsync/ each run.
#
# Usage:
#   ./music_sync.sh -s <source> -t /Volumes/MUSE1
#   ./music_sync.sh -s <source> -a          # analyze distribution only

set -euo pipefail

# ── Configuration (edit these) ───────────────────────────────────────────────
DRIVE_SIZE_GB=256     # Capacity of each flash drive
BUFFER_GB=5           # Minimum headroom to leave free on each drive
DRIVE_PREFIX="MUSE"   # Volume names: MUSE1, MUSE2, …
STATE_DIR="$HOME/.musicsync"
DRIVE_STATE=".musicsync"        # state subdir written on the drive itself
CACHE_MAX_AGE=3600              # seconds before re-scanning source (1 hr)
# ─────────────────────────────────────────────────────────────────────────────

USABLE_MB=$(( (DRIVE_SIZE_GB - BUFFER_GB) * 1024 ))
MASTER="$STATE_DIR/master_list.txt"
SYNC_STATUS="$STATE_DIR/sync_status.txt"   # records which drives have been synced

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
info()   { echo -e "${BLUE}[INFO]${NC}   $*" >&2; }
ok()     { echo -e "${GREEN}[OK]${NC}     $*" >&2; }
warn()   { echo -e "${YELLOW}[WARN]${NC}   $*" >&2; }
err()    { echo -e "${RED}[ERR]${NC}    $*" >&2; }
action() { echo -e "${CYAN}[>>]${NC}     $*" >&2; }

usage() {
    cat >&2 << EOF
Music Flash Drive Sync

Usage: $0 -s <source_dir> -t <drive_path> [-f]
       $0 -s <source_dir> -a

  -s <path>   Source music dir (one subfolder per artist)
  -t <path>   Target drive  (e.g. /Volumes/MUSE1)
  -a          Analyze: show drive allocation, no changes
  -f          Force rescan of source (ignore cache)
  -h          Help

DRIVE_SIZE_GB=${DRIVE_SIZE_GB}  BUFFER_GB=${BUFFER_GB}  →  ${USABLE_MB} MB usable per drive
Edit those values at the top of this script.
EOF
    exit 1
}

SOURCE_DIR="" DRIVE_PATH="" ANALYZE=false FORCE=false

while getopts "s:t:d:afh" opt; do
    case $opt in
        s)   SOURCE_DIR="${OPTARG%/}" ;;
        t|d) DRIVE_PATH="${OPTARG%/}" ;;
        a)   ANALYZE=true ;;
        f)   FORCE=true ;;
        h)   usage ;;
        \?)  err "Unknown option -$OPTARG"; usage ;;
        :)   err "-$OPTARG requires an argument"; usage ;;
    esac
done

[[ -z "$SOURCE_DIR" ]]                       && { err "Source required (-s)"; usage; }
[[ ! -d "$SOURCE_DIR" ]]                      && { err "Not found: $SOURCE_DIR"; exit 1; }
[[ $ANALYZE = false && -z "$DRIVE_PATH" ]]    && { err "Drive required (-t)"; usage; }
[[ -n "$DRIVE_PATH" && ! -d "$DRIVE_PATH" ]]  && { err "Not found: $DRIVE_PATH"; exit 1; }

mkdir -p "$STATE_DIR"

# ── 1. Build master list ──────────────────────────────────────────────────────
# Scans source, assigns each artist to a drive number, writes master_list.txt.
#
# master_list.txt format (tab-separated, comments start with #):
#   DRIVE_NUM   ARTIST_NAME   SIZE_MB

build_master_list() {
    local stale=true
    if [[ -f "$MASTER" ]] && ! $FORCE; then
        local age=$(( $(date +%s) - $(stat -f %m "$MASTER") ))
        (( age < CACHE_MAX_AGE )) && stale=false
    fi

    if ! $stale; then
        local n
        n=$(grep -vc '^#' "$MASTER" 2>/dev/null || echo 0)
        info "Cached master list: $n artists  ($MASTER)"
        return
    fi

    info "Scanning $SOURCE_DIR …"
    local scan_tmp
    scan_tmp=$(mktemp)
    local count=0

    while IFS= read -r artist; do
        local mb
        mb=$(du -sm "$SOURCE_DIR/$artist" 2>/dev/null | awk '{print int($1)}')
        printf '%s\t%s\n' "$artist" "${mb:-0}" >> "$scan_tmp"
        count=$(( count + 1 ))
        (( count % 50 == 0 )) && info "  … $count artists scanned"
    done < <(find "$SOURCE_DIR" -maxdepth 1 -mindepth 1 -type d -exec basename {} \; | sort)

    ok "Scanned $count artists"

    # Assign drive numbers: fill each drive up to USABLE_MB, then move on.
    # An artist is never split — if it doesn't fit, the drive stops there.
    local drive=1 used_mb=0
    {
        printf '# master_list — source: %s\n' "$SOURCE_DIR"
        printf '# generated: %s\n' "$(date)"
        printf '# drive_size=%dGB  buffer=%dGB  usable_per_drive=%dMB\n' \
            "$DRIVE_SIZE_GB" "$BUFFER_GB" "$USABLE_MB"
        printf '# DRIVE_NUM\tARTIST\tSIZE_MB\n'

        while IFS=$'\t' read -r artist mb; do
            [[ -z "$artist" ]] && continue
            if (( used_mb + mb > USABLE_MB )); then
                drive=$(( drive + 1 ))
                used_mb=0
            fi
            printf '%d\t%s\t%d\n' "$drive" "$artist" "$mb"
            used_mb=$(( used_mb + mb ))
        done < "$scan_tmp"
    } > "$MASTER"

    rm -f "$scan_tmp"

    local num_drives
    num_drives=$(grep -v '^#' "$MASTER" | awk -F'\t' 'BEGIN{m=0}{if($1+0>m)m=$1}END{print m}')
    ok "Master list written: $count artists across $num_drives drives  →  $MASTER"
}

# ── 2. Print distribution summary ────────────────────────────────────────────

show_distribution() {
    local num_drives
    num_drives=$(grep -v '^#' "$MASTER" | awk -F'\t' 'BEGIN{m=0}{if($1+0>m)m=$1}END{print m}')

    echo ""
    printf '  %-12s  %8s  %8s\n' "Drive" "Artists" "Used"
    printf '  %-12s  %8s  %8s\n' "────────────" "────────" "──────"
    for d in $(seq 1 "$num_drives"); do
        local cnt used_gb
        cnt=$(grep -v '^#' "$MASTER" | awk -F'\t' -v d="$d" '$1==d' | wc -l | tr -d ' ')
        used_gb=$(grep -v '^#' "$MASTER" | awk -F'\t' -v d="$d" '$1==d {s+=$3} END{printf "%.1f", s/1024}')
        printf '  %-12s  %8d  %7s GB\n' "${DRIVE_PREFIX}${d}" "$cnt" "$used_gb"
    done
    echo ""
}

# ── 3. Sync status helpers ───────────────────────────────────────────────────

# Record a drive as successfully synced
record_sync() {
    local drive_num="$1" artist_count="$2"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    # Update or append the line for this drive number
    if [[ -f "$SYNC_STATUS" ]] && grep -q "^${drive_num}	" "$SYNC_STATUS"; then
        local tmp
        tmp=$(mktemp)
        grep -v "^${drive_num}	" "$SYNC_STATUS" > "$tmp" || true
        printf '%d\t%s\t%d\n' "$drive_num" "$ts" "$artist_count" >> "$tmp"
        sort -n "$tmp" > "$SYNC_STATUS"
        rm -f "$tmp"
    else
        printf '%d\t%s\t%d\n' "$drive_num" "$ts" "$artist_count" >> "$SYNC_STATUS"
        sort -n "$SYNC_STATUS" -o "$SYNC_STATUS"
    fi
}

# Warn if earlier drives in the set haven't been synced yet
check_sequence() {
    local drive_num="$1"
    if [[ ! -f "$SYNC_STATUS" ]]; then
        if (( drive_num > 1 )); then
            warn "${DRIVE_PREFIX}${drive_num}: no prior sync records — have ${DRIVE_PREFIX}1 through ${DRIVE_PREFIX}$(( drive_num - 1 )) been synced?"
        fi
        return
    fi
    local missing=()
    for (( d=1; d<drive_num; d++ )); do
        grep -q "^${d}	" "$SYNC_STATUS" || missing+=( "${DRIVE_PREFIX}${d}" )
    done
    if (( ${#missing[@]} > 0 )); then
        warn "Syncing ${DRIVE_PREFIX}${drive_num} out of sequence — not yet synced: ${missing[*]}"
        warn "This is fine, but those drives may have stale content."
    fi
}

# Show sync status for all drives in the set
show_sync_status() {
    local num_drives="$1"
    echo ""
    echo "Sync status:"
    for d in $(seq 1 "$num_drives"); do
        if [[ -f "$SYNC_STATUS" ]] && grep -q "^${d}	" "$SYNC_STATUS"; then
            local ts count
            ts=$(    awk -F'\t' -v d="$d" '$1==d {print $2}' "$SYNC_STATUS")
            count=$( awk -F'\t' -v d="$d" '$1==d {print $3}' "$SYNC_STATUS")
            printf '  %s%-2d  ✓  synced %s  (%d artists)\n' "$DRIVE_PREFIX" "$d" "$ts" "$count"
        else
            printf '  %s%-2d  —  not yet synced\n' "$DRIVE_PREFIX" "$d"
        fi
    done
    echo ""
}

# ── 4. Sync one drive ────────────────────────────────────────────────────────

sync_drive() {
    local drive_path="$1" drive_num="$2"
    local vol
    vol=$(basename "$drive_path")

    check_sequence "$drive_num"

    local total_mb avail_mb
    total_mb=$(df -m "$drive_path" | awk 'NR==2 {print int($2)}')
    avail_mb=$(df -m "$drive_path" | awk 'NR==2 {print int($4)}')

    # Push master list to the drive
    local ds="$drive_path/$DRIVE_STATE"
    mkdir -p "$ds"
    cp "$MASTER" "$ds/master_list.txt"
    ok "master_list.txt → $ds/"

    # What SHOULD be on this drive (from master list)
    local tmp_should tmp_on
    tmp_should=$(mktemp); tmp_on=$(mktemp)

    grep -v '^#' "$MASTER" \
        | awk -F'\t' -v d="$drive_num" '$1==d {print $2}' \
        | sort > "$tmp_should"

    # What IS on this drive (non-hidden dirs, skipping .musicsync and system dirs)
    find "$drive_path" -maxdepth 1 -mindepth 1 -type d ! -name '.*' \
        -exec basename {} \; | sort > "$tmp_on"

    local to_remove to_add to_keep
    to_remove=$(comm -13 "$tmp_should" "$tmp_on"  | grep -v '^$' || true)
    to_add=$(   comm -23 "$tmp_should" "$tmp_on"  | grep -v '^$' || true)
    to_keep=$(  comm -12 "$tmp_should" "$tmp_on"  | grep -v '^$' || true)
    rm -f "$tmp_should" "$tmp_on"

    count_n() { [[ -z "$1" ]] && echo 0 || printf '%s\n' "$1" | grep -c '.' || echo 0; }
    local add_n remove_n keep_n
    add_n=$(count_n "$to_add"); remove_n=$(count_n "$to_remove"); keep_n=$(count_n "$to_keep")

    local num_drives
    num_drives=$(grep -v '^#' "$MASTER" | awk -F'\t' 'BEGIN{m=0}{if($1+0>m)m=$1}END{print m}')

    echo ""
    echo "══════════════════════════════════════"
    printf '  %s  (drive #%d of %d)\n' "$vol" "$drive_num" "$num_drives"
    printf '  Free: %d MB of %d MB total\n' "$avail_mb" "$total_mb"
    echo "══════════════════════════════════════"
    printf '  Keep   %d artists\n'  "$keep_n"
    printf '  Add    %d artists\n'  "$add_n"
    printf '  Remove %d artists\n'  "$remove_n"
    echo "══════════════════════════════════════"
    echo ""


    if [[ -n "$to_remove" ]]; then
        echo "To remove:"
        printf '%s\n' "$to_remove" | sed 's/^/  - /'
        echo ""
    fi
    if [[ -n "$to_add" ]]; then
        echo "To add:"
        printf '%s\n' "$to_add" | head -15 | sed 's/^/  + /'
        (( add_n > 15 )) && printf '  … and %d more\n' "$(( add_n - 15 ))"
        echo ""
    fi

    if [[ -z "$to_remove" && -z "$to_add" ]]; then
        echo ""
        ok "$vol — all $keep_n artists already in place, nothing to do."
        record_sync "$drive_num" "$keep_n"
        return
    fi

    printf 'Proceed? (y/N): '
    read -r confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && { warn "Cancelled."; return; }
    echo ""

    # Remove artists no longer assigned to this drive
    if [[ -n "$to_remove" ]]; then
        while IFS= read -r artist; do
            [[ -z "$artist" ]] && continue
            action "Removing: $artist"
            rm -rf "${drive_path:?}/$artist"
            ok "Removed: $artist"
        done <<< "$to_remove"
        echo ""
    fi

    # Add missing artists via rsync
    if [[ -n "$to_add" ]]; then
        local i=0
        while IFS= read -r artist; do
            [[ -z "$artist" ]] && continue
            i=$(( i + 1 ))
            local src="$SOURCE_DIR/$artist"
            [[ ! -d "$src" ]] && { warn "[$i/$add_n] Source missing: $artist"; continue; }

            local need_mb avail_mb
            need_mb=$(du -sm "$src" 2>/dev/null | awk '{print int($1)}')
            avail_mb=$(df -m "$drive_path" | awk 'NR==2 {print int($4)}')
            if (( need_mb > avail_mb )); then
                warn "[$i/$add_n] No space for $artist (need ${need_mb} MB, ${avail_mb} MB free)"
                continue
            fi

            action "[$i/$add_n] $artist  (${need_mb} MB, ${avail_mb} MB free)"
            rsync -a --delete "$src/" "$drive_path/$artist/"
            ok "[$i/$add_n] $artist"
        done <<< "$to_add"
    fi

    echo ""
    ok "Done: $vol"

    # Record successful sync
    local synced_count
    synced_count=$(grep -v '^#' "$MASTER" | awk -F'\t' -v d="$drive_num" '$1==d' | wc -l | tr -d ' ')
    record_sync "$drive_num" "$synced_count"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    info "Source: $SOURCE_DIR"
    echo ""

    # Detect actual drive capacity before building the master list.
    # Flash drives report less than their marketing size when formatted,
    # so use the real number to get correct allocation (and correct removes).
    if [[ -n "$DRIVE_PATH" ]]; then
        local actual_total_mb actual_usable_mb
        actual_total_mb=$(df -m "$DRIVE_PATH" | awk 'NR==2 {print int($2)}')
        actual_usable_mb=$(( actual_total_mb - BUFFER_GB * 1024 ))
        if (( actual_usable_mb != USABLE_MB )); then
            info "Drive actual capacity: ${actual_total_mb} MB  →  ${actual_usable_mb} MB usable (was ${USABLE_MB} MB assumed)"
            USABLE_MB=$actual_usable_mb
            FORCE=true   # rebuild master list with corrected capacity
        fi
    fi

    build_master_list

    if $ANALYZE; then
        show_distribution
        exit 0
    fi

    show_distribution

    # Detect starting drive number
    local vol drive_num
    vol=$(basename "$DRIVE_PATH")
    if [[ "$vol" =~ ^${DRIVE_PREFIX}([0-9]+)$ ]]; then
        drive_num="${BASH_REMATCH[1]}"
    else
        local nd
        nd=$(grep -v '^#' "$MASTER" | awk -F'\t' 'BEGIN{m=0}{if($1+0>m)m=$1}END{print m}')
        warn "Volume '$vol' doesn't match ${DRIVE_PREFIX}N naming"
        printf 'Enter drive number (1–%d): ' "$nd"
        read -r drive_num
    fi

    local num_drives
    num_drives=$(grep -v '^#' "$MASTER" | awk -F'\t' 'BEGIN{m=0}{if($1+0>m)m=$1}END{print m}')

    # Sync drives in sequence, prompting to continue after each one
    while true; do
        sync_drive "$DRIVE_PATH" "$drive_num"

        drive_num=$(( drive_num + 1 ))

        if (( drive_num > num_drives )); then
            show_sync_status "$num_drives"
            ok "All $num_drives drives complete."
            break
        fi

        echo ""
        printf 'Continue to %s%d? (y/N): ' "$DRIVE_PREFIX" "$drive_num"
        read -r cont
        if [[ ! "$cont" =~ ^[Yy]$ ]]; then
            show_sync_status "$num_drives"
            info "Stopped. To resume:  $0 -s \"$SOURCE_DIR\" -t /Volumes/${DRIVE_PREFIX}${drive_num}"
            break
        fi

        # Wait for the correct drive — retry until it's mounted or user quits
        local expected_path="/Volumes/${DRIVE_PREFIX}${drive_num}"
        while true; do
            printf 'Insert %s%d and press Enter (or q to stop): ' "$DRIVE_PREFIX" "$drive_num"
            read -r response
            [[ "$response" =~ ^[Qq]$ ]] && {
                echo ""
                show_sync_status "$num_drives"
                info "Stopped. To resume:  $0 -s \"$SOURCE_DIR\" -t $expected_path"
                exit 0
            }
            if [[ -d "$expected_path" ]]; then
                # Confirm it's really the right drive by checking the volume name
                local found_vol
                found_vol=$(basename "$expected_path")
                if [[ "$found_vol" = "${DRIVE_PREFIX}${drive_num}" ]]; then
                    DRIVE_PATH="$expected_path"
                    break
                fi
            fi
            # Check if a different MUSE drive is mounted where we expected
            local mounted_muse
            mounted_muse=$(find /Volumes -maxdepth 1 -type d -name "${DRIVE_PREFIX}*" \
                           ! -name "${DRIVE_PREFIX}${drive_num}" 2>/dev/null \
                           | head -1 | xargs basename 2>/dev/null || true)
            if [[ -n "$mounted_muse" ]]; then
                warn "Found $mounted_muse but expected ${DRIVE_PREFIX}${drive_num} — please swap drives."
            else
                warn "${DRIVE_PREFIX}${drive_num} not found at $expected_path — is it mounted?"
            fi
        done
    done
}

main
