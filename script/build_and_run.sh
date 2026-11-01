#!/bin/bash
set -euo pipefail
umask 077

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
ARCHIVE="${DIST_DIR}/Bose USB Background 0.2.1.zip"
LABEL="local.codex.BoseUSBBridge"
DOMAIN="gui/$(/usr/bin/id -u)"
OLD_APP="/Applications/Bose USB.app"
case "$MODE" in run|--verify|--build-only) ;; *) echo 'usage: build_and_run.sh [--verify|--build-only]' >&2; exit 2;; esac

if [[ "$MODE" != "--build-only" ]] && { [[ -e "$OLD_APP" ]] || /usr/bin/pgrep -f '/Applications/Bose USB.app/Contents/MacOS/BoseUSBBridge' >/dev/null; }; then
  echo 'Legacy Bose USB.app is present or running; quit/remove it before building or installing the background service.' >&2
  exit 1
fi

STAGING="$(/usr/bin/mktemp -d /private/tmp/BoseUSBBackground.XXXXXX)"
trap '/bin/rm -rf "$STAGING"' EXIT
PACKAGE_ROOT="${STAGING}/BoseUSBBackground"
SERVICE="${PACKAGE_ROOT}/payload/Service"
/bin/mkdir -p "${SERVICE}/bin" "${SERVICE}/Helpers" "${DIST_DIR}"

cd "$ROOT_DIR"
swift build -c release -Xswiftc -Osize -Xswiftc -gnone
BIN_PATH="$(swift build -c release --show-bin-path)"
/usr/bin/install -m 755 "${BIN_PATH}/BoseUSBBridge" "${SERVICE}/bin/BoseUSBBridge"
/usr/bin/install -m 755 "${ROOT_DIR}/script/bose-usb" "${SERVICE}/bin/bose-usb"
clang -Os -mmacosx-version-min=14.0 -Wall -Wextra -Werror Helpers/bose_mode.c -framework IOKit -framework CoreFoundation -o "${SERVICE}/Helpers/bose_mode"
clang -Os -mmacosx-version-min=14.0 -Wall -Wextra -Werror -Wno-deprecated-declarations Helpers/native_usb.c -framework IOKit -framework CoreFoundation -o "${SERVICE}/Helpers/native_usb"
clang -Os -mmacosx-version-min=14.0 -Wall -Wextra -Werror Helpers/bose_source.c -framework IOKit -framework CoreFoundation -o "${SERVICE}/Helpers/bose_source"
for helper in bose_mode native_usb bose_source; do
  codesign --force --sign - "${SERVICE}/Helpers/${helper}"
  codesign --verify --strict "${SERVICE}/Helpers/${helper}"
done
/usr/bin/strip -S -x "${SERVICE}/bin/BoseUSBBridge"
codesign --force --sign - "${SERVICE}/bin/BoseUSBBridge"
codesign --verify --strict "${SERVICE}/bin/BoseUSBBridge"
for name in install.sh uninstall.sh control.sh; do /usr/bin/install -m 755 "${ROOT_DIR}/script/${name}" "${PACKAGE_ROOT}/${name}"; done
/usr/bin/install -m 644 "${ROOT_DIR}/README.md" "${PACKAGE_ROOT}/README.md"
for name in LICENSE NOTICE CHANGELOG.md; do /usr/bin/install -m 644 "${ROOT_DIR}/${name}" "${PACKAGE_ROOT}/${name}"; done
/usr/bin/ditto "${ROOT_DIR}/docs" "${PACKAGE_ROOT}/docs"
/usr/bin/ditto -c -k --keepParent "$PACKAGE_ROOT" "$ARCHIVE"
echo "Package: $ARCHIVE"

if [[ "$MODE" == "--build-only" ]]; then exit 0; fi
"${PACKAGE_ROOT}/install.sh"

if [[ "$MODE" == "--verify" ]]; then
  READY=0
  for ((i=0; i<45; i++)); do
    BIN="${HOME}/Library/Application Support/BoseUSBBridge/Service/bin/BoseUSBBridge"
    if STATUS_JSON="$("$BIN" status 2>/dev/null)" && \
      OK="$(printf '%s\n' "$STATUS_JSON" | /usr/bin/plutil -extract ok raw -o - - 2>/dev/null)" && \
      RUNNING="$(printf '%s\n' "$STATUS_JSON" | /usr/bin/plutil -extract running raw -o - - 2>/dev/null)" && \
      BUSY="$(printf '%s\n' "$STATUS_JSON" | /usr/bin/plutil -extract busy raw -o - - 2>/dev/null)" && \
      CONNECTED="$(printf '%s\n' "$STATUS_JSON" | /usr/bin/plutil -extract connected raw -o - - 2>/dev/null)" && \
      ACTIVE="$(printf '%s\n' "$STATUS_JSON" | /usr/bin/plutil -extract active raw -o - - 2>/dev/null)" && \
      [[ "$OK" == true && "$RUNNING" == true && "$BUSY" == false ]] && \
      { [[ "$CONNECTED" == false ]] || [[ "$ACTIVE" == true ]]; }; then READY=1; break; fi
    /bin/sleep 1
  done
  if [[ "$READY" != 1 ]]; then echo 'Service did not reach a settled status within 45 seconds.' >&2; exit 1; fi
  if ! /bin/launchctl print "${DOMAIN}/${LABEL}" 2>/dev/null | /usr/bin/grep -q 'pid ='; then
    echo 'LaunchAgent loaded without a running service process.' >&2
    exit 1
  fi
  echo 'Verified: settled service process is running. A connected-device transition still requires device observation.'
fi
