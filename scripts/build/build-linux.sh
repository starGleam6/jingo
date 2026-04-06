#!/bin/bash
# ============================================================================
# JinGo VPN - Linux 构建脚本
# ============================================================================
# 描述：编译 Linux 应用 (在 Linux 上运行)
#
# 功能：编译、部署依赖、打包 DEB/RPM/TGZ
# 依赖：Linux, CMake 3.21+, Qt 6.5+, GCC/Clang
# 版本：1.2.0
# ============================================================================

set -e  # 遇到错误立即退出
set -o pipefail  # 管道中的错误也触发退出

# ============================================================================
# 用户配置 - 修改下面的路径以匹配您的环境
# ============================================================================

# --------------------- Qt 路径配置 ---------------------
# Qt Linux 安装路径 (gcc_64 目录)
# 优先使用环境变量 QT_DIR 或 Qt6_DIR，否则使用默认值
# 本地开发请修改下面的默认路径，或设置环境变量
# 示例: "/opt/Qt/6.8.0/gcc_64" 或 "/home/yourname/Qt/6.8.0/gcc_64"
if [[ -n "${QT_DIR:-}" ]]; then
    : # 使用已设置的 QT_DIR
elif [[ -n "${Qt6_DIR:-}" ]]; then
    QT_DIR="$Qt6_DIR"
else
    QT_DIR="/mnt/dev/Qt/6.10.1/gcc_64"
fi

# --------------------- 构建配置 ---------------------
# 是否使用 Ninja (推荐，更快)
USE_NINJA=true

# --------------------- 脚本初始化 ---------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 错误处理
trap 'on_error $LINENO' ERR

on_error() {
    local line=$1
    print_error "脚本在第 $line 行发生错误"
    exit 1
}

# 加载白标资源复制脚本
if [[ -f "$SCRIPT_DIR/copy-brand-assets.sh" ]]; then
    source "$SCRIPT_DIR/copy-brand-assets.sh"
fi

# --------------------- 应用信息 ---------------------
APP_NAME="JinGo"

# ============================================================================
# 脚本内部变量 (一般不需要修改)
# ============================================================================
# SCRIPT_DIR 已在上面定义
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build-linux"
RELEASE_DIR="$PROJECT_ROOT/release"
CONFIGURATION="Release"
CLEAN_BUILD=false
CREATE_PACKAGE=true
PACKAGE_TYPE="all"  # all/deb/arch/tarball/rpm
DEPLOY_DEPS=true
UPDATE_TRANSLATIONS=false
VERBOSE=false
BRAND_NAME=""

# --------------------- 输出命名 ---------------------
# 获取构建日期 (YYYYMMDD 格式)
BUILD_DATE=$(date +%Y%m%d)

# 生成输出文件名: {brand}-{version}-{date}-{platform}.{ext}
generate_output_name() {
    local version="${1:-1.3.0}"
    local ext="${2:-}"
    local brand="${BRAND_NAME:-${BRAND:-1}}"
    local platform="linux"

    if [[ -n "$ext" ]]; then
        echo "jingo-${brand}-${version}-${BUILD_DATE}-${platform}.${ext}"
    else
        echo "jingo-${brand}-${version}-${BUILD_DATE}-${platform}"
    fi
}

# ============================================================================
# 颜色定义
# ============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# 打印带颜色的消息
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_step() {
    echo -e "\n${CYAN}${BOLD}>>> $1${NC}\n"
}

# 格式化文件大小
format_size() {
    local size=$1
    if [[ $size -ge 1073741824 ]]; then
        echo "$(echo "scale=2; $size/1073741824" | bc)GB"
    elif [[ $size -ge 1048576 ]]; then
        echo "$(echo "scale=2; $size/1048576" | bc)MB"
    elif [[ $size -ge 1024 ]]; then
        echo "$(echo "scale=2; $size/1024" | bc)KB"
    else
        echo "${size}B"
    fi
}

# 显示帮助信息
show_help() {
    cat << EOF
${BOLD}JinGoVPN Linux 构建脚本 v1.3.0${NC}

${CYAN}用法:${NC}
    $0 [选项]

${CYAN}构建选项:${NC}
    -c, --clean          清理构建目录后重新构建
    -d, --debug          Debug 模式构建（不部署、不打包）
    -r, --release        Release 模式构建（默认，自动部署和打包）
    -p, --package [TYPE] 指定打包类型
                         TYPE: all (默认) | deb | arch | tarball | rpm
    --no-package         不打包，只编译

${CYAN}翻译选项:${NC}
    -t, --translate      更新翻译（运行 Python 翻译脚本）

${CYAN}白标定制:${NC}
    -b, --brand NAME     应用白标定制（从 white-labeling/<NAME> 加载配置）

${CYAN}其他选项:${NC}
    -v, --verbose        显示详细输出
    -h, --help           显示此帮助信息

${CYAN}环境变量:${NC}
    Qt6_DIR              Qt 6 安装路径（例如: /opt/Qt/6.10.0/gcc_64）
    CMAKE_PREFIX_PATH    CMake 查找路径

${CYAN}示例:${NC}
    # 默认：编译 Release 版本、部署依赖、打包
    $0

    # 清理后重新编译打包
    $0 --clean

    # 只编译 Debug 版本（不打包）
    $0 --debug

    # 只打包 Debian 包
    $0 --package deb

    # 使用白标定制编译
    $0 --brand 26

${CYAN}输出目录:${NC}
    Debug:   $PROJECT_ROOT/build-linux/bin/
    Release: $PROJECT_ROOT/build-linux/bin/
    Packages: $PROJECT_ROOT/build-linux/

EOF
}

# 解析命令行参数
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--clean)
                CLEAN_BUILD=true
                shift
                ;;
            -d|--debug)
                CONFIGURATION="Debug"
                DEPLOY_DEPS=false
                CREATE_PACKAGE=false
                shift
                ;;
            -r|--release)
                CONFIGURATION="Release"
                shift
                ;;
            -p|--package)
                CREATE_PACKAGE=true
                # 检查是否指定了包类型 (deb/arch/tarball/all)
                if [[ -n "$2" ]] && [[ "$2" != -* ]]; then
                    PACKAGE_TYPE="$2"
                    shift 2
                else
                    PACKAGE_TYPE="all"
                    shift
                fi
                ;;
            --no-package)
                CREATE_PACKAGE=false
                shift
                ;;
            -t|--translate)
                UPDATE_TRANSLATIONS=true
                shift
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -b|--brand)
                if [[ -z "$2" ]] || [[ "$2" == -* ]]; then
                    print_error "--brand 需要指定品牌名称"
                    exit 1
                fi
                BRAND_NAME="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                print_error "未知选项: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# ============================================================================
# 应用白标定制
# ============================================================================
apply_brand_customization() {
    # Linux 平台默认使用品牌 28
    local brand_id="${BRAND_NAME:-${BRAND:-28}}"

    print_step "复制白标资源 (品牌: $brand_id)"

    # 使用 copy-brand-assets.sh 中的函数复制资源
    if type copy_brand_assets &> /dev/null; then
        if ! copy_brand_assets "$brand_id"; then
            print_warning "白标资源复制失败，使用默认资源继续"
        fi
    else
        print_warning "copy_brand_assets 函数未加载，跳过白标资源复制"
    fi
}

# 检查必要工具
check_requirements() {
    print_info "检查构建环境..."

    # 检查 Linux
    if [[ "$OSTYPE" != "linux-gnu"* ]]; then
        print_error "此脚本只能在 Linux 上运行"
        exit 1
    fi

    # 检查 CMake
    if ! command -v cmake &> /dev/null; then
        print_error "CMake 未安装。请安装 CMake"
        print_info "Ubuntu/Debian: sudo apt install cmake"
        print_info "Fedora/RHEL: sudo dnf install cmake"
        exit 1
    fi
    print_success "CMake: $(cmake --version | head -n1)"

    # 检查编译器
    if ! command -v g++ &> /dev/null; then
        print_error "g++ 未安装。请安装 C++ 编译器"
        print_info "Ubuntu/Debian: sudo apt install build-essential"
        print_info "Fedora/RHEL: sudo dnf install gcc-c++"
        exit 1
    fi
    print_success "g++: $(g++ --version | head -n1)"

    # 检查 Qt
    if [ -z "$QT_DIR" ]; then
        # 尝试自动查找 Qt
        QT_PATHS=(
            "/opt/Qt/*/gcc_64"
            "$HOME/Qt/*/gcc_64"
            "/usr/lib/x86_64-linux-gnu/qt6"
            "/usr/lib/qt6"
        )

        for pattern in "${QT_PATHS[@]}"; do
            for path in $pattern; do
                if [ -d "$path" ] && [ -f "$path/bin/qmake" ]; then
                    QT_DIR="$path"
                    print_success "自动找到 Qt: $QT_DIR"
                    break 2
                fi
            done
        done

        if [ -z "$QT_DIR" ]; then
            print_warning "未找到 Qt，请设置 Qt6_DIR 环境变量"
            print_info "例如: export Qt6_DIR=/opt/Qt/6.8.0/gcc_64"
        fi
    else
        if [ ! -d "$QT_DIR" ]; then
            print_error "Qt 目录不存在: $QT_DIR"
            exit 1
        fi
        print_success "Qt: $QT_DIR"
    fi

    # 检查 ninja (可选，但推荐)
    if command -v ninja &> /dev/null; then
        print_success "Ninja: $(ninja --version)"
        USE_NINJA=true
    else
        print_warning "Ninja 未安装，将使用 make（推荐安装 ninja 以提升编译速度）"
        print_info "Ubuntu/Debian: sudo apt install ninja-build"
        print_info "Fedora/RHEL: sudo dnf install ninja-build"
        USE_NINJA=false
    fi

    # 检查 patchelf（依赖部署需要）
    if [ "$DEPLOY_DEPS" = true ] || [ "$CREATE_PACKAGE" = true ]; then
        if command -v patchelf &> /dev/null; then
            print_success "patchelf 可用（修改 RPATH）"
        else
            print_warning "未安装 patchelf，将无法修改库的 RPATH"
            print_info "建议安装: sudo apt install patchelf"
        fi
    fi

    # 检查打包工具（如果需要打包）
    if [ "$CREATE_PACKAGE" = true ]; then
        if command -v dpkg-deb &> /dev/null; then
            print_success "dpkg-deb 可用（可生成 DEB 包）"
        fi
        if command -v rpmbuild &> /dev/null; then
            print_success "rpmbuild 可用（可生成 RPM 包）"
        fi
    fi

    print_success "构建环境检查完成"
}

# ============================================================================
# 更新翻译内容（Python 脚本）
# ============================================================================
update_translations() {
    if [[ "$UPDATE_TRANSLATIONS" != true ]]; then
        return
    fi

    print_step "更新翻译内容"

    local translate_script="$SCRIPT_DIR/translate_ts.py"

    if [[ ! -f "$translate_script" ]]; then
        print_warning "翻译脚本不存在: $translate_script"
        return
    fi

    if ! command -v python3 &> /dev/null; then
        print_warning "python3 未安装，跳过翻译更新"
        return
    fi

    print_info "运行翻译脚本..."
    if python3 "$translate_script" 2>&1; then
        print_success "翻译内容已更新"
    else
        print_warning "翻译脚本执行失败"
    fi
}

# ============================================================================
# 生成翻译文件
# ============================================================================
generate_translations() {
    local translations_dir="$PROJECT_ROOT/resources/translations"
    local lrelease=""

    # 查找 lrelease 工具
    if [[ -n "$QT_DIR" ]] && [[ -x "$QT_DIR/bin/lrelease" ]]; then
        lrelease="$QT_DIR/bin/lrelease"
    elif command -v lrelease &> /dev/null; then
        lrelease="lrelease"
    elif command -v lrelease-qt6 &> /dev/null; then
        lrelease="lrelease-qt6"
    fi

    if [[ -z "$lrelease" ]]; then
        print_warning "lrelease 未找到，跳过翻译生成"
        return
    fi

    if [[ ! -d "$translations_dir" ]]; then
        print_warning "翻译目录不存在: $translations_dir"
        return
    fi

    # 检查是否需要重新生成翻译文件
    local need_regenerate=false
    local ts_count=0
    local qm_count=0
    local languages=()

    for ts_file in "$translations_dir"/*.ts; do
        if [[ -f "$ts_file" ]]; then
            ts_count=$((ts_count + 1))
            local base_name=$(basename "$ts_file" .ts)
            local qm_file="$translations_dir/$base_name.qm"
            local lang=$(echo "$base_name" | sed 's/jingo_//')
            languages+=("$lang")

            # 检查 .qm 是否存在且比 .ts 新
            if [[ ! -f "$qm_file" ]] || [[ "$ts_file" -nt "$qm_file" ]]; then
                need_regenerate=true
            fi
        fi
    done

    if [[ "$need_regenerate" == false ]] && [[ "$CLEAN_BUILD" != true ]]; then
        print_info "翻译文件已是最新，跳过生成"
        return
    fi

    print_step "生成翻译文件 (.qm)"

    # 编译所有 .ts 文件为 .qm 文件
    for ts_file in "$translations_dir"/*.ts; do
        if [[ -f "$ts_file" ]]; then
            local base_name=$(basename "$ts_file" .ts)

            if [[ "$VERBOSE" == true ]]; then
                print_info "编译: $base_name.ts"
                "$lrelease" "$ts_file" -qm "$translations_dir/$base_name.qm" 2>&1 | grep -E "Generated|Ignored" || true
            else
                "$lrelease" "$ts_file" -qm "$translations_dir/$base_name.qm" > /dev/null 2>&1
            fi

            if [[ -f "$translations_dir/$base_name.qm" ]]; then
                qm_count=$((qm_count + 1))
            fi
        fi
    done

    if [[ $qm_count -gt 0 ]]; then
        print_success "生成 $qm_count 个翻译文件"
        local lang_list=$(IFS=','; echo "${languages[*]}")
        print_info "支持语言: $lang_list"
    else
        print_warning "未生成翻译文件"
    fi
}

# 清理构建目录
clean_build_dir() {
    if [ "$CLEAN_BUILD" = true ]; then
        print_info "清理构建目录: $BUILD_DIR"
        rm -rf "$BUILD_DIR"
        print_success "构建目录已清理"
    fi
}

# 配置项目
configure_project() {
    print_info "配置 CMake 项目..."
    print_info "  项目目录: $PROJECT_ROOT"
    print_info "  构建目录: $BUILD_DIR"
    print_info "  配置: $CONFIGURATION"

    mkdir -p "$BUILD_DIR"

    CMAKE_ARGS=(
        -S "$PROJECT_ROOT"
        -B "$BUILD_DIR"
        -DCMAKE_BUILD_TYPE="$CONFIGURATION"
    )

    # 使用 Ninja 生成器
    if [ "$USE_NINJA" = true ]; then
        CMAKE_ARGS+=(-G Ninja)
    fi

    # 设置 Qt 路径
    if [ -n "$QT_DIR" ]; then
        CMAKE_ARGS+=(-DCMAKE_PREFIX_PATH="$QT_DIR")
    fi

    # 如果需要打包，启用 CPack
    if [ "$CREATE_PACKAGE" = true ]; then
        CMAKE_ARGS+=(-DENABLE_PACKAGING=ON)
    fi

    # 安全功能开关
    if [ "${ENABLE_LICENSE_CHECK:-}" = "ON" ]; then
        CMAKE_ARGS+=(-DENABLE_LICENSE_CHECK=ON)
        print_info "CMake: 启用授权验证 (ENABLE_LICENSE_CHECK=ON)"
    fi
    if [ "${ENABLE_CONFIG_SIGNATURE_VERIFY:-}" = "ON" ]; then
        CMAKE_ARGS+=(-DENABLE_CONFIG_SIGNATURE_VERIFY=ON)
        print_info "CMake: 启用配置签名验证 (ENABLE_CONFIG_SIGNATURE_VERIFY=ON)"
    fi

    cmake "${CMAKE_ARGS[@]}"

    print_success "CMake 配置完成"
}

# 编译项目
build_project() {
    print_step "编译 $CONFIGURATION 版本"

    cd "$BUILD_DIR"

    # 获取 CPU 核心数
    NPROC=$(nproc 2>/dev/null || echo 4)
    print_info "使用 $NPROC 个并行任务编译"

    # 开始计时
    local start_time=$(date +%s)

    # 编译
    echo ""
    local build_log="$BUILD_DIR/build.log"
    cmake --build . --config "$CONFIGURATION" -j"$NPROC" 2>&1 | tee "$build_log"
    local build_result=${PIPESTATUS[0]}

    # 检查编译结果
    if [[ $build_result -ne 0 ]] || grep -q "error:" "$build_log"; then
        print_error "编译失败 (exit code: $build_result)"
        echo ""
        echo "=== 错误信息 ==="
        grep -i "error:" "$build_log" | head -30
        echo ""
        echo "=== 最后 50 行日志 ==="
        tail -50 "$build_log"
        exit 1
    fi

    # 计算编译时间
    local end_time=$(date +%s)
    local build_time=$((end_time - start_time))

    # 检查编译结果
    BIN_DIR="$BUILD_DIR/bin"
    APP_PATH="$BIN_DIR/$APP_NAME"

    if [[ ! -f "$APP_PATH" ]]; then
        print_error "编译失败: 主可执行文件不存在"
        print_error "期望路径: $APP_PATH"
        ls -la "$BIN_DIR/" 2>/dev/null || true
        exit 1
    fi

    echo ""
    print_success "编译成功！耗时 ${build_time} 秒"

    # 显示应用大小
    local app_size=$(stat -c%s "$APP_PATH" 2>/dev/null || echo "0")
    print_info "应用大小: $(format_size $app_size)"

    # 显示架构
    local arch=$(file "$APP_PATH" | grep -o "x86-64\|x86_64\|aarch64\|ARM" | head -1 || echo "unknown")
    print_info "架构: $arch"
}

# 部署依赖
deploy_dependencies() {
    if [ "$DEPLOY_DEPS" = false ]; then
        return
    fi

    BIN_DIR="$BUILD_DIR/bin"
    LIB_DIR="$BIN_DIR/lib"
    PLUGINS_DIR="$BIN_DIR/plugins"
    APP_PATH="$BIN_DIR/$APP_NAME"

    if [ ! -f "$APP_PATH" ]; then
        print_error "未找到可执行文件: $APP_PATH"
        exit 1
    fi

    # 检查是否已经部署过（有足够多的 Qt 库）
    local qt_lib_count=$(find "$LIB_DIR" -name "libQt6*.so*" -type f 2>/dev/null | wc -l)
    if [ "$qt_lib_count" -gt 20 ] && [ "$CLEAN_BUILD" = false ]; then
        print_info "依赖库已部署 ($qt_lib_count 个 Qt 库)，跳过"
        return
    fi

    print_info "部署 Qt 依赖库和插件..."
    mkdir -p "$LIB_DIR" "$PLUGINS_DIR"

    # 递归收集所有依赖库
    print_info "递归收集依赖库..."

    local processed_libs=$(mktemp)
    local pending_files=$(mktemp)

    echo "$APP_PATH" > "$pending_files"

    while IFS= read -r file; do
        [ -z "$file" ] && continue

        # 标记为已处理
        echo "$file" >> "$processed_libs"

        # 提取依赖
        ldd "$file" 2>/dev/null | grep "=>" | while IFS= read -r line; do
            lib_path=$(echo "$line" | awk '{print $3}')
            [ -z "$lib_path" ] || [ ! -f "$lib_path" ] && continue

            # 只收集 Qt6 和 OpenSSL 库
            if ! echo "$lib_path" | grep -qE "(Qt6|libssl|libcrypto|libicu)"; then
                continue
            fi

            # 跳过系统 Qt 库（优先使用我们的 Qt 目录）
            if echo "$lib_path" | grep -qE "^/(lib|usr/lib)/.*Qt6"; then
                # 系统 Qt 库，尝试从我们的 Qt 目录找对应的库
                lib_name=$(basename "$lib_path")
                if [ -n "$QT_DIR" ] && [ -f "$QT_DIR/lib/$lib_name" ]; then
                    lib_path="$QT_DIR/lib/$lib_name"
                else
                    # Qt 目录中没有，跳过系统库
                    continue
                fi
            fi

            # 跳过已处理
            if grep -qxF "$lib_path" "$processed_libs" 2>/dev/null; then
                continue
            fi

            # 添加到待处理列表
            echo "$lib_path" >> "$pending_files"

            # 拷贝到 lib 目录
            lib_name=$(basename "$lib_path")
            if [ ! -f "$LIB_DIR/$lib_name" ]; then
                cp "$lib_path" "$LIB_DIR/" 2>/dev/null || true
                [[ "$VERBOSE" == true ]] && print_info "  $lib_name" || true
            fi
        done
    done < <(sort -u "$pending_files")

    # 创建符号链接
    (cd "$LIB_DIR" && \
        for lib in libQt6*.so.6.*; do
            [ -f "$lib" ] || continue
            base="${lib%.??.?}"
            [ ! -e "$base" ] && ln -sf "$lib" "$base"
        done
    )

    # QML 运行时和插件需要的额外库（ldd 检测不到的动态加载库）
    if [ -n "$QT_DIR" ]; then
        print_info "拷贝 QML 和插件运行时库..."
        # QML 基础库
        for extra_lib in libQt6QmlWorkerScript.so.6 libQt6QmlModels.so.6 libQt6QmlMeta.so.6 libQt6LabsSettings.so.6; do
            if [ -f "$QT_DIR/lib/$extra_lib" ] && [ ! -f "$LIB_DIR/$extra_lib" ]; then
                cp "$QT_DIR/lib/$extra_lib"* "$LIB_DIR/" 2>/dev/null || true
            fi
        done

        # QuickControls2 相关库（QML 模块需要）
        for extra_lib in libQt6QuickControls2*.so.6 libQt6QuickLayouts.so.6 libQt6QuickTemplates2.so.6; do
            if [ -f "$QT_DIR/lib/$extra_lib" ] && [ ! -f "$LIB_DIR/$(basename $extra_lib)" ]; then
                cp "$QT_DIR/lib/$extra_lib"* "$LIB_DIR/" 2>/dev/null || true
            fi
        done

        # 平台集成库
        for extra_lib in libQt6XcbQpa.so.6 libQt6WaylandClient.so.6 libQt6WaylandEglClientHwIntegration.so.6; do
            if [ -f "$QT_DIR/lib/$extra_lib" ] && [ ! -f "$LIB_DIR/$extra_lib" ]; then
                cp "$QT_DIR/lib/$extra_lib"* "$LIB_DIR/" 2>/dev/null || true
            fi
        done

        # OpenGL/图形库
        for extra_lib in libQt6OpenGL.so.6 libQt6OpenGLWidgets.so.6 libQt6Svg.so.6; do
            if [ -f "$QT_DIR/lib/$extra_lib" ] && [ ! -f "$LIB_DIR/$extra_lib" ]; then
                cp "$QT_DIR/lib/$extra_lib"* "$LIB_DIR/" 2>/dev/null || true
            fi
        done

        # EGL 支持库（如果存在）
        for extra_lib in libQt6EglFSDeviceIntegration.so.6 libQt6EglFsKmsSupport.so.6; do
            if [ -f "$QT_DIR/lib/$extra_lib" ] && [ ! -f "$LIB_DIR/$extra_lib" ]; then
                cp "$QT_DIR/lib/$extra_lib"* "$LIB_DIR/" 2>/dev/null || true
            fi
        done
    fi

    # 修改所有 Qt 库的 RPATH，让它们互相查找同目录的库
    if command -v patchelf &> /dev/null; then
        print_info "修改 Qt 库 RPATH..."
        find "$LIB_DIR" -name "libQt6*.so*" -type f | while read -r lib; do
            # 设置 RPATH 为 $ORIGIN（同目录查找）
            patchelf --set-rpath '$ORIGIN' "$lib" 2>/dev/null || true
        done
        # 注意：主可执行文件的 RPATH 由 CMakeLists.txt 设置，不在此修改
    fi

    local lib_count=$(find "$LIB_DIR" -name "*.so*" -type f | wc -l)
    print_success "收集了 $lib_count 个依赖库"

    rm -f "$processed_libs" "$pending_files"

    # 拷贝 Qt 插件
    if [ -n "$QT_DIR" ]; then
        print_info "拷贝 Qt 插件..."

        # 平台插件
        mkdir -p "$PLUGINS_DIR/platforms"
        for plugin in libqxcb.so libqwayland-egl.so libqwayland-generic.so libqminimal.so; do
            [ -f "$QT_DIR/plugins/platforms/$plugin" ] && \
                cp "$QT_DIR/plugins/platforms/$plugin" "$PLUGINS_DIR/platforms/"
        done

        # 图像格式
        mkdir -p "$PLUGINS_DIR/imageformats"
        for plugin in libqsvg.so libqjpeg.so libqico.so libqgif.so libqpng.so; do
            [ -f "$QT_DIR/plugins/imageformats/$plugin" ] && \
                cp "$QT_DIR/plugins/imageformats/$plugin" "$PLUGINS_DIR/imageformats/"
        done

        # 图标引擎
        mkdir -p "$PLUGINS_DIR/iconengines"
        [ -f "$QT_DIR/plugins/iconengines/libqsvgicon.so" ] && \
            cp "$QT_DIR/plugins/iconengines/libqsvgicon.so" "$PLUGINS_DIR/iconengines/"

        # 平台主题
        mkdir -p "$PLUGINS_DIR/platformthemes"
        for plugin in libqgtk3.so libqxdgdesktopportal.so; do
            [ -f "$QT_DIR/plugins/platformthemes/$plugin" ] && \
                cp "$QT_DIR/plugins/platformthemes/$plugin" "$PLUGINS_DIR/platformthemes/"
        done

        # SQL 驱动（必需）
        mkdir -p "$PLUGINS_DIR/sqldrivers"
        [ -f "$QT_DIR/plugins/sqldrivers/libqsqlite.so" ] && \
            cp "$QT_DIR/plugins/sqldrivers/libqsqlite.so" "$PLUGINS_DIR/sqldrivers/"

        # TLS 后端（必需）
        mkdir -p "$PLUGINS_DIR/tls"
        [ -f "$QT_DIR/plugins/tls/libqopensslbackend.so" ] && \
            cp "$QT_DIR/plugins/tls/libqopensslbackend.so" "$PLUGINS_DIR/tls/"

        # XCB GLX 集成插件（OpenGL 支持）
        if [ -d "$QT_DIR/plugins/xcbglintegrations" ]; then
            mkdir -p "$PLUGINS_DIR/xcbglintegrations"
            cp -r "$QT_DIR/plugins/xcbglintegrations"/* "$PLUGINS_DIR/xcbglintegrations/" 2>/dev/null || true
        fi

        # EGL 设备集成插件（如果存在）
        if [ -d "$QT_DIR/plugins/egldeviceintegrations" ]; then
            mkdir -p "$PLUGINS_DIR/egldeviceintegrations"
            cp -r "$QT_DIR/plugins/egldeviceintegrations"/* "$PLUGINS_DIR/egldeviceintegrations/" 2>/dev/null || true
        fi

        # QML 模块（必需）
        if [ -d "$QT_DIR/qml" ]; then
            print_info "拷贝 QML 模块..."
            QML_DIR="$BIN_DIR/qml"
            mkdir -p "$QML_DIR"

            # 拷贝必需的 QML 模块
            for module in QtQuick QtQuick.2 QtQml QtQuick/Controls QtQuick/Layouts QtQuick/Window QtQuick/Templates; do
                if [ -d "$QT_DIR/qml/$module" ]; then
                    mkdir -p "$QML_DIR/$module"
                    cp -r "$QT_DIR/qml/$module"/* "$QML_DIR/$module/" 2>/dev/null || true
                fi
            done
        fi

        # 修改插件 RPATH，让它们使用打包的 Qt 库而非系统库
        if command -v patchelf &> /dev/null; then
            print_info "修改插件 RPATH..."
            find "$PLUGINS_DIR" -name "*.so" | while read -r plugin; do
                # 设置 RPATH 支持两种路径：
                # 1. 构建目录：plugins/platforms/ -> ../../lib
                # 2. 安装目录：/usr/lib/jingo/plugins/platforms/ -> ../../
                patchelf --set-rpath '$ORIGIN/../../lib:$ORIGIN/../../' "$plugin" 2>/dev/null || true
            done

            # 修改 QML 插件 RPATH（根据深度分别设置）
            if [ -d "$BIN_DIR/qml" ]; then
                print_info "修改 QML 插件 RPATH..."

                # 1 级深度: qml/QtQml/*.so -> $ORIGIN/../..
                find "$BIN_DIR/qml" -maxdepth 2 -mindepth 2 -name "*.so" -type f | while read -r plugin; do
                    patchelf --set-rpath '$ORIGIN/../..' "$plugin" 2>/dev/null || true
                done

                # 2 级深度: qml/QtQuick/Controls/*.so -> $ORIGIN/../../..
                find "$BIN_DIR/qml" -maxdepth 3 -mindepth 3 -name "*.so" -type f | while read -r plugin; do
                    patchelf --set-rpath '$ORIGIN/../../..' "$plugin" 2>/dev/null || true
                done

                # 3 级深度: qml/QtQuick/Controls/Fusion/*.so -> $ORIGIN/../../../..
                find "$BIN_DIR/qml" -maxdepth 4 -mindepth 4 -name "*.so" -type f | while read -r plugin; do
                    patchelf --set-rpath '$ORIGIN/../../../..' "$plugin" 2>/dev/null || true
                done

                # 4 级及更深: qml/a/b/c/d/*.so -> $ORIGIN/../../../../..
                find "$BIN_DIR/qml" -mindepth 5 -name "*.so" -type f | while read -r plugin; do
                    patchelf --set-rpath '$ORIGIN/../../../../..' "$plugin" 2>/dev/null || true
                done
            fi
        else
            print_warning "未找到 patchelf，插件可能使用系统 Qt 库"
        fi

        # 收集插件依赖的库（如 xcb-cursor）
        print_info "收集插件依赖..."
        find "$PLUGINS_DIR" -name "*.so" | while read -r plugin; do
            ldd "$plugin" 2>/dev/null | grep "=>" | awk '{print $3}' | while read -r lib; do
                [ -z "$lib" ] || [ ! -f "$lib" ] && continue
                # 只收集 xcb、wayland 相关库
                if echo "$lib" | grep -qE "(xcb|wayland|xkb)"; then
                    lib_name=$(basename "$lib")
                    [ ! -f "$LIB_DIR/$lib_name" ] && cp "$lib" "$LIB_DIR/" 2>/dev/null
                fi
            done
        done

        local plugin_count=$(find "$PLUGINS_DIR" -name "*.so" | wc -l)
        print_success "拷贝了 $plugin_count 个插件"
    fi

    # 创建启动脚本
    cat > "$BIN_DIR/jingo" << 'EOF'
#!/bin/bash
# JinGo VPN 启动脚本
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LD_LIBRARY_PATH="${SCRIPT_DIR}/lib:${LD_LIBRARY_PATH}"
export QT_PLUGIN_PATH="${SCRIPT_DIR}/plugins"
export QT_QPA_PLATFORM_PLUGIN_PATH="${SCRIPT_DIR}/plugins/platforms"
exec "${SCRIPT_DIR}/JinGo" "$@"
EOF
    chmod +x "$BIN_DIR/jingo"

    print_success "依赖部署完成"
}

# 创建安装包
create_packages() {
    if [ "$CREATE_PACKAGE" = false ]; then
        return
    fi

    # 打包前确保依赖已部署
    if [ "$DEPLOY_DEPS" = false ]; then
        print_warning "打包需要先部署依赖，自动执行部署..."
        DEPLOY_DEPS=true
        deploy_dependencies
    fi

    print_step "创建安装包"

    # 直接输出到 release 目录
    mkdir -p "$RELEASE_DIR"

    cd "$BUILD_DIR"

    # 生成 DEB 包 (Debian/Ubuntu)
    if [ "$PACKAGE_TYPE" = "all" ] || [ "$PACKAGE_TYPE" = "deb" ]; then
        print_info "生成 DEB 包..."
        cpack -G DEB

        DEB_FILE=$(find . -name "*.deb" -type f | head -n 1)
        if [ -n "$DEB_FILE" ]; then
            DEB_SIZE=$(du -h "$DEB_FILE" | cut -f1)
            mv "$DEB_FILE" "$RELEASE_DIR/"
            print_success "DEB 包: $(basename $DEB_FILE) ($DEB_SIZE)"
        fi
    fi

    # 生成 TGZ 包 (通用)
    if [ "$PACKAGE_TYPE" = "all" ] || [ "$PACKAGE_TYPE" = "tarball" ]; then
        print_info "生成 TGZ 包..."
        cpack -G TGZ

        TGZ_FILE=$(find . -name "*.tar.gz" -type f | head -n 1)
        if [ -n "$TGZ_FILE" ]; then
            TGZ_SIZE=$(du -h "$TGZ_FILE" | cut -f1)
            mv "$TGZ_FILE" "$RELEASE_DIR/"
            print_success "TGZ 包: $(basename $TGZ_FILE) ($TGZ_SIZE)"
        fi
    fi

    # 生成 Arch Linux 包
    if [ "$PACKAGE_TYPE" = "all" ] || [ "$PACKAGE_TYPE" = "arch" ]; then
        if command -v makepkg &> /dev/null; then
            print_info "生成 Arch Linux 包..."

            cd "$PROJECT_ROOT"

            # 创建源码 tarball (makepkg 需要)
            VERSION=$(grep "set(PROJECT_VERSION" CMakeLists.txt | sed 's/.*"\(.*\)".*/\1/' || echo "1.3.0")
            TARBALL_NAME="jingo-$VERSION.tar.gz"

            if command -v git &> /dev/null && git rev-parse --git-dir > /dev/null 2>&1; then
                git archive --format=tar.gz --prefix="jingo-$VERSION/" HEAD > "$TARBALL_NAME"
            else
                tar czf "$TARBALL_NAME" --transform "s,^,jingo-$VERSION/," --exclude=build-* --exclude=.git * 2>/dev/null
            fi

            # 运行 makepkg
            makepkg -f --skipinteg 2>&1 | grep -v "^==> " || true

            # 移动生成的包
            PKG_FILE=$(find . -name "jingo-*.pkg.tar.zst" -type f | head -n 1)
            if [ -n "$PKG_FILE" ]; then
                PKG_SIZE=$(du -h "$PKG_FILE" | cut -f1)
                mv "$PKG_FILE" "$RELEASE_DIR/"
                print_success "Arch 包: $(basename $PKG_FILE) ($PKG_SIZE)"
            fi

            # 清理临时文件
            rm -f "$TARBALL_NAME" 2>/dev/null
            rm -rf pkg/ src/ 2>/dev/null
        else
            print_warning "跳过 Arch 包（未安装 makepkg）"
        fi
    fi

    # 生成 RPM 包 (可选)
    if [ "$PACKAGE_TYPE" = "rpm" ]; then
        if command -v rpmbuild &> /dev/null; then
            print_info "生成 RPM 包..."
            cd "$BUILD_DIR"
            cpack -G RPM

            RPM_FILE=$(find . -name "*.rpm" -type f | head -n 1)
            if [ -n "$RPM_FILE" ]; then
                RPM_SIZE=$(du -h "$RPM_FILE" | cut -f1)
                mv "$RPM_FILE" "$RELEASE_DIR/"
                print_success "RPM 包: $(basename $RPM_FILE) ($RPM_SIZE)"
            fi
        else
            print_warning "跳过 RPM 包（未安装 rpmbuild）"
        fi
    fi

    # 生成 SHA256 校验和
    cd "$RELEASE_DIR"
    if ls *.deb *.tar.gz *.pkg.tar.zst 2>/dev/null | grep -q .; then
        print_info "生成 SHA256 校验和..."
        sha256sum *.deb *.tar.gz *.pkg.tar.zst 2>/dev/null > SHA256SUMS || true
        print_success "校验和已生成: SHA256SUMS"
    fi

    # 显示生成的所有包
    echo ""
    print_success "安装包创建完成！"
    print_info "包文件位置: $RELEASE_DIR"
    echo ""
    ls -lh "$RELEASE_DIR"/ 2>/dev/null || true

    cd "$PROJECT_ROOT"
}

# 显示验证信息
verify_app() {
    print_step "验证应用"

    BIN_DIR="$BUILD_DIR/bin"
    APP_PATH="$BIN_DIR/$APP_NAME"

    if [[ ! -f "$APP_PATH" ]]; then
        print_error "未找到可执行文件"
        return
    fi

    # 显示文件大小
    local app_size=$(stat -c%s "$APP_PATH" 2>/dev/null || echo "0")
    print_success "可执行文件大小: $(format_size $app_size)"

    # 显示架构
    local arch=$(file "$APP_PATH" | grep -o "x86-64\|x86_64\|aarch64\|ARM" | head -1 || echo "unknown")
    print_success "架构: $arch"

    # 显示依赖
    print_info "Qt 依赖库:"
    if ldd "$APP_PATH" 2>/dev/null | grep -q "Qt6"; then
        ldd "$APP_PATH" | grep "Qt6" | awk '{print "  " $1 " => " $3}' | head -10
        local qt_count=$(ldd "$APP_PATH" | grep "Qt6" | wc -l)
        print_info "共找到 $qt_count 个 Qt6 依赖"
    else
        print_warning "未找到 Qt6 依赖"
    fi

    # 检查是否部署了依赖
    if [[ -d "$BIN_DIR/lib" ]]; then
        local lib_count=$(ls -1 "$BIN_DIR/lib" 2>/dev/null | wc -l)
        print_success "已部署 $lib_count 个依赖库"
    else
        print_info "未部署依赖库（使用系统库）"
    fi

    if [[ -d "$BIN_DIR/plugins" ]]; then
        local plugin_count=$(find "$BIN_DIR/plugins" -name "*.so" 2>/dev/null | wc -l)
        print_success "已部署 $plugin_count 个 Qt 插件"
    else
        print_info "未部署 Qt 插件"
    fi

    # 检查可执行权限
    if [[ -x "$APP_PATH" ]]; then
        print_success "可执行权限: 正常"
    else
        print_warning "可执行权限: 缺失"
    fi
}

# ============================================================================
# 复制到 release 目录（仅在非打包模式下使用）
# ============================================================================
copy_to_release() {
    # 打包模式已在 create_packages 中处理，跳过
    if [[ "$CREATE_PACKAGE" == true ]]; then
        return
    fi

    if [[ "$CONFIGURATION" != "Release" ]]; then
        return
    fi

    print_info "复制构建产物到 release 目录..."

    mkdir -p "$RELEASE_DIR"

    BIN_DIR="$BUILD_DIR/bin"
    APP_PATH="$BIN_DIR/$APP_NAME"

    if [[ -f "$APP_PATH" ]]; then
        local version="1.3.0"
        local tar_name=$(generate_output_name "$version" "tar.gz")
        print_info "创建压缩包: $tar_name"

        (cd "$BUILD_DIR" && tar -czf "$RELEASE_DIR/$tar_name" bin)

        if [[ -f "$RELEASE_DIR/$tar_name" ]]; then
            print_success "已创建: $RELEASE_DIR/$tar_name"
        fi
    fi
}

# ============================================================================
# 显示构建摘要
# ============================================================================
show_summary() {
    BIN_DIR="$BUILD_DIR/bin"
    APP_PATH="$BIN_DIR/$APP_NAME"

    echo ""
    echo -e "${GREEN}${BOLD}=================================================="
    echo "              构建完成！"
    echo "==================================================${NC}"
    echo ""

    if [[ -n "$APP_PATH" ]] && [[ -f "$APP_PATH" ]]; then
        echo -e "${CYAN}应用路径:${NC}"
        echo "  $APP_PATH"
        echo ""

        if [[ "$DEPLOY_DEPS" == true ]] && [[ -f "$BIN_DIR/jingo" ]]; then
            echo -e "${CYAN}运行应用（已部署依赖）:${NC}"
            echo "  $BIN_DIR/jingo"
        else
            echo -e "${CYAN}运行应用:${NC}"
            echo "  $APP_PATH"
            echo ""
            echo -e "${CYAN}部署依赖（如需要）:${NC}"
            echo "  $0 --deploy"
        fi

        if [[ "$CREATE_PACKAGE" == true ]]; then
            echo ""
            echo -e "${CYAN}安装包位置:${NC}"
            echo "  $RELEASE_DIR"
            ls -1 "$RELEASE_DIR"/*.deb "$RELEASE_DIR"/*.tar.gz "$RELEASE_DIR"/*.pkg.tar.zst 2>/dev/null | sed 's/^/  /' || echo "  未找到安装包"
        fi
    fi
    echo ""
}

# 主函数
main() {
    echo ""
    echo -e "${BOLD}=================================================="
    echo "      JinGoVPN Linux 构建脚本 v1.3.0"
    echo "==================================================${NC}"
    echo ""

    parse_args "$@"

    # 记录开始时间
    local start_time=$(date +%s)

    print_info "构建配置: $CONFIGURATION"
    if [[ -n "$BRAND_NAME" ]]; then
        print_info "品牌定制: $BRAND_NAME"
    fi
    print_info "时间: $(date '+%Y-%m-%d %H:%M:%S')"
    if [[ "$VERBOSE" == true ]]; then
        print_info "详细模式: 开启"
    fi
    if [[ "$UPDATE_TRANSLATIONS" == true ]]; then
        print_info "翻译更新: 开启"
    fi
    if [[ "$CREATE_PACKAGE" == true ]]; then
        print_info "创建安装包: 开启"
    fi
    if [[ "$DEPLOY_DEPS" == true ]]; then
        print_info "部署依赖: 开启"
    fi

    # 应用白标定制 (如果指定了品牌)
    apply_brand_customization

    check_requirements
    clean_build_dir
    update_translations
    generate_translations
    configure_project
    build_project
    deploy_dependencies
    verify_app
    create_packages
    copy_to_release
    show_summary

    # 显示总耗时
    local end_time=$(date +%s)
    local total_time=$((end_time - start_time))
    print_info "总耗时: ${total_time} 秒"

    echo ""
}

# 执行主函数
main "$@"
