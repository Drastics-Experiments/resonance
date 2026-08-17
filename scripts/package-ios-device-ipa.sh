#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 <Resonance.app> <output.ipa>" >&2
  exit 64
}

[[ $# -eq 2 ]] || usage

app_path="$1"
output_path="$2"

[[ -d "$app_path" ]] || {
  echo "error: app bundle not found: $app_path" >&2
  exit 66
}

plist_path="$app_path/Info.plist"
executable_path="$app_path/Resonance"

[[ -f "$plist_path" ]] || {
  echo "error: Info.plist not found in app bundle" >&2
  exit 65
}

[[ -f "$executable_path" ]] || {
  echo "error: Resonance executable not found in app bundle" >&2
  exit 65
}

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist_path")"
[[ "$bundle_id" == "com.gavindietrich.LikedSongsMobile" ]] || {
  echo "error: unexpected bundle identifier: $bundle_id" >&2
  exit 65
}

platform="$(/usr/libexec/PlistBuddy -c 'Print :DTPlatformName' "$plist_path")"
[[ "$platform" == "iphoneos" ]] || {
  echo "error: expected an iphoneos app, found: $platform" >&2
  exit 65
}

[[ ! -e "$app_path/_CodeSignature" && ! -e "$app_path/embedded.mobileprovision" ]] || {
  echo "error: input app must be unsigned and unprovisioned" >&2
  exit 65
}

architectures="$(lipo -archs "$executable_path")"
[[ " $architectures " == *" arm64 "* ]] || {
  echo "error: device executable does not contain arm64: $architectures" >&2
  exit 65
}

[[ " $architectures " != *" x86_64 "* ]] || {
  echo "error: simulator architecture found in device executable: $architectures" >&2
  exit 65
}

staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/resonance-ipa.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT

mkdir -p "$staging_dir/Payload"
ditto "$app_path" "$staging_dir/Payload/Resonance.app"
mkdir -p "$(dirname "$output_path")"
ditto -c -k --keepParent "$staging_dir/Payload" "$output_path"

unzip -t "$output_path" >/dev/null

entry_count="$(unzip -Z1 "$output_path" | awk '/^Payload\/[^\/]+\.app\/$/ { count += 1 } END { print count + 0 }')"
[[ "$entry_count" == "1" ]] || {
  echo "error: IPA must contain exactly one top-level app bundle" >&2
  exit 65
}

shasum -a 256 "$output_path" > "$output_path.sha256"
