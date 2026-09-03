#!/usr/bin/env python3
"""Dawnhaul transfer engine.

Copies new files from a mounted Seestar MyWorks share into local staging,
then from staging onto the QNAP share. Never deletes anything on the Seestar.
"""
from __future__ import annotations

import json
import os
import shutil
import sys
import time
from pathlib import Path

FIT = {".fit", ".fits"}
JPG = {".jpg", ".jpeg"}
MOV = {".mp4", ".mov", ".avi"}
SKIP_NAMES = {".ds_store", "thumbs.db"}

MODE = "siril"


def log(msg: str) -> None:
    ts = time.strftime("%H:%M:%S")
    print(f"{ts}  {msg}", flush=True)


def skip_name(name: str) -> bool:
    lower = name.lower()
    if lower in SKIP_NAMES or name.startswith("._") or name.startswith("."):
        return True
    if lower.endswith("_thn.jpg") or lower.endswith("_thn.jpeg"):
        return True
    return False


def short_vol(path: str) -> str:
    if path == "/MyWorks":
        return "/System/Volumes/Data/MyWorks"
    prefix = "/System/Volumes/Data/Volumes/"
    if path.startswith(prefix):
        return "/Volumes/" + path[len(prefix):]
    return path


def load_config() -> dict:
    here = Path(__file__).resolve().parent.parent
    path = here / "config.json"
    if not path.exists():
        sys.exit(f"missing config: {path}")
    return json.loads(path.read_text())


def copy_data(src: Path, dst_tmp: Path) -> None:
    """Copy bytes only. macOS copyfile(COPYFILE_ALL) pulls SMB xattrs/flags
    and fails with EPERM (Operation not permitted).
    """
    dst_tmp.parent.mkdir(parents=True, exist_ok=True)
    with open(src, "rb") as fsrc, open(dst_tmp, "wb") as fdst:
        shutil.copyfileobj(fsrc, fdst, length=1024 * 1024)
    try:
        st = src.stat()
        os.utime(dst_tmp, (st.st_atime, st.st_mtime))
    except OSError:
        pass


def copy_if_new(src: Path, dst: Path, stats: dict) -> None:
    if skip_name(src.name) or not src.is_file():
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    try:
        size = src.stat().st_size
    except OSError as exc:
        stats["errors"] += 1
        log(f"err       cannot stat {src}: {exc}")
        return
    if dst.exists():
        try:
            if dst.stat().st_size == size:
                stats["skipped"] += 1
                return
        except OSError:
            pass
    tmp = dst.parent / (dst.name + ".dawnhaul")
    try:
        copy_data(src, tmp)
        tmp.replace(dst)
    except OSError as exc:
        stats["errors"] += 1
        log(f"err       copy failed {src.name}: {exc}")
        if stats["errors"] == 1 and getattr(exc, "errno", None) == 1:
            log("hint      Operation not permitted is usually macOS blocking SMB metadata, or Terminal lacking Full Disk Access / network-volume access in Privacy & Security.")
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass
        return
    stats["copied"] += 1
    stats["bytes"] += size
    log(f"copy      {src.parent.name}/{dst.name}  ({size} bytes)")


def iter_files(root: Path):
    if not root.exists():
        return
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        for name in filenames:
            if skip_name(name):
                continue
            yield Path(dirpath) / name


def is_fit(path: Path) -> bool:
    return path.suffix.lower() in FIT


def is_jpg(path: Path) -> bool:
    return path.suffix.lower() in JPG


def is_mov(path: Path) -> bool:
    return path.suffix.lower() in MOV


def object_name(folder: str) -> str:
    return folder[:-4] if folder.endswith("_sub") else folder


def pull_siril(src_root: Path, staging: Path, stats: dict) -> None:
    for child in sorted(src_root.iterdir() if src_root.exists() else []):
        if not child.is_dir() or child.name.startswith("."):
            continue
        name = child.name
        obj = object_name(name)
        if name.endswith("_sub"):
            dest_dir = staging / obj / "lights"
            for f in iter_files(child):
                if is_fit(f):
                    copy_if_new(f, dest_dir / f.name, stats)
        else:
            dest_root = staging / obj
            dest_root.mkdir(parents=True, exist_ok=True)
            (dest_root / "lights").mkdir(exist_ok=True)
            for f in child.iterdir():
                if f.is_file() and is_fit(f):
                    copy_if_new(f, dest_root / f.name, stats)


def pull_science(src_root: Path, staging: Path, stats: dict) -> None:
    for f in iter_files(src_root):
        if is_fit(f):
            rel = f.relative_to(src_root)
            copy_if_new(f, staging / rel, stats)


def pull_archive(src_root: Path, staging: Path, stats: dict) -> None:
    for f in iter_files(src_root):
        rel = f.relative_to(src_root)
        copy_if_new(f, staging / rel, stats)


def pull_keepers(src_root: Path, staging: Path, stats: dict) -> None:
    for child in sorted(src_root.iterdir() if src_root.exists() else []):
        if not child.is_dir() or child.name.startswith(".") or child.name.endswith("_sub"):
            continue
        dest = staging / child.name
        for f in child.iterdir():
            if not f.is_file():
                continue
            if is_fit(f) or is_jpg(f) or is_mov(f):
                copy_if_new(f, dest / f.name, stats)


def push_staging(staging: Path, nas: Path, stats: dict) -> None:
    if not staging.exists():
        return
    for f in iter_files(staging):
        rel = f.relative_to(staging)
        copy_if_new(f, nas / rel, stats)


def main() -> int:
    cfg = load_config()
    seestar_raw = short_vol(
        (os.environ.get("DAWNHAUL_SEESTAR") or cfg.get("seestar_volume") or "").strip()
    )
    seestar = Path(seestar_raw) if seestar_raw else Path("/var/empty/dawnhaul-no-seestar")
    staging = Path(os.path.expanduser(cfg["staging"]))
    qnap_vol = Path(short_vol(os.environ.get("DAWNHAUL_QNAP") or cfg["qnap_volume"]))
    nas_root = qnap_vol / cfg["nas_subdir"]
    mode = cfg.get("mode", MODE)

    staging.mkdir(parents=True, exist_ok=True)
    stats = {"copied": 0, "skipped": 0, "errors": 0, "bytes": 0}

    log(f"mode      {mode}")
    if seestar.exists():
        log(f"pull      {seestar} → {staging}")
        if mode == "siril":
            pull_siril(seestar, staging, stats)
        elif mode == "science":
            pull_science(seestar, staging, stats)
        elif mode == "keepers":
            pull_keepers(seestar, staging, stats)
        else:
            pull_archive(seestar, staging, stats)
        log(
            f"pull      copied {stats['copied']}, skipped {stats['skipped']}, "
            f"errors {stats['errors']}"
        )
    else:
        log(f"warn      Seestar volume not mounted at {seestar} — push staging only")

    push_stats = {"copied": 0, "skipped": 0, "errors": 0, "bytes": 0}
    if not nas_root.parent.exists():
        log(f"err       QNAP volume not mounted at {qnap_vol}")
        return 2
    nas_root.mkdir(parents=True, exist_ok=True)
    log(f"push      {staging} → {nas_root}")
    push_staging(staging, nas_root, push_stats)
    log(
        f"push      copied {push_stats['copied']}, skipped {push_stats['skipped']}, "
        f"errors {push_stats['errors']}"
    )

    result = {
        "pulled": stats,
        "pushed": push_stats,
        "mode": mode,
        "ok": stats["errors"] == 0 and push_stats["errors"] == 0,
    }
    state = Path(os.path.expanduser(cfg["state_dir"]))
    state.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y-%m-%d")
    (state / "last-run.json").write_text(json.dumps(result, indent=2) + "\n")
    (state / f"{stamp}.json").write_text(json.dumps(result, indent=2) + "\n")
    log("done      " + ("ok" if result["ok"] else "finished with errors"))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())

