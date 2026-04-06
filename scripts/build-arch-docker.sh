#!/bin/bash
#
# 使用 Docker 构建 Arch Linux 包
# 适用于在非 Arch 系统（如 Ubuntu）上构建 Arch 包
#

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  使用 Docker 构建 Arch Linux 包${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# 检查 Docker
if ! command -v docker &> /dev/null; then
    echo -e "${RED}错误: Docker 未安装${NC}"
    echo ""
    echo "安装 Docker:"
    echo "  Ubuntu/Debian: sudo apt-get install docker.io"
    echo "  然后: sudo usermod -aG docker \$USER"
    echo "  重新登录使更改生效"
    exit 1
fi

# 获取项目根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 读取版本号
VERSION=$(grep "set(PROJECT_VERSION" "$PROJECT_ROOT/CMakeLists.txt" | sed 's/.*"\(.*\)".*/\1/' || echo "1.3.0")

echo -e "${BLUE}版本: ${NC}$VERSION"
echo -e "${BLUE}项目目录: ${NC}$PROJECT_ROOT"
echo ""

# 创建 Dockerfile
cat > /tmp/Dockerfile.jingo-arch << 'EOF'
FROM archlinux:latest

# 更新系统并安装依赖
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm \
        base-devel \
        git \
        cmake \
        ninja \
        qt6-base \
        qt6-declarative \
        qt6-tools \
        qt6-quickcontrols2 \
        libxcb \
        xcb-util-cursor

# 创建构建用户（makepkg 不能以 root 运行）
RUN useradd -m -G wheel builder && \
    echo "builder ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

WORKDIR /build
EOF

echo -e "${GREEN}✓ Dockerfile 已创建${NC}"

# 构建 Docker 镜像
echo ""
echo -e "${BLUE}构建 Docker 镜像...${NC}"
docker build -t jingo-arch-builder -f /tmp/Dockerfile.jingo-arch . || {
    echo -e "${RED}Docker 镜像构建失败${NC}"
    exit 1
}
echo -e "${GREEN}✓ Docker 镜像构建完成${NC}"

# 在 Docker 容器中构建
echo ""
echo -e "${BLUE}在 Docker 容器中构建 Arch 包...${NC}"
echo ""

docker run --rm \
    -v "$PROJECT_ROOT:/build" \
    -u builder \
    jingo-arch-builder \
    bash -c "
        set -e

        # 配置 git safe directory
        git config --global --add safe.directory /build

        # 运行构建脚本
        cd /build

        # 构建项目
        cmake -B build-linux -G Ninja -DCMAKE_BUILD_TYPE=Release
        ninja -C build-linux -j\$(nproc)

        # 创建源码 tarball
        git archive --format=tar.gz --prefix=jingo-$VERSION/ HEAD > jingo-$VERSION.tar.gz

        # 构建 Arch 包
        makepkg -f --skipinteg

        # 移动到 packages 目录
        mkdir -p packages
        mv -f *.pkg.tar.zst packages/ 2>/dev/null || true

        # 清理
        rm -f jingo-$VERSION.tar.gz

        echo ''
        echo '========================================='
        echo 'Arch 包构建完成！'
        echo '========================================='
        ls -lh packages/*.pkg.tar.zst
    "

# 检查结果
if [ -f "$PROJECT_ROOT/packages/"*.pkg.tar.zst ]; then
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  Arch Linux 包构建成功！${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
    ls -lh "$PROJECT_ROOT/packages/"*.pkg.tar.zst
    echo ""
    echo -e "${BLUE}安装命令:${NC}"
    echo -e "  sudo pacman -U packages/*.pkg.tar.zst"
else
    echo ""
    echo -e "${RED}错误: 包文件未生成${NC}"
    exit 1
fi

# 清理 Dockerfile
rm -f /tmp/Dockerfile.jingo-arch

echo ""
echo -e "${GREEN}完成！${NC}"
