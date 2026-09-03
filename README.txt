Dawnhaul
========

Moves last night's Seestar captures from MyWorks to your QNAP Pictures share
without sitting in Finder.

Your kit
--------
  Seestar     automount /System/Volumes/Data/MyWorks
  QNAP        smb://100.72.231.12/Pictures  (user mfrazier)
  NAS folder  Pictures/AstroPeak
  Mode        siril
  Schedule    8:30 AM plus two catch-up hours

Install on the Mac Mini
-----------------------
1. On the Mini (AnyDesk / Chrome Remote Desktop is fine), open Terminal.
2. Paste the installer you copied from Dawnhaul, then press Return.
3. ONE TIME: in Finder choose Go → Connect to Server
     smb://100.72.231.12/Pictures
   Sign in as mfrazier, tick
   "Remember this password in my keychain".
4. Seestar is auto_smb at /System/Volumes/Data/MyWorks. Confirm with: ls "/System/Volumes/Data/MyWorks". Dawnhaul lists that path so autofs remounts after imaging. It will not unmount it.
5. Keep the Mini from sleeping, or wake it before the job:
     System Settings → Energy → Prevent automatic sleeping
   Optional wake:
     sudo pmset repeat wakeorpoweron MTWRFSU 08:20:00
6. Leave Tailscale running. Leave the Seestar in station mode on the same
   Wi-Fi as the Mini until the haul finishes — or run it by hand before
   you power the Seestar down:
     ~/Dawnhaul/bin/haul.sh --force

What it does
------------
  • Lists /System/Volumes/Data/MyWorks so auto_smb remounts smbfs (//Guest@10.0.0.1/EMMC Images/MyWorks). Never unmounts that map.
  • Mounts the QNAP share via Connect to Server (password in Keychain).
  • Pulls new files into ~/Dawnhaul/staging first, then pushes that folder
    to the NAS. If Tailscale blips, the night is still on the Mini.
  • Never deletes files on the Seestar.
  • Skips files that already exist at the same size (incremental).
  • Writes a log to ~/Dawnhaul/logs/YYYY-MM-DD.log
  • Shows a macOS notification when it finishes.

If the Seestar is off at 8:30 AM, Dawnhaul still pushes anything already
in staging. Run haul.sh --force after a session if you power the scope down.

The Seestar drops smbfs while imaging; map auto_smb stays at
/System/Volumes/Data/MyWorks. The morning job lists that path so autofs
reattaches //Guest@10.0.0.1/EMMC Images/MyWorks. Catch-up
hours cover a late reappearance. Dawnhaul never unmounts auto_smb.

If launchd cannot list the Data path (Operation not permitted) but
Terminal can, grant Full Disk Access to Terminal and to /bin/bash.

Confirm:

  ls /System/Volumes/Data/MyWorks
  ls /Volumes/Pictures
  mount | grep -i myworks

"Operation not permitted" on copy
---------------------------------
That is not a Unix permission bit. macOS copyfile tries to bring SMB
extended attributes onto the local disk and gets EPERM. Current haul.py
copies file bytes only. Re-run the installer (safe) or replace
~/Dawnhaul/bin/haul.py and haul.sh from the kit, then:

  ~/Dawnhaul/bin/haul.sh --force

If it still fails, System Settings → Privacy & Security → Full Disk Access
(and Files and Folders / network volumes) for Terminal.

Uninstall
---------
  ~/Dawnhaul/bin/uninstall.sh

