#!/bin/zsh
# Publishes a release that scripts/release.sh built: uploads the DMG to a
# GitHub Release, then adds it to the update feed that every installed copy
# of SameKeys checks (KB-101).
#
#   scripts/publish-release.sh [--critical]
#
# --critical marks the update critical: Sparkle shows it at once, without the
# option to skip it. Keep it for updates that fix lost or stuck keys.
#
# Needs, for the version in project.yml:
#   dist/SameKeys-<version>.dmg   signed with Developer ID and notarized
#   release-notes/<version>/       en.html, zh-Hans.html and ja.html
# and the update signing key in the login keychain (Sparkle's generate_keys,
# account "keybridge"). The public half is SUPublicEDKey in project.yml.
#
# The DMG is uploaded before the feed changes, so the feed never points at a
# file that is not there yet. Nothing is published until you confirm.
set -euo pipefail
cd "$(dirname "$0")/.."

step() { print -P "%B==> $1%b" }
fail() { print -u2 "error: $1"; exit 1 }

critical=()
[[ ${1:-} == --critical ]] && critical=(--critical)

version=$(awk -F'"' '/MARKETING_VERSION:/ { print $2; exit }' project.yml)
build=$(awk -F'"' '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' project.yml)
[[ -n $version && -n $build ]] || fail "could not read the version from project.yml"
dmg=dist/SameKeys-$version.dmg
notes=release-notes/$version
appcast=site/appcast.xml
tag=v$version
url=https://github.com/lynnjeans/samekeys/releases/download/$tag/SameKeys-$version.dmg

step "Checking SameKeys $version ($build)"
[[ -z $(git status --porcelain) ]] || fail "the working tree has uncommitted changes"
[[ $(git branch --show-current) == main ]] || fail "publish from main"
git fetch -q origin main
[[ $(git rev-parse HEAD) == $(git rev-parse origin/main) ]] || fail "main is not the same as origin/main; pull or push first"
[[ -f $dmg ]] || fail "$dmg is missing; run scripts/release.sh first"
# An ad-hoc or unnotarized build must never reach the feed: installed copies
# would replace themselves with it and lose their permissions, or be blocked
# by Gatekeeper.
# (Read whole first; `| grep -q` under pipefail can fail a matching signature.)
signature=$(codesign -dv --verbose=2 $dmg 2>&1)
[[ $signature == *$'\n'"Authority=Developer ID Application"* ]] \
  || fail "$dmg is not signed with Developer ID"
xcrun stapler validate -q $dmg || fail "$dmg is not notarized"
for language in en zh-Hans ja; do
  [[ -s $notes/$language.html ]] || fail "release notes missing: $notes/$language.html"
done
gh release view $tag >/dev/null 2>&1 && fail "GitHub already has a release $tag"

# Sparkle's tools come with its Swift package: from the release build, or
# failing that from a development build.
sign_update=(build/release/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update(N)
  build/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update(N))
sign_update=${sign_update[1]:-}
[[ -x $sign_update ]] || fail "Sparkle's sign_update not found; build SameKeys once so the package is fetched"

step "Signing the update"
signature=$($sign_update --account keybridge -p $dmg)
length=$(stat -f %z $dmg)

# Written to a copy first: appcast.py refuses a build number that is not
# newer, and that should stop things before anything is uploaded. The copy
# ends in .xml, which is how sign_update tells a feed from an archive.
feed_dir=$(mktemp -d)
trap 'rm -rf $feed_dir' EXIT
feed=$feed_dir/appcast.xml
[[ -f $appcast ]] && cp $appcast $feed
python3 scripts/appcast.py --appcast $feed --version $version --build $build --url $url \
  --length $length --signature $signature --notes $notes $critical

# The feed itself is signed too (SK-312): copies after 1.5.1 set
# SURequireSignedFeed and refuse a feed whose signature does not match, so a
# changed feed cannot show other release notes or mark a version critical.
# appcast.py drops the old signature when it rewrites the feed; sign_update
# appends the new one. Any later hand edit of site/appcast.xml must be
# signed again: `sign_update --account keybridge site/appcast.xml`.
step "Signing the update feed"
$sign_update --account keybridge $feed
$sign_update --account keybridge --verify $feed >/dev/null || fail "the signed feed does not verify"

print
print "  Release:   $tag, $dmg ($(du -h $dmg | cut -f1 | tr -d ' '))"
print "  Feed:      $appcast gets SameKeys $version ($build)${critical:+, critical}"
print "  Commit:    $(git log -1 --format='%h %s')"
print
read -q "?Publish? Every installed SameKeys will be offered this version. [y/N] " || { print; fail "not published" }
print

step "Creating the GitHub release"
gh release create $tag $dmg $dmg.sha256 --title "SameKeys $version" --notes-file $notes/en.html --target $(git rev-parse HEAD)

step "Publishing the update feed"
cp $feed $appcast
git add $appcast
git commit -q -m "Publish SameKeys $version to the update feed"
git push -q origin main

step "Done"
print "  The website workflow deploys $appcast in a minute or two; installed copies find it on their next daily check."
