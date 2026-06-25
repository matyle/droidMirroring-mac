#!/usr/bin/env bash
# Fetch Google platform-tools and extract the `adb` binary into App/Resources/.
# Idempotent.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=versions.env
source "${SCRIPT_DIR}/versions.env"

OUT_DIR="${ROOT_DIR}/App/Resources"
TMP_DIR="$(mktemp -d -t droidmirroring-adb-XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

ZIP_URL="https://dl.google.com/android/repository/platform-tools_r${PLATFORM_TOOLS_VERSION}-darwin.zip"
ZIP_FILE="${TMP_DIR}/platform-tools.zip"

mkdir -p "${OUT_DIR}/Licenses"

if [[ -x "${OUT_DIR}/adb" && -n "${PLATFORM_TOOLS_SHA256}" ]]; then
  echo "==> Verifying existing adb (zip sha cached marker)"
  if [[ -f "${OUT_DIR}/.adb.sha" && "$(cat "${OUT_DIR}/.adb.sha")" == "${PLATFORM_TOOLS_SHA256}" ]]; then
    echo "==> Already up to date."
    exit 0
  fi
fi

echo "==> Downloading platform-tools r${PLATFORM_TOOLS_VERSION}"
curl --fail --location --progress-bar --output "${ZIP_FILE}" "${ZIP_URL}"

if [[ -n "${PLATFORM_TOOLS_SHA256}" ]]; then
  echo "${PLATFORM_TOOLS_SHA256}  ${ZIP_FILE}" | shasum -a 256 -c -
else
  echo "==> WARNING: PLATFORM_TOOLS_SHA256 is empty in versions.env."
  echo "    Compute with: shasum -a 256 \"${ZIP_FILE}\""
fi

unzip -q "${ZIP_FILE}" -d "${TMP_DIR}"
install -m 0755 "${TMP_DIR}/platform-tools/adb" "${OUT_DIR}/adb"
echo "${PLATFORM_TOOLS_SHA256:-unknown}" > "${OUT_DIR}/.adb.sha"

# Bundle the upstream NOTICE / LICENSE for compliance.
if [[ -f "${TMP_DIR}/platform-tools/NOTICE.txt" ]]; then
  install -m 0644 "${TMP_DIR}/platform-tools/NOTICE.txt" "${OUT_DIR}/Licenses/LICENSE-adb"
else
  cat > "${OUT_DIR}/Licenses/LICENSE-adb" <<'EOF'
The adb binary bundled with this app is part of Android platform-tools,
distributed by Google under the Apache License 2.0.

Source: https://developer.android.com/tools/releases/platform-tools
EOF
fi

echo "==> Done: ${OUT_DIR}/adb"
