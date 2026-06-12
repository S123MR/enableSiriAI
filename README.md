# enableSiriAI

A small macOS utility to enable Apple Intelligence / enhanced Siri features.

> WARNING: This tool performs low-level system changes, including writing to the sealed System volume, installing a custom kernel extension, and may require disabling SIP/Authenticated Root. Use at your own risk.

## Requirements

- Administrative access (`sudo`) to run the script
- System Integrity Protection (SIP) and Authenticated Root needs to be disabled for the script to work

## Before you begin

1. It's recommended to back up your Mac and important data.
2. If SIP or Authenticated Root is enabled, disabe them before use.
3. Know how to boot into recovery

## Usage

Open Terminal, change to the repository folder, and run:

```zsh
cd /path/to/enableSIriAI
./enableSiriAI.sh
```

## What the script does

1. Check system security status and warn if SIP or Authenticated Root appears enabled
2. Clean previous spoofing and eligibility cache artifacts
3. Install `CodexRegionSpoof.kext` into `/Library/Extensions`
4. Create and bootstrap a launch daemon to load the kext on boot
5. Mount the sealed system volume, modify `GenerativeModels.plist`, and create a new snapshot

## Command line options

- `--uninstall`
  - Removes the installed kext and loader service
  - Attempts to restore saved preference and eligibility cache backups
  - Restores the original `GenerativeModels.plist` snapshot if a backup is present

- `--verify-only`
  - Checks current system status without making changes
  - Prints macOS version, SIP/Authenticated Root status, hardware region info, loaded kext status, and the live `GenerativeModels.plist` state

- `--skip-location-spoof`
  - Install the hardware region spoofer but skip the boot-time location/IP spoofing logic(when you are not in restrcited regions of Siri AI(including network))

## Recommended workflow

1. Confirm your Mac is backed up.
2. Open Terminal.
3. Navigate to the repository:

```zsh
cd /Users/yourname/Downloads/enableSIriAI
```
(or the place where your saved repo is)

4. Run the installer:

```zsh
./enableSiriAI.sh
```

4. If you want to keep hardware spoofing only, run:

```zsh
./enableSiriAI.sh --skip-location-spoof
```

6. Reboot after the script completes.

## Uninstall

To undo the changes and restore backups when available, run:

```zsh
./enableSiriAI.sh --uninstall
```

The uninstall process will:

- unload and remove `/Library/Extensions/CodexRegionSpoof.kext`
- remove the loader script and launch daemon
- restore backed-up preference and eligibility cache files
- restore the original `GenerativeModels.plist` from backup if present
- create a new boot snapshot for the restored System volume

## Troubleshooting

- If the script fails due to SIP/Authenticated Root, boot into recovery and disable those protections.
- If you need to verify without changing anything, use `./enableSiriAI.sh --verify-only`.
- Reboot after installation or uninstall to ensure the system boots from the updated snapshot.

## Notes

- The script uses `/Library/Scripts/Codex/load-region-spoof.sh` and `/Library/LaunchDaemons/local.codex.region-spoof-loader.plist`
- Boot-time location spoofing uses `ipinfo.io` unless `--skip-location-spoof` is provided(use this flag when your location is not in restricted regions of Siri AI)
- The `CodexRegionSpoof` system kext and some of this script's logic are based on work from https://github.com/WhiteSoulss/enableAppleIntelligence
- A reboot is strongly recommended after installation or uninstall

## Disclaimer

This repository is provided for educational or experimental use only. Modifying system and boot snapshots can make your system unstable or unbootable. Always keep backups, understand the changes being made, and proceed at your own risk.
