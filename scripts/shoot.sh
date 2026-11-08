#!/bin/bash
# Screenshot a theme in dev mode (sample apps) with headless Chrome, to check layouts quickly.
#   scripts/shoot.sh cloth            → build/shots/cloth.png (10 sample apps)
#   scripts/shoot.sh cloth "n=3&hot=1" → build/shots/cloth-n=3&hot=1.png
# The real app renders with WebKit; `MenuBuddy --snapshot` checks that path.
set -euo pipefail
cd "$(dirname "$0")/.."
theme=$1
query=${2:-}
size=${SIZE:-900,560}
mkdir -p build/shots
out="build/shots/$theme${query:+-$query}.png"
# perl's alarm: headless Chrome occasionally hangs instead of exiting.
perl -e 'alarm 45; exec @ARGV' "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars \
    --allow-file-access-from-files --window-size="$size" --virtual-time-budget=4000 \
    --screenshot="$PWD/$out" "file://$PWD/Resources/Themes/$theme.html${query:+?$query}" >/dev/null 2>&1
echo "$out"
