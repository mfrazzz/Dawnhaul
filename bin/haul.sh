#!/bin/bash
# Dawnhaul — autofs-attach Seestar + QNAP, copy new files. Pull-only from Seestar.
# Safe to run by hand:  ~/Dawnhaul/bin/haul.sh
# Both shares attach through autofs (/etc/auto_smb) as /System/Volumes/Data/*
# because those paths are NOT blocked by macOS privacy for launchd, unlike /Volumes/*.
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

# Fast TCP reachability check (~3s max). Avoids long autofs hangs when a host is down.
port_up() {
  local host="$1" port="${2:-445}"
  nc -z -G 5 "${host}" "${port}" >/dev/null 2>&1
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

# Listing an autofs trigger path (e.g. /System/Volumes/Data/MyWorks) makes
# automountd attach the smbfs share defined in /etc/auto_smb. No Finder, no osascript.
attach_autofs() {
  local label="$1" vol="$2" tries="$3" host="$4"
  local i rc
  for i in $(seq 1 "${tries}"); do
    log "${label}   waiting for ${vol}  (try ${i}/${tries})"
    set +e
    share_live "${vol}"
    rc=$?
    set -e
    if [[ "${rc}" -eq 0 ]]; then
      log "${label}   ready  ${vol}"
      return 0
    fi
    if [[ "${rc}" -eq 3 ]]; then
      log "warn      ${vol} blocked by macOS privacy — grant Full Disk Access to Terminal (and /bin/bash for launchd)"
    elif [[ "${rc}" -eq 2 ]]; then
      log "${label}   timed out  ${host} (still down?)"
    fi
    sleep 4
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

# ---- Seestar (autofs) ----
if [[ "${SEESTAR_METHOD}" != "automount" ]]; then
  log "seestar   warning: seestar_method should be \"automount\" for autofs; using ${SEESTAR_METHOD}"
fi
if ! port_up "${SEESTAR_HOST}" 445; then
  log "warn      Seestar unreachable on port 445 (${SEESTAR_HOST}) — will push staging only"
  SEESTAR_VOL=""
else
  if ! attach_autofs "seestar" "${SEESTAR_VOL}" 8 "${SEESTAR_HOST}"; then
    log "warn      Seestar autofs path not attachable — will push staging only"
    SEESTAR_VOL=""
  fi
fi

# ---- QNAP (autofs) ----
if ! port_up "${QNAP_HOST}" 445; then
  log "err       QNAP unreachable on port 445 (${QNAP_HOST})"
  if [[ "${NOTIFY}" == "yes" ]]; then
    osascript -e 'display notification "QNAP unreachable — check power/VPN." with title "Dawnhaul"' || true
  fi
  exit 2
fi
if ! attach_autofs "qnap" "${QNAP_VOL}" 8 "${QNAP_HOST}"; then
  log "err       QNAP autofs path not attachable (${QNAP_VOL})"
  if [[ "${NOTIFY}" == "yes" ]]; then
    osascript -e 'display notification "QNAP mount failed — check /etc/auto_smb." with title "Dawnhaul"' || true
  fi
  exit 2
fi

export DAWNHAUL_SEESTAR="${SEESTAR_VOL}"
export DAWNHAUL_QNAP="${QNAP_VOL}"

set +e
python3 "${ROOT}/bin/haul.py"
RC=$?
set -e

# autofs mounts under /System/Volumes/Data are never unmounted here.

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