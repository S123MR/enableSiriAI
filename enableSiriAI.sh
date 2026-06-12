#!/bin/zsh
set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

# Variables & Flags
DO_UNINSTALL=0
DO_VERIFY_ONLY=0
SKIP_LOCATION_SPOOF=0

KEXT="/Library/Extensions/CodexRegionSpoof.kext"
LOCAL_KEXT="$ROOT_DIR/tools/CodexRegionSpoof.kext"
LOCAL_KEXT_BIN="$LOCAL_KEXT/Contents/MacOS/CodexRegionSpoof"
LOCAL_KEXT_BIN_B64="$LOCAL_KEXT/Contents/MacOS/CodexRegionSpoof.b64"
LOADER_SCRIPT="/Library/Scripts/Codex/load-region-spoof.sh"
LOADER_PLIST="/Library/LaunchDaemons/local.codex.region-spoof-loader.plist"
MOUNT_POINT="/tmp/mount"
PLIST_PATH="$MOUNT_POINT/System/Library/FeatureFlags/Domain/GenerativeModels.plist"
BACKUP_DIR="/private/var/db/codex_featureflags_backup"

ORIG_ARGS=("$@")

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall) DO_UNINSTALL=1 ;;
    --verify-only) DO_VERIFY_ONLY=1 ;;
    --skip-location-spoof) SKIP_LOCATION_SPOOF=1 ;;
    -h|--help)
      echo "Usage: ./enable_apple_intelligence_oneclick.sh [options]"
      echo "Options:"
      echo "  --skip-location-spoof  Skip software IP/Location spoofing (keeps Hardware model spoofing)."
      echo "  --verify-only          Check current system state and configurations."
      echo "  --uninstall            Remove all spoofing and revert System volume snapshot."
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# Output formatter
section() {
  echo
  echo "== $1 =="
}

# Auto-escalate to sudo if not root
if [[ $EUID -ne 0 && "$DO_VERIFY_ONLY" -eq 0 ]]; then
  echo "Administrative privileges required. Prompting for sudo..."
  exec sudo "$0" "${ORIG_ARGS[@]}"
fi

# Preflight: Check SIP and Authenticated Root
check_security_status() {
  local warn=0
  if csrutil status | grep -qi 'enabled'; then warn=1; fi
  if csrutil authenticated-root status | grep -qi 'enabled'; then warn=1; fi
  
  if [[ $warn -eq 1 ]]; then
    section "Security Protections Alert"
    echo "WARNING: System Integrity Protection (SIP) or Authenticated Root appears to be enabled."
    echo "Modifying the sealed System volume and loading custom kexts requires these to be disabled."
    echo "If you proceed, the snapshot creation or kext loading may fail."
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
  echo "macOS: $(sw_vers -productVersion 2>/dev/null || true)"
  
  section "SIP / SSV"
  csrutil status 2>&1 || true
  csrutil authenticated-root status 2>&1 || true

  section "Hardware Region State"
  ioreg -rd1 -c IOPlatformExpertDevice | grep -Ei '"region-info"|"country-of-origin"|"model"|"model-number"' || true

  section "CodexRegionSpoof Kext"
  kmutil showloaded 2>/dev/null | grep -Ei 'Codex|RegionSpoof' || echo "CodexRegionSpoof is not currently loaded."

  section "GenerativeModels FeatureFlags (Live System)"
  if [[ -f "/System/Library/FeatureFlags/Domain/GenerativeModels.plist" ]]; then
    plutil -p "/System/Library/FeatureFlags/Domain/GenerativeModels.plist" | grep -A 2 "EnhancedSiriWaitlist" || echo "EnhancedSiriWaitlist key not found in live system."
  else
    echo "GenerativeModels.plist not found in /System/Library/FeatureFlags/Domain/"
  fi
  
  exit 0
}

clean_previous_configurations() {
  section "Cleaning previous configurations & caches"
  mkdir -p "$BACKUP_DIR"

  # Unload daemons
  launchctl bootout system "$LOADER_PLIST" 2>/dev/null || true
  rm -f "$LOADER_PLIST" "$LOADER_SCRIPT" 2>/dev/null || true
  
  # Non-destructive backups of original state (cp -n prevents overwriting the very first backup)
  local siri_pref="$HOME/Library/Preferences/com.apple.assistant.backedup.plist"
  [[ -f "$siri_pref" ]] && cp -n "$siri_pref" "$BACKUP_DIR/siri_pref.backup" 2>/dev/null || true
  [[ -f "/private/var/db/eligibilityd/eligibility.plist" ]] && cp -n "/private/var/db/eligibilityd/eligibility.plist" "$BACKUP_DIR/eligibility.backup" 2>/dev/null || true
  [[ -f "/private/var/db/os_eligibility/eligibility.plist" ]] && cp -n "/private/var/db/os_eligibility/eligibility.plist" "$BACKUP_DIR/os_eligibility.backup" 2>/dev/null || true
  [[ -f "/private/var/db/com.apple.countryd/countryCodeCache.plist" ]] && cp -n "/private/var/db/com.apple.countryd/countryCodeCache.plist" "$BACKUP_DIR/countryCodeCache.backup" 2>/dev/null || true

  # Remove UI locks
  defaults delete com.apple.assistant.backedup SiriAvailability 2>/dev/null || true
  rm -f "$HOME/Library/Containers/com.apple.systempreferences.AppleIDSettings/Data/Library/Preferences/com.apple.assistant.backedup.plist" 2>/dev/null || true
  
  # Clear eligibility cache
  chflags nouchg /private/var/db/eligibilityd/eligibility.plist 2>/dev/null || true
  rm -f /private/var/db/eligibilityd/eligibility.plist 2>/dev/null || true
  chflags nouchg /private/var/db/os_eligibility/eligibility.plist 2>/dev/null || true
  rm -f /private/var/db/os_eligibility/eligibility.plist 2>/dev/null || true

  # Unlock countryd cache
  chflags nouchg /private/var/db/com.apple.countryd/countryCodeCache.plist 2>/dev/null || true
  chmod 0644 /private/var/db/com.apple.countryd/countryCodeCache.plist 2>/dev/null || true
}

ensure_region_spoof_kext_installed() {
  section "Installing Hardware Region Spoofer"
  if [[ -d "$KEXT" ]]; then
    echo "Kext already installed at $KEXT, replacing..."
  fi

  if [[ ! -d "$LOCAL_KEXT" ]]; then
    echo "Error: Missing local bundle $LOCAL_KEXT" >&2
    exit 1
  fi

  if [[ ! -x "$LOCAL_KEXT_BIN" && -f "$LOCAL_KEXT_BIN_B64" ]]; then
    /usr/bin/base64 -D -i "$LOCAL_KEXT_BIN_B64" -o "$LOCAL_KEXT_BIN"
    chmod 755 "$LOCAL_KEXT_BIN"
  fi

  rm -rf "$KEXT"
  cp -R "$LOCAL_KEXT" "$KEXT"
  chown -R root:wheel "$KEXT"
  chmod -R go-w "$KEXT"
}

install_boot_loader() {
  mkdir -p /Library/Scripts/Codex

  local tmp_script="$(mktemp)"
  cat > "$tmp_script" <<EOF
#!/bin/zsh
set -u

LOG="/var/log/codex-region-spoof-loader.log"
KEXT="/Library/Extensions/CodexRegionSpoof.kext"

{
  echo "==== \$(date) ===="
  if /usr/bin/kmutil showloaded 2>/dev/null | /usr/bin/grep -qi 'local.codex.RegionSpoof'; then
    echo "CodexRegionSpoof already loaded"
  else
    echo "loading \$KEXT"
    /usr/bin/kmutil load -p "\$KEXT" || true
  fi

  /bin/sleep 1
  /usr/bin/killall eligibilityd generativeexperiencesd modelcatalogd 2>/dev/null || true

EOF

  # If not skipped, inject mainland China location override logic into loader
  if [[ "$SKIP_LOCATION_SPOOF" -eq 0 ]]; then
    cat >> "$tmp_script" <<'EOF'
  GEO_CC="US"
  GEO_IP="unknown"
  GEO_CITY="unknown"
  
  if /usr/bin/curl -s --max-time 8 https://ipinfo.io/json >/tmp/codex_geo_ip.json 2>/dev/null; then
    GEO_CC="$(/usr/bin/python3 -c 'import json; print((json.load(open("/tmp/codex_geo_ip.json")).get("country") or "").upper())' 2>/dev/null || true)"
    GEO_IP="$(/usr/bin/python3 -c 'import json; print(json.load(open("/tmp/codex_geo_ip.json")).get("ip",""))' 2>/dev/null || true)"
    GEO_CITY="$(/usr/bin/python3 -c 'import json; print(json.load(open("/tmp/codex_geo_ip.json")).get("city",""))' 2>/dev/null || true)"
  fi
  if [ -z "$GEO_CC" ]; then GEO_CC="US"; fi
  
  /bin/mkdir -p /var/db/locationd/Library/Caches/GeoServices
  /usr/bin/python3 - "$GEO_CC" "$GEO_IP" "$GEO_CITY" <<'PY'
import plistlib, sys
cc, ip, city = sys.argv[1:4]
payload = {"DeviceCountryCodeSourced": {"cc": cc, "metadata": {"sourceNote": "boot-time spoof", "ip": ip, "city": city}, "source": 262}}
with open("/var/db/locationd/Library/Caches/GeoServices/DirectReadConfigStore.plist", "wb") as f:
    plistlib.dump(payload, f)
PY
  /usr/sbin/chown _locationd:_locationd /var/db/locationd/Library/Caches/GeoServices/DirectReadConfigStore.plist 2>/dev/null || true
  /bin/chmod 0644 /var/db/locationd/Library/Caches/GeoServices/DirectReadConfigStore.plist 2>/dev/null || true
  /usr/bin/killall locationd geod routined 2>/dev/null || true
EOF
  fi

  cat >> "$tmp_script" <<'EOF'
} >> "$LOG" 2>&1
exit 0
EOF

  install -o root -g wheel -m 755 "$tmp_script" "$LOADER_SCRIPT"
  rm -f "$tmp_script"

  local tmp_plist="$(mktemp)"
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
  launchctl bootstrap system "$LOADER_PLIST" || { echo "Error: Failed to bootstrap LaunchDaemon"; exit 1; }
  launchctl kickstart -k system/local.codex.region-spoof-loader || { echo "Error: Failed to kickstart LaunchDaemon"; exit 1; }
}

modify_system_volume() {
  section "Mounting & Editing Sealed System Volume"
  
  # Step 6: Find root device (matches diskutil apfs list Role: System)
  local root_dev="$(mount | awk '$3 == "/" {print $1; exit}')"
  if [[ -z "$root_dev" ]]; then
    echo "Error: Could not determine root device." >&2
    exit 1
  fi
  # Convert snapshot identifier (e.g. disk3s5s1) to volume identifier (e.g. disk3s5)
  local sys_dev="$(echo "$root_dev" | sed -E 's/(s[0-9]+)s[0-9]+$/\1/')"
  echo "Identified System Volume: $sys_dev"

  # Step 7: Mount
  mkdir -p "$MOUNT_POINT"
  echo "Mounting $sys_dev to $MOUNT_POINT (Read/Write)..."
  mount -o nobrowse -t apfs "$sys_dev" "$MOUNT_POINT"

  # Step 8: Edit the plist using Python
  if [[ -f "$PLIST_PATH" ]]; then
    echo "Found GenerativeModels.plist. Backing up and editing..."
    mkdir -p "$BACKUP_DIR"
    cp "$PLIST_PATH" "$BACKUP_DIR/GenerativeModels.plist.backup"
    
    local patcher="$(mktemp)"
    cat > "$patcher" <<'PY'
import os, plistlib, sys
path = sys.argv[1]
try:
    with open(path, "rb") as f:
        data = plistlib.load(f)
except FileNotFoundError:
    data = {}

if "EnhancedSiriWaitlist" not in data or not isinstance(data["EnhancedSiriWaitlist"], dict):
    data["EnhancedSiriWaitlist"] = {}

data["EnhancedSiriWaitlist"]["Enabled"] = False

tmp = f"{path}.tmp"
with open(tmp, "wb") as f:
    plistlib.dump(data, f, fmt=plistlib.FMT_BINARY)

os.replace(tmp, path)
print("Successfully modified EnhancedSiriWaitlist:Enabled to <false/>")
PY
    /usr/bin/python3 "$patcher" "$PLIST_PATH"
    rm -f "$patcher"
    
    # Ensure proper permissions
    chown root:wheel "$PLIST_PATH"
    chmod 0644 "$PLIST_PATH"
  else
    echo "Error: $PLIST_PATH not found on the system volume!"
    exit 1
  fi

  # Step 9: Bless the snapshot
  echo "Creating new EFI boot snapshot..."
  bless --mount "$MOUNT_POINT" --bootefi --create-snapshot
  echo "Snapshot created successfully!"
}

uninstall() {
  section "Apple Intelligence Uninstall / Restore"
  check_security_status
  
  clean_previous_configurations
  
  echo "Unloading and removing CodexRegionSpoof.kext..."
  if [[ -d "$KEXT" ]]; then
    kmutil unload -p "$KEXT" 2>/dev/null || true
    rm -rf "$KEXT"
  fi

  # Restore cached plists
  echo "Restoring previous preferences and caches..."
  local siri_pref="$HOME/Library/Preferences/com.apple.assistant.backedup.plist"
  [[ -f "$BACKUP_DIR/siri_pref.backup" ]] && cp "$BACKUP_DIR/siri_pref.backup" "$siri_pref" && chown $(stat -f "%Su" "$HOME") "$siri_pref" 2>/dev/null || true
  [[ -f "$BACKUP_DIR/eligibility.backup" ]] && cp "$BACKUP_DIR/eligibility.backup" "/private/var/db/eligibilityd/eligibility.plist" 2>/dev/null || true
  [[ -f "$BACKUP_DIR/os_eligibility.backup" ]] && cp "$BACKUP_DIR/os_eligibility.backup" "/private/var/db/os_eligibility/eligibility.plist" 2>/dev/null || true
  [[ -f "$BACKUP_DIR/countryCodeCache.backup" ]] && cp "$BACKUP_DIR/countryCodeCache.backup" "/private/var/db/com.apple.countryd/countryCodeCache.plist" 2>/dev/null || true

  # Restore System Volume modification if backup exists
  if [[ -f "$BACKUP_DIR/GenerativeModels.plist.backup" ]]; then
    section "Restoring System Volume..."
    local root_dev="$(mount | awk '$3 == "/" {print $1; exit}')"
    local sys_dev="$(echo "$root_dev" | sed -E 's/(s[0-9]+)s[0-9]+$/\1/')"
    
    mkdir -p "$MOUNT_POINT"
    mount -o nobrowse -t apfs "$sys_dev" "$MOUNT_POINT"
    
    echo "Restoring original GenerativeModels.plist..."
    cp "$BACKUP_DIR/GenerativeModels.plist.backup" "$PLIST_PATH"
    chown root:wheel "$PLIST_PATH"
    chmod 0644 "$PLIST_PATH"
    
    echo "Creating new restored boot snapshot..."
    bless --mount "$MOUNT_POINT" --bootefi --create-snapshot
    rm -rf "$BACKUP_DIR"
    echo "System volume restored."
  else
    echo "No GenerativeModels.plist backup found. Skipping System volume restore."
  fi

  section "Uninstall Complete"
  echo "Reboot your Mac for all changes to take effect and to boot into the restored snapshot."
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
modify_system_volume

section "Installation Complete!"
echo "The script has successfully:"
echo "1. Cleared old configuration caches."
echo "2. Installed the secure hardware spoofer."
if [[ "$SKIP_LOCATION_SPOOF" -eq 1 ]]; then
  echo "3. Skipped Location/Geo spoofing (as requested by flag)."
else
  echo "3. Configured boot-time US Location/Geo spoofing."
fi
echo "4. Edited the sealed system volume (GenerativeModels.plist) and created a new snapshot."
echo ""
echo "Next Step: Reboot your Mac. You should now be greeted with the new Siri AI!"