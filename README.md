# po0 省/市白名单一键脚本

这个项目用于在 po0 服务器上按中国地区 IP 段限制入站访问：只有交互选择的省份或城市可以访问服务器，其他来源访问任意端口都会被拒绝。脚本同时托管 `INPUT` 和 `FORWARD` 链，因此机器上的转发端口也会受到同一白名单限制。

## 文件

- `install.sh`：服务器上运行的一键脚本
- `data/regions.json`：省市索引
- `data/regions/*.txt`：本地 CIDR 段
- `tools/region_tool.py`：本地数据解析和命令生成工具
- `vendor/ipipfree.ipdb`：本地 ipdb 参考文件

## 国内机器一键安装

po0 只能走国内网络时，用 GitHub 加速源安装（优先 `ghspeedup.com`，失败再试 `gh-proxy.com`）：

```bash
curl -fsSL https://ghspeedup.com/https://raw.githubusercontent.com/rollingshmily/po0_whitelist/main/bootstrap.sh | sudo bash
```

若上一条失败：

```bash
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/rollingshmily/po0_whitelist/main/bootstrap.sh | sudo bash
```

安装完成后，在 VPS 上直接输入：

```bash
p
```

即可唤出白名单脚本。`p status`、`p clear`、`p dry-run`、`p update`、`p token` 同样可用。

仓库里的 IP 库更新后，在 po0 上同步：

```bash
p update
```

`p update` 走 `ghspeedup.com` / `gh-proxy.com` 拉最新包，然后**按你上次选的省市自动重灌** ipset，不用再走交互。选择记录在 `/var/lib/po0_whitelist/last_selection.json`，第一次需要先 `p` 选一次。只想重灌不想拉仓库，用 `p reapply`。

## Loon 自动上报直连 IP

Loon 插件会用 **DIRECT** 访问 po0 的上报口（默认 `41741`），服务器按连接来源 IP 加白。这个端口对所有来源开放，靠 Token 鉴权；加进去的 IP 进独立集合 `po0_client_ips`，省市重灌时不会被清掉。

1. po0 上先 `p` 完成一次省市 apply，再执行：

```bash
p token
```

2. Loon 导入插件。先删掉旧插件，再用下面地址新装（ghspeedup 这条会 404，刷新等于没更新）：

```text
https://gh-proxy.com/https://raw.githubusercontent.com/rollingshmily/po0_whitelist/main/loon/po0-ip-report.plugin
```

备用：

```text
https://cdn.jsdelivr.net/gh/rollingshmily/po0_whitelist@main/loon/po0-ip-report.plugin
```

3. 填第一台 po0 的公网 IP、端口、Token。检查间隔默认 `*/5 * * * *`（每 5 分钟），可改成 `*/1 * * * *` 每分钟等。多台机器在「更多机器」里每行一台：`地址|端口|Token`。网络切换和手动上报同样会打到所有已填机器。

查看已上报 IP：`p clients`

## 使用

已经把项目放到服务器上时：

```bash
sudo bash install.sh setup   # 安装到 /opt/po0_whitelist 并添加命令 p
sudo bash install.sh apply   # 或直接输入 p
```

脚本会直接列出所有省份，例如 `1.北京市`、`19.广东省`。选择省份后会继续列出该省全部城市，例如 `1.广州市`、`3.深圳市`。你可以输入编号，也可以直接输入名称；多个选择用空格、英文逗号、中文逗号或顿号分隔。

查看状态：

```bash
sudo bash install.sh status
```

清除规则：

```bash
sudo bash install.sh clear
```

## 安全提示

`apply` 会拒绝所有未命中白名单的入站流量，包括 SSH。脚本会检测当前 SSH 客户端 IP，并询问是否加入本次白名单，建议保留默认 `Y`。

脚本运行时不访问外网。若服务器缺少 `iptables` 或 `ipset`，会自动使用系统默认软件源安装依赖。

## 重新准备本地数据

在有外网的机器上运行：

```bash
python tools/prepare_data.py --ipdb /path/to/ipipfree.ipdb
```

然后把整个目录复制到服务器即可。
