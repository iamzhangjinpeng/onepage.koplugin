#!/usr/bin/env bash
# Copy the working tree onto a USB-mounted Kindle.
#
#   scripts/deploy_usb.sh /Volumes/Kindle            # keep the wallpaper cache
#   scripts/deploy_usb.sh /Volumes/Kindle --fresh    # also wipe onepage caches
#   scripts/deploy_usb.sh --fresh /Volumes/Kindle    # same, flag first
#
# --fresh deletes koreader/screenshots/onepage/ (downloaded JPEG, its JSON,
# every rendered PNG and display/wallpaper.png). Nothing outside that one
# directory is touched. Use it to reproduce a first install, or whenever the
# change affects the cache key or the painted geometry -- otherwise the old
# PNG is a cache hit and the new code never runs.
#
# The Kindle must be ejected before KOReader is started again: plugins are only
# loaded at startup, so "完全退出 KOReader 再打开" is part of the procedure.
set -euo pipefail

mount=""
fresh=""
for arg in "$@"; do
    case "$arg" in
        --fresh) fresh="--fresh" ;;
        -h|--help) echo "usage: $0 /Volumes/Kindle [--fresh]"; exit 0 ;;
        -*) echo "unknown option: $arg" >&2; exit 2 ;;
        *) mount="$arg" ;;
    esac
done
if [[ -z "$mount" ]]; then
    echo "usage: $0 /Volumes/Kindle [--fresh]" >&2
    exit 2
fi

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plugins_dir="$mount/koreader/plugins"
dest="$plugins_dir/onepage.koplugin"
if [[ ! -d "$plugins_dir" ]]; then
    echo "error: $plugins_dir not found — is the Kindle mounted here?" >&2
    echo "hint: ls /Volumes" >&2
    exit 1
fi
case "$dest" in
    */koreader/plugins/onepage.koplugin) ;;
    *) echo "error: refusing to write to $dest" >&2; exit 1 ;;
esac

# Only the files the plugin actually loads; tests/ and scripts/ stay on the host.
# COPYFILE_DISABLE stops macOS from writing "._name" AppleDouble files onto the
# FAT volume; the find below is a belt-and-braces cleanup for older copies.
#
# Copy into a staging directory and verify it before touching the installed
# copy. The old "rm -rf $dest; cp ..." order meant a USB disconnect (or a
# blocked rm) between the two steps left the device with no plugin at all.
staging="$plugins_dir/onepage.koplugin.new"
rm -rf "$staging"
mkdir -p "$staging"
COPYFILE_DISABLE=1 cp "$repo_dir"/_meta.lua "$repo_dir"/main.lua "$repo_dir"/onepage_*.lua \
    "$repo_dir"/README.md "$staging/"
COPYFILE_DISABLE=1 cp -R "$repo_dir/docs" "$staging/"
find "$staging" -name '._*' -delete 2>/dev/null || true

for src in "$repo_dir"/_meta.lua "$repo_dir"/main.lua "$repo_dir"/onepage_*.lua "$repo_dir"/README.md; do
    name="$(basename "$src")"
    want="$(shasum -a 256 "$src" | cut -d' ' -f1)"
    got="$(shasum -a 256 "$staging/$name" 2>/dev/null | cut -d' ' -f1)"
    if [[ "$want" != "$got" ]]; then
        echo "error: $name did not survive the copy — installed copy left untouched" >&2
        rm -rf "$staging"
        exit 1
    fi
done
if [[ ! -f "$staging/docs/field-test.md" ]]; then
    echo "error: docs did not survive the copy — installed copy left untouched" >&2
    rm -rf "$staging"
    exit 1
fi

rm -rf "$dest"
mv "$staging" "$dest"

if [[ "$fresh" == "--fresh" ]]; then
    cache="$mount/koreader/screenshots/onepage"
    if [[ -d "$cache" ]]; then
        count=$(find "$cache" -type f | wc -l | tr -d ' ')
        bytes=$(du -sk "$cache" | cut -f1)
        rm -rf "$cache"
        echo "wiped $cache ($count files, ${bytes} KB)"
    else
        echo "cache already empty: $cache"
    fi
fi

sync
if [[ ! -f "$dest/main.lua" ]]; then
    echo "error: $dest/main.lua is missing after the swap — the volume went away mid-deploy, redeploy before starting KOReader" >&2
    exit 1
fi
echo "deployed to $dest"
find "$dest" -maxdepth 1 -type f 2>/dev/null | sort | sed 's|^|  |' || true
echo "next: eject, then 完全退出 KOReader 并重新打开"
