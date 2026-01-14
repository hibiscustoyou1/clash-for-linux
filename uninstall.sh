#!/usr/bin/env bash
set -euo pipefail

# =========================
# 参数（对标 install.sh + install_systemd.sh）
# =========================
Install_Dir="${CLASH_INSTALL_DIR:-/opt/clash-for-linux}"
Service_Name="clash-for-linux"
Service_User="${CLASH_SERVICE_USER:-clash}"
Service_Group="${CLASH_SERVICE_GROUP:-$Service_User}"
Unit_Path="/etc/systemd/system/${Service_Name}.service"

# 可选：删除运行用户/组（默认不删）
CLASH_REMOVE_USER="${CLASH_REMOVE_USER:-false}"

# =========================
# 彩色输出
# =========================
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }

# =========================
# 前置校验
# =========================
if [ "$(id -u)" -ne 0 ]; then
  err "需要 root 权限执行卸载脚本（请使用 sudo bash uninstall.sh）"
  exit 1
fi

info "开始卸载 ${Service_Name} ..."
info "Install_Dir=${Install_Dir}"

# =========================
# 1) 优雅停止（优先 shutdown.sh，再 systemd）
# =========================
if [ -f "${Install_Dir}/shutdown.sh" ]; then
  info "执行 shutdown.sh（优雅停止）..."
  bash "${Install_Dir}/shutdown.sh" >/dev/null 2>&1 || true
fi

if command -v systemctl >/dev/null 2>&1; then
  info "停止并禁用 systemd 服务..."
  systemctl stop "${Service_Name}.service" >/dev/null 2>&1 || true
  systemctl disable "${Service_Name}.service" >/dev/null 2>&1 || true
fi

# =========================
# 2) 兜底：按 PID 文件杀进程（对标 unit 的 PIDFile）
# =========================
PID_FILE="${Install_Dir}/temp/clash.pid"
if [ -f "$PID_FILE" ]; then
  PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "${PID:-}" ] && kill -0 "$PID" 2>/dev/null; then
    info "检测到 PID=${PID}，尝试停止..."
    kill "$PID" 2>/dev/null || true
    sleep 1
    if kill -0 "$PID" 2>/dev/null; then
      warn "进程仍在运行，强制 kill -9 ${PID}"
      kill -9 "$PID" 2>/dev/null || true
    fi
    ok "已停止 clash 进程（PIDFile）"
  fi
fi

# 再兜底：按进程名（系统可能有多个 clash，不建议无脑 pkill -9；先提示再杀）
if pgrep -x clash >/dev/null 2>&1; then
  warn "检测到仍有 clash 进程存在（可能非本项目），尝试温和结束..."
  pkill -x clash >/dev/null 2>&1 || true
  sleep 1
fi
if pgrep -x clash >/dev/null 2>&1; then
  warn "仍残留 clash 进程，执行 pkill -9（可能影响其它 clash 实例）..."
  pkill -9 -x clash >/dev/null 2>&1 || true
fi

# =========================
# 3) 删除 systemd unit（对标 install_systemd.sh）
# =========================
if [ -f "$Unit_Path" ]; then
  rm -f "$Unit_Path"
  ok "已移除 systemd 单元: ${Unit_Path}"
fi

# drop-in（万一用户自定义过）
if [ -d "/etc/systemd/system/${Service_Name}.service.d" ]; then
  rm -rf "/etc/systemd/system/${Service_Name}.service.d"
  ok "已移除 drop-in: /etc/systemd/system/${Service_Name}.service.d"
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed >/dev/null 2>&1 || true
fi

# =========================
# 4) 清理默认配置/环境脚本/命令入口
# =========================
if [ -f "/etc/default/${Service_Name}" ]; then
  rm -f "/etc/default/${Service_Name}"
  ok "已移除: /etc/default/${Service_Name}"
fi

# 运行时 Env_File 可能写到 /etc/profile.d 或 temp，这里都清
if [ -f "/etc/profile.d/clash-for-linux.sh" ]; then
  rm -f "/etc/profile.d/clash-for-linux.sh"
  ok "已移除: /etc/profile.d/clash-for-linux.sh"
fi

if [ -f "${Install_Dir}/temp/clash-for-linux.sh" ]; then
  rm -f "${Install_Dir}/temp/clash-for-linux.sh" || true
  ok "已移除: ${Install_Dir}/temp/clash-for-linux.sh"
fi

if [ -f "/usr/local/bin/clashctl" ]; then
  rm -f "/usr/local/bin/clashctl"
  ok "已移除: /usr/local/bin/clashctl"
fi

# =========================
# 5) 删除安装目录
# =========================
if [ -d "$Install_Dir" ]; then
  rm -rf "$Install_Dir"
  ok "已移除安装目录: ${Install_Dir}"
else
  warn "未找到安装目录: ${Install_Dir}"
fi

# =========================
# 6) 可选：删除运行用户/组（默认不删）
# =========================
if [ "$CLASH_REMOVE_USER" = "true" ]; then
  warn "CLASH_REMOVE_USER=true：将尝试删除运行用户/组（若存在且无依赖）"

  if id "$Service_User" >/dev/null 2>&1; then
    userdel "$Service_User" >/dev/null 2>&1 || true
    ok "已尝试删除用户: ${Service_User}"
  fi

  if getent group "$Service_Group" >/dev/null 2>&1; then
    groupdel "$Service_Group" >/dev/null 2>&1 || true
    ok "已尝试删除组: ${Service_Group}"
  fi
else
  info "默认不删除用户/组。若确认无其它用途，可用：CLASH_REMOVE_USER=true sudo bash uninstall.sh"
fi

# =========================
# 7) 提示：当前终端代理变量需要手动清
# =========================
echo
warn "如果你曾执行 proxy_on，当前终端可能仍保留代理环境变量。可执行："
echo "  unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY"
echo "  # 或关闭终端重新打开"

echo
ok "卸载完成 ✅"
