#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

version="$(
    sed -nE 's/^[[:space:]]*version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' \
        _meta.lua | head -n 1
)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: _meta.lua version must use X.Y.Z format (got: ${version:-missing})" >&2
    exit 1
fi

archive_path="${1:-dist/onepage.koplugin-v${version}.zip}"
if [[ "$archive_path" != /* ]]; then
    archive_path="$repo_dir/$archive_path"
fi
# A zip of a version that was already published must never be silently
# replaced: the release asset is immutable, and a rebuilt file with the same
# name but a different digest reads as "安装包校验失败" only after someone has
# waited for the download. --force is for rebuilding before the first upload.
if [[ -e "$archive_path" && "${2:-}" != "--force" ]]; then
    echo "error: $archive_path already exists" >&2
    echo "       if v$version is published, bump the version instead of rebuilding it" >&2
    echo "       rebuilding before upload: sh $0 $1 --force" >&2
    exit 1
fi
mkdir -p "$(dirname "$archive_path")"

stage_dir="$(mktemp -d)"
cleanup() { rm -rf "$stage_dir"; }
trap cleanup EXIT

plugin_dir="$stage_dir/onepage.koplugin"
mkdir -p "$plugin_dir"
cp _meta.lua main.lua onepage_api.lua onepage_layout.lua \
    onepage_wallpaper.lua onepage_update.lua README.md "$plugin_dir/"
cp -R docs "$plugin_dir/"

rm -f "$archive_path"
(
    cd "$stage_dir"
    zip -qr "$archive_path" onepage.koplugin
)
unzip -tq "$archive_path"

size="$(wc -c < "$archive_path" | tr -d ' ')"
digest="$(shasum -a 256 "$archive_path" | cut -d' ' -f1)"

echo "version=$version"
echo "archive=$archive_path"
echo "size=$size"

# The release asset must report exactly this digest: onepage_update.check
# compares it against the file it downloads and refuses anything else, so a
# stale zip means "安装包校验失败" on every device.
echo "sha256=$digest"
echo "digest=sha256:$digest"
