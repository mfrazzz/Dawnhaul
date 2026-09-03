# AGENTS.md

Dawnhaul moves last night's Seestar astro captures from the Seestar (my Mac Mini's
automount) to a QNAP NAS. Entrypoint: `~/Dawnhaul/bin/haul.sh` (bash wrapper) →
`bin/haul.py` (copy engine). No build/test/lint; it's a personal macOS cron-style tool.

## Run it

- Manual run: `~/Dawnhaul/bin/haul.sh --force` (safe). `--force` skips the once-per-day
  guard in `state/YYYY-MM-DD.json`. Without it, the script exits 0 if that run already happened.
- Scheduled by launchd: `~/Library/LaunchAgents/com.dawnhaul.sync.plist` (8:30 / 9:30 / 10:30).
  That plist lives OUTSIDE the repo; logs go to `logs/launchd.{out,err}.log`.
- Logs: `logs/YYYY-MM-DD.log`. State/result JSON: `state/`.

## Hard invariants — do not break

- **Never unmount `/System/Volumes/Data/MyWorks`.** It's the auto_smb autofs trigger for
  the Seestar (`//Guest@10.0.0.1/EMMC Images/MyWorks`). Imaging drops the real smbfs and
  leaves this trigger; Dawnhaul just lists it to re-attach. `clear_stale()` in `haul.sh` and
  `short_vol()` deliberately return early for `/System/Volumes/Data/*` paths. Preserve this.
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

- `config.json` is the single source of truth: `seestar_*` (host 10.0.0.1, automount path),
  `qnap_*` (100.72.231.12, user mfrazier), `staging`, `state_dir`, `mode`, `notify`,
  `keep_staging`, `nas_subdir` (target folder under the QNAP Pictures share).
- `mode` selects the staging layout: `siril` (dirs ending `_sub` → `<obj>/lights/`,
  mosaic dirs → `<obj>/` with `lights/`), `science`, `keepers`, else `archive`.
- **README.txt can drift from `config.json`** (e.g., it says NAS folder `AstroPeak`). The code
  reads `config.json` only — trust config.json + the scripts over README prose.

## Directory roles

- `bin/` — scripts (`haul.sh`, `haul.py`, `uninstall.sh`). The actual program.
- `staging/` — local buffer: files land here from the Seestar, then get pushed to the NAS.
  Keep-staging is on; it is NOT cleared after a successful push.
- `state/` — per-day result JSON + `last-run.json`; also `haul.lock` (pid lockfile, temporary).
- `logs/` — dated run logs + `launchd.*`.
