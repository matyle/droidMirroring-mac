#!/usr/bin/env bash
# Fetch scrcpy-server-vX.Y.jar from upstream release and place it into App/Resources/.
# Idempotent: skips download if file already exists with matching sha256.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=versions.env
source "${SCRIPT_DIR}/versions.env"

OUT_DIR="${ROOT_DIR}/App/Resources"
OUT_FILE="${OUT_DIR}/scrcpy-server-v${SCRCPY_VERSION}.jar"
URL="https://github.com/Genymobile/scrcpy/releases/download/v${SCRCPY_VERSION}/scrcpy-server-v${SCRCPY_VERSION}"

mkdir -p "${OUT_DIR}"

if [[ -f "${OUT_FILE}" && -n "${SCRCPY_SERVER_SHA256}" ]]; then
  echo "==> Verifying existing ${OUT_FILE}"
  if shasum -a 256 "${OUT_FILE}" | awk '{print $1}' | grep -qi "^${SCRCPY_SERVER_SHA256}$"; then
    echo "==> Already up to date."
    exit 0
  fi
  echo "==> SHA mismatch, re-downloading."
fi

echo "==> Downloading scrcpy-server v${SCRCPY_VERSION}"
curl --fail --location --progress-bar --output "${OUT_FILE}" "${URL}"

if [[ -n "${SCRCPY_SERVER_SHA256}" ]]; then
  echo "==> Verifying sha256"
  echo "${SCRCPY_SERVER_SHA256}  ${OUT_FILE}" | shasum -a 256 -c -
else
  echo "==> WARNING: SCRCPY_SERVER_SHA256 is empty in versions.env."
  echo "    Compute with: shasum -a 256 \"${OUT_FILE}\""
fi

# Symlink to a stable name the App target expects.
ln -sf "scrcpy-server-v${SCRCPY_VERSION}.jar" "${OUT_DIR}/scrcpy-server.jar"
echo "==> Done: ${OUT_FILE}"

# Also pull the LICENSE for compliance bundling.
curl --fail --silent --location \
  --output "${OUT_DIR}/Licenses/LICENSE-scrcpy" \
  "https://raw.githubusercontent.com/Genymobile/scrcpy/v${SCRCPY_VERSION}/LICENSE"
echo "==> Wrote App/Resources/Licenses/LICENSE-scrcpy"
