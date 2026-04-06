#!/bin/bash
#
# JinGo VPN 启动器
# 自动处理 X11 授权和权限提升
#

# 查找 JinGo 可执行文件
JINGO_BIN=""

# 优先查找系统安装的版本
for path in /usr/bin/JinGo /usr/local/bin/JinGo; do
    if [ -x "$path" ]; then
        JINGO_BIN="$path"
        break
    fi
done

# 如果没找到，尝试构建目录
if [ -z "$JINGO_BIN" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    BUILD_BIN="$SCRIPT_DIR/../../build-linux/bin/JinGo"
    if [ -x "$BUILD_BIN" ]; then
        JINGO_BIN="$BUILD_BIN"
    fi
fi

# 还是没找到就报错
if [ -z "$JINGO_BIN" ]; then
    echo "错误: 找不到 JinGo 可执行文件"
    echo "请确保 JinGo 已正确安装"
    exit 1
fi

# 允许本地 X11 连接
xhost +local: 2>/dev/null || true

# 使用 pkexec 提升权限并保留环境变量
exec pkexec env \
    DISPLAY="$DISPLAY" \
    XAUTHORITY="$XAUTHORITY" \
    HOME="$HOME" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    "$JINGO_BIN" "$@"
