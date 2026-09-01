#!/usr/bin/env bash
# 国内 GitHub 加速下载：gh-proxy.com -> ghfast.top -> 直连
set -euo pipefail

PO0_REPO="${PO0_REPO:-rollingshmily/po0_whitelist}"
PO0_BRANCH="${PO0_BRANCH:-main}"
PO0_ARCHIVE_URL="https://github.com/${PO0_REPO}/archive/refs/heads/${PO0_BRANCH}.tar.gz"

PO0_GITHUB_MIRRORS=(
  "https://gh-proxy.com/"
  "https://ghfast.top/"
)

po0_http_get() {
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

po0_fetch_latest_tree() {
  local tmpdir="$1"
  local archive="${tmpdir}/src.tar.gz"
  local url prefix ok=0 src

  echo "正在通过国内加速源下载 ${PO0_REPO}@${PO0_BRANCH} ..." >&2
  for prefix in "${PO0_GITHUB_MIRRORS[@]}"; do
    url="${prefix}${PO0_ARCHIVE_URL}"
    echo "尝试 ${url}" >&2
    if po0_http_get "${url}" "${archive}"; then
      ok=1
      break
    fi
  done
  if [[ "${ok}" -ne 1 ]]; then
    echo "加速源失败，尝试直连 GitHub ..." >&2
    po0_http_get "${PO0_ARCHIVE_URL}" "${archive}"
  fi

  tar --warning=no-timestamp -tzf "${archive}" >/dev/null
  tar --warning=no-timestamp -xzf "${archive}" -C "${tmpdir}"
  src="$(find "${tmpdir}" -mindepth 1 -maxdepth 1 -type d -name 'po0_whitelist-*' | head -n 1)"
  if [[ -z "${src}" || ! -f "${src}/install.sh" || ! -d "${src}/data/regions" ]]; then
    echo "压缩包内容无效。" >&2
    return 1
  fi
  printf '%s\n' "${src}"
}
