#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${ROOT}/tools/firewall_lib.sh"
source "${ROOT}/tools/github_fetch.sh"

PO0_INSTALL_DIR="${PO0_INSTALL_DIR:-/opt/po0_whitelist}"
PO0_BIN="${PO0_BIN:-/usr/local/bin/p}"
PO0_STATE_DIR="${PO0_STATE_DIR:-/var/lib/po0_whitelist}"
PO0_SELECTION_FILE="${PO0_SELECTION_FILE:-${PO0_STATE_DIR}/last_selection.json}"
PO0_TOKEN_FILE="${PO0_TOKEN_FILE:-${PO0_STATE_DIR}/mailbox.token}"
PO0_MAILBOX_CONF="${PO0_MAILBOX_CONF:-${PO0_STATE_DIR}/mailbox.conf}"
if [[ -f "${PO0_MAILBOX_CONF}" ]]; then
  # shellcheck disable=SC1090
  source "${PO0_MAILBOX_CONF}"
fi
PO0_MAILBOX_HOST="${PO0_MAILBOX_HOST:-}"
PO0_MAILBOX_PORT="${PO0_MAILBOX_PORT:-18443}"
if [[ -n "${PO0_MAILBOX_HOST}" ]]; then
  PO0_MAILBOX_URL="${PO0_MAILBOX_URL:-http://${PO0_MAILBOX_HOST}:${PO0_MAILBOX_PORT}}"
else
  PO0_MAILBOX_URL="${PO0_MAILBOX_URL:-}"
fi

usage() {
  cat <<'EOF'
po0 省/市白名单一键脚本

用法：
  ./install.sh apply     交互选择地区并应用防火墙
  ./install.sh dry-run   交互选择地区，只打印将执行的命令
  ./install.sh status    查看当前托管规则
  ./install.sh clear     清除本脚本创建的规则和 ipset
  ./install.sh setup     安装到本机并添加快捷命令 p
  ./install.sh update    拉取最新 IP 库，并按上次选择的省市自动重灌
  ./install.sh reapply   不拉仓库，按上次省市重新应用
  ./install.sh token            显示 Loon 要填的信箱地址和 Token
  ./install.sh mailbox-config   配置海外信箱地址/端口/Token
  ./install.sh clients          查看已从信箱取回的直连 IP
  ./install.sh pull             从海外信箱拉取直连 IP 并写入 ipset
  ./install.sh add-ip           手动把一个 IPv4 加入直连白名单
  ./install.sh uninstall        卸载本机快捷命令、定时拉取和安装目录
  ./install.sh                  不带参数则进入交互菜单

说明：
  安装完成后输入 p 进入菜单。也可直接 p apply / p update 等。
  apply 会让未命中白名单的所有入站端口全部拒绝。
  apply 成功后会记住所选省市；之后更新可按上次选择重灌。
  Loon 报到海外信箱，防火墙机器只出站拉取，国内机器不开 HTTP 口。
EOF
}

pick_by_indices() {
  local prompt="$1"
  local max="$2"
  local input
  while true; do
    read -r -p "${prompt}" input
    input="${input//,/ }"
    [[ -n "${input}" ]] || continue
    local ok=1
    for value in ${input}; do
      if ! [[ "${value}" =~ ^[0-9]+$ ]] || (( value < 1 || value > max )); then
        ok=0
      fi
    done
    if [[ "${ok}" -eq 1 ]]; then
      echo "${input}"
      return
    fi
    echo "输入无效，请输入 1-${max} 范围内的编号，可用空格或逗号分隔。"
  done
}

split_user_list() {
  local input="$1"
  input="${input//,/ }"
  input="${input//，/ }"
  input="${input//、/ }"
  printf '%s\n' ${input}
}

read_from_tty() {
  local prompt="$1"
  local value
  if [[ -r /dev/tty ]]; then
    read -r -p "${prompt}" value < /dev/tty
  else
    read -r -p "${prompt}" value
  fi
  printf '%s\n' "${value}"
}

code_at_index() {
  local rows="$1"
  local index="$2"
  awk -F '\t' -v wanted="${index}" '$1 == wanted {print $2}' <<<"${rows}"
}

interactive_select_codes() {
  SELECTED_CODES=()
  echo "请选择省/自治区/直辖市：" >&2
  po0_show_provinces >&2
  echo >&2
  echo "输入编号或省份名称，多个用空格/逗号分隔，例如：1 2 广东省 江苏省" >&2

  local province_input
  province_input="$(read_from_tty "省份: ")"
  [[ -n "${province_input}" ]] || {
    echo "未输入省份。" >&2
    exit 1
  }

  local province_selector province_code city_input city_selector city_code
  while IFS= read -r province_selector; do
    [[ -n "${province_selector}" ]] || continue
    province_code="$(po0_resolve_province "${province_selector}")"

    echo >&2
    po0_show_cities "${province_code}" >&2
    echo "输入 0/全省/全市，或输入城市编号/城市名称，多个用空格/逗号分隔，例如：1 2 深圳市 广州市" >&2
    city_input="$(read_from_tty "城市: ")"
    [[ -n "${city_input}" ]] || {
      echo "未输入城市选择。" >&2
      exit 1
    }

    if [[ "${city_input}" == "0" || "${city_input}" == "全省" || "${city_input}" == "全市" ]]; then
      SELECTED_CODES+=("${province_code}")
    else
      while IFS= read -r city_selector; do
        [[ -n "${city_selector}" ]] || continue
        city_code="$(po0_resolve_city "${province_code}" "${city_selector}")"
        SELECTED_CODES+=("${city_code}")
      done < <(split_user_list "${city_input}")
    fi
  done < <(split_user_list "${province_input}")
}

confirm_client_ip() {
  local client_ip="$1"
  if [[ -z "${client_ip}" ]]; then
    echo ""
    return
  fi

  echo "检测到当前 SSH 客户端 IP：${client_ip}" >&2
  read -r -p "是否临时加入本次白名单以避免断连？[Y/n] " answer
  case "${answer:-Y}" in
    y|Y|yes|YES) echo "${client_ip}" ;;
    *) echo "" ;;
  esac
}

run_apply_or_dry_run() {
  local dry_run="$1"
  local -a selected_codes
  interactive_select_codes
  selected_codes=("${SELECTED_CODES[@]}")
  if [[ "${#selected_codes[@]}" -eq 0 ]]; then
    echo "未选择任何地区。" >&2
    exit 1
  fi

  local client_ip
  client_ip="$(confirm_client_ip "$(po0_detect_ssh_client_ip)")"

  echo
  echo "将使用以下地区代码：${selected_codes[*]}"
  echo

  if [[ "${dry_run}" == "1" ]]; then
    po0_render_apply_commands "${client_ip}" "${selected_codes[@]}"
    return
  fi

  po0_require_root
  po0_require_commands
  echo "即将应用规则：未命中白名单的所有入站端口都会被拒绝。"
  read -r -p "确认继续？输入 YES: " confirm
  if [[ "${confirm}" != "YES" ]]; then
    echo "已取消。"
    exit 0
  fi
  po0_render_apply_commands "${client_ip}" "${selected_codes[@]}" | po0_run_rendered_commands
  save_selection "${selected_codes[@]}"
  echo "规则已应用。已记住本次省市选择，之后 p update 会按这次自动重灌。"
  stop_legacy_report_service
  install_pull_timer
  pull_mailbox || true
}

save_selection() {
  po0_region_tool save-selection --file "${PO0_SELECTION_FILE}" "$@"
}

load_selection_codes() {
  po0_region_tool load-selection --file "${PO0_SELECTION_FILE}"
}

apply_saved_selection() {
  local reason="${1:-reapply}"
  if [[ ! -f "${PO0_SELECTION_FILE}" ]]; then
    echo "还没有保存过省市选择。请先运行 p 交互选择一次。" >&2
    return 1
  fi

  local -a selected_codes=()
  local code
  while IFS= read -r code; do
    [[ -n "${code}" ]] || continue
    selected_codes+=("${code}")
  done < <(load_selection_codes)

  if [[ "${#selected_codes[@]}" -eq 0 ]]; then
    echo "保存的省市选择为空。" >&2
    return 1
  fi

  echo "按上次选择重灌（${reason}）："
  po0_region_tool describe-codes "${selected_codes[@]}"

  local client_ip
  client_ip="$(po0_detect_ssh_client_ip)"
  if [[ -n "${client_ip}" ]]; then
    echo "自动把当前 SSH 客户端 IP ${client_ip} 加入本次白名单，避免断连。"
  fi

  po0_require_root
  po0_require_commands
  po0_render_apply_commands "${client_ip}" "${selected_codes[@]}" | po0_run_rendered_commands
  stop_legacy_report_service
  install_pull_timer
  pull_mailbox || true
  echo "已按上次省市选择重新应用规则。"
}

status_rules() {
  po0_require_root
  echo "== ipset: ${PO0_SET_NAME} =="
  if command -v ipset >/dev/null 2>&1; then
    ipset list "${PO0_SET_NAME}" 2>/dev/null || true
  else
    echo "ipset 未安装"
  fi
  echo
  echo "== iptables chain: ${PO0_CHAIN_NAME} =="
  if command -v iptables >/dev/null 2>&1; then
    iptables -S "${PO0_CHAIN_NAME}" 2>/dev/null || true
  else
    echo "iptables 未安装"
  fi
}

clear_rules() {
  po0_require_root
  po0_require_commands
  po0_render_clear_commands | po0_run_rendered_commands
  echo "已清除本脚本管理的规则。"
}

install_shortcut() {
  local target_root="${1:-${ROOT}}"
  po0_require_root
  mkdir -p "$(dirname "${PO0_BIN}")"
  cat > "${PO0_BIN}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
INSTALL_SH="${target_root}/install.sh"
if [[ ! -f "\${INSTALL_SH}" ]]; then
  echo "未找到 \${INSTALL_SH}，请重新安装 po0_whitelist。" >&2
  exit 1
fi
if [[ "\${EUID}" -ne 0 ]]; then
  exec sudo -- bash "\${INSTALL_SH}" "\$@"
fi
exec bash "\${INSTALL_SH}" "\$@"
EOF
  chmod 755 "${PO0_BIN}"
  echo "已安装快捷命令：p  ->  ${target_root}/install.sh"
}

ensure_mailbox_token() {
  mkdir -p "${PO0_STATE_DIR}"
  if [[ ! -s "${PO0_TOKEN_FILE}" ]]; then
    echo "还没有信箱 Token。请先在海外机器跑 mailbox-install.sh，再在本机执行 p mailbox-config" >&2
    return 1
  fi
  chmod 600 "${PO0_TOKEN_FILE}"
}

stop_legacy_report_service() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now po0-report.service 2>/dev/null || true
    rm -f /etc/systemd/system/po0-report.service
    systemctl daemon-reload 2>/dev/null || true
  fi
  if [[ -f "${PO0_STATE_DIR}/report.pid" ]]; then
    kill "$(cat "${PO0_STATE_DIR}/report.pid")" 2>/dev/null || true
    rm -f "${PO0_STATE_DIR}/report.pid"
  fi
}

pull_mailbox() {
  po0_require_root
  if [[ -z "${PO0_MAILBOX_URL}" ]]; then
    echo "还没有配置信箱地址。请先执行：p mailbox-config" >&2
    return 1
  fi
  ensure_mailbox_token || return 1
  command -v ipset >/dev/null 2>&1 || po0_require_commands
  local token ips ip
  token="$(cat "${PO0_TOKEN_FILE}")"
  ips="$(curl -fsS --connect-timeout 8 --max-time 15 \
    -H "Authorization: Bearer ${token}" \
    "${PO0_MAILBOX_URL}/list")" || {
    echo "从信箱拉取失败：${PO0_MAILBOX_URL}/list" >&2
    return 1
  }
  ipset create "${PO0_CLIENT_SET_NAME}" hash:ip family inet -exist
  while IFS= read -r ip; do
    [[ -n "${ip}" ]] || continue
    ipset add "${PO0_CLIENT_SET_NAME}" "${ip}" -exist
  done < <(python3 -c 'import json,sys; [print(ip) for ip in json.loads(sys.argv[1]).get("ips", [])]' "${ips}")
  echo "已从信箱同步直连 IP。"
}

install_pull_timer() {
  po0_require_root
  local script_root="${PO0_INSTALL_DIR}"
  [[ -x "${script_root}/install.sh" ]] || script_root="${ROOT}"
  if command -v systemctl >/dev/null 2>&1 && [[ -d /etc/systemd/system ]]; then
    cat > /etc/systemd/system/po0-mailbox-pull.service <<EOF
[Unit]
Description=Pull client IPs from overseas mailbox
After=network-online.target

[Service]
Type=oneshot
Environment=PATH=/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/bin/bash ${script_root}/install.sh pull
EOF
    cat > /etc/systemd/system/po0-mailbox-pull.timer <<'EOF'
[Unit]
Description=Pull client IPs from overseas mailbox every minute

[Timer]
OnBootSec=20s
OnUnitActiveSec=60s
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now po0-mailbox-pull.timer
  fi
}

show_token() {
  po0_require_root
  if [[ ! -s "${PO0_TOKEN_FILE}" ]]; then
    echo "信箱 Token 还没放到 ${PO0_TOKEN_FILE}"
    echo "Loon 信箱地址: ${PO0_MAILBOX_HOST}"
    echo "Loon 信箱端口: ${PO0_MAILBOX_PORT}"
    return 1
  fi
  echo "Loon 信箱地址: ${PO0_MAILBOX_HOST}"
  echo "Loon 信箱端口: ${PO0_MAILBOX_PORT}"
  echo "Token: $(cat "${PO0_TOKEN_FILE}")"
  echo "Loon 插件: https://gh-proxy.com/https://raw.githubusercontent.com/rollingshmily/po0_whitelist/main/loon/po0-ip-report.plugin"
}

mailbox_config() {
  po0_require_root
  mkdir -p "${PO0_STATE_DIR}"
  local host port token
  host="$(read_from_tty "信箱公网 IP 或域名: ")"
  port="$(read_from_tty "信箱端口 [18443]: ")"
  token="$(read_from_tty "信箱 Token: ")"
  port="${port:-18443}"
  if [[ -z "${host}" || -z "${token}" ]]; then
    echo "地址和 Token 不能为空。" >&2
    exit 1
  fi
  cat > "${PO0_MAILBOX_CONF}" <<EOF
PO0_MAILBOX_HOST=${host}
PO0_MAILBOX_PORT=${port}
PO0_MAILBOX_URL=http://${host}:${port}
EOF
  chmod 600 "${PO0_MAILBOX_CONF}"
  printf '%s\n' "${token}" > "${PO0_TOKEN_FILE}"
  chmod 600 "${PO0_TOKEN_FILE}"
  PO0_MAILBOX_HOST="${host}"
  PO0_MAILBOX_PORT="${port}"
  PO0_MAILBOX_URL="http://${host}:${port}"
  install_pull_timer
  echo "信箱已配置。Loon 填地址 ${host}、端口 ${port}，Token 用刚才那把。"
  echo "请给该信箱 IP 在 Loon 里走 DIRECT。"
  pull_mailbox || true
}

show_clients() {
  po0_require_root
  if command -v ipset >/dev/null 2>&1; then
    ipset list "${PO0_CLIENT_SET_NAME}" 2>/dev/null || echo "还没有已上报的直连 IP"
  else
    echo "ipset 未安装"
  fi
}

add_manual_ip() {
  po0_require_root
  command -v ipset >/dev/null 2>&1 || po0_require_commands
  local ip
  ip="$(read_from_tty "要加白的 IPv4: ")"
  ip="${ip// /}"
  if [[ -z "${ip}" ]]; then
    echo "未输入 IP。" >&2
    return 1
  fi
  python3 -c 'import ipaddress,sys; ip=ipaddress.ip_address(sys.argv[1]); assert ip.version==4' "${ip}" || {
    echo "不是合法 IPv4。" >&2
    return 1
  }
  ipset create "${PO0_CLIENT_SET_NAME}" hash:ip family inet -exist
  ipset add "${PO0_CLIENT_SET_NAME}" "${ip}" -exist
  echo "已加入直连白名单：${ip}"
}

uninstall_local() {
  po0_require_root
  local confirm
  confirm="$(read_from_tty "确认卸载本机 po0 白名单脚本？输入 YES: ")"
  if [[ "${confirm}" != "YES" ]]; then
    echo "已取消。"
    return 0
  fi
  if command -v iptables >/dev/null 2>&1 && command -v ipset >/dev/null 2>&1; then
    po0_render_clear_commands | po0_run_rendered_commands || true
  fi
  stop_legacy_report_service
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now po0-mailbox-pull.timer 2>/dev/null || true
    rm -f /etc/systemd/system/po0-mailbox-pull.timer /etc/systemd/system/po0-mailbox-pull.service
    systemctl daemon-reload 2>/dev/null || true
  fi
  rm -f "${PO0_BIN}"
  if [[ -d "${PO0_INSTALL_DIR}" ]]; then
    rm -rf "${PO0_INSTALL_DIR}"
  fi
  local wipe
  wipe="$(read_from_tty "同时删除本机状态（信箱配置/Token/上次省市）？输入 YES: ")"
  if [[ "${wipe}" == "YES" ]]; then
    rm -rf "${PO0_STATE_DIR}"
  fi
  echo "本机脚本已卸载。海外信箱需在信箱机器上执行：sudo bash mailbox-install.sh uninstall"
}

show_menu() {
  local choice
  while true; do
    cat <<'EOF'

======== po0 白名单 ========
 1) 选择省市并应用
 2) 预览命令（不改防火墙）
 3) 按上次省市重灌
 4) 查看状态
 5) 清除省市规则
 6) 手动加一个直连 IP
 7) 配置海外信箱
 8) 从信箱拉取 IP
 9) 查看直连 IP 名单
10) 显示 Loon 地址和 Token
11) 更新脚本和 IP 库
12) 卸载本机脚本
 0) 退出
==========================
EOF
    choice="$(read_from_tty "请选择: ")"
    case "${choice}" in
      1) run_apply_or_dry_run 0 ;;
      2) run_apply_or_dry_run 1 ;;
      3) apply_saved_selection reapply || true ;;
      4) status_rules ;;
      5) clear_rules ;;
      6) add_manual_ip || true ;;
      7) mailbox_config ;;
      8) pull_mailbox || true ;;
      9) show_clients ;;
      10) show_token || true ;;
      11) update_from_github ;;
      12) uninstall_local; return 0 ;;
      0|q|Q) echo "Bye."; return 0 ;;
      *) echo "无效选择。" ;;
    esac
  done
}

setup_install() {
  po0_require_root
  if ! command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
    echo "未找到 python3/python，无法安装。" >&2
    exit 1
  fi
  mkdir -p "${PO0_INSTALL_DIR}"
  if [[ "$(cd "${ROOT}" && pwd)" != "$(cd "${PO0_INSTALL_DIR}" && pwd)" ]]; then
    tar -C "${ROOT}" --exclude .git --exclude __pycache__ -cf - . | tar -C "${PO0_INSTALL_DIR}" -xf -
  fi
  chmod 755 "${PO0_INSTALL_DIR}/install.sh"
  install_shortcut "${PO0_INSTALL_DIR}"
  stop_legacy_report_service
  if [[ -f "${PO0_MAILBOX_CONF}" ]]; then
    install_pull_timer
  fi
  echo "安装完成。输入 p 即可唤出白名单脚本。"
  echo "Loon 信箱请先在海外机器跑 mailbox-install.sh，再在本机 p mailbox-config"
}

update_from_github() {
  po0_require_root
  local tmp src
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' RETURN
  src="$(po0_fetch_latest_tree "${tmp}")"
  mkdir -p "${ROOT}/data/regions"
  find "${ROOT}/data/regions" -type f -name '*.txt' -delete
  cp -a "${src}/." "${ROOT}/"
  chmod 755 "${ROOT}/install.sh" "${ROOT}/bootstrap.sh"
  if [[ -d "${PO0_INSTALL_DIR}" && "$(cd "${ROOT}" && pwd)" != "$(cd "${PO0_INSTALL_DIR}" && pwd)" ]]; then
    find "${PO0_INSTALL_DIR}/data/regions" -type f -name '*.txt' -delete 2>/dev/null || true
    cp -a "${src}/." "${PO0_INSTALL_DIR}/"
    chmod 755 "${PO0_INSTALL_DIR}/install.sh"
    install_shortcut "${PO0_INSTALL_DIR}"
  else
    install_shortcut "${ROOT}"
  fi
  echo "已从 GitHub 同步最新 IP 库和脚本。"
  if [[ -f "${PO0_SELECTION_FILE}" ]]; then
    apply_saved_selection update
  else
    echo "还没有保存过省市选择，防火墙未改。先运行 p 选一次即可。"
  fi
}

main() {
  local command="${1:-menu}"
  case "${command}" in
    menu) show_menu ;;
    apply) run_apply_or_dry_run 0 ;;
    dry-run) run_apply_or_dry_run 1 ;;
    status) status_rules ;;
    clear) clear_rules ;;
    setup|install) setup_install ;;
    update) update_from_github ;;
    reapply) apply_saved_selection reapply ;;
    token) show_token ;;
    mailbox-config) mailbox_config ;;
    clients) show_clients ;;
    pull) pull_mailbox ;;
    add-ip) add_manual_ip ;;
    uninstall) uninstall_local ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
