#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# magicrew one-click installer
# Usage: curl https://<host>/install.sh | bash
# ---------------------------------------------------------------------------

BINARY_NAME="magicrew-cli"
INSTALL_DIR="${MAGICREW_CLI_INSTALL_DIR:-/usr/local/bin}"
# Defaults: binaries come from GitHub Releases, configs come from gh-pages/bootstrap/latest.
# You can pin a specific version via MAGICREW_CLI_RELEASE_TAG (for example: magicrew-cli-v0.0.1); otherwise latest is used.
if [ -n "${MAGICREW_CLI_RELEASE_TAG:-}" ]; then
  RELEASE_BASE_URL="${MAGICREW_CLI_RELEASE_BASE_URL:-https://github.com/dtyq/artifacts/releases/download/${MAGICREW_CLI_RELEASE_TAG}}"
else
  RELEASE_BASE_URL="${MAGICREW_CLI_RELEASE_BASE_URL:-https://github.com/dtyq/artifacts/releases/latest/download}"
fi
BOOTSTRAP_BASE_URL="${MAGICREW_CLI_BOOTSTRAP_BASE_URL:-https://dtyq.github.io/artifacts/bootstrap/latest}"
CONFIG_FILE="${MAGICREW_CLI_CONFIG_FILE:-${HOME}/.config/magicrew/config.yml}"
VALUES_FILE="${MAGICREW_CLI_VALUES_FILE:-${HOME}/.config/magicrew/values.yaml}"

download_file() {
  local url="$1"
  local output="$2"

  if command -v curl &>/dev/null; then
    if [ -t 2 ]; then
      curl -fL --progress-bar "${url}" -o "${output}"
    else
      curl -fsSL "${url}" -o "${output}"
    fi
  elif command -v wget &>/dev/null; then
    if [ -t 2 ]; then
      wget --show-progress -O "${output}" "${url}"
    else
      wget -qO "${output}" "${url}"
    fi
  else
    echo "Neither curl nor wget found. Please install one and retry." >&2
    exit 1
  fi
}

parse_checksum_file() {
  local checksum_file="$1"
  local expected_len="$2"
  local checksum

  checksum="$(awk 'NF {print $1; exit}' "${checksum_file}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  if [[ -n "${checksum}" && "${#checksum}" -eq "${expected_len}" && "${checksum}" =~ ^[0-9a-f]+$ ]]; then
    echo "${checksum}"
    return 0
  fi
  return 1
}

calc_local_checksum() {
  local algo="$1"
  local file="$2"
  local output checksum

  case "${algo}" in
    sha256)
      if command -v sha256sum &>/dev/null; then
        output="$(sha256sum "${file}")"
      elif command -v shasum &>/dev/null; then
        output="$(shasum -a 256 "${file}")"
      else
        return 1
      fi
      ;;
    md5)
      if command -v md5sum &>/dev/null; then
        output="$(md5sum "${file}")"
      elif command -v md5 &>/dev/null; then
        output="$(md5 -q "${file}")"
      else
        return 1
      fi
      ;;
    *)
      return 1
      ;;
  esac

  checksum="$(printf '%s\n' "${output}" | awk 'NF {print $1; exit}' | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  if [[ -n "${checksum}" ]]; then
    echo "${checksum}"
    return 0
  fi
  return 1
}

resolve_remote_checksum() {
  local binary_url="$1"
  local checksum_tmp checksum checksum_url algo expected_len

  checksum_tmp="$(mktemp)"
  for algo in sha256 md5; do
    if [ "${algo}" = "sha256" ]; then
      expected_len=64
      checksum_url="${binary_url}.sha256"
    else
      expected_len=32
      checksum_url="${binary_url}.md5"
    fi

    if download_file "${checksum_url}" "${checksum_tmp}" >/dev/null 2>&1; then
      if checksum="$(parse_checksum_file "${checksum_tmp}" "${expected_len}")"; then
        REMOTE_CHECKSUM_ALGO="${algo}"
        REMOTE_CHECKSUM_VALUE="${checksum}"
        rm -f "${checksum_tmp}"
        return 0
      fi
    fi
  done

  rm -f "${checksum_tmp}"
  return 1
}

# ---------------------------------------------------------------------------
# 1. Docker preflight checks
# ---------------------------------------------------------------------------
echo "Checking Docker installation..."
if ! command -v docker &>/dev/null; then
  echo "✗ Docker is not installed" >&2
  echo "Please install Docker first: https://docs.docker.com/get-docker/" >&2
  exit 1
fi
if ! docker info &>/dev/null; then
  echo "✗ Docker is not running" >&2
  echo "Please start Docker and try again" >&2
  exit 1
fi
echo "✓ Docker is installed and running"
echo ""

# Detect OS
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "${OS}" in
  linux)  OS="linux" ;;
  darwin) OS="darwin" ;;
  *)
    echo "Unsupported OS: ${OS}" >&2
    echo "magicrew currently supports Linux and macOS." >&2
    exit 1
    ;;
esac

# Detect architecture
ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64 | amd64) ARCH="amd64" ;;
  arm64 | aarch64) ARCH="arm64" ;;
  *)
    echo "Unsupported architecture: ${ARCH}" >&2
    exit 1
    ;;
esac

BINARY_URL="${RELEASE_BASE_URL}/${BINARY_NAME}-${OS}-${ARCH}"
CONFIG_URL="${BOOTSTRAP_BASE_URL}/config.yml"
VALUES_URL="${BOOTSTRAP_BASE_URL}/values.yaml"

echo "Installing magicrew (${OS}/${ARCH})..."

# Determine install path
if [ -w "${INSTALL_DIR}" ]; then
  DEST="${INSTALL_DIR}/${BINARY_NAME}"
  USE_SUDO=""
else
  DEST="${INSTALL_DIR}/${BINARY_NAME}"
  USE_SUDO="sudo"
fi

# Fallback to ~/.local/bin if /usr/local/bin is not writable even with sudo
if [ -z "${USE_SUDO}" ] || command -v sudo &>/dev/null; then
  : # can install to INSTALL_DIR
else
  INSTALL_DIR="${HOME}/.local/bin"
  DEST="${INSTALL_DIR}/${BINARY_NAME}"
  mkdir -p "${INSTALL_DIR}"
  USE_SUDO=""
fi

TMP=""
REMOTE_CHECKSUM_ALGO=""
REMOTE_CHECKSUM_VALUE=""
if [ -x "${DEST}" ]; then
  echo "Found existing local binary: ${DEST}"
else
  echo "No local binary found at ${DEST}"
fi
if resolve_remote_checksum "${BINARY_URL}"; then
  echo "Found remote ${REMOTE_CHECKSUM_ALGO} checksum for ${BINARY_NAME}"
else
  echo "No remote checksum file found (.sha256/.md5); will reinstall binary"
fi

NEED_DOWNLOAD=1
if [ -x "${DEST}" ]; then
  if [ -n "${REMOTE_CHECKSUM_ALGO}" ] && [ -n "${REMOTE_CHECKSUM_VALUE}" ]; then
    if LOCAL_CHECKSUM="$(calc_local_checksum "${REMOTE_CHECKSUM_ALGO}" "${DEST}")"; then
      if [ "${LOCAL_CHECKSUM}" = "${REMOTE_CHECKSUM_VALUE}" ]; then
        NEED_DOWNLOAD=0
      else
        echo "Existing binary checksum mismatch; will download latest binary"
      fi
    else
      echo "Unable to calculate local ${REMOTE_CHECKSUM_ALGO}; will download latest binary"
    fi
  else
    echo "Existing binary found but checksum is unavailable; will download latest binary"
  fi
fi

if [ "${NEED_DOWNLOAD}" -eq 1 ]; then
  TMP="$(mktemp)"
  trap 'rm -f "${TMP:-}"' EXIT

  echo "Downloading from ${BINARY_URL} ..."
  download_file "${BINARY_URL}" "${TMP}"

  if [ -n "${REMOTE_CHECKSUM_ALGO}" ] && [ -n "${REMOTE_CHECKSUM_VALUE}" ]; then
    if ! DOWNLOADED_CHECKSUM="$(calc_local_checksum "${REMOTE_CHECKSUM_ALGO}" "${TMP}")"; then
      echo "Failed to calculate downloaded file ${REMOTE_CHECKSUM_ALGO}" >&2
      exit 1
    fi
    if [ "${DOWNLOADED_CHECKSUM}" != "${REMOTE_CHECKSUM_VALUE}" ]; then
      echo "Checksum verification failed for downloaded binary (${REMOTE_CHECKSUM_ALGO})" >&2
      exit 1
    fi
    echo "✓ Downloaded binary ${REMOTE_CHECKSUM_ALGO} verified"
  fi

  chmod +x "${TMP}"
  ${USE_SUDO} mv "${TMP}" "${DEST}"
  echo "✓ magicrew installed to ${DEST}"
else
  echo "✓ magicrew already up-to-date at ${DEST}; skipping binary download"
fi

# ---------------------------------------------------------------------------
# 2. Download configuration files
# ---------------------------------------------------------------------------
echo ""
echo "Downloading configuration and values..."
mkdir -p "$(dirname "${CONFIG_FILE}")"
TMP_CONFIG="$(mktemp)"
TMP_VALUES="$(mktemp)"
trap 'rm -f "${TMP:-}" "${TMP_CONFIG:-}" "${TMP_VALUES:-}"' EXIT

download_file "${CONFIG_URL}" "${TMP_CONFIG}"
download_file "${VALUES_URL}" "${TMP_VALUES}"

mv "${TMP_CONFIG}" "${CONFIG_FILE}"
mv "${TMP_VALUES}" "${VALUES_FILE}"
echo "✓ Configuration saved to ${CONFIG_FILE}"
echo "✓ Values saved to ${VALUES_FILE}"

# ---------------------------------------------------------------------------
# 3. Run deploy with explicit config paths
# ---------------------------------------------------------------------------
# If image pulls must go through a proxy (for example, private network environments),
# set and export these variables before running this script:
#   export HTTP_PROXY=http://<proxy>:<port>
#   export HTTPS_PROXY=http://<proxy>:<port>
#   export NO_PROXY=localhost,127.0.0.1
# kind forwards these variables into node containers so containerd can pull control-plane images.
echo ""
echo "Starting deployment..."
"${DEST}" deploy --config "${CONFIG_FILE}" --values "${VALUES_FILE}"
