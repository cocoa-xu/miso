#!/bin/bash
set -euo pipefail

[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
  printf '%s\n' 'MISO requires macOS on Apple silicon.' >&2
  exit 1
}
version=${MISO_ACTION_VERSION:-latest}
if [[ "$version" != latest && "$version" != source && ! "$version" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf '%s\n' 'Expected a MISO release version, latest, or source.' >&2
  exit 1
fi
base_url=${MISO_ACTION_XCODE_BASE_URL:-}
unset MISO_ACTION_XCODE_BASE_URL
if [[ "$base_url" == *$'\n'* || "$base_url" == *$'\r'* ]]; then
  printf '%s\n' 'Xcode base URL must be a single line.' >&2
  exit 1
fi
if [[ -n "$base_url" ]]; then
  printf '::add-mask::%s\n' "${base_url//%/%25}"
fi
installation=$(mktemp -d "$RUNNER_TEMP/miso.XXXXXX")
complete=false
trap 'if [[ "$complete" != true ]]; then rm -rf "$installation"; fi' EXIT
if [[ "$version" == source ]]; then
  make -C "$GITHUB_ACTION_PATH" build
  install -m 755 "$GITHUB_ACTION_PATH/.build/release/miso" "$installation/miso"
elif [[ "$version" == latest ]]; then
  gh release download --repo cocoa-xu/miso --pattern 'miso.tar.gz*' --dir "$installation"
else
  gh release download "v${version#v}" --repo cocoa-xu/miso \
    --pattern 'miso.tar.gz*' --dir "$installation"
fi
(
  cd "$installation"
  if [[ "$version" != source ]]; then
    shasum -a 256 -c miso.tar.gz.sha256
    tar -xzf miso.tar.gz
    rm miso.tar.gz miso.tar.gz.sha256
  fi
  codesign --verify --strict miso
  [[ "$(lipo -archs miso)" == arm64 ]]
  ./miso --version
)
if [[ -n "$base_url" ]] && ! "$installation/miso" xcode prepare-archive --help | grep -q MISO_XCODE_BASE_URL; then
  printf '%s\n' 'This MISO release predates Xcode mirrors; use version: source or a newer release.' >&2
  exit 1
fi
printf '%s\n' "$installation" >> "$GITHUB_PATH"
printf 'MISO_XCODE_BASE_URL=%s\n' "$base_url" >> "$GITHUB_ENV"
complete=true
