# OCI-Mao

面向 Oracle Cloud Infrastructure（OCI）的中文管理面板，把租户、实例、网络、开机任务、日志和自动化集中到一个工作台，支持桌面和手机浏览器。

**本项目采用闭源二进制分发。** 此仓库用于提供项目说明、安装脚本和发布包；公开下载二进制不代表授予开放源代码许可。安装包不提供原始业务源码，使用和再分发应遵守项目授权约定。第三方组件适用各自许可证。

- 项目仓库：<https://github.com/yumengya04/Oci-Mao>
- 本安装包版本：**0.1.1**
- 发布下载：[OCI-Mao Releases](https://github.com/yumengya04/Oci-Mao/releases)
- 安装入口：[install.sh](install.sh)

## 功能介绍

| 模块 | 主要功能 |
| --- | --- |
| 租户配置 | 添加与批量导入配置、私钥规范化、分组、搜索、冻结和加密保存 |
| 租户管理 | 租户信息、区间、IAM 策略、账户配额、账务、成本预算、区域订阅和云公告 |
| 身份与用户 | 身份域、安全策略、认证因素、用户与组、API 密钥、登录和审计日志 |
| 云实例 | 创建实例、开关机、形状调整、引导卷、块存储、IP 和 DNS 绑定 |
| 虚拟云网络 | VCN、子网、网关、路由、安全列表、NSG、流日志和网络负载均衡 |
| 开机任务 | 任务持久化、配置修改、并发执行、状态与日志、暂停恢复和重复提交保护 |
| 自动化 | 实例守护、定时换 IP、DNS 联动、流量与配额保护、租户测活 |
| DNS 与集成 | Cloudflare、阿里云 DNS、Cloudflare Workers 管理 |
| 远程终端 | WebSSH、串行控制台、多标签终端、文件传输和主机状态 |
| 通知与备份 | Telegram 通知、每日播报、加密配置备份、OCI 对象存储与阿里云 OSS 定时备份 |
| 支持与扩展 | OCI 支持工单、受保护的跟进记录、Oracle AI 工作空间和可选网关 |
| 系统设置 | 管理账户、登录保护、显示设置、代理、实时日志和更新配置 |

云功能是否可用，取决于租户订阅、区域、服务资格和 API 用户的 IAM 权限。新建实例、自动网络和相关资源采用普通默认名称，也可以自行命名。

## 安装前准备

推荐在 Linux 服务器上通过 Docker 部署。

| 项目 | 要求 |
| --- | --- |
| 架构 | x86_64（amd64）或 ARM64（arm64） |
| 软件 | Bash、curl、Python 3、Docker Engine 和 Docker Compose V2 |
| 权限 | 安装目录可写，并可访问 Docker；使用默认 `/opt/oci-mao` 时通常需要 `sudo` |
| 网络 | 可访问 GitHub、Docker 镜像仓库、Python 包源以及所使用的云服务 |
| 端口 | 宿主机回环地址的 8501、8502 可用 |
| 资源 | 建议从 2 核、2 GB 内存、10 GB 可用磁盘开始，按租户数量和任务并发调整 |

Python 3 用于安装包校验和解压；应用在 Docker 内运行 CPython 3.12，无需在主机安装业务依赖或编译工具。发布包未附带 Docker 镜像和第三方依赖缓存，首次安装需要下载它们。

Ubuntu / Debian 可先准备基础工具：

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl python3
```

Docker Engine 和 Compose V2 请按 [Docker 官方安装文档](https://docs.docker.com/engine/install/) 安装，并确认以下命令成功：

```bash
sudo docker info
docker compose version
```

`install.sh` 检查 Docker 环境，不自动安装 Docker 或修改系统的软件源。

## 快速安装

在服务器上下载这个仓库的安装脚本，然后执行：

```bash
curl -fL --retry 3 -o install.sh \
  https://raw.githubusercontent.com/yumengya04/Oci-Mao/main/install.sh
sudo bash install.sh --dir /opt/oci-mao
```

脚本会取得 `0.1.1` 的二进制发布包，校验内容，解压到指定目录，构建 Docker 镜像并启动三个服务。对应 Release 必须先上传 `OCI-Mao-0.1.1`。同目录中的二进制安装包也可使用；发布前离线安装请通过 `--sha256` 指定随包提供的正确摘要。

| 服务 | 用途 | 默认地址 |
| --- | --- | --- |
| `panel` | 浏览器管理面板 | `http://127.0.0.1:8501` |
| `worker` | 开机任务、守护、定时任务和备份 | 无公开端口 |
| `logs` | 日志、WebSSH 和串行控制台 | `http://127.0.0.1:8502/logs` |

安装完成后，打开面板并按页面提示创建管理员。没有预设的用户名或密码。

**服务器上的 `127.0.0.1` 指服务器本机。** 在自己的电脑访问服务器面板，请使用下面的 SSH 隧道或配置 HTTPS 反向代理。

## 完整安装过程

### 1. 下载并预检查

```bash
curl -fL --retry 3 -o install.sh \
  https://raw.githubusercontent.com/yumengya04/Oci-Mao/main/install.sh
sudo bash install.sh --dir /opt/oci-mao --check
```

首次安装或显式指定 `--version`、`--sha256` 时，预检查会在临时目录校验发布包；已有完整部署且未指定版本、校验值时，只检查现有部署文件和环境。两种模式均检查 Docker、Compose、项目与数据卷归属，不写入部署文件、本地配置或项目标记，也不启动容器。

### 2. 正式安装

```bash
sudo bash install.sh --dir /opt/oci-mao --timeout 300
```

首次安装按顺序完成：取得发布包、校验与解压、确认项目及数据卷、准备本地配置、构建镜像、启动服务、检查面板和日志健康端点。`--timeout` 指构建完成后的服务就绪等待时间，不包含下载与构建时间。

默认 Compose 项目名为 `oci-panel`，数据卷为 `oci-panel_panel-data`。首次安装记录项目名，之后运行继续使用同一项目与数据卷。已有 `.env` 会保留。

### 3. 打开面板

在自己的电脑建立 SSH 隧道，替换服务器用户名和地址：

```bash
ssh -N \
  -L 8501:127.0.0.1:8501 \
  -L 8502:127.0.0.1:8502 \
  用户名@服务器地址
```

保持 SSH 连接，在浏览器打开 <http://127.0.0.1:8501>。同时转发 8502，实时日志和终端才能正常工作。

### 4. 创建管理员并添加租户

首次访问创建管理员后，进入“租户配置 → 添加租户”，填写用户 OCID、租户 OCID、API 指纹、区域和私钥。批量导入支持粘贴 INI 配置段并上传对应 PEM 文件。

配置示例中的值需要替换为自己的 OCI 信息：

```ini
[DEFAULT]
user=ocid1.user.oc1..替换为用户OCID
tenancy=ocid1.tenancy.oc1..替换为租户OCID
fingerprint=替换为API密钥指纹
region=ap-sydney-1
key_file=oci_api_key.pem
```

API 公钥须先登记到 OCI 用户，并与私钥和指纹对应。只粘贴私钥正文时，面板会补齐必要的头尾；批量导入时，`key_file` 用来匹配上传文件名。

添加后先检查租户、实例和区域的读取结果，再创建所需任务。账户设置位于“系统设置”，退出登录位于页面右上角。

## 安装包与校验

本版只有一个发布包 **`OCI-Mao-0.1.1`**，安装和面板更新共用该文件。没有扩展名，内容采用 ZIP 格式；附带 `OCI-Mao-0.1.1.sha256` 校验文件。

安装脚本通过 GitHub Release 资产的 SHA256 摘要校验 0.1.1，也可以通过 `--sha256` 显式指定随包提供的摘要。原 0.1.0 的校验值仍保留在脚本中，原发布包不变：

```text
bbda50e7f1108cbd610e5020ec46a8006723475db5dca327f41c53a0794bdac1
```

上面的值仅适用于原 0.1.0。其他版本必须具有 GitHub 提供的有效资产摘要，或通过 `--sha256` 显式指定正确的校验值。

也可以手动下载并核对：

```bash
curl -fL --retry 3 -o OCI-Mao-0.1.1 \
  https://github.com/yumengya04/Oci-Mao/releases/download/0.1.1/OCI-Mao-0.1.1
curl -fL --retry 3 -o OCI-Mao-0.1.1.sha256 \
  https://github.com/yumengya04/Oci-Mao/releases/download/0.1.1/OCI-Mao-0.1.1.sha256
sha256sum -c OCI-Mao-0.1.1.sha256
```

把安装包与新下载的 `install.sh` 放在同一目录，再执行快速安装命令。脚本会优先校验并使用可用的本地发布包，无需先手动解压。

包内除 `install.sh`、Docker 部署配置和 README 外，其余应用文件均为原生 `.so` 或二进制资源容器。前端资源与运行配置封装在 `resources.bin`，发布清单封装在 `RELEASE.bin`。不附原始业务 `.py`、生成的 `.c`、构建工具或源码备份。

原生编译和资源封装保护原始源码，但二进制仍可能被逆向分析；浏览器运行页面时取得的 HTML、CSS 和 JavaScript 仍可查看。

## 安装脚本参数

```bash
bash install.sh --help
sudo bash install.sh --dir /opt/oci-mao --check
sudo bash install.sh --dir /opt/oci-mao --version 0.1.1 --timeout 300
sudo bash install.sh --dir /opt/oci-mao --project oci-panel
```

| 参数 | 含义 |
| --- | --- |
| `--dir 路径` | 指定部署目录；通常默认 `/opt/oci-mao`，从已解压的完整二进制目录运行时可直接使用该目录 |
| `--version 版本` | 指定 Release 版本，当前默认 `0.1.1`；显式指定时重新校验并安装对应发布包 |
| `--sha256 摘要` | 显式指定安装包的 SHA256，必须与实际内容一致 |
| `--project 名称` | 首次安装指定 Compose 项目名；已有部署沿用原项目名 |
| `--timeout 秒数` | 构建后等待服务就绪的时限，默认 180 秒 |
| `--check` | 只读部署预检查；首次或显式指定版本、摘要时临时校验发布包，不启动服务 |
| `--help`、`-h` | 显示帮助 |

安装目录支持空格。升级和重跑时，请使用原部署目录与原项目名，避免连接到另一份数据卷。

## 日常管理

在部署目录运行，项目名使用首次安装时的名称：

```bash
cd /opt/oci-mao

# 查看服务和近期日志
sudo docker compose -p oci-panel ps
sudo docker compose -p oci-panel logs --tail 100 panel worker logs

# 重启、停止或重新启动
sudo docker compose -p oci-panel restart panel worker logs
sudo docker compose -p oci-panel stop panel worker logs
sudo docker compose -p oci-panel up -d
```

容器配置为 `restart: unless-stopped`。Docker 随系统启动，且容器未被手动停止时，服务器重启后服务会自动恢复。后台任务需要 `worker` 持续运行。

## 终端管理菜单

安装完成后输入 `ocimao` 打开管理菜单；需要 Docker 管理权限时使用 `sudo ocimao`。脚本会记录部署目录和 Compose 项目，重跑时识别已有安装并沿用原配置与数据卷。

```text
== OCI Mao 管理 ==
  1) 查看状态        2) 启动        3) 停止        4) 重启
  5) 查看实时日志    6) 修改配置（含回滚）
  7) 备份            8) 恢复
  9) 升级到最新版   10) 版本信息
 11) 清除Tg绑定    12) 卸载
 13) 解除备份验证锁定
 14) HTTPS 服务状态  15) 恢复原端口访问（停用 HTTPS）
  0) 退出
```

也可直接执行子命令：

```bash
sudo ocimao status
sudo ocimao start
sudo ocimao stop
sudo ocimao restart
sudo ocimao logs
sudo ocimao version
sudo ocimao upgrade
sudo ocimao config
sudo ocimao config --rollback
sudo ocimao backup /var/backups/oci-mao/config.zip
sudo ocimao restore /var/backups/oci-mao/config.zip
