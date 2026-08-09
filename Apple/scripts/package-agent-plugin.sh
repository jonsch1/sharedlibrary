#!/bin/sh
set -eu

apple_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo_root=$(CDPATH= cd -- "$apple_root/.." && pwd)
source_root="$repo_root/Plugins/briefly"
output_root=${1:-"$apple_root/.build/plugin/briefly"}

if [ -e "$output_root" ]; then
  echo "Output already exists: $output_root" >&2
  exit 1
fi

swift build --package-path "$apple_root" -c release --product briefly-mcp
mkdir -p "$output_root"
cp -R "$source_root/." "$output_root"
cp "$apple_root/.build/release/briefly-mcp" "$output_root/bin/briefly-mcp"
chmod 755 "$output_root/bin/briefly-mcp"

echo "$output_root"
