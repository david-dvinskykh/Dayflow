#!/usr/bin/env bash
set -euo pipefail

# Rebuilds Dayflow from this checkout and installs it into /Applications,
# signed with the local "Dayflow Local Signing" certificate so macOS keeps
# the Screen Recording permission across rebuilds.
#
# Usage:
#   ./scripts/rebuild_local.sh            # pull, build, install, relaunch
#   ./scripts/rebuild_local.sh --no-pull  # build the checkout as it is
#
# The full build log goes to ~/dayflow-build.log.

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CERT_NAME=${CERT_NAME:-Dayflow Local Signing}
APP_DEST=/Applications/Dayflow.app
MOUNT_POINT=/tmp/dayflow-dmg
LOG="${HOME}/dayflow-build.log"
PULL=1
[[ "${1:-}" == "--no-pull" ]] && PULL=0

step() { printf '\n==> %s\n' "$*"; }
fail() {
  printf '\nERROR: %s\n' "$*" >&2
  printf 'Last lines of %s:\n' "${LOG}" >&2
  tail -25 "${LOG}" >&2 || true
  exit 1
}

cd "${REPO_ROOT}"

if [[ ${PULL} -eq 1 ]]; then
  step "Updating $(git rev-parse --abbrev-ref HEAD)"
  git pull --ff-only || fail "git pull failed (local changes or diverged branch)."
fi

step "Checking the signing certificate"
if ! security find-identity -v -p codesigning | grep -F "\"${CERT_NAME}\"" >/dev/null; then
  echo "Certificate \"${CERT_NAME}\" not found, creating it (macOS will ask for your password)…"
  "${REPO_ROOT}/scripts/create_local_signing_cert.sh"
fi

step "Building and signing (full log: ${LOG})"
rm -f "${REPO_ROOT}/Dayflow.dmg" "${REPO_ROOT}"/rw.*.Dayflow.dmg
if ! SIGN_ID="${CERT_NAME}" ALLOW_MISSING_BACKEND_URL=1 DISABLE_UPDATES=1 \
  CREATE_DMG_EXTRA_ARGS="--skip-jenkins" \
  "${REPO_ROOT}/scripts/release_dmg.sh" >"${LOG}" 2>&1; then
  grep -n "error:" "${LOG}" | head -20 >&2 || true
  fail "Build failed."
fi
[[ -f "${REPO_ROOT}/Dayflow.dmg" ]] || fail "Build finished but Dayflow.dmg is missing."
rm -f "${REPO_ROOT}"/rw.*.Dayflow.dmg

step "Installing to ${APP_DEST}"
hdiutil detach "${MOUNT_POINT}" -force -quiet >/dev/null 2>&1 || true
mkdir -p "${MOUNT_POINT}"
hdiutil attach -nobrowse -readonly -mountpoint "${MOUNT_POINT}" "${REPO_ROOT}/Dayflow.dmg" \
  >>"${LOG}" 2>&1 || fail "Could not mount Dayflow.dmg."
trap 'hdiutil detach "${MOUNT_POINT}" -force -quiet >/dev/null 2>&1 || true' EXIT
[[ -d "${MOUNT_POINT}/Dayflow.app" ]] || fail "Dayflow.app not found inside the DMG."

# Only now, with the new app in hand, replace the installed one.
pkill -x Dayflow >/dev/null 2>&1 || true
sleep 1
rm -rf "${APP_DEST}"
ditto "${MOUNT_POINT}/Dayflow.app" "${APP_DEST}" || fail "Copy to ${APP_DEST} failed."
hdiutil detach "${MOUNT_POINT}" -force -quiet >/dev/null 2>&1 || true
trap - EXIT
xattr -dr com.apple.quarantine "${APP_DEST}" 2>/dev/null || true

step "Verifying the signature"
AUTHORITY=$(codesign -dv --verbose=2 "${APP_DEST}" 2>&1 | grep '^Authority=' | head -1 || true)
echo "${AUTHORITY:-Authority=<none>}"
if [[ "${AUTHORITY}" != "Authority=${CERT_NAME}" ]]; then
  echo "WARNING: not signed with \"${CERT_NAME}\"; macOS may ask for Screen Recording again." >&2
fi

step "Launching Dayflow"
open "${APP_DEST}"
echo
echo "Done: $(defaults read "${APP_DEST}/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?')" \
  "built from $(git rev-parse --short HEAD)."
