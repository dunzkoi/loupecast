#!/bin/bash
# Rebuilds the demo on the landing page and in the READMEs: draws the screen (scripts/make-demo.swift), lets a debug
# build of Loupecast export it (LOUPECAST_EXPORT_TO), then encodes the copies: site/demo.mp4 (H.264, 1280 px, under
# 2 MB), site/demo-poster.jpg and .github/demo.gif for the READMEs (ffmpeg's palette GIF at 720 px, 12 fps: under half
# the size of the app's own 960 px GIF export, which writes every frame whole). Needs ffmpeg.
# Run: scripts/make-demo.sh
set -euo pipefail
cd "$(dirname "$0")/.."
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
swift scripts/make-demo.swift "$W/rec"
swift build --product Loupecast
LOUPECAST_RECORDINGS_DIR="$W/recordings" LOUPECAST_EXPORT_DIR="$W/exports" LOUPECAST_OPEN="$W/rec" \
  LOUPECAST_SNAPSHOT="$W/editor.png" LOUPECAST_SELECT=none LOUPECAST_EXPORT_TO="$W/demo.mp4" \
  "$(swift build --show-bin-path)/Loupecast" | grep 'LOUPECAST: export'
ffmpeg -v error -y -i "$W/demo.mp4" -vf scale=1280:-2 -c:v libx264 -preset slow -crf "${CRF:-27}" -pix_fmt yuv420p \
  -movflags +faststart -an site/demo.mp4
ffmpeg -v error -y -i "$W/demo.mp4" -frames:v 1 -vf scale=1280:-2 -q:v 3 site/demo-poster.jpg
ffmpeg -v error -y -i "$W/demo.mp4" -filter_complex \
  "fps=12,scale=720:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" \
  .github/demo.gif
ls -l site/demo.mp4 site/demo-poster.jpg .github/demo.gif
