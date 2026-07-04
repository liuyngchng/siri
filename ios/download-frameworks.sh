#!/usr/bin/env bash
#
# download-frameworks.sh
# 下载 sherpa-onnx iOS 预编译 framework（onnxruntime + sherpa-onnx）
#
# 用法:
#   chmod +x download-frameworks.sh
#   ./download-frameworks.sh
#
# 这些 framework 从 k2-fsa/sherpa-onnx GitHub Releases 下载，
# 不提交到 git（已在 .gitignore 中忽略 ios/Frameworks/）。
#
# 下载后解压到 ios/Frameworks/，Xcode 项目可直接引用。

set -euo pipefail

# ============================================================
# 配置区
# ============================================================

# sherpa-onnx iOS 预编译包版本
SHERPA_ONNX_VERSION="v1.13.3"

# 下载 URL（从 k2-fsa/sherpa-onnx GitHub Releases）
# 如果此链接失效，请访问 https://github.com/k2-fsa/sherpa-onnx/releases
# 找到对应版本的 iOS 包（sherpa-onnx-v*-ios.tar.bz2）并更新下面的 URL
DOWNLOAD_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/${SHERPA_ONNX_VERSION}/sherpa-onnx-${SHERPA_ONNX_VERSION}-ios.tar.bz2"

ARCHIVE_NAME="sherpa-onnx-${SHERPA_ONNX_VERSION}-ios.tar.bz2"

# ============================================================
# 路径
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRAMEWORKS_DIR="${SCRIPT_DIR}/Frameworks"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DOWNLOAD_DIR="${PROJECT_DIR}/.model_cache"

# ============================================================
# 工具函数
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $*"; }

check_deps() {
    local missing=()
    for cmd in curl bunzip2; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log_error "缺少依赖: ${missing[*]}"
        exit 1
    fi
}

# ============================================================
# 主流程
# ============================================================

echo ""
echo "=============================================="
echo "  Siri iOS Framework 下载"
echo "=============================================="
echo ""
echo "  sherpa-onnx 版本: ${SHERPA_ONNX_VERSION}"
echo "  下载地址: ${DOWNLOAD_URL}"
echo "  目标目录: ${FRAMEWORKS_DIR}"
echo ""

check_deps

# 检查是否已存在
if [ -d "${FRAMEWORKS_DIR}/onnxruntime.xcframework" ] && [ -d "${FRAMEWORKS_DIR}/sherpa-onnx.xcframework" ]; then
    log_warn "Framework 已存在: ${FRAMEWORKS_DIR}"
    read -p "  是否重新下载? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "跳过下载"
        exit 0
    fi
    log_info "删除旧 framework..."
    rm -rf "${FRAMEWORKS_DIR}"
fi

mkdir -p "$DOWNLOAD_DIR"
mkdir -p "$FRAMEWORKS_DIR"

# ---- 下载 ----
log_step "1/2 下载 sherpa-onnx iOS 预编译包..."
log_info "URL: ${DOWNLOAD_URL}"
curl -L --progress-bar -o "${DOWNLOAD_DIR}/${ARCHIVE_NAME}" "${DOWNLOAD_URL}"
log_info "下载完成: ${ARCHIVE_NAME}"

# ---- 解压 ----
log_step "2/2 解压到 Frameworks 目录..."
log_info "解压 .tar.bz2..."

# 先解压到临时目录
TEMP_DIR="${DOWNLOAD_DIR}/ios-frameworks-tmp"
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"

tar -xjf "${DOWNLOAD_DIR}/${ARCHIVE_NAME}" -C "$TEMP_DIR"

# 查找并移动 .xcframework 文件
XC_FRAMEWORKS=$(find "$TEMP_DIR" -name "*.xcframework" -maxdepth 3 -type d)
if [ -z "$XC_FRAMEWORKS" ]; then
    log_error "未在压缩包中找到 .xcframework 文件"
    log_error "请检查 sherpa-onnx Releases 页面: https://github.com/k2-fsa/sherpa-onnx/releases"
    exit 1
fi

for fw in $XC_FRAMEWORKS; do
    fw_name="$(basename "$fw")"
    log_info "安装: ${fw_name}"
    cp -R "$fw" "${FRAMEWORKS_DIR}/"
done

# 清理临时文件
rm -rf "$TEMP_DIR"
log_info "临时文件已清理"

# ============================================================
# 完成
# ============================================================

echo ""
echo "=============================================="
echo "  下载完成"
echo "=============================================="
echo ""
echo "  已安装的 Framework:"
ls -d "${FRAMEWORKS_DIR}"/* 2>/dev/null | while read f; do
    fw_name="$(basename "$f")"
    fw_size="$(du -sh "$f" | cut -f1)"
    echo "    ${fw_name} (${fw_size})"
done
echo ""
echo "  下一步:"
echo "    在 Xcode 中打开项目即可编译运行"
echo ""
log_info "全部就绪!"
