#!/bin/bash
set -euo pipefail

[[ ${GITHUB_ACTIONS:-} == true && ${RUNNER_OS:-} == macOS && ${RUNNER_ARCH:-} == ARM64 ]]
work="$RUNNER_TEMP/miso-image"
evidence="$RUNNER_TEMP/image-evidence"
mkdir -p "$evidence"
binary="$work/bin/miso"
tart="$work/bin/tart.app/Contents/MacOS/tart"
export PATH="$work/bin:$PATH"
export TART_HOME="$work/tart"
export TART_NO_AUTO_PRUNE=1

fetch() {
  local url=$1 destination=$2 bytes=$3 digest=$4
  [[ ! -e "$destination" ]]
  curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
    --connect-timeout 30 --max-time 3600 --retry 2 --retry-max-time 3900 \
    --max-filesize "$bytes" --output "$destination.partial" "$url"
  [[ $(stat -f %z "$destination.partial") == "$bytes" ]]
  [[ $(shasum -a 256 "$destination.partial" | awk '{print $1}') == "$digest" ]]
  mv "$destination.partial" "$destination"
}

host() {
  sw_vers
  uname -m
  sysctl hw.model hw.memsize
  sysctl kern.hv_support || true
  xcodebuild -version
  swift --version
  sudo -n id -u
  csrutil status
  /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    /System/Library/Filesystems/apfs.fs/Contents/Info.plist
  [[ $(sw_vers -productVersion) == 27.0 && $(sw_vers -buildVersion) == 26A428 ]]
  df -k /
}

prepare() {
  mkdir -p "$work/bin" "$work/inputs/packages" "$TART_HOME/vms"
  cp .build/release/miso "$binary"
  codesign --verify --strict "$binary"
  cp "$(command -v gh)" "$work/bin/gh"
  otool -L "$work/bin/gh" > "$evidence/gh-libraries.txt"
  if grep -q '/opt/homebrew/' "$evidence/gh-libraries.txt"; then
    printf '%s\n' 'GitHub CLI still requires Homebrew libraries.' >&2
    return 1
  fi
  /usr/bin/jq --version
  fetch https://github.com/openai/tart/releases/download/2.40.1/tart.tar.gz \
    "$work/tart.tar.gz" 22943905 363e2701154a8155cbc1bb6d845430c9b42697d2a186bc49574471ca2877db46
  tar -xzf "$work/tart.tar.gz" -C "$work/bin"
  codesign --verify --deep --strict "$work/bin/tart.app"
  "$tart" --version
  df -k / > "$evidence/space-before-cleanup.txt"
  xcrun simctl runtime delete all || true
  local selected path
  selected=$(cd "$DEVELOPER_DIR/../.." && pwd -P)
  for path in /Applications/Xcode*.app; do
    [[ -d "$path" && ! -L "$path" && "$path" != "$selected" ]] || continue
    sudo -n rm -r "$path"
  done
  for path in "$HOME/Library/Android" "$HOME/.android" "$HOME/.gradle" \
    "$HOME/.rustup" "$HOME/.cargo" "$HOME/Library/Caches/Homebrew" \
    "$HOME/Library/Caches/org.swift.swiftpm" .build /opt/homebrew \
    /usr/local/share/powershell /usr/local/share/dotnet /usr/local/lib/node_modules \
    /System/Library/AssetsV2/com_apple_MobileAsset_AppleDeveloperDocumentation; do
    if [[ -d "$path" && ! -L "$path" ]]; then sudo -n rm -r "$path"; fi
  done
  hash -r
  "$work/bin/gh" --version
  /usr/bin/git --version
  df -k / | tee "$evidence/space-after-cleanup.txt"
  [[ $(df -k "$work" | awk 'NR==2 {print $4}') -ge 93323264 ]]
}

download() {
  local filename url bytes digest
  while IFS=$'\t' read -r filename url bytes digest; do
    printf 'Downloading %s\n' "$filename"
    fetch "$url" "$work/inputs/packages/$filename" "$bytes" "$digest"
  done < Resources/CI/macos-27.0.1-clt.tsv
  df -k / > "$evidence/space-after-download.txt"
}

build() {
  (
    while true; do
      printf '%s\t%s\n' "$(date -u +%FT%TZ)" "$(df -k "$work" | awk 'NR==2 {print $4}')" \
        >> "$evidence/space-samples.tsv"
      sleep 30
    done
  ) &
  monitor_pid=$!
  local options=(--disk-bytes 68719476736 --output "$work/restore")
  if [[ ${MISO_KEEP_DOWNLOADS:-false} == true ]]; then options+=(--keep-downloads); fi
  sudo -n "$binary" restore \
    https://updates.cdn-apple.com/2026FallFCS/59241290-5d51-4ca8-9df4-31624b9a4eac/UniversalMac_27.0.1_26A434_Restore.ipsw \
    --packages "$work/inputs/packages" "${options[@]}" \
    > "$evidence/restore.json"
  jq -e '.profile.release == {version:"27.0.1",build:"26A434"} and .profile.ipswSHA256 == "2f016638293c3e641b8b25391a76fbc16563b3711915a5551cf8aa0f5598a5c1"' \
    "$evidence/restore.json"
  sudo -n "$binary" bundle export-tart "$work/restore/assembled/bundle" \
    --output "$work/export" > "$evidence/export.json"
  sudo -n cp "$work/restore/assembled/bundle/manifest.json" "$evidence/bundle-manifest.json"
  sudo -n chown -R "$(id -u):$(id -g)" "$work/export" "$evidence"
  mv "$work/export/vm" "$TART_HOME/vms/vanilla"
  "$tart" get vanilla --format json > "$evidence/tart-config.json"
  collect
  hdiutil info > "$evidence/attachments.txt"
  if grep -F "$work/restore" "$evidence/attachments.txt"; then
    printf '%s\n' 'Restore images are still attached.' >&2
    return 1
  fi
  if [[ ${MISO_KEEP_DOWNLOADS:-false} == true ]]; then
    sudo -n mv "$work/restore/downloads" "$work/retained-downloads"
  fi
  sudo -n rm -r "$work/restore" "$work/inputs"
  df -k / > "$evidence/space-after-build.txt"
}

publish() {
  local owner reference
  owner=$(printf '%s' "$GITHUB_REPOSITORY_OWNER" | tr '[:upper:]' '[:lower:]')
  reference="ghcr.io/$owner/miso-ci-vanilla:27.0.1-26A434-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT"
  "$tart" push vanilla "$reference" --concurrency 2 --chunk-size 2 \
    --label "org.opencontainers.image.source=https://github.com/$GITHUB_REPOSITORY" \
    --label "org.opencontainers.image.revision=$GITHUB_SHA" \
    --label dev.macos-image.version=27.0.1 --label dev.macos-image.build=26A434 \
    --label dev.macos-image.variant=vanilla
  printf '%s\n' "$reference" > "$evidence/reference.txt"
}

verify() {
  local reference owner tag digest directory name expected
  reference=$(cat "$evidence/reference.txt")
  owner=$(printf '%s' "$GITHUB_REPOSITORY_OWNER" | tr '[:upper:]' '[:lower:]')
  tag=${reference##*:}
  gh api "/users/$owner/packages/container/miso-ci-vanilla/versions" > "$evidence/package-versions.json"
  digest=$(jq -er --arg tag "$tag" \
    '[.[] | select(.metadata.container.tags | index($tag))] | if length == 1 then .[0].name else error("Ambiguous image tag") end' \
    "$evidence/package-versions.json")
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]
  reference="${reference%:*}@$digest"
  export TART_HOME="$work/download-check"
  "$tart" clone "$reference" downloaded --concurrency 2
  directory="$TART_HOME/vms/downloaded"
  for name in disk.img nvram.bin; do
    expected=$(jq -er --arg name "$name" '.files[] | select(.path == $name) | .sha256' "$evidence/export.json")
    [[ $(shasum -a 256 "$directory/$name" | awk '{print $1}') == "$expected" ]]
  done
  jq -S '{hardwareModel,ecid,cpuCountMin,memorySizeMin,os,arch,diskFormat}' \
    "$work/tart/vms/vanilla/config.json" > "$evidence/source-identity.json"
  jq -S '{hardwareModel,ecid,cpuCountMin,memorySizeMin,os,arch,diskFormat}' \
    "$directory/config.json" > "$evidence/downloaded-identity.json"
  cmp "$evidence/source-identity.json" "$evidence/downloaded-identity.json"
  jq -n --arg reference "$reference" --arg revision "$GITHUB_SHA" \
    '{reference:$reference,revision:$revision,downloadVerified:true,vmStarted:false}' \
    > "$evidence/publication.json"
  printf 'Verified OCI image: `%s`\n' "$reference" >> "$GITHUB_STEP_SUMMARY"
  df -k / > "$evidence/space-after-verification.txt"
}

collect() {
  df -k / > "$evidence/space-final.txt"
  if [[ -d "$work/restore" ]]; then
    sudo -n find "$work/restore" -maxdepth 3 -name journal.json -type f -print0 |
      while IFS= read -r -d '' path; do
        sudo -n cat "$path" | jq -c \
          '{operation,status,error,vmStarted,stage:.metadata.stage,target:.metadata.target,ipswDownloaded:.metadata.ipswDownloaded,downloadedIPSWRemoved:.metadata.downloadedIPSWRemoved,keepDownloads:.metadata.keepDownloads,commands:[.commands[] | select(.error != null) | {name,error,result}]}'
      done > "$evidence/journals.jsonl"
    sudo -n find "$work/restore" -maxdepth 3 -name journal.json -type f -print0 |
      while IFS= read -r -d '' path; do
        sudo -n cat "$path" | jq -r '.commands[] | select(.error != null) | .stderr' |
          while IFS= read -r log; do
            [[ "$log" == logs/* && "$log" != *..* ]] || continue
            printf '\n%s/%s\n' "${path%/journal.json}" "$log"
            sudo -n tail -c 8192 "${path%/journal.json}/$log"
          done
      done > "$evidence/failed-commands.txt"
  fi
}

finish() {
  local status=$?
  if [[ -n ${monitor_pid:-} ]]; then
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
  fi
  printf '{"stage":"%s","exitCode":%d}\n' "$stage" "$status" > "$evidence/$stage-status.json"
}

case ${1:-} in
  host|prepare|download|build|publish|verify|collect)
    stage=$1
    trap finish EXIT
    "$stage"
    ;;
  *) printf '%s\n' 'Usage: ci-image.sh host|prepare|download|build|publish|verify|collect' >&2; exit 2 ;;
esac
