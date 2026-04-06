#!/bin/bash
#
# Linux 多格式打包脚本
# 生成 Debian、Arch Linux 和 tarball 包
#
# 使用方法:
#   ./scripts/package-linux.sh [all|deb|arch|tarball]
#
# 示例:
#   ./scripts/package-linux.sh all       # 生成所有格式
#   ./scripts/package-linux.sh deb       # 只生成 .deb
#   ./scripts/package-linux.sh arch      # 只生成 Arch 包
#   ./scripts/package-linux.sh tarball   # 只生成 .tar.gz
#

set -e  # 遇到错误立即退出

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 获取项目根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# 读取版本号
if [ -f "CMakeLists.txt" ]; then
    VERSION=$(grep "set(PROJECT_VERSION" CMakeLists.txt | sed 's/.*"\(.*\)".*/\1/')
else
    VERSION="1.3.0"
    log_warning "无法从 CMakeLists.txt 读取版本号，使用默认版本: $VERSION"
fi

BUILD_DIR="build-linux"
PACKAGE_OUTPUT_DIR="$PROJECT_ROOT/packages"

log_info "JinGo VPN Linux 打包工具"
log_info "版本: $VERSION"
log_info "====================================="

# 创建输出目录
mkdir -p "$PACKAGE_OUTPUT_DIR"

# 检查构建目录
if [ ! -d "$BUILD_DIR" ]; then
    log_error "构建目录不存在: $BUILD_DIR"
    log_info "请先运行构建命令: cmake -B $BUILD_DIR -G Ninja && ninja -C $BUILD_DIR"
    exit 1
fi

# 检查可执行文件
if [ ! -f "$BUILD_DIR/bin/JinGo" ]; then
    log_error "可执行文件不存在: $BUILD_DIR/bin/JinGo"
    log_info "请先编译项目: ninja -C $BUILD_DIR"
    exit 1
fi

#############################################
# Debian 包 (.deb)
#############################################
package_deb() {
    log_info "开始构建 Debian 包..."

    cd "$BUILD_DIR"

    # 使用 CPack 生成 DEB
    cpack -G DEB

    # 移动到输出目录
    mv -f *.deb "$PACKAGE_OUTPUT_DIR/" 2>/dev/null || true

    cd "$PROJECT_ROOT"

    DEB_FILE=$(ls "$PACKAGE_OUTPUT_DIR"/jingo*.deb 2>/dev/null | head -1)
    if [ -f "$DEB_FILE" ]; then
        log_success "Debian 包已生成: $(basename $DEB_FILE)"
        log_info "  路径: $DEB_FILE"
        log_info "  大小: $(du -h "$DEB_FILE" | cut -f1)"
        log_info "  安装命令: sudo dpkg -i $DEB_FILE"
    else
        log_error "Debian 包生成失败"
        return 1
    fi
}

#############################################
# Tarball (.tar.gz)
#############################################
package_tarball() {
    log_info "开始构建 Tarball..."

    cd "$BUILD_DIR"

    # 使用 CPack 生成 TGZ
    cpack -G TGZ

    # 移动到输出目录
    mv -f *.tar.gz "$PACKAGE_OUTPUT_DIR/" 2>/dev/null || true

    cd "$PROJECT_ROOT"

    TGZ_FILE=$(ls "$PACKAGE_OUTPUT_DIR"/jingo-*.tar.gz 2>/dev/null | head -1)
    if [ -f "$TGZ_FILE" ]; then
        log_success "Tarball 已生成: $(basename $TGZ_FILE)"
        log_info "  路径: $TGZ_FILE"
    else
        log_error "Tarball 生成失败"
        return 1
    fi
}

#############################################
# Arch Linux 包 (.pkg.tar.zst)
#############################################
package_arch() {
    log_info "开始构建 Arch Linux 包..."

    # 检查 makepkg 是否安装
    if ! command -v makepkg &> /dev/null; then
        log_warning "makepkg 未安装，跳过 Arch Linux 包构建"
        log_info "在 Arch Linux 上安装: sudo pacman -S base-devel"
        log_info "在其他系统上，可以使用 Docker 构建 Arch 包"
        return 0
    fi

    # 检查 PKGBUILD 文件
    if [ ! -f "PKGBUILD" ]; then
        log_error "PKGBUILD 文件不存在"
        return 1
    fi

    # 创建源码 tarball（makepkg 需要）
    TARBALL_NAME="jingo-$VERSION.tar.gz"
    log_info "创建源码归档: $TARBALL_NAME"

    git archive --format=tar.gz --prefix="jingo-$VERSION/" HEAD > "$TARBALL_NAME"

    # 复制预编译的库文件（如果需要）
    mkdir -p "jingo-$VERSION/build-linux/bin"
    cp -r "$BUILD_DIR/bin/JinGo" "jingo-$VERSION/build-linux/bin/" 2>/dev/null || true

    # 运行 makepkg
    makepkg -f --skipinteg

    # 移动到输出目录
    mv -f *.pkg.tar.zst "$PACKAGE_OUTPUT_DIR/" 2>/dev/null || true

    # 清理
    rm -rf "$TARBALL_NAME" jingo-$VERSION/

    PKG_FILE=$(ls "$PACKAGE_OUTPUT_DIR"/jingo-*.pkg.tar.zst 2>/dev/null | head -1)
    if [ -f "$PKG_FILE" ]; then
        log_success "Arch Linux 包已生成: $(basename $PKG_FILE)"
        log_info "  路径: $PKG_FILE"
        log_info "  安装命令: sudo pacman -U $PKG_FILE"
    else
        log_warning "Arch Linux 包生成失败或被跳过"
    fi
}

#############################################
# 主逻辑
#############################################
PACKAGE_TYPE="${1:-all}"

case "$PACKAGE_TYPE" in
    all)
        log_info "构建所有包格式..."
        package_deb
        package_tarball
        package_arch
        ;;
    deb|debian)
        package_deb
        ;;
    arch|archlinux)
        package_arch
        ;;
    tarball|tgz|tar.gz)
        package_tarball
        ;;
    *)
        log_error "未知的包类型: $PACKAGE_TYPE"
        echo ""
        echo "用法: $0 [all|deb|arch|tarball]"
        echo ""
        echo "选项:"
        echo "  all       生成所有格式 (默认)"
        echo "  deb       只生成 Debian 包 (.deb)"
        echo "  arch      只生成 Arch Linux 包 (.pkg.tar.zst)"
        echo "  tarball   只生成通用 tarball (.tar.gz)"
        exit 1
        ;;
esac

# 显示生成的包
echo ""
log_info "====================================="
log_info "打包完成！生成的文件:"
log_info "====================================="
ls -lh "$PACKAGE_OUTPUT_DIR"/ 2>/dev/null || log_warning "未找到任何包文件"

echo ""
log_success "所有操作完成！"
