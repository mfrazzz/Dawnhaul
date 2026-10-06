# AGENTS.md

Dawnhaul moves last night's Seestar astro captures from the Seestar (my Mac Mini's
automount) to a QNAP NAS. Entrypoint: `~/Dawnhaul/bin/haul.sh` (bash wrapper) →
`bin/haul.py` (copy engine). No build/test/lint; it's a personal macOS cron-style tool.

## Run it

- Manual run: `~/Dawnhaul/bin/haul.sh --force` (safe). `--force` skips the once-per-day
  guard in `state/YYYY-MM-DD.json`. Without it, the script exits 0 if that run already happened.
- **Manual runs echo to the terminal; launchd runs stay log-only.** `bin/haul.sh` only tees when
  `[[ -t 1 ]]`, so `logs/launchd.out.log` does not duplicate the (large) run log. Don't "simplify"
  this back to an unconditional `exec >>"${LOG}"` — a hand run then looks like a silent no-op, which
  is how a failed QNAP attach went unnoticed for hours.
- Scheduled by launchd: `~/Library/LaunchAgents/com.dawnhaul.sync.plist` (7:00 / 8:00 / 9:00).
  That plist lives OUTSIDE the repo (template: `com.dawnhaul.sync.plist.example`);
  logs go to `logs/launchd.{out,err}.log`.
- Logs: `logs/YYYY-MM-DD.log`. State/result JSON: `state/`.

## How mounts work (autofs, not Finder)

Both shares attach through the **auto_smb autofs map** (`/etc/auto_smb`), so the launchd job
never touches `/Volumes/*`. `/Volumes/*` smbfs mounts are blocked by macOS privacy for a
launchd-`/bin/bash` without Full Disk Access; `/System/Volumes/Data/*` autofs paths are not.
- Seestar: `/System/Volumes/Data/MyWorks` → `//Guest@10.0.0.1/EMMC Images/MyWorks`.
- QNAP: `/System/Volumes/Data/Pictures` → `//<qnap_user>:<pass>@<qnap_host>/Pictures`
  (password is URL-encoded inline — `%24` for `$`).
- **Critical:** `/etc/auto_smb` is a *direct map* (full-path keys). It is NOT
  auto-registered by automountd — `/etc/auto_master` must contain `/-  auto_smb`
  (append-only; SIP blocks bootout/kickstart -k of automountd, so reload with
  `sudo killall automountd` + `sudo launchctl kickstart system/com.apple.automountd`,
  then verify `mount | grep auto_smb`).
Listing a `/System/Volumes/Data/*` path makes automountd attach the share. Dawnhaul's
`attach_autofs()` just does that after a `nc -z` port-445 liveness check. **Never unmount**
any `/System/Volumes/Data/*` mount as part of normal operation, and never delete files on the
Seestar. (The one exception is the stale-orphan recovery below.)

### Stale orphan mounts — the EACCES trap

`EACCES` on a `/System/Volumes/Data/*` autofs path is **not** a TCC/Full-Disk-Access block and
is **not** fixed by reloading automountd. Check these in order:

1. **Stale mount (most common).** `mount` still lists the smbfs mount, but smbfs has no session
   behind it — the QNAP dropped the connection (`Server closed their side of the connection` in
   `log stream --predicate 'process == "kernel" AND senderImagePath CONTAINS "smb"'`) and left the
   mount entry behind. automountd can never mount over an occupied mountpoint, so the trigger
   never re-fires and every access returns `EACCES`. `sudo killall automountd` does **not** help:
   the orphan outlives automountd (the `automounted` flag is only a flag, not ownership).
   Confirm with `smbutil statshares -a` — the share is absent while `nc -z` port 445 still answers.
   Recover with `sudo umount /System/Volumes/Data/Pictures`; the next `ls` re-triggers a fresh
   attach. Nothing is at risk: with no session the share is unreachable anyway. This is the ONLY
   sanctioned exception to the never-unmount rule, and it must stay a manual, diagnosed step.
2. **Duplicate mount.** The same share is also mounted elsewhere, normally a Finder
   *Connect to Server* at `/Volumes/Pictures`. Finder mounts are made without `noowners`, so smbfs
   reuses that session's restrictive `0700` mode on the autofs trigger. Fix by `umount`ing the
   `/Volumes/*` duplicate (that one is never a protected trigger). Prevention: do not
   *Connect to Server* the QNAP `Pictures` share in Finder.
3. Otherwise it is the mount's own mode. The mount must be **owned by you**; the mode may be
   `0700` (QNAP `Pictures`) or `0777` (Seestar `MyWorks`) — both are fine. Never `chmod`.

`haul.sh::diagnose_eacces()` distinguishes these at runtime and prints the recovery command.
Do not reintroduce a blanket "grant Full Disk Access" message for `EACCES`: FDA is already granted
to `/bin/bash`, `/bin/zsh`, Terminal and iTerm2, so that hint sent debugging down the wrong path
for weeks.

## Hard invariants — do not break

- **Never unmount `/System/Volumes/Data/MyWorks` or `/System/Volumes/Data/Pictures`** as part of
  normal operation. Those are auto_smb autofs triggers. Dawnhaul only lists them to (re)attach; it
  never unmounts or unmounts-force anything. If you re-add mount/unmount logic, it must return
  early for `/System/Volumes/Data/*` paths. `short_vol()` must keep passing them through. The sole
  exception is the manual, diagnosed stale-orphan recovery documented above.
- **Copy file bytes only.** macOS `copyfile` pulls SMB extended attributes and fails with
  EPERM ("Operation not permitted"). `haul.py::copy_data` must keep using `shutil.copyfileobj`.
  "Operation not permitted" here is a macOS **privacy** block (fix: System Settings → Privacy
  & Security → Full Disk Access / network volumes for Terminal and /bin/bash), NOT a Unix
  permission bit — never "fix" it with chmod.
- **Never delete files on the Seestar.** Pull is copy-only; the Seestar is the source of truth.

## Duplicated logic that must stay in sync

The same normalization appears in both `bin/haul.sh` (bash `short_vol`) and `bin/haul.py`
(python `short_vol`): `/MyWorks` → `/System/Volumes/Data/MyWorks`, and
`/System/Volumes/Data/Volumes/X` → `/Volumes/X`. The once-per-day completion guard also lives
in bash (checks `state/${STAMP}.json`), while `haul.py` writes that file. If you change path
handling or the guard, change BOTH.

## Config

- `config.json` is the single source of truth: `seestar_*` (host 10.0.0.1, autofs path
  `/System/Volumes/Data/MyWorks`), `qnap_*` (<qnap_host>, user <qnap_user>, autofs path
  `/System/Volumes/Data/Pictures`), `staging`, `state_dir`, `mode`, `notify`,
  `keep_staging`, `nas_subdir` (target folder under the QNAP share).
- The QNAP password lives inline (URL-encoded) in `/etc/auto_smb`, not in `config.json`.
- `keep_staging: true` (default) leaves staging after a push. `false` (or `--prune`)
  deletes a staging file during push when the NAS copy already exists at the same size
  (a skip). Files copied this run stay until the next haul confirms them. Then empty
  dirs are dropped. Never deletes anything on the Seestar.
- `mode` selects the staging layout: `siril` (dirs ending `_sub` → `<obj>/lights/`,
  mosaic dirs → `<obj>/` with `lights/`), `science`, `keepers`, else `archive`.
- **README.md can drift from `config.json`** (e.g., it says NAS folder `AstroPeak`). The code
  reads `config.json` only — trust config.json + the scripts over README prose.

## Directory roles

- `bin/` — scripts (`haul.sh`, `haul.py`, `uninstall.sh`). The actual program.
- `staging/` — local buffer: files land here from the Seestar, then get pushed to the NAS.
  With `keep_staging: true` it is left in place. With `false` or `--prune`, verified NAS
  copies (same size) are removed from staging during the push.
- `state/` — per-day result JSON + `last-run.json`; also `haul.lock` (pid lockfile, temporary).
- `logs/` — dated run logs + `launchd.*`.
