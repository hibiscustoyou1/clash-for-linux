#!/bin/bash

PORT_CHECK_WARNED=${PORT_CHECK_WARNED:-0}

is_port_in_use() {
	local port="$1"
	if command -v ss >/dev/null 2>&1; then
		ss -lnt | awk '{print $4}' | grep -E "(:|\.)${port}$" >/dev/null 2>&1
		return $?
	fi
	if command -v netstat >/dev/null 2>&1; then
		netstat -lnt | awk '{print $4}' | grep -E "(:|\.)${port}$" >/dev/null 2>&1
		return $?
	fi
	if command -v lsof >/dev/null 2>&1; then
		lsof -iTCP -sTCP:LISTEN -P -n | awk '{print $9}' | grep -E "(:|\.)${port}$" >/dev/null 2>&1
		return $?
	fi
	if [ "$PORT_CHECK_WARNED" -eq 0 ]; then
		echo -e "\033[33m[WARN] 未找到端口检测工具，端口冲突检测可能不准确\033[0m" >&2
		PORT_CHECK_WARNED=1
	fi
	return 1
}

find_available_port() {
	local start_port=${1:-20000}
	local end_port=${2:-65000}
	local port

	if command -v shuf >/dev/null 2>&1; then
		for _ in {1..50}; do
			port=$(shuf -i "${start_port}-${end_port}" -n 1)
			if ! is_port_in_use "$port"; then
				echo "$port"
				return 0
			fi
		done
	fi

	for port in $(seq "$start_port" "$end_port"); do
		if ! is_port_in_use "$port"; then
			echo "$port"
			return 0
		fi
	done

	return 1
}

resolve_port_value() {
	local name="$1"
	local value="$2"
	local resolved

	if [ -z "$value" ] || [ "$value" = "auto" ]; then
		resolved=$(find_available_port)
		if [ -z "$resolved" ]; then
			return 1
		fi
		echo -e "\033[33m[WARN] ${name} 端口已自动分配为 ${resolved}\033[0m" >&2
		echo "$resolved"
		return 0
	fi

	if [[ "$value" =~ ^[0-9]+$ ]]; then
		if is_port_in_use "$value"; then
			resolved=$(find_available_port)
			if [ -n "$resolved" ]; then
				echo -e "\033[33m[WARN] ${name} 端口 ${value} 已被占用，已自动切换为 ${resolved}\033[0m" >&2
				echo "$resolved"
				return 0
			fi
		fi
	fi

	echo "$value"
}

resolve_host_port() {
	local name="$1"
	local raw="$2"
	local default_host="$3"
	local host
	local port

	if [ "$raw" = "auto" ] || [ -z "$raw" ]; then
		host="$default_host"
		port="auto"
	else
		if [[ "$raw" == *:* ]]; then
			host="${raw%:*}"
			port="${raw##*:}"
		else
			host="$default_host"
			port="$raw"
		fi
	fi

	port=$(resolve_port_value "$name" "$port") || return 1
	echo "${host}:${port}"
}
