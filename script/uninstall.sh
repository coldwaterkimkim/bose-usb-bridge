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
LABEL="local.codex.BoseUSBBridge"
APP_SUPPORT="${HOME}/Library/Application Support/BoseUSBBridge"
SERVICE_DIR="${APP_SUPPORT}/Service"
MANAGEMENT_MARKER="${APP_SUPPORT}/.bose-usb-management-owned"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
SERVICE_OWNED=0
[[ ! -L "$APP_SUPPORT" ]] || { echo "Application Support path is a symlink; refusing uninstall: $APP_SUPPORT" >&2; exit 1; }
[[ ! -L "$SERVICE_DIR" ]] || { echo "Service path is a symlink; refusing uninstall: $SERVICE_DIR" >&2; exit 1; }
[[ ! -L "$PLIST" ]] || { echo "LaunchAgent path is a symlink; refusing removal: $PLIST" >&2; exit 1; }
if [[ -e "$SERVICE_DIR" ]]; then
  [[ ! -L "${SERVICE_DIR}/bin" && ! -L "${SERVICE_DIR}/Helpers" && -x "${SERVICE_DIR}/bin/BoseUSBBridge" && -f "${SERVICE_DIR}/.bose-usb-owned" ]] || { echo "Service path ownership could not be verified; refusing removal: $SERVICE_DIR" >&2; exit 1; }
  owned_marker "${SERVICE_DIR}/.bose-usb-owned" || { echo "Service ownership marker does not match; refusing removal: $SERVICE_DIR" >&2; exit 1; }
  SERVICE_OWNED=1
fi
if [[ -e "$PLIST" && ! -f "$PLIST" ]]; then echo "LaunchAgent path is not a regular file; refusing removal: $PLIST" >&2; exit 1; fi
if [[ -f "$PLIST" ]]; then
  /usr/bin/plutil -lint "$PLIST" >/dev/null || { echo "LaunchAgent plist is invalid; refusing removal: $PLIST" >&2; exit 1; }
  EXISTING_LABEL=$(/usr/libexec/PlistBuddy -c 'Print Label' "$PLIST" 2>/dev/null || true)
  [[ "$EXISTING_LABEL" == "$LABEL" ]] || { echo "LaunchAgent label does not match; refusing removal: $PLIST" >&2; exit 1; }
fi
for path in "${APP_SUPPORT}/control.sh" "${APP_SUPPORT}/uninstall.sh"; do
  [[ ! -L "$path" ]] || { echo "Management script path is a symlink; refusing uninstall: $path" >&2; exit 1; }
  [[ ! -e "$path" || -f "$path" ]] || { echo "Management script path is not a regular file: $path" >&2; exit 1; }
done
[[ ! -L "$MANAGEMENT_MARKER" ]] || { echo 'Management ownership marker is a symlink; refusing uninstall.' >&2; exit 1; }
if [[ "$SERVICE_OWNED" == 1 && ( -e "${APP_SUPPORT}/control.sh" || -e "${APP_SUPPORT}/uninstall.sh" || -e "$MANAGEMENT_MARKER" ) ]]; then
  owned_marker "$MANAGEMENT_MARKER" || { echo 'Management script ownership could not be verified; refusing uninstall.' >&2; exit 1; }
fi

DOMAIN="gui/$(/usr/bin/id -u)"
if /bin/launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1 || [[ "$SERVICE_OWNED" == 1 ]]; then
  if [[ "$SERVICE_OWNED" == 1 && -x "${APP_SUPPORT}/control.sh" ]]; then
    "${APP_SUPPORT}/control.sh" stop
  elif [[ -x "${SCRIPT_DIR}/control.sh" ]]; then
    "${SCRIPT_DIR}/control.sh" stop
  elif [[ "$SERVICE_OWNED" == 0 ]] && /bin/launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1; then
    PID=$(/bin/launchctl print "${DOMAIN}/${LABEL}" 2>/dev/null | /usr/bin/awk '/pid =/ {print $3; exit}')
    [[ -z "$PID" ]] || { echo 'A LaunchAgent process is running without an owned executable; refusing removal.' >&2; exit 1; }
    /bin/launchctl bootout "${DOMAIN}/${LABEL}"
  else
    echo 'Cannot locate a trusted controller to verify safe shutdown.' >&2
    exit 1
  fi
fi

if [[ "$SERVICE_OWNED" == 1 ]]; then /bin/rm -rf "$SERVICE_DIR"; fi
if [[ -f "$PLIST" ]]; then /bin/rm -f "$PLIST"; fi
if [[ "$SERVICE_OWNED" == 1 ]]; then
  if [[ -f "${APP_SUPPORT}/control.sh" ]]; then /bin/rm -f "${APP_SUPPORT}/control.sh"; fi
  if [[ -f "${APP_SUPPORT}/uninstall.sh" ]]; then /bin/rm -f "${APP_SUPPORT}/uninstall.sh"; fi
  if [[ -f "$MANAGEMENT_MARKER" ]]; then /bin/rm -f "$MANAGEMENT_MARKER"; fi
fi
echo 'Service removed. User settings, remembered volume, routing state, and diagnostics were preserved.'
