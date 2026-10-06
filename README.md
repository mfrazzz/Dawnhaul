# Dawnhaul

Dawnhual (original code came from Grok AI, and then updated and
enhanced using OpenCode AI with Grok and Big Pickle LLMs) was my solution
to having a Seestar and Mac Mini hosted at a remote location 
(AstroPeak Remote Observatory in my case) and automating moving the
previous night's Seestar fits files to a NAS located on my local LAN.

Pull-only from the Seestar: the scope is the source of truth and Dawnhaul
never deletes or moves files on it. Captures are copied into a staging 
folder on the Mac first, then pushed to the NAS. If the NAS is briefly
unreachable, the night's data is already safe on the Mac.

## How it works

Both shares attach through macOS **autofs** — no Finder, no `mount` calls,
no Full Disk Access guessing. The magic is two config files:

1. `/etc/auto_smb` defines the shares as **direct-map** entries with full
   paths (this is what makes autofs attach them on demand).
2. `/etc/auto_master` must explicitly register `auto_smb` as a direct map
   with the line `/- auto_smb`. **Without this line nothing happens on
   modern macOS** — the map is not auto-registered.

The launchd job lists `/System/Volumes/Data/*` paths; simply listing an
autofs trigger path makes `automountd` attach the SMB share. These `Data`
paths are *not* blocked by macOS privacy for a non-elevated launchd job
(unlike `/Volumes/*`), so no Full Disk Access is required.

## What you need

- A Mac (any Apple Silicon or Intel based); used with macOS 26, autofs behavior unchanged
  on older versions)
- A Seestar S50/S30 on the same Wi-Fi as the Mac (its SMB share `EMMC Images`
  contains a `MyWorks` folder; roughly `//Guest@SEESTAR_IP/EMMC%20Images/MyWorks`)
- A NAS running SMB (mine is QNAP) with a target share that accepts user/password auth
- Python installed on the Mac (easiest to do this with Homebrew)
- Grant Full Disk Access to /bin/bash, Terminal, iTerm2, or whatever default terminal
  program you use.
- A network connection between the Mac and the NAS (I use Tailscale).

## Install

The repo is plain bash + one Python file; there is **no installer**. Copy it
to `~/Dawnhaul` and step through below.

### 1. Clone and configure

```sh
git clone https://github.com/mfrazzz/Dawnhaul.git ~/Dawnhaul
cd ~/Dawnhaul
cp config.example.json config.json
# edit config.json: set seestar_host, qnap_host, qnap_user, nas_subdir
```

- `seestar_volume` = autofs path of the Seestar share. Default
  `/System/Volumes/Data/MyWorks`.
- `qnap_volume` = autofs path of the NAS share. Default
  `/System/Volumes/Data/Pictures`.
- `mode` selects the staging layout, see [Modes](#modes).
- `keep_staging` controls whether verified NAS copies are removed from
  staging, see [Staging](#staging).
- `staging` / `state_dir` default to `~/Dawnhaul/staging`, `~/Dawnhaul/state`.

### 2. Configure autofs

Create `/etc/auto_smb` (root-owned). Two lines, URL-encoded credentials:

```
/System/Volumes/Data/MyWorks  -fstype=smbfs,soft,noowners,nosuid  ://Guest@SEESTAR_IP/EMMC%20Images/MyWorks
/System/Volumes/Data/Pictures -fstype=smbfs,soft,noowners,nosuid  ://QNAP_USER:URLENCODED_PASS@QNAP_IP/Pictures
```

- Spaces in share names → `%20`. Password characters like `$` → `%24`.
- Keep the QNAP password here only; do not put it in `config.json`.

Then register the map in `/etc/auto_master` by **appending**:

```
/-    auto_smb
```

(On SIP-enabled systems you can append to `auto_master`, though you cannot
`bootout`/`launchctl kickstart -k` the daemon — that is blocked. Use the
reload sequence below instead.)

Reload automount:

```sh
sudo killall automountd; sleep 2; sudo launchctl kickstart system/com.apple.automountd
# then confirm the map actually registered:
mount | grep auto_smb   # expect: map auto_smb on /System/Volumes/Data/MyWorks ...
sudo automount -vc      # prints "auto_smb ... mounted" when registered
```

Verify the shares now react to being listed:

```sh
ls /System/Volumes/Data/MyWorks/    # Seestar captures appear
ls /System/Volumes/Data/Pictures/   # NAS share appears
```

If the `mount | grep auto_smb` line is missing, the earlier stale-design
`/etc/auto_smb` map was never being served — the `/- auto_smb` line in
`/etc/auto_master` is the required piece.

### 3. Run it once by hand

```sh
cd ~/Dawnhaul
bin/haul.sh --force
```

`--force` ignores the once-per-day guard so you can test repeatedly.
`--prune` deletes staging files that already exist on the NAS at the same
size (same as `keep_staging: false` for one run). Combine them:

```sh
bin/haul.sh --force --prune
```

Watch `logs/YYYY-MM-DD.log` and a macOS notification on completion.

### 4. Schedule it

Fix `/PATH/TO` in the included `com.dawnhaul.sync.plist.example`, then:

```sh
cp com.dawnhaul.sync.plist.example ~/Library/LaunchAgents/com.dawnhaul.sync.plist
launchctl unload ~/Library/LaunchAgents/com.dawnhaul.sync.plist 2>/dev/null || true
launchctl load ~/Library/LaunchAgents/com.dawnhaul.sync.plist
launchctl list | grep dawnhaul   # confirm registered
```

Default schedule: 7:00, 8:00, 9:00 (three tries so it catches the Seestar
whenever it wakes). Edit the plist `StartCalendarInterval` entries to change.

### 5. Keep the Mac awake (optional but recommended)

```sh
sudo pmset repeat wakeorpoweron MTWRFSU 06:50:00
```

Leave Tailscale running if the NAS is only reachable over Tailscale (as in
the original setup: the QNAP was at a Tailscale IP).

## Modes

`mode` in `config.json` selects the staging layout during the pull:

| mode      | Seestar folders → staging layout                                  |
|-----------|-------------------------------------------------------------------|
| `siril`   | `<obj>_sub/` → `<obj>/lights/`; mosaic `<obj>/` → `<obj>/lights/`  |
| `science` | flat copy preserving relative paths under staging                 |
| `keepers` | each top-level dir → staging/<dir>, keeps FIT/JPG/MOV             |
| else      | `archive`: flat copy preserving relative paths under staging      |

## Staging

Captures land in `staging/` first, then get pushed to the NAS. That buffer
is what makes a Tailscale blip safe.

| setting / flag | what happens |
|----------------|--------------|
| `keep_staging: true` (default) | staging is left in place after a push |
| `keep_staging: false` | during push, a staging file is deleted only if the NAS copy already exists at the **same size** (a skip) |
| `bin/haul.sh --prune` | same as `keep_staging: false`, for one run, without changing config |

Files **copied this run** stay in staging until the next haul confirms them
on the NAS. Empty directories are dropped after a prune. Nothing on the
Seestar is ever deleted.

`--prune` also bypasses the once-per-day guard, so you can prune later the
same day without `--force`.

## What it never does

- **Never unmounts** `/System/Volumes/Data/MyWorks` or
  `/System/Volumes/Data/Pictures`. They are autofs triggers; the script only
  lists them. (The one manual exception is a stale orphan mount — see
  Troubleshooting below.)
- **Never deletes files on the Seestar.**
- **Never copies SMB extended attributes.** `haul.py` copies file bytes only
  (`shutil.copyfileobj`), because macOS `copyfile(COPYFILE_ALL)` pulls SMB
  xattrs and fails with EPERM.

## Troubleshooting

### "Permission denied" on `/System/Volumes/Data/Pictures` (EACCES)

This is **not** a Full Disk Access problem and **not** something `chmod` can fix
— Full Disk Access is already granted to `/bin/bash`, `/bin/zsh`, Terminal and
iTerm2. `haul.sh` names the actual cause in the log. Work through it in this
order:

1. **Stale orphan mount (most common).** `mount` still lists the smbfs mount,
   but smbfs has no session behind it: the QNAP dropped the connection and left
   the mount entry behind. automountd can never mount over an occupied
   mountpoint, so the trigger never re-fires and every access returns `EACCES`.
   Reloading automountd does **not** help — the orphan outlives automountd.

   Confirm and clear it:

   ```sh
   smbutil statshares -a     # Pictures is ABSENT while mount lists it
   nc -z <qnap_host> 445      # still answers, so the NAS is up
   sudo umount /System/Volumes/Data/Pictures
   ls /System/Volumes/Data/Pictures    # re-triggers a fresh attach
   ```

   Nothing is at risk: with no session the share is unreachable anyway. This is
   the only sanctioned exception to the never-unmount rule, and it is a manual,
   diagnosed step — Dawnhaul never does it itself.
2. **Duplicate mount.** The same share is also mounted elsewhere, usually a
   Finder *Connect to Server* at `/Volumes/Pictures`. Finder mounts are made
   without `noowners`, so smbfs reuses that session's restrictive `0700` mount
   mode on the autofs trigger. Fix by `umount`ing the `/Volumes/*` duplicate.
   Prevention: do not *Connect to Server* the QNAP `Pictures` share in Finder.
3. Otherwise it is the mount's own mode. The mount must be owned by you; the
   mode may be `0700` (`Pictures`) or `0777` (`MyWorks`) — both are fine.

### "Operation not permitted" during copy
That is a macOS **privacy** block, not a Unix permission bit. It usually means
Terminal (or `/bin/bash` for launchd) lacks Full Disk Access / network-volume
access: System Settings → Privacy & Security → Full Disk Access → add
Terminal (and `/bin/bash`). Do **not** try to fix it with `chmod`.

The autofs `Data` paths above normally avoid this entirely.

### "/System/Volumes/Data/Pictures: No such file or directory"
The `auto_smb` map never registered. Confirm `/- auto_smb` is appended to
`/etc/auto_master` and that `mount | grep auto_smb` shows the triggers, then
re-run the killall/kickstart sequence.

### Nothing happens at the scheduled time
- Check `logs/launchd.err.log` and `logs/launchd.out.log`.
- Confirm the job loaded: `launchctl list | grep dawnhaul`.
- Check the plist `ProgramArguments` path actually exists.
- A manual run now echoes to the terminal, so `bin/haul.sh --force` failing is
  visible immediately; the log is still the source of truth.

### QNAP unreachable (exit 2)
`port_up` probes TCP 445 on `qnap_host`. If the NAS only answers over
Tailscale, make sure the app/CLI is up before the job (or add an earlier
StartCalendarInterval entry).

### Autofs path not attachable
If the log says `STALE MOUNT`, the automountd reload below will not help — use
the stale-orphan procedure at the top of this section instead. Reloading is
only useful right after an OS upgrade, to re-register the map:

```sh
sudo killall automountd; sleep 2; sudo launchctl kickstart system/com.apple.automountd
mount | grep auto_smb
ls /System/Volumes/Data/Pictures
```

Do **not** fall back to `/Volumes/Pictures` — that path is blocked for
launchd, and leaving a Finder mount of `Pictures` there poisons the autofs
mount's mode.

### "Input/output error" during copy / rename
Transient SMB glitch (common over Tailscale). Dawnhaul writes bytes to a
`.dawnhaul` temp file, fsyncs, then renames. Rename retries a few times on
EIO; if the NAS file already matches size, it counts as success. Failed
files stay in staging and retry on the next `--force`.

## Project layout

```
bin/haul.sh               bash wrapper: guard, lock, autofs attach; --force / --prune
bin/haul.py               copy engine: pull → staging → push, prune, modes, state
bin/uninstall.sh          removes the launch agent
config.example.json       template; copy to config.json and edit
com.dawnhaul.sync.plist.example  launchd template; fix paths before install
```

## Uninstall

```sh
~/Dawnhaul/bin/uninstall.sh
```

That removes the launch agent only; logs/staging are left behind. Delete the
whole thing with `rm -rf ~/Dawnhaul`.
