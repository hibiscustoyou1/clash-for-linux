#!/bin/bash

Subconverter_Bin=""
Subconverter_Ready=false

Subconverter_Dir="${Server_Dir}/tools/subconverter"
Default_Bin="${Subconverter_Dir}/subconverter"

resolve_subconverter_arch() {
	local raw_arch="$1"
	case "$raw_arch" in
		x86_64|amd64)
			echo "linux-amd64"
			;;
		aarch64|arm64)
			echo "linux-arm64"
			;;
		armv7*|armv7l)
			echo "linux-armv7"
			;;
		*)
			echo ""
			;;
	esac
}

try_subconverter_bin() {
	local candidate="$1"
	if [ -n "$candidate" ] && [ -x "$candidate" ]; then
		Subconverter_Bin="$candidate"
		Subconverter_Ready=true
		return 0
	fi
	return 1
}

# ------------------------------------------------------------
# FIX: SUBCONVERTER_PATH may be unbound when parent shell uses `set -u`
# Use ${SUBCONVERTER_PATH:-} to avoid "unbound variable"
# ------------------------------------------------------------
SUBCONVERTER_PATH_SAFE="${SUBCONVERTER_PATH:-}"

if [ -n "$SUBCONVERTER_PATH_SAFE" ]; then
	try_subconverter_bin "$SUBCONVERTER_PATH_SAFE" && return 0
else
	try_subconverter_bin "$Default_Bin" && return 0
fi

Detected_Arch="${CpuArch:-$(uname -m 2>/dev/null)}"
Resolved_Arch="$(resolve_subconverter_arch "$Detected_Arch")"

if [ -n "$Resolved_Arch" ]; then
	try_subconverter_bin "${Subconverter_Dir}/subconverter-${Resolved_Arch}" && return 0
	try_subconverter_bin "${Subconverter_Dir}/bin/subconverter-${Resolved_Arch}" && return 0
	try_subconverter_bin "${Subconverter_Dir}/${Resolved_Arch}/subconverter" && return 0
fi

Default_Template="https://github.com/tindy2013/subconverter/releases/latest/download/subconverter_{arch}.tar.gz"
Auto_Download="${SUBCONVERTER_AUTO_DOWNLOAD:-auto}"

if [ "$Auto_Download" != "false" ] && [ -n "$Resolved_Arch" ]; then
	Download_Template="${SUBCONVERTER_DOWNLOAD_URL_TEMPLATE:-$Default_Template}"
	if [ -z "$Download_Template" ]; then
		echo -e "\033[33m[WARN] 未设置 SUBCONVERTER_DOWNLOAD_URL_TEMPLATE，跳过 subconverter 自动下载\033[0m"
		return 0
	fi

	Download_Url="${Download_Template//\{arch\}/${Resolved_Arch}}"

	# Ensure temp dirs exist
	mkdir -p "${Server_Dir}/temp" "${Subconverter_Dir}"

	Download_Archive="${Server_Dir}/temp/subconverter-${Resolved_Arch}.tar.gz"
	Extract_Dir="${Server_Dir}/temp/subconverter-${Resolved_Arch}"
	mkdir -p "${Extract_Dir}"

	if command -v curl >/dev/null 2>&1; then
		curl -L -sS -o "${Download_Archive}" "${Download_Url}"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "${Download_Archive}" "${Download_Url}"
	else
		echo -e "\033[33m[WARN] 未找到 curl 或 wget，无法自动下载 subconverter\033[0m"
		return 0
	fi

	# Only extract if archive exists and is non-empty
	if [ -s "${Download_Archive}" ]; then
		tar -xzf "${Download_Archive}" -C "${Extract_Dir}" 2>/dev/null
		Downloaded_Bin="$(find "${Extract_Dir}" -maxdepth 3 -type f -name "subconverter" -print -quit)"
		if [ -n "${Downloaded_Bin}" ]; then
			mv "${Downloaded_Bin}" "${Subconverter_Dir}/subconverter-${Resolved_Arch}"
			chmod +x "${Subconverter_Dir}/subconverter-${Resolved_Arch}"
			try_subconverter_bin "${Subconverter_Dir}/subconverter-${Resolved_Arch}" && return 0
		fi
	fi

	echo -e "\033[33m[WARN] subconverter 自动下载失败，跳过订阅转换\033[0m"
fi

return 0