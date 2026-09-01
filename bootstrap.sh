#!/usr/bin/env bash
# 国内机器一键安装：优先走 gh-proxy.com 拉 GitHub 包。
# 用法：
#   curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/rollingshmily/po0_whitelist/main/bootstrap.sh | sudo bash
set -euo pipefail

REPO="${PO0_REPO:-rollingshmily/po0_whitelist}"
BRANCH="${PO0_BRANCH:-main}"
INSTALL_DIR="${PO0_INSTALL_DIR:-/opt/po0_whitelist}"
ARCHIVE_URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"

MIRRORS=(
  "https://gh-proxy.com/"
  "https://ghfast.top/"
)

if [[ "${EUID}" -ne 0 ]]; then
  echo "请用 root 或 sudo 运行：curl -fsSL <bootstrap.sh> | sudo bash" >&2
  exit 1
fi

# 人如果还停在 /opt/po0_whitelist 里，后面 rm -rf 会把当前目录抽空，bash 狂报 getcwd。
cd /

download() {
  local url="$1"
  local dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --connect-timeout 15 --retry 2 -o "${dest}" "${url}"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "${dest}" --timeout=15 "${url}"
  else
    echo "未找到 curl/wget。" >&2
    return 1
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
ARCHIVE="${TMP}/src.tar.gz"

echo "正在通过国内加速源下载 ${REPO}@${BRANCH} ..."
ok=0
for prefix in "${MIRRORS[@]}"; do
  url="${prefix}${ARCHIVE_URL}"
  echo "尝试 ${url}"
  if download "${url}" "${ARCHIVE}"; then
    ok=1
    break
  fi
done
if [[ "${ok}" -ne 1 ]]; then
  echo "加速源失败，尝试直连 GitHub ..."
  download "${ARCHIVE_URL}" "${ARCHIVE}"
fi

tar --warning=no-timestamp -tzf "${ARCHIVE}" >/dev/null
tar --warning=no-timestamp -xzf "${ARCHIVE}" -C "${TMP}"
SRC="$(find "${TMP}" -mindepth 1 -maxdepth 1 -type d -name 'po0_whitelist-*' | head -n 1)"
if [[ -z "${SRC}" || ! -f "${SRC}/install.sh" ]]; then
  echo "压缩包内容无效。" >&2
  exit 1
fi

rm -rf "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}"
cp -a "${SRC}/." "${INSTALL_DIR}/"
chmod 755 "${INSTALL_DIR}/install.sh" "${INSTALL_DIR}/bootstrap.sh"
bash "${INSTALL_DIR}/install.sh" setup
