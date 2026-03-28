#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/hot_sample_lib.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

window_probe_swift="$tmpdir/ghostty_window_probe.swift"
cat >"$window_probe_swift" <<'SWIFT'
import Foundation
import CoreGraphics

struct Window: Encodable {
    let owner: String
    let name: String
    let number: Int
    let layer: Int
    let alpha: Double
    let onscreen: Bool
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as NSArray? ?? []
var windows: [Window] = []
for case let item as NSDictionary in raw {
    let owner = item[kCGWindowOwnerName] as? String ?? ""
    if !owner.lowercased().contains("ghostty") {
        continue
    }

    let name = item[kCGWindowName] as? String ?? ""
    let number = item[kCGWindowNumber] as? Int ?? -1
    let layer = item[kCGWindowLayer] as? Int ?? -1
    let alpha = item[kCGWindowAlpha] as? Double ?? 0

    let onscreen: Bool
    if let value = item[kCGWindowIsOnscreen] as? Bool {
        onscreen = value
    } else if let value = item[kCGWindowIsOnscreen] as? Int {
        onscreen = value != 0
    } else {
        onscreen = false
    }

    let bounds = item[kCGWindowBounds] as? NSDictionary ?? [:]
    let x = bounds["X"] as? Double ?? 0
    let y = bounds["Y"] as? Double ?? 0
    let width = bounds["Width"] as? Double ?? 0
    let height = bounds["Height"] as? Double ?? 0

    windows.append(Window(
        owner: owner,
        name: name,
        number: number,
        layer: layer,
        alpha: alpha,
        onscreen: onscreen,
        x: x,
        y: y,
        width: width,
        height: height
    ))
}

let data = try JSONEncoder().encode(windows)
FileHandle.standardOutput.write(data)
SWIFT

window_ocr_swift="$tmpdir/ghostty_window_ocr.swift"
cat >"$window_ocr_swift" <<'SWIFT'
import Foundation
import Vision
import AppKit

let path = CommandLine.arguments[1]
let url = URL(fileURLWithPath: path)
guard let image = NSImage(contentsOf: url) else {
    fputs("unable to open image\n", stderr)
    exit(1)
}

var rect = CGRect.zero
guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
    fputs("unable to create cgimage\n", stderr)
    exit(1)
}

let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
try handler.perform([request])

for observation in request.results ?? [] {
    if let text = observation.topCandidates(1).first?.string, !text.isEmpty {
        print(text)
    }
}
SWIFT

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

window_snapshot_json() {
  swift "$window_probe_swift"
}

select_terminal_window() {
  python3 -c '
import json
import sys

windows = json.load(sys.stdin)
candidates = [
    w for w in windows
    if w["onscreen"]
    and w["layer"] == 0
    and w["alpha"] > 0
    and w["name"] != "Configuration Errors"
]
if not candidates:
    sys.exit(1)

window = max(candidates, key=lambda w: (w["width"] * w["height"], w["number"]))
print(str(window["number"]) + "\t" + window["name"])
'
}

configuration_errors_present() {
  python3 -c '
import json
import sys

windows = json.load(sys.stdin)
for window in windows:
    if window["name"] == "Configuration Errors" and window["onscreen"] and window["alpha"] > 0:
        print("true")
        break
else:
    print("false")
' 
}

ocr_image_text() {
  local image_path="$1"
  swift "$window_ocr_swift" "$image_path"
}

ghostty_pid() {
  ps -axo pid=,command= | awk '/\/Ghostty\.app\/Contents\/MacOS\/ghostty$/ { pid = $1 } END { if (pid != "") print pid }'
}

pid="$(ghostty_pid)"
[[ -n "$pid" ]] || fail "no live Ghostty app process found"

selected_window=""
for _attempt in $(seq 1 40); do
  snapshot="$(window_snapshot_json)" || fail "unable to inspect Ghostty windows"

  if [[ "$(printf '%s\n' "$snapshot" | configuration_errors_present)" == "true" ]]; then
    fail "Ghostty is showing the Configuration Errors window"
  fi

  if selected_window="$(printf '%s\n' "$snapshot" | select_terminal_window 2>/dev/null)"; then
    break
  fi

  sleep 0.25
done

[[ -n "$selected_window" ]] || fail "no on-screen Ghostty terminal window found"

window_id="${selected_window%%$'\t'*}"
window_name="${selected_window#*$'\t'}"
window_image="$tmpdir/ghostty_window.png"
screencapture -x -l "$window_id" "$window_image" >/dev/null 2>&1 || fail "unable to capture Ghostty window image"

ocr_text="$(ocr_image_text "$window_image")" || fail "unable to OCR Ghostty window image"
case "$window_name"$'\n'"$ocr_text" in
  *"Configuration Errors"*|*"Oh, no. "*|*"The terminal failed to initialize"*|*"The renderer has failed."*)
    fail "Ghostty window is showing an error UI"
    ;;
esac

generation="$(hot_sample_current_generation)" || fail "unable to query hot runtime generation from live app"

printf 'PASS live Ghostty window healthy (pid=%s, generation=%s, window_id=%s, title=%s)\n' \
  "$pid" \
  "$generation" \
  "$window_id" \
  "$window_name"
