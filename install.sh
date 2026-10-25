#!/usr/bin/env bash
# 私有发布包安装入口。依赖已有 Docker Engine/Desktop 和 Docker Compose v2。
set -Eeuo pipefail
umask 077

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
COMPOSE_FILE="$ROOT_DIR/compose.yaml"
ENV_FILE="$ROOT_DIR/.env"
PROJECT_FILE="$ROOT_DIR/.oci-panel-project"
PROJECT_ARG=""
PROJECT=""
TIMEOUT=180
CHECK_ONLY=0
STAGE="读取参数"
TEMP_FILE=""

usage() {
    cat <<'HELP'
用法：bash install.sh [参数]

在本脚本所在私有发布包目录构建并启动 panel、worker、logs。
无需 git clone；不会安装 Docker，也不会删除数据卷或覆盖已有 .env。

参数：
  --project NAME  首次安装的 Compose 项目名（默认 oci-panel）。
                  已有 .oci-panel-project / .env 的项目名必须一致。
  --timeout SEC   构建结束后等待三项服务就绪的秒数（默认 180，正整数）。
  --check         只读预检：依赖、项目/数据卷归属、端口和 Compose 配置。
  --help, -h      显示本帮助。

示例：
  bash install.sh --check
  bash install.sh
  bash install.sh --project oci-panel --timeout 300

首次原子创建本地默认 .env 和项目标记；后续运行保留它们及数据卷。
同一份安装目录不能通过改项目名切换数据卷。构建需要能获取镜像和依赖，
除非它们已在 Docker 缓存中。请先按 README 安装并启动 Docker。
HELP
}

say() { printf '%s\n' "$*"; }
fail() { printf '失败：%s\n' "$*" >&2; exit 1; }
cleanup() { if [[ -n "$TEMP_FILE" ]]; then rm -f -- "$TEMP_FILE"; fi; }
trap cleanup EXIT
trap 'code=$?; printf "失败：阶段「%s」执行异常（退出码 %s，行 %s）。已有配置和数据卷均保留。\n" "$STAGE" "$code" "$LINENO" >&2; exit "$code"' ERR

valid_project() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; }

while (( $# > 0 )); do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --check) CHECK_ONLY=1; shift ;;
        --project)
            (( $# >= 2 )) || fail '--project 缺少项目名。'
            [[ -z "$PROJECT_ARG" ]] || fail '--project 只能提供一次。'
            PROJECT_ARG="$2"; shift 2 ;;
        --timeout)
            (( $# >= 2 )) || fail '--timeout 缺少秒数。'
            [[ "$2" =~ ^[1-9][0-9]{0,5}$ ]] || fail '--timeout 必须是 1 至 999999 的整数秒。'
            TIMEOUT="$2"; shift 2 ;;
        *) fail "未知参数：$1。使用 --help 查看用法。" ;;
    esac
done
if [[ -n "$PROJECT_ARG" ]]; then
    valid_project "$PROJECT_ARG" || fail '项目名只允许小写字母、数字、下划线和连字符，首字符必须是字母或数字。'
fi

# 只读取项目名，绝不 source .env 或执行其中的内容。
read_env_project() {
    local line value found=""
    if [[ -e "$ENV_FILE" || -L "$ENV_FILE" ]]; then
        [[ -f "$ENV_FILE" && -r "$ENV_FILE" ]] || fail '.env 必须是可读的普通文件。'
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?COMPOSE_PROJECT_NAME[[:space:]]*=(.*)$ ]]; then
                value="${BASH_REMATCH[2]}"
                value="${value%%#*}"
                value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
                case "$value" in
                    \"*\") value="${value#\"}"; value="${value%\"}" ;;
                    \'*\') value="${value#\'}"; value="${value%\'}" ;;
                esac
                found="$value"
            fi
        done < "$ENV_FILE"
    fi
    if [[ -n "$found" ]]; then
        valid_project "$found" || fail '.env 中的 COMPOSE_PROJECT_NAME 必须是固定的合法项目名，不能使用变量展开。'
    fi
    ENV_PROJECT="$found"
}

STAGE="确认项目名"
MARKER_PROJECT=""
if [[ -e "$PROJECT_FILE" || -L "$PROJECT_FILE" ]]; then
    [[ -f "$PROJECT_FILE" && -r "$PROJECT_FILE" ]] || fail '.oci-panel-project 必须是可读的普通文件。'
    MARKER_PROJECT="$(cat -- "$PROJECT_FILE")"
    MARKER_PROJECT="${MARKER_PROJECT%$'\r'}"
    valid_project "$MARKER_PROJECT" || fail '.oci-panel-project 中的项目名无效，请核实原安装项目，勿直接切换数据卷。'
fi
read_env_project
if [[ -n "$MARKER_PROJECT" && -n "$ENV_PROJECT" && "$MARKER_PROJECT" != "$ENV_PROJECT" ]]; then
    fail '.oci-panel-project 与 .env 的 COMPOSE_PROJECT_NAME 不一致。请核实原部署项目名。'
fi
PROJECT="${MARKER_PROJECT:-${ENV_PROJECT:-${PROJECT_ARG:-oci-panel}}}"
if [[ -n "$PROJECT_ARG" && "$PROJECT_ARG" != "$PROJECT" ]]; then
    fail "项目已固定为 $PROJECT，不能改为 $PROJECT_ARG。重跑时请使用原项目名以保留原数据卷。"
fi

STAGE="只读预检"
say '[1/5] 检查发布包、Docker 和 Compose……'
for file in compose.yaml Dockerfile requirements.txt app.py worker.py log_server.py brand_streamlit.py; do
    [[ -f "$ROOT_DIR/$file" ]] || fail "发布包不完整，缺少 $file。请完整解压私有 ZIP。"
done
for command in docker mktemp sed ln rm; do
    command -v "$command" >/dev/null 2>&1 || fail "找不到 $command。请按 README 准备依赖后重试。"
done
docker compose version >/dev/null 2>&1 || fail 'Docker Compose v2 不可用。请安装/启用 docker compose 插件。'
docker info >/dev/null 2>&1 || fail '无法连接 Docker。请启动 Docker，并确认当前用户有访问权限；Linux 可按 README 配置 docker 组或使用 sudo。'

compose() {
    local env_path=/dev/null
    if [[ -f "$ENV_FILE" ]]; then env_path="$ENV_FILE"; fi
    docker compose --project-directory "$ROOT_DIR" -f "$COMPOSE_FILE" -p "$PROJECT" --env-file "$env_path" "$@"
}

say "安装目录：$ROOT_DIR"
say "固定项目：$PROJECT；数据卷：${PROJECT}_panel-data"
all_volumes="$(docker volume ls --format '{{.Name}}')"
panel_volumes="$(docker volume ls --filter 'label=com.docker.compose.volume=panel-data' --format '{{.Name}}')"
EXPECTED_VOLUME="${PROJECT}_panel-data"
if [[ $'\n'"$all_volumes"$'\n' == *$'\n'"$EXPECTED_VOLUME"$'\n'* ]]; then
    owner="$(docker volume inspect --format '{{ index .Labels "com.docker.compose.project" }}|{{ index .Labels "com.docker.compose.volume" }}' "$EXPECTED_VOLUME")"
    [[ "$owner" == "$PROJECT|panel-data" ]] || fail "已有卷 $EXPECTED_VOLUME 的 Compose 归属不匹配，停止以避免误用数据。"
elif [[ -z "$MARKER_PROJECT" && -z "$ENV_PROJECT" && -z "$PROJECT_ARG" && -n "$panel_volumes" ]]; then
    say "已发现其他项目的数据卷：$panel_volumes"
    fail '无法确认原项目名，不会默认创建新卷。请查看 docker volume inspect 的 Compose 项目标签，使用 --project 原项目名重试。'
fi

containers="$(docker ps --format '{{.ID}}|{{.Ports}}|{{.Label "com.docker.compose.project"}}')"
while IFS='|' read -r container_id ports owner; do
    [[ -n "$container_id" ]] || continue
    if [[ "$ports" == *:8501-\>* || "$ports" == *:8502-\>* ]]; then
        [[ "$owner" == "$PROJECT" ]] || fail "容器 $container_id 已发布 8501/8502，且不属于项目 $PROJECT。请先核实该服务，本脚本不会停止它。"
    fi
done <<< "$containers"
compose config --quiet || fail 'Compose 配置校验失败。请检查 compose.yaml 和已有 .env。'
if (( CHECK_ONLY )); then
    say '预检通过。未创建 .env、项目标记、容器或数据卷。正式安装请运行 bash install.sh（自定义项目名时继续带 --project）。'
    exit 0
fi

# 临时文件权限受 umask 077 保护；硬链接是原子的排他创建，已有文件不会被覆盖。
create_once() {
    local target="$1" content="$2"
    TEMP_FILE="$(mktemp "$ROOT_DIR/.install.tmp.XXXXXX")"
    printf '%s\n' "$content" > "$TEMP_FILE"
    if ! ln -- "$TEMP_FILE" "$target" 2>/dev/null; then
        [[ -e "$target" || -L "$target" ]] || fail "无法原子创建 $target，请检查目录写权限/文件系统硬链接支持。"
    fi
    rm -f -- "$TEMP_FILE"
    TEMP_FILE=""
}

STAGE="保留/创建本地配置"
say '[2/5] 保留已有配置，首次创建本地默认值……'
if [[ ! -e "$ENV_FILE" && ! -L "$ENV_FILE" ]]; then
    create_once "$ENV_FILE" "# 本地访问默认值；配置公网 HTTPS 请按 README 修改这两项。
COMPOSE_PROJECT_NAME=$PROJECT
PANEL_LOG_WS_URL=ws://127.0.0.1:8502/ws/logs
PANEL_ALLOWED_ORIGINS=http://127.0.0.1:8501,http://127.0.0.1:8502"
    say '.env 已原子创建（若另一安装进程先创建，则保留其文件）。'
else
    say '已有 .env 已保留。'
fi
read_env_project
[[ -z "$ENV_PROJECT" || "$ENV_PROJECT" == "$PROJECT" ]] || fail '另一个安装进程创建了不同项目名的 .env，已停止且未覆盖文件。'
if [[ ! -e "$PROJECT_FILE" && ! -L "$PROJECT_FILE" ]]; then create_once "$PROJECT_FILE" "$PROJECT"; fi
[[ -f "$PROJECT_FILE" && "$(cat -- "$PROJECT_FILE")" == "$PROJECT" ]] || fail '项目标记在安装期间发生变化，已停止且未覆盖文件。'
compose config --quiet || fail '本地配置校验失败。已有配置/项目标记均保留，请修正后使用相同项目名重跑。'

STAGE="构建并启动"
say '[3/5] 构建镜像并启动 panel、worker、logs（首次构建可能较久）……'
compose up -d --build || fail '镜像构建或启动失败。请检查 Docker 输出、镜像/依赖下载及端口 8501/8502 占用。配置与数据卷已保留，修复后重跑本命令。'

http_ready() {
    # 在本项目对应的容器内检查，避免将宿主机上的旧服务误认成新部署。
    compose exec -T "$1" python -c 'import sys, urllib.request; opener = urllib.request.build_opener(urllib.request.ProxyHandler({})); response = opener.open(sys.argv[1], timeout=2); sys.exit(0 if response.status == 200 else 1)' "$2" >/dev/null 2>&1
}
service_running() {
    local container
    container="$(compose ps -q "$1")" || return 1
    [[ -n "$container" ]] || return 1
    [[ "$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null)" == true ]]
}

STAGE="等待服务就绪"
say "[4/5] 等待三项服务就绪，最多 ${TIMEOUT} 秒（不含构建时间）……"
started=$SECONDS
READY=0
while (( SECONDS - started < TIMEOUT )); do
    if service_running panel && service_running worker && service_running logs && \
        http_ready panel 'http://127.0.0.1:8501/_stcore/health' && http_ready logs 'http://127.0.0.1:8502/health'; then
        READY=1
        break
    fi
    sleep 2
done
if (( ! READY )); then
    compose ps --all || true
    printf '查看失败服务日志：在安装目录运行 docker compose -p %q -f compose.yaml logs --tail=100 panel worker logs\n' "$PROJECT" >&2
    fail "等待超时（${TIMEOUT} 秒）。至少一项服务未就绪。配置与数据卷已保留；按上面的状态/日志排查后重跑，可提高 --timeout。"
fi
say '[5/5] 安装完成：panel、worker、logs 正在运行，两项 HTTP 健康检查通过。'
say '面板：http://127.0.0.1:8501'
say '日志查看：http://127.0.0.1:8502/logs'
say '数据位于 Docker 命名卷；后续在同一目录使用相同项目名重跑即可更新。公网 HTTPS 与首次账号/云凭据配置请继续按 README 操作。'
