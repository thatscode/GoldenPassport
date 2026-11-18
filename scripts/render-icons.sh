#!/bin/bash
# Renders the icon images that macOS 13–15 and the menu bar use from design/icon/*.svg.
# Needs rsvg-convert (brew install librsvg). macOS 26 and later use Resources/AppIcon.icon,
# which build-app.sh compiles with actool; keep its layers in step with AppIcon-flat.svg.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
rsvg-convert -w 1024 -h 1024 "$ROOT/design/icon/AppIcon-flat.svg" -o "$ROOT/Resources/AppIcon.png"
rsvg-convert -f pdf "$ROOT/design/icon/statusIcon.svg" -o "$ROOT/Resources/statusIcon.pdf"
echo "Rendered Resources/AppIcon.png and Resources/statusIcon.pdf"
