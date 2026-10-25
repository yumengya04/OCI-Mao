#!/usr/bin/env bash
# OCI-Mao 闭源二进制安装入口；不执行下载包中的安装脚本。
set -Eeuo pipefail
umask 077

SCRIPT_DIR=""
SCRIPT_FILE=""
INVOKED_NAME="$(basename -- "${BASH_SOURCE[0]:-install.sh}")"
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
    SCRIPT_FILE="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"
fi
ROOT_ARG=""
VERSION="0.1.1"
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
ACTION=""
ACTION_ARGS=()
ASSUME_YES=0
CONFIG_ROLLBACK=0
MANAGER_STATE_DIR="${OCI_MAO_STATE_DIR:-/etc/oci-mao}"
MANAGER_BIN_DIR="${OCI_MAO_BIN_DIR:-/usr/local/bin}"
MANAGER_LIB_DIR="${OCI_MAO_LIB_DIR:-/usr/local/lib/oci-mao}"
MANAGER_STATE="$MANAGER_STATE_DIR/deployment.json"

usage() {
    cat <<'HELP'
用法：bash install.sh [install|menu] [参数]
      ocimao [管理命令] [参数]

下载并校验 GitHub 闭源二进制包，构建并启动 panel、worker、logs。
在已经解压的二进制目录运行时直接使用该目录；其他情况默认安装到 /opt/oci-mao。
支持直接从刚克隆的仓库运行；不会安装 Docker、删除数据卷或覆盖已有 .env。
交互运行显示管理菜单，选择 16 安装/修复；install 命令直接执行安装/修复。
非交互运行保持自动安装，--check 始终只进行预检。

参数：
  --dir PATH      安装目录，默认 /opt/oci-mao（已解压包内运行时为包目录）。
  --version VER   下载指定 Release 标签（默认 0.1.1）；重跑此参数可重新安装。
  --sha256 HEX    指定安装包 SHA256；指定其他版本时也可读取 GitHub 资产 digest。
  --project NAME  首次安装的 Compose 项目名（默认 oci-panel）。
                  已有 .oci-panel-project / .env 的项目名必须一致。
  --timeout SEC   构建结束后等待三项服务就绪的秒数（默认 180，正整数）。
  --check         预检；下载和校验只用临时目录，不写安装目录或启动服务。
  --help, -h      显示本帮助。
  --yes           明确确认卸载、清除 Telegram 绑定或解除备份验证锁定。

安装后输入 ocimao 打开管理菜单；支持 install、status、start、stop、restart、logs、
config、backup [ZIP]、restore ZIP、upgrade、version、clear-telegram、uninstall、
unlock-backup、https-status、disable-https。备份密码通过隐藏输入或
OCI_MAO_BACKUP_PASSWORD 环境变量提供，不放在命令参数中。
手动回滚配置：ocimao config --rollback [本部署 .ocimao-config-backups 内的 .bak 路径]。
不指定路径时恢复最近的历史副本，校验或启动失败会保留操作前配置。

示例：
  sudo bash install.sh --dir /opt/oci-mao --check
  sudo bash install.sh install --dir /opt/oci-mao
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
        --yes) ASSUME_YES=1; shift ;;
        --rollback) [[ "$ACTION" == config ]] || fail '--rollback 仅用于 config 命令。'; CONFIG_ROLLBACK=1; shift ;;
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
        install|menu|status|start|stop|restart|logs|config|backup|restore|upgrade|version|clear-telegram|clear-tg|uninstall|unlock-backup|https-status|disable-https)
            [[ -z "$ACTION" ]] || fail '一次只能执行一个管理命令。'
            ACTION="$1"; shift ;;
        -*) fail "未知参数：$1。使用 --help 查看用法。" ;;
        *) [[ -n "$ACTION" ]] || fail "未知参数：$1。使用 --help 查看用法。"; ACTION_ARGS+=("$1"); shift ;;
    esac
done
if [[ "$INVOKED_NAME" == ocimao && -z "$ACTION" && "$CHECK_ONLY" == 0 && -z "$VERSION_ARG" && -z "$SHA_ARG" ]]; then ACTION=menu; fi
if [[ "$ACTION" == install && ${#ACTION_ARGS[@]} != 0 ]]; then fail 'install 不接受位置参数，请使用 --dir 等安装参数。'; fi
if [[ -n "$PROJECT_ARG" ]]; then
    valid_project "$PROJECT_ARG" || fail '项目名只允许小写字母、数字、下划线和连字符，首字符必须是字母或数字。'
fi

command -v python3 >/dev/null 2>&1 || fail '找不到 python3。请按 README 准备依赖后重试。'
if [[ -z "$ROOT_ARG" && -e "$MANAGER_STATE" ]]; then
    manager_values="$(python3 - "$MANAGER_STATE" <<'PY'
import json, os, re, sys
from pathlib import Path
p=Path(sys.argv[1])
if p.is_symlink() or not p.is_file(): raise SystemExit('部署记录必须是普通文件。')
record=json.loads(p.read_text(encoding='utf-8'))
directory=record.get('directory'); project=record.get('project')
if not isinstance(directory,str) or '\n' in directory or not os.path.isabs(directory) or not re.fullmatch(r'[a-z0-9][a-z0-9_-]*',project or ''):
    raise SystemExit('部署记录无效。')
print(directory); print(project)
PY
)" || fail '无法读取 OCI-Mao 部署记录。'
    manager_values="${manager_values//$'\r'/}"
    ROOT_ARG="${manager_values%$'\n'*}"
    recorded_project="${manager_values##*$'\n'}"
    [[ -z "$PROJECT_ARG" || "$PROJECT_ARG" == "$recorded_project" ]] || fail '管理命令项目名与部署记录不一致。'
    PROJECT_ARG="$recorded_project"
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
if [[ -z "$ACTION" && -t 0 && -z "$VERSION_ARG" && -z "$SHA_ARG" && "$CHECK_ONLY" == 0 ]]; then
    ACTION=menu
fi

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
            if path.is_file() and path.read_bytes()==data:
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

installed_version() {
    python3 - "$ROOT_DIR/RELEASE.bin" <<'PY'
import json,re,sys,zlib
from pathlib import Path
raw=Path(sys.argv[1]).read_bytes();magic=b'OCI-MAO-RELEASE\x00\x02'
if not raw.startswith(magic):raise SystemExit('无法读取已安装版本；发布清单格式无效。')
decoder=zlib.decompressobj();plain=decoder.decompress(raw[len(magic):],1024*1024+1)
if len(plain)>1024*1024 or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:raise SystemExit('版本清单损坏。')
value=json.loads(plain).get('version','')
if not re.fullmatch(r'v?\d+\.\d+\.\d+(?:[-+][A-Za-z0-9.-]+)?',value):raise SystemExit('版本清单无效。')
print(value)
PY
}

package_is_complete() {
    local directory="$1" file arch helper
    local modules=()
    for file in compose.yaml Dockerfile README.md resources.bin RELEASE.bin; do
        [[ -f "$directory/$file" && ! -L "$directory/$file" ]] || return 1
    done
    for arch in amd64 arm64; do
        modules=("$directory/_native/$arch/"*.so)
        [[ -f "${modules[0]}" && ${#modules[@]} -ge 196 ]] || return 1
        for helper in _mao_resources mao_runtime _framework_routes; do
            modules=("$directory/_native/$arch/$helper"*.so)
            [[ -f "${modules[0]}" ]] || return 1
        done
    done
    return 0
}

INSTALL_NEEDS_DOWNLOAD=0
if [[ "$ACTION" == install ]] && ! package_is_complete "$ROOT_DIR"; then
    INSTALL_NEEDS_DOWNLOAD=1
    if [[ -z "$VERSION_ARG" && -f "$ROOT_DIR/RELEASE.bin" && ! -L "$ROOT_DIR/RELEASE.bin" ]] && repair_version="$(installed_version 2>/dev/null)"; then
        VERSION_ARG="$repair_version"
        VERSION="${VERSION_ARG#v}"
    fi
fi

STAGE="获取并校验二进制包"
if [[ ( -z "$ACTION" || "$ACTION" == install ) && ( -n "$VERSION_ARG" || -n "$SHA_ARG" || "$INSTALL_NEEDS_DOWNLOAD" == 1 || !( -e "$COMPOSE_FILE" || -e "$ROOT_DIR/resources.bin" || -e "$ROOT_DIR/_native" ) ) ]]; then
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

compose() {
    local env_path=/dev/null
    if [[ -f "$ENV_FILE" ]]; then env_path="$ENV_FILE"; fi
    docker compose --project-directory "${PACKAGE_DIR:-$ROOT_DIR}" -f "$COMPOSE_FILE" -p "$PROJECT" --env-file "$env_path" "$@"
}

register_manager() {
    python3 - "$SCRIPT_FILE" "$ROOT_DIR" "$PROJECT" "$MANAGER_STATE_DIR" "$MANAGER_BIN_DIR" "$MANAGER_LIB_DIR" <<'PY'
import json, os, shutil, sys, tempfile
from pathlib import Path
source, directory, project, state_dir, bin_dir, lib_dir=sys.argv[1:]
root=Path(directory).resolve(); state=Path(state_dir); bindir=Path(bin_dir); lib=Path(lib_dir)
for target in (state,bindir,lib):
    for parent in (target,*target.parents):
        if parent.is_symlink(): raise SystemExit('管理入口目录不能是符号链接：'+str(parent))
    target.mkdir(parents=True,exist_ok=True)
registry=state/'deployment.json'; script=lib/'install.sh'; launcher=bindir/'ocimao'
if registry.is_symlink() or script.is_symlink(): raise SystemExit('管理配置或脚本不能是符号链接。')
if registry.exists():
    old=json.loads(registry.read_text(encoding='utf-8'))
    if old.get('directory')!=str(root).replace('\\','/') or old.get('project')!=project:
        raise SystemExit('ocimao 已管理其他安装目录；请使用原目录，不能覆盖其他部署记录。')
if launcher.exists() or launcher.is_symlink():
    if not ((launcher.is_symlink() and launcher.resolve()==script.resolve()) or
            (os.name=='nt' and launcher.is_file() and script.is_file() and launcher.read_bytes()==script.read_bytes())):
        raise SystemExit('ocimao 命令已被其他程序占用，不会覆盖。')
original=Path(source).resolve() if source else root/'install.sh'
if not original.is_file(): raise SystemExit('无法找到安装脚本以创建管理命令。')
def write(path,content,mode):
    fd,name=tempfile.mkstemp(prefix='.ocimao-',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as stream:stream.write(content)
        os.chmod(name,mode);os.replace(name,path)
    finally:
        if os.path.exists(name):os.unlink(name)
script_content=original.read_bytes()
if not script.is_file() or script.read_bytes()!=script_content:write(script,script_content,0o755)
write(registry,json.dumps({'directory':str(root).replace('\\','/'),'project':project},ensure_ascii=False).encode(),0o600)
os.chmod(state,0o700)
if not launcher.is_symlink():
    try:launcher.symlink_to(script)
    except OSError:
        if os.name!='nt':raise
        if not launcher.is_file() or launcher.read_bytes()!=script_content:write(launcher,script_content,0o755)
print('管理命令已就绪：'+str(launcher))
PY
}

manager_check_container_identity() {
    local container service details
    for service in panel worker logs; do
        container="$(compose ps --all -q "$service")" || return 1
        [[ -n "$container" ]] || continue
        details="$(docker inspect "$container")" || return 1
        printf '%s\n' "$details" | python3 -c 'import json,sys; from pathlib import Path; root=Path(sys.argv[1]).resolve(); project,service=sys.argv[2:]; rows=json.load(sys.stdin); assert isinstance(rows,list) and len(rows)==1,"容器身份异常"; item=rows[0]; labels=item.get("Config",{}).get("Labels",{}); assert labels.get("com.docker.compose.project")==project and labels.get("com.docker.compose.service")==service,"容器不属于本项目"; assert Path(labels.get("com.docker.compose.project.working_dir","")).resolve()==root,"同名项目来自其他安装目录"; configs=labels.get("com.docker.compose.project.config_files","").split(","); assert configs and Path(configs[0]).resolve()==root/"compose.yaml" and all(Path(p).resolve() in {root/"compose.yaml",root/"compose.ocimao-https.yaml"} for p in configs),"容器配置文件不属于本部署"; mounts=[m for m in item.get("Mounts",[]) if m.get("Destination")=="/app/data"]; assert len(mounts)==1 and mounts[0].get("Type")=="volume" and mounts[0].get("Name")==project+"_panel-data","容器数据卷不属于本部署"' "$ROOT_DIR" "$PROJECT" "$service" || return 1
    done
}

manager_ready() {
    [[ -f "$COMPOSE_FILE" && ! -L "$COMPOSE_FILE" ]] || { say '未检测到此目录的 OCI-Mao 部署，请先安装。'; return 1; }
    command -v docker >/dev/null 2>&1 || { say '找不到 Docker，请先安装 Docker。'; return 1; }
    docker compose version >/dev/null 2>&1 && docker info >/dev/null 2>&1 || { say 'Docker 或 Compose 不可用。'; return 1; }
    [[ -n "$MARKER_PROJECT" || -n "$ENV_PROJECT" || -n "$PROJECT_ARG" ]] || { say '无法确认已有部署项目，请先安装或明确指定原项目。'; return 1; }
    manager_check_container_identity || return 1
    local owner
    owner="$(docker volume inspect --format '{{ index .Labels "com.docker.compose.project" }}|{{ index .Labels "com.docker.compose.volume" }}' "${PROJECT}_panel-data" 2>/dev/null)" || owner=""
    [[ -z "$owner" || "$owner" == "$PROJECT|panel-data" ]] || { say '本项目数据卷归属不匹配，停止管理操作。'; return 1; }
}

manager_http_ready() {
    compose exec -T "$1" python -c 'import sys,urllib.request; opener=urllib.request.build_opener(urllib.request.ProxyHandler({})); r=opener.open(sys.argv[1],timeout=2); sys.exit(0 if r.status==200 else 1)' "$2" >/dev/null 2>&1
}

manager_wait() {
    local started=$SECONDS container service good
    while (( SECONDS-started<TIMEOUT )); do
        good=1
        for service in panel worker logs; do
            container="$(compose ps -q "$service")" || container=""
            if [[ -z "$container" || "$(docker inspect --format '{{.State.Running}}' "$container" 2>/dev/null)" != true ]]; then good=0; break; fi
        done
        if (( good )) && manager_http_ready panel 'http://127.0.0.1:8501/_stcore/health' && manager_http_ready logs 'http://127.0.0.1:8502/health'; then return 0; fi
        sleep 2
    done
    say '服务等待超时，请用 ocimao logs 查看原因。'; return 1
}

manager_confirm() {
    (( ASSUME_YES )) && return 0
    local answer
    printf '%s 输入 yes 确认：' "$1"
    IFS= read -r answer || return 1
    answer="${answer%$'\r'}"
    [[ "$answer" == yes ]]
}

manager_config() {
    local backup selected env_project editor_text="${VISUAL:-${EDITOR:-vi}}"
    local -a editor
    [[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] || { say '.env 不是普通配置文件。'; return 1; }
    backup="$(python3 - "$ENV_FILE" "$ROOT_DIR" <<'PY'
import os,shutil,sys,tempfile
from pathlib import Path
folder=Path(sys.argv[2])/'.ocimao-config-backups'
if folder.is_symlink():raise SystemExit('配置备份目录不能是符号链接。')
folder.mkdir(mode=0o700,exist_ok=True)
fd,path=tempfile.mkstemp(prefix='env-',suffix='.bak',dir=folder);os.close(fd)
shutil.copyfile(sys.argv[1],path);os.chmod(path,0o600);print(path)
PY
)" || return 1
    if (( CONFIG_ROLLBACK )); then
        selected="$(python3 - "$ROOT_DIR" "${1:-}" "$backup" <<'PY'
import sys
from pathlib import Path
root=Path(sys.argv[1]).resolve();folder=root/'.ocimao-config-backups';exclude=Path(sys.argv[3]).resolve()
source=Path(sys.argv[2]).absolute() if sys.argv[2] else next(iter(sorted((p for p in folder.glob('env-*.bak') if p.resolve()!=exclude),key=lambda p:p.stat().st_mtime,reverse=True)),None)
if source is None or source.is_symlink() or not source.is_file() or source.parent.resolve()!=folder.resolve() or source.suffix!='.bak':raise SystemExit('回滚只能选择此部署的 .ocimao-config-backups 内普通 .bak 文件。')
for parent in (folder,*folder.parents):
    if parent.is_symlink():raise SystemExit('回滚目录不能是符号链接。')
print(source)
PY
)" || return 1
        selected="${selected%$'\r'}"
        manager_restore_env "$selected" || return 1
        say "恢复配置副本：$selected"
    else
        IFS=' ' read -r -a editor <<< "$editor_text"
        if ! "${editor[@]}" "$ENV_FILE"; then say '编辑器未正常退出，恢复原配置。'; manager_restore_env "$backup"; return 1; fi
    fi
    if [[ -L "$ENV_FILE" ]] || ! env_project="$(read_env_project; printf '%s' "$ENV_PROJECT")" || [[ -n "$env_project" && "$env_project" != "$PROJECT" ]] || ! compose config --quiet; then
        say '配置校验失败，已恢复原配置。'; manager_restore_env "$backup"; return 1
    fi
    if ! compose up -d || ! manager_wait; then
        say '应用配置失败，正在恢复原配置和服务。'
        manager_restore_env "$backup" || return 1
        compose up -d || true
        return 1
    fi
    say "配置已应用，回滚副本：$backup"
}

manager_restore_env() {
    python3 - "$1" "$ENV_FILE" <<'PY'
import os,sys,tempfile
from pathlib import Path
source,target=map(Path,sys.argv[1:])
if target.is_symlink():target.unlink()
fd,name=tempfile.mkstemp(prefix='.ocimao-env-',dir=target.parent)
try:
    with os.fdopen(fd,'wb') as stream:stream.write(source.read_bytes())
    os.chmod(name,0o600);os.replace(name,target)
finally:
    if os.path.exists(name):os.unlink(name)
PY
}

manager_json() {
    local password="${OCI_MAO_BACKUP_PASSWORD:-}" rollback="${OCI_MAO_ROLLBACK_PASSWORD:-}"
    if [[ "$1" == password && -z "$password" ]]; then
        printf '备份密码：' >&2; IFS= read -r -s password || return 1; printf '\n' >&2
    fi
    if [[ "$1" == restore && -z "$password" ]]; then
        printf '原备份密码：' >&2; IFS= read -r -s password || return 1; printf '\n' >&2
    fi
    if [[ "$1" == restore && -z "$rollback" ]]; then
        printf '恢复前备份的新密码：' >&2; IFS= read -r -s rollback || return 1; printf '\n' >&2
    fi
    [[ "$password" != *$'\n'* && "$password" != *$'\r'* && "$rollback" != *$'\n'* && "$rollback" != *$'\r'* ]] || { say '备份密码不能包含换行。' >&2; return 1; }
    printf '%s\n%s\n' "$password" "$rollback" | python3 -c 'import json,sys; values=sys.stdin.read().splitlines(); result={"password":values[0] if values else ""}; result.update({"rollback_password":values[1] if len(values)>1 else ""} if sys.argv[1]=="restore" else {}); print(json.dumps(result))' "$1"
}

manager_backend() {
    compose exec -T panel python -c 'import panel_backup; raise SystemExit(panel_backup.management_main())' "$@"
}

manager_export_verified() {
    local source="$1" target="$2" expected="$3" container
    python3 - "$target" "$expected" <<'PY' || return 1
import re,sys
from pathlib import Path
target=Path(sys.argv[1]).absolute()
if not re.fullmatch(r'[0-9a-f]{64}',sys.argv[2]):raise SystemExit('备份摘要无效。')
if target.exists() or target.is_symlink():raise SystemExit('备份目标已存在，不会覆盖。')
for parent in target.parents:
    if parent.is_symlink():raise SystemExit('备份目录不能是符号链接。')
target.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
PY
    container="$(compose ps -q panel)"; [[ -n "$container" ]] || return 1
    TEMP_FILE="$(mktemp "$(dirname -- "$target")/.ocimao-backup.XXXXXX")" || return 1
    docker cp "$container:$source" "$TEMP_FILE" || return 1
    python3 - "$TEMP_FILE" "$target" "$expected" <<'PY' || return 1
import hashlib,os,sys
from pathlib import Path
temporary,target=map(Path,sys.argv[1:3])
if temporary.is_symlink() or hashlib.sha256(temporary.read_bytes()).hexdigest()!=sys.argv[3]:raise SystemExit('导出的备份 SHA256 校验失败。')
os.chmod(temporary,0o600)
try:os.link(temporary,target,follow_symlinks=False)
except FileExistsError:raise SystemExit('备份目标已存在，不会覆盖。')
temporary.unlink()
PY
    TEMP_FILE=""
}

manager_backup() {
    local target="${1:-$ROOT_DIR/backups/oci-mao-$(date +%Y%m%d-%H%M%S).zip}" id container payload output expected
    id="$(python3 -c 'import secrets;print(secrets.token_hex(12))')"
    id="${id%$'\r'}"
    python3 - "$target" <<'PY' || return 1
import sys
from pathlib import Path
p=Path(sys.argv[1]).absolute()
if p.exists() or p.is_symlink():raise SystemExit('备份目标已存在，不会覆盖：'+str(p))
for parent in p.parents:
    if parent.is_symlink():raise SystemExit('备份目录不能是符号链接。')
p.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
PY
    payload="$(manager_json password)" || return 1
    output="$(printf '%s\n' "$payload" | manager_backend backup --path "/app/data/cli-backups/backup-$id.zip")" || return 1
    expected="$(printf '%s\n' "$output" | python3 -c 'import json,re,sys; value=json.load(sys.stdin).get("sha256",""); assert re.fullmatch("[0-9a-f]{64}",value),"备份摘要无效"; print(value)')" || return 1
    expected="${expected%$'\r'}"
    manager_export_verified "/app/data/cli-backups/backup-$id.zip" "$target" "$expected" || return 1
    say "备份已保存：$target"
}

manager_restore() {
    local source="${1:-}" id payload output rollback rollback_sha export_failed=0
    if [[ -z "$source" ]]; then printf '备份 ZIP 路径：'; IFS= read -r source || return 1; fi
    [[ -f "$source" && ! -L "$source" ]] || { say '恢复文件必须是普通 ZIP 文件。'; return 1; }
    manager_confirm '恢复将导入备份配置；恢复前会自动备份当前配置。' || return 1
    payload="$(manager_json restore)" || return 1
    id="$(python3 -c 'import secrets;print(secrets.token_hex(12))')"
    id="${id%$'\r'}"
    compose exec -T panel python -c 'import os,sys; from pathlib import Path; p=Path("/app/data/cli-backups")/sys.argv[1]; p.parent.mkdir(mode=0o700,exist_ok=True); data=sys.stdin.buffer.read(200*1024*1024+1); assert len(data)<=200*1024*1024,"Backup exceeds limit"; fd=os.open(p,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600); f=os.fdopen(fd,"wb"); f.write(data); f.close()' "incoming-$id.zip" < "$source" || return 1
    if output="$(printf '%s\n' "$payload" | manager_backend restore --path "/app/data/cli-backups/incoming-$id.zip")"; then
        say "$output"
        rollback="$(printf '%s\n' "$output" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("rollback_path",""))')" || rollback=""
        rollback_sha="$(printf '%s\n' "$output" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("rollback_sha256",""))')" || rollback_sha=""
        rollback="${rollback%$'\r'}"; rollback_sha="${rollback_sha%$'\r'}"
        if [[ "$rollback" =~ ^/app/data/cli-backups/[A-Za-z0-9_.-]+\.zip$ ]]; then
            if ! manager_export_verified "$rollback" "$ROOT_DIR/backups/$(basename -- "$rollback")" "$rollback_sha"; then export_failed=1; fi
        else
            export_failed=1
        fi
        compose exec -T panel python -c 'import sys; from pathlib import Path; (Path("/app/data/cli-backups")/sys.argv[1]).unlink(missing_ok=True)' "incoming-$id.zip" || say '临时恢复文件仍在本部署数据卷。'
        compose restart panel worker logs && manager_wait || { say '配置已恢复，服务未全部就绪，请查看日志。'; return 1; }
        if (( export_failed )); then say "配置已恢复并已重启服务；恢复前加密备份未导出，仍保留在数据卷：$rollback"; return 1; fi
        say '配置已恢复，恢复前加密备份已校验并保存到主机。'
    else
        compose exec -T panel python -c 'import sys; from pathlib import Path; (Path("/app/data/cli-backups")/sys.argv[1]).unlink(missing_ok=True)' "incoming-$id.zip" || true
        return 1
    fi
}

manager_upgrade() {
    command -v curl >/dev/null 2>&1 || { say '找不到 curl。'; return 1; }
    TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/oci-mao-download.XXXXXX")"
    download "https://api.github.com/repos/$REPOSITORY/releases/latest" "$TEMP_DIR/release.json" || return 1
    local values tag digest current
    values="$(python3 - "$TEMP_DIR/release.json" "$REPOSITORY" <<'PY'
import json,re,sys
from urllib.parse import quote,urlsplit
value=json.load(open(sys.argv[1],encoding='utf-8'));tag=value.get('tag_name','')
if value.get('draft') or value.get('prerelease') or not re.fullmatch(r'v?\d+\.\d+\.\d+',tag):raise SystemExit('没有有效的最新正式版本。')
name='OCI-Mao-'+tag.removeprefix('v'); rows=[a for a in value.get('assets',[]) if a.get('name')==name]
if len(rows)!=1:raise SystemExit('最新 Release 缺少 OCI-Mao 二进制包。')
digest=rows[0].get('digest') or ''
if not re.fullmatch(r'sha256:[a-fA-F0-9]{64}',digest):raise SystemExit('最新 Release 没有可验证 SHA256，不会安装。')
print(tag); print(digest[7:].lower())
PY
)" || return 1
    values="${values//$'\r'/}"
    tag="${values%$'\n'*}"; digest="${values##*$'\n'}"
    current="$(installed_version)" || return 1
    if ! python3 - "$current" "$tag" <<'PY'
import sys
parts=lambda v:tuple(map(int,v.removeprefix('v').split('.')))
raise SystemExit(0 if parts(sys.argv[2])>parts(sys.argv[1]) else 1)
PY
    then say "已安装 $current，最新正式版本 $tag，无需升级。"; return 0; fi
    say "升级：$current → $tag；原数据卷与 .env 保留。"
    bash "$SCRIPT_FILE" --dir "$ROOT_DIR" --project "$PROJECT" --version "$tag" --sha256 "$digest" --timeout "$TIMEOUT"
}

manager_https_status() {
    say '本部署默认 HTTP 端口：127.0.0.1:8501（面板）、127.0.0.1:8502（日志）。'
    if [[ -f "$ROOT_DIR/.oci-mao-https.json" && ! -L "$ROOT_DIR/.oci-mao-https.json" ]]; then
        say '检测到本部署的 HTTPS 管理记录。'
    else
        say '本部署未启用由 ocimao 管理的 HTTPS；主机上的外部反向代理不由本命令管理。'
    fi
    compose ps --all
    [[ ! -f "$ENV_FILE" ]] || python3 - "$ENV_FILE" <<'PY'
import sys
for line in open(sys.argv[1],encoding='utf-8'):
    if line.startswith(('PANEL_LOG_WS_URL=','PANEL_ALLOWED_ORIGINS=')):print(line.rstrip())
PY
}

manager_disable_https() {
    local state="$ROOT_DIR/.oci-mao-https.json" overlay="$ROOT_DIR/compose.ocimao-https.yaml" container details before_file proposed_file
    if [[ ! -e "$state" ]]; then say '没有本工具管理的 HTTPS，原 HTTP 端口保持可用；外部反代未作修改。'; return 0; fi
python3 - "$state" "$overlay" "$PROJECT" "$ENV_FILE" <<'PY' || return 1
import json,sys
from pathlib import Path
p,o=map(Path,sys.argv[1:3]);v=json.loads(p.read_text(encoding='utf-8'))
if p.is_symlink() or o.is_symlink() or not o.is_file() or v.get('project')!=sys.argv[3] or v.get('overlay')!='compose.ocimao-https.yaml' or not isinstance(v.get('env_before'),dict):raise SystemExit('HTTPS 管理记录不完整，停止操作。')
env=Path(sys.argv[4]);before=v['env_before'];keys={'PANEL_LOG_WS_URL','PANEL_ALLOWED_ORIGINS'}
if env.is_symlink() or not env.is_file() or set(before)-keys or any(value is not None and (not isinstance(value,str) or '\n' in value or '\r' in value) for value in before.values()):raise SystemExit('HTTPS 原配置记录无效，未停止服务。')
PY
    container="$(docker compose --project-directory "$ROOT_DIR" -f "$COMPOSE_FILE" -f "$overlay" -p "$PROJECT" --env-file "$ENV_FILE" ps --all -q https)" || return 1
    if [[ -n "$container" ]]; then
        details="$(docker inspect "$container")" || return 1
        printf '%s\n' "$details" | python3 -c 'import json,sys;from pathlib import Path;root=Path(sys.argv[1]).resolve();project=sys.argv[2];rows=json.load(sys.stdin);assert isinstance(rows,list) and len(rows)==1,"HTTPS 容器身份异常";labels=rows[0].get("Config",{}).get("Labels",{});assert labels.get("com.docker.compose.project")==project and labels.get("com.docker.compose.service")=="https" and Path(labels.get("com.docker.compose.project.working_dir","")).resolve()==root,"HTTPS 容器不属于此部署"; configs=[Path(p).resolve() for p in labels.get("com.docker.compose.project.config_files","").split(",")];assert root/"compose.ocimao-https.yaml" in configs and all(p in {root/"compose.yaml",root/"compose.ocimao-https.yaml"} for p in configs),"HTTPS 容器配置不属于此部署"' "$ROOT_DIR" "$PROJECT" || return 1
    fi
    before_file="$(mktemp "$ROOT_DIR/.ocimao-https-before.XXXXXX")" || return 1
    proposed_file="$(mktemp "$ROOT_DIR/.ocimao-https-after.XXXXXX")" || { rm -f -- "$before_file"; return 1; }
    python3 - "$state" "$ENV_FILE" "$before_file" "$proposed_file" <<'PY' || { rm -f -- "$before_file" "$proposed_file"; return 1; }
import json,re,sys
from pathlib import Path
state,env,snapshot,proposed=map(Path,sys.argv[1:]);data=json.loads(state.read_text(encoding='utf-8'))
before=data['env_before'];keys={'PANEL_LOG_WS_URL','PANEL_ALLOWED_ORIGINS'}
snapshot.write_bytes(env.read_bytes())
assignment=re.compile(r'^\s*(?:export\s+)?(PANEL_LOG_WS_URL|PANEL_ALLOWED_ORIGINS)\s*=')
lines=[line for line in env.read_text(encoding='utf-8').splitlines() if not assignment.match(line)]
for key in sorted(keys):
    value=before.get(key)
    if value is not None:lines.append(key+'='+value)
proposed.write_text('\n'.join(lines)+'\n',encoding='utf-8')
PY
    if ! docker compose --project-directory "$ROOT_DIR" -f "$COMPOSE_FILE" -p "$PROJECT" --env-file "$proposed_file" config --quiet; then
        rm -f -- "$before_file" "$proposed_file"; say '恢复 HTTP 的配置无效，HTTPS 服务保持原状。'; return 1
    fi
    if ! docker compose --project-directory "$ROOT_DIR" -f "$COMPOSE_FILE" -f "$overlay" -p "$PROJECT" --env-file "$ENV_FILE" stop https; then rm -f -- "$before_file" "$proposed_file"; return 1; fi
    if ! manager_restore_env "$proposed_file" || ! compose up -d || ! manager_wait || ! docker compose --project-directory "$ROOT_DIR" -f "$COMPOSE_FILE" -f "$overlay" -p "$PROJECT" --env-file "$ENV_FILE" rm -f https; then
        manager_restore_env "$before_file" || true
        docker compose --project-directory "$ROOT_DIR" -f "$COMPOSE_FILE" -f "$overlay" -p "$PROJECT" --env-file "$ENV_FILE" up -d || true
        rm -f -- "$before_file" "$proposed_file"
        say 'HTTP 恢复未完成，原配置及 HTTPS 管理记录已保留，并已尝试恢复本项目 HTTPS。'; return 1
    fi
    python3 - "$state" "$overlay" <<'PY' || return 1
import sys
from pathlib import Path
for name in sys.argv[1:]:Path(name).unlink()
PY
    rm -f -- "$before_file" "$proposed_file"
    say '已停用本部署的 HTTPS 代理，恢复启用前的 HTTP 配置和原端口。'
}

manager_uninstall() {
    manager_confirm "卸载项目 $PROJECT；保留数据卷、.env 和备份。" || return 1
    if [[ -e "$ROOT_DIR/.oci-mao-https.json" ]]; then manager_disable_https || return 1; fi
    compose down || return 1
    python3 - "$ROOT_DIR" "$PROJECT" "$MANAGER_STATE" "$MANAGER_BIN_DIR/ocimao" "$MANAGER_LIB_DIR/install.sh" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1]).resolve(); project=sys.argv[2]; state,launcher,script=map(Path,sys.argv[3:])
fixed=['resources.bin','RELEASE.bin','Dockerfile','compose.yaml','install.sh','README.md','.dockerignore','deploy/compose.oracle-ai.yaml','.oci-panel-project']
paths=[root/name for name in fixed]
for arch in ('amd64','arm64'):paths.extend((root/'_native'/arch).glob('*.so'))
for path in paths:
    if (not path.resolve().is_relative_to(root) or path.is_symlink()
            or any(parent.is_symlink() for parent in path.parents if parent.is_relative_to(root))):raise SystemExit('卸载路径不安全，停止移除文件。')
for path in paths:
    if path.is_file():path.unlink()
if state.is_file() and not state.is_symlink():
    value=json.loads(state.read_text(encoding='utf-8'))
    if value.get('directory')==str(root).replace('\\','/') and value.get('project')==project:
        if ((launcher.is_symlink() and launcher.resolve()==script.resolve()) or
            (launcher.is_file() and script.is_file() and launcher.read_bytes()==script.read_bytes())):launcher.unlink()
        if script.is_file() and not script.is_symlink():script.unlink()
        state.unlink()
print('程序已卸载。Docker 数据卷、.env、配置回滚副本和备份均已保留。')
PY
}

manager_install() {
    [[ -n "$SCRIPT_FILE" && -f "$SCRIPT_FILE" ]] || { say '请先将 install.sh 下载为文件，再执行安装/修复。'; return 1; }
    local options=(install --dir "$ROOT_DIR" --timeout "$TIMEOUT")
    if [[ -n "$MARKER_PROJECT" || -n "$ENV_PROJECT" || -n "$PROJECT_ARG" ]]; then options+=(--project "$PROJECT"); fi
    if [[ -n "$VERSION_ARG" ]]; then options+=(--version "$VERSION_ARG"); fi
    if [[ -n "$SHA_ARG" ]]; then options+=(--sha256 "$SHA_ARG"); fi
    if (( CHECK_ONLY )); then options+=(--check); fi
    say "安装/修复：$ROOT_DIR；保留已有 .env、项目名和数据卷。"
    bash "$SCRIPT_FILE" "${options[@]}" || return $?
    if (( ! CHECK_ONLY )); then
        COMPOSE_FILE="$ROOT_DIR/compose.yaml"
        MARKER_PROJECT="$(cat -- "$PROJECT_FILE")"
        MARKER_PROJECT="${MARKER_PROJECT%$'\r'}"
        read_env_project
        PROJECT="$MARKER_PROJECT"
    fi
}

manager_dispatch() {
    local command="$1"; shift
    [[ "$command" == install ]] && { manager_install "$@"; return; }
    [[ "$command" == version ]] && { installed_version; return; }
    manager_ready || return 1
    case "$command" in
        status) say "OCI-Mao · $ROOT_DIR · 项目 $PROJECT"; compose ps --all ;;
        start) compose up -d && manager_wait ;;
        stop) compose stop panel worker logs ;;
        restart) compose restart panel worker logs && manager_wait ;;
        logs) local code=0; trap ':' INT; compose logs --follow --tail=100 panel worker logs || code=$?; trap - INT; [[ "$code" == 0 || "$code" == 130 ]] ;;
        config) manager_config "$@" ;;
        backup) manager_backup "$@" ;;
        restore) manager_restore "$@" ;;
        upgrade) manager_upgrade ;;
        clear-telegram|clear-tg) manager_confirm '清除本面板 Telegram 绑定和通知配置。' && printf '{"confirm":true}\n' | manager_backend clear-telegram ;;
        unlock-backup) manager_confirm '解除备份密码验证锁定；不修改管理员登录锁定。' && printf '{"confirm":true}\n' | manager_backend unlock-backup ;;
        uninstall) manager_uninstall ;;
        https-status) manager_https_status ;;
        disable-https) manager_disable_https ;;
        *) say '未知管理命令。'; return 1 ;;
    esac
}

manager_menu() {
    local choice command config_choice
    while true; do
        cat <<'MENU'

== OCI Mao 管理 ==
  1) 查看状态        2) 启动        3) 停止        4) 重启
  5) 查看实时日志    6) 修改配置（含回滚）
  7) 备份            8) 恢复
  9) 升级到最新版   10) 版本信息
 11) 清除Tg绑定    12) 卸载
 13) 解除备份验证锁定
 14) HTTPS 服务状态  15) 恢复原端口访问（停用 HTTPS）
 16) 安装/修复（保留配置和数据卷）
  0) 退出
MENU
        printf '请选择：'; IFS= read -r choice || return 0
        choice="${choice%$'\r'}"
        case "$choice" in
            0) return 0 ;; 1) command=status ;; 2) command=start ;; 3) command=stop ;;
            4) command=restart ;; 5) command=logs ;; 6) command=config ;; 7) command=backup ;;
            8) command=restore ;; 9) command=upgrade ;; 10) command=version ;;
            11) command=clear-telegram ;; 12) command=uninstall ;; 13) command=unlock-backup ;;
            14) command=https-status ;; 15) command=disable-https ;; 16) command=install ;;
            *) say '请输入 0 至 16。'; continue ;;
        esac
        if [[ "$command" == config ]]; then
            printf '1) 修改配置  2) 回滚到上次配置  0) 返回\n请选择：'
            IFS= read -r config_choice || return 0
            config_choice="${config_choice%$'\r'}"
            case "$config_choice" in
                0) continue ;; 1) CONFIG_ROLLBACK=0 ;; 2) CONFIG_ROLLBACK=1 ;;
                *) say '请输入 0、1 或 2。'; continue ;;
            esac
        fi
        if manager_dispatch "$command"; then [[ "$command" == uninstall ]] && return 0; else say '操作未完成，已有数据保留。'; fi
        CONFIG_ROLLBACK=0
    done
}

if [[ "$ACTION" == menu && -f "$PROJECT_FILE" && -f "$ENV_FILE" && -t 0 ]]; then
    say "检测到已有 OCI-Mao：$ROOT_DIR（$PROJECT）。"
    register_manager || fail '管理命令创建失败。'
fi
if [[ -n "$ACTION" && "$ACTION" != install ]]; then
    if [[ "$ACTION" == menu ]]; then manager_menu; else manager_dispatch "$ACTION" "${ACTION_ARGS[@]}"; fi
    exit $?
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
manager_check_container_identity || fail '已有同名项目容器的目录、配置或数据卷不属于本部署，未执行安装/修复。'

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
register_manager || fail '管理命令创建失败；配置和数据保留。'

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
say '输入 ocimao 打开管理菜单。'
say '面板：http://127.0.0.1:8501'
say '日志查看：http://127.0.0.1:8502/logs'
say '数据位于 Docker 命名卷；重新下载安装包请带 --version，并保留原目录/项目名。公网 HTTPS 与首次账号/云凭据配置请继续按 README 操作。'
