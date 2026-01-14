#!/usr/bin/env bash
set -euo pipefail

#################### 脚本初始化任务 ####################

Server_Dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载.env变量文件
if [ ! -f "$Server_Dir/.env" ]; then
  echo -e "\033[31m[ERROR]\033[0m 未找到 .env：$Server_Dir/.env"
  exit 1
fi
# shellcheck disable=SC1090
source "$Server_Dir/.env"

#################### 变量设置 ####################

Conf_Dir="$Server_Dir/conf"
Temp_Dir="$Server_Dir/temp"
Log_Dir="$Server_Dir/logs"

mkdir -p "$Conf_Dir" "$Temp_Dir" "$Log_Dir"

URL="${CLASH_URL:?Error: CLASH_URL variable is not set or empty}"

# 获取 CLASH_SECRET 值，若未设置则尝试读取旧配置，否则生成随机数
Secret="${CLASH_SECRET:-}"
if [ -z "$Secret" ] && [ -f "$Conf_Dir/config.yaml" ]; then
  Secret="$(awk -F': ' '/^secret:/{print $2; exit}' "$Conf_Dir/config.yaml" || true)"
fi
if [ -z "$Secret" ]; then
  Secret="$(openssl rand -hex 32)"
fi

CLASH_HTTP_PORT="${CLASH_HTTP_PORT:-7890}"
CLASH_SOCKS_PORT="${CLASH_SOCKS_PORT:-7891}"
CLASH_REDIR_PORT="${CLASH_REDIR_PORT:-7892}"
CLASH_LISTEN_IP="${CLASH_LISTEN_IP:-0.0.0.0}"
CLASH_ALLOW_LAN="${CLASH_ALLOW_LAN:-false}"
EXTERNAL_CONTROLLER_ENABLED="${EXTERNAL_CONTROLLER_ENABLED:-true}"
EXTERNAL_CONTROLLER="${EXTERNAL_CONTROLLER:-127.0.0.1:9090}"
ALLOW_INSECURE_TLS="${ALLOW_INSECURE_TLS:-false}"
CLASH_HEADERS="${CLASH_HEADERS:-}"

# 工具脚本
# shellcheck disable=SC1090
source "$Server_Dir/scripts/port_utils.sh"
CLASH_HTTP_PORT="$(resolve_port_value "HTTP" "$CLASH_HTTP_PORT")"
CLASH_SOCKS_PORT="$(resolve_port_value "SOCKS" "$CLASH_SOCKS_PORT")"
CLASH_REDIR_PORT="$(resolve_port_value "REDIR" "$CLASH_REDIR_PORT")"
EXTERNAL_CONTROLLER="$(resolve_host_port "External Controller" "$EXTERNAL_CONTROLLER" "0.0.0.0")"

# shellcheck disable=SC1090
source "$Server_Dir/scripts/config_utils.sh"

#################### action / if_success ####################

success() { echo -en "\\033[60G[\\033[1;32m  OK  \\033[0;39m]\r"; return 0; }
failure() { local rc=$?; echo -en "\\033[60G[\\033[1;31mFAILED\\033[0;39m]\r"; [ -x /bin/plymouth ] && /bin/plymouth --details; return $rc; }
action() { local STRING rc; STRING=$1; echo -n "$STRING "; shift; "$@" && success || failure; rc=$?; echo; return $rc; }

if_success() {
  local ok_msg="$1" fail_msg="$2" st="$3"
  if [ "$st" -eq 0 ]; then
    action "$ok_msg" /bin/true
  else
    action "$fail_msg" /bin/false
    exit 1
  fi
}

#################### 任务执行 ####################

# 临时取消环境变量（避免被自身代理影响下载）
unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY || true

echo -e '\n正在检测订阅地址...'
Text1="Clash订阅地址可访问！"
Text2="Clash订阅地址不可访问！"

CHECK_CMD=(curl -o /dev/null -L -sS --retry 5 -m 10 --connect-timeout 10 -w "%{http_code}")
if [ "$ALLOW_INSECURE_TLS" = "true" ]; then
  CHECK_CMD+=(-k)
  echo -e "\033[33m[WARN] 已启用不安全的 TLS 下载（跳过证书校验）\033[0m"
fi
if [ -n "$CLASH_HEADERS" ]; then
  CHECK_CMD+=(-H "$CLASH_HEADERS")
fi
CHECK_CMD+=("$URL")

status_code="$("${CHECK_CMD[@]}")"
echo "$status_code" | grep -E '^[23][0-9]{2}$' &>/dev/null
ReturnStatus=$?
if_success "$Text1" "$Text2" "$ReturnStatus"

echo -e '\n正在下载Clash配置文件...'
Text3="配置文件下载成功！"
Text4="配置文件下载失败，退出更新！"

CURL_CMD=(curl -L -sS --retry 5 -m 20 -o "$Temp_Dir/clash.yaml")
if [ "$ALLOW_INSECURE_TLS" = "true" ]; then
  CURL_CMD+=(-k)
fi
if [ -n "$CLASH_HEADERS" ]; then
  CURL_CMD+=(-H "$CLASH_HEADERS")
fi
CURL_CMD+=("$URL")

"${CURL_CMD[@]}" || true
ReturnStatus=$?

if [ $ReturnStatus -ne 0 ]; then
  WGET_CMD=(wget -q -O "$Temp_Dir/clash.yaml")
  if [ "$ALLOW_INSECURE_TLS" = "true" ]; then
    WGET_CMD+=(--no-check-certificate)
  fi
  if [ -n "$CLASH_HEADERS" ]; then
    WGET_CMD+=(--header="$CLASH_HEADERS")
  fi
  WGET_CMD+=("$URL")

  for _ in {1..10}; do
    "${WGET_CMD[@]}" && ReturnStatus=0 && break || ReturnStatus=$?
  done
fi
if_success "$Text3" "$Text4" "$ReturnStatus"

# 基础内容校验（避免 HTML/空文件）
if ! grep -Eq '^(proxies:|proxy-groups:|rules:|mixed-port:|port:)' "$Temp_Dir/clash.yaml"; then
  echo -e "\033[31m[ERROR]\033[0m 下载内容不像 Clash 配置（缺少关键字段），请检查订阅是否返回了网页/登录页/错误信息。"
  echo -e "可执行：head -n 20 $Temp_Dir/clash.yaml 查看内容"
  exit 1
fi

\cp -a "$Temp_Dir/clash.yaml" "$Temp_Dir/clash_config.yaml"

# subconverter
# shellcheck disable=SC1090
source "$Server_Dir/scripts/resolve_subconverter.sh"
if [ "${Subconverter_Ready:-false}" = "true" ]; then
  echo -e '\n判断订阅内容是否符合clash配置文件标准:'
  export SUBCONVERTER_BIN="$Subconverter_Bin"
  bash "$Server_Dir/scripts/clash_profile_conversion.sh"
  sleep 1
else
  echo -e "\033[33m[WARN] 未检测到可用的 subconverter，跳过订阅转换\033[0m"
fi

# ========= 生成最终 config.yaml =========
# 兼容两类订阅：
# A) 全量 config（包含 port/mixed-port 等），直接用订阅为主
# B) 仅节点列表（含 proxies:），用 templete + proxies 合并
FULL_CONFIG=false
if grep -Eq '^(port:|mixed-port:|socks-port:|redir-port:)' "$Temp_Dir/clash_config.yaml"; then
  FULL_CONFIG=true
fi

if [ "$FULL_CONFIG" = "true" ]; then
  echo -e "\n检测到订阅为【全量配置】模式，直接使用订阅生成 config.yaml"
  \cp -a "$Temp_Dir/clash_config.yaml" "$Temp_Dir/config.yaml"
else
  echo -e "\n检测到订阅为【节点/片段】模式，使用 templete 合并 proxies"
  if [ ! -f "$Temp_Dir/templete_config.yaml" ]; then
    echo -e "\033[31m[ERROR]\033[0m 未找到 templete_config.yaml：$Temp_Dir/templete_config.yaml"
    exit 1
  fi

  sed -n '/^proxies:/,$p' "$Temp_Dir/clash_config.yaml" > "$Temp_Dir/proxy.txt"
  cat "$Temp_Dir/templete_config.yaml" > "$Temp_Dir/config.yaml"
  cat "$Temp_Dir/proxy.txt" >> "$Temp_Dir/config.yaml"
fi

# 替换占位符（仅在 templete 模式才会命中；全量模式下无害）
sed -i "s/CLASH_HTTP_PORT_PLACEHOLDER/${CLASH_HTTP_PORT}/g" "$Temp_Dir/config.yaml"
sed -i "s/CLASH_SOCKS_PORT_PLACEHOLDER/${CLASH_SOCKS_PORT}/g" "$Temp_Dir/config.yaml"
sed -i "s/CLASH_REDIR_PORT_PLACEHOLDER/${CLASH_REDIR_PORT}/g" "$Temp_Dir/config.yaml"
sed -i "s/CLASH_LISTEN_IP_PLACEHOLDER/${CLASH_LISTEN_IP}/g" "$Temp_Dir/config.yaml"
sed -i "s/CLASH_ALLOW_LAN_PLACEHOLDER/${CLASH_ALLOW_LAN}/g" "$Temp_Dir/config.yaml"

# external-controller（全量 config 也允许覆盖/写入）
if [ "$EXTERNAL_CONTROLLER_ENABLED" = "true" ]; then
  # 如果已经有 external-controller 则替换；没有则追加
  if grep -qE '^external-controller:' "$Temp_Dir/config.yaml"; then
    sed -i "s@^external-controller:.*@external-controller: ${EXTERNAL_CONTROLLER}@g" "$Temp_Dir/config.yaml"
  else
    echo "external-controller: ${EXTERNAL_CONTROLLER}" >> "$Temp_Dir/config.yaml"
  fi
else
  # 禁用：若存在则注释
  sed -i "s@^external-controller:.*@# external-controller: disabled@g" "$Temp_Dir/config.yaml" || true
fi

apply_tun_config "$Temp_Dir/config.yaml"
apply_mixin_config "$Temp_Dir/config.yaml" "$Server_Dir"

\cp "$Temp_Dir/config.yaml" "$Conf_Dir/config.yaml"

# Dashboard
Work_Dir="$(cd "$(dirname "$0")" && pwd)"
Dashboard_Dir="${Work_Dir}/dashboard/public"
if [ "$EXTERNAL_CONTROLLER_ENABLED" = "true" ]; then
  # 若有 external-ui 注释行则替换；否则追加
  if grep -qE '^(#\s*)?external-ui:' "$Conf_Dir/config.yaml"; then
    sed -ri "s@^(#\s*)?external-ui:.*@external-ui: ${Dashboard_Dir}@g" "$Conf_Dir/config.yaml"
  else
    echo "external-ui: ${Dashboard_Dir}" >> "$Conf_Dir/config.yaml"
  fi
fi

# 写入 secret（用 awk 重写，避免 sed 转义问题）
tmpfile="$(mktemp)"
awk -v sec="$Secret" '
  BEGIN{done=0}
  /^secret:/ {print "secret: " sec; done=1; next}
  {print}
  END{ if(done==0) print "secret: " sec }
' "$Conf_Dir/config.yaml" > "$tmpfile"
mv "$tmpfile" "$Conf_Dir/config.yaml"

echo -e "\n订阅更新完成，如需生效请执行: bash restart.sh\n"
