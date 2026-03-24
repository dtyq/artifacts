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
PROXY_ENV_FILE="${MAGICREW_CLI_PROXY_ENV_FILE:-${HOME}/.config/magicrew/proxy.env}"
PROXY_DOC_URL="${MAGICREW_CLI_PROXY_DOC_URL:-https://docs.docker.com/engine/daemon/proxy/}"
HOST_PROXY_URL="${MAGICREW_CLI_HOST_PROXY_URL:-}"

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

is_tty_interactive() {
  [ -t 1 ] && [ -r /dev/tty ] && [ -w /dev/tty ]
}

download_file() {
  local url="$1"
  local output="$2"
  local proxy_arg=()

  # Prefer explicit proxy for downloader to avoid environment propagation ambiguity.
  if [ -n "${HOST_PROXY_URL:-}" ]; then
    proxy_arg=(--proxy "${HOST_PROXY_URL}")
  fi

  if command -v curl &>/dev/null; then
    if [ -t 2 ]; then
      curl -fL --progress-bar "${proxy_arg[@]}" "${url}" -o "${output}"
    else
      curl -fsSL "${proxy_arg[@]}" "${url}" -o "${output}"
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

first_non_empty() {
  local value
  for value in "$@"; do
    if [ -n "${value}" ]; then
      printf "%s" "${value}"
      return 0
    fi
  done
  return 1
}

trim_space() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf "%s" "${s}"
}

merge_csv_values() {
  local current="$1"
  shift
  local out="" item token trimmed
  local -a result_list=()
  local -a _csv_current=()
  local seen_list=","

  add_unique_csv_item() {
    local raw="$1"
    trimmed="$(trim_space "${raw}")"
    if [ -z "${trimmed}" ]; then
      return 0
    fi
    token="$(printf "%s" "${trimmed}" | tr '[:upper:]' '[:lower:]')"
    case "${seen_list}" in
      *,"${token}",*) return 0 ;;
    esac
    seen_list="${seen_list}${token},"
    result_list+=("${trimmed}")
  }

  if [ -n "${current}" ]; then
    IFS=',' read -r -a _csv_current <<< "${current}" || true
    for item in "${_csv_current[@]}"; do
      add_unique_csv_item "${item}"
    done
  fi
  for item in "$@"; do
    add_unique_csv_item "${item}"
  done

  local i
  for ((i = 0; i < ${#result_list[@]}; i++)); do
    if [ "${i}" -gt 0 ]; then
      out+=","
    fi
    out+="${result_list[$i]}"
  done
  printf "%s" "${out}"
}

is_localhost_proxy_host() {
  local host
  host="$(printf "%s" "$1" | tr '[:upper:]' '[:lower:]')"
  case "${host}" in
    localhost|127.0.0.1|::1) return 0 ;;
    *) return 1 ;;
  esac
}

parse_proxy_url() {
  local input="$1"
  PROXY_SCHEME=""
  PROXY_AUTH=""
  PROXY_HOST=""
  PROXY_PORT=""
  PROXY_PATH=""

  if [ -z "${input}" ]; then
    return 1
  fi

  local rest hostport tail
  if [[ "${input}" == *"://"* ]]; then
    PROXY_SCHEME="${input%%://*}"
    rest="${input#*://}"
  else
    PROXY_SCHEME="http"
    rest="${input}"
  fi

  if [[ "${rest}" == *@* ]]; then
    PROXY_AUTH="${rest%%@*}"
    rest="${rest#*@}"
  fi

  if [[ "${rest}" == */* ]]; then
    hostport="${rest%%/*}"
    PROXY_PATH="/${rest#*/}"
  else
    hostport="${rest}"
    PROXY_PATH=""
  fi

  if [[ "${hostport}" == \[*\]* ]]; then
    PROXY_HOST="${hostport%%]*}"
    PROXY_HOST="${PROXY_HOST#[}"
    tail="${hostport#*]}"
    if [[ "${tail}" == :* ]]; then
      PROXY_PORT="${tail#:}"
    fi
  else
    if [[ "${hostport}" == *:* ]]; then
      PROXY_HOST="${hostport%%:*}"
      PROXY_PORT="${hostport##*:}"
    else
      PROXY_HOST="${hostport}"
      PROXY_PORT=""
    fi
  fi

  if [ -z "${PROXY_HOST}" ]; then
    return 1
  fi
  return 0
}

build_proxy_url() {
  local scheme="$1"
  local auth="$2"
  local host="$3"
  local port="$4"
  local path="$5"
  local url=""
  local host_rendered="${host}"
  if [[ "${host_rendered}" == *:* ]] && [[ "${host_rendered}" != \[*\] ]]; then
    host_rendered="[${host_rendered}]"
  fi
  url="${scheme}://"
  if [ -n "${auth}" ]; then
    url+="${auth}@"
  fi
  url+="${host_rendered}"
  if [ -n "${port}" ]; then
    url+=":${port}"
  fi
  url+="${path}"
  printf "%s" "${url}"
}

has_any_proxy_env() {
  [ -n "${HTTP_PROXY:-}" ] || [ -n "${HTTPS_PROXY:-}" ] || [ -n "${ALL_PROXY:-}" ] || [ -n "${http_proxy:-}" ] || [ -n "${https_proxy:-}" ] || [ -n "${all_proxy:-}" ]
}

set_proxy_env_all_cases() {
  local proxy_url="$1"
  local no_proxy_csv="$2"
  export HTTP_PROXY="${proxy_url}"
  export HTTPS_PROXY="${proxy_url}"
  export ALL_PROXY="${proxy_url}"
  export http_proxy="${proxy_url}"
  export https_proxy="${proxy_url}"
  export all_proxy="${proxy_url}"
  export NO_PROXY="${no_proxy_csv}"
  export no_proxy="${no_proxy_csv}"
}

apply_proxy_url_with_current_no_proxy() {
  local proxy_url="$1"
  local no_proxy_csv
  no_proxy_csv="$(merge_csv_values "${NO_PROXY:-${no_proxy:-}}" \
    "localhost" "127.0.0.1" "::1" "host.docker.internal" ".internal" ".local" \
    "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16")"
  set_proxy_env_all_cases "${proxy_url}" "${no_proxy_csv}"
}

ensure_default_no_proxy() {
  local merged
  merged="$(merge_csv_values "${NO_PROXY:-${no_proxy:-}}" \
    "localhost" "127.0.0.1" "::1" "host.docker.internal" ".internal" ".local" \
    "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16")"
  export NO_PROXY="${merged}"
  export no_proxy="${merged}"
}

prompt_yes_no_tty() {
  local message="$1"
  local default_answer="$2" # y or n
  local prompt_suffix=""
  local reply=""
  if [ "${default_answer}" = "y" ]; then
    prompt_suffix="[Y/n]"
  else
    prompt_suffix="[y/N]"
  fi
  while true; do
    printf "%b" "${C_INFO}    ${message} ${prompt_suffix}: ${C_RESET}" >/dev/tty
    if ! IFS= read -r reply </dev/tty; then
      return 1
    fi
    reply="$(trim_space "${reply}")"
    if [ -z "${reply}" ]; then
      reply="${default_answer}"
    fi
    case "${reply}" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
    esac
    print_warn "Please enter y or n."
  done
}

prompt_value_tty() {
  local message="$1"
  local value=""
  printf "%b" "${C_INFO}    ${message}: ${C_RESET}" >/dev/tty
  if IFS= read -r value </dev/tty; then
    printf "%s" "${value}"
    return 0
  fi
  return 1
}

check_proxy_reachable() {
  local proxy_url="$1"
  local target code
  local required_target="https://github.com"
  local targets=(
    "https://www.magicrew.ai"
  )

  # github.com is required because installer binaries are downloaded from GitHub Releases.
  code="$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 15 --proxy "${proxy_url}" "${required_target}" || true)"
  if [[ "${code}" == "" || "${code}" == "000" ]]; then
    return 1
  fi
  print_ok "Proxy connectivity check passed via ${required_target} (HTTP ${code})."

  for target in "${targets[@]}"; do
    if [ "${target}" = "${required_target}" ]; then
      continue
    fi
    code="$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 15 --proxy "${proxy_url}" "${target}" || true)"
    if [[ "${code}" != "" && "${code}" != "000" ]]; then
      print_ok "Proxy connectivity check passed via ${target} (HTTP ${code})."
    fi
  done
  return 0
}


save_proxy_env_file() {
  local host_proxy_url="$1"
  local no_proxy_csv="$2"
  local dir
  dir="$(dirname "${PROXY_ENV_FILE}")"
  mkdir -p "${dir}"
  cat > "${PROXY_ENV_FILE}" <<EOF
HTTP_PROXY=${host_proxy_url}
HTTPS_PROXY=${host_proxy_url}
ALL_PROXY=${host_proxy_url}
NO_PROXY=${no_proxy_csv}
http_proxy=${host_proxy_url}
https_proxy=${host_proxy_url}
all_proxy=${host_proxy_url}
no_proxy=${no_proxy_csv}
MAGICREW_CLI_HOST_PROXY_URL=${host_proxy_url}
EOF
  chmod 600 "${PROXY_ENV_FILE}"
}

parse_proxy_env_line() {
  local line="$1"
  line="$(trim_space "${line}")"
  if [ -z "${line}" ] || [[ "${line}" == \#* ]]; then
    return 1
  fi

  if [[ "${line}" != *=* ]]; then
    return 1
  fi

  local key="${line%%=*}"
  local value="${line#*=}"
  key="$(trim_space "${key}")"
  value="$(trim_space "${value}")"
  case "${key}" in
    HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY|http_proxy|https_proxy|all_proxy|no_proxy|MAGICREW_CLI_HOST_PROXY_URL) ;;
    *) return 1 ;;
  esac

  if [[ "${value}" == \"*\" ]] && [[ "${value}" == *\" ]]; then
    value="${value#\"}"
    value="${value%\"}"
  elif [[ "${value}" == \'*\' ]]; then
    value="${value#\'}"
    value="${value%\'}"
  fi

  PROXY_ENV_KEY="${key}"
  PROXY_ENV_VALUE="${value}"
  return 0
}

load_proxy_env_file_if_exists() {
  local line key value
  local loaded=0
  if [ ! -f "${PROXY_ENV_FILE}" ]; then
    return 1
  fi

  while IFS= read -r line || [ -n "${line}" ]; do
    if parse_proxy_env_line "${line}"; then
      key="${PROXY_ENV_KEY}"
      value="${PROXY_ENV_VALUE}"
      export "${key}=${value}"
      loaded=1
    fi
  done < "${PROXY_ENV_FILE}"

  if [ "${loaded}" -eq 1 ]; then
    if [ -n "${MAGICREW_CLI_HOST_PROXY_URL:-}" ]; then
      HOST_PROXY_URL="${MAGICREW_CLI_HOST_PROXY_URL}"
    else
      HOST_PROXY_URL="$(first_non_empty "${HTTP_PROXY:-}" "${http_proxy:-}" "${HTTPS_PROXY:-}" "${https_proxy:-}" "${ALL_PROXY:-}" "${all_proxy:-}" || true)"
    fi
    ensure_default_no_proxy
    return 0
  fi
  return 1
}

docker_proxy_smoke_test() {
  local timeout_sec="${MAGICREW_CLI_DOCKER_SMOKE_TIMEOUT_SECONDS:-20}"
  case "${timeout_sec}" in
    ''|*[!0-9]*)
      timeout_sec=20
      ;;
    *)
      if [ "${timeout_sec}" -le 0 ]; then
        timeout_sec=20
      fi
      ;;
  esac

  local timeout_flag
  timeout_flag="$(mktemp)"
  rm -f "${timeout_flag}"

  docker run --rm --pull always alpine:latest true >/dev/null 2>&1 &
  local pid="$!"
  (
    sleep "${timeout_sec}"
    if kill -0 "${pid}" 2>/dev/null; then
      printf "1" > "${timeout_flag}"
      kill "${pid}" 2>/dev/null || true
    fi
  ) &
  local watcher_pid="$!"

  wait "${pid}"
  local run_exit_code=$?
  kill "${watcher_pid}" 2>/dev/null || true
  wait "${watcher_pid}" 2>/dev/null || true

  local timed_out=0
  if [ -f "${timeout_flag}" ]; then
    timed_out=1
  fi
  rm -f "${timeout_flag}"

  if [ "${run_exit_code}" -eq 0 ]; then
    print_ok "Docker daemon network check passed (docker run --pull always alpine:latest true)."
    return 0
  fi
  if [ "${timed_out}" -eq 1 ]; then
    print_warn "Docker daemon network check timed out after ${timeout_sec}s."
  else
    print_warn "Docker daemon network check failed (docker run --pull always alpine:latest true)."
  fi
  print_warn "This check does not delete local images."
  print_warn "You may need to configure Docker daemon proxy settings:"
  print_info "${PROXY_DOC_URL}"
  return 1
}

setup_proxy_env_if_needed() {
  local proxy_candidate=""
  local no_proxy_csv=""

  if has_any_proxy_env; then
    ensure_default_no_proxy
    HOST_PROXY_URL="$(first_non_empty "${HTTP_PROXY:-}" "${http_proxy:-}" "${HTTPS_PROXY:-}" "${https_proxy:-}" "${ALL_PROXY:-}" "${all_proxy:-}" || true)"
    print_ok "Detected proxy environment variables in current shell."
    return 0
  fi

  if load_proxy_env_file_if_exists; then
    print_ok "Loaded proxy settings from ${PROXY_ENV_FILE}."
    if [ -z "${HOST_PROXY_URL}" ]; then
      HOST_PROXY_URL="$(first_non_empty "${HTTP_PROXY:-}" "${http_proxy:-}" "${HTTPS_PROXY:-}" "${https_proxy:-}" "${ALL_PROXY:-}" "${all_proxy:-}" || true)"
    fi
    return 0
  fi

  if ! is_tty_interactive; then
    print_warn "No proxy env detected and interactive TTY unavailable."
    print_warn "Will continue without proxy setup."
    return 0
  fi

  print_warn "No proxy env detected. Without a proxy, deployment may fail in restricted networks."
  if ! prompt_yes_no_tty "Configure terminal proxy now?" "y"; then
    print_warn "Skipped proxy setup by user choice."
    return 0
  fi

  while true; do
    proxy_candidate="$(prompt_value_tty "Enter proxy URL (example: http://host:port)")" || return 0
    proxy_candidate="$(trim_space "${proxy_candidate}")"
    if [ -z "${proxy_candidate}" ]; then
      print_warn "Proxy URL cannot be empty."
      continue
    fi
    if ! parse_proxy_url "${proxy_candidate}"; then
      print_warn "Cannot parse proxy URL. Please retry."
      continue
    fi
    proxy_candidate="$(build_proxy_url "${PROXY_SCHEME}" "${PROXY_AUTH}" "${PROXY_HOST}" "${PROXY_PORT}" "${PROXY_PATH}")"
    break
  done

  if ! check_proxy_reachable "${proxy_candidate}"; then
    print_warn "Proxy connectivity check failed for all probe targets."
    if ! prompt_yes_no_tty "Continue with this proxy anyway?" "y"; then
      print_warn "Skipped proxy setup by user choice."
      return 0
    fi
  fi

  no_proxy_csv="$(merge_csv_values "" \
    "localhost" "127.0.0.1" "::1" "host.docker.internal" ".internal" \
    "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16")"
  HOST_PROXY_URL="${proxy_candidate}"
  apply_proxy_url_with_current_no_proxy "${HOST_PROXY_URL}"
  print_ok "Host proxy environment variables exported for current installer session."

  no_proxy_csv="${NO_PROXY:-${no_proxy:-${no_proxy_csv}}}"

  save_proxy_env_file "${HOST_PROXY_URL}" "${no_proxy_csv}"
  print_ok "Saved proxy configuration to ${PROXY_ENV_FILE}."
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
  local docker_client_version=""
  local docker_server_version=""
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
  docker_client_version="$(docker version --format '{{.Client.Version}}' 2>/dev/null || true)"
  docker_server_version="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
  if [ -n "${docker_client_version}" ] && [ -n "${docker_server_version}" ]; then
    print_ok "Docker is installed and running (client ${docker_client_version}, server ${docker_server_version})."
  elif [ -n "${docker_client_version}" ]; then
    print_ok "Docker is installed and running (client ${docker_client_version})."
  else
    print_ok "Docker is installed and running."
  fi
}

check_optional_tools() {
  if command -v kubectl &>/dev/null; then
    local kubectl_version=""
    kubectl_version="$(kubectl version --client --short 2>/dev/null || true)"
    if [ -z "${kubectl_version}" ]; then
      kubectl_version="$(kubectl version --client 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g' | sed 's/[[:space:]]*$//')"
    fi
    if [ -n "${kubectl_version}" ]; then
      print_ok "kubectl is available (${kubectl_version})."
    else
      print_ok "kubectl is available (optional, useful for managing the Kubernetes cluster)."
    fi
  else
    print_warn "kubectl is not installed (optional). Install it if you want to inspect/manage the Kubernetes cluster."
  fi
}

print_environment_info() {
  local kernel_info host_arch
  kernel_info="$(uname -sr)"
  host_arch="$(uname -m)"
  print_info "Kernel: ${kernel_info}, machine: ${host_arch}"
}

print_binary_sha256() {
  local file="$1"
  local label="$2"
  local binary_sha256=""
  if [ ! -f "${file}" ]; then
    return 0
  fi
  if binary_sha256="$(calc_local_checksum "sha256" "${file}")"; then
    print_info "${label} sha256: ${binary_sha256}"
  else
    print_warn "Unable to calculate ${label} sha256."
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
# 1. Environment preflight checks
# ---------------------------------------------------------------------------
detect_platform

print_section "1/5" "Environment preflight"
print_environment_info
check_docker_preflight
check_optional_tools

# ---------------------------------------------------------------------------
# 2. Proxy setup and docker daemon network check
# ---------------------------------------------------------------------------
print_section "2/5" "Proxy setup"
setup_proxy_env_if_needed
docker_proxy_smoke_test || true

BINARY_URL="${RELEASE_BASE_URL}/${BINARY_ASSET_NAME}-${OS}-${ARCH}"
CONFIG_URL="${BOOTSTRAP_BASE_URL}/config.yml"
VALUES_URL="${BOOTSTRAP_BASE_URL}/values.yaml"

print_section "3/5" "Install magicrew (${OS}/${ARCH})"

# Determine install path
choose_install_dir
ensure_install_dir_writable
DEST="${INSTALL_DIR}/${BIN_NAME}"

TMP=""
REMOTE_CHECKSUM_ALGO=""
REMOTE_CHECKSUM_VALUE=""
if [ -x "${DEST}" ]; then
  print_info "Found existing local binary: ${DEST}"
  print_binary_sha256 "${DEST}" "Existing ${BIN_NAME} binary"
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
  print_binary_sha256 "${DEST}" "Installed ${BIN_NAME} binary"
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
# 4. Download configuration files
# ---------------------------------------------------------------------------
print_section "4/5" "Download configuration files"
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
# 5. Run deploy with explicit config paths
# ---------------------------------------------------------------------------
# If image pulls must go through a proxy (for example, private network environments),
# set and export these variables before running this script:
#   export HTTP_PROXY=http://<proxy>:<port>
#   export HTTPS_PROXY=http://<proxy>:<port>
#   export NO_PROXY=localhost,127.0.0.1
# kind forwards these variables into node containers so containerd can pull control-plane images.
print_section "5/5" "Start deployment"
"${DEST}" deploy --config "${CONFIG_FILE}" --values "${VALUES_FILE}"
