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
PO0_MAILBOX_PULL_MINUTES="${PO0_MAILBOX_PULL_MINUTES:-5}"
if [[ -n "${PO0_MAILBOX_HOST}" ]]; then
  PO0_MAILBOX_URL="${PO0_MAILBOX_URL:-http://${PO0_MAILBOX_HOST}:${PO0_MAILBOX_PORT}}"
else
  PO0_MAILBOX_URL="${PO0_MAILBOX_URL:-}"
fi

usage() {
  cat <<'EOF'
po0 省/市白名单

用法：
  p / ./install.sh                 菜单
  p apply                          添加省市并应用
  p reapply                        应用上次选择
  p status                         当前规则
  p clear                          清除省市（保留客户端 IP）
  p clear-all                      清除全部
  p add-ip                         手动添加 IPv4
  p update                         更新脚本和 IP 库，并按上次选择应用
  p mailbox-config                 配置信箱
  p pull-interval                  修改拉取间隔（分钟）
  p pull                           立即从信箱拉取
  p clients                        客户端 IP 列表
  p token                          显示信箱地址与 Token
  p uninstall                      卸载
  p dry-run                        只打印将执行的命令
  p help                           命令说明

说明：
  省市白名单离线可用，信箱可选。国内机器不开 HTTP 口。
  apply 会拒绝未命中白名单的全部入站。成功后记住省市，update 按上次选择再应用。
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
  maybe_sync_mailbox
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
  maybe_sync_mailbox
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
  echo "已关掉地区白名单。手机直连 IP 名单还在。"
}

clear_all_rules() {
  po0_require_root
  po0_require_commands
  po0_render_clear_commands | po0_run_rendered_commands
  ipset destroy "${PO0_CLIENT_SET_NAME}" 2>/dev/null || true
  echo "已清除当前所有规则（地区白名单 + 手机直连 IP）。"
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

mailbox_configured() {
  [[ -n "${PO0_MAILBOX_URL:-}" && -s "${PO0_TOKEN_FILE}" ]]
}

maybe_sync_mailbox() {
  if ! mailbox_configured; then
    return 0
  fi
  install_pull_timer
  pull_mailbox || true
}

install_pull_timer() {
  po0_require_root
  mailbox_configured || return 0
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
    local minutes="${PO0_MAILBOX_PULL_MINUTES:-5}"
    cat > /etc/systemd/system/po0-mailbox-pull.timer <<EOF
[Unit]
Description=Pull client IPs from overseas mailbox every ${minutes} minutes

[Timer]
OnBootSec=30s
OnUnitActiveSec=${minutes}min
AccuracySec=30s

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

write_mailbox_conf() {
  mkdir -p "${PO0_STATE_DIR}"
  cat > "${PO0_MAILBOX_CONF}" <<EOF
PO0_MAILBOX_HOST=${PO0_MAILBOX_HOST}
PO0_MAILBOX_PORT=${PO0_MAILBOX_PORT}
PO0_MAILBOX_URL=${PO0_MAILBOX_URL}
PO0_MAILBOX_PULL_MINUTES=${PO0_MAILBOX_PULL_MINUTES}
EOF
  chmod 600 "${PO0_MAILBOX_CONF}"
}

set_pull_interval() {
  po0_require_root
  local minutes current
  current="${PO0_MAILBOX_PULL_MINUTES:-5}"
  minutes="$(read_from_tty "每隔几分钟从信箱拉一次 [${current}]: ")"
  minutes="${minutes:-${current}}"
  if ! [[ "${minutes}" =~ ^[1-9][0-9]*$ ]] || (( minutes > 1440 )); then
    echo "请输入 1 到 1440 的整数分钟。" >&2
    return 1
  fi
  PO0_MAILBOX_PULL_MINUTES="${minutes}"
  if [[ -n "${PO0_MAILBOX_HOST}" ]]; then
    write_mailbox_conf
  fi
  install_pull_timer
  echo "已改为每 ${minutes} 分钟拉一次。"
}

mailbox_config() {
  po0_require_root
  mkdir -p "${PO0_STATE_DIR}"
  local host port token minutes
  host="$(read_from_tty "信箱公网 IP 或域名: ")"
  port="$(read_from_tty "信箱端口 [18443]: ")"
  token="$(read_from_tty "信箱 Token: ")"
  minutes="$(read_from_tty "每隔几分钟拉一次 [5]: ")"
  port="${port:-18443}"
  minutes="${minutes:-5}"
  if [[ -z "${host}" || -z "${token}" ]]; then
    echo "地址和 Token 不能为空。" >&2
    exit 1
  fi
  if ! [[ "${minutes}" =~ ^[1-9][0-9]*$ ]] || (( minutes > 1440 )); then
    echo "拉取间隔请输入 1 到 1440 的整数分钟。" >&2
    exit 1
  fi
  printf '%s\n' "${token}" > "${PO0_TOKEN_FILE}"
  chmod 600 "${PO0_TOKEN_FILE}"
  PO0_MAILBOX_HOST="${host}"
  PO0_MAILBOX_PORT="${port}"
  PO0_MAILBOX_URL="http://${host}:${port}"
  PO0_MAILBOX_PULL_MINUTES="${minutes}"
  write_mailbox_conf
  install_pull_timer
  echo "信箱已配置。Loon 填地址 ${host}、端口 ${port}，Token 用刚才那把。"
  echo "本机每 ${minutes} 分钟拉一次。请给该信箱 IP 在 Loon 里走 DIRECT。"
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
  cd /
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

pause_menu() {
  read_from_tty "Enter 返回" >/dev/null || true
}

region_menu() {
  local choice
  while true; do
    cat <<'EOF'

省市白名单
 1) 添加省市
 2) 应用上次选择
 3) 当前规则
 4) 清除省市
 5) 清除全部
 6) 添加 IP
 0) 返回
EOF
    choice="$(read_from_tty "选择: ")"
    case "${choice}" in
      1) run_apply_or_dry_run 0; pause_menu ;;
      2) apply_saved_selection reapply || true; pause_menu ;;
      3) status_rules; pause_menu ;;
      4) clear_rules; pause_menu ;;
      5) clear_all_rules; pause_menu ;;
      6) add_manual_ip || true; pause_menu ;;
      0) return 0 ;;
      *) echo "无效选择。" ;;
    esac
  done
}

phone_menu() {
  local choice
  while true; do
    cat <<'EOF'

信箱
 1) 配置信箱
 2) 拉取间隔
 3) 立即拉取
 4) 客户端列表
 5) 查看 Token
 0) 返回
EOF
    choice="$(read_from_tty "选择: ")"
    case "${choice}" in
      1) mailbox_config; pause_menu ;;
      2) set_pull_interval || true; pause_menu ;;
      3) pull_mailbox || true; pause_menu ;;
      4) show_clients; pause_menu ;;
      5) show_token || true; pause_menu ;;
      0) return 0 ;;
      *) echo "无效选择。" ;;
    esac
  done
}

show_menu() {
  local choice
  while true; do
    cat <<'EOF'

po0 白名单
 1) 省市白名单
 2) 信箱
 3) 更新
 4) 卸载
 0) 退出
EOF
    choice="$(read_from_tty "选择: ")"
    case "${choice}" in
      1) region_menu ;;
      2) phone_menu ;;
      3) update_from_github; pause_menu ;;
      4) uninstall_local; return 0 ;;
      0|q|Q) echo "已退出。"; return 0 ;;
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

replace_install_tree() {
  local src="$1" dest="$2"
  mkdir -p "${dest}"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete --exclude '.git' "${src}/" "${dest}/"
  else
    python3 - "${src}" "${dest}" <<'PY'
import shutil, sys
from pathlib import Path
src, dest = Path(sys.argv[1]), Path(sys.argv[2])
dest.mkdir(parents=True, exist_ok=True)
wanted = set()
for path in src.rglob("*"):
    rel = path.relative_to(src)
    if str(rel) == ".git" or str(rel).startswith(".git/"):
        continue
    wanted.add(rel)
    target = dest / rel
    if path.is_dir():
        target.mkdir(parents=True, exist_ok=True)
    else:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, target)
for path in sorted(dest.rglob("*"), reverse=True):
    rel = path.relative_to(dest)
    if str(rel) == ".git" or str(rel).startswith(".git/"):
        continue
    if rel not in wanted:
        if path.is_dir():
            try:
                path.rmdir()
            except OSError:
                pass
        else:
            path.unlink()
PY
  fi
  chmod 755 "${dest}/install.sh" "${dest}/bootstrap.sh" "${dest}/mailbox-install.sh" 2>/dev/null || true
}

update_from_github() {
  po0_require_root
  local tmp src dest
  tmp="$(mktemp -d)"
  src="$(po0_fetch_latest_tree "${tmp}")"
  dest="${PO0_INSTALL_DIR}"
  mkdir -p "${dest}"
  replace_install_tree "${src}" "${dest}"
  if [[ "$(cd "${ROOT}" && pwd)" != "$(cd "${dest}" && pwd)" ]]; then
    replace_install_tree "${src}" "${ROOT}"
  fi
  install_shortcut "${dest}"
  rm -rf "${tmp}"
  echo "脚本和 IP 库已覆盖更新，正在加载新版本..."
  exec bash "${dest}/install.sh" __after_update
}

after_update() {
  if [[ -f "${PO0_SELECTION_FILE}" ]]; then
    apply_saved_selection update || true
  else
    echo "文件已更新。还没有保存过省市选择，防火墙未改。"
  fi
  if [[ -t 0 ]]; then
    show_menu
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
    clear-all) clear_all_rules ;;
    setup|install) setup_install ;;
    update) update_from_github ;;
    __after_update) after_update ;;
    reapply) apply_saved_selection reapply ;;
    token) show_token ;;
    mailbox-config) mailbox_config ;;
    pull-interval) set_pull_interval ;;
    clients) show_clients ;;
    pull) pull_mailbox ;;
    add-ip) add_manual_ip ;;
    uninstall) uninstall_local ;;
    -h|--help|help) usage ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
