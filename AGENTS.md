# AGENTS.md

Dawnhaul moves last night's Seestar astro captures from the Seestar (my Mac Mini's
automount) to a QNAP NAS. Entrypoint: `~/Dawnhaul/bin/haul.sh` (bash wrapper) →
`bin/haul.py` (copy engine). No build/test/lint; it's a personal macOS cron-style tool.

## Run it

- Manual run: `~/Dawnhaul/bin/haul.sh --force` (safe). `--force` skips the once-per-day
  guard in `state/YYYY-MM-DD.json`. Without it, the script exits 0 if that run already happened.
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
any `/System/Volumes/Data/*` mount and never delete files on the Seestar.

## Hard invariants — do not break

- **Never unmount `/System/Volumes/Data/MyWorks` or `/System/Volumes/Data/Pictures`.**
  Those are auto_smb autofs triggers. Dawnhaul only lists them to (re)attach; it never
  unmounts or unmounts-force anything. If you re-add mount/unmount logic, it must return
  early for `/System/Volumes/Data/*` paths. `short_vol()` must keep passing them through.
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
- `mode` selects the staging layout: `siril` (dirs ending `_sub` → `<obj>/lights/`,
  mosaic dirs → `<obj>/` with `lights/`), `science`, `keepers`, else `archive`.
- **README.md can drift from `config.json`** (e.g., it says NAS folder `AstroPeak`). The code
  reads `config.json` only — trust config.json + the scripts over README prose.

## Directory roles

- `bin/` — scripts (`haul.sh`, `haul.py`, `uninstall.sh`). The actual program.
- `staging/` — local buffer: files land here from the Seestar, then get pushed to the NAS.
  Keep-staging is on; it is NOT cleared after a successful push.
- `state/` — per-day result JSON + `last-run.json`; also `haul.lock` (pid lockfile, temporary).
- `logs/` — dated run logs + `launchd.*`.
