#!/usr/bin/env bash
# 在海外机器上安装 Loon 上报信箱。国内防火墙机器不要跑这个脚本。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${PO0_MAILBOX_DIR:-/opt/po0-mailbox}"
STATE_DIR="${PO0_MAILBOX_STATE:-/var/lib/po0-mailbox}"
TOKEN_FILE="${PO0_MAILBOX_TOKEN_FILE:-${STATE_DIR}/token}"
STORE_FILE="${PO0_MAILBOX_STORE:-${STATE_DIR}/clients.json}"
ENV_FILE="${PO0_MAILBOX_ENV:-/etc/default/po0-mailbox}"
UNIT_FILE="/etc/systemd/system/po0-mailbox.service"

read_default() {
  local prompt="$1"
  local default="$2"
  local value=""
  if [[ -r /dev/tty ]]; then
    read -r -p "${prompt}" value < /dev/tty
  else
    read -r -p "${prompt}" value
  fi
  if [[ -z "${value}" ]]; then
    printf '%s\n' "${default}"
  else
    printf '%s\n' "${value}"
  fi
}

if [[ "${EUID}" -ne 0 ]]; then
  echo "请用 root 或 sudo 运行。" >&2
  exit 1
fi

if [[ "${1:-}" == "uninstall" ]]; then
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now po0-mailbox.service 2>/dev/null || true
    rm -f "${UNIT_FILE}"
    systemctl daemon-reload 2>/dev/null || true
  fi
  rm -rf "${INSTALL_DIR}"
  echo "信箱服务已停。是否删除 Token 和已上报 IP？"
  confirm="$(read_default "输入 YES 删除状态目录: " "")"
  if [[ "${confirm}" == "YES" ]]; then
    rm -rf "${STATE_DIR}" "${ENV_FILE}"
  fi
  echo "海外信箱已卸载。"
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "需要 python3。" >&2
  exit 1
fi

echo "=== po0 信箱安装（海外机器）==="
echo "国内要做 iptables 白名单的机器不要装这个，只装 install.sh。"
echo

PORT="$(read_default "监听端口 [18443]: " "18443")"
PULL_ALLOW="$(read_default "允许拉取名单的源 IP（国内机器访问信箱时的源地址，多个用逗号/空格都行）: " "")"
if [[ -z "${PULL_ALLOW}" ]]; then
  echo "必须填写至少一个拉取源 IP，否则防火墙机器取不回名单。" >&2
  exit 1
fi

mkdir -p "${INSTALL_DIR}" "${STATE_DIR}"
chmod 700 "${STATE_DIR}"
cp -a "${ROOT}/tools/mailbox_server.py" "${INSTALL_DIR}/mailbox_server.py"
chmod 755 "${INSTALL_DIR}/mailbox_server.py"

if [[ ! -s "${TOKEN_FILE}" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16 > "${TOKEN_FILE}"
  else
    python3 -c 'import secrets; print(secrets.token_hex(16))' > "${TOKEN_FILE}"
  fi
fi
chmod 600 "${TOKEN_FILE}"
TOKEN="$(tr -d '\n' < "${TOKEN_FILE}")"

cat > "${ENV_FILE}" <<EOF
PO0_MAILBOX_PORT=${PORT}
PO0_MAILBOX_BIND=0.0.0.0
PO0_MAILBOX_TOKEN_FILE=${TOKEN_FILE}
PO0_MAILBOX_STORE=${STORE_FILE}
PO0_MAILBOX_PULL_ALLOW="${PULL_ALLOW}"
EOF
chmod 600 "${ENV_FILE}"

if command -v systemctl >/dev/null 2>&1 && [[ -d /etc/systemd/system ]]; then
  cat > "${UNIT_FILE}" <<EOF
[Unit]
Description=po0 Loon IP mailbox
After=network-online.target

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
Environment=PATH=/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/mailbox_server.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now po0-mailbox.service
else
  echo "没有 systemd，请自行后台运行："
  echo "  set -a; source ${ENV_FILE}; set +a; nohup python3 ${INSTALL_DIR}/mailbox_server.py &"
fi

PUBLIC_HINT="$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"

echo
echo "信箱已安装。"
echo "Loon 插件请填："
echo "  信箱地址 = 这台海外机器的公网 IP${PUBLIC_HINT:+（当前检测到 ${PUBLIC_HINT}）}"
echo "  信箱端口 = ${PORT}"
echo "  Token     = ${TOKEN}"
echo
echo "国内防火墙机器上执行："
echo "  sudo bash install.sh mailbox-config"
echo "然后填写上面的地址、端口、Token。"
echo
echo "请给信箱公网 IP 配 Loon DIRECT，不要走代理。"
