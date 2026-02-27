# Music Flash Drive Sync

Two scripts for syncing a music library to a set of flash drives. The library is expected to contain one subfolder per artist, with albums and tracks nested inside.

```
/Volumes/matisse_space/Music/
├── Aerosmith/
│   ├── Toys in the Attic/
│   │   ├── 01 Toys in the Attic.flac
│   │   └── ...
│   └── Rocks/
├── Led Zeppelin/
└── ...
```

Drives are expected to be named `MUSE1`, `MUSE2`, `MUSE3`, etc. and formatted as **exFAT**.

---

## Script 1 — music_rsync_with_space_check.sh

**Use this to fill a blank drive for the first time.**

Copies artist folders from source to a target drive one at a time, alphabetically. Checks available space before each copy and stops cleanly when the drive is full, printing the exact command needed to resume on the next blank drive.

### Flags

| Flag | Argument | Required | Description |
|------|----------|----------|-------------|
| `-s` | `<path>` | Yes | Source music directory containing artist subfolders |
| `-t` | `<path>` | Yes | Target drive path (e.g. `/Volumes/MUSE1`) |
| `-b` | `<folder name>` | No | Artist name to start from — used to resume on a new drive at the point where the previous one filled up |
| `-h` | — | No | Show usage help |

### Usage

```bash
# Fill the first blank drive
./music_rsync_with_space_check.sh \
  -s /Volumes/matisse_space/Music \
  -t /Volumes/MUSE1

# Resume on the next blank drive starting where MUSE1 stopped
./music_rsync_with_space_check.sh \
  -s /Volumes/matisse_space/Music \
  -t /Volumes/MUSE2 \
  -b "Jesse Cook"
```

### What it does

1. Scans the source directory and collects all artist folders, sorted alphabetically
2. If `-b` is given, skips forward to that artist in the sorted list
3. For each artist folder in order:
   - Measures the source folder size
   - Checks free space on the target (requires folder size + 10% headroom)
   - If enough space: runs `rsync -avzx --progress` to copy the folder
   - If not enough space: stops, logs `STOPPED_AT: <artist>`, prints the exact `-b` command to resume on the next drive
4. On Ctrl-C or a mid-copy space failure, cleans up the partial copy
5. Prints a final summary: folders copied, space used, space remaining
6. Writes a timestamped log file to `<target_drive>/rsync_log_YYYYMMDD_HHMMSS.txt`

### Stopping and resuming

When the drive fills up the output ends with:

```
[WARNING] STOPPING: Not enough space to continue
[WARNING] Stopped at folder: Jesse Cook
[INFO]    To continue on next drive, use:

  ./music_rsync_with_space_check.sh \
    -s "/Volumes/matisse_space/Music" \
    -t /path/to/next/drive \
    -b "Jesse Cook"
```

Eject the full drive, insert a blank one, and run that command verbatim.

### Notes

- **Additive only** — never deletes anything from the destination
- **No state tracking** — each run is independent; the script has no knowledge of previous runs or other drives
- The 10% space buffer is hardcoded in `REQUIRED_SPACE=$(( FOLDER_SIZE * 110 / 100 ))`

---

## Script 2 — music_sync.sh

**Use this to maintain and rebalance an already-populated set of drives.**

Calculates which artists belong on which drive based on the actual formatted capacity of the drives, then for each drive: removes artists that no longer belong there and rsyncs any that are missing. Handles the case where drives were originally filled with an incorrect size assumption (e.g. treating a 228 GB formatted drive as 256 GB).

### Configuration

Edit these variables at the top of the script before first use:

| Variable | Default | Description |
|----------|---------|-------------|
| `DRIVE_SIZE_GB` | `256` | Nominal drive capacity — the script auto-detects actual formatted size and overrides this automatically |
| `BUFFER_GB` | `5` | Minimum free headroom to keep on each drive after allocation |
| `DRIVE_PREFIX` | `MUSE` | Volume name prefix — drives must be named `MUSE1`, `MUSE2`, etc. |
| `CACHE_MAX_AGE` | `3600` | Seconds before the source library scan cache expires (1 hour) |

### Flags

| Flag | Argument | Required | Description |
|------|----------|----------|-------------|
| `-s` | `<path>` | Yes | Source music directory (one subfolder per artist) |
| `-t` | `<path>` | Yes* | Target drive path (e.g. `/Volumes/MUSE1`) |
| `-d` | `<path>` | Yes* | Alias for `-t` |
| `-a` | — | No | Analyze only — print drive allocation table, make no changes. Does not require `-t` |
| `-f` | — | No | Force rescan — rebuild master list from source even if the cache is fresh. Use after adding or removing music |
| `-h` | — | No | Show usage help |

\* `-t` or `-d` is required unless `-a` is used alone.

### Usage

```bash
# See how the library would be split across drives (no changes made)
./music_sync.sh -s /Volumes/matisse_space/Music -a

# Sync MUSE1, then offer to continue to MUSE2, MUSE3, etc.
./music_sync.sh -s /Volumes/matisse_space/Music -t /Volumes/MUSE1

# Start or resume at a specific drive
./music_sync.sh -s /Volumes/matisse_space/Music -t /Volumes/MUSE2

# Force a fresh source scan (after adding new artists)
./music_sync.sh -s /Volumes/matisse_space/Music -t /Volumes/MUSE1 -f
```

### Step-by-step flow

#### 1. Detect actual drive capacity

Reads the real formatted size of the connected drive using `df`. A drive marketed as 256 GB typically formats to ~228–233 GB. If the detected capacity differs from `DRIVE_SIZE_GB * 1024`, the script:

- Logs the discrepancy
- Recalculates usable space from the real number
- Forces a master list rebuild

This corrects over-allocation without requiring manual adjustment of `DRIVE_SIZE_GB`.

#### 2. Build the master list

Scans every artist folder in the source, records its size, then assigns artists to drive numbers by walking alphabetically and filling each drive up to its usable capacity before moving to the next. No artist is ever split across drives.

Result is written to `~/.musicsync/master_list.txt`:

```
# DRIVE_NUM   ARTIST             SIZE_MB
1             'Til Tuesday       8
1             2CELLOS            194
1             Aerosmith          412
...
2             Led Zeppelin       1843
...
3             Wilco              634
```

The scan is cached for one hour. Use `-f` to force a fresh scan.

#### 3. Show distribution summary

Prints a table showing how many artists and how many GB are allocated to each drive:

```
  Drive          Artists      Used
  ────────────  ────────  ──────
  MUSE1              330    227.8 GB
  MUSE2              334    227.9 GB
  MUSE3              144    152.8 GB
```

#### 4. Write index to the drive

Copies `master_list.txt` to `<drive>/.musicsync/master_list.txt`. Every drive in the set carries an identical copy so you can see the full allocation from any drive.

#### 5. Diff: what should be vs. what is

Compares artists assigned to this drive number in the master list against the artist folders physically present at the drive root:

- **Keep** — present on drive and in master list → no action
- **Remove** — on drive but not in master list (overflow from prior over-allocation, or artists removed from source)
- **Add** — in master list but not on drive (new artists, or artists that shifted to this drive after rebalancing)

Prints the full plan with counts and artist names, then asks `Proceed? (y/N)`.

#### 6. Execute

On confirmation:

1. **Removes** each unwanted artist folder with `rm -rf`
2. **Adds** each missing artist with `rsync -a --delete`, checking live free space on the drive before each copy and skipping with a warning if there is not enough room

When a drive is already fully in sync:

```
[OK]     MUSE1 — all 330 artists already in place, nothing to do.
```

#### 7. Continue to next drive

After each drive completes, the script offers to continue:

```
Continue to MUSE2? (y/N):
```

- **y** — prompts to swap drives, then verifies the correct volume is mounted before proceeding. If the wrong drive is inserted, warns and asks again:
  ```
  [WARN]   Found MUSE3 but expected MUSE2 — please swap drives.
  Insert MUSE2 and press Enter (or q to stop):
  ```
- **n** or **q** — prints the sync status table and the exact command to resume, then exits

### Sync status tracking

Each time a drive finishes (whether changes were made or it was already current), the result is recorded in `~/.musicsync/sync_status.txt`. This table is printed whenever the script stops:

```
Sync status:
  MUSE1   ✓  synced 2026-02-26 22:00:00  (330 artists)
  MUSE2   ✓  synced 2026-02-26 22:47:00  (334 artists)
  MUSE3   —  not yet synced
```

If a drive is synced out of sequence (e.g. MUSE3 before MUSE2), the script warns but proceeds:

```
[WARN]   Syncing MUSE3 out of sequence — not yet synced: MUSE2
[WARN]   This is fine, but those drives may have stale content.
```

### State files

| Path | Description |
|------|-------------|
| `~/.musicsync/master_list.txt` | Full artist-to-drive allocation; rebuilt on scan |
| `~/.musicsync/sync_status.txt` | Per-drive sync history |
| `<drive>/.musicsync/master_list.txt` | Copy of master list written to every drive |

---

## Typical workflow

### Initial population of blank drives

Use `music_rsync_with_space_check.sh` to fill each drive in sequence. It stops at the right point and tells you where the next drive should begin with `-b`.

### Ongoing maintenance

Once the drives are populated, use `music_sync.sh` for all subsequent work:

```bash
# After adding new artists to the source library
./music_sync.sh -s /Volumes/matisse_space/Music -t /Volumes/MUSE1 -f
# answer y at each "Continue to MUSE2?" prompt to work through all drives

# Routine check — verify everything is current (no rescan needed if < 1 hour old)
./music_sync.sh -s /Volumes/matisse_space/Music -t /Volumes/MUSE1

# Check the allocation without connecting a drive
./music_sync.sh -s /Volumes/matisse_space/Music -a
```

### After `music_sync.sh` rebalances allocation

If `music_sync.sh` detects the drives are a different size than assumed and rebalances (removing overflow artists from MUSE1, moving them to MUSE2, etc.), run through all drives in order to propagate the changes:

```bash
./music_sync.sh -s /Volumes/matisse_space/Music -t /Volumes/MUSE1 -f
# continue through MUSE2, MUSE3 at the prompts
```
