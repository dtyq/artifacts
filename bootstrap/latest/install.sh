#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# magicrew one-click installer
# Usage: curl https://<host>/install.sh | bash
# ---------------------------------------------------------------------------

BINARY_ASSET_NAME="magicrew-cli"
BIN_NAME="${MAGICREW_BIN_NAME:-magicrew}"
USER_INSTALL_DIR="${HOME}/.local/bin"
SYSTEM_INSTALL_DIR="/usr/local/bin"
INSTALL_DIR="${MAGICREW_CLI_INSTALL_DIR:-}"
USE_SUDO=""
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

init_colors() {
  C_RESET=""
  C_BOLD=""
  C_INFO=""
  C_STEP=""
  C_OK=""
  C_WARN=""
  C_ERR=""
  C_CHOICE=""
  C_DIM=""

  if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_INFO=$'\033[36m'
    C_STEP=$'\033[1;36m'
    C_OK=$'\033[32m'
    C_WARN=$'\033[33m'
    C_ERR=$'\033[31m'
    C_CHOICE=$'\033[35m'
    C_DIM=$'\033[2m'
  fi
}

print_section() { printf "\n%b[%s]%b %b%s%b\n" "${C_STEP}" "$1" "${C_RESET}" "${C_BOLD}" "$2" "${C_RESET}"; }
print_info() { printf "%b\n" "${C_INFO}  • $*${C_RESET}"; }
print_ok() { printf "%b\n" "${C_OK}  ✓ $*${C_RESET}"; }
print_warn() { printf "%b\n" "${C_WARN}  ! $*${C_RESET}"; }
print_err() { printf "%b\n" "${C_ERR}  ✗ $*${C_RESET}" >&2; }
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
      wget -O "${output}" "${url}"
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

choose_install_dir() {
  local user_dest="${USER_INSTALL_DIR}/${BIN_NAME}"
  local system_dest="${SYSTEM_INSTALL_DIR}/${BIN_NAME}"

  if [ -n "${INSTALL_DIR}" ]; then
    return 0
  fi

  # Reuse existing install location to avoid asking every run.
  if [ -x "${user_dest}" ] && [ ! -x "${system_dest}" ]; then
    INSTALL_DIR="${USER_INSTALL_DIR}"
    return 0
  fi
  if [ -x "${system_dest}" ] && [ ! -x "${user_dest}" ]; then
    INSTALL_DIR="${SYSTEM_INSTALL_DIR}"
    return 0
  fi
  if [ -x "${user_dest}" ] && [ -x "${system_dest}" ]; then
    INSTALL_DIR="${USER_INSTALL_DIR}"
    print_warn "Detected binaries in both install directories; using ${USER_INSTALL_DIR} by default."
    return 0
  fi

  INSTALL_DIR="${USER_INSTALL_DIR}"

  if [ ! -t 1 ] || [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
    return 0
  fi

  print_section "SETUP" "Choose install directory for ${BIN_NAME}"
  printf "%b\n" "${C_CHOICE}    [1] ${USER_INSTALL_DIR}${C_RESET} ${C_DIM}(recommended)${C_RESET}"
  printf "%b\n" "${C_CHOICE}    [2] ${SYSTEM_INSTALL_DIR}${C_RESET} ${C_WARN}(requires sudo/admin permission)${C_RESET}"
  printf "%b" "${C_INFO}    Enter choice [1/2]${C_RESET} ${C_DIM}(default: 1)${C_RESET}: " >/dev/tty

  local choice
  if IFS= read -r choice </dev/tty; then
    case "${choice}" in
      2)
        INSTALL_DIR="${SYSTEM_INSTALL_DIR}"
        ;;
      ""|1)
        INSTALL_DIR="${USER_INSTALL_DIR}"
        ;;
      *)
        print_err "Unrecognized choice: ${choice}."
        print_err "Please rerun and choose 1 or 2."
        exit 1
        ;;
    esac
  fi
}

ensure_install_dir_writable() {
  if [ -d "${INSTALL_DIR}" ]; then
    :
  elif mkdir -p "${INSTALL_DIR}" 2>/dev/null; then
    :
  elif [ "${INSTALL_DIR}" = "${SYSTEM_INSTALL_DIR}" ] && command -v sudo &>/dev/null; then
    USE_SUDO="sudo"
    ${USE_SUDO} mkdir -p "${INSTALL_DIR}"
  else
    print_err "Failed to create install directory: ${INSTALL_DIR}"
    print_err "Please set MAGICREW_CLI_INSTALL_DIR to a writable path and retry."
    exit 1
  fi

  if [ -w "${INSTALL_DIR}" ]; then
    USE_SUDO=""
    return 0
  fi

  if [ "${INSTALL_DIR}" = "${SYSTEM_INSTALL_DIR}" ]; then
    if command -v sudo &>/dev/null; then
      USE_SUDO="sudo"
      return 0
    fi
    print_err "No write permission to ${SYSTEM_INSTALL_DIR}, and sudo is not available."
    print_err "Please choose option 1 (${USER_INSTALL_DIR}),"
    print_err "or set MAGICREW_CLI_INSTALL_DIR to a writable directory."
  else
    print_err "No write permission to install directory: ${INSTALL_DIR}"
    print_err "Please set MAGICREW_CLI_INSTALL_DIR to a writable directory and retry."
  fi
  exit 1
}

check_docker_preflight() {
  if ! command -v docker &>/dev/null; then
    print_err "Docker is not installed."
    print_err "Please install Docker first: https://docs.docker.com/get-docker/"
    exit 1
  fi
  if ! docker info &>/dev/null; then
    print_err "Docker is not running."
    print_err "Please start Docker and try again"
    exit 1
  fi
  print_ok "Docker is installed and running."
}

check_optional_tools() {
  if command -v kubectl &>/dev/null; then
    print_ok "kubectl is available (optional, useful for managing the Kubernetes cluster)."
  else
    print_warn "kubectl is not installed (optional). Install it if you want to inspect/manage the Kubernetes cluster."
  fi
}

detect_platform() {
  OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "${OS}" in
    linux)  OS="linux" ;;
    darwin) OS="darwin" ;;
    *)
      print_err "Unsupported OS: ${OS}"
      print_err "magicrew currently supports Linux and macOS."
      exit 1
      ;;
  esac

  ARCH="$(uname -m)"
  case "${ARCH}" in
    x86_64 | amd64) ARCH="amd64" ;;
    arm64 | aarch64) ARCH="arm64" ;;
    *)
      print_err "Unsupported architecture: ${ARCH}"
      exit 1
      ;;
  esac
}

init_colors

# ---------------------------------------------------------------------------
# 1. Docker preflight checks
# ---------------------------------------------------------------------------
print_section "1/4" "Environment preflight"
check_docker_preflight
check_optional_tools

detect_platform

BINARY_URL="${RELEASE_BASE_URL}/${BINARY_ASSET_NAME}-${OS}-${ARCH}"
CONFIG_URL="${BOOTSTRAP_BASE_URL}/config.yml"
VALUES_URL="${BOOTSTRAP_BASE_URL}/values.yaml"

print_section "2/4" "Install magicrew (${OS}/${ARCH})"

# Determine install path
choose_install_dir
ensure_install_dir_writable
DEST="${INSTALL_DIR}/${BIN_NAME}"

TMP=""
REMOTE_CHECKSUM_ALGO=""
REMOTE_CHECKSUM_VALUE=""
if [ -x "${DEST}" ]; then
  print_info "Found existing local binary: ${DEST}"
else
  print_info "No local binary found at ${DEST}"
fi
if resolve_remote_checksum "${BINARY_URL}"; then
  print_info "Found remote ${REMOTE_CHECKSUM_ALGO} checksum for ${BIN_NAME}"
else
  print_warn "No remote checksum file found (.sha256/.md5); will reinstall binary."
fi

NEED_DOWNLOAD=1
if [ -x "${DEST}" ]; then
  if [ -n "${REMOTE_CHECKSUM_ALGO}" ] && [ -n "${REMOTE_CHECKSUM_VALUE}" ]; then
    if LOCAL_CHECKSUM="$(calc_local_checksum "${REMOTE_CHECKSUM_ALGO}" "${DEST}")"; then
      if [ "${LOCAL_CHECKSUM}" = "${REMOTE_CHECKSUM_VALUE}" ]; then
        NEED_DOWNLOAD=0
      else
        print_warn "Existing binary checksum mismatch; downloading latest binary."
      fi
    else
      print_warn "Unable to calculate local ${REMOTE_CHECKSUM_ALGO}; downloading latest binary."
    fi
  else
    print_warn "Existing binary found but checksum is unavailable; downloading latest binary."
  fi
fi

if [ "${NEED_DOWNLOAD}" -eq 1 ]; then
  TMP="$(mktemp)"
  trap 'rm -f "${TMP:-}"' EXIT

  if [ "${USE_SUDO}" = "sudo" ]; then
    print_warn "No write permission to ${SYSTEM_INSTALL_DIR}; using sudo to install."
  fi

  print_info "Downloading binary: ${BINARY_URL}"
  download_file "${BINARY_URL}" "${TMP}"

  if [ -n "${REMOTE_CHECKSUM_ALGO}" ] && [ -n "${REMOTE_CHECKSUM_VALUE}" ]; then
    if ! DOWNLOADED_CHECKSUM="$(calc_local_checksum "${REMOTE_CHECKSUM_ALGO}" "${TMP}")"; then
      print_err "Failed to calculate downloaded file ${REMOTE_CHECKSUM_ALGO}"
      exit 1
    fi
    if [ "${DOWNLOADED_CHECKSUM}" != "${REMOTE_CHECKSUM_VALUE}" ]; then
      print_err "Checksum verification failed for downloaded binary (${REMOTE_CHECKSUM_ALGO})"
      exit 1
    fi
    print_ok "Downloaded binary ${REMOTE_CHECKSUM_ALGO} verified."
  fi

  chmod +x "${TMP}"
  ${USE_SUDO} mv "${TMP}" "${DEST}"
  print_ok "Installed magicrew to ${DEST}."
else
  print_ok "magicrew already up-to-date at ${DEST}; skip binary download."
fi

if [ "${INSTALL_DIR}" = "${USER_INSTALL_DIR}" ]; then
  case ":${PATH}:" in
    *":${USER_INSTALL_DIR}:"*)
      ;;
    *)
      print_warn "Add ${USER_INSTALL_DIR} to PATH if it is not already available in your shell:"
      print_info "  export PATH=\"${USER_INSTALL_DIR}:\$PATH\""
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# 2. Download configuration files
# ---------------------------------------------------------------------------
print_section "3/4" "Download configuration files"
mkdir -p "$(dirname "${CONFIG_FILE}")"
TMP_CONFIG="$(mktemp)"
TMP_VALUES="$(mktemp)"
trap 'rm -f "${TMP:-}" "${TMP_CONFIG:-}" "${TMP_VALUES:-}"' EXIT

download_file "${CONFIG_URL}" "${TMP_CONFIG}"
download_file "${VALUES_URL}" "${TMP_VALUES}"

mv "${TMP_CONFIG}" "${CONFIG_FILE}"
mv "${TMP_VALUES}" "${VALUES_FILE}"
print_ok "Configuration saved to ${CONFIG_FILE}."
print_ok "Values saved to ${VALUES_FILE}."

# ---------------------------------------------------------------------------
# 3. Run deploy with explicit config paths
# ---------------------------------------------------------------------------
# If image pulls must go through a proxy (for example, private network environments),
# set and export these variables before running this script:
#   export HTTP_PROXY=http://<proxy>:<port>
#   export HTTPS_PROXY=http://<proxy>:<port>
#   export NO_PROXY=localhost,127.0.0.1
# kind forwards these variables into node containers so containerd can pull control-plane images.
print_section "4/4" "Start deployment"
"${DEST}" deploy --config "${CONFIG_FILE}" --values "${VALUES_FILE}"
