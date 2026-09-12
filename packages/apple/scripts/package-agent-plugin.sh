#!/bin/sh
set -eu

apple_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
packages_root=$(CDPATH= cd -- "$apple_root/.." && pwd)
source_root="$packages_root/mcp/plugin"
output_root=${1:-"$apple_root/.build/plugin/briefly"}

if [ -e "$output_root" ]; then
  echo "Output already exists: $output_root" >&2
  exit 1
fi

mkdir -p "$output_root"
cp -R "$source_root/." "$output_root"

echo "$output_root"
