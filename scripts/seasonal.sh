#!/bin/bash
# The Christmas Tree theme's seasonal extra is a page kept encoded in Resources/Themes/seasonal.dat
# (so it isn't spoiled at a glance); the app decodes it in memory. To edit it:
#   scripts/seasonal.sh decode            → build/seasonal.html (plain HTML)
#   scripts/seasonal.sh encode [file]     → Resources/Themes/seasonal.dat, from build/seasonal.html or [file]
# Encoding: bytes XOR "MenuBuddy", then base64 (76-column lines).
set -euo pipefail
cd "$(dirname "$0")/.."
xor='my $k = "MenuBuddy"; my $o = ""; for my $i (0 .. length($_) - 1) { $o .= chr(ord(substr($_, $i, 1)) ^ ord(substr($k, $i % length($k), 1))) }'
case "${1:-}" in
    decode)
        mkdir -p build
        perl -MMIME::Base64 -0777 -ne '$_ = decode_base64($_); '"$xor"' print $o' Resources/Themes/seasonal.dat > build/seasonal.html
        echo "build/seasonal.html" ;;
    encode)
        perl -MMIME::Base64 -0777 -ne "$xor"' print encode_base64($o)' "${2:-build/seasonal.html}" > Resources/Themes/seasonal.dat
        echo "Resources/Themes/seasonal.dat" ;;
    *) echo "usage: scripts/seasonal.sh decode|encode [file]" >&2; exit 1 ;;
esac
