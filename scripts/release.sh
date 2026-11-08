#!/bin/bash
# Publish a new MenuBuddy version; everyone then updates with the install line.
#   scripts/release.sh 0.2.0 "What changed, in a sentence or two"
# Sets the version in Info.plist, builds the universal release zip and its checksum, commits,
# tags v<version>, pushes, and creates the GitHub release with both files. Needs a clean tree
# (commit your work first) and gh signed in as the repo owner.
set -euo pipefail
cd "$(dirname "$0")/.."
version=${1:?usage: scripts/release.sh <version> "<notes>"}
notes=${2:?usage: scripts/release.sh <version> "<notes>"}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must look like 0.2.0" >&2; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "commit your changes first" >&2; exit 1; }
git rev-parse "v$version" >/dev/null 2>&1 && { echo "v$version already exists" >&2; exit 1; }

plist=Resources/Info.plist
build=$(( $(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' $plist) + 1 ))
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $version" -c "Set CFBundleVersion $build" $plist
scripts/build.sh --release
git commit -qam "MenuBuddy $version"
git tag "v$version"
git push -q origin HEAD:main "v$version"   # always to main, whatever the local branch is called

# The owner's gh account (this Mac may have another one active).
export GH_TOKEN=${GH_TOKEN:-$(gh auth token --user cocoxcao 2>/dev/null || gh auth token)}
gh release create "v$version" build/MenuBuddy.zip build/MenuBuddy.zip.sha256 --title "MenuBuddy $version" --notes "$notes

Install or update:
\`\`\`sh
curl -fsSL https://raw.githubusercontent.com/cocoxcao/MenuBuddy/main/install.sh | bash
\`\`\`
SHA-256 of MenuBuddy.zip: \`$(cut -d' ' -f1 build/MenuBuddy.zip.sha256)\`"
echo "Released v$version. Update with the install line."
