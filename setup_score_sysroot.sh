#!/usr/bin/env bash
# setup_score_sysroot.sh — Build score::mw::com and install headers + fat static library
# to a score_mw_sysroot directory for use by standalone CMake applications.
#
# Usage:
#   ./setup_score_sysroot.sh [COMMUNICATION_REPO_DIR [SCORE_MW_SYSROOT_DIR]] [--cpu=arm64]
#
# Defaults:
#   COMMUNICATION_REPO_DIR  = ../score/communication  (sibling of this repo)
#   SCORE_MW_SYSROOT_DIR    = ./build/score_mw_sysroot        (x86)
#                           = ./build/score_mw_sysroot_arm64  (ARM64)
#
# Examples:
#   ./setup_score_sysroot.sh                          # x86 build, auto-clone repo
#   ./setup_score_sysroot.sh /path/to/communication   # x86 build, existing repo
#   ./setup_score_sysroot.sh /path/to/communication --cpu=arm64  # ARM64 cross-build


set -euo pipefail


# Print cross-compilation hint if BAZEL_CPU is not set (after parsing args)
if [[ -z "${BAZEL_CPU:-}" ]]; then
    echo ""
    echo "Hint: For cross-compilation, use the --cpu flag when running this script and when building with Bazel."
    echo "      Example: ./setup_score_sysroot.sh --cpu=arm64"
    echo "      For CMake cross-compilation, you may need to specify a toolchain file or set environment variables depending on your toolchain and target platform."
    echo ""
fi


# Parse --cpu argument if present, default to arm64 if not set
BAZEL_CPU=""
OTHER_ARGS=()
for arg in "$@"; do
    if [[ "$arg" == --cpu=* ]]; then
        BAZEL_CPU="--cpu=arm64"  # This line is modified to always use aarch64
    else
        OTHER_ARGS+=("$arg")
    fi
done

# Remove --cpu from positional parameters
set -- "${OTHER_ARGS[@]}"

# Set ARM64 platform flags only when --cpu=arm64 was requested
if [[ -n "$BAZEL_CPU" ]]; then
    BAZEL_CPU="--cpu=arm64"
    BAZEL_PLAT="--platforms=//platforms:rpi5_aarch64"
    BAZEL_CROSSTOOL=""
    BAZEL_COMPILER=""
else
    BAZEL_PLAT=""
    BAZEL_CROSSTOOL=""
    BAZEL_COMPILER=""
fi


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${1:-}" ]]; then
    echo "ERROR: COMMUNICATION_REPO_DIR is required."
    echo "Usage: $0 <path/to/eclipse-score/communication> [SCORE_MW_SYSROOT_DIR] [--cpu=arm64]"
    exit 1
fi
COMM_REPO="$1"

if [[ ! -d "${COMM_REPO}/.git" ]]; then
    echo "ERROR: '${COMM_REPO}' is not a git repository."
    echo "Please clone eclipse-score/communication first:"
    echo "  git clone https://github.com/eclipse-score/communication ${COMM_REPO}"
    exit 1
fi

# Set CPU suffix for sysroot directories
if [[ -n "$BAZEL_CPU" ]]; then
    CPU_SUFFIX="_arm64"
else
    CPU_SUFFIX=""
fi

# Use CPU-specific local sysroot directory inside build folder
BUILD_DIR="${SCRIPT_DIR}/build"
mkdir -p "${BUILD_DIR}"
SCORE_MW_SYSROOT="${2:-${BUILD_DIR}/score_mw_sysroot${CPU_SUFFIX}}"

# Always use the actual Bazel output directory for the current config
# bazel info bazel-bin doesn't reliably reflect --platforms, so follow the symlink directly
get_bazel_out_dir() {
    readlink -f "${COMM_REPO}/bazel-bin"
}

echo "==> Using communication repository at ${COMM_REPO}"
echo "==> Sysroot target     : ${SCORE_MW_SYSROOT}"


cd "${COMM_REPO}"

# Clean Bazel outputs before cross-compiling to avoid mixing architectures

echo "==> Cleaning previous Bazel build outputs (bazel clean) ..."
if [[ -n "$BAZEL_CPU" ]]; then
    bazel clean $BAZEL_CPU $BAZEL_PLAT
    BAZEL_CONFIG="$BAZEL_CPU $BAZEL_PLAT"
else
    bazel clean
    BAZEL_CONFIG=""
fi

# ---------------------------------------------------------------------------
# 1. Build //score/mw/com — compiles all middleware object files into bazel-bin
# ---------------------------------------------------------------------------

echo "==> Building //score/mw/com ..."
bazel build $BAZEL_CONFIG //score/mw/com

echo "==> Building transitive C++ deps (score_baselibs, plumbing) ..."
# These targets are not compiled as part of //score/mw/com alone.
# They provide symbols referenced by objects in the fat archive.
# Note: @score_logging is a transitive dep — not directly accessible in Bzlmod.
# Its objects are already built as part of //score/mw/com above.
bazel build $BAZEL_CONFIG \
    @score_baselibs//score/mw/log/detail:thread_local_guard \
    @score_baselibs//score/mw/log/detail:log_recorder_factory \
    @score_baselibs//score/mw/log/detail:empty_recorder_factory \
    @score_baselibs//score/mw/log/detail:console_only_recorder_factory \
    @score_baselibs//score/memory/shared:shared_memory_factory_impl \
    @score_baselibs//score/memory/shared:shared_memory_factory \
    //score/mw/com/impl/plumbing:proxy_binding_factory_impl \
    //score/mw/com/impl/plumbing:skeleton_binding_factory_impl \
    //score/mw/com/impl/bindings/lola:path_builder \
    //score/mw/com/impl/bindings/lola:shm_path_builder \
    //score/mw/com/impl/bindings/lola:partial_restart_path_builder


# ---------------------------------------------------------------------------
# 2. Collect middleware .pic.o files and pack into a fat static library.
#    We use all .pic.o under bazel-bin, excluding examples and tests.
#    Also, verify architecture when cross-compiling.
# ---------------------------------------------------------------------------
LIB_DIR="${SCORE_MW_SYSROOT}/lib"
mkdir -p "${LIB_DIR}"

FAT_ARCHIVE="${LIB_DIR}/libmw_com.a"
echo "==> Collecting object files ..."

OBJ_LIST="$(mktemp)"
BAZEL_OUT_DIR=$(get_bazel_out_dir)
BAZEL_CACHE_DIR=$(dirname "$BAZEL_OUT_DIR")/execroot/_main

# Collect objects from bazel-bin (main + external repos)
# ARM64 cross-toolchain produces .o; x86 Bazel produces .pic.o
find -L "$BAZEL_OUT_DIR" \( -name "*.pic.o" -o -name "*.o" \) \
    ! -path "*/example/*" \
    ! -path "*/test/*"    \
    ! -path "*/tests/*"   \
    ! -name "*_test.pic.o" \
    ! -name "*_test.o" \
    > "${OBJ_LIST}"

OBJ_COUNT=$(wc -l < "${OBJ_LIST}")
echo "    Found ${OBJ_COUNT} object files"

# Check architecture of first object file if cross-compiling
if [[ -n "$BAZEL_CPU" ]]; then
    FIRST_OBJ=$(head -n 1 "${OBJ_LIST}")
    if [[ -n "$FIRST_OBJ" ]]; then
        ARCH_INFO=$(file "$FIRST_OBJ")
        echo "==> Verifying object file architecture: $ARCH_INFO"
        if ! echo "$ARCH_INFO" | grep -qi 'aarch64\|arm'; then
            echo "ERROR: Bazel did not produce aarch64 object files."
            echo "       Check your Bazel toolchain and configuration for ARM cross-compilation."
            echo "       Aborting sysroot creation."
            exit 1
        fi
    fi
fi

echo "==> Building ${FAT_ARCHIVE} ..."
# Read list into array to pass to ar (handles spaces in paths)
mapfile -t OBJ_FILES < "${OBJ_LIST}"
rm -f "${OBJ_LIST}"

ar rcs "${FAT_ARCHIVE}" "${OBJ_FILES[@]}"

# Workaround for linker error: remove object file with main() from libmw_com.a (must be after archive creation)
if [ -f "${FAT_ARCHIVE}" ]; then
    ar t "${FAT_ARCHIVE}" | grep -q lola_benchmarking_client.pic.o && ar d "${FAT_ARCHIVE}" lola_benchmarking_client.pic.o && \
    echo "Removed lola_benchmarking_client.pic.o from libmw_com.a to avoid multiple definition of main() error."
fi
echo "    Created ${FAT_ARCHIVE} ($(du -sh "${FAT_ARCHIVE}" | cut -f1))"

# ---------------------------------------------------------------------------
# 3. Install headers
# ---------------------------------------------------------------------------
INCLUDE_DIR="${SCORE_MW_SYSROOT}/include"
mkdir -p "${INCLUDE_DIR}"

# Helper: copy .h/.hpp from SRC_ROOT, paths relative to INC_ROOT
install_headers() {
    local src_root="$1"
    local inc_root="$2"
    find -L "${src_root}" \( -name "*.h" -o -name "*.hpp" \) | while IFS= read -r hdr; do
        REL="${hdr#${inc_root}/}"
        DEST="${INCLUDE_DIR}/${REL}"
        mkdir -p "$(dirname "${DEST}")"
        cp "${hdr}" "${DEST}"
    done
}

EXTERNALS="${COMM_REPO}/bazel-communication/external"

echo "==> Installing score/ (internal) headers ..."
install_headers "${COMM_REPO}/score" "${COMM_REPO}"

echo "==> Installing score_baselibs headers ..."
install_headers "${EXTERNALS}/score_baselibs+" "${EXTERNALS}/score_baselibs+"
FUTURECPP_INC="${EXTERNALS}/score_baselibs+/score/language/futurecpp/include"
[[ -d "${FUTURECPP_INC}" ]] && install_headers "${FUTURECPP_INC}" "${FUTURECPP_INC}"

echo "==> Installing score_logging headers ..."
[[ -d "${EXTERNALS}/score_logging+" ]] && \
    install_headers "${EXTERNALS}/score_logging+" "${EXTERNALS}/score_logging+"

echo "==> Installing Boost headers ..."
for boost_dir in "${EXTERNALS}"/boost.*+; do
    [[ -d "${boost_dir}/include" ]] && \
        install_headers "${boost_dir}/include" "${boost_dir}/include"
done

echo "==> Installing acl headers ..."
if [[ -n "$BAZEL_CPU" ]]; then
    ACL_INC="${EXTERNALS}/score_baselibs++_repo_rules+acl-deb-aarch64/usr/include"
else
    ACL_INC="${EXTERNALS}/score_baselibs++_repo_rules+acl-deb/usr/include"
fi
[[ -d "${ACL_INC}" ]] && install_headers "${ACL_INC}" "${ACL_INC}"

echo "==> Installing Bazel-generated (_virtual_includes) headers ..."
find -L bazel-bin -path "*/_virtual_includes/*" \
    \( -name "*.h" -o -name "*.hpp" \) | while IFS= read -r hdr; do
    REL=$(echo "${hdr}" | sed 's|.*/_virtual_includes/[^/]*/||')
    DEST="${INCLUDE_DIR}/${REL}"
    mkdir -p "$(dirname "${DEST}")"
    cp "${hdr}" "${DEST}"
done

# ---------------------------------------------------------------------------
# 4. Generate MwComConfig.cmake for find_package()
# ---------------------------------------------------------------------------
CMAKE_DIR="${SCORE_MW_SYSROOT}/lib/cmake/MwCom"
mkdir -p "${CMAKE_DIR}"

cat > "${CMAKE_DIR}/MwComConfig.cmake" << 'EOF'
# MwComConfig.cmake — imported target for score::mw::com
cmake_minimum_required(VERSION 3.16)

get_filename_component(_MWCOM_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)

if(NOT TARGET score::mw::com)
    add_library(score::mw::com STATIC IMPORTED GLOBAL)
    set_target_properties(score::mw::com PROPERTIES
        IMPORTED_LOCATION             "${_MWCOM_ROOT}/lib/libmw_com.a"
        INTERFACE_INCLUDE_DIRECTORIES "${_MWCOM_ROOT}/include"
        INTERFACE_LINK_LIBRARIES      "acl"
    )
endif()
EOF


echo ""
echo "==> Done."
echo ""
echo "    ${SCORE_MW_SYSROOT}/"
echo "    ├── include/          (headers)"
echo "    └── lib/"
echo "        ├── libmw_com.a   (fat static library)"
echo "        └── cmake/MwCom/MwComConfig.cmake"
echo ""
echo "Build your app:"
echo "    cd build"
if [[ -n "$BAZEL_CPU" ]]; then
    echo "    # Cross-compilation (e.g. ARM/aarch64):"
    echo "    cmake -DCMAKE_TOOLCHAIN_FILE=../toolchain-arm64.cmake -DCMAKE_PREFIX_PATH=${SCORE_MW_SYSROOT} .."
else
    echo "    cmake -DCMAKE_PREFIX_PATH=${SCORE_MW_SYSROOT} ${SCRIPT_DIR}/.."
fi
echo "    make -j\$(nproc)"



GLOBAL_SYSROOT="/usr/local/score_mw_sysroot${CPU_SUFFIX}"
echo ""
echo "==> Copying ${SCORE_MW_SYSROOT} to ${GLOBAL_SYSROOT} (requires sudo) ..."
sudo rm -rf "${GLOBAL_SYSROOT}"
sudo cp -r "${SCORE_MW_SYSROOT}" "${GLOBAL_SYSROOT}"
echo "    Installed global sysroot to ${GLOBAL_SYSROOT}"
