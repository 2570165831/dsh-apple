#!/bin/bash
# Fetch everything the repository does not carry, then build for the simulator.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
for tool in node npm python3 gem git curl unzip jq xcodebuild; do
  command -v "$tool" > /dev/null || { echo "bootstrap: $tool is required; see README.md" >&2; exit 1; }
done
"$ROOT/scripts/fetch-vendor.sh"
"$ROOT/scripts/fetch-payload.sh"
[ -d "$ROOT/tools/gems/gems" ] || gem install xcodeproj --no-document --install-dir "$ROOT/tools/gems"
"$ROOT/ish/scripts/fetch-sources.sh"
GEM_HOME="$ROOT/tools/gems" GEM_PATH="$ROOT/tools/gems" /usr/bin/ruby "$ROOT/scripts/gen-xcode-project.rb"
"$ROOT/ish/scripts/build-cli.sh"
"$ROOT/scripts/build-app.sh"
