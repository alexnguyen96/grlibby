#!/bin/sh
# Build the release asset for KOReader: a zip of the plugin folder.
#
# Upload the resulting goodreadslibby.koplugin.zip as an asset on the GitHub
# release — the plugin's self-updater prefers a .zip asset whose name contains
# "goodreadslibby" (and falls back to GitHub's source zip if there's no asset).
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
out="goodreadslibby.koplugin.zip"
rm -f "$out"
zip -r -X "$out" goodreadslibby.koplugin \
  -x '*/__pycache__/*' '*.log' '*.log.1' >/dev/null
echo "Wrote $root/$out"
