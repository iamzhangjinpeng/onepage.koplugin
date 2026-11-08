#!/usr/bin/env bash
# Copy the working tree onto a USB-mounted Kindle.
#
#   scripts/deploy_usb.sh /Volumes/Kindle            # keep the wallpaper cache
#   scripts/deploy_usb.sh /Volumes/Kindle --fresh    # also wipe onepage caches
#
# The Kindle must be ejected before KOReader is started again: plugins are only
# loaded at startup, so "完全退出 KOReader 再打开" is part of the procedure.
set -euo pipefail

mount="${1:-}"
fresh="${2:-}"
if [[ -z "$mount" ]]; then
    echo "usage: $0 /Volumes/Kindle [--fresh]" >&2
    exit 2
fi
if [[ "$fresh" != "" && "$fresh" != "--fresh" ]]; then
    echo "unknown option: $fresh" >&2
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
rm -rf "$dest"
mkdir -p "$dest"
cp "$repo_dir"/_meta.lua "$repo_dir"/main.lua "$repo_dir"/onepage_*.lua \
    "$repo_dir"/README.md "$dest/"
cp -R "$repo_dir/docs" "$dest/"

if [[ "$fresh" == "--fresh" ]]; then
    rm -rf "$mount/koreader/screenshots/onepage"
    echo "wiped koreader/screenshots/onepage"
fi

sync
echo "deployed to $dest"
find "$dest" -maxdepth 1 -type f | sort | sed 's|^|  |'
echo "next: eject, then 完全退出 KOReader 并重新打开"
