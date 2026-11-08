#!/usr/bin/env bash
# Pull everything needed to review a field test off a USB-mounted Kindle.
#
#   scripts/collect_logs.sh /Volumes/Kindle
#
# Produces fieldtest/<timestamp>/ with:
#   crash.log        full log tail (logger.info/warn land here)
#   onepage.log      only the lines this plugin wrote
#   listing.txt      cache/dir listing, sizes and dates
#   *.png            the display copy plus every cached render
set -euo pipefail

mount="${1:-}"
if [[ -z "$mount" ]]; then
    echo "usage: $0 /Volumes/Kindle" >&2
    exit 2
fi
koreader="$mount/koreader"
if [[ ! -d "$koreader" ]]; then
    echo "error: $koreader not found — is the Kindle mounted here?" >&2
    exit 1
fi

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
out="$repo_dir/fieldtest/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
: > "$out/onepage.log"   # always present, even when crash.log is missing

if [[ -f "$koreader/crash.log" ]]; then
    tail -n 3000 "$koreader/crash.log" > "$out/crash.log"
    grep -a "一页壁纸" "$out/crash.log" > "$out/onepage.log" || true
else
    echo "warning: no crash.log — start KOReader once so it writes one" >&2
fi

shots="$koreader/screenshots/onepage"
{
    echo "# $koreader"
    [[ -f "$koreader/git-rev" ]] && echo "koreader: $(cat "$koreader/git-rev")"
    echo
    echo "## $shots"
    ls -la "$shots" 2>/dev/null || echo "(missing)"
    echo
    echo "## $shots/wallpaper"
    ls -la "$shots/wallpaper" 2>/dev/null || echo "(missing)"
    echo
    echo "## $shots/wallpaper/display"
    ls -la "$shots/wallpaper/display" 2>/dev/null || echo "(missing)"
} > "$out/listing.txt"

if [[ -d "$shots/wallpaper" ]]; then
    find "$shots/wallpaper" -name '*.png' -type f -exec cp {} "$out/" \; 2>/dev/null || true
fi

echo "collected into $out"
ls -la "$out"
echo
echo "plugin log lines: $(wc -l < "$out/onepage.log")"
