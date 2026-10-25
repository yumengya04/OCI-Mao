# OCI-Mao

OCI-Mao 是面向 Oracle Cloud Infrastructure（OCI）的中文管理面板，将多租户配置、云资源、开机任务、自动化和日志集中到一个工作台，支持桌面和手机浏览器。

本项目采用闭源分发。请通过授权渠道取得安装包，在授权范围内安装和使用。安装包内的 Python 文件属于部署所需的运行代码，不代表开放源代码许可；未经许可不得公开上传或再分发。第三方组件按其各自许可证使用，详见 [LICENSE.txt](LICENSE.txt) 和 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 功能介绍

| 模块 | 功能 |
| --- | --- |
| 租户配置 | 添加、批量导入、分组、搜索、冻结、加密保存 OCI 配置和私钥 |
| 租户管理 | 租户信息、区间、IAM 策略、账户配额、账务、预算、区域订阅及云公告 |
| 身份与用户 | 身份域、安全策略、认证因素、用户与组、API 密钥、登录和审计日志 |
| 实例与存储 | 实例创建和电源操作、形状调整、引导卷、块存储、对象存储与 IP 管理 |
| 虚拟云网络 | VCN、子网、网关、路由、安全列表、NSG、流日志及网络负载均衡 |
| 开机任务 | 持久化任务、配置修改、并发执行、状态与日志、暂停和恢复、防重复提交 |
| 自动化 | 实例守护、定时换 IP、DNS 联动、流量与配额保护、租户测活 |
| DNS 与集成 | Cloudflare、阿里云 DNS、实例绑定 DNS，以及 Cloudflare Workers 管理 |
| 远程终端 | WebSSH、串行控制台、多标签终端、文件传输及主机状态 |
| 通知与备份 | Telegram 通知和每日播报、完整面板加密备份、OCI 对象存储和阿里云 OSS 定时备份 |
| 支持与扩展 | OCI 支持工单与受保护的跟进记录、Oracle AI 工作空间和可选网关 |
| 系统管理 | 管理账户、登录保护、显示设置、网络代理、事件和实时日志、系统更新 |

云功能是否可用取决于租户订阅、区域、OCI 服务资格以及 API 用户的 IAM 权限。安装脚本负责部署服务；它不会添加租户或创建云资源。

## 快速安装

推荐使用 Linux + Docker Engine + Docker Compose V2。应用安装只需要运行一个脚本：`install.sh`。

1. 准备 Docker 和 Compose V2，确保 `docker info`、`docker compose version` 可以正常执行。
2. 从授权渠道取得 `OCI-Mao-0.1.0-private.zip` 及同名 `.sha256` 校验文件，核对后解压到安装目录。
3. 在解压后的目录运行：

   ```bash
   sudo bash install.sh
   ```

4. 打开 `http://127.0.0.1:8501`，首次访问按页面提示创建管理员，然后添加 OCI 租户。

服务器上的 `127.0.0.1` 指服务器本机。远程访问请使用下文的 SSH 隧道或 HTTPS 反向代理。

## 安装前准备

| 项目 | 要求 |
| --- | --- |
| 系统 | 可运行 Docker Engine 和 Compose V2 的 Linux 主机，具备 Bash |
| 权限 | 当前用户能访问 Docker 守护进程，或使用 `sudo bash install.sh` |
| 网络 | 首次构建需要访问 Docker 镜像仓库和 Python 包源；使用云功能还需访问对应服务 |
| 端口 | 宿主机回环地址的 8501、8502 未被其他服务占用 |
| 资源 | 按任务并发和租户数量配置；建议从 2 核、2 GB 内存、10 GB 可用磁盘开始 |
| Python | Docker 镜像使用 Python 3.12；Docker 部署无需在主机安装应用 Python 环境 |

安装包包含应用运行文件，未包含预构建 Docker 镜像或第三方依赖缓存。它不是完全离线安装包。

## 完整安装过程

### 1. 检查 Docker 环境

```bash
docker --version
docker compose version
sudo docker info
```

若 Docker 或 Compose 不存在，请先按系统对应的 Docker 安装文档完成安装并启动守护进程。`install.sh` 会检查这些条件，不会自动更换系统的软件源或安装 Docker。

### 2. 校验安装包

将 ZIP 和校验文件放在同一个目录，运行：

```bash
sha256sum -c OCI-Mao-0.1.0-private.zip.sha256
```

看到 `OK` 后继续。校验文件应与安装包一起从可信的授权渠道获取。

### 3. 解压到安装目录

以下路径供新安装使用。首次安装请选择空目录；升级已有面板请按“升级与更新”操作。

```bash
sudo mkdir -p /opt/oci-panel/current
sudo unzip OCI-Mao-0.1.0-private.zip -d /opt/oci-panel/current
cd /opt/oci-panel/current
```

ZIP 内直接包含 `README.md`、`install.sh`、`compose.yaml` 等文件，没有额外的顶层目录。

### 4. 运行预检查

```bash
sudo bash install.sh --check
```

预检查不启动容器、不生成配置。发现缺少文件、Docker 不可用或部署冲突时，按提示处理，再运行相同命令。端口预检查识别 Docker 容器占用；宿主机其他进程的冲突会在实际启动时由 Docker 报错。

### 5. 正式安装

```bash
sudo bash install.sh
```

脚本会按顺序检查环境与安装目录、确定 Compose 项目名、保留或初始化 `.env`、检查 Compose 配置、构建镜像并启动三个服务，最后检查容器运行状态和面板、日志服务的健康端点。

| 服务 | 用途 | 默认访问地址 |
| --- | --- | --- |
| `panel` | 浏览器管理面板 | `http://127.0.0.1:8501` |
| `worker` | 持续执行开机任务、守护、定时任务和备份 | 无公开端口 |
| `logs` | 实时日志、WebSSH 和串行控制台 | `http://127.0.0.1:8502` |

默认 Compose 项目名为 `oci-panel`，数据卷为 `oci-panel_panel-data`。脚本记录项目名，后续重跑沿用该名称，避免连接到另一份数据卷。已有 `.env` 和数据卷会保留。

安装失败时脚本返回非零退出码，并提示检查位置；它不会删除数据库、密钥或数据卷。修正问题后可再次运行。重复运行会重新构建和协调服务状态，因此已有服务可能被重建。

### 6. 创建管理员并添加租户

首次访问显示“创建管理员账户”，没有预设用户名或密码。创建完成后进入面板。

在“租户配置”中选择“添加租户”，填写 OCI 用户 OCID、租户 OCID、指纹、区域及私钥等信息；也可以使用批量导入，粘贴多个 INI 配置段并上传对应 PEM 文件。只粘贴私钥正文时会补齐必要的头尾。批量导入支持输入加密 PEM 的解密口令。

批量配置示例（所有值均为占位内容）：

```ini
[DEFAULT]
user=ocid1.user.oc1..替换为你的用户OCID
tenancy=ocid1.tenancy.oc1..替换为你的租户OCID
fingerprint=替换为API密钥指纹
region=ap-sydney-1
key_file=oci_api_key.pem
```

`key_file` 在批量导入时用于匹配上传文件名，不需要把客户端私钥放到容器的相同路径。API 公钥须先在 OCI 中登记，并与私钥、指纹一致。

添加后打开租户或实例页面检查读取结果，再创建需要的任务。后台任务依赖 `worker` 持续运行。账户密码位于“系统设置 → 账户设置”，退出登录位于页面右上角。

## 远程访问

### SSH 隧道

在自己的电脑运行下列命令，替换服务器用户名和地址：

```bash
ssh -N -L 8501:127.0.0.1:8501 -L 8502:127.0.0.1:8502 用户名@服务器地址
```

保持连接，在浏览器打开 **`http://127.0.0.1:8501`**。同时转发 8502，实时日志和终端才能工作。首次管理员可通过此方式创建。

### HTTPS 域名访问

包内提供 [Nginx 示例](deploy/nginx.conf.example) 和 [环境变量示例](deploy/env.example)。在服务器配置实际域名和有效证书，并修改已有 `.env` 的对应项，例如：

```dotenv
COMPOSE_PROJECT_NAME=oci-panel
PANEL_LOG_WS_URL=wss://panel.example.com/ws/logs
PANEL_ALLOWED_ORIGINS=https://panel.example.com
```

把 `panel.example.com` 替换为实际域名。Origin 必须与浏览器访问的协议、域名和端口一致；域名部署使用 `https` 和 `wss`。按示例转发面板、日志、`/ssh`、`/ssh/session`、`/ssh-assets/` 和 `/ws/` 路径，并启用 WebSocket 升级。

修改后检查 Nginx 配置并重载；在安装目录重建容器环境：

```bash
sudo docker compose -p oci-panel up -d
```

若首次安装采用了其他项目名，请将命令中的 `oci-panel` 替换为记录的名称。Compose 默认仍只向宿主机回环地址发布端口，由 Nginx 提供外部访问。

## 安装脚本参数

```bash
bash install.sh --help
sudo bash install.sh --check
sudo bash install.sh --timeout 300
sudo bash install.sh --project oci-panel
```

| 参数 | 含义 |
| --- | --- |
| `--help` | 显示帮助 |
| `--check` | 只读检查，不生成配置、不构建、不启动 |
| `--timeout 秒数` | 构建和启动后等待健康检查的时限 |
| `--project 名称` | 首次部署指定 Compose 项目名；已有安装沿用原项目名 |

脚本以自身所在目录作为安装目录，支持目录包含空格。它只使用授权安装包内的文件，不从 GitHub 克隆源代码。

## 日常管理

在安装目录运行，项目名使用首次安装时的名称：

```bash
# 查看三个服务
sudo docker compose -p oci-panel ps

# 查看近期日志
sudo docker compose -p oci-panel logs --tail 100 panel worker logs

# 重启服务
sudo docker compose -p oci-panel restart panel worker logs

# 停止服务
sudo docker compose -p oci-panel stop panel worker logs

# 启动已有服务
sudo docker compose -p oci-panel up -d
```

容器配置了 `restart: unless-stopped`。Docker 随系统启动且容器未被手动停止时，服务会在服务器重启后自动恢复。
