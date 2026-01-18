#!/usr/bin/env bash
# 严格模式
set -eo pipefail

# --- DEBUG: 打印具体失败的行号和命令（systemd 下非常关键） ---
trap 'rc=$?; echo "[ERR] rc=$rc line=$LINENO cmd=$BASH_COMMAND" >&2' ERR
# 如需更详细：取消下一行注释
# set -x
# --- DEBUG end ---

############################################
# Clash for Linux - start.sh (Full Version)
# - systemd 模式下订阅失败/下载失败：不退出，使用 conf/config.yaml（必要时从 conf/fallback_config.yaml 拷贝）兜底启动
# - 非 systemd 模式：订阅失败/下载失败直接退出（保持手动执行的强约束）
############################################

# 加载系统函数库(Only for RHEL Linux)
[ -f /etc/init.d/functions ] && source /etc/init.d/functions

#################### 脚本初始化任务 ####################

# 获取脚本工作目录绝对路径
export Server_Dir
Server_Dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载.env变量文件
# shellcheck disable=SC1090
# --- source .env（不可信输入，必须放宽） ---
if [ -f "$Server_Dir/.env" ]; then
  set +u
  source "$Server_Dir/.env" || echo "[WARN] failed to source .env" >&2
  set -u
fi

# systemd 模式开关（必须在 set -u 下安全）
SYSTEMD_MODE="${SYSTEMD_MODE:-false}"

# root-only 强约束：不是 root 直接退出
if [ "$(id -u)" -ne 0 ]; then
  echo "[ERR] root-only mode: please run as root" >&2
  exit 2
fi

# 给二进制启动程序、脚本等添加可执行权限
chmod +x "$Server_Dir/bin/"* 2>/dev/null || true
chmod +x "$Server_Dir/scripts/"* 2>/dev/null || true
if [ -f "$Server_Dir/tools/subconverter/subconverter" ]; then
  chmod +x "$Server_Dir/tools/subconverter/subconverter" 2>/dev/null || true
fi

#################### 变量设置 ####################

Conf_Dir="$Server_Dir/conf"

# root-only：统一使用安装目录下的 temp/logs
Temp_Dir="$Server_Dir/temp"
Log_Dir="$Server_Dir/logs"

mkdir -p "$Conf_Dir" "$Temp_Dir" "$Log_Dir" || {
  echo "[ERR] cannot create dirs: Conf_Dir=$Conf_Dir Temp_Dir=$Temp_Dir Log_Dir=$Log_Dir"
  exit 2
}

# 再做一次可写性检查，避免后面玄学 exit
touch "$Temp_Dir/.write_test" 2>/dev/null || { echo "[ERR] Temp_Dir not writable: $Temp_Dir"; exit 2; }
rm -f "$Temp_Dir/.write_test" 2>/dev/null || true

PID_FILE="${CLASH_PID_FILE:-$Temp_Dir/clash.pid}"

is_running() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

if is_running; then
  echo -e "\n[OK] Clash 已在运行 (pid=$(cat "$PID_FILE"))，跳过重复启动\n"
  exit 0
fi

# 统一订阅变量
URL="${CLASH_URL:-}"

# 清理可能的 CRLF（Windows 写 .env 很常见）
URL="$(printf '%s' "$URL" | tr -d '\r')"

#让 bash 子进程能拿到
export CLASH_URL="$URL"

# 只有在“需要在线更新订阅”的模式下才强制要求 URL
if [ -z "$URL" ] && [ "${SYSTEMD_MODE:-false}" != "true" ]; then
  echo "[ERR] CLASH_URL 为空（未配置订阅地址）"
  exit 2
fi

# 获取 CLASH_SECRET 值：优先 .env；其次读取旧 config；占位符视为无效；最后生成随机值
Secret="${CLASH_SECRET:-}"

# 尝试从旧 config.yaml 读取（仅当 .env 未提供）
if [ -z "$Secret" ] && [ -f "$Conf_Dir/config.yaml" ]; then
  Secret="$(awk -F': *' '/^[[:space:]]*secret[[:space:]]*:/{print $2; exit}' "$Conf_Dir/config.yaml" 2>/dev/null | tr -d '"' || true)"
fi

# 若读取到的是占位符（如 ${CLASH_SECRET}），视为无效
if [[ "$Secret" =~ ^\$\{.*\}$ ]]; then
  Secret=""
fi

# 兜底生成随机 secret
if [ -z "$Secret" ]; then
  if command -v openssl >/dev/null 2>&1; then
    Secret="$(openssl rand -hex 32)"
  else
    # 32 bytes -> 64 hex chars
    Secret="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  fi
fi

# 强制写入 secret 到指定配置文件（存在则替换，不存在则追加）
force_write_secret() {
  local file="$1"
  [ -f "$file" ] || return 0

  if grep -qE '^[[:space:]]*secret:' "$file"; then
    # 替换整行 secret（无论原来是啥，包括 SECRET_PLACEHOLDER / "${CLASH_SECRET}"）
    sed -i -E "s|^[[:space:]]*secret:.*$|secret: ${Secret}|g" "$file"
  else
    # 没有 secret 行就追加到文件末尾
    printf "\nsecret: %s\n" "$Secret" >> "$file"
  fi
}

ensure_ui_link() {
  mkdir -p "$Conf_Dir"
  ln -sfn "$Server_Dir/dashboard/public" "$Conf_Dir/ui"
}

# --- helpers: upsert yaml key (top-level), ensure UI links ---
upsert_yaml_kv() {
  # Usage: upsert_yaml_kv <file> <key> <value>
  # Writes: key: value  (top-level)
  local file="$1" key="$2" value="$3"
  [ -n "$file" ] && [ -n "$key" ] || return 1

  # 如果文件不存在，先创建
  [ -f "$file" ] || : >"$file" || return 1

  if grep -qE "^[[:space:]]*${key}:[[:space:]]*" "$file" 2>/dev/null; then
    # 替换整行（避免残留引号）
    sed -i -E "s|^[[:space:]]*${key}:[[:space:]]*.*$|${key}: ${value}|g" "$file"
  else
    # 追加前保证有换行
    tail -c 1 "$file" 2>/dev/null | read -r _last || true
    # shellcheck disable=SC2034
    if [ "$(tail -c 1 "$file" 2>/dev/null || true)" != "" ]; then
      printf "\n" >>"$file"
    fi
    printf "%s: %s\n" "$key" "$value" >>"$file"
  fi
}

ensure_ui_links() {
  local ui_src="${UI_SRC_DIR:-$Server_Dir/dashboard/public}"

  mkdir -p "$Conf_Dir" 2>/dev/null || true
  if [ -d "$ui_src" ]; then
    ln -sfn "$ui_src" "$Conf_Dir/ui" 2>/dev/null || true
  fi
}

force_write_controller_and_ui() {
  local file="$1"
  local controller="${EXTERNAL_CONTROLLER:-127.0.0.1:9090}"

  [ -n "$file" ] || return 1

  # 1) external-controller
  upsert_yaml_kv "$file" "external-controller" "$controller" || true

  # 2) external-ui：永远写稳定路径 Conf_Dir/ui（脚本保证它存在且指向真实 UI）
  ensure_ui_links

  # 如果 UI 源目录缺失，就不要写 external-ui（避免写一个死路径）
  if [ -e "$Conf_Dir/ui" ]; then
    upsert_yaml_kv "$file" "external-ui" "$Conf_Dir/ui" || true
  fi
}

# 设置默认值
CLASH_HTTP_PORT="${CLASH_HTTP_PORT:-7890}"
CLASH_SOCKS_PORT="${CLASH_SOCKS_PORT:-7891}"
CLASH_REDIR_PORT="${CLASH_REDIR_PORT:-7892}"
CLASH_LISTEN_IP="${CLASH_LISTEN_IP:-127.0.0.1}"
CLASH_ALLOW_LAN="${CLASH_ALLOW_LAN:-false}"

EXTERNAL_CONTROLLER_ENABLED="${EXTERNAL_CONTROLLER_ENABLED:-true}"
EXTERNAL_CONTROLLER="${EXTERNAL_CONTROLLER:-127.0.0.1:9090}"

ALLOW_INSECURE_TLS="${ALLOW_INSECURE_TLS:-false}"

# 端口与配置工具
# shellcheck disable=SC1090
source "$Server_Dir/scripts/port_utils.sh"
CLASH_HTTP_PORT="$(resolve_port_value "HTTP" "$CLASH_HTTP_PORT")"
CLASH_SOCKS_PORT="$(resolve_port_value "SOCKS" "$CLASH_SOCKS_PORT")"
CLASH_REDIR_PORT="$(resolve_port_value "REDIR" "$CLASH_REDIR_PORT")"
EXTERNAL_CONTROLLER="$(resolve_host_port "External Controller" "$EXTERNAL_CONTROLLER" "127.0.0.1")"

# shellcheck disable=SC1090
source "$Server_Dir/scripts/config_utils.sh"

#################### 函数定义 ####################

# 自定义action函数，实现通用action功能（兼容 journald；关键错误会额外 echo 到 stderr）
success() {
  echo -en "\033[60G[\033[1;32m OK \033[0;39m]\r"
  return 0
}

failure() {
  local rc=$?
  echo -en "\033[60G[\033[1;31mFAILED\033[0;39m]\r"
  [ -x /bin/plymouth ] && /bin/plymouth --details
  return "$rc"
}

action() {
  local STRING
  STRING=$1
  shift

  # 执行命令本身的成功/失败，不应让 UI 输出影响返回码
  if "$@"; then
    success $"$STRING" || true
    return 0
  else
    failure $"$STRING" || true
    return 1
  fi
}

# 判断命令是否正常执行
# - 手动模式：失败直接 exit
# - systemd 模式：只打印状态，不影响退出码
if_success() {
  local ok_msg=$1
  local fail_msg=$2
  local rc=$3

  if [ "$rc" -eq 0 ]; then
    action "$ok_msg" /bin/true || true
    return 0
  fi

  # rc != 0
  action "$fail_msg" /bin/false || true

  if [ "${SYSTEMD_MODE:-false}" = "true" ]; then
    # systemd 下不允许在 UI 函数中 exit
    return "$rc"
  else
    exit "$rc"
  fi
}

ensure_subconverter() {
  local bin="${Server_Dir}/tools/subconverter/subconverter"
  local port="25500"

  # 没有二进制直接跳过
  if [ ! -x "$bin" ]; then
    echo "[WARN] subconverter bin not found: $bin"
    export SUBCONVERTER_READY="false"
    return 0
  fi

  # 已在监听则认为就绪
  if ss -lntp 2>/dev/null | grep -qE ":${port}[[:space:]]"; then
    export SUBCONVERTER_URL="${SUBCONVERTER_URL:-http://127.0.0.1:${port}}"
    export SUBCONVERTER_READY="true"
    return 0
  fi

  # 启动（后台）
  echo "[INFO] starting subconverter..."
  (cd "${Server_Dir}/tools/subconverter" && nohup "./subconverter" >/dev/null 2>&1 &)

  # 等待端口起来
  for _ in 1 2 3 4 5; do
    sleep 1
    if ss -lntp 2>/dev/null | grep -qE ":${port}[[:space:]]"; then
      export SUBCONVERTER_URL="${SUBCONVERTER_URL:-http://127.0.0.1:${port}}"
      export SUBCONVERTER_READY="true"
      echo "[OK] subconverter ready at ${SUBCONVERTER_URL}"
      return 0
    fi
  done

  echo "[WARN] subconverter start failed or port not ready"
  export SUBCONVERTER_READY="false"
  return 0
}

#################### 任务执行 ####################

## 获取CPU架构信息
# shellcheck disable=SC1090
source "$Server_Dir/scripts/get_cpu_arch.sh"

if [[ -z "${CpuArch:-}" ]]; then
  echo "[ERROR] Failed to obtain CPU architecture" >&2
  exit 2
fi

# shellcheck disable=SC1090
source "$Server_Dir/scripts/resolve_clash.sh"

## 临时取消环境变量
unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY || true

########################################################
# systemd 兜底：如果没有可用订阅 URL，则确保有 config.yaml
########################################################
ensure_fallback_config() {
  # conf/config.yaml 为空或不存在，则从 fallback 拷贝
  if [ ! -s "$Conf_Dir/config.yaml" ]; then
    if [ -s "$Server_Dir/conf/fallback_config.yaml" ]; then
      cp -f "$Server_Dir/conf/fallback_config.yaml" "$Conf_Dir/config.yaml"
      echo -e "\033[33m[WARN]\033[0m 已复制 fallback_config.yaml -> conf/config.yaml（兜底）"
    else
      echo -e "\033[31m[ERROR]\033[0m 未找到可用的 conf/fallback_config.yaml，无法兜底启动" >&2
      if [ "${SYSTEMD_MODE:-false}" = "true" ]; then
        return 1
      else
        exit 1
      fi
    fi
  fi

  # 强制写入真实 secret（失败时也遵循同样规则）
  if ! force_write_secret "$Conf_Dir/config.yaml"; then
    echo -e "\033[31m[ERROR]\033[0m 写入 secret 失败：$Conf_Dir/config.yaml" >&2
    if [ "${SYSTEMD_MODE:-false}" = "true" ]; then
      return 1
    else
      exit 1
    fi
  fi

  return 0
}
SKIP_CONFIG_REBUILD=false

# systemd 模式下若 URL 为空：直接兜底启动
if [ "${SYSTEMD_MODE}" = "true" ] && [ -z "${URL:-}" ]; then
  echo -e "\033[33m[WARN]\033[0m SYSTEMD_MODE=true 且 CLASH_URL 为空，跳过订阅更新，使用本地兜底配置启动"
  ensure_fallback_config || true
  SKIP_CONFIG_REBUILD=true
fi

#################### Clash 订阅地址检测及配置文件下载 ####################
if [ "$SKIP_CONFIG_REBUILD" != "true" ]; then
  echo -e '\n正在检测订阅地址...'
  Text1="Clash订阅地址可访问！"
  Text2="Clash订阅地址不可访问！"

  CHECK_CMD=(curl -o /dev/null -L -sS --retry 5 -m 10 --connect-timeout 10 -w "%{http_code}")
  if [ "$ALLOW_INSECURE_TLS" = "true" ]; then
    CHECK_CMD+=(-k)
    echo -e "\033[33m[WARN]\033[0m 已启用不安全的 TLS 下载（跳过证书校验）"
  fi
  if [ -n "${CLASH_HEADERS:-}" ]; then
    CHECK_CMD+=(-H "$CLASH_HEADERS")
  fi
  CHECK_CMD+=("$URL")

  # 不让 set -e 干扰获取状态码
  set +e
  status_code="$("${CHECK_CMD[@]}")"
  curl_rc=$?
  set -e

  # curl 本身失败，视为不可用
  if [ "$curl_rc" -ne 0 ]; then
    status_code=""
    ReturnStatus=1
  else
    echo "$status_code" | grep -E '^[23][0-9]{2}$' &>/dev/null
    ReturnStatus=$?
  fi

  if [ "$ReturnStatus" -eq 0 ]; then
    action "$Text1" /bin/true || true
  else
    if [ "$SYSTEMD_MODE" = "true" ]; then
      action "$Text2（systemd 模式不退出，尝试使用旧配置/兜底配置）" /bin/false || true
      echo -e "\033[33m[WARN]\033[0m Subscribe check failed: http_code=${status_code:-unknown}, url=${URL}" >&2
      ensure_fallback_config || true
      SKIP_CONFIG_REBUILD=true
    else
      if_success "$Text1" "$Text2" "$ReturnStatus"
    fi
  fi
fi

#################### 下载订阅并生成 config.yaml（非兜底路径） ####################
if [ "$SKIP_CONFIG_REBUILD" != "true" ]; then
  ensure_subconverter || true
  echo -e '\n正在下载Clash配置文件...'
  Text3="配置文件clash.yaml下载成功！"
  Text4="配置文件clash.yaml下载失败！"

  # --- DBG: 显式打印并验证临时目录可写（systemd 下常见权限问题） ---
  echo "[DBG] uid=$(id -u) user=$(id -un) SYSTEMD_MODE=${SYSTEMD_MODE:-}"
  echo "[DBG] Server_Dir=$Server_Dir Conf_Dir=$Conf_Dir Temp_Dir=$Temp_Dir Log_Dir=$Log_Dir"
  echo "[DBG] URL=$(printf '%q' "$URL")"

  mkdir -p "$Temp_Dir" 2>/dev/null || true
  touch "$Temp_Dir/.write_test" 2>/dev/null || { echo "[ERR] Temp_Dir not writable: $Temp_Dir" >&2; exit 2; }
  rm -f "$Temp_Dir/.write_test" 2>/dev/null || true
  # --- DBG end ---

  CURL_CMD=(curl -fL -S --retry 2 --connect-timeout 10 -m 30 -o "$Temp_Dir/clash.yaml")
  if [ "$ALLOW_INSECURE_TLS" = "true" ]; then
    CURL_CMD+=(-k)
  fi
  if [ -n "${CLASH_HEADERS:-}" ]; then
    CURL_CMD+=(-H "$CLASH_HEADERS")
  fi
  CURL_CMD+=("$URL")

  set +e
  CURL_ERR="$Temp_Dir/curl.err"
  : > "$CURL_ERR"
  "${CURL_CMD[@]}" 2>>"$CURL_ERR"
  ReturnStatus=$?
  set -e

  echo "[DBG] curl rc=$ReturnStatus"
  if [ -s "$CURL_ERR" ]; then
    echo "[DBG] curl stderr (last 50 lines):"
    tail -n 50 "$CURL_ERR"
  fi

  if [ "$ReturnStatus" -ne 0 ]; then
    WGET_CMD=(wget -q -O "$Temp_Dir/clash.yaml")
    if [ "$ALLOW_INSECURE_TLS" = "true" ]; then
      WGET_CMD+=(--no-check-certificate)
    fi
    if [ -n "${CLASH_HEADERS:-}" ]; then
      WGET_CMD+=(--header="$CLASH_HEADERS")
    fi
    WGET_CMD+=("$URL")

    for _ in {1..10}; do
      set +e
      "${WGET_CMD[@]}"
      ReturnStatus=$?
      set -e
      if [ "$ReturnStatus" -eq 0 ]; then
        break
      fi
    done
  fi

  CONFIG_FILE="${CONFIG_FILE:-$Temp_Dir/config.yaml}"
  mkdir -p "$Temp_Dir" || true

  if [ "$ReturnStatus" -eq 0 ] && [ -s "$Temp_Dir/clash.yaml" ]; then
    SRC_YAML="$Temp_Dir/clash.yaml"

    # 1) 判断是否是完整 Clash 配置（关键字段之一存在即可）
    if grep -qE '^(proxies:|proxy-providers:|rules:|port:|mixed-port:|dns:)' "$SRC_YAML"; then
      cp -f "$SRC_YAML" "$CONFIG_FILE"
      echo "[INFO] subscription already is a full clash config"
    else
      # 2) 非完整配置：尝试用 subconverter 转换
      echo "[INFO] subscription is not a full config, try conversion via subconverter..."

      export IN_FILE="$SRC_YAML"
      export OUT_FILE="$Temp_Dir/clash_converted.yaml"

      set +e
      bash "$Server_Dir/scripts/clash_profile_conversion.sh"
      conv_rc=$?
      set -e

      if [ "$conv_rc" -eq 0 ] && [ -s "$OUT_FILE" ]; then
        cp -f "$OUT_FILE" "$CONFIG_FILE"
        echo "[INFO] conversion ok -> runtime config ready"
      else
        echo "[WARN] conversion skipped/failed, will keep original and rely on fallback"
        cp -f "$SRC_YAML" "$CONFIG_FILE"
      fi
    fi

    # 3) 强制注入 external-controller / external-ui（运行态兜底）
    force_write_controller_and_ui "$CONFIG_FILE" || true

    # 4) 强制注入 secret
    force_write_secret "$CONFIG_FILE" || true

    # Optional: Fix test URLs to HTTPS for reliability (safe, narrow scope)
    if [ "${FIX_TEST_URL_HTTPS:-true}" = "true" ] && [ -s "$CONFIG_FILE" ]; then
      # 1) proxy-groups url-test / fallback url
      sed -i -E \
        "s#(url:[[:space:]]*['\"])http://#\1https://#g" \
        "$CONFIG_FILE" 2>/dev/null || true

      # 2) cfw-latency-url (used by some dashboards / generators)
      sed -i -E \
        "s#(cfw-latency-url:[[:space:]]*['\"])http://#\1https://#g" \
        "$CONFIG_FILE" 2>/dev/null || true
    fi

    # 5) 自检：失败则回退到旧配置
    BIN="${Server_Dir}/bin/clash-linux-amd64"
    NEW_CFG="$CONFIG_FILE"
    OLD_CFG="${Conf_Dir}/config.yaml"

    if [ -x "$BIN" ] && [ -f "$NEW_CFG" ]; then
      if ! "$BIN" -t -f "$NEW_CFG" >/dev/null 2>&1; then
        echo "[ERROR] Generated config invalid, fallback to last good config: $OLD_CFG" >&2
        if [ -f "$OLD_CFG" ]; then
          cp -f "$OLD_CFG" "$NEW_CFG"
        else
          echo "[FATAL] No valid config available, aborting startup" >&2
          exit 1
        fi
      fi
    fi

    echo "[INFO] Runtime config generated: $CONFIG_FILE (size=$(wc -c <"$CONFIG_FILE" 2>/dev/null || echo 0))"
  else
    echo "[WARN] Download did not produce clash.yaml (rc=$ReturnStatus), skip runtime config generation" >&2
  fi

  if [ "$ReturnStatus" -eq 0 ]; then
    action "$Text3" /bin/true || true
  else
    if [ "$SYSTEMD_MODE" = "true" ]; then
      action "$Text4（systemd 模式：下载失败，使用旧配置/兜底配置继续启动）" /bin/false || true
      echo -e "\033[33m[WARN]\033[0m Download failed, will fallback. url=${URL}" >&2
      ensure_fallback_config || true
      SKIP_CONFIG_REBUILD=true
    else
      if_success "$Text3" "$Text4（退出启动）" "$ReturnStatus"
    fi
  fi
fi

# =========================================================
# 判断订阅是否已是完整 Clash YAML（Meta / Mihomo / Premium）
# 若是完整配置，则直接使用，跳过后续代理拆解与拼接
# =========================================================
if grep -qE '^(proxies:|proxy-providers:|mixed-port:|port:)' "$Temp_Dir/clash.yaml"; then
  echo "[INFO] subscription is a full Clash config, use it directly"
  cp -f "$Temp_Dir/clash.yaml" "$Conf_Dir/config.yaml"

  # 生成运行态（systemd non-root 实际启动用 Temp_Dir/config.yaml）
  cp -f "$Temp_Dir/clash.yaml" "$Temp_Dir/config.yaml"

  # 写 controller/ui + secret（写到运行态）
  force_write_controller_and_ui "$Temp_Dir/config.yaml" || true
  force_write_secret "$Temp_Dir/config.yaml" || true

  # 同时把 conf/config.yaml 也补齐（方便你 grep/排查）
  force_write_controller_and_ui "$Conf_Dir/config.yaml" || true
  force_write_secret "$Conf_Dir/config.yaml" || true

  # 创建 UI 软链（systemd non-root 用 /tmp）
  Dashboard_Src="$Server_Dir/dashboard/public"
  if [ -d "$Dashboard_Src" ]; then
    ln -sfn "$Dashboard_Src" "$Conf_Dir/ui" 2>/dev/null || true
  fi

    SKIP_CONFIG_REBUILD=true
  fi

#################### 订阅转换/拼接（非兜底路径） ####################
if [ "$SKIP_CONFIG_REBUILD" != "true" ]; then
  # 运行期配置文件：默认用 Temp_Dir（systemd + clash 用户可写）
  CONFIG_FILE="$Temp_Dir/config.yaml"

  # 1) 重命名订阅文件
  \cp -a "$Temp_Dir/clash.yaml" "$Temp_Dir/clash_config.yaml"

  # 2) 判断订阅内容是否符合 clash 配置文件标准，尝试转换（需 subconverter）
  # shellcheck disable=SC1090
  source "$Server_Dir/scripts/resolve_subconverter.sh"

  if [ "${Subconverter_Ready:-false}" = "true" ]; then
    echo -e '\n判断订阅内容是否符合clash配置文件标准:'
    export SUBCONVERTER_BIN="$Subconverter_Bin"
    bash "$Server_Dir/scripts/clash_profile_conversion.sh"
    sleep 1
  else
    echo -e "\033[33m[WARN]\033[0m 未检测到可用的 subconverter，跳过订阅转换"
  fi

  # 3) 订阅形态判断：
  # - 如果已经是完整 Clash 配置（Meta/Mihomo 常见 mixed-port / proxy-providers 等），直接用它作为运行配置
  # - 否则才走 “proxies: 抽取 + template 拼接”
  if grep -qE '^(mixed-port:|port:|proxy-providers:|proxies:)' "$Temp_Dir/clash_config.yaml"; then
    # 情况 A：完整配置（优先）
    if grep -q '^proxies:' "$Temp_Dir/clash_config.yaml" || grep -q '^proxy-providers:' "$Temp_Dir/clash_config.yaml" || grep -q '^mixed-port:' "$Temp_Dir/clash_config.yaml" || grep -q '^port:' "$Temp_Dir/clash_config.yaml"; then
      echo "[INFO] subscription looks like a full Clash config, use it directly"
      cp -f "$Temp_Dir/clash_config.yaml" "$CONFIG_FILE"
      # 写入 secret（运行态）
      force_write_secret "$CONFIG_FILE"
      # 直接跳过后续拼接流程
      SKIP_CONFIG_REBUILD=true
    fi
  fi

  # 情况 B：不是完整配置，才尝试抽取 proxies 并拼接
  if [ "$SKIP_CONFIG_REBUILD" != "true" ]; then
    if grep -q '^proxies:' "$Temp_Dir/clash_config.yaml"; then
      sed -n '/^proxies:/,$p' "$Temp_Dir/clash_config.yaml" > "$Temp_Dir/proxy.txt"
    else
      echo "[ERROR] subscription is not a full config and also has no 'proxies:'; cannot build config." >&2
      # systemd 模式：兜底继续；非 systemd：退出
      if [ "${SYSTEMD_MODE:-false}" = "true" ]; then
        ensure_fallback_config || true
        SKIP_CONFIG_REBUILD=true
      else
        exit 2
      fi
    fi
  fi

  # 4) 合并形成新的 config，并替换配置占位符
  if [ "$SKIP_CONFIG_REBUILD" != "true" ]; then
    cat "$Temp_Dir/templete_config.yaml" > "$CONFIG_FILE"
    cat "$Temp_Dir/proxy.txt" >> "$CONFIG_FILE"

    sed -i "s/CLASH_HTTP_PORT_PLACEHOLDER/${CLASH_HTTP_PORT}/g" "$CONFIG_FILE"
    sed -i "s/CLASH_SOCKS_PORT_PLACEHOLDER/${CLASH_SOCKS_PORT}/g" "$CONFIG_FILE"
    sed -i "s/CLASH_REDIR_PORT_PLACEHOLDER/${CLASH_REDIR_PORT}/g" "$CONFIG_FILE"
    sed -i "s/CLASH_LISTEN_IP_PLACEHOLDER/${CLASH_LISTEN_IP}/g" "$CONFIG_FILE"
    sed -i "s/CLASH_ALLOW_LAN_PLACEHOLDER/${CLASH_ALLOW_LAN}/g" "$CONFIG_FILE"
  fi

  # 5) 配置 external-controller
  if [ "$EXTERNAL_CONTROLLER_ENABLED" = "true" ]; then
    sed -i "s/EXTERNAL_CONTROLLER_PLACEHOLDER/${EXTERNAL_CONTROLLER}/g" "$CONFIG_FILE"
  else
    sed -i "s/external-controller: 'EXTERNAL_CONTROLLER_PLACEHOLDER'/# external-controller: disabled/g" "$CONFIG_FILE"
  fi

  apply_tun_config "$CONFIG_FILE"
  apply_mixin_config "$CONFIG_FILE" "$Server_Dir"

  # 6) 是否同步到 conf（root/非 systemd 时才做；systemd+非root跳过）
  \cp "$CONFIG_FILE" "$Conf_Dir/"

  # 7) Dashboard external-ui（systemd+非root：把 ui 放 Temp_Dir 下，避免写 conf）
  Work_Dir="$(cd "$(dirname "$0")" && pwd)"
  Dashboard_Src="${Work_Dir}/dashboard/public"

  if [ "$EXTERNAL_CONTROLLER_ENABLED" = "true" ]; then
    if [ "${SYSTEMD_MODE:-false}" = "true" ] && [ "$(id -u)" -ne 0 ]; then
      # runtime ui path (writable)
      Dashboard_Link="$Temp_Dir/ui"
      if [ -d "$Dashboard_Src" ]; then
        ln -sfn "$Dashboard_Src" "$Dashboard_Link" 2>/dev/null || true
      fi
    else
      # conf ui path (root can manage)
      Dashboard_Link="${Conf_Dir}/ui"
      if [ -d "$Dashboard_Src" ]; then
        ln -sfn "$Dashboard_Src" "$Dashboard_Link" || true
      else
        echo -e "\033[33m[WARN]\033[0m Dashboard source not found: $Dashboard_Src (external-ui may not work)"
      fi
    fi

    # ensure external-ui points to Dashboard_Link
    if grep -qE '^[[:space:]]*external-ui:' "$CONFIG_FILE"; then
      sed -i -E "s|^[[:space:]]*external-ui:.*$|external-ui: ${Dashboard_Link}|g" "$CONFIG_FILE"
    else
      printf "\nexternal-ui: %s\n" "$Dashboard_Link" >> "$CONFIG_FILE"
    fi
  fi

  # 8) 写入 secret（写到 runtime config）
  force_write_secret "$CONFIG_FILE"

else
  # 兜底路径：尽量也写入 secret（conf/config.yaml 可写时）
  if grep -qE '^secret:\s*' "$Conf_Dir/config.yaml" 2>/dev/null; then
    force_write_secret "$Conf_Dir/config.yaml"
  else
    echo "secret: ${Secret}" >> "$Conf_Dir/config.yaml" || true
  fi
fi

#################### 启动Clash服务 ####################

# 选择运行期配置文件与工作目录
CONFIG_FILE="${CONFIG_FILE:-$Conf_Dir/config.yaml}"
RUNTIME_DIR="${Conf_Dir}"

# 启动前确保配置文件存在且非空
if [ ! -s "$CONFIG_FILE" ]; then
  echo -e "\033[31m[ERROR]\033[0m config 不存在或为空：$CONFIG_FILE，无法启动 Clash" >&2
  exit 2
fi

# 最终护栏：禁止未渲染的占位符进入运行态
if grep -q '\${' "$CONFIG_FILE"; then
  echo "[ERROR] config contains unresolved placeholders (\${...}): $CONFIG_FILE" >&2
  exit 2
fi

# 确保运行目录存在且可写（clash/mihomo 可能会写 cache/geo 数据）
mkdir -p "$RUNTIME_DIR" 2>/dev/null || true
touch "$RUNTIME_DIR/.write_test" 2>/dev/null || {
  echo "[ERROR] runtime dir not writable: $RUNTIME_DIR (uid=$(id -u))" >&2
  exit 2
}
rm -f "$RUNTIME_DIR/.write_test" 2>/dev/null || true

echo -e '\n正在启动Clash服务...'
Text5="服务启动成功！"
Text6="服务启动失败！"

Clash_Bin="$(resolve_clash_bin "$Server_Dir" "$CpuArch")"
ReturnStatus=$?

if [ "$ReturnStatus" -eq 0 ]; then
  if [ "${SYSTEMD_MODE:-false}" = "true" ]; then
    echo "[INFO] SYSTEMD_MODE=true，前台启动交给 systemd 监管"
    echo "[INFO] Using config: $CONFIG_FILE"
    echo "[INFO] Using runtime dir: $RUNTIME_DIR"

    # systemd 前台：只用 -f 指定配置文件，-d 作为工作目录
    exec "$Clash_Bin" -f "$CONFIG_FILE" -d "$RUNTIME_DIR"
  else
    echo "[INFO] 后台启动 (nohup)"
    echo "[INFO] Using config: $CONFIG_FILE"
    echo "[INFO] Using runtime dir: $RUNTIME_DIR"

    nohup "$Clash_Bin" -f "$CONFIG_FILE" -d "$RUNTIME_DIR" >>"$Log_Dir/clash.log" 2>&1 &
    PID=$!
    ReturnStatus=$?

    if [ "$ReturnStatus" -eq 0 ]; then
      echo "$PID" > "$PID_FILE"
    fi
  fi
fi

if [ "${SYSTEMD_MODE:-false}" = "true" ]; then
  if_success "$Text5" "$Text6" "$ReturnStatus" || true
else
  if_success "$Text5" "$Text6" "$ReturnStatus"
fi

#################### 输出信息 ####################

echo ''
if [ "$EXTERNAL_CONTROLLER_ENABLED" = "true" ]; then
  echo -e "Clash Dashboard 访问地址: http://${EXTERNAL_CONTROLLER}/ui"

  SHOW_SECRET="${CLASH_SHOW_SECRET:-false}"
  SHOW_SECRET_MASKED="${CLASH_SHOW_SECRET_MASKED:-true}"

  if [ "$SHOW_SECRET" = "true" ]; then
    echo -e "Secret: ${Secret}"
  elif [ "$SHOW_SECRET_MASKED" = "true" ]; then
    # 脱敏：前4后4
    masked="${Secret:0:4}****${Secret: -4}"
    echo -e "Secret: ${masked}  (set CLASH_SHOW_SECRET=true to show full)"
  else
    echo -e "Secret: 已生成（未显示）。查看：/opt/clash-for-linux/conf/config.yaml 或 .env"
  fi
else
  echo -e "External Controller (Dashboard) 已禁用"
fi
echo ''

#################### 写入代理环境变量文件 ####################

Env_File="${CLASH_ENV_FILE:-}"

if [ "$Env_File" = "off" ] || [ "$Env_File" = "disabled" ]; then
  echo -e "\033[33m[WARN]\033[0m 已关闭环境变量文件生成"
else
  if [ -z "$Env_File" ]; then
    if [ -w /etc/profile.d ]; then
      Env_File="/etc/profile.d/clash-for-linux.sh"
    else
      Env_File="$Temp_Dir/clash-for-linux.sh"
    fi
  fi

  if [ -f /etc/profile.d/clash.sh ]; then
    echo -e "\033[33m[WARN]\033[0m 检测到旧版环境变量文件 /etc/profile.d/clash.sh，建议确认是否需要清理"
  fi

  mkdir -p "$(dirname "$Env_File")"

  cat >"$Env_File"<<EOF
# 开启系统代理
function proxy_on() {
  export http_proxy=http://${CLASH_LISTEN_IP}:${CLASH_HTTP_PORT}
  export https_proxy=http://${CLASH_LISTEN_IP}:${CLASH_HTTP_PORT}
  export no_proxy=127.0.0.1,localhost
  export HTTP_PROXY=http://${CLASH_LISTEN_IP}:${CLASH_HTTP_PORT}
  export HTTPS_PROXY=http://${CLASH_LISTEN_IP}:${CLASH_HTTP_PORT}
  export NO_PROXY=127.0.0.1,localhost
  echo -e "\033[32m[√] 已开启代理\033[0m"
}

# 关闭系统代理
function proxy_off() {
  unset http_proxy
  unset https_proxy
  unset no_proxy
  unset HTTP_PROXY
  unset HTTPS_PROXY
  unset NO_PROXY
  echo -e "\033[31m[×] 已关闭代理\033[0m"
}
EOF

  echo -e "请执行以下命令加载环境变量: source ${Env_File}\n"
  echo -e "请执行以下命令开启系统代理: proxy_on\n"
  echo -e "若要临时关闭系统代理，请执行: proxy_off\n"
fi
