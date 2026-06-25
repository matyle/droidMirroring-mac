#!/usr/bin/env bash
# One-shot setup: fetch all bundled binaries + verify toolchain.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Checking toolchain"
command -v xcodebuild >/dev/null || { echo "Xcode CLT not found. Run: xcode-select --install"; exit 1; }
command -v swift >/dev/null      || { echo "swift not found in PATH"; exit 1; }
command -v xcodegen >/dev/null   || echo "  (optional) xcodegen missing: brew install xcodegen"

bash "${SCRIPT_DIR}/fetch-scrcpy-server.sh"
bash "${SCRIPT_DIR}/fetch-adb.sh"

echo "==> Resolving SwiftPM packages"
for pkg in "${SCRIPT_DIR}/.."/Packages/*/; do
  echo "    - $(basename "${pkg}")"
  (cd "${pkg}" && swift package resolve >/dev/null)
done

echo "==> Bootstrap complete."
