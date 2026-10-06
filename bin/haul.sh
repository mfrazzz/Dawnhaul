#!/bin/bash
# Dawnhaul — autofs-attach Seestar + QNAP, copy new files. Pull-only from Seestar.
# Safe to run by hand:  ~/Dawnhaul/bin/haul.sh
# Both shares attach through autofs (/etc/auto_smb) as /System/Volumes/Data/*
# because those paths are NOT blocked by macOS privacy for launchd, unlike /Volumes/*.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${ROOT}/config.json"
LOG_DIR="${ROOT}/logs"
STAMP="$(date +%Y-%m-%d)"
LOG="${LOG_DIR}/${STAMP}.log"
LOCK="${ROOT}/state/haul.lock"
mkdir -p "${LOG_DIR}" "${ROOT}/state" "${ROOT}/staging"

# launchd runs have no terminal: keep them log-only so launchd.out.log does not
# duplicate the (large) run log. Hand runs echo to the terminal as well.
if [[ -t 1 ]]; then
  exec > >(tee -a "${LOG}") 2>&1
else
  exec >>"${LOG}" 2>&1
fi

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

FORCE=0
PRUNE=0
for arg in "$@"; do
  case "${arg}" in
    --force) FORCE=1 ;;
    --prune) PRUNE=1 ;;
    *)
      log "err       unknown argument: ${arg}  (use --force and/or --prune)"
      exit 1
      ;;
  esac
done

if [[ "${FORCE}" -eq 0 && "${PRUNE}" -eq 0 ]] && [[ -f "${ROOT}/state/${STAMP}.json" ]]; then
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

log "dawnhaul  starting"

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

# Prints every mountpoint holding the same SMB share as ${vol}, one per line.
# A second mount of the same share (normally a stale Finder mount under
# /Volumes) makes smbfs reuse that session's mount mode. Finder mounts are made
# without noowners, so the autofs trigger can come up root-owned 0700 and deny
# the user with EACCES — reloading automountd does NOT clear that.
duplicate_mounts() {
  local vol="$1" src
  src="$(mount | awk -v p="${vol}" '$3 == p && $1 ~ /^\/\// {print $1; exit}')"
  [[ -n "${src}" ]] || return 1
  mount | awk -v s="${src}" '$1 == s {print $3}'
}

# Succeeds when smbfs still holds a live session for the share mounted at
# ${vol}. Matches on the share component of the mount source against the share
# names smbutil reports, so it does not depend on how config spells host/share.
smb_session() {
  local vol="$1"
  python3 - "${vol}" <<'SESSPY'
import subprocess, sys, urllib.parse
vol = sys.argv[1]
src = ""
for line in subprocess.run(["mount"], capture_output=True, text=True).stdout.splitlines():
    f = line.split()
    if len(f) >= 3 and f[0].startswith("//") and f[2] == vol:
        src = f[0]
        break
if not src:
    sys.exit(1)
rest = src[2:]
if "@" in rest:
    rest = rest.split("@", 1)[1]
path = rest.split("/", 1)[1] if "/" in rest else ""
want = urllib.parse.unquote(path.split("/", 1)[0]).lower()
out = subprocess.run(["smbutil", "statshares", "-a"], capture_output=True, text=True).stdout
sys.exit(0 if any(l.strip().lower() == want for l in out.splitlines()) else 1)
SESSPY
}

# EACCES on an autofs smbfs path is NOT a TCC/Full-Disk-Access problem. Name the
# real cause instead. Two seen in practice:
#   1. stale mount - the mountpoint is still mounted but its SMB session is
#      gone. automountd can never mount over an occupied mountpoint, so the
#      trigger never re-fires and every access is EACCES. Reloading automountd
#      does NOT help: the orphan mount outlives automountd.
#   2. duplicate mount - the same share is also mounted elsewhere (usually a
#      Finder /Volumes mount made without noowners), so smbfs reuses that
#      session's restrictive 0700 mount mode.
# Never chmod: this is a mount/session problem, not Unix permissions.
diagnose_eacces() {
  local vol="$1" dups
  if mount | grep -qF " on ${vol} (" && ! smb_session "${vol}"; then
    log "warn      ${vol} EACCES — STALE MOUNT: still mounted, but smbfs has no session for it"
    log "warn      automountd cannot mount over an occupied mountpoint; attempting auto-recovery"
    if sudo -n /sbin/umount "${vol}" 2>/dev/null; then
      log "info      auto-recovered: unmounted stale ${vol} (re-attach will occur on next trigger)"
      return 0
    else
      log "warn      failed to auto-unmount ${vol}; clear manually: sudo umount ${vol}"
    fi
    return 0
  fi
  dups="$(duplicate_mounts "${vol}" | grep -vx "${vol}" || true)"
  if [[ -n "${dups}" ]]; then
    log "warn      ${vol} EACCES — same SMB share is also mounted at: $(printf '%s ' ${dups})"
    log "warn      duplicate mount sets the mount mode; clear it with: umount ${dups%% *}"
    return 0
  fi
  log "warn      ${vol} EACCES — mount mode, not a TCC block (Full Disk Access is already granted)"
  log "warn      inspect with: ls -ld ${vol}   (the mount must be owned by you; mode may be 0700 or 0777)"
}

# Listing an autofs trigger path (e.g. /System/Volumes/Data/MyWorks) makes
# automountd attach the smbfs share defined in /etc/auto_smb. No Finder, no osascript.
attach_autofs() {
  local label="$1" vol="$2" tries="$3" host="$4"
  local i rc explained=0
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
      # Explain once per share; repeating it on every retry buries the log.
      if [[ "${explained}" -eq 0 ]]; then
        diagnose_eacces "${vol}"
        explained=1
      fi
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
  log "hint      see the EACCES warnings above; do NOT chmod (this is a mount-mode issue, not Unix permissions)"
  if [[ "${NOTIFY}" == "yes" ]]; then
    osascript -e 'display notification "QNAP mount failed — check /etc/auto_smb." with title "Dawnhaul"' || true
  fi
  exit 2
fi

export DAWNHAUL_SEESTAR="${SEESTAR_VOL}"
export DAWNHAUL_QNAP="${QNAP_VOL}"

set +e
if [[ "${PRUNE}" -eq 1 ]]; then
  python3 "${ROOT}/bin/haul.py" --prune
else
  python3 "${ROOT}/bin/haul.py"
fi
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