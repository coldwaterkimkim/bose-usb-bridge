#!/bin/bash
set -euo pipefail
umask 077

owned_marker() {
  [[ -f "$1" && ! -L "$1" ]] || return 1
  case "$(/bin/cat "$1")" in
    'local.codex.BoseUSBBridge|0.2.0'|'local.codex.BoseUSBBridge|0.2.1') return 0 ;;
    *) return 1 ;;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="${SCRIPT_DIR}/payload/Service"
LABEL="local.codex.BoseUSBBridge"
APP_SUPPORT="${HOME}/Library/Application Support/BoseUSBBridge"
SERVICE_DIR="${APP_SUPPORT}/Service"
MANAGEMENT_MARKER="${APP_SUPPORT}/.bose-usb-management-owned"
MANAGEMENT_DIR="$APP_SUPPORT"
BIN="${SERVICE_DIR}/bin/BoseUSBBridge"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
DOMAIN="gui/$(/usr/bin/id -u)"

[[ ! -L "$APP_SUPPORT" ]] || { echo "Application Support path is a symlink; refusing install: $APP_SUPPORT" >&2; exit 1; }
[[ ! -L "$SERVICE_DIR" ]] || { echo "Service path is a symlink; refusing install: $SERVICE_DIR" >&2; exit 1; }

if [[ -e "/Applications/Bose USB.app" ]] || /usr/bin/pgrep -f '/Applications/Bose USB.app/Contents/MacOS/BoseUSBBridge' >/dev/null; then
  echo 'Legacy Bose USB.app is present or running; quit/remove it before installing this service.' >&2
  exit 1
fi
for tool in "${PAYLOAD}/bin/BoseUSBBridge" "${PAYLOAD}/bin/bose-usb" "${PAYLOAD}/Helpers/bose_mode" "${PAYLOAD}/Helpers/native_usb" "${PAYLOAD}/Helpers/bose_source"; do
  [[ -x "$tool" ]] || { echo "Package payload is incomplete: $tool" >&2; exit 1; }
done
/bin/mkdir -p -m 700 "$APP_SUPPORT"
/bin/chmod 700 "$APP_SUPPORT"
if [[ -e "$SERVICE_DIR" ]]; then
  [[ ! -L "$SERVICE_DIR" && -x "$BIN" && -f "${SERVICE_DIR}/.bose-usb-owned" ]] || { echo "Existing Service path is not owned by this installer; refusing overwrite: $SERVICE_DIR" >&2; exit 1; }
  owned_marker "${SERVICE_DIR}/.bose-usb-owned" || { echo "Service ownership marker does not match; refusing overwrite: $SERVICE_DIR" >&2; exit 1; }
  [[ ! -L "${SERVICE_DIR}/bin" && ! -L "${SERVICE_DIR}/Helpers" ]] || { echo 'A Service child path is a symlink; refusing overwrite.' >&2; exit 1; }
  [[ ! -e "${SERVICE_DIR}/bin" || -d "${SERVICE_DIR}/bin" ]] || { echo 'Service bin path is not a directory; refusing overwrite.' >&2; exit 1; }
  [[ ! -e "${SERVICE_DIR}/Helpers" || -d "${SERVICE_DIR}/Helpers" ]] || { echo 'Service Helpers path is not a directory; refusing overwrite.' >&2; exit 1; }
fi
if [[ -e "${APP_SUPPORT}/control.sh" || -e "${APP_SUPPORT}/uninstall.sh" || -e "$MANAGEMENT_MARKER" ]]; then
  owned_marker "${SERVICE_DIR}/.bose-usb-owned" || { echo 'An existing management script is not associated with this service; refusing overwrite.' >&2; exit 1; }
  owned_marker "$MANAGEMENT_MARKER" || { echo 'Management script ownership marker does not match; refusing overwrite.' >&2; exit 1; }
  [[ ! -L "$MANAGEMENT_MARKER" && ! -L "${APP_SUPPORT}/control.sh" && ! -L "${APP_SUPPORT}/uninstall.sh" ]] || { echo 'A management script path is a symlink; refusing overwrite.' >&2; exit 1; }
fi
[[ ! -L "$PLIST" ]] || { echo "LaunchAgent path is a symlink; refusing overwrite: $PLIST" >&2; exit 1; }
if [[ -e "$PLIST" ]]; then
  EXISTING_LABEL=$(/usr/libexec/PlistBuddy -c 'Print Label' "$PLIST" 2>/dev/null || true)
  [[ "$EXISTING_LABEL" == "$LABEL" ]] || { echo "LaunchAgent path belongs to another job; refusing overwrite: $PLIST" >&2; exit 1; }
fi
LOG_FILE="${APP_SUPPORT}/service.log"
[[ ! -L "$LOG_FILE" ]] || { echo "Service log path is a symlink; refusing install: $LOG_FILE" >&2; exit 1; }
[[ ! -e "$LOG_FILE" || -f "$LOG_FILE" ]] || { echo "Service log path is not a regular file: $LOG_FILE" >&2; exit 1; }
if [[ -e "$SERVICE_DIR" ]] || /bin/launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1; then
  if [[ ! -x "${APP_SUPPORT}/control.sh" ]]; then echo 'Existing service has no trusted controller; refusing to replace it.' >&2; exit 1; fi
  "${APP_SUPPORT}/control.sh" stop
fi

/bin/mkdir -p -m 700 "${SERVICE_DIR}/bin" "${SERVICE_DIR}/Helpers" "${HOME}/Library/LaunchAgents"
for name in BoseUSBBridge bose-usb; do /usr/bin/install -m 755 "${PAYLOAD}/bin/${name}" "${SERVICE_DIR}/bin/${name}"; done
for name in bose_mode native_usb bose_source; do /usr/bin/install -m 755 "${PAYLOAD}/Helpers/${name}" "${SERVICE_DIR}/Helpers/${name}"; done
/usr/bin/install -m 600 /dev/null "${SERVICE_DIR}/.bose-usb-owned"
printf '%s\n' 'local.codex.BoseUSBBridge|0.2.1' > "${SERVICE_DIR}/.bose-usb-owned"
/bin/chmod 700 "$SERVICE_DIR" "${SERVICE_DIR}/bin" "${SERVICE_DIR}/Helpers"

: >> "$LOG_FILE"
/bin/chmod 600 "$LOG_FILE"
PLIST_STAGE="$(/usr/bin/mktemp /private/tmp/BoseUSBBridge.plist.XXXXXX)"
trap '/bin/rm -f "$PLIST_STAGE"' EXIT
/usr/bin/plutil -create xml1 "$PLIST_STAGE"
/usr/bin/plutil -insert Label -string "$LABEL" "$PLIST_STAGE"
/usr/bin/plutil -insert ProgramArguments -json '[]' "$PLIST_STAGE"
/usr/bin/plutil -insert ProgramArguments.0 -string "$BIN" "$PLIST_STAGE"
/usr/bin/plutil -insert ProgramArguments.1 -string run "$PLIST_STAGE"
/usr/bin/plutil -insert RunAtLoad -bool YES "$PLIST_STAGE"
/usr/bin/plutil -insert KeepAlive -json '{}' "$PLIST_STAGE"
/usr/bin/plutil -insert KeepAlive.SuccessfulExit -bool NO "$PLIST_STAGE"
/usr/bin/plutil -insert LimitLoadToSessionType -string Aqua "$PLIST_STAGE"
/usr/bin/plutil -insert ExitTimeOut -integer 60 "$PLIST_STAGE"
/usr/bin/plutil -insert ThrottleInterval -integer 10 "$PLIST_STAGE"
/usr/bin/plutil -insert StandardErrorPath -string "$LOG_FILE" "$PLIST_STAGE"
/usr/bin/plutil -lint "$PLIST_STAGE" >/dev/null
/usr/bin/install -m 600 "$PLIST_STAGE" "$PLIST"

/usr/bin/install -m 755 "${SCRIPT_DIR}/control.sh" "${MANAGEMENT_DIR}/control.sh"
/usr/bin/install -m 755 "${SCRIPT_DIR}/uninstall.sh" "${MANAGEMENT_DIR}/uninstall.sh"
/usr/bin/install -m 600 /dev/null "$MANAGEMENT_MARKER"
printf '%s\n' 'local.codex.BoseUSBBridge|0.2.1' > "$MANAGEMENT_MARKER"

/bin/launchctl bootstrap "$DOMAIN" "$PLIST"
/bin/launchctl print "${DOMAIN}/${LABEL}" >/dev/null
echo "Installed and started: $BIN"
echo 'User settings and diagnostic data are preserved outside Service.'
