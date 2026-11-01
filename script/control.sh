#!/bin/bash
set -euo pipefail
umask 077

LABEL="local.codex.BoseUSBBridge"
APP_SUPPORT="${HOME}/Library/Application Support/BoseUSBBridge"
SERVICE_DIR="${APP_SUPPORT}/Service"
BIN="${SERVICE_DIR}/bin/BoseUSBBridge"
PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
DOMAIN="gui/$(/usr/bin/id -u)"

usage() {
  cat <<'EOF'
Usage: ./script/control.sh {start|stop|restart|status|normal|resume|uninstall|native [args...]}
  start     load the per-user background service
  stop      ask the service to restore normal mode, then unload its LaunchAgent
  restart   stop safely and start again
  status    print current service status
  normal    restore ordinary USB mode and the output the service changed
  resume    resume automatic USB mode handling
  native    pass a supported command to the service executable
EOF
}

require_install() {
  [[ -x "$BIN" ]] || { echo "Service executable not found: $BIN" >&2; exit 1; }
}

legacy_guard() {
  if [[ -e "/Applications/Bose USB.app" ]] || /usr/bin/pgrep -f '/Applications/Bose USB.app/Contents/MacOS/BoseUSBBridge' >/dev/null; then
    echo 'Legacy Bose USB.app is present or running; remove/quit it before using the background service.' >&2
    exit 1
  fi
}

loaded() { /bin/launchctl print "${DOMAIN}/${LABEL}" >/dev/null 2>&1; }
job_pid() { /bin/launchctl print "${DOMAIN}/${LABEL}" 2>/dev/null | /usr/bin/awk '/pid =/ {print $3; exit}'; }
field() { /usr/bin/plutil -extract "$1" raw -o - -; }
native_status() { "$BIN" status; }

stop_service() {
  local is_loaded=0 pid='' status='' running=''
  loaded && is_loaded=1
  if [[ ! -x "$BIN" ]]; then
    pid="$(job_pid || true)"
    if [[ -n "$pid" ]]; then echo 'Service process is running but its executable is missing; refusing to unload.' >&2; return 1; fi
    if [[ "$is_loaded" == 1 ]]; then /bin/launchctl bootout "${DOMAIN}/${LABEL}"; fi
    return 0
  fi
  if ! status="$(native_status 2>/dev/null)"; then
    pid="$(job_pid || true)"
    if [[ -n "$pid" ]]; then echo 'Native status is unavailable while the LaunchAgent has a process; refusing to unload.' >&2; return 1; fi
    if [[ "$is_loaded" == 1 ]]; then /bin/launchctl bootout "${DOMAIN}/${LABEL}"; return; fi
    echo 'Native service status is unavailable; refusing to assume it is stopped.' >&2
    return 1
  fi
  running="$(printf '%s\n' "$status" | field running)"
  if [[ "$running" == true ]]; then
    if ! "$BIN" shutdown; then echo 'Graceful shutdown failed; refusing to unload.' >&2; return 1; fi
    local i
    for ((i=0; i<70; i++)); do
      status="$(native_status 2>/dev/null || true)"
      running="$(printf '%s\n' "$status" | field running 2>/dev/null || true)"
      pid="$(job_pid || true)"
      if [[ "$running" == false && -z "$pid" ]]; then break; fi
      /bin/sleep 1
    done
    if [[ "$running" != false || -n "$pid" ]]; then
      echo 'Service did not confirm shutdown and process exit; refusing to unload.' >&2
      return 1
    fi
  else
    pid="$(job_pid || true)"
    if [[ -n "$pid" ]]; then
      local i
      for ((i=0; i<70; i++)); do
        pid="$(job_pid || true)"
        [[ -n "$pid" ]] || break
        /bin/sleep 1
      done
      [[ -z "$pid" ]] || { echo 'LaunchAgent process did not exit; refusing to unload.' >&2; return 1; }
    fi
  fi
  if loaded; then /bin/launchctl bootout "${DOMAIN}/${LABEL}"; fi
}

start_service() {
  require_install
  legacy_guard
  if loaded; then
    /bin/launchctl kickstart "${DOMAIN}/${LABEL}"
  else
    [[ -f "$PLIST" ]] || { echo "LaunchAgent not found: $PLIST" >&2; exit 1; }
    /bin/launchctl bootstrap "$DOMAIN" "$PLIST"
  fi
  /bin/launchctl print "${DOMAIN}/${LABEL}" >/dev/null
}

command_name="${1:-}"
[[ $# -eq 0 ]] || shift
case "$command_name" in
  start) start_service ;;
  stop) stop_service ;;
  restart) stop_service; start_service ;;
  status) require_install; "$BIN" status ;;
  normal) require_install; "$BIN" normal ;;
  resume) require_install; "$BIN" resume ;;
  native) require_install; exec "$BIN" "$@" ;;
  uninstall)
    if [[ -x "${APP_SUPPORT}/uninstall.sh" ]]; then exec "${APP_SUPPORT}/uninstall.sh"; fi
    echo 'Installed uninstaller not found.' >&2; exit 1 ;;
  -h|--help|help|'') usage ;;
  *) usage >&2; exit 2 ;;
esac
