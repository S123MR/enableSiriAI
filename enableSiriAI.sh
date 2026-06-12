#!/bin/zsh
set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

# Variables & Flags
DO_UNINSTALL=0
DO_VERIFY_ONLY=0
SKIP_LOCATION_SPOOF=0
USE_SAFE_OVERRIDE=0

KEXT="/Library/Extensions/CodexRegionSpoof.kext"
LOCAL_KEXT="$ROOT_DIR/tools/CodexRegionSpoof.kext"
LOCAL_KEXT_BIN="$LOCAL_KEXT/Contents/MacOS/CodexRegionSpoof"
LOCAL_KEXT_BIN_B64="$LOCAL_KEXT/Contents/MacOS/CodexRegionSpoof.b64"
LOADER_SCRIPT="/Library/Scripts/Codex/load-region-spoof.sh"
LOADER_PLIST="/Library/LaunchDaemons/local.codex.region-spoof-loader.plist"

# APFS Snapshot Variables
MOUNT_POINT="/tmp/mount"
PLIST_PATH="$MOUNT_POINT/System/Library/FeatureFlags/Domain/GenerativeModels.plist"

# Safe Override Variables
OVERRIDE_DIR="/Library/Preferences/FeatureFlags/Domain"
OVERRIDE_PLIST="$OVERRIDE_DIR/GenerativeModels.plist"

# Backup Architecture
BACKUP_BASE="$ROOT_DIR/backup"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
CURRENT_BACKUP_DIR="$BACKUP_BASE/run-$TIMESTAMP"

ORIG_ARGS=("$@")

# --- Global Cleanup Trap ---
cleanup() {
  if mount | grep -q " on $MOUNT_POINT "; then
    echo "Cleaning up: Unmounting $MOUNT_POINT..."
    diskutil unmount force "$MOUNT_POINT" 2>/dev/null || umount "$MOUNT_POINT" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall) DO_UNINSTALL=1 ;;
    --verify-only) DO_VERIFY_ONLY=1 ;;
    --skip-location-spoof) SKIP_LOCATION_SPOOF=1 ;;
    --safe-override) USE_SAFE_OVERRIDE=1 ;;
    -h|--help)
      echo "Usage: ./$(basename "$0") [options]"
      echo "Options:"
      echo "  --skip-location-spoof  Skip boot-time Location spoofing."
      echo "  --safe-override        Use local /Library override instead of APFS snapshot."
      echo "  --verify-only          Check current system state."
      echo "  --uninstall            Remove all spoofing and revert system configurations."
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

section() {
  echo
  echo "== $1 =="
}

# --- 1. Sudo Escalation (Must be first, array expansion safely handled) ---
if [[ $EUID -ne 0 && "$DO_VERIFY_ONLY" -eq 0 ]]; then
  echo "Administrative privileges required. Prompting for sudo..."
  if [[ ${#ORIG_ARGS[@]} -gt 0 ]]; then
    exec sudo "$0" "${ORIG_ARGS[@]}"
  else
    exec sudo "$0"
  fi
fi

# --- 2. Safe User Home Assignment (handles spaces) ---
if [[ -n "${SUDO_USER:-}" ]]; then
  REAL_HOME=$(dscl . -read /Users/"$SUDO_USER" NFSHomeDirectory 2>/dev/null | sed 's/^[[:space:]]*NFSHomeDirectory:[[:space:]]*//' || true)
  [[ -z "$REAL_HOME" ]] && REAL_HOME="$HOME"
else
  REAL_HOME="$HOME"
fi

# --- 3. macOS Version Check ---
macos_major_version() {
  local version
  version="$(sw_vers -productVersion 2>/dev/null || echo 0)"
  echo "${version%%.*}"
}

if [[ "$DO_VERIFY_ONLY" -eq 0 && "$DO_UNINSTALL" -eq 0 ]]; then
  if [[ "$(macos_major_version)" -lt 27 ]]; then
    section "macOS Version Alert"
    echo "WARNING: This script is explicitly designed for macOS 27 and newer."
    echo "Running this on an older macOS version might cause unexpected behavior."
    if read -q "REPLY?Do you want to proceed anyway? (y/n) "; then
      echo ""
    else
      echo -e "\nAborting."
      exit 1
    fi
  fi
fi

# --- 4. Security Protections Check ---
check_security_status() {
  local warn=0
  if csrutil status | grep -qi 'enabled'; then warn=1; fi
  if csrutil authenticated-root status | grep -qi 'enabled'; then warn=1; fi
  
  if [[ $warn -eq 1 ]]; then
    section "Security Protections Alert"
    echo "WARNING: System Integrity Protection (SIP) or Authenticated Root appears to be enabled."
    if [[ "$USE_SAFE_OVERRIDE" -eq 0 ]]; then
      echo "Modifying the sealed System volume requires these to be disabled."
    fi
    if read -q "REPLY?Do you want to proceed anyway? (y/n) "; then
      echo ""
    else
      echo -e "\nAborting."
      exit 1
    fi
  fi
}

verify_only() {
  section "Preflight"
  echo "macOS: $(sw_vers -productVersion)"
  csrutil status
  csrutil authenticated-root status

  section "Hardware Region State"
  ioreg -rd1 -c IOPlatformExpertDevice | grep -Ei '"region-info"|"country-of-origin"|"model"|"model-number"' || true

  section "CodexRegionSpoof Kext"
  kmutil showloaded 2>/dev/null | grep -Ei 'Codex|RegionSpoof' || echo "Not loaded."

  section "GenerativeModels FeatureFlags (Live System)"
  if [[ -f "/System/Library/FeatureFlags/Domain/GenerativeModels.plist" ]]; then
    echo "--- System Volume Plist ---"
    plutil -p "/System/Library/FeatureFlags/Domain/GenerativeModels.plist" | grep -A 2 "EnhancedSiriWaitlist" || echo "EnhancedSiriWaitlist key not found."
  fi
  if [[ -f "$OVERRIDE_PLIST" ]]; then
    echo "--- Safe Override Plist ---"
    plutil -p "$OVERRIDE_PLIST" | grep -A 2 "EnhancedSiriWaitlist" || echo "EnhancedSiriWaitlist key not found."
  fi
  
  exit 0
}

clean_previous_configurations() {
  section "Cleaning previous configurations & caches"
  mkdir -p "$CURRENT_BACKUP_DIR"

  # Unload daemons safely
  launchctl bootout system "$LOADER_PLIST" 2>/dev/null || true
  rm -f "$LOADER_PLIST" "$LOADER_SCRIPT"
  
  # Strict backups
  local siri_pref="$REAL_HOME/Library/Preferences/com.apple.assistant.backedup.plist"
  if [[ -f "$siri_pref" ]]; then cp "$siri_pref" "$CURRENT_BACKUP_DIR/siri_pref.backup"; fi
  if [[ -f "/private/var/db/eligibilityd/eligibility.plist" ]]; then cp "/private/var/db/eligibilityd/eligibility.plist" "$CURRENT_BACKUP_DIR/eligibility.backup"; fi
  if [[ -f "/private/var/db/os_eligibility/eligibility.plist" ]]; then cp "/private/var/db/os_eligibility/eligibility.plist" "$CURRENT_BACKUP_DIR/os_eligibility.backup"; fi
  if [[ -f "/private/var/db/com.apple.countryd/countryCodeCache.plist" ]]; then cp "/private/var/db/com.apple.countryd/countryCodeCache.plist" "$CURRENT_BACKUP_DIR/countryCodeCache.backup"; fi

  # Remove UI locks & Flush Preference Caches
  sudo -u "${SUDO_USER:-$USER}" defaults delete com.apple.assistant.backedup SiriAvailability 2>/dev/null || true
  rm -f "$REAL_HOME/Library/Containers/com.apple.systempreferences.AppleIDSettings/Data/Library/Preferences/com.apple.assistant.backedup.plist"
  killall cfprefsd 2>/dev/null || true
  
  # Clear cache files
  chflags nouchg,noschg /private/var/db/eligibilityd/eligibility.plist 2>/dev/null || true
  rm -f /private/var/db/eligibilityd/eligibility.plist
  chflags nouchg,noschg /private/var/db/os_eligibility/eligibility.plist 2>/dev/null || true
  rm -f /private/var/db/os_eligibility/eligibility.plist

  # Unlock countryd cache
  chflags nouchg,noschg /private/var/db/com.apple.countryd/countryCodeCache.plist 2>/dev/null || true
  chmod 0644 /private/var/db/com.apple.countryd/countryCodeCache.plist 2>/dev/null || true
}

ensure_region_spoof_kext_installed() {
  section "Installing Hardware Region Spoofer"
  if [[ -d "$KEXT" ]]; then
    echo "Unloading existing kext before replacement..."
    kmutil unload -p "$KEXT" 2>/dev/null || true
    rm -rf "$KEXT"
  fi

  if [[ ! -d "$LOCAL_KEXT" ]]; then
    echo "Error: Missing local bundle $LOCAL_KEXT" >&2
    exit 1
  fi

  if [[ ! -x "$LOCAL_KEXT_BIN" && -f "$LOCAL_KEXT_BIN_B64" ]]; then
    /usr/bin/base64 -D -i "$LOCAL_KEXT_BIN_B64" -o "$LOCAL_KEXT_BIN" || { echo "Fatal Error: Kext payload decoding failed."; exit 1; }
    chmod 755 "$LOCAL_KEXT_BIN"
  fi

  cp -R "$LOCAL_KEXT" "$KEXT"
  chown -R root:wheel "$KEXT"
  chmod -R go-w "$KEXT"
}

install_boot_loader() {
  mkdir -p /Library/Scripts/Codex

  local tmp_script
  tmp_script="$(mktemp)"
  cat > "$tmp_script" <<EOF
#!/bin/zsh
set -e

LOG="/var/log/codex-region-spoof-loader.log"
KEXT="/Library/Extensions/CodexRegionSpoof.kext"

{
  echo "==== \$(date) ===="
  /usr/bin/kmutil load -p "\$KEXT" || echo "Kext load failed, may already be loaded."
  /bin/sleep 1
  /usr/bin/killall eligibilityd generativeexperiencesd modelcatalogd 2>/dev/null || true
EOF

  if [[ "$SKIP_LOCATION_SPOOF" -eq 0 ]]; then
    cat >> "$tmp_script" <<'EOF'
  GEO_PLIST="/var/db/locationd/Library/Caches/GeoServices/DirectReadConfigStore.plist"
  /bin/mkdir -p /var/db/locationd/Library/Caches/GeoServices
  
  cat > "$GEO_PLIST" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>DeviceCountryCodeSourced</key>
    <dict>
        <key>cc</key>
        <string>US</string>
        <key>source</key>
        <integer>262</integer>
        <key>metadata</key>
        <dict>
            <key>sourceNote</key>
            <string>boot-time-spoof</string>
        </dict>
    </dict>
</dict>
</plist>
XML
  
  /usr/sbin/chown _locationd:_locationd "$GEO_PLIST"
  /bin/chmod 0644 "$GEO_PLIST"
  /usr/bin/killall locationd geod routined 2>/dev/null || true
EOF
  fi

  cat >> "$tmp_script" <<'EOF'
} >> "$LOG" 2>&1
exit 0
EOF

  install -o root -g wheel -m 755 "$tmp_script" "$LOADER_SCRIPT"
  rm -f "$tmp_script"

  local tmp_plist
  tmp_plist="$(mktemp)"
  cat > "$tmp_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>local.codex.region-spoof-loader</string>
  <key>ProgramArguments</key>
  <array><string>${LOADER_SCRIPT}</string></array>
  <key>RunAtLoad</key><true/>
  <key>LaunchOnlyOnce</key><true/>
  <key>StandardOutPath</key><string>/var/log/codex-region-spoof-loader.stdout.log</string>
  <key>StandardErrorPath</key><string>/var/log/codex-region-spoof-loader.stderr.log</string>
</dict>
</plist>
EOF
  install -o root -g wheel -m 644 "$tmp_plist" "$LOADER_PLIST"
  rm -f "$tmp_plist"

  echo "Bootstrapping LaunchDaemon..."
  launchctl bootout system "$LOADER_PLIST" 2>/dev/null || true
  launchctl bootstrap system "$LOADER_PLIST" || { echo "Fatal Error: Failed to bootstrap LaunchDaemon"; exit 1; }
  launchctl kickstart -k system/local.codex.region-spoof-loader || { echo "Fatal Error: Failed to kickstart LaunchDaemon"; exit 1; }
}

apply_generative_models_patch() {
  if [[ "$USE_SAFE_OVERRIDE" -eq 1 ]]; then
    section "Applying Safe FeatureFlag Override"
    
    mkdir -p "$OVERRIDE_DIR"
    if [[ -f "$OVERRIDE_PLIST" ]]; then
      cp "$OVERRIDE_PLIST" "$CURRENT_BACKUP_DIR/GenerativeModels_Override.plist.backup"
    fi
    
    /usr/libexec/PlistBuddy -c "Clear dict" "$OVERRIDE_PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :EnhancedSiriWaitlist dict" "$OVERRIDE_PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :EnhancedSiriWaitlist:Enabled bool false" "$OVERRIDE_PLIST" 2>/dev/null || \
    /usr/libexec/PlistBuddy -c "Set :EnhancedSiriWaitlist:Enabled false" "$OVERRIDE_PLIST" || \
    { echo "Fatal Error: PlistBuddy failed to modify the safe override plist."; exit 1; }
    
    chown root:wheel "$OVERRIDE_PLIST"
    chmod 0644 "$OVERRIDE_PLIST"
    echo "Safe FeatureFlag Override applied successfully to $OVERRIDE_PLIST!"
    
  else
    section "Mounting & Editing Sealed System Volume"
    
    local root_dev
    root_dev="$(mount | awk '$3 == "/" {print $1; exit}')"
    if [[ -z "$root_dev" ]]; then
      echo "Fatal Error: Could not determine root device." >&2
      exit 1
    fi
    
    local sys_dev
    sys_dev="$(echo "$root_dev" | sed -E 's/(s[0-9]+)s[0-9]+$/\1/')"
    if [[ ! -b "$sys_dev" ]]; then
      echo "Fatal Error: Parsed device $sys_dev is not a valid block device." >&2
      exit 1
    fi
    
    echo "Identified System Volume: $sys_dev"

    mkdir -p "$MOUNT_POINT"
    echo "Mounting $sys_dev to $MOUNT_POINT (Read/Write)..."
    mount -o nobrowse -t apfs "$sys_dev" "$MOUNT_POINT" || { echo "Fatal Error: Failed to mount System Volume."; exit 1; }

    if [[ -f "$PLIST_PATH" ]]; then
      echo "Found GenerativeModels.plist. Backing up and editing..."
      cp "$PLIST_PATH" "$CURRENT_BACKUP_DIR/GenerativeModels.plist.backup"
      
      /usr/libexec/PlistBuddy -c "Add :EnhancedSiriWaitlist dict" "$PLIST_PATH" 2>/dev/null || true
      /usr/libexec/PlistBuddy -c "Add :EnhancedSiriWaitlist:Enabled bool false" "$PLIST_PATH" 2>/dev/null || \
      /usr/libexec/PlistBuddy -c "Set :EnhancedSiriWaitlist:Enabled false" "$PLIST_PATH" || \
      { echo "Fatal Error: PlistBuddy failed to modify the plist."; exit 1; }
      
      chown root:wheel "$PLIST_PATH"
      chmod 0644 "$PLIST_PATH"
    else
      echo "Fatal Error: $PLIST_PATH not found on the system volume!"
      exit 1
    fi

    echo "Creating new EFI boot snapshot..."
    bless --mount "$MOUNT_POINT" --bootefi --create-snapshot || { echo "Fatal Error: Failed to bless snapshot."; exit 1; }
    
    echo "Snapshot created successfully!"
    diskutil unmount force "$MOUNT_POINT" 2>/dev/null || umount "$MOUNT_POINT" 2>/dev/null || true
  fi
}

uninstall() {
  section "Apple Intelligence Uninstall / Restore"
  check_security_status
  
  local LATEST_BACKUP=""
  local OLDEST_BACKUP=""
  
  if [[ -d "$BACKUP_BASE" ]]; then
    # Use latest backup for caching/preferences, but oldest backup for pristine system files
    LATEST_BACKUP=$(ls -td "$BACKUP_BASE"/*/ 2>/dev/null | head -1 || true)
    OLDEST_BACKUP=$(ls -td "$BACKUP_BASE"/*/ 2>/dev/null | tail -1 || true)
  fi

  echo "Unloading and removing CodexRegionSpoof.kext and Daemons..."
  if [[ -d "$KEXT" ]]; then
    kmutil unload -p "$KEXT" 2>/dev/null || true
    rm -rf "$KEXT"
  fi
  launchctl bootout system "$LOADER_PLIST" 2>/dev/null || true
  rm -f "$LOADER_PLIST" "$LOADER_SCRIPT"
  
  sudo -u "${SUDO_USER:-$USER}" defaults delete com.apple.assistant.backedup SiriAvailability 2>/dev/null || true
  killall cfprefsd 2>/dev/null || true
  
  chflags nouchg,noschg /private/var/db/eligibilityd/eligibility.plist 2>/dev/null || true
  rm -f /private/var/db/eligibilityd/eligibility.plist
  chflags nouchg,noschg /private/var/db/os_eligibility/eligibility.plist 2>/dev/null || true
  rm -f /private/var/db/os_eligibility/eligibility.plist

  if [[ -f "$OVERRIDE_PLIST" ]]; then
    echo "Removing Safe FeatureFlag Override..."
    rm -f "$OVERRIDE_PLIST"
  fi

  if [[ -n "$LATEST_BACKUP" ]]; then
    echo "Restoring previous preferences and caches from: $LATEST_BACKUP"
    local siri_pref="$REAL_HOME/Library/Preferences/com.apple.assistant.backedup.plist"
    
    if [[ -f "$LATEST_BACKUP/siri_pref.backup" ]]; then
      cp "$LATEST_BACKUP/siri_pref.backup" "$siri_pref"
      chown $(stat -f "%Su" "$REAL_HOME") "$siri_pref"
    fi
    if [[ -f "$LATEST_BACKUP/eligibility.backup" ]]; then cp "$LATEST_BACKUP/eligibility.backup" "/private/var/db/eligibilityd/eligibility.plist"; fi
    if [[ -f "$LATEST_BACKUP/os_eligibility.backup" ]]; then cp "$LATEST_BACKUP/os_eligibility.backup" "/private/var/db/os_eligibility/eligibility.plist"; fi
    if [[ -f "$LATEST_BACKUP/countryCodeCache.backup" ]]; then cp "$LATEST_BACKUP/countryCodeCache.backup" "/private/var/db/com.apple.countryd/countryCodeCache.plist"; fi

    if [[ -f "$LATEST_BACKUP/GenerativeModels_Override.plist.backup" ]]; then
       mkdir -p "$OVERRIDE_DIR"
       cp "$LATEST_BACKUP/GenerativeModels_Override.plist.backup" "$OVERRIDE_PLIST"
       chown root:wheel "$OVERRIDE_PLIST"
       chmod 0644 "$OVERRIDE_PLIST"
    fi

    # System file restoration (Uses OLDEST_BACKUP to prevent double-run tamper restores)
    if [[ -n "$OLDEST_BACKUP" && -f "$OLDEST_BACKUP/GenerativeModels.plist.backup" ]]; then
      section "Restoring System Volume (From pristine backup: $OLDEST_BACKUP)..."
      local root_dev
      root_dev="$(mount | awk '$3 == "/" {print $1; exit}')"
      local sys_dev
      sys_dev="$(echo "$root_dev" | sed -E 's/(s[0-9]+)s[0-9]+$/\1/')"
      if [[ ! -b "$sys_dev" ]]; then
        echo "Fatal Error: Parsed device $sys_dev is not a valid block device." >&2
        exit 1
      fi
      
      mkdir -p "$MOUNT_POINT"
      mount -o nobrowse -t apfs "$sys_dev" "$MOUNT_POINT" || { echo "Fatal Error: Failed to mount System Volume."; exit 1; }
      
      echo "Restoring original GenerativeModels.plist..."
      cp "$OLDEST_BACKUP/GenerativeModels.plist.backup" "$PLIST_PATH"
      chown root:wheel "$PLIST_PATH"
      chmod 0644 "$PLIST_PATH"
      
      echo "Creating new restored boot snapshot..."
      bless --mount "$MOUNT_POINT" --bootefi --create-snapshot || { echo "Fatal Error: Failed to bless snapshot."; exit 1; }
      
      diskutil unmount force "$MOUNT_POINT" 2>/dev/null || umount "$MOUNT_POINT" 2>/dev/null || true
      echo "System volume restored."
    else
      echo "No GenerativeModels.plist pristine backup found. Skipping System volume restore."
    fi
  else
    echo "No backup directory found! Skipping file restoration."
  fi

  section "Uninstall Complete"
  echo "Note: The backup folder ($BACKUP_BASE) was intentionally kept."
  echo "Reboot your Mac to boot into the restored configuration."
  exit 0
}

# --- Execution Flow ---
if [[ "$DO_VERIFY_ONLY" -eq 1 ]]; then
  verify_only
fi

if [[ "$DO_UNINSTALL" -eq 1 ]]; then
  uninstall
fi

check_security_status
clean_previous_configurations
ensure_region_spoof_kext_installed
install_boot_loader
apply_generative_models_patch

section "Installation Complete!"
echo "1. Backed up and cleared old configuration caches."
echo "2. Installed the secure hardware spoofer."
if [[ "$SKIP_LOCATION_SPOOF" -eq 1 ]]; then
  echo "3. Skipped Location/Geo spoofing."
else
  echo "3. Configured secure boot-time US Location/Geo spoofing."
fi
if [[ "$USE_SAFE_OVERRIDE" -eq 1 ]]; then
  echo "4. Applied Safe FeatureFlag Override (System Volume untouched)."
else
  echo "4. Edited the sealed system volume and created a new snapshot."
fi
echo ""
echo "Next Step: Reboot your Mac to activate Siri AI!"