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
USER_LANG="${MAGICREW_CLI_LANG:-}"
LANG_PREF_FILE="${MAGICREW_CLI_LANG_PREF_FILE:-${HOME}/.config/magicrew/lang.env}"

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

normalize_lang() {
  local raw="${1:-}"
  raw="$(printf "%s" "${raw}" | tr '[:upper:]' '[:lower:]')"
  case "${raw}" in
    zh|zh_*|zh-*|cn|chinese) printf "zh" ;;
    en|en_*|en-*|english) printf "en" ;;
    "") printf "" ;;
    *) printf "en" ;;
  esac
}

detect_system_lang() {
  local candidate=""
  candidate="$(first_non_empty "${LC_ALL:-}" "${LC_MESSAGES:-}" "${LANG:-}" || true)"
  if [ -z "${candidate}" ] && [ "$(uname -s)" = "Darwin" ] && command -v defaults &>/dev/null; then
    candidate="$(defaults read -g AppleLocale 2>/dev/null || true)"
  fi
  candidate="$(normalize_lang "${candidate}")"
  if [ -z "${candidate}" ]; then
    candidate="en"
  fi
  printf "%s" "${candidate}"
}

load_saved_lang_preference() {
  local line
  local normalized=""
  if [ ! -f "${LANG_PREF_FILE}" ]; then
    return 1
  fi

  while IFS= read -r line || [ -n "${line}" ]; do
    line="$(trim_space "${line}")"
    if [ -z "${line}" ] || [[ "${line}" == \#* ]]; then
      continue
    fi

    normalized="$(normalize_lang "${line}")"
    if [ -n "${normalized}" ]; then
      printf "%s" "${normalized}"
      return 0
    fi
  done < "${LANG_PREF_FILE}"

  return 1
}

save_user_lang_preference() {
  local lang="$1"
  local dir
  lang="$(normalize_lang "${lang}")"
  if [ -z "${lang}" ]; then
    return 1
  fi
  dir="$(dirname "${LANG_PREF_FILE}")"
  mkdir -p "${dir}"
  printf "%s\n" "${lang}" > "${LANG_PREF_FILE}"
  chmod 600 "${LANG_PREF_FILE}"
}

msg() {
  local key="$1"
  case "${USER_LANG}:${key}" in
    zh:lang_select_prompt) echo "Select / 选择 (default: %s - %s): " ;;
    en:lang_select_prompt) echo "Select / 选择 (default: %s - %s): " ;;
    zh:lang_invalid_choice) echo "Invalid choice, please enter 1 or 2 / 输入无效，请输入 1 或 2" ;;
    en:lang_invalid_choice) echo "Invalid choice, please enter 1 or 2 / 输入无效，请输入 1 或 2" ;;
    zh:prompt_yes_no_invalid) echo "请输入 y 或 n。" ;;
    en:prompt_yes_no_invalid) echo "Please enter y or n." ;;
    zh:section_preflight) echo "环境预检" ;;
    en:section_preflight) echo "Environment preflight" ;;
    zh:section_proxy_setup) echo "代理设置" ;;
    en:section_proxy_setup) echo "Proxy setup" ;;
    zh:section_install) echo "安装 magicrew (%s/%s)" ;;
    en:section_install) echo "Install magicrew (%s/%s)" ;;
    zh:section_download_config) echo "下载配置文件" ;;
    en:section_download_config) echo "Download configuration files" ;;
    zh:section_start_deploy) echo "开始部署" ;;
    en:section_start_deploy) echo "Start deployment" ;;
    zh:err_unsupported_os) echo "不支持的操作系统: %s" ;;
    en:err_unsupported_os) echo "Unsupported OS: %s" ;;
    zh:err_support_scope) echo "magicrew 当前仅支持 Linux 和 macOS。" ;;
    en:err_support_scope) echo "magicrew currently supports Linux and macOS." ;;
    zh:err_unsupported_arch) echo "不支持的架构: %s" ;;
    en:err_unsupported_arch) echo "Unsupported architecture: %s" ;;
    zh:err_docker_not_installed) echo "未安装 Docker。" ;;
    en:err_docker_not_installed) echo "Docker is not installed." ;;
    zh:err_install_docker_hint) echo "请先安装 Docker: https://docs.docker.com/get-docker/" ;;
    en:err_install_docker_hint) echo "Please install Docker first: https://docs.docker.com/get-docker/" ;;
    zh:err_docker_not_running) echo "Docker 未运行。" ;;
    en:err_docker_not_running) echo "Docker is not running." ;;
    zh:err_start_docker_hint) echo "请先启动 Docker 后重试" ;;
    en:err_start_docker_hint) echo "Please start Docker and try again" ;;
    zh:err_missing_downloader) echo "未检测到 curl 或 wget，请安装其一后重试。" ;;
    en:err_missing_downloader) echo "Neither curl nor wget found. Please install one and retry." ;;
    zh:ok_proxy_check_passed) echo "代理连通性检测通过: %s (HTTP %s)。" ;;
    en:ok_proxy_check_passed) echo "Proxy connectivity check passed via %s (HTTP %s)." ;;
    zh:ok_docker_network_check_passed) echo "Docker daemon 网络检测通过 (docker run --pull always alpine:latest true)。" ;;
    en:ok_docker_network_check_passed) echo "Docker daemon network check passed (docker run --pull always alpine:latest true)." ;;
    zh:warn_docker_network_check_timeout) echo "Docker daemon 网络检测超时（%ss）。" ;;
    en:warn_docker_network_check_timeout) echo "Docker daemon network check timed out after %ss." ;;
    zh:warn_docker_network_check_failed) echo "Docker daemon 网络检测失败 (docker run --pull always alpine:latest true)。" ;;
    en:warn_docker_network_check_failed) echo "Docker daemon network check failed (docker run --pull always alpine:latest true)." ;;
    zh:warn_docker_network_no_delete) echo "该检查不会删除本地镜像。" ;;
    en:warn_docker_network_no_delete) echo "This check does not delete local images." ;;
    zh:warn_docker_proxy_hint) echo "你可能需要配置 Docker daemon 代理：" ;;
    en:warn_docker_proxy_hint) echo "You may need to configure Docker daemon proxy settings:" ;;
    zh:ok_proxy_env_detected) echo "检测到当前 shell 已设置代理环境变量。" ;;
    en:ok_proxy_env_detected) echo "Detected proxy environment variables in current shell." ;;
    zh:ok_proxy_env_loaded) echo "已从 %s 加载代理配置。" ;;
    en:ok_proxy_env_loaded) echo "Loaded proxy settings from %s." ;;
    zh:warn_no_proxy_no_tty) echo "未检测到代理环境变量，且当前无可交互 TTY。" ;;
    en:warn_no_proxy_no_tty) echo "No proxy env detected and interactive TTY unavailable." ;;
    zh:warn_continue_without_proxy) echo "将继续执行且不配置代理。" ;;
    en:warn_continue_without_proxy) echo "Will continue without proxy setup." ;;
    zh:warn_proxy_recommended) echo "未检测到代理环境变量。在受限网络下，不配置代理可能导致部署失败。" ;;
    en:warn_proxy_recommended) echo "No proxy env detected. Without a proxy, deployment may fail in restricted networks." ;;
    zh:prompt_configure_proxy_now) echo "现在配置终端代理？" ;;
    en:prompt_configure_proxy_now) echo "Configure terminal proxy now?" ;;
    zh:warn_proxy_skipped) echo "已按用户选择跳过代理配置。" ;;
    en:warn_proxy_skipped) echo "Skipped proxy setup by user choice." ;;
    zh:prompt_enter_proxy_url) echo "请输入代理 URL（示例: http://host:port）" ;;
    en:prompt_enter_proxy_url) echo "Enter proxy URL (example: http://host:port)" ;;
    zh:warn_proxy_empty) echo "代理 URL 不能为空。" ;;
    en:warn_proxy_empty) echo "Proxy URL cannot be empty." ;;
    zh:warn_proxy_parse_failed) echo "无法解析代理 URL，请重试。" ;;
    en:warn_proxy_parse_failed) echo "Cannot parse proxy URL. Please retry." ;;
    zh:warn_proxy_probe_failed) echo "所有探测目标的代理连通性检测均失败。" ;;
    en:warn_proxy_probe_failed) echo "Proxy connectivity check failed for all probe targets." ;;
    zh:prompt_continue_proxy_anyway) echo "仍然使用该代理继续？" ;;
    en:prompt_continue_proxy_anyway) echo "Continue with this proxy anyway?" ;;
    zh:ok_proxy_exported) echo "已为当前安装会话导出宿主机代理环境变量。" ;;
    en:ok_proxy_exported) echo "Host proxy environment variables exported for current installer session." ;;
    zh:ok_proxy_saved) echo "已将代理配置保存到 %s。" ;;
    en:ok_proxy_saved) echo "Saved proxy configuration to %s." ;;
    zh:warn_dual_binaries) echo "在两个安装目录都检测到二进制；默认使用 %s。" ;;
    en:warn_dual_binaries) echo "Detected binaries in both install directories; using %s by default." ;;
    zh:section_setup) echo "安装设置" ;;
    en:section_setup) echo "SETUP" ;;
    zh:setup_choose_install_dir) echo "选择 %s 的安装目录" ;;
    en:setup_choose_install_dir) echo "Choose install directory for %s" ;;
    zh:setup_option_user_dir) echo "[1] %s（推荐）" ;;
    en:setup_option_user_dir) echo "[1] %s (recommended)" ;;
    zh:setup_option_system_dir) echo "[2] %s（需要 sudo/管理员权限）" ;;
    en:setup_option_system_dir) echo "[2] %s (requires sudo/admin permission)" ;;
    zh:setup_choose_prompt) echo "请输入选项 [1/2]（默认: 1）: " ;;
    en:setup_choose_prompt) echo "Enter choice [1/2] (default: 1): " ;;
    zh:err_unrecognized_choice) echo "无法识别的选项: %s。" ;;
    en:err_unrecognized_choice) echo "Unrecognized choice: %s." ;;
    zh:err_rerun_choose_1_2) echo "请重新运行并输入 1 或 2。" ;;
    en:err_rerun_choose_1_2) echo "Please rerun and choose 1 or 2." ;;
    zh:err_create_install_dir) echo "创建安装目录失败: %s" ;;
    en:err_create_install_dir) echo "Failed to create install directory: %s" ;;
    zh:err_set_install_dir_retry) echo "请将 MAGICREW_CLI_INSTALL_DIR 设置为可写路径后重试。" ;;
    en:err_set_install_dir_retry) echo "Please set MAGICREW_CLI_INSTALL_DIR to a writable path and retry." ;;
    zh:err_no_write_system_no_sudo) echo "%s 无写权限，且系统中无 sudo。" ;;
    en:err_no_write_system_no_sudo) echo "No write permission to %s, and sudo is not available." ;;
    zh:err_choose_option_1) echo "请使用选项 1（%s），" ;;
    en:err_choose_option_1) echo "Please choose option 1 (%s)," ;;
    zh:err_or_set_install_dir) echo "或将 MAGICREW_CLI_INSTALL_DIR 设置为可写目录。" ;;
    en:err_or_set_install_dir) echo "or set MAGICREW_CLI_INSTALL_DIR to a writable directory." ;;
    zh:err_no_write_install_dir) echo "安装目录无写权限: %s" ;;
    en:err_no_write_install_dir) echo "No write permission to install directory: %s" ;;
    zh:ok_docker_running_client_server) echo "Docker 已安装并运行（client %s, server %s）。" ;;
    en:ok_docker_running_client_server) echo "Docker is installed and running (client %s, server %s)." ;;
    zh:ok_docker_running_client) echo "Docker 已安装并运行（client %s）。" ;;
    en:ok_docker_running_client) echo "Docker is installed and running (client %s)." ;;
    zh:ok_docker_running) echo "Docker 已安装并运行。" ;;
    en:ok_docker_running) echo "Docker is installed and running." ;;
    zh:ok_kubectl_available_version) echo "kubectl 可用（%s）。" ;;
    en:ok_kubectl_available_version) echo "kubectl is available (%s)." ;;
    zh:ok_kubectl_available_optional) echo "kubectl 可用（可选，便于管理 Kubernetes 集群）。" ;;
    en:ok_kubectl_available_optional) echo "kubectl is available (optional, useful for managing the Kubernetes cluster)." ;;
    zh:warn_kubectl_missing_optional) echo "kubectl 未安装（可选）。如需巡检/管理 Kubernetes 集群，建议安装。" ;;
    en:warn_kubectl_missing_optional) echo "kubectl is not installed (optional). Install it if you want to inspect/manage the Kubernetes cluster." ;;
    zh:info_kernel_machine) echo "内核: %s, 架构: %s" ;;
    en:info_kernel_machine) echo "Kernel: %s, machine: %s" ;;
    zh:info_label_sha256) echo "%s sha256: %s" ;;
    en:info_label_sha256) echo "%s sha256: %s" ;;
    zh:warn_sha256_unavailable) echo "无法计算 %s 的 sha256。" ;;
    en:warn_sha256_unavailable) echo "Unable to calculate %s sha256." ;;
    zh:info_found_local_binary) echo "检测到本地已存在二进制: %s" ;;
    en:info_found_local_binary) echo "Found existing local binary: %s" ;;
    zh:info_no_local_binary) echo "在 %s 未发现本地二进制" ;;
    en:info_no_local_binary) echo "No local binary found at %s" ;;
    zh:info_found_remote_checksum) echo "已获取 %s 的远端 %s 校验值" ;;
    en:info_found_remote_checksum) echo "Found remote %s checksum for %s" ;;
    zh:warn_no_remote_checksum) echo "未找到远端校验文件（.sha256/.md5）；将重新安装二进制。" ;;
    en:warn_no_remote_checksum) echo "No remote checksum file found (.sha256/.md5); will reinstall binary." ;;
    zh:warn_existing_checksum_mismatch) echo "现有二进制校验不匹配；将下载最新二进制。" ;;
    en:warn_existing_checksum_mismatch) echo "Existing binary checksum mismatch; downloading latest binary." ;;
    zh:warn_local_checksum_unavailable) echo "无法计算本地 %s；将下载最新二进制。" ;;
    en:warn_local_checksum_unavailable) echo "Unable to calculate local %s; downloading latest binary." ;;
    zh:warn_existing_no_checksum) echo "检测到已有二进制但无可用校验值；将下载最新二进制。" ;;
    en:warn_existing_no_checksum) echo "Existing binary found but checksum is unavailable; downloading latest binary." ;;
    zh:warn_system_dir_need_sudo) echo "%s 无写权限；将使用 sudo 安装。" ;;
    en:warn_system_dir_need_sudo) echo "No write permission to %s; using sudo to install." ;;
    zh:info_downloading_binary) echo "正在下载二进制: %s" ;;
    en:info_downloading_binary) echo "Downloading binary: %s" ;;
    zh:err_download_checksum_calc) echo "计算下载文件 %s 失败" ;;
    en:err_download_checksum_calc) echo "Failed to calculate downloaded file %s" ;;
    zh:err_download_checksum_verify) echo "下载二进制校验失败（%s）" ;;
    en:err_download_checksum_verify) echo "Checksum verification failed for downloaded binary (%s)" ;;
    zh:ok_download_checksum_verified) echo "下载二进制 %s 校验通过。" ;;
    en:ok_download_checksum_verified) echo "Downloaded binary %s verified." ;;
    zh:ok_installed_to_dest) echo "已安装 magicrew 到 %s。" ;;
    en:ok_installed_to_dest) echo "Installed magicrew to %s." ;;
    zh:ok_already_up_to_date) echo "magicrew 在 %s 已是最新；跳过二进制下载。" ;;
    en:ok_already_up_to_date) echo "magicrew already up-to-date at %s; skip binary download." ;;
    zh:warn_add_path_hint) echo "如当前 shell 尚未生效，请将 %s 加入 PATH：" ;;
    en:warn_add_path_hint) echo "Add %s to PATH if it is not already available in your shell:" ;;
    zh:info_export_path_cmd) echo "  export PATH=\"%s:\$PATH\"" ;;
    en:info_export_path_cmd) echo "  export PATH=\"%s:\$PATH\"" ;;
    zh:ok_config_saved) echo "配置文件已保存到 %s。" ;;
    en:ok_config_saved) echo "Configuration saved to %s." ;;
    zh:ok_values_saved) echo "Values 文件已保存到 %s。" ;;
    en:ok_values_saved) echo "Values saved to %s." ;;
    *)
      # Fallback to key to avoid hard failure on missing translations.
      echo "${key}"
      ;;
  esac
}

select_user_lang_if_tty() {
  local detected_lang="$1"
  local default_choice="1"
  local default_label="English"
  local choice=""

  case "${detected_lang}" in
    zh)
      default_choice="2"
      default_label="中文"
      ;;
  esac

  USER_LANG="${detected_lang}"

  if ! is_tty_interactive; then
    return 0
  fi

  while true; do
    printf "%b\n" "${C_INFO}  • Language / 语言${C_RESET}" >/dev/tty
    printf "%b\n" "${C_INFO}    [1] English${C_RESET}" >/dev/tty
    printf "%b\n" "${C_INFO}    [2] 中文${C_RESET}" >/dev/tty
    printf "%b" "${C_INFO}    $(printf "$(msg lang_select_prompt)" "${default_choice}" "${default_label}")${C_RESET}" >/dev/tty
    if ! IFS= read -r choice </dev/tty; then
      return 1
    fi

    choice="$(trim_space "${choice}")"
    if [ -z "${choice}" ]; then
      choice="${default_choice}"
    fi

    case "${choice}" in
      1|en|EN|english|English)
        USER_LANG="en"
        save_user_lang_preference "${USER_LANG}" || true
        return 0
        ;;
      2|zh|ZH|cn|CN|chinese|Chinese|中文)
        USER_LANG="zh"
        save_user_lang_preference "${USER_LANG}" || true
        return 0
        ;;
    esac
    printf "%b\n" "${C_WARN}  ! $(msg lang_invalid_choice)${C_RESET}" >/dev/tty
  done
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
    echo "$(msg err_missing_downloader)" >&2
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
    print_warn "$(msg prompt_yes_no_invalid)"
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
  print_ok "$(printf "$(msg ok_proxy_check_passed)" "${required_target}" "${code}")"

  for target in "${targets[@]}"; do
    if [ "${target}" = "${required_target}" ]; then
      continue
    fi
    code="$(curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 15 --proxy "${proxy_url}" "${target}" || true)"
    if [[ "${code}" != "" && "${code}" != "000" ]]; then
      print_ok "$(printf "$(msg ok_proxy_check_passed)" "${target}" "${code}")"
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
    print_ok "$(msg ok_docker_network_check_passed)"
    return 0
  fi
  if [ "${timed_out}" -eq 1 ]; then
    print_warn "$(printf "$(msg warn_docker_network_check_timeout)" "${timeout_sec}")"
  else
    print_warn "$(msg warn_docker_network_check_failed)"
  fi
  print_warn "$(msg warn_docker_network_no_delete)"
  print_warn "$(msg warn_docker_proxy_hint)"
  print_info "${PROXY_DOC_URL}"
  return 1
}

setup_proxy_env_if_needed() {
  local proxy_candidate=""
  local no_proxy_csv=""

  if has_any_proxy_env; then
    ensure_default_no_proxy
    HOST_PROXY_URL="$(first_non_empty "${HTTP_PROXY:-}" "${http_proxy:-}" "${HTTPS_PROXY:-}" "${https_proxy:-}" "${ALL_PROXY:-}" "${all_proxy:-}" || true)"
    print_ok "$(msg ok_proxy_env_detected)"
    return 0
  fi

  if load_proxy_env_file_if_exists; then
    print_ok "$(printf "$(msg ok_proxy_env_loaded)" "${PROXY_ENV_FILE}")"
    if [ -z "${HOST_PROXY_URL}" ]; then
      HOST_PROXY_URL="$(first_non_empty "${HTTP_PROXY:-}" "${http_proxy:-}" "${HTTPS_PROXY:-}" "${https_proxy:-}" "${ALL_PROXY:-}" "${all_proxy:-}" || true)"
    fi
    return 0
  fi

  if ! is_tty_interactive; then
    print_warn "$(msg warn_no_proxy_no_tty)"
    print_warn "$(msg warn_continue_without_proxy)"
    return 0
  fi

  print_warn "$(msg warn_proxy_recommended)"
  if ! prompt_yes_no_tty "$(msg prompt_configure_proxy_now)" "y"; then
    print_warn "$(msg warn_proxy_skipped)"
    return 0
  fi

  while true; do
    proxy_candidate="$(prompt_value_tty "$(msg prompt_enter_proxy_url)")" || return 0
    proxy_candidate="$(trim_space "${proxy_candidate}")"
    if [ -z "${proxy_candidate}" ]; then
      print_warn "$(msg warn_proxy_empty)"
      continue
    fi
    if ! parse_proxy_url "${proxy_candidate}"; then
      print_warn "$(msg warn_proxy_parse_failed)"
      continue
    fi
    proxy_candidate="$(build_proxy_url "${PROXY_SCHEME}" "${PROXY_AUTH}" "${PROXY_HOST}" "${PROXY_PORT}" "${PROXY_PATH}")"
    break
  done

  if ! check_proxy_reachable "${proxy_candidate}"; then
    print_warn "$(msg warn_proxy_probe_failed)"
    if ! prompt_yes_no_tty "$(msg prompt_continue_proxy_anyway)" "y"; then
      print_warn "$(msg warn_proxy_skipped)"
      return 0
    fi
  fi

  no_proxy_csv="$(merge_csv_values "" \
    "localhost" "127.0.0.1" "::1" "host.docker.internal" ".internal" \
    "10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16")"
  HOST_PROXY_URL="${proxy_candidate}"
  apply_proxy_url_with_current_no_proxy "${HOST_PROXY_URL}"
  print_ok "$(msg ok_proxy_exported)"

  no_proxy_csv="${NO_PROXY:-${no_proxy:-${no_proxy_csv}}}"

  save_proxy_env_file "${HOST_PROXY_URL}" "${no_proxy_csv}"
  print_ok "$(printf "$(msg ok_proxy_saved)" "${PROXY_ENV_FILE}")"
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
    print_warn "$(printf "$(msg warn_dual_binaries)" "${USER_INSTALL_DIR}")"
    return 0
  fi

  INSTALL_DIR="${USER_INSTALL_DIR}"

  if [ ! -t 1 ] || [ ! -r /dev/tty ] || [ ! -w /dev/tty ]; then
    return 0
  fi

  print_section "$(msg section_setup)" "$(printf "$(msg setup_choose_install_dir)" "${BIN_NAME}")"
  printf "%b\n" "${C_CHOICE}    $(printf "$(msg setup_option_user_dir)" "${USER_INSTALL_DIR}")${C_RESET}"
  printf "%b\n" "${C_CHOICE}    $(printf "$(msg setup_option_system_dir)" "${SYSTEM_INSTALL_DIR}")${C_RESET}"
  printf "%b" "${C_INFO}    $(msg setup_choose_prompt)${C_RESET}" >/dev/tty

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
        print_err "$(printf "$(msg err_unrecognized_choice)" "${choice}")"
        print_err "$(msg err_rerun_choose_1_2)"
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
    print_err "$(printf "$(msg err_create_install_dir)" "${INSTALL_DIR}")"
    print_err "$(msg err_set_install_dir_retry)"
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
    print_err "$(printf "$(msg err_no_write_system_no_sudo)" "${SYSTEM_INSTALL_DIR}")"
    print_err "$(printf "$(msg err_choose_option_1)" "${USER_INSTALL_DIR}")"
    print_err "$(msg err_or_set_install_dir)"
  else
    print_err "$(printf "$(msg err_no_write_install_dir)" "${INSTALL_DIR}")"
    print_err "$(msg err_set_install_dir_retry)"
  fi
  exit 1
}

check_docker_preflight() {
  local docker_client_version=""
  local docker_server_version=""
  if ! command -v docker &>/dev/null; then
    print_err "$(msg err_docker_not_installed)"
    print_err "$(msg err_install_docker_hint)"
    exit 1
  fi
  if ! docker info &>/dev/null; then
    print_err "$(msg err_docker_not_running)"
    print_err "$(msg err_start_docker_hint)"
    exit 1
  fi
  docker_client_version="$(docker version --format '{{.Client.Version}}' 2>/dev/null || true)"
  docker_server_version="$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)"
  if [ -n "${docker_client_version}" ] && [ -n "${docker_server_version}" ]; then
    print_ok "$(printf "$(msg ok_docker_running_client_server)" "${docker_client_version}" "${docker_server_version}")"
  elif [ -n "${docker_client_version}" ]; then
    print_ok "$(printf "$(msg ok_docker_running_client)" "${docker_client_version}")"
  else
    print_ok "$(msg ok_docker_running)"
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
      print_ok "$(printf "$(msg ok_kubectl_available_version)" "${kubectl_version}")"
    else
      print_ok "$(msg ok_kubectl_available_optional)"
    fi
  else
    print_warn "$(msg warn_kubectl_missing_optional)"
  fi
}

print_environment_info() {
  local kernel_info host_arch
  kernel_info="$(uname -sr)"
  host_arch="$(uname -m)"
  print_info "$(printf "$(msg info_kernel_machine)" "${kernel_info}" "${host_arch}")"
}

print_binary_sha256() {
  local file="$1"
  local label="$2"
  local binary_sha256=""
  if [ ! -f "${file}" ]; then
    return 0
  fi
  if binary_sha256="$(calc_local_checksum "sha256" "${file}")"; then
    print_info "$(printf "$(msg info_label_sha256)" "${label}" "${binary_sha256}")"
  else
    print_warn "$(printf "$(msg warn_sha256_unavailable)" "${label}")"
  fi
}

detect_platform() {
  OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case "${OS}" in
    linux)  OS="linux" ;;
    darwin) OS="darwin" ;;
    *)
      print_err "$(printf "$(msg err_unsupported_os)" "${OS}")"
      print_err "$(msg err_support_scope)"
      exit 1
      ;;
  esac

  ARCH="$(uname -m)"
  case "${ARCH}" in
    x86_64 | amd64) ARCH="amd64" ;;
    arm64 | aarch64) ARCH="arm64" ;;
    *)
      print_err "$(printf "$(msg err_unsupported_arch)" "${ARCH}")"
      exit 1
      ;;
  esac
}

init_colors

LANG_SOURCE=""
USER_LANG="$(normalize_lang "${USER_LANG}")"
if [ -z "${USER_LANG}" ]; then
  USER_LANG="$(load_saved_lang_preference || true)"
  if [ -n "${USER_LANG}" ]; then
    LANG_SOURCE="saved"
  fi
else
  LANG_SOURCE="env"
fi
if [ -z "${USER_LANG}" ]; then
  USER_LANG="$(detect_system_lang)"
  LANG_SOURCE="detected"
fi
if [ "${LANG_SOURCE}" = "detected" ]; then
  select_user_lang_if_tty "${USER_LANG}" || true
fi

# ---------------------------------------------------------------------------
# 1. Environment preflight checks
# ---------------------------------------------------------------------------
detect_platform

print_section "1/5" "$(msg section_preflight)"
print_environment_info
check_docker_preflight
check_optional_tools

# ---------------------------------------------------------------------------
# 2. Proxy setup and docker daemon network check
# ---------------------------------------------------------------------------
print_section "2/5" "$(msg section_proxy_setup)"
setup_proxy_env_if_needed
docker_proxy_smoke_test || true

BINARY_URL="${RELEASE_BASE_URL}/${BINARY_ASSET_NAME}-${OS}-${ARCH}"
CONFIG_URL="${BOOTSTRAP_BASE_URL}/config.yml"
VALUES_URL="${BOOTSTRAP_BASE_URL}/values.yaml"

print_section "3/5" "$(printf "$(msg section_install)" "${OS}" "${ARCH}")"

# Determine install path
choose_install_dir
ensure_install_dir_writable
DEST="${INSTALL_DIR}/${BIN_NAME}"

TMP=""
REMOTE_CHECKSUM_ALGO=""
REMOTE_CHECKSUM_VALUE=""
if [ -x "${DEST}" ]; then
  print_info "$(printf "$(msg info_found_local_binary)" "${DEST}")"
  print_binary_sha256 "${DEST}" "Existing ${BIN_NAME} binary"
else
  print_info "$(printf "$(msg info_no_local_binary)" "${DEST}")"
fi
if resolve_remote_checksum "${BINARY_URL}"; then
  print_info "$(printf "$(msg info_found_remote_checksum)" "${REMOTE_CHECKSUM_ALGO}" "${BIN_NAME}")"
else
  print_warn "$(msg warn_no_remote_checksum)"
fi

NEED_DOWNLOAD=1
if [ -x "${DEST}" ]; then
  if [ -n "${REMOTE_CHECKSUM_ALGO}" ] && [ -n "${REMOTE_CHECKSUM_VALUE}" ]; then
    if LOCAL_CHECKSUM="$(calc_local_checksum "${REMOTE_CHECKSUM_ALGO}" "${DEST}")"; then
      if [ "${LOCAL_CHECKSUM}" = "${REMOTE_CHECKSUM_VALUE}" ]; then
        NEED_DOWNLOAD=0
      else
        print_warn "$(msg warn_existing_checksum_mismatch)"
      fi
    else
      print_warn "$(printf "$(msg warn_local_checksum_unavailable)" "${REMOTE_CHECKSUM_ALGO}")"
    fi
  else
    print_warn "$(msg warn_existing_no_checksum)"
  fi
fi

if [ "${NEED_DOWNLOAD}" -eq 1 ]; then
  TMP="$(mktemp)"
  trap 'rm -f "${TMP:-}"' EXIT

  if [ "${USE_SUDO}" = "sudo" ]; then
    print_warn "$(printf "$(msg warn_system_dir_need_sudo)" "${SYSTEM_INSTALL_DIR}")"
  fi

  print_info "$(printf "$(msg info_downloading_binary)" "${BINARY_URL}")"
  download_file "${BINARY_URL}" "${TMP}"

  if [ -n "${REMOTE_CHECKSUM_ALGO}" ] && [ -n "${REMOTE_CHECKSUM_VALUE}" ]; then
    if ! DOWNLOADED_CHECKSUM="$(calc_local_checksum "${REMOTE_CHECKSUM_ALGO}" "${TMP}")"; then
      print_err "$(printf "$(msg err_download_checksum_calc)" "${REMOTE_CHECKSUM_ALGO}")"
      exit 1
    fi
    if [ "${DOWNLOADED_CHECKSUM}" != "${REMOTE_CHECKSUM_VALUE}" ]; then
      print_err "$(printf "$(msg err_download_checksum_verify)" "${REMOTE_CHECKSUM_ALGO}")"
      exit 1
    fi
    print_ok "$(printf "$(msg ok_download_checksum_verified)" "${REMOTE_CHECKSUM_ALGO}")"
  fi

  chmod +x "${TMP}"
  ${USE_SUDO} mv "${TMP}" "${DEST}"
  print_ok "$(printf "$(msg ok_installed_to_dest)" "${DEST}")"
  print_binary_sha256 "${DEST}" "Installed ${BIN_NAME} binary"
else
  print_ok "$(printf "$(msg ok_already_up_to_date)" "${DEST}")"
fi

if [ "${INSTALL_DIR}" = "${USER_INSTALL_DIR}" ]; then
  case ":${PATH}:" in
    *":${USER_INSTALL_DIR}:"*)
      ;;
    *)
      print_warn "$(printf "$(msg warn_add_path_hint)" "${USER_INSTALL_DIR}")"
      print_info "$(printf "$(msg info_export_path_cmd)" "${USER_INSTALL_DIR}")"
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# 4. Download configuration files
# ---------------------------------------------------------------------------
print_section "4/5" "$(msg section_download_config)"
mkdir -p "$(dirname "${CONFIG_FILE}")"
TMP_CONFIG="$(mktemp)"
TMP_VALUES="$(mktemp)"
trap 'rm -f "${TMP:-}" "${TMP_CONFIG:-}" "${TMP_VALUES:-}"' EXIT

download_file "${CONFIG_URL}" "${TMP_CONFIG}"
download_file "${VALUES_URL}" "${TMP_VALUES}"

mv "${TMP_CONFIG}" "${CONFIG_FILE}"
mv "${TMP_VALUES}" "${VALUES_FILE}"
print_ok "$(printf "$(msg ok_config_saved)" "${CONFIG_FILE}")"
print_ok "$(printf "$(msg ok_values_saved)" "${VALUES_FILE}")"

# ---------------------------------------------------------------------------
# 5. Run deploy with explicit config paths
# ---------------------------------------------------------------------------
# If image pulls must go through a proxy (for example, private network environments),
# set and export these variables before running this script:
#   export HTTP_PROXY=http://<proxy>:<port>
#   export HTTPS_PROXY=http://<proxy>:<port>
#   export NO_PROXY=localhost,127.0.0.1
# kind forwards these variables into node containers so containerd can pull control-plane images.
print_section "5/5" "$(msg section_start_deploy)"
"${DEST}" deploy --config "${CONFIG_FILE}" --values "${VALUES_FILE}"
