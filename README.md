# Switchroot Linux eMMC Flash Script

<div align="center">
  <img src="https://raw.githubusercontent.com/sthetix/Switchroot-Linux-eMMC-Flasher/main/title.png" alt="Switchroot Linux eMMC Flasher Title" width="70%">
</div>

This Bash script automates the process of flashing a Linux distribution to the eMMC of a Nintendo Switch using a Linux environment. It fetches available Switchroot Linux variants from `download.switchroot.org`, prepares an SD card with necessary boot files, and flashes the selected distribution to the Switch's eMMC.

## Features
- **Dynamic Distribution Fetching**: Downloads available Linux variants (Ubuntu, Fedora) from `download.switchroot.org`.
- **SD Card Preparation**: Copies boot files and configures Hekate `.ini` files for eMMC booting.
- **eMMC Flashing**: Erases and flashes the selected Linux image to the Switch's eMMC.
- **Dependency Management**: Automatically installs required tools (`curl`, `parted`, `gdisk`, etc.).
- **Error Handling**: Includes retries, logging, and detailed error messages.

## Requirements
- **Linux Environment**: A Linux system with root privileges (e.g., Ubuntu, Fedora).
- **Hekate**: Installed on your SD card for USB Mass Storage (UMS) access.
- **SD Card**: Formatted as FAT32.
- **Internet Connection**: To fetch distributions and dependencies.
- **USB Connection**: For connecting the Switch to your computer via Hekate UMS.

## Supported Distributions
- Ubuntu Bionic (18.04)
- Ubuntu Jammy (22.04)
- Ubuntu Noble (24.04) - Including KUbuntu and Ubuntu Unity variants
- Fedora 39
- Fedora 41

## Usage
1. **Clone the Repository**:
   ```bash
   git clone https://github.com/sthetix/Switchroot-Linux-eMMC-Flasher
   cd Switchroot-Linux-eMMC-Flasher

2. **Make the Script Executable**:
    ```bash
    chmod +x flash_linux.sh

3. **Run the Script**:
   ```bash
   ./flash_linux.sh


4. **Follow the on-screen prompts to**:
  - Select a Linux distribution.
  - Connect your SD card via Hekate UMS.
  - Connect your Switch eMMC via Hekate UMS.
  - Confirm the flashing process.

## ⚠️ WARNING: DATA LOSS ⚠️
**This script will COMPLETELY ERASE your Nintendo Switch's eMMC data!** All existing data, including games, saves, and the original Nintendo Switch OS, will be wiped. **Proceed at your own risk!**

- **Backup First**: Use Hekate to back up your eMMC (e.g., `Tools > Backup eMMC > eMMC BOOT0 & BOOT1` and `eMMC RAW GPP`) before running this script. Without a backup, your Switch could be **toast** or **wrecked** if something goes wrong.
- **Double-Check Devices**: Ensure you select the correct SD card and eMMC devices during the script prompts. Flashing the wrong device could damage your system or other drives.

## Installation Steps
1. **Select Distribution**: Choose from the fetched list of available Linux variants.
2. **Download & Extract**: The script downloads and extracts the selected `.7z` file.
3. **Prepare SD Card**: Boot files are copied to the SD card for Hekate.
4. **Flash eMMC**: The Linux image is written to the Switch's eMMC.
5. **Cleanup**: Option to delete or keep temporary files.

## Post-Installation
- Unplug the USB cable.
- Reboot your Switch into Hekate.
- Select the installed Linux distribution from the `More Configs` menu.

## Troubleshooting
- **Logs**: Check `/tmp/switchroot_temp/setup_log.txt` for detailed error messages.
- **Dependencies**: Ensure all required packages are installed (listed in the script).
- **Internet Issues**: Verify connectivity with `ping download.switchroot.org`.

## Contributing
Feel free to submit issues or pull requests to improve the script. Suggestions for additional error handling, distribution support, or usability enhancements are welcome!

## License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments
- **Switchroot Team**: For providing the Linux distributions and tools.
- **Hekate Developers**: For the essential bootloader and UMS functionality.



