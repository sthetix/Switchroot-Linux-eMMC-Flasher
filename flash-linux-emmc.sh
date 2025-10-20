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
echo "Fetches Linux variants from download.switchroot.org - Version 1.0.2"
echo "Setting up, please wait..."

# Dependency check
TEMP_DIR="/tmp/switchroot_temp"
LOG_FILE="$TEMP_DIR/setup_log.txt"
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR" || {
    echo "Error: Failed to create $TEMP_DIR!"
    exit 1
}
chmod -R u+rw "$TEMP_DIR" || {
    echo "Error: Failed to set permissions on $TEMP_DIR!"
    exit 1
}

echo "Checking dependencies..."
COMMANDS=("curl" "gdisk" "bc" "lsblk" "7z" "tar" "mkfs.ext4" "partprobe" "sgdisk")
PACKAGES=("curl" "gdisk" "bc" "lsblk" "p7zip-full" "tar" "e2fsprogs" "parted" "gdisk")

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

echo "Fetching available distributions..."

# Fetch Switchroot Linux distros only
echo "Setup started at $(date)" > "$LOG_FILE"
SUBFOLDERS=("ubuntu-bionic" "Ubuntu-jammy" "Ubuntu-noble" "fedora-39" "fedora-41")
declare -A DISTRO_MAP
DISTRO_MAP["ubuntu-bionic"]="Ubuntu Bionic (18.04)"
DISTRO_MAP["ubuntu-jammy"]="Ubuntu Jammy (22.04)"
DISTRO_MAP["ubuntu-noble"]="Ubuntu Noble (24.04)"
DISTRO_MAP["fedora-39"]="Fedora 39"
DISTRO_MAP["fedora-41"]="Fedora 41"

OPTIONS=()
INDEX=1
MAX_RETRIES=3
BASE_URL="https://download.switchroot.org"

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
echo "Available distributions for eMMC installation:"
OPTIONS=("0) Use local OS image file (.7z)" "${OPTIONS[@]}")
for OPT in "${OPTIONS[@]}"; do
    echo "  $OPT"
done
echo "----------"
while true; do
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
            IS_LOCAL="false"
        fi
        break
    else
        echo "  Error: Invalid choice! Enter a number between 0 and $((${#OPTIONS[@]} - 1)) or 'retry'."
    fi
done

echo ""
if [ "$DISTRO_CHOICE" -eq 0 ]; then
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
            cp "$ZIP_URL" "$TEMP_DIR/$ZIP_FILE" || {
                echo "  $(tput bold)Error: Failed to copy $ZIP_URL to $TEMP_DIR!$(tput sgr0)"
                exit 1
            }
            echo "  Copied $ZIP_FILE to $TEMP_DIR ($((FILE_SIZE / 1024 / 1024)) MB)"
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

    while [ ! -f "$TEMP_DIR/$ZIP_FILE" ] || [ "$(stat -c%s "$TEMP_DIR/$ZIP_FILE")" -lt "$MIN_SIZE" ]; do
        if [ "$RETRY_COUNT" -ge "$MAX_RETRIES" ]; then
            echo "  $(tput bold)Error: Download failed after $MAX_RETRIES attempts!$(tput sgr0)"
            echo "  Download manually from $ZIP_URL and place in $TEMP_DIR."
            exit 1
        fi
        echo "  Downloading $ZIP_FILE (Attempt $((RETRY_COUNT + 1))/$MAX_RETRIES)..."
        curl -L --progress-bar -o "$TEMP_DIR/$ZIP_FILE" "$ZIP_URL" || {
            echo "  Warning: Download failed, retrying..."
            rm -f "$TEMP_DIR/$ZIP_FILE"
        }
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
    echo "  $(tput bold)Error: Extraction failed! File may be corrupted.$(tput sgr0)"
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

# Find boot files (case-insensitive)
SWITCHROOT_SUBDIR=$(find "$EXTRACTED_DIR/switchroot" -maxdepth 1 -type d -iname "$DISTRO_LOWER" -print -quit)
if [ -n "$SWITCHROOT_SUBDIR" ]; then
    SUBDIR_NAME=$(basename "$SWITCHROOT_SUBDIR")
    SWITCHROOT_PATH="/switchroot/$SUBDIR_NAME/"
    echo "  Found switchroot directory: $SWITCHROOT_SUBDIR"
    if [ "$SWITCHROOT_SUBDIR" != "$TEMP_DIR/switchroot/$SUBDIR_NAME" ]; then
        mv "$SWITCHROOT_SUBDIR" "$TEMP_DIR/switchroot/$SUBDIR_NAME" 2>/dev/null || true
    fi
    if grep -q "boot_prefixes=" "$INI_FILE" && ! grep -q "boot_prefixes=$SWITCHROOT_PATH" "$INI_FILE"; then
        sed -i "s|boot_prefixes=.*|boot_prefixes=$SWITCHROOT_PATH|" "$INI_FILE"
        echo "Updated boot_prefixes to $SWITCHROOT_PATH in $INI_FILE." >> "$LOG_FILE"
    fi
else
    BOOT_FILES=$(ls "$EXTRACTED_DIR"/*.{bin,bmp,scr,dtimg} "$EXTRACTED_DIR"/initramfs "$EXTRACTED_DIR"/uImage 2>/dev/null || true)
    if [ -n "$BOOT_FILES" ]; then
        echo "  Moving boot files to switchroot/$DISTRO_LOWER/"
        mkdir -p "$TEMP_DIR/switchroot/$DISTRO_LOWER"
        mv "$EXTRACTED_DIR"/*.{bin,bmp,scr,dtimg} "$EXTRACTED_DIR"/initramfs "$EXTRACTED_DIR"/uImage "$TEMP_DIR/switchroot/$DISTRO_LOWER/" 2>/dev/null || true
        SWITCHROOT_PATH="/switchroot/$DISTRO_LOWER/"
        if grep -q "boot_prefixes=" "$INI_FILE"; then
            sed -i "s|boot_prefixes=.*|boot_prefixes=$SWITCHROOT_PATH|" "$INI_FILE"
        else
            echo "boot_prefixes=$SWITCHROOT_PATH" >> "$INI_FILE"
        fi
        echo "Set boot_prefixes to $SWITCHROOT_PATH in $INI_FILE." >> "$LOG_FILE"
    else
        echo "  $(tput bold)Error: No switchroot directory or boot files found!$(tput sgr0)"
        echo "Extracted structure:" >> "$LOG_FILE"
        ls -lR "$EXTRACTED_DIR" >> "$LOG_FILE"
        exit 1
    fi
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
    mkdir -p "$SD_MOUNT/switchroot/$DISTRO_LOWER"
    cp -r "$TEMP_DIR/switchroot/$DISTRO_LOWER"/* "$SD_MOUNT/switchroot/$DISTRO_LOWER/" || {
        echo "Warning: Failed to copy some boot files to $SD_MOUNT/switchroot/$DISTRO_LOWER." >> "$LOG_FILE"
    }
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