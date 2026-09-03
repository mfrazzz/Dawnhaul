#!/bin/bash
# Dawnhaul — mount Seestar + QNAP, copy new files, unmount Seestar.
# Safe to run by hand:  ~/Dawnhaul/bin/haul.sh
set -euo pipefail

ROOT="${HOME}/Dawnhaul"
CONFIG="${ROOT}/config.json"
LOG_DIR="${ROOT}/logs"
STAMP="$(date +%Y-%m-%d)"
LOG="${LOG_DIR}/${STAMP}.log"
LOCK="${ROOT}/state/haul.lock"
mkdir -p "${LOG_DIR}" "${ROOT}/state" "${ROOT}/staging"

exec >>"${LOG}" 2>&1

log() { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; }

# auto_smb on this Mini is /System/Volumes/Data/MyWorks (not /Volumes).
# /MyWorks does not exist on the sealed root. /Volumes/MyWorks is Finder-only.
# Do not rewrite Data/MyWorks — that is the real autofs mount point.
short_vol() {
  local p="$1"
  case "$p" in
    /MyWorks) printf '%s\n' "/System/Volumes/Data/MyWorks" ;;
    /System/Volumes/Data/Volumes/*)
      printf '%s\n' "/Volumes/${p#/System/Volumes/Data/Volumes/}"
      ;;
    *) printf '%s\n' "$p" ;;
  esac
}

if [[ ! -f "${CONFIG}" ]]; then
  log "err       missing ${CONFIG}"
  exit 1
fi

SEESTAR_HOST="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("seestar_host",""))' "${CONFIG}")"
SEESTAR_SHARE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("seestar_share","MyWorks"))' "${CONFIG}")"
SEESTAR_VOL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("seestar_volume") or "/System/Volumes/Data/MyWorks")' "${CONFIG}")"
SEESTAR_METHOD="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("seestar_method") or "automount")' "${CONFIG}")"
QNAP_HOST="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["qnap_host"])' "${CONFIG}")"
QNAP_SHARE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["qnap_share"])' "${CONFIG}")"
QNAP_USER="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["qnap_user"])' "${CONFIG}")"
QNAP_VOL="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["qnap_volume"])' "${CONFIG}")"
NOTIFY="$(python3 -c 'import json,sys; print("yes" if json.load(open(sys.argv[1])).get("notify") else "no")' "${CONFIG}")"
SEESTAR_VOL="$(short_vol "${SEESTAR_VOL}")"
QNAP_VOL="$(short_vol "${QNAP_VOL}")"

if [[ "${1:-}" != "--force" ]] && [[ -f "${ROOT}/state/${STAMP}.json" ]]; then
  log "skip      already completed a haul today (${STAMP}); pass --force to run anyway"
  exit 0
fi

if [[ -f "${LOCK}" ]]; then
  old="$(cat "${LOCK}" 2>/dev/null || true)"
  if [[ -n "${old}" ]] && kill -0 "${old}" 2>/dev/null; then
    log "skip      another haul is running (pid ${old})"
    exit 0
  fi
fi
echo "$$" > "${LOCK}"
trap 'rm -f "${LOCK}"' EXIT

# Stay awake while we copy — Seestar Wi-Fi is slow.
caffeinate -i -w "$$" &
CAFF_PID=$!
trap 'rm -f "${LOCK}"; kill "${CAFF_PID}" 2>/dev/null || true' EXIT

log "dawnhaul  starting  (scheduled 8:30 AM)"

wait_for_network() {
  local i
  for i in $(seq 1 30); do
    if route -n get default >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# smbfs (already attached) or autofs map auto_smb (needs a list to attach).
# Imaging drops smbfs and leaves the autofs trigger at Data/MyWorks.
find_smbfs() {
  local share="$1"
  local want="$2"
  local line mp smbfs="" auto=""
  while IFS= read -r line; do
    mp="${line#* on }"
    mp="${mp%% (*}"
    if [[ -n "${want}" && "$mp" == "${want}" ]] || [[ "$mp" == */"$share" ]]; then
      case "$line" in
        *smbfs*) smbfs="$mp" ;;
        *autofs*) auto="$mp" ;;
      esac
    fi
  done < <(mount)
  if [[ -n "$smbfs" ]]; then
    printf '%s\n' "$smbfs"
    return 0
  fi
  if [[ -n "$auto" ]]; then
    printf '%s\n' "$auto"
    return 0
  fi
  return 1
}

share_live() {
  local vol="$1"
  [[ -n "${vol}" ]] || return 1
  python3 - "${vol}" 20 <<'LIVEPY'
import os, sys, signal
path, secs = sys.argv[1], int(sys.argv[2])
signal.signal(signal.SIGALRM, lambda s, f: sys.exit(2))
signal.alarm(secs)
try:
    os.listdir(path)
except PermissionError:
    sys.exit(3)
except Exception:
    sys.exit(1)
sys.exit(0)
LIVEPY
}

trigger_automount() {
  local tries="$1"
  local i rc path found seen_paths
  local -a cands
  cands=()
  seen_paths=$'\n'
  found="$(find_smbfs "${SEESTAR_SHARE}" "${SEESTAR_VOL}" || true)"
  for path in "${SEESTAR_VOL}" "${found}"; do
    [[ -n "${path}" ]] || continue
    case "${seen_paths}" in
      *$'\n'"${path}"$'\n'*) continue ;;
    esac
    seen_paths="${seen_paths}${path}"$'\n'
    cands+=("${path}")
  done
  for i in $(seq 1 "${tries}"); do
    for path in "${cands[@]}"; do
      log "seestar   trying ${path}  (try ${i}/${tries})"
      set +e
      share_live "${path}"
      rc=$?
      set -e
      if [[ "${rc}" -eq 0 ]]; then
        SEESTAR_VOL="${path}"
        log "seestar   ready  ${path}"
        return 0
      fi
      if [[ "${rc}" -eq 3 ]]; then
        log "warn      ${path} blocked by macOS privacy — grant Full Disk Access to Terminal (and /bin/bash for launchd)"
      elif [[ "${rc}" -eq 2 ]]; then
        log "seestar   timed out  ${path} (scope still down?)"
      fi
    done
    sleep 6
  done
  return 1
}

clear_stale() {
  local vol="$1" rc
  [[ -n "${vol}" ]] || return 0
  # Never unmount auto_smb / Data-volume maps.
  case "${vol}" in
    /System/Volumes/Data/MyWorks|/System/Volumes/Data/home) return 0 ;;
  esac
  if [[ "${vol}" == /System/Volumes/Data/* && "${vol}" != /System/Volumes/Data/Volumes/* ]]; then
    return 0
  fi
  set +e
  share_live "${vol}"
  rc=$?
  set -e
  # 3 = privacy blocked — the mount is probably real. Do not unmount it.
  if [[ "${rc}" -eq 3 ]]; then
    return 0
  fi
  if [[ -e "${vol}" && "${rc}" -ne 0 ]]; then
    log "mount     stale  ${vol} — forcing unmount"
    diskutil unmount force "${vol}" >/dev/null 2>&1 || umount -f "${vol}" >/dev/null 2>&1 || true
  fi
  if [[ "${vol}" == /Volumes/* && -d "${vol}" ]] && ! find_smbfs "$(basename "${vol}")" >/dev/null; then
    rmdir "${vol}" >/dev/null 2>&1 || true
  fi
}

MOUNT_PATH=""
WE_MOUNTED=0
mount_smb() {
  local url="$1"
  local share="$2"
  local tries="$3"
  local i j found
  WE_MOUNTED=0
  MOUNT_PATH=""
  found="$(find_smbfs "${share}" || true)"
  if [[ -n "${found}" ]] && share_live "${found}"; then
    log "mount     already up  ${found}  (smbfs)"
    MOUNT_PATH="${found}"
    return 0
  fi
  clear_stale "${found}"
  clear_stale "/Volumes/${share}"
  for i in $(seq 1 "${tries}"); do
    log "mount     ${url}  (try ${i}/${tries})"
    osascript -e "mount volume \"${url}\"" >/dev/null 2>&1 || true
    for j in $(seq 1 12); do
      found="$(find_smbfs "${share}" || true)"
      if [[ -n "${found}" ]] && share_live "${found}"; then
        log "mount     ready  ${found}"
        MOUNT_PATH="${found}"
        WE_MOUNTED=1
        return 0
      fi
      sleep 2
    done
    sleep 5
  done
  return 1
}

if ! wait_for_network; then
  log "err       no network"
  exit 1
fi

if command -v tailscale >/dev/null 2>&1; then
  if tailscale status >/dev/null 2>&1; then
    log "tailscale up"
  else
    log "warn      tailscale CLI present but not connected"
  fi
else
  log "network   tailscale CLI not on PATH (ok if the app is running)"
fi

SEESTAR_URL="smb://${SEESTAR_HOST}/${SEESTAR_SHARE}"
QNAP_URL="smb://${QNAP_USER}@${QNAP_HOST}/${QNAP_SHARE}"

SEESTAR_WE_MOUNTED=0
if [[ "${SEESTAR_METHOD}" == "automount" ]]; then
  log "seestar   automount  ${SEESTAR_VOL}"
  if trigger_automount 8; then
    :
  else
    log "warn      automount path not listable — falling back to Finder mount"
    if mount_smb "${SEESTAR_URL}" "${SEESTAR_SHARE}" 10; then
      SEESTAR_VOL="${MOUNT_PATH}"
      SEESTAR_WE_MOUNTED="${WE_MOUNTED}"
    else
      log "warn      Seestar did not mount — will still push anything already in staging"
      SEESTAR_VOL=""
    fi
  fi
else
  # Finder / Connect to Server
  if mount_smb "${SEESTAR_URL}" "${SEESTAR_SHARE}" 12; then
    SEESTAR_VOL="${MOUNT_PATH}"
    SEESTAR_WE_MOUNTED="${WE_MOUNTED}"
  else
    log "warn      Seestar did not mount — will still push anything already in staging"
    SEESTAR_VOL=""
  fi
fi

if ! mount_smb "${QNAP_URL}" "${QNAP_SHARE}" 10; then
  log "err       QNAP did not mount. Connect once in Finder, save the password to Keychain, then retry."
  if [[ "${NOTIFY}" == "yes" ]]; then
    osascript -e 'display notification "QNAP did not mount — open Finder and save the password." with title "Dawnhaul"' || true
  fi
  exit 2
fi
QNAP_VOL="${MOUNT_PATH}"

export DAWNHAUL_SEESTAR="${SEESTAR_VOL}"
export DAWNHAUL_QNAP="${QNAP_VOL}"

set +e
python3 "${ROOT}/bin/haul.py"
RC=$?
set -e

# Never unmount autofs. Only unmount a Finder share we mounted this run.
if [[ "${SEESTAR_METHOD}" != "automount" && "${SEESTAR_WE_MOUNTED}" -eq 1 && "${SEESTAR_VOL}" == /Volumes/* ]]; then
  diskutil unmount "${SEESTAR_VOL}" >/dev/null 2>&1 || umount "${SEESTAR_VOL}" >/dev/null 2>&1 || true
  log "unmount   ${SEESTAR_VOL}"
fi

if [[ "${RC}" -eq 0 ]]; then
  log "done      ok"
  if [[ "${NOTIFY}" == "yes" ]]; then
    osascript -e 'display notification "Files are on the NAS." with title "Dawnhaul"' || true
  fi
else
  log "done      exit ${RC}"
  if [[ "${NOTIFY}" == "yes" ]]; then
    osascript -e 'display notification "Haul finished with errors. Check ~/Dawnhaul/logs." with title "Dawnhaul"' || true
  fi
fi
exit "${RC}"

