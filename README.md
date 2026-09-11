# Dawnhaul

Moves last night's Seestar astro captures from the Seestar to a NAS,
without Finder and without anyone sitting at the Mac.

Pull-only from the Seestar: the scope is the source of truth and Dawnhaul
never deletes or moves files on it. Captures are copied into a local
staging folder first, then pushed to the NAS. If the NAS is briefly
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

- A Mac (any Intel/Apple Silicon; used with macOS 26, autofs meat unchanged
  on older versions)
- A Seestar S50/S30 on the same Wi-Fi as the Mac (its SMB share `EMMC Images`
  contains a `MyWorks` folder; roughly `//Guest@SEESTAR_IP/EMMC%20Images/MyWorks`)
- A QNAP (or any SMB NAS) with a target share that accepts user/password auth

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
- `staging` / `state_dir` default to `~/Dawnhaul/staging`, `~/Dawnhaul/state`.

### 2. Configure autofs (this is the whole trick)

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

`--force` ignores the once-per-day guard so you can test repeatedly. Watch
`logs/YYYY-MM-DD.log` and a macOS notification on completion.

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

`keep_staging: true` keeps the staging folder after a success so a NAS
glitch never loses a night; run again (`--force`) to retry the push.

## What it never does

- **Never unmounts** `/System/Volumes/Data/MyWorks` or
  `/System/Volumes/Data/Pictures`. They are autofs triggers; the script only
  lists them.
- **Never deletes files on the Seestar.**
- **Never copies SMB extended attributes.** `haul.py` copies file bytes only
  (`shutil.copyfileobj`), because macOS `copyfile(COPYFILE_ALL)` pulls SMB
  xattrs and fails with EPERM.

## Troubleshooting

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

### QNAP unreachable (exit 2)
`port_up` probes TCP 445 on `qnap_host`. If the NAS only answers over
Tailscale, make sure the app/CLI is up before the job (or add an earlier
StartCalendarInterval entry).

## Project layout

```
bin/haul.sh               bash wrapper: guard, lock, port checks, autofs attach
bin/haul.py               copy engine: pull → staging → push, modes, state
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