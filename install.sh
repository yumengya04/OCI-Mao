#!/usr/bin/env bash
# OCI-Mao 闭源二进制安装入口；不执行下载包中的安装脚本。
set -Eeuo pipefail
umask 077

SCRIPT_DIR=""
SCRIPT_FILE=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
    SCRIPT_FILE="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"
fi
ROOT_ARG=""
VERSION="0.1.0"
VERSION_ARG=""
SHA_ARG=""
REPOSITORY="yumengya04/Oci-Mao"
PINNED_SHA="bbda50e7f1108cbd610e5020ec46a8006723475db5dca327f41c53a0794bdac1"
TEMP_DIR=""
PACKAGE_DIR=""
PROJECT_ARG=""
PROJECT=""
TIMEOUT=180
CHECK_ONLY=0
STAGE="读取参数"
TEMP_FILE=""

usage() {
    cat <<'HELP'
用法：bash install.sh [参数]

下载并校验 GitHub 闭源二进制包，构建并启动 panel、worker、logs。
在已经解压的二进制目录运行时直接使用该目录；其他情况默认安装到 /opt/oci-mao。
支持直接从刚克隆的仓库运行；不会安装 Docker、删除数据卷或覆盖已有 .env。

参数：
  --dir PATH      安装目录，默认 /opt/oci-mao（已解压包内运行时为包目录）。
  --version VER   下载指定 Release 标签（默认 0.1.0）；重跑此参数可重新安装。
  --sha256 HEX    指定安装包 SHA256；指定其他版本时也可读取 GitHub 资产 digest。
  --project NAME  首次安装的 Compose 项目名（默认 oci-panel）。
                  已有 .oci-panel-project / .env 的项目名必须一致。
  --timeout SEC   构建结束后等待三项服务就绪的秒数（默认 180，正整数）。
  --check         预检；下载和校验只用临时目录，不写安装目录或启动服务。
  --help, -h      显示本帮助。

示例：
  sudo bash install.sh --dir /opt/oci-mao --check
  sudo bash install.sh --dir /opt/oci-mao
  bash install.sh --project oci-panel --timeout 300

首次原子创建本地默认 .env 和项目标记；后续运行保留它们及数据卷。
同一份安装目录不能通过改项目名切换数据卷。构建需要能获取镜像和依赖，
除非它们已在 Docker 缓存中。请先安装并启动 Docker Engine + Compose v2，
并安装 curl、python3。安装包无扩展名，内部仍为 ZIP；脚本自动处理，无需 unzip。
建议先将脚本下载为文件再运行；通过 bash -s 运行时，后续维护请重新下载仓库脚本。
HELP
}

say() { printf '%s\n' "$*"; }
fail() { printf '失败：%s\n' "$*" >&2; exit 1; }
cleanup() {
    if [[ -n "$TEMP_FILE" ]]; then rm -f -- "$TEMP_FILE"; fi
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" && "$(basename -- "$TEMP_DIR")" == oci-mao-download.* ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}
trap cleanup EXIT
trap 'code=$?; printf "失败：阶段「%s」执行异常（退出码 %s，行 %s）。已有配置和数据卷均保留。\n" "$STAGE" "$code" "$LINENO" >&2; exit "$code"' ERR

valid_project() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; }

while (( $# > 0 )); do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --check) CHECK_ONLY=1; shift ;;
        --dir)
            (( $# >= 2 )) && [[ -n "$2" ]] || fail '--dir 缺少目录。'
            [[ -z "$ROOT_ARG" ]] || fail '--dir 只能提供一次。'
            ROOT_ARG="$2"; shift 2 ;;
        --version)
            (( $# >= 2 )) || fail '--version 缺少版本。'
            [[ -z "$VERSION_ARG" ]] || fail '--version 只能提供一次。'
            [[ "$2" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || fail '--version 必须是合法版本标签，例如 0.1.0。'
            VERSION_ARG="$2"; VERSION="${2#v}"; shift 2 ;;
        --sha256)
            (( $# >= 2 )) || fail '--sha256 缺少摘要。'
            [[ -z "$SHA_ARG" ]] || fail '--sha256 只能提供一次。'
            [[ "$2" =~ ^[a-fA-F0-9]{64}$ ]] || fail '--sha256 必须是 64 位十六进制摘要。'
            SHA_ARG="${2,,}"; shift 2 ;;
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

if [[ -n "$ROOT_ARG" ]]; then
    ROOT_DIR="$ROOT_ARG"
elif [[ -n "$SCRIPT_DIR" && ( -e "$SCRIPT_DIR/compose.yaml" || -e "$SCRIPT_DIR/resources.bin" || -e "$SCRIPT_DIR/_native" ) ]]; then
    ROOT_DIR="$SCRIPT_DIR"
else
    ROOT_DIR="/opt/oci-mao"
fi
[[ "$ROOT_DIR" == /* || "$ROOT_DIR" =~ ^[A-Za-z]:/ ]] || ROOT_DIR="$PWD/$ROOT_DIR"
for command in python3 mktemp sed ln rm; do
    command -v "$command" >/dev/null 2>&1 || fail "找不到 $command。请按 README 准备依赖后重试。"
done
ROOT_DIR="$(python3 - "$ROOT_DIR" <<'PY'
import os, sys
print(os.path.abspath(sys.argv[1]).replace('\\', '/'))
PY
)"
[[ "$ROOT_DIR" != / ]] || fail '安装目录不能是文件系统根目录。'
COMPOSE_FILE="$ROOT_DIR/compose.yaml"
ENV_FILE="$ROOT_DIR/.env"
PROJECT_FILE="$ROOT_DIR/.oci-panel-project"

# 下载文件始终通过 HTTPS；不执行下载结果。其他版本没有可验证摘要时直接停止。
download() {
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 20 --max-time 600 --retry 2 --output "$2" "$1"
}
archive_tool() {
    MAO_INSTALLER_SOURCE="$SCRIPT_FILE" python3 - "$@" <<'PY'
import hashlib, json, os, re, shutil, stat, sys, tempfile, zipfile, zlib
from pathlib import Path, PurePosixPath

mode, archive_name, expected_sha, version, destination = sys.argv[1:]
archive_path = Path(archive_name)
if archive_path.stat().st_size > 32 * 1024 * 1024:
    raise SystemExit('安装包大小超过限制。')
digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
if digest != expected_sha:
    raise SystemExit('安装包 SHA256 校验失败；未解压或安装。')
allowed = {'README.md', 'install.sh', 'Dockerfile', 'compose.yaml', '.dockerignore',
           'deploy/compose.oracle-ai.yaml', 'resources.bin', 'RELEASE.bin'}
native = re.compile(r'_native/(amd64|arm64)/([A-Za-z_][A-Za-z_0-9]*)\.cpython-312-[a-z0-9_-]+\.so')
with zipfile.ZipFile(archive_path) as archive:
    rows = archive.infolist()
    if len(rows) > 500 or sum(row.file_size for row in rows) > 128 * 1024 * 1024:
        raise SystemExit('安装包大小或文件数量异常。')
    contents, folded = {}, set()
    for row in rows:
        name = row.filename
        parts = PurePosixPath(name).parts
        if not parts or name.startswith('/') or '\\' in name or ':' in name or any(p in ('.', '..') for p in parts) or '/'.join(parts) != name:
            raise SystemExit('安装包包含不安全路径。')
        if name.casefold() in folded:
            raise SystemExit('安装包包含重复路径。')
        folded.add(name.casefold())
        kind = stat.S_IFMT(row.external_attr >> 16)
        if kind not in (0, stat.S_IFREG) or row.is_dir() or row.flag_bits & 1:
            raise SystemExit('安装包包含链接、特殊文件或加密 ZIP 条目。')
        if name not in allowed and not native.fullmatch(name):
            raise SystemExit('安装包包含非允许文件或明文源码：' + name)
        contents[name] = archive.read(row)
    if not allowed <= contents.keys():
        raise SystemExit('安装包缺少配置或二进制资源。')
    magic = b'OCI-MAO-RELEASE\x00\x02'
    release = contents['RELEASE.bin']
    if not release.startswith(magic):
        raise SystemExit('安装包发布清单格式不兼容。')
    decoder = zlib.decompressobj()
    decoded = decoder.decompress(release[len(magic):], 1024 * 1024)
    if not decoder.eof or decoder.unused_data:
        raise SystemExit('安装包发布清单过大或损坏。')
    manifest = json.loads(decoded)
    if manifest.get('format') != 2 or manifest.get('version') != version or manifest.get('python_version') != [3, 12]:
        raise SystemExit('安装包版本或运行格式不匹配。')
    files = manifest.get('files', {})
    if set(files) != set(contents) - {'RELEASE.bin'} or any(hashlib.sha256(contents[name]).hexdigest() != sha for name, sha in files.items()):
        raise SystemExit('安装包内部文件摘要校验失败。')
    if manifest.get('resource_sha256') != hashlib.sha256(contents['resources.bin']).hexdigest():
        raise SystemExit('安装包资源摘要校验失败。')
    for arch, machine in (('amd64', 62), ('arm64', 183)):
        names = [name for name in contents if native.fullmatch(name) and native.fullmatch(name).group(1) == arch]
        modules = {native.fullmatch(name).group(2): name for name in names}
        if len(names) != 196 or len(modules) != 196 or not {'_mao_resources', 'mao_runtime', '_framework_routes'} <= modules.keys():
            raise SystemExit('安装包缺少完整原生模块：' + arch)
        records = manifest.get('architectures', {}).get(arch, [])
        if len(records) != 196 or {record['module'] for record in records} != set(modules):
            raise SystemExit('安装包架构清单不完整：' + arch)
        for record in records:
            name = modules[record['module']]
            data = contents[name]
            if record['file'] != name.rsplit('/', 1)[1] or record['sha256'] != files[name] or data[:6] != b'\x7fELF\x02\x01' or int.from_bytes(data[18:20], 'little') != machine:
                raise SystemExit('安装包原生模块格式或架构错误：' + name)
    if mode == 'validate':
        print('二进制安装包校验通过：' + version + '，SHA256 ' + digest)
    elif mode in ('extract', 'install'):
        target = Path(destination)
        installer_source = os.environ.get('MAO_INSTALLER_SOURCE', '')
        current_installer = Path(installer_source) if installer_source else None
        current_document = current_installer.parent / 'README.md' if current_installer else None
        copy_installer = mode == 'install' and current_installer is not None and current_installer.is_file() and not current_installer.is_symlink()
        copy_document = mode == 'install' and current_document is not None and current_document.is_file() and not current_document.is_symlink()
        if copy_installer:
            # 在下载的脚本文件运行时，把当前安装入口也存入安装目录。
            contents['install.sh'] = current_installer.read_bytes()
        if copy_document:
            contents['README.md'] = current_document.read_bytes()
        # 检查所有目标及祖先后才创建目录；不跟随现有符号链接。
        for name in contents:
            path = target / name
            for parent in (path, *path.parents):
                if parent.is_symlink():
                    raise SystemExit('安装目标包含符号链接，停止写入：' + str(parent))
            if path.exists() and not path.is_file():
                raise SystemExit('安装目标包含非普通文件：' + str(path))
            if any(parent.exists() and not parent.is_dir() for parent in path.parents):
                raise SystemExit('安装目标的父路径不是目录。')
        for name, data in contents.items():
            path = target / name
            # 当前文档/脚本优先于包内旧副本；无当前文件时保留已有副本。
            if mode == 'install' and name == 'README.md' and path.exists() and not copy_document:
                continue
            if mode == 'install' and name == 'install.sh' and path.exists() and not copy_installer:
                continue
            path.parent.mkdir(parents=True, exist_ok=True)
            fd, temp_name = tempfile.mkstemp(prefix='.oci-mao-file-', dir=path.parent)
            try:
                with os.fdopen(fd, 'wb') as output:
                    output.write(data)
                os.chmod(temp_name, 0o755 if name == 'install.sh' else 0o644)
                os.replace(temp_name, path)
            finally:
                if os.path.exists(temp_name):
                    os.unlink(temp_name)
    else:
        raise SystemExit('未知安装包操作。')
PY
}

STAGE="获取并校验二进制包"
if [[ -n "$VERSION_ARG" || -n "$SHA_ARG" || !( -e "$COMPOSE_FILE" || -e "$ROOT_DIR/resources.bin" || -e "$ROOT_DIR/_native" ) ]]; then
    command -v curl >/dev/null 2>&1 || fail '找不到 curl。请先安装 curl。'
    TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oci-mao-download.XXXXXX")"
    ARCHIVE="$TEMP_DIR/OCI-Mao-$VERSION"
    DIGEST="$SHA_ARG"
    if [[ -z "$DIGEST" && "$VERSION" == 0.1.0 ]]; then DIGEST="$PINNED_SHA"; fi
    RELEASE_TAG="${VERSION_ARG:-$VERSION}"
    if [[ -z "$DIGEST" ]]; then
        download "https://api.github.com/repos/$REPOSITORY/releases/tags/$RELEASE_TAG" "$TEMP_DIR/release.json" || fail '无法读取 GitHub Release；请核对版本或使用 --sha256。'
        DIGEST="$(python3 - "$TEMP_DIR/release.json" "OCI-Mao-$VERSION" <<'PY'
import json, re, sys
release = json.load(open(sys.argv[1], encoding='utf-8'))
assets = [a for a in release.get('assets', []) if a.get('name') == sys.argv[2]]
if len(assets) != 1 or not re.fullmatch(r'sha256:[0-9a-f]{64}', assets[0].get('digest') or ''):
    raise SystemExit('GitHub 没有该安装包的可信 SHA256；请提供 --sha256。')
print(assets[0]['digest'][7:])
PY
)" || fail '没有可验证的 SHA256，停止安装。'
    fi
    if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/OCI-Mao-$VERSION" && ! -L "$SCRIPT_DIR/OCI-Mao-$VERSION" ]]; then
        say "使用仓库中的二进制包：OCI-Mao-$VERSION"
        cp -- "$SCRIPT_DIR/OCI-Mao-$VERSION" "$ARCHIVE"
    else
        say "从 GitHub Release 下载 OCI-Mao-$VERSION…"
        download "https://github.com/$REPOSITORY/releases/download/$RELEASE_TAG/OCI-Mao-$VERSION" "$ARCHIVE" || fail '安装包下载失败；检查网络和 Release 资产是否存在。'
    fi
    archive_tool validate "$ARCHIVE" "$DIGEST" "$VERSION" '' || fail '二进制安装包校验失败；未修改安装目录。'
    PACKAGE_DIR="$TEMP_DIR/package"
    archive_tool extract "$ARCHIVE" "$DIGEST" "$VERSION" "$PACKAGE_DIR" || fail '二进制包临时解压失败。'
    COMPOSE_FILE="$PACKAGE_DIR/compose.yaml"
fi

# 只读取项目名，绝不 source .env 或执行其中的内容。
read_env_project() {
    local line value found=""
    if [[ -e "$ENV_FILE" || -L "$ENV_FILE" ]]; then
        [[ -f "$ENV_FILE" && -r "$ENV_FILE" && ! -L "$ENV_FILE" ]] || fail '.env 必须是可读的普通文件，不能是符号链接。'
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
    [[ -f "$PROJECT_FILE" && -r "$PROJECT_FILE" && ! -L "$PROJECT_FILE" ]] || fail '.oci-panel-project 必须是可读的普通文件，不能是符号链接。'
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
for file in compose.yaml Dockerfile README.md resources.bin RELEASE.bin; do
    [[ -f "${PACKAGE_DIR:-$ROOT_DIR}/$file" && ! -L "${PACKAGE_DIR:-$ROOT_DIR}/$file" ]] || fail "发布包不完整，缺少 $file。请完整解压 OCI-Mao 二进制安装包。"
done
for arch in amd64 arm64; do
    native_modules=("${PACKAGE_DIR:-$ROOT_DIR}/_native/$arch/"*.so)
    [[ -f "${native_modules[0]}" ]] || fail "发布包不完整，缺少 $arch 原生模块。"
    for helper in _mao_resources mao_runtime _framework_routes; do
        native_helpers=("${PACKAGE_DIR:-$ROOT_DIR}/_native/$arch/$helper"*.so)
        [[ -f "${native_helpers[0]}" ]] || fail "发布包不完整，缺少 $arch 的 $helper 原生运行模块。"
    done
done
for command in docker mktemp sed ln rm; do
    command -v "$command" >/dev/null 2>&1 || fail "找不到 $command。请按 README 准备依赖后重试。"
done
docker compose version >/dev/null 2>&1 || fail 'Docker Compose v2 不可用。请安装/启用 docker compose 插件。'
docker info >/dev/null 2>&1 || fail '无法连接 Docker。请启动 Docker，并确认当前用户有访问权限；Linux 可按 README 配置 docker 组或使用 sudo。'

compose() {
    local env_path=/dev/null
    if [[ -f "$ENV_FILE" ]]; then env_path="$ENV_FILE"; fi
    docker compose --project-directory "${PACKAGE_DIR:-$ROOT_DIR}" -f "$COMPOSE_FILE" -p "$PROJECT" --env-file "$env_path" "$@"
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
    say '预检通过。未写入安装目录、.env、项目标记、容器或数据卷。正式安装使用相同参数并去掉 --check。'
    exit 0
fi

if [[ -n "$PACKAGE_DIR" ]]; then
    STAGE="安装已校验的二进制文件"
    archive_tool install "$ARCHIVE" "$DIGEST" "$VERSION" "$ROOT_DIR" || fail '安装文件写入失败；已有 .env 和数据卷保留。'
    PACKAGE_DIR=""
    COMPOSE_FILE="$ROOT_DIR/compose.yaml"
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
say '数据位于 Docker 命名卷；重新下载安装包请带 --version，并保留原目录/项目名。公网 HTTPS 与首次账号/云凭据配置请继续按 README 操作。'
