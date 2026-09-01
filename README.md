# po0 省/市白名单一键脚本

在国内服务器上按中国地区 IP 段限制入站：只有选中的省份或城市可以访问，其他来源访问任意端口都会被拒绝。脚本同时托管 `INPUT` 和 `FORWARD` 链。

国内防火墙机器**不要开 HTTP 上报口**。Loon 把直连出口 IP 报到一台**海外信箱**，国内机器只出站把名单拉回来。

## 文件

- `install.sh`：国内防火墙机器入口（`p`）
- `mailbox-install.sh`：海外信箱安装
- `data/regions.json`：省市索引
- `data/regions/*.txt`：本地 CIDR
- `tools/mailbox_server.py`：信箱服务
- `loon/`：Loon 插件
- `vendor/ipipfree.ipdb`：离线 ipdb 参考

## 1. 海外信箱（先装）

在一台能被手机直连、又能被国内机器访问的海外机器上：

```bash
curl -fsSL https://gh-proxy.com/https://github.com/rollingshmily/po0_whitelist/archive/refs/heads/main.tar.gz -o /tmp/po0.tar.gz
tar -xzf /tmp/po0.tar.gz -C /tmp
cd /tmp/po0_whitelist-main
sudo bash mailbox-install.sh
```

交互会问：

1. 监听端口（默认 `18443`）
2. **允许拉取名单的源 IP**：填国内防火墙机器访问信箱时的源地址（内网就填内网 IP，可逗号分隔）

装完会打印 Loon 要填的地址、端口、Token。Token 只出现在这台机器上，不要提交到 Git。

## 2. 国内防火墙机器

```bash
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/rollingshmily/po0_whitelist/main/bootstrap.sh | sudo bash
```

然后输入 `p` 进入菜单，可配置信箱、应用省市、手动加白、更新、卸载。也可直接：

```bash
p mailbox-config   # 填海外信箱的地址、端口、Token
p                  # 菜单：选省市 / 拉取 / 更新 / 卸载
```

之后每分钟自动 `p pull`。也可手动：

```bash
p token      # 给 Loon 看地址/端口/Token
p pull       # 立刻从信箱拉 IP
p clients    # 看已写入的直连 IP
p update     # 用加速源更新省市 IP 库并按上次选择重灌
p reapply    # 不拉仓库，按上次省市重灌
```

## 3. Loon 插件

删掉旧插件后导入：

```text
https://gh-proxy.com/https://raw.githubusercontent.com/rollingshmily/po0_whitelist/main/loon/po0-ip-report.plugin
```

备用：

```text
https://cdn.jsdelivr.net/gh/rollingshmily/po0_whitelist@main/loon/po0-ip-report.plugin
```

在插件设置里自己填：

- 信箱地址：海外机器公网 IP
- 信箱端口：和 `mailbox-install.sh` 一致
- Token：安装信箱时打印的那把
- 定时检查：Cron，默认 `*/5 * * * *`

请给**信箱 IP** 配 Loon DIRECT，不要走代理。不要把国内防火墙机器的公网 IP 填进插件。

## 使用

已经把项目放到服务器上时：

```bash
sudo bash install.sh setup
sudo bash install.sh apply
```

选择省份后可再选全省或若干城市。编号和名称都可以，多个用空格/逗号分隔。

```bash
sudo bash install.sh status
sudo bash install.sh clear
```

## 安全提示

`apply` 会拒绝所有未命中白名单的入站流量，包括 SSH。脚本会检测当前 SSH 客户端 IP，并询问是否加入本次白名单，建议保留默认 `Y`。

省市规则应用时不访问外网。缺少 `iptables`/`ipset` 时用系统默认软件源安装。

## 重新准备本地数据

在有外网的机器上：

```bash
python tools/prepare_data.py --ipdb /path/to/ipipfree.ipdb
```

然后把目录复制到防火墙机器。
