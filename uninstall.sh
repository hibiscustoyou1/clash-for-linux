#!/usr/bin/env bash
set -euo pipefail

# =========================
# 基础参数（与 install.sh 对齐）
# =========================
Install_Dir="${CLASH_INSTALL_DIR:-/opt/clash-for-linux}"
Service_Name="clash-for-linux"
Service_User="${CLASH_SERVICE_USER:-clash}"
Service_Group="${CLASH_SERVICE_GROUP:-$Service_User}"

# 是否删除运行用户/组（默认不删，更安全；想删就 CLASH_REMOVE_USER=true）
CLASH_REMOVE_USER="${CLASH_REMOVE_USER:-false}"

# 彩色输出
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
# 1) 停止服务（systemd）
# =========================
if command -v systemctl >/dev/null 2>&1; then
  info "停止并禁用 systemd 服务..."
  systemctl stop "${Service_Name}.service" >/dev/null 2>&1 || true
  systemctl disable "${Service_Name}.service" >/dev/null 2>&1 || true
fi

# =========================
# 2) 兜底：杀掉残留进程（防止删目录后仍占端口）
#    - 优先按 PID 文件
#    - 再按二进制名/路径兜底
# =========================
PID_FILE=""
if [ -d "${Install_Dir}/temp" ] && [ -f "${Install_Dir}/temp/clash.pid" ]; then
  PID_FILE="${Install_Dir}/temp/clash.pid"
fi

if [ -n "$PID_FILE" ]; then
  PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "${PID:-}" ] && kill -0 "$PID" 2>/dev/null; then
    info "检测到 PID_FILE 进程：PID=${PID}，尝试停止..."
    kill "$PID" 2>/dev/null || true
    sleep 1
    if kill -0 "$PID" 2>/dev/null; then
      warn "进程仍在运行，执行强制停止：kill -9 ${PID}"
      kill -9 "$PID" 2>/dev/null || true
    fi
    ok "已停止 clash 进程（PID_FILE）"
  fi
fi

# 兜底：按进程名
if pgrep -x clash >/dev/null 2>&1; then
  warn "检测到残留 clash 进程，执行 pkill..."
  pkill clash >/dev/null 2>&1 || true
  sleep 1
fi
if pgrep -x clash >/dev/null 2>&1; then
  warn "clash 仍残留，执行 pkill -9..."
  pkill -9 clash >/dev/null 2>&1 || true
fi

# =========================
# 3) 清理 systemd unit（兼容不同路径）
# =========================
remove_unit_file() {
  local p="$1"
  if [ -f "$p" ]; then
    rm -f "$p"
    ok "已移除 unit: $p"
  fi
}

remove_unit_file "/etc/systemd/system/${Service_Name}.service"
remove_unit_file "/usr/lib/systemd/system/${Service_Name}.service"
remove_unit_file "/lib/systemd/system/${Service_Name}.service"

# reload systemd
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed >/dev/null 2>&1 || true
fi

# =========================
# 4) 清理 drop-in（如果有）
# =========================
if [ -d "/etc/systemd/system/${Service_Name}.service.d" ]; then
  rm -rf "/etc/systemd/system/${Service_Name}.service.d"
  ok "已移除 drop-in: /etc/systemd/system/${Service_Name}.service.d"
fi

# =========================
# 5) 清理环境变量脚本 / 默认配置
# =========================
if [ -f "/etc/default/${Service_Name}" ]; then
  rm -f "/etc/default/${Service_Name}"
  ok "已移除: /etc/default/${Service_Name}"
fi

if [ -f "/etc/profile.d/clash-for-linux.sh" ]; then
  rm -f "/etc/profile.d/clash-for-linux.sh"
  ok "已移除: /etc/profile.d/clash-for-linux.sh"
fi

# 兼容旧版遗留
if [ -f "/etc/profile.d/clash.sh" ]; then
  warn "检测到旧版 /etc/profile.d/clash.sh（非本脚本必然生成），如确认无用可手动删除"
fi

# =========================
# 6) 清理命令入口
# =========================
if [ -f "/usr/local/bin/clashctl" ]; then
  rm -f "/usr/local/bin/clashctl"
  ok "已移除: /usr/local/bin/clashctl"
fi

# =========================
# 7) 清理安装目录
# =========================
if [ -d "$Install_Dir" ]; then
  rm -rf "$Install_Dir"
  ok "已移除安装目录: ${Install_Dir}"
else
  warn "未找到安装目录: ${Install_Dir}"
fi

# =========================
# 8) 可选：删除运行用户/组（默认不删）
# =========================
if [ "$CLASH_REMOVE_USER" = "true" ]; then
  warn "CLASH_REMOVE_USER=true：将尝试删除运行用户/组（若存在且无依赖）"

  # 先删用户
  if id "$Service_User" >/dev/null 2>&1; then
    userdel "$Service_User" >/dev/null 2>&1 || true
    ok "已删除用户: ${Service_User}（如有依赖可能未删除，请检查）"
  fi

  # 再删组（仅当组存在且无成员依赖时）
  if getent group "$Service_Group" >/dev/null 2>&1; then
    groupdel "$Service_Group" >/dev/null 2>&1 || true
    ok "已删除组: ${Service_Group}（如有依赖可能未删除，请检查）"
  fi
else
  info "默认不删除用户/组（更安全）。如需删除：CLASH_REMOVE_USER=true sudo bash uninstall.sh"
fi

# =========================
# 9) 清理当前 shell 的代理变量提示（不修改你的 shell，只提示）
# =========================
echo
warn "如果你之前开启过 proxy_on，当前终端可能还残留代理环境变量。可执行："
echo "  unset http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY"
echo "  # 或重新打开一个新终端"

echo
ok "卸载完成 ✅"
