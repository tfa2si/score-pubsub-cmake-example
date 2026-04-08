#!/usr/bin/env bash
# install_sysroot.sh — Build score::mw::com and install headers + fat static library
# to a sysroot directory for use by standalone CMake applications.
#
# Usage:
#   ./install_sysroot.sh [COMMUNICATION_REPO_DIR [SYSROOT_DIR]]
#
# Defaults:
#   COMMUNICATION_REPO_DIR  = ../communication  (sibling of this repo)
#   SYSROOT_DIR             = ./sysroot
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMM_REPO="${1:-$(realpath "${SCRIPT_DIR}/../communication")}"
SYSROOT="${2:-${SCRIPT_DIR}/sysroot}"

echo "==> Communication repo : ${COMM_REPO}"
echo "==> Sysroot target     : ${SYSROOT}"

cd "${COMM_REPO}"

# ---------------------------------------------------------------------------
# 1. Build //score/mw/com — compiles all middleware object files into bazel-bin
# ---------------------------------------------------------------------------
echo "==> Building //score/mw/com ..."
bazel build //score/mw/com

echo "==> Building transitive C++ deps (score_baselibs, score_logging, plumbing) ..."
# These targets are not compiled as part of //score/mw/com alone.
# They provide symbols referenced by objects in the fat archive.
bazel build \
    @score_baselibs//score/mw/log/detail:thread_local_guard \
    @score_baselibs//score/mw/log/detail:log_recorder_factory \
    @score_baselibs//score/mw/log/detail:empty_recorder_factory \
    @score_baselibs//score/mw/log/detail:console_only_recorder_factory \
    @score_baselibs//score/memory/shared:shared_memory_factory_impl \
    @score_baselibs//score/memory/shared:shared_memory_factory \
    @score_logging//score/mw/log/detail/common:recorder_factory \
    @score_logging//score/mw/log/detail/common:composite_recorder \
    @score_logging//score/mw/log/detail/file_recorder:file_recorder \
    @score_logging//score/mw/log/detail/file_recorder:file_recorder_factory \
    //score/mw/com/impl/plumbing:proxy_binding_factory_impl \
    //score/mw/com/impl/plumbing:skeleton_binding_factory_impl \
    //score/mw/com/impl/bindings/lola:path_builder \
    //score/mw/com/impl/bindings/lola:shm_path_builder \
    //score/mw/com/impl/bindings/lola:partial_restart_path_builder

# ---------------------------------------------------------------------------
# 2. Collect middleware .pic.o files and pack into a fat static library.
#    We use all .pic.o under bazel-bin, excluding examples and tests.
# ---------------------------------------------------------------------------
LIB_DIR="${SYSROOT}/lib"
mkdir -p "${LIB_DIR}"

FAT_ARCHIVE="${LIB_DIR}/libmw_com.a"
echo "==> Collecting object files ..."

OBJ_LIST="$(mktemp)"
find -L bazel-bin -name "*.pic.o" \
    ! -path "*/example/*" \
    ! -path "*/test/*"    \
    ! -path "*/tests/*"   \
    ! -name "*_test.pic.o" \
    > "${OBJ_LIST}"

OBJ_COUNT=$(wc -l < "${OBJ_LIST}")
echo "    Found ${OBJ_COUNT} object files"

echo "==> Building ${FAT_ARCHIVE} ..."
# Read list into array to pass to ar (handles spaces in paths)
mapfile -t OBJ_FILES < "${OBJ_LIST}"
rm -f "${OBJ_LIST}"

ar rcs "${FAT_ARCHIVE}" "${OBJ_FILES[@]}"
echo "    Created ${FAT_ARCHIVE} ($(du -sh "${FAT_ARCHIVE}" | cut -f1))"

# ---------------------------------------------------------------------------
# 3. Install headers
# ---------------------------------------------------------------------------
INCLUDE_DIR="${SYSROOT}/include"
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
ACL_INC="${EXTERNALS}/score_baselibs++_repo_rules+acl-deb-aarch64/usr/include"
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
CMAKE_DIR="${SYSROOT}/lib/cmake/MwCom"
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
echo "    ${SYSROOT}/"
echo "    ├── include/          (headers)"
echo "    └── lib/"
echo "        ├── libmw_com.a   (fat static library)"
echo "        └── cmake/MwCom/MwComConfig.cmake"
echo ""
echo "Build your app:"
echo "    mkdir build && cd build"
echo "    cmake -DCMAKE_PREFIX_PATH=${SYSROOT} ${SCRIPT_DIR}"
echo "    make -j\$(nproc)"
