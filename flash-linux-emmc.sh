#!/bin/bash

# Prompt for sudo password immediately
if [ "$EUID" -ne 0 ]; then
    echo "This script requires root privileges. Please enter your sudo password:"
    sudo -v || {
        echo "Error: Failed to obtain root privileges! Please rerun the script and provide a valid password."
        exit 1
    }
    exec sudo "$0" "$@"
fi

# Initial header
clear
echo "$(tput bold)================ Switchroot Linux eMMC Flash Script ================$(tput sgr0)"
echo "Requirements: Linux environment, Hekate, SD card (FAT32), internet."
echo "Fetches Linux variants from download.switchroot.org - Version 1.2.0"
echo "Setting up, please wait..."

# Dependency check
# Allow user to override temp directory via environment variable
# Usage: TEMP_DIR=/path/to/large/disk ./flash-linux-emmc.sh
TEMP_DIR="${TEMP_DIR:-/tmp/switchroot_temp}"
LOG_FILE="$TEMP_DIR/setup_log.txt"

# Check if temp directory is on /tmp and has limited space
if [[ "$TEMP_DIR" == /tmp/* ]]; then
    TMP_AVAIL=$(df /tmp | tail -1 | awk '{print $4}')
    TMP_AVAIL_GB=$((TMP_AVAIL / 1024 / 1024))
    if [ "$TMP_AVAIL_GB" -lt 10 ]; then
        echo "$(tput bold)Warning: /tmp has only ${TMP_AVAIL_GB}GB free space!$(tput sgr0)"
        echo "  Extracting large archives requires ~8-10GB of free space."
        echo ""
        echo "  You can specify a custom temp directory with more space:"
        echo "  $(tput bold)TEMP_DIR=/path/to/large/disk sudo -E ./flash-linux-emmc.sh$(tput sgr0)"
        echo ""
        read -p "Continue anyway? (y/N): " CONTINUE_LOW_SPACE
        if [ "$CONTINUE_LOW_SPACE" != "y" ] && [ "$CONTINUE_LOW_SPACE" != "Y" ]; then
            echo "Exiting. Please specify TEMP_DIR with more space."
            exit 1
        fi
    fi
fi

# Check if temp directory exists and has downloaded files
PRESERVE_DOWNLOADS=false
CACHED_DISTRO=""
CACHED_7Z_FILE=""

if [ -d "$TEMP_DIR" ]; then
    # Look for any .7z files that might be previous downloads
    if ls "$TEMP_DIR"/*.7z >/dev/null 2>&1; then
        CACHED_7Z_FILE=$(ls "$TEMP_DIR"/*.7z | head -1)
        CACHED_7Z_NAME=$(basename "$CACHED_7Z_FILE")

        # Try to detect which distro this is from filename
        if [[ "$CACHED_7Z_NAME" =~ fedora-39 ]]; then
            CACHED_DISTRO="fedora-39"
        elif [[ "$CACHED_7Z_NAME" =~ fedora-41 ]]; then
            CACHED_DISTRO="fedora-41"
        elif [[ "$CACHED_7Z_NAME" =~ fedora-42 ]]; then
            CACHED_DISTRO="fedora-42"
        elif [[ "$CACHED_7Z_NAME" =~ [uU]buntu.*[bB]ionic ]]; then
            CACHED_DISTRO="ubuntu-bionic"
        elif [[ "$CACHED_7Z_NAME" =~ [uU]buntu.*[jJ]ammy ]]; then
            CACHED_DISTRO="ubuntu-jammy"
        elif [[ "$CACHED_7Z_NAME" =~ [uU]buntu.*[nN]oble ]]; then
            CACHED_DISTRO="ubuntu-noble"
        elif [[ "$CACHED_7Z_NAME" =~ lakka ]]; then
            CACHED_DISTRO="lakka"
        fi

        if [ -n "$CACHED_DISTRO" ]; then
            echo "$(tput bold)Found cached download: $CACHED_7Z_NAME$(tput sgr0)"
            echo "  Detected distro: $CACHED_DISTRO"
            echo ""
            read -p "Use this cached download? (Y/n): " USE_CACHED

            if [ "$USE_CACHED" = "n" ] || [ "$USE_CACHED" = "N" ]; then
                echo "  Clearing temp directory to download new distro..."
                rm -rf "$TEMP_DIR"
            else
                echo "  Using cached download"
                PRESERVE_DOWNLOADS=true
                # Move downloads to a safe location temporarily
                mkdir -p "${TEMP_DIR}_backup"
                mv "$TEMP_DIR"/*.7z "${TEMP_DIR}_backup/" 2>/dev/null || true
            fi
        else
            echo "Found existing download but couldn't detect distro"
            PRESERVE_DOWNLOADS=true
            mkdir -p "${TEMP_DIR}_backup"
            mv "$TEMP_DIR"/*.7z "${TEMP_DIR}_backup/" 2>/dev/null || true
        fi
    fi
fi

# Only clean temp dir if not preserving
if [ "$PRESERVE_DOWNLOADS" = false ]; then
    rm -rf "$TEMP_DIR"
fi

mkdir -p "$TEMP_DIR" || {
    echo "Error: Failed to create $TEMP_DIR!"
    exit 1
}
chmod -R u+rw "$TEMP_DIR" || {
    echo "Error: Failed to set permissions on $TEMP_DIR!"
    exit 1
}

# Restore preserved downloads and update CACHED_7Z_FILE path
if [ "$PRESERVE_DOWNLOADS" = true ]; then
    mv "${TEMP_DIR}_backup"/*.7z "$TEMP_DIR/" 2>/dev/null || true
    rm -rf "${TEMP_DIR}_backup"
    # Update CACHED_7Z_FILE to point to the restored location
    if [ -n "$CACHED_7Z_FILE" ]; then
        CACHED_7Z_FILE="$TEMP_DIR/$(basename "$CACHED_7Z_FILE")"
    fi
fi

echo "Checking dependencies..."
COMMANDS=("curl" "gdisk" "bc" "lsblk" "7z" "tar" "mkfs.ext4" "partprobe" "sgdisk" "aria2c")
PACKAGES=("curl" "gdisk" "bc" "lsblk" "p7zip-full" "tar" "e2fsprogs" "parted" "gdisk" "aria2")

for i in "${!COMMANDS[@]}"; do
    cmd="${COMMANDS[$i]}"
    pkg="${PACKAGES[$i]}"
    if ! command -v "$cmd" &> /dev/null; then
        echo "  Installing $pkg (provides $cmd)..."
        echo "Installing $pkg..." >> "$LOG_FILE"
        if ! ping -c 1 download.switchroot.org > /dev/null 2>&1; then
            echo "  Error: No internet connection detected! Please connect and rerun."
            exit 1
        fi
        apt update >> "$LOG_FILE" 2>&1 && apt install -y "$pkg" >> "$LOG_FILE" 2>&1 || {
            echo "  Error: Failed to install $pkg! Check $LOG_FILE for details."
            exit 1
        }
        echo "  $pkg installed successfully."
    fi
done

echo "All dependencies satisfied."
echo ""

# Setup logging
echo "Setup started at $(date)" > "$LOG_FILE"

# Auto-discover Linux distros from the server
BASE_URL="https://download.switchroot.org"
LINUX_KEYWORDS="ubuntu|fedora|lakka|arch|debian|manjaro|opensuse"

# Skip discovery AND file listing if we're using cached distro
SKIP_FILE_LISTING=false
if [ -n "$CACHED_DISTRO" ] && [ "$PRESERVE_DOWNLOADS" = true ]; then
    echo "Skipping distribution discovery (using cached: $CACHED_DISTRO)"
    SUBFOLDERS=("$CACHED_DISTRO")
    SKIP_FILE_LISTING=true
else
    echo "Fetching available distributions..."
    echo "Discovering available distributions from $BASE_URL..."
    echo "Auto-discovery started" >> "$LOG_FILE"

    # Fetch directory listing and extract Linux distro folders
    RAW_LISTING=$(curl -s "$BASE_URL/")
    if [ -z "$RAW_LISTING" ]; then
        echo "  $(tput bold)Error: Failed to fetch distribution list from server!$(tput sgr0)"
        echo "  Check your internet connection and try again."
        exit 1
    fi

    # Extract directory names (href="/dirname/" or href="dirname/") and filter for Linux distros
    SUBFOLDERS=()
    while IFS= read -r dir; do
        if [ -n "$dir" ]; then
            SUBFOLDERS+=("$dir")
            echo "  Discovered: $dir"
            echo "Discovered distro: $dir" >> "$LOG_FILE"
        fi
    done < <(echo "$RAW_LISTING" | grep -oP 'href="/?(\K[^"/]+)(?=/")' | grep -iE "^($LINUX_KEYWORDS)" | sort -u)

    if [ ${#SUBFOLDERS[@]} -eq 0 ]; then
        echo "  $(tput bold)Error: No Linux distributions found on server!$(tput sgr0)"
        echo "  This may indicate a server issue or network problem."
        exit 1
    fi

    echo "Found ${#SUBFOLDERS[@]} distribution(s)."
    echo ""
fi

# Function to generate friendly display name from folder name
get_distro_display_name() {
    local folder="$1"
    local name=""

    # Parse folder name (e.g., "ubuntu-noble" -> "Ubuntu Noble", "fedora-42" -> "Fedora 42")
    if [[ "$folder" =~ ^ubuntu-(.+)$ ]]; then
        local version="${BASH_REMATCH[1]}"
        case "$version" in
            bionic) name="Ubuntu Bionic (18.04)" ;;
            jammy)  name="Ubuntu Jammy (22.04)" ;;
            noble)  name="Ubuntu Noble (24.04)" ;;
            *)      name="Ubuntu ${version^}" ;;  # Capitalize first letter
        esac
    elif [[ "$folder" =~ ^fedora-(.+)$ ]]; then
        name="Fedora ${BASH_REMATCH[1]}"
    elif [[ "$folder" =~ ^lakka$ ]]; then
        name="Lakka (RetroArch)"
    else
        # Generic: capitalize first letter of each word
        name=$(echo "$folder" | sed 's/-/ /g' | sed 's/\b\(.\)/\u\1/g')
    fi

    echo "$name"
}

# Build distro map dynamically
declare -A DISTRO_MAP
for folder in "${SUBFOLDERS[@]}"; do
    DISTRO_MAP["$folder"]="$(get_distro_display_name "$folder")"
    echo "Mapped: $folder -> ${DISTRO_MAP[$folder]}" >> "$LOG_FILE"
done

OPTIONS=()
INDEX=1
MAX_RETRIES=3

# If we're using cached distro, skip file listing and use cached file directly
if [ "$SKIP_FILE_LISTING" = true ] && [ -n "$CACHED_7Z_FILE" ]; then
    echo "Using cached file: $(basename "$CACHED_7Z_FILE")"
    echo "Using cached file: $CACHED_7Z_FILE" >> "$LOG_FILE"

    # Set up variables directly from cached file
    CACHED_7Z_NAME=$(basename "$CACHED_7Z_FILE")
    CACHED_DISTRO_LOWER=$(echo "$CACHED_DISTRO" | tr '[:upper:]' '[:lower:]')

    # Determine variant if applicable
    VARIANT=""
    if [ "$CACHED_DISTRO_LOWER" = "ubuntu-noble" ]; then
        if [[ "$CACHED_7Z_NAME" =~ "kUbuntu" ]]; then
            VARIANT="KUbuntu"
        elif [[ "$CACHED_7Z_NAME" =~ "unity" ]]; then
            VARIANT="Ubuntu Unity"
        fi
    fi

    if [ -n "$VARIANT" ]; then
        OPTION_NAME="${DISTRO_MAP[$CACHED_DISTRO]} - $VARIANT"
    else
        OPTION_NAME="${DISTRO_MAP[$CACHED_DISTRO]}"
    fi

    OPTIONS+=("$INDEX) $OPTION_NAME - $CACHED_7Z_NAME")
    eval "ZIP_URL_$INDEX=$CACHED_7Z_FILE"  # Use local cached file path
    eval "DISTRO_$INDEX=$CACHED_DISTRO"
    eval "ID_$INDEX=SWR-${CACHED_DISTRO%%-*}"
    eval "PREFIX_$INDEX=/switchroot/$CACHED_DISTRO_LOWER/"
    eval "INI_$INDEX=L4T_${CACHED_DISTRO%%-*}.ini"
    INDEX=$((INDEX + 1))
else
    # Normal flow: fetch file listings from server
    for SUBFOLDER in "${SUBFOLDERS[@]}"; do
        SUBFOLDER_LOWER=$(echo "$SUBFOLDER" | tr '[:upper:]' '[:lower:]')
        echo "Fetching $SUBFOLDER_LOWER..." >> "$LOG_FILE"
        RETRY_COUNT=0
        LISTING=""
        while [ -z "$LISTING" ] && [ "$RETRY_COUNT" -lt "$MAX_RETRIES" ]; do
            RAW_LISTING=$(curl -s "$BASE_URL/$SUBFOLDER_LOWER/")
            HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/$SUBFOLDER_LOWER/")
            echo "HTTP status for $BASE_URL/$SUBFOLDER_LOWER/: $HTTP_STATUS" >> "$LOG_FILE"
            if [ "$HTTP_STATUS" != "200" ]; then
                echo "Failed to access $BASE_URL/$SUBFOLDER_LOWER/ (HTTP $HTTP_STATUS)" >> "$LOG_FILE"
                break
            fi
            LISTING=$(echo "$RAW_LISTING" | grep -oP '(?<=href=")[^"]*\.7z(?=")')
            if [ -z "$LISTING" ]; then
                echo "Retry $((RETRY_COUNT + 1)) for $SUBFOLDER_LOWER: No .7z files found" >> "$LOG_FILE"
                RETRY_COUNT=$((RETRY_COUNT + 1))
                sleep 1
            fi
        done
        if [ -n "$LISTING" ]; then
            while IFS= read -r ZIP_FILE; do
                if [ -n "$ZIP_FILE" ]; then
                    echo "Found: $ZIP_FILE in $SUBFOLDER_LOWER" >> "$LOG_FILE"
                    VARIANT=""
                    if [ "$SUBFOLDER_LOWER" = "ubuntu-noble" ]; then
                        if [[ "$ZIP_FILE" =~ "kUbuntu" ]]; then
                            VARIANT="KUbuntu"
                        elif [[ "$ZIP_FILE" =~ "unity" ]]; then
                            VARIANT="Ubuntu Unity"
                        fi
                    fi
                    if [ -n "$VARIANT" ]; then
                        OPTION_NAME="${DISTRO_MAP[$SUBFOLDER_LOWER]} - $VARIANT"
                    else
                        OPTION_NAME="${DISTRO_MAP[$SUBFOLDER_LOWER]}"
                    fi
                    OPTIONS+=("$INDEX) $OPTION_NAME - $ZIP_FILE")
                    eval "ZIP_URL_$INDEX=$BASE_URL$ZIP_FILE"
                    eval "DISTRO_$INDEX=$SUBFOLDER"
                    eval "ID_$INDEX=SWR-${SUBFOLDER%%-*}"
                    eval "PREFIX_$INDEX=/switchroot/$SUBFOLDER_LOWER/"
                    eval "INI_$INDEX=L4T_${SUBFOLDER%%-*}.ini"
                    INDEX=$((INDEX + 1))
                fi
            done <<< "$LISTING"
        else
            echo "Failed to fetch .7z files from $SUBFOLDER_LOWER after $MAX_RETRIES retries" >> "$LOG_FILE"
        fi
        echo -n "."
    done

    echo # Newline after dots
    echo ""
fi

if [ ${#OPTIONS[@]} -eq 0 ]; then
    echo "$(tput bold)Error: No Linux variants found!$(tput sgr0)"
    echo "  Check $LOG_FILE for details."
    exit 1
fi

# Spinner function (simplified)
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    printf "  [ ] "
    while [ -d /proc/$pid ]; do
        local temp=${spinstr#?}
        printf "\b\b\b[%c]" "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
    done
    printf "\b\b\b[Done]\n"
}

# Step 1: Select Distro
echo "$(tput bold)========== Step 1: Select Linux Distribution ==========$(tput sgr0)"

# Check if we have a cached distro and can auto-select it
AUTO_SELECT_INDEX=""
if [ -n "$CACHED_DISTRO" ] && [ "$PRESERVE_DOWNLOADS" = true ]; then
    # Find the index for the cached distro
    for i in $(seq 1 $((INDEX - 1))); do
        DISTRO_VAR="DISTRO_$i"
        DISTRO_VAL=$(eval echo \$$DISTRO_VAR)
        DISTRO_VAL_LOWER=$(echo "$DISTRO_VAL" | tr '[:upper:]' '[:lower:]')
        if [ "$DISTRO_VAL_LOWER" = "$CACHED_DISTRO" ]; then
            AUTO_SELECT_INDEX=$i
            break
        fi
    done

    if [ -n "$AUTO_SELECT_INDEX" ]; then
        echo "  Auto-selecting cached distro: $(eval echo \$DISTRO_$AUTO_SELECT_INDEX)"
        DISTRO_CHOICE=$AUTO_SELECT_INDEX

        # Extract variables immediately for auto-selected distro
        DISTRO=$(eval echo \$DISTRO_$AUTO_SELECT_INDEX)
        ZIP_URL=$(eval echo \$ZIP_URL_$AUTO_SELECT_INDEX)
        ID=$(eval echo \$ID_$AUTO_SELECT_INDEX)
        PREFIX=$(eval echo \$PREFIX_$AUTO_SELECT_INDEX)
        INI=$(eval echo \$INI_$AUTO_SELECT_INDEX)
        # Check if ZIP_URL is a local file path (cached file) or remote URL
        if [[ "$ZIP_URL" =~ ^https?:// ]]; then
            IS_LOCAL="false"
        else
            IS_LOCAL="true"
        fi
    fi
fi

# Only show selection menu if not auto-selected
if [ -z "$AUTO_SELECT_INDEX" ]; then
    echo "Available distributions for eMMC installation:"
    OPTIONS=("0) Use local OS image file (.7z)" "${OPTIONS[@]}")
    for OPT in "${OPTIONS[@]}"; do
        echo "  $OPT"
    done
    echo "----------"
fi

while [ -z "$DISTRO_CHOICE" ]; do
    read -p "$(tput bold)Enter number (0-$(( ${#OPTIONS[@]} - 1 ))) or 'retry': $(tput sgr0)" DISTRO_CHOICE
    if [ "$DISTRO_CHOICE" = "retry" ]; then
        echo "Refreshing selection..."
        continue
    fi
    if [[ "$DISTRO_CHOICE" =~ ^[0-9]+$ ]] && [ "$DISTRO_CHOICE" -ge 0 ] && [ "$DISTRO_CHOICE" -lt "${#OPTIONS[@]}" ]; then
        if [ "$DISTRO_CHOICE" -eq 0 ]; then
            read -p "$(tput bold)Enter path and file name to local Switchroot .7z file (or press Enter to skip): $(tput sgr0)" LOCAL_7Z_PATH
            if [ -z "$LOCAL_7Z_PATH" ]; then
                echo "No path provided, refreshing selection..."
                continue
            fi
            if [ -f "$LOCAL_7Z_PATH" ]; then
                LOCAL_7Z_NAME=$(basename "$LOCAL_7Z_PATH")
                if [[ "$LOCAL_7Z_NAME" =~ \.7z$ ]]; then
                    # Infer distribution from filename
                    SUBFOLDER_LOWER="local"
                    if [[ "$LOCAL_7Z_NAME" =~ [uU]buntu-[bB]ionic ]]; then
                        SUBFOLDER_LOWER="ubuntu-bionic"
                    elif [[ "$LOCAL_7Z_NAME" =~ [uU]buntu-[jJ]ammy ]]; then
                        SUBFOLDER_LOWER="ubuntu-jammy"
                    elif [[ "$LOCAL_7Z_NAME" =~ [uU]buntu-[nN]oble ]]; then
                        SUBFOLDER_LOWER="ubuntu-noble"
                    elif [[ "$LOCAL_7Z_NAME" =~ [fF]edora-39 ]]; then
                        SUBFOLDER_LOWER="fedora-39"
                    elif [[ "$LOCAL_7Z_NAME" =~ [fF]edora-41 ]]; then
                        SUBFOLDER_LOWER="fedora-41"
                    fi
                    DISTRO="$SUBFOLDER_LOWER"
                    ZIP_URL="$LOCAL_7Z_PATH"
                    ID="SWR-${SUBFOLDER_LOWER%%-*}"
                    PREFIX="/switchroot/$SUBFOLDER_LOWER/"
                    INI="L4T_${SUBFOLDER_LOWER%%-*}.ini"
                    IS_LOCAL="true"
                    echo "Added local archive: $LOCAL_7Z_NAME (SUBFOLDER: $SUBFOLDER_LOWER)" >> "$LOG_FILE"
                else
                    echo "  Error: '$LOCAL_7Z_PATH' is not a .7z file!"
                    echo "Invalid local file: $LOCAL_7Z_PATH" >> "$LOG_FILE"
                    continue
                fi
            else
                echo "  Error: File '$LOCAL_7Z_PATH' does not exist!"
                echo "Local file not found: $LOCAL_7Z_PATH" >> "$LOG_FILE"
                continue
            fi
        else
            DISTRO=$(eval echo \$DISTRO_$DISTRO_CHOICE)
            ZIP_URL=$(eval echo \$ZIP_URL_$DISTRO_CHOICE)
            ID=$(eval echo \$ID_$DISTRO_CHOICE)
            PREFIX=$(eval echo \$PREFIX_$DISTRO_CHOICE)
            INI=$(eval echo \$INI_$DISTRO_CHOICE)
            # Check if ZIP_URL is a local file path (cached file) or remote URL
            if [[ "$ZIP_URL" =~ ^https?:// ]]; then
                IS_LOCAL="false"
            else
                IS_LOCAL="true"
            fi
        fi
        break
    else
        echo "  Error: Invalid choice! Enter a number between 0 and $((${#OPTIONS[@]} - 1)) or 'retry'."
    fi
done

echo ""
if [ -n "$AUTO_SELECT_INDEX" ]; then
    # For auto-selected cached distro, show simpler message
    ZIP_FILE_DISPLAY=$(basename "$ZIP_URL")
    echo "Selected: $DISTRO - $ZIP_FILE_DISPLAY (cached)"
elif [ "$DISTRO_CHOICE" -eq 0 ]; then
    echo "Selected: $DISTRO (0) Use local OS image file (.7z))"
else
    echo "Selected: $DISTRO (${OPTIONS[$DISTRO_CHOICE]})"
fi
echo ""

# Step 2: Download and Extract
echo "$(tput bold)========== Step 2: Downloading $DISTRO Files ==========$(tput sgr0)"
MIN_SIZE=$((500 * 1024 * 1024)) # 500MB in bytes
MAX_RETRIES=3
RETRY_COUNT=0

ZIP_FILE=$(basename "$ZIP_URL")
RAW_FILE="${DISTRO}.raw"
DISTRO_LOWER=$(echo "$DISTRO" | tr '[:upper:]' '[:lower:]')

if [ "$IS_LOCAL" = "true" ]; then
    echo "  Using local file: $ZIP_URL"
    if [ -f "$ZIP_URL" ]; then
        FILE_SIZE=$(stat -c%s "$ZIP_URL")
        if [ "$FILE_SIZE" -ge "$MIN_SIZE" ]; then
            # Check if the file is already in TEMP_DIR (cached file)
            if [ "$(dirname "$ZIP_URL")" = "$TEMP_DIR" ]; then
                echo "  $ZIP_FILE already in temp directory ($((FILE_SIZE / 1024 / 1024)) MB), skipping copy..."
            else
                cp "$ZIP_URL" "$TEMP_DIR/$ZIP_FILE" || {
                    echo "  $(tput bold)Error: Failed to copy $ZIP_URL to $TEMP_DIR!$(tput sgr0)"
                    exit 1
                }
                echo "  Copied $ZIP_FILE to $TEMP_DIR ($((FILE_SIZE / 1024 / 1024)) MB)"
            fi
        else
            echo "  $(tput bold)Error: Local file too small ($((FILE_SIZE / 1024 / 1024)) MB), expected at least $((MIN_SIZE / 1024 / 1024)) MB.$(tput sgr0)"
            exit 1
        fi
    else
        echo "  $(tput bold)Error: Local file '$ZIP_URL' not found!$(tput sgr0)"
        exit 1
    fi
else
    if [ -f "$TEMP_DIR/$ZIP_FILE" ]; then
        FILE_SIZE=$(stat -c%s "$TEMP_DIR/$ZIP_FILE")
        if [ "$FILE_SIZE" -ge "$MIN_SIZE" ]; then
            echo "  $ZIP_FILE already downloaded ($((FILE_SIZE / 1024 / 1024)) MB), skipping..."
        else
            echo "  Existing $ZIP_FILE too small ($((FILE_SIZE / 1024)) KB), re-downloading..."
            rm -f "$TEMP_DIR/$ZIP_FILE"
        fi
    fi

    # Check if aria2c is available for faster multi-connection download
    USE_ARIA2=false
    if command -v aria2c &> /dev/null; then
        USE_ARIA2=true
        echo "  Using aria2c for faster multi-connection download..."
    fi

    while [ ! -f "$TEMP_DIR/$ZIP_FILE" ] || [ "$(stat -c%s "$TEMP_DIR/$ZIP_FILE")" -lt "$MIN_SIZE" ]; do
        if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
            echo "  $(tput bold)Error: Download failed after $MAX_RETRIES attempts!$(tput sgr0)"
            echo "  Download manually from $ZIP_URL and place in $TEMP_DIR."
            exit 1
        fi

        echo "  Downloading $ZIP_FILE (Attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)..."

        if [ "$USE_ARIA2" = true ]; then
            # Use aria2c with 8 connections for faster download (like IDM)
            aria2c -x 8 -s 8 -k 1M --allow-overwrite=true --auto-file-renaming=false \
                   -d "$TEMP_DIR" -o "$ZIP_FILE" "$ZIP_URL" || {
                echo "  Warning: Download failed, retrying..."
                rm -f "$TEMP_DIR/$ZIP_FILE"
            }
        else
            # Fallback to curl with progress bar
            curl -L --progress-bar -o "$TEMP_DIR/$ZIP_FILE" "$ZIP_URL" || {
                echo "  Warning: Download failed, retrying..."
                rm -f "$TEMP_DIR/$ZIP_FILE"
            }
        fi

        FILE_SIZE=$(stat -c%s "$TEMP_DIR/$ZIP_FILE" 2>/dev/null || echo 0)
        if [ "$FILE_SIZE" -lt "$MIN_SIZE" ]; then
            echo "  Error: File too small ($((FILE_SIZE / 1024 / 1024)) MB), expected $((MIN_SIZE / 1024 / 1024)) MB."
            rm -f "$TEMP_DIR/$ZIP_FILE"
        fi
        RETRY_COUNT=$((RETRY_COUNT + 1))
        sleep 2
    done

    echo "  Download complete: $ZIP_FILE ($((FILE_SIZE / 1024 / 1024)) MB)"
fi

echo "  Extracting $DISTRO files..."
7z x "$TEMP_DIR/$ZIP_FILE" -o"$TEMP_DIR" >> "$LOG_FILE" 2>&1 || {
    echo "  $(tput bold)Error: Extraction failed!$(tput sgr0)"
    echo ""
    echo "  Last 20 lines of 7z output:"
    tail -20 "$LOG_FILE" | sed 's/^/    /'
    echo ""
    echo "  Possible causes:"
    echo "    - Corrupted download (try deleting and re-downloading)"
    echo "    - Incompatible 7z version (try: apt install p7zip-full)"
    echo "    - Archive requires password (not supported)"
    echo ""
    echo "  Full log saved at: $LOG_FILE"
    exit 1
}
echo "  Extraction complete."
echo ""

# Scan extracted files and adjust structure
echo "Scanning extracted files..."
EXTRACTED_DIR="$TEMP_DIR"
echo "Debug: Contents of $EXTRACTED_DIR after extraction:" >> "$LOG_FILE"
ls -lR "$EXTRACTED_DIR" >> "$LOG_FILE" 2>&1

# Find and configure the .ini file in bootloader folder
BOOTLOADER_DIR="$TEMP_DIR/bootloader"
mkdir -p "$BOOTLOADER_DIR" || {
    echo "  Error: Failed to create $BOOTLOADER_DIR!"
    exit 1
}
chmod -R u+rw "$TEMP_DIR" || {
    echo "  Error: Failed to set permissions on $TEMP_DIR!"
    exit 1
}

INI_FOUND=$(find "$BOOTLOADER_DIR" -type f -name "*.ini" | head -n 1)
if [ -n "$INI_FOUND" ]; then
    INI_FILE="$INI_FOUND"  # Use the found file directly
    echo "  Found .ini file: $INI_FILE"
    echo "Found .ini file: $INI_FILE" >> "$LOG_FILE"
    chmod u+rw "$INI_FILE" || {
        echo "  Error: Failed to set permissions on $INI_FILE!"
        exit 1
    }
else
    echo "  $(tput bold)Error: No .ini file found in $BOOTLOADER_DIR!$(tput sgr0)"
    echo "No .ini file found in $BOOTLOADER_DIR" >> "$LOG_FILE"
    exit 1
fi

# Remove all blank lines and trailing newline, then append eMMC settings
echo "  Configuring $INI_FILE for eMMC..."
echo "Cleaning up $INI_FILE and appending eMMC settings..." >> "$LOG_FILE"
sed -i '/^[[:space:]]*$/d' "$INI_FILE"  # Remove blank or whitespace-only lines
# Remove trailing newline from the last line
if [ -s "$INI_FILE" ]; then
    truncate -s -1 "$INI_FILE"  # Strip the final newline
fi

# Append eMMC settings if missing
if ! grep -q "^emmc=1$" "$INI_FILE" || ! grep -q "^rootdev=mmcblk0p1$" "$INI_FILE" || ! grep -q "^rootfstype=ext4$" "$INI_FILE"; then
    printf "\nemmc=1\nrootdev=mmcblk0p1\nrootfstype=ext4" >> "$INI_FILE" || {
        echo "Error: Failed to append settings to $INI_FILE!" >> "$LOG_FILE"
        exit 1
    }
    echo "Appended eMMC settings (emmc=1, rootdev=mmcblk0p1, rootfstype=ext4)" >> "$LOG_FILE"
else
    echo "All required eMMC settings already present in $INI_FILE, skipping append." >> "$LOG_FILE"
fi

echo "Modified $INI_FILE for single-partition eMMC booting." >> "$LOG_FILE"
echo "Current $INI_FILE content:" >> "$LOG_FILE"
cat "$INI_FILE" >> "$LOG_FILE"

# Smart boot files detection - handles various archive structures
echo "  Searching for boot files..."
echo "Searching for boot files in extracted archive..." >> "$LOG_FILE"

SWITCHROOT_SUBDIR=""
SWITCHROOT_PATH=""

# Strategy 1: Look for exact distro match (e.g., switchroot/ubuntu-noble/, switchroot/fedora-42/)
if [ -d "$EXTRACTED_DIR/switchroot" ]; then
    SWITCHROOT_SUBDIR=$(find "$EXTRACTED_DIR/switchroot" -maxdepth 1 -type d -iname "$DISTRO_LOWER" -print -quit 2>/dev/null)
    echo "Strategy 1 (exact match '$DISTRO_LOWER'): ${SWITCHROOT_SUBDIR:-not found}" >> "$LOG_FILE"
fi

# Strategy 2: Look for distro base name match (e.g., fedora-42 -> fedora, ubuntu-noble -> ubuntu)
if [ -z "$SWITCHROOT_SUBDIR" ] && [ -d "$EXTRACTED_DIR/switchroot" ]; then
    DISTRO_BASE=$(echo "$DISTRO_LOWER" | sed 's/-[0-9]*$//' | sed 's/-.*$//')
    SWITCHROOT_SUBDIR=$(find "$EXTRACTED_DIR/switchroot" -maxdepth 1 -type d -iname "$DISTRO_BASE" -print -quit 2>/dev/null)
    echo "Strategy 2 (base name '$DISTRO_BASE'): ${SWITCHROOT_SUBDIR:-not found}" >> "$LOG_FILE"
fi

# Strategy 3: Look for any non-install directory with boot files inside switchroot/
if [ -z "$SWITCHROOT_SUBDIR" ] && [ -d "$EXTRACTED_DIR/switchroot" ]; then
    for subdir in "$EXTRACTED_DIR/switchroot"/*/; do
        if [ -d "$subdir" ]; then
            subdir_name=$(basename "$subdir")
            # Skip the install directory
            if [ "$subdir_name" = "install" ]; then
                continue
            fi
            # Check if this directory contains boot files
            if ls "$subdir"/*.{bin,scr,dtimg} "$subdir"/initramfs "$subdir"/uImage 2>/dev/null | head -1 > /dev/null; then
                SWITCHROOT_SUBDIR="$subdir"
                echo "Strategy 3 (found boot files in '$subdir_name'): $SWITCHROOT_SUBDIR" >> "$LOG_FILE"
                break
            fi
        fi
    done
fi

# Strategy 4: Look for boot files in the root extracted directory
if [ -z "$SWITCHROOT_SUBDIR" ]; then
    BOOT_FILES=$(ls "$EXTRACTED_DIR"/*.{bin,bmp,scr,dtimg} "$EXTRACTED_DIR"/initramfs "$EXTRACTED_DIR"/uImage 2>/dev/null || true)
    if [ -n "$BOOT_FILES" ]; then
        echo "Strategy 4 (root level boot files): found" >> "$LOG_FILE"
        echo "  Found boot files in root directory, reorganizing..."
        mkdir -p "$TEMP_DIR/switchroot/$DISTRO_LOWER"
        mv "$EXTRACTED_DIR"/*.{bin,bmp,scr,dtimg} "$EXTRACTED_DIR"/initramfs "$EXTRACTED_DIR"/uImage "$TEMP_DIR/switchroot/$DISTRO_LOWER/" 2>/dev/null || true
        SWITCHROOT_SUBDIR="$TEMP_DIR/switchroot/$DISTRO_LOWER"
    fi
fi

# Process the found directory
if [ -n "$SWITCHROOT_SUBDIR" ]; then
    SUBDIR_NAME=$(basename "$SWITCHROOT_SUBDIR")
    SWITCHROOT_PATH="/switchroot/$SUBDIR_NAME/"
    echo "  Found switchroot directory: $SWITCHROOT_SUBDIR"
    echo "Using switchroot path: $SWITCHROOT_PATH" >> "$LOG_FILE"

    # Move to standard location if needed
    if [ "$SWITCHROOT_SUBDIR" != "$TEMP_DIR/switchroot/$SUBDIR_NAME" ]; then
        mkdir -p "$TEMP_DIR/switchroot"
        mv "$SWITCHROOT_SUBDIR" "$TEMP_DIR/switchroot/$SUBDIR_NAME" 2>/dev/null || true
        SWITCHROOT_SUBDIR="$TEMP_DIR/switchroot/$SUBDIR_NAME"
    fi

    # Update boot_prefixes in INI file only if needed
    # Match original behavior: only update if boot_prefixes exists AND doesn't match expected path
    if grep -q "boot_prefixes=" "$INI_FILE"; then
        if ! grep -q "boot_prefixes=$SWITCHROOT_PATH" "$INI_FILE"; then
            sed -i "s|boot_prefixes=.*|boot_prefixes=$SWITCHROOT_PATH|" "$INI_FILE"
            echo "Updated boot_prefixes to $SWITCHROOT_PATH in $INI_FILE." >> "$LOG_FILE"
        else
            echo "boot_prefixes already set to $SWITCHROOT_PATH, no change needed." >> "$LOG_FILE"
        fi
    else
        echo "boot_prefixes=$SWITCHROOT_PATH" >> "$INI_FILE"
        echo "Added boot_prefixes=$SWITCHROOT_PATH to $INI_FILE." >> "$LOG_FILE"
    fi
else
    echo "  $(tput bold)Error: No switchroot directory or boot files found!$(tput sgr0)"
    echo ""
    echo "  The extracted archive doesn't contain the expected boot file structure."
    echo "  Expected: switchroot/<distro>/ directory with boot files, or boot files in root."
    echo ""
    echo "  Please check the log file for details: $LOG_FILE"
    echo "Extracted structure:" >> "$LOG_FILE"
    ls -lR "$EXTRACTED_DIR" >> "$LOG_FILE"
    exit 1
fi

# Prepare the filesystem image for flashing
if ls "$TEMP_DIR"/switchroot/install/l4t.0* >/dev/null 2>&1; then
    echo "  Preparing $DISTRO RAW image..."
    cat "$TEMP_DIR"/switchroot/install/l4t.0* > "$TEMP_DIR/$RAW_FILE" || {
        echo "  $(tput bold)Error: Failed to merge split l4t files!$(tput sgr0)"
        exit 1
    }
    echo "  RAW image ready: $TEMP_DIR/$RAW_FILE"
else
    echo "  $(tput bold)Error: No l4t.0* files found in $TEMP_DIR/switchroot/install!$(tput sgr0)"
    echo "Extracted contents:" >> "$LOG_FILE"
    ls -lR "$TEMP_DIR" >> "$LOG_FILE"
    exit 1
fi

if [ ! -f "$TEMP_DIR/$RAW_FILE" ]; then
    echo "  $(tput bold)Error: $RAW_FILE not found!$(tput sgr0)"
    exit 1
fi
echo ""

# Step 3: Prepare SD Card
echo "$(tput bold)========== Step 3: Prepare SD Card ==========$(tput sgr0)"
echo "  Mount your SD card via Hekate:"
echo "  In Hekate: Tools > USB Tools > Disable Read-Only > SD Card, then connect USB."
echo "----------"
read -p "$(tput bold)Press Enter when SD card is connected:$(tput sgr0) " -r

echo "  Detecting SD card..."
TIMEOUT=60
COUNT=0
SD_DEV=""
SD_MOUNT="/mnt/sdcard"
echo -n "  Scanning"
while [ -z "$SD_DEV" ] && [ $COUNT -lt $TIMEOUT ]; do
    NEW_DISKS=$(lsblk -o NAME,SIZE,LABEL,TYPE,MOUNTPOINT | grep disk)
    if [ -n "$NEW_DISKS" ]; then
        echo -e "\n  Detected devices:"
        echo "$NEW_DISKS" | sed 's/^/    /'
        read -p "$(tput bold)Enter SD card device (e.g., sda, sdb) or 'retry': $(tput sgr0)" SD_DEV
        if [ "$SD_DEV" = "retry" ]; then
            SD_DEV=""
            echo -n "  Retrying"
        else
            SD_SIZE=$(lsblk -b -n -o SIZE /dev/$SD_DEV | head -n 1)
            SD_SIZE_GB=$(echo "scale=1; $SD_SIZE / 1024 / 1024 / 1024" | bc)
            SD_MOUNTPOINT=$(lsblk -n -o MOUNTPOINT /dev/${SD_DEV}1 2>/dev/null || lsblk -n -o MOUNTPOINT /dev/$SD_DEV 2>/dev/null)
            SD_FSTYPE=$(lsblk -n -o FSTYPE /dev/${SD_DEV}1 2>/dev/null || lsblk -n -o FSTYPE /dev/$SD_DEV 2>/dev/null)
            echo "  Selected: $SD_DEV ($SD_SIZE_GB GB, FSTYPE: $SD_FSTYPE${SD_MOUNTPOINT:+, mounted at $SD_MOUNTPOINT})"
            if [[ "$SD_DEV" =~ ^nvme ]] || [ $(echo "$SD_SIZE_GB > 200" | bc) -eq 1 ] && [ -z "$SD_MOUNTPOINT" ]; then
                echo "  Warning: $SD_DEV ($SD_SIZE_GB GB) may be an internal OS drive!"
                read -p "  Confirm this is your SD card? (y/N): " CONFIRM_SD
                if [ "$CONFIRM_SD" != "y" ] && [ "$CONFIRM_SD" != "Y" ]; then
                    SD_DEV=""
                    echo "  Retrying detection..."
                fi
            fi
            if [ -n "$SD_DEV" ] && [ -b "/dev/$SD_DEV" ]; then
                break
            else
                echo "  Error: Invalid device '$SD_DEV'! Retrying..."
                SD_DEV=""
            fi
        fi
    fi
    echo -n "."
    sleep 1
    COUNT=$((COUNT + 1))
done

if [ -z "$SD_DEV" ]; then
    echo -e "\n  $(tput bold)Error: Detection timed out!$(tput sgr0)"
    echo "  Current devices:"
    lsblk -o NAME,SIZE,LABEL,TYPE,MOUNTPOINT | sed 's/^/    /'
    read -p "$(tput bold)Enter SD card device (e.g., sda, sdb): $(tput sgr0)" SD_DEV
    if [ ! -b "/dev/$SD_DEV" ]; then
        echo "  $(tput bold)Error: Invalid device '$SD_DEV'!$(tput sgr0)"
        exit 1
    fi
    SD_FSTYPE=$(lsblk -n -o FSTYPE /dev/${SD_DEV}1 2>/dev/null || lsblk -n -o FSTYPE /dev/$SD_DEV 2>/dev/null)
    SD_MOUNTPOINT=$(lsblk -n -o MOUNTPOINT /dev/${SD_DEV}1 2>/dev/null || lsblk -n -o MOUNTPOINT /dev/$SD_DEV 2>/dev/null)
fi

echo "  Checking SD card filesystem..."
if [ "$SD_FSTYPE" != "vfat" ]; then
    echo "  $(tput bold)Error: SD card is '$SD_FSTYPE', not FAT32 (vfat)!$(tput sgr0)"
    echo "  Format the first partition as FAT32 and rerun the script."
    [ -n "$SD_MOUNTPOINT" ] && echo "  Note: Currently mounted at $SD_MOUNTPOINT. Unmount manually if reformatting."
    exit 1
else
    echo "  SD card is FAT32, proceeding..."
fi

if [ -n "$SD_MOUNTPOINT" ]; then
    if [ -w "$SD_MOUNTPOINT" ]; then
        SD_MOUNT="$SD_MOUNTPOINT"
        echo "  Using existing mount at $SD_MOUNT (writable)."
    else
        echo "  SD card mounted at $SD_MOUNTPOINT but not writable."
        read -p "$(tput bold)Unmount and remount? (y/N): $(tput sgr0)" REMOUNT_CONFIRM
        if [ "$REMOUNT_CONFIRM" = "y" ] || [ "$REMOUNT_CONFIRM" = "Y" ]; then
            umount "$SD_MOUNTPOINT" || {
                echo "  $(tput bold)Error: Failed to unmount $SD_MOUNTPOINT! Unmount manually and rerun.$(tput sgr0)"
                exit 1
            }
            mkdir -p "$SD_MOUNT"
            mount /dev/${SD_DEV}1 "$SD_MOUNT" || mount /dev/$SD_DEV "$SD_MOUNT" || {
                echo "  $(tput bold)Error: Failed to remount SD card!$(tput sgr0)"
                exit 1
            }
            echo "  SD card remounted at $SD_MOUNT."
        else
            echo "  $(tput bold)Error: SD card must be writable. Remount or adjust permissions manually.$(tput sgr0)"
            exit 1
        fi
    fi
else
    mkdir -p "$SD_MOUNT"
    mount /dev/${SD_DEV}1 "$SD_MOUNT" || mount /dev/$SD_DEV "$SD_MOUNT" || {
        echo "  $(tput bold)Error: Failed to mount SD card!$(tput sgr0)"
        exit 1
    }
    echo "  SD card mounted at $SD_MOUNT."
fi

echo -n "  Copying boot files and .ini to SD card"
(
    mkdir -p "$SD_MOUNT/bootloader/ini"
    cp "$INI_FILE" "$SD_MOUNT/bootloader/ini/$(basename "$INI_FILE")" || {
        echo "Error: Failed to copy $INI_FILE to SD card!" >> "$LOG_FILE"
        exit 1
    }

    # Use the actual subdirectory name that was found, not the expected one
    ACTUAL_SUBDIR_NAME=$(basename "$SWITCHROOT_SUBDIR")
    mkdir -p "$SD_MOUNT/switchroot/$ACTUAL_SUBDIR_NAME"

    if [ -d "$SWITCHROOT_SUBDIR" ]; then
        cp -r "$SWITCHROOT_SUBDIR"/* "$SD_MOUNT/switchroot/$ACTUAL_SUBDIR_NAME/" || {
            echo "Warning: Failed to copy some boot files to $SD_MOUNT/switchroot/$ACTUAL_SUBDIR_NAME." >> "$LOG_FILE"
        }
        echo "Copied boot files from $SWITCHROOT_SUBDIR to SD card" >> "$LOG_FILE"
    else
        echo "Error: SWITCHROOT_SUBDIR ($SWITCHROOT_SUBDIR) does not exist!" >> "$LOG_FILE"
        exit 1
    fi

    sync
) &
spinner $!
echo ""

if [ ! -f "$SD_MOUNT/bootloader/hekate_ipl.ini" ]; then
    echo "  Warning: hekate_ipl.ini not found in $SD_MOUNT/bootloader!"
    echo "  Ensure Hekate is installed (e.g., extract hekate_ctcaer_X.X.X_Nyx_X.X.X.zip to SD root)."
fi

umount "$SD_MOUNT" || true
echo "  SD card unmounted (if mounted by script)."
echo ""

# Step 4: Flash eMMC
echo "$(tput bold)========== Step 4: Flash eMMC with $DISTRO ==========$(tput sgr0)"
echo "  Mount your eMMC via Hekate:"
echo "  In Hekate: Tools > USB Tools > Disable Read-Only > eMMC RAW GPP, then connect USB."
echo "----------"
read -p "$(tput bold)Press Enter when eMMC is connected:$(tput sgr0) " -r

echo "  Detecting eMMC..."
COUNT=0
EMMC_DEV=""
TIMEOUT=60
echo -n "  Scanning"
while [ -z "$EMMC_DEV" ] && [ $COUNT -lt $TIMEOUT ]; do
    NEW_DISKS=$(lsblk -o NAME,SIZE,LABEL,TYPE,MOUNTPOINT | grep disk)
    if [ -n "$NEW_DISKS" ]; then
        echo -e "\n  Detected devices:"
        echo "$NEW_DISKS" | sed 's/^/    /'
        read -p "$(tput bold)Enter eMMC device (e.g., sdc) or 'retry': $(tput sgr0)" EMMC_DEV
        if [ "$EMMC_DEV" = "retry" ]; then
            EMMC_DEV=""
            echo -n "  Retrying"
        else
            EMMC_SIZE=$(lsblk -b -n -o SIZE /dev/$EMMC_DEV | head -n 1)
            EMMC_SIZE_GB=$(echo "scale=1; $EMMC_SIZE / 1024 / 1024 / 1024" | bc)
            echo "  Selected: $EMMC_DEV ($EMMC_SIZE_GB GB)"
            if [ $(echo "$EMMC_SIZE_GB < 25 || $EMMC_SIZE_GB > 65" | bc) -eq 1 ]; then
                echo "  Warning: Size ($EMMC_SIZE_GB GB) atypical for eMMC (29GB or 58GB)!"
                read -p "  Confirm this is your eMMC? (y/N): " CONFIRM_EMMC
                if [ "$CONFIRM_EMMC" != "y" ] && [ "$CONFIRM_EMMC" != "Y" ]; then
                    EMMC_DEV=""
                    echo "  Retrying detection..."
                fi
            fi
            if [ -n "$EMMC_DEV" ] && [ -b "/dev/$EMMC_DEV" ]; then
                break
            else
                echo "  Error: Invalid device '$EMMC_DEV'! Retrying..."
                EMMC_DEV=""
            fi
        fi
    fi
    echo -n "."
    sleep 1
    COUNT=$((COUNT + 1))
done

if [ -z "$EMMC_DEV" ]; then
    echo -e "\n  $(tput bold)Error: Detection timed out!$(tput sgr0)"
    echo "  Current devices:"
    lsblk -o NAME,SIZE,LABEL,TYPE,MOUNTPOINT | sed 's/^/    /'
    read -p "$(tput bold)Enter eMMC device (e.g., sdc): $(tput sgr0)" EMMC_DEV
    if [ ! -b "/dev/$EMMC_DEV" ]; then
        echo "  $(tput bold)Error: Invalid device '$EMMC_DEV'!$(tput sgr0)"
        exit 1
    fi
fi

echo ""
echo "  $(tput bold)Selected: $EMMC_DEV ($EMMC_SIZE_GB GB) - Confirm this is your eMMC? (y/N)$(tput sgr0)"
read -r CONFIRM
[ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ] && exit 1

echo "  $(tput bold)Last chance to abort! This will erase the eMMC entirely. Proceed? (y/N)$(tput sgr0)"
read -r FINAL_CONFIRM
[ "$FINAL_CONFIRM" != "y" ] && [ "$FINAL_CONFIRM" != "Y" ] && exit 1

echo "  Zapping partition table..."
sgdisk -Z /dev/$EMMC_DEV >> "$LOG_FILE" 2>&1 || {
    echo "Warning: Failed to zap partition table with sgdisk, proceeding with gdisk." >> "$LOG_FILE"
}
sync
sleep 1

echo "  Partitioning eMMC (single partition)..."
gdisk /dev/$EMMC_DEV <<EOF >>"$LOG_FILE" 2>&1
x
s
128
w
y
EOF
gdisk /dev/$EMMC_DEV <<EOF >>"$LOG_FILE" 2>&1
o
y
n
1

+29G
8300
w
y
EOF
echo "  Partition table created."
partprobe /dev/$EMMC_DEV >> "$LOG_FILE" 2>&1 || {
    echo "Warning: partprobe failed, proceeding anyway." >> "$LOG_FILE"
}
sleep 1

echo "  Checking for mounted partitions..."
MOUNTED_PARTS=$(lsblk -n -o NAME,MOUNTPOINT /dev/$EMMC_DEV* | grep -v "^$EMMC_DEV " | awk '{sub(/^└─/, "", $1); if ($2) print "/dev/"$1 " " $2}' | sort -u)
if [ -n "$MOUNTED_PARTS" ]; then
    echo "  Mounted partitions detected:"
    echo "$MOUNTED_PARTS" | sed 's/^/    /'
    while read -r PART MOUNTPOINT; do
        echo "    Unmounting $PART from $MOUNTPOINT..."
        umount -f "$PART" 2>/dev/null || umount -l "$PART" 2>/dev/null || {
            echo "  $(tput bold)Error: Failed to force unmount $PART! Please unmount manually and rerun.$(tput sgr0)"
            exit 1
        }
        if [ -n "$(lsblk -n -o MOUNTPOINT $PART)" ]; then
            echo "  $(tput bold)Error: $PART still mounted at $(lsblk -n -o MOUNTPOINT $PART)!$(tput sgr0)"
            exit 1
        fi
    done <<< "$MOUNTED_PARTS"
else
    echo "  No mounted partitions found."
fi

echo "  Formatting /dev/${EMMC_DEV}1 as ext4..."
mkfs.ext4 -F /dev/${EMMC_DEV}1 || {
    echo "  $(tput bold)Error: Failed to format /dev/${EMMC_DEV}1!$(tput sgr0)"
    exit 1
}
sync
sleep 1

echo "  Flashing $DISTRO to /dev/${EMMC_DEV}1..."
dd if="$TEMP_DIR/$RAW_FILE" of=/dev/${EMMC_DEV}1 bs=2M conv=fsync status=progress || {
    echo "  $(tput bold)Error: Failed to flash $RAW_FILE!$(tput sgr0)"
    exit 1
}
sync
echo "  eMMC flashing complete!"
echo ""

# Step 5: Cleanup
echo "$(tput bold)========== Step 5: Cleanup ==========$(tput sgr0)"
echo "  Temporary files are in $TEMP_DIR."
BOLD=$(tput bold)
RESET=$(tput sgr0)
read -p "${BOLD}Delete temporary files or keep for backup? (d/k): ${RESET}" CLEANUP
if [ "$CLEANUP" = "d" ] || [ "$CLEANUP" = "D" ]; then
    rm -rf "$TEMP_DIR"
    echo "  Temporary files deleted."
else
    echo "  Temporary files kept in $TEMP_DIR."
fi
echo ""

# Completion
echo "$(tput bold)================ Installation Complete! ================$(tput sgr0)"
echo "  To boot into $DISTRO:"
echo "    1. Unplug the USB cable."
echo "    2. In Hekate, select '$DISTRO' from 'More Configs' menu."