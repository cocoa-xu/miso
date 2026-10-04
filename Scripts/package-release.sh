#!/bin/bash
set -euo pipefail

tag=${1:?Usage: package-release.sh vVERSION}
if [[ ! "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  printf 'Invalid release tag: %s\n' "$tag" >&2
  exit 1
fi
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  printf '%s\n' 'Release packaging requires macOS on Apple silicon.' >&2
  exit 1
fi

version=${tag#v}
binary="$(swift build -c release --disable-automatic-resolution --show-bin-path)/miso"
if [[ "$("$binary" --version)" != "$version" ]]; then
  printf '%s\n' 'The release tag must match the version in Sources/MisoCLI/Miso.swift.' >&2
  exit 1
fi
[[ "$(lipo -archs "$binary")" == arm64 ]]
codesign --verify --strict "$binary"

output="$PWD/.build/artifacts"
archive="miso.tar.gz"
mkdir -p "$output"
if [[ -e "$output/$archive" || -e "$output/$archive.sha256" ]]; then
  printf '%s\n' 'Release assets already exist.' >&2
  exit 1
fi
staging=$(mktemp -d "${TMPDIR:-/tmp}/miso-release.XXXXXX")
trap 'rm -rf "$staging"' EXIT
install -m 755 "$binary" "$staging/miso"
cp README.md ACKNOWLEDGMENTS.md "$staging/"
cp -R ThirdPartyLicenses "$staging/"
{
  printf 'Version: %s\nCommit: %s\n' "$version" "$(git rev-parse HEAD)"
  sw_vers
  swift --version
} > "$staging/BUILD.txt"
COPYFILE_DISABLE=1 tar -czf "$output/$archive" -C "$staging" \
  miso README.md ACKNOWLEDGMENTS.md ThirdPartyLicenses BUILD.txt
mkdir "$staging/verify"
tar -xzf "$output/$archive" -C "$staging/verify"
codesign --verify --strict "$staging/verify/miso"
[[ "$("$staging/verify/miso" --version)" == "$version" ]]
"$staging/verify/miso" --help > /dev/null
(
  cd "$output"
  shasum -a 256 "$archive" > "$archive.sha256"
  shasum -a 256 -c "$archive.sha256"
)
