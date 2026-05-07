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


# Parse --cpu and --no-clean arguments
BAZEL_CPU=""
SKIP_BAZEL_CLEAN=0
OTHER_ARGS=()
for arg in "$@"; do
    if [[ "$arg" == --cpu=* ]]; then
        BAZEL_CPU="--cpu=arm64"  # This line is modified to always use aarch64
    elif [[ "$arg" == --no-clean ]]; then
        SKIP_BAZEL_CLEAN=1
    else
        OTHER_ARGS+=("$arg")
    fi
done

# Remove --cpu/--no-clean from positional parameters
set -- "${OTHER_ARGS[@]}"

# Set ARM64 platform flags only when --cpu=arm64 was requested
# --copt=-fPIC is required to build a shared library from these objects;
# it is harmless for static linking.
if [[ -n "$BAZEL_CPU" ]]; then
    BAZEL_CPU="--cpu=arm64"
    BAZEL_PLAT="--platforms=//platforms:rpi5_aarch64"
    BAZEL_CROSSTOOL=""
    BAZEL_COMPILER=""
    BAZEL_FPIC="--copt=-fPIC"
else
    BAZEL_PLAT=""
    BAZEL_CROSSTOOL=""
    BAZEL_COMPILER=""
    BAZEL_FPIC="--copt=-fPIC"
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

# ---------------------------------------------------------------------------
# 0. Apply cross-compilation patches to the comm repo (idempotent)
# ---------------------------------------------------------------------------
SCORE_BASELIBS="${SCRIPT_DIR}/../score_forks/score_baselibs"

echo "==> Applying cross-compilation patches to comm repo ..."

# 0a. platforms/ — defines //platforms:rpi5_aarch64
if [[ ! -d "${COMM_REPO}/platforms" ]]; then
    SRC_PLATFORMS=""
    for candidate in \
        "${SCRIPT_DIR}/../hello_world_bazel_cross_comp/platforms" \
        "${SCRIPT_DIR}/../bazel_cross_comp_test/platforms" \
        "${SCRIPT_DIR}/../test/communication/platforms"; do
        [[ -d "$candidate" ]] && SRC_PLATFORMS="$candidate" && break
    done
    if [[ -n "$SRC_PLATFORMS" ]]; then
        cp -r "$SRC_PLATFORMS" "${COMM_REPO}/platforms"
        echo "    platforms/ copied from ${SRC_PLATFORMS}"
    else
        echo "    WARNING: could not find a platforms/ directory to copy"
    fi
fi

# 0b. toolchain/ — provides //toolchain:arm64_linux_gcc_toolchain_entry
if [[ ! -f "${COMM_REPO}/toolchain/cc_toolchain_config.bzl" ]]; then
    SRC_TOOLCHAIN=""
    for candidate in \
        "${SCRIPT_DIR}/../test/communication/toolchain" \
        "${SCRIPT_DIR}/../hello_world_bazel_cross_comp/toolchain"; do
        [[ -f "${candidate}/cc_toolchain_config.bzl" ]] && SRC_TOOLCHAIN="$candidate" && break
    done
    if [[ -n "$SRC_TOOLCHAIN" ]]; then
        mkdir -p "${COMM_REPO}/toolchain"
        cp -r "${SRC_TOOLCHAIN}/." "${COMM_REPO}/toolchain/"
        echo "    toolchain/ copied from ${SRC_TOOLCHAIN}"
    else
        echo "    WARNING: could not find a toolchain/ directory to copy"
    fi
fi

# 0c. local_libs/ — local ACL library
if [[ ! -d "${COMM_REPO}/local_libs" ]]; then
    for candidate in \
        "${SCRIPT_DIR}/../test/communication/local_libs"; do
        if [[ -d "$candidate" ]]; then
            cp -r "$candidate" "${COMM_REPO}/local_libs"
            echo "    local_libs/ copied from ${candidate}"
            break
        fi
    done
fi

# 0d. MODULE.bazel — register cross toolchain + platforms + local overrides
# Use Python to do the insert so we avoid shell quoting / newline issues.
SCORE_BASELIBS_ABS="$(realpath "${SCORE_BASELIBS}" 2>/dev/null || echo "${SCORE_BASELIBS}")"
python3 - "${COMM_REPO}/MODULE.bazel" "${SCORE_BASELIBS_ABS}" <<'PYEOF'
import sys, os
path, baselibs = sys.argv[1], sys.argv[2]
with open(path) as f:
    src = f.read()

needs_toolchain = 'arm64_linux_gcc_toolchain_entry' not in src
needs_baselibs  = 'module_name = "score_baselibs"' not in src

if not needs_toolchain and not needs_baselibs:
    sys.exit(0)

block = ""
if needs_toolchain:
    block += """
# Register minimal cross toolchain and platforms
register_toolchains("//toolchain:arm64_linux_gcc_toolchain_entry")
register_execution_platforms("//platforms:local_x86_64", "//platforms:rpi5_aarch64")"""

if needs_baselibs and os.path.isdir(baselibs):
    block += """

# Override score_baselibs with local fork
local_path_override(
    module_name = "score_baselibs",
    path = \"""" + baselibs + """\",
)

# Make local_acl visible to all modules (including score_baselibs)
bazel_dep(name = "local_acl", version = "1.0")
local_path_override(
    module_name = "local_acl",
    path = "./local_libs/acl",
)"""

anchor = 'module(name = "score_communication")'
idx = src.find(anchor)
if idx == -1:
    print("    MODULE.bazel: anchor not found, skipping"); sys.exit(0)

end = idx + len(anchor)
src = src[:end] + block + src[end:]
with open(path, 'w') as f:
    f.write(src)
print("    MODULE.bazel: patched OK")
PYEOF

# 0e. .bazelrc — suppress deprecated-declarations warning-as-error
if ! grep -q 'Wno-error=deprecated-declarations' "${COMM_REPO}/.bazelrc" 2>/dev/null; then
    echo 'build --copt=-Wno-error=deprecated-declarations' >> "${COMM_REPO}/.bazelrc"
    echo "    .bazelrc: added -Wno-error=deprecated-declarations"
fi

# 0f. tracing_runtime.cpp — replace StdVariantType with direct field assignment
TRACING="${COMM_REPO}/score/mw/com/impl/bindings/lola/tracing/tracing_runtime.cpp"
if grep -q 'StdVariantType element_variant' "$TRACING" 2>/dev/null; then
    python3 - "$TRACING" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    src = f.read()
old = re.search(r'// Compute element variant.*?return ServiceInstanceElement\{[^}]+\};', src, re.DOTALL)
if not old:
    print("    tracing_runtime.cpp: pattern not found, skipping")
    sys.exit(0)
new_code = '''    ServiceInstanceElement output_service_instance_element{};
    if (service_element_type == impl::ServiceElementType::EVENT)
    {
        const auto lola_event_id = lola_service_type_deployment->events_.at(std::string{service_element_name});
        output_service_instance_element.element_id = static_cast<ServiceInstanceElement::EventIdType>(lola_event_id);
    }
    else if (service_element_type == impl::ServiceElementType::FIELD)
    {
        const auto lola_field_id = lola_service_type_deployment->fields_.at(std::string{service_element_name});
        output_service_instance_element.element_id = static_cast<ServiceInstanceElement::FieldIdType>(lola_field_id);
    }
    else
    {
        score::mw::log::LogFatal("lola") << "Service element type: " << service_element_type
                                         << " is invalid. Terminating.";
        std::terminate();
    }

    output_service_instance_element.service_id =
        static_cast<ServiceInstanceElement::ServiceIdType>(lola_service_type_deployment->service_id_);

    if (!lola_service_instance_deployment->instance_id_.has_value())
    {
        score::mw::log::LogFatal("lola")
            << "Tracing should not be done on service element without configured instance ID. Terminating.";
        std::terminate();
    }
    output_service_instance_element.instance_id = static_cast<ServiceInstanceElement::InstanceIdType>(
        lola_service_instance_deployment->instance_id_.value().GetId());

    const auto version = ServiceIdentifierTypeView{service_identifier}.GetVersion();
    output_service_instance_element.major_version = ServiceVersionTypeView{version}.getMajor();
    output_service_instance_element.minor_version = ServiceVersionTypeView{version}.getMinor();
    return output_service_instance_element;'''
src = src[:old.start()] + new_code + src[old.end():]
with open(path, 'w') as f:
    f.write(src)
print("    tracing_runtime.cpp: patched OK")
PYEOF
fi

# 0g. flag_file.cpp — use ResultBlank instead of Result<void> for local vars
FLAG_FILE="${COMM_REPO}/score/mw/com/impl/bindings/lola/service_discovery/flag_file.cpp"
if grep -q 'score::Result<void> result{}' "$FLAG_FILE" 2>/dev/null; then
    sed -i \
        -e 's/score::Result<void> result{}/score::ResultBlank result{}/g' \
        -e 's/result = Result<void>{}/result = ResultBlank{}/g' \
        "$FLAG_FILE"
    echo "    flag_file.cpp: patched ResultBlank"
fi

# 0h. ipc_bridge BUILD — add console_only_backend dep if missing
IPC_BUILD="${COMM_REPO}/score/mw/com/example/ipc_bridge/BUILD"
if [[ -f "$IPC_BUILD" ]] && ! grep -q 'console_only_backend' "$IPC_BUILD"; then
    sed -i 's|"@score_baselibs//score/mw/log",|"@score_baselibs//score/mw/log",\n        "@score_baselibs//score/mw/log:console_only_backend",|' \
        "$IPC_BUILD"
    echo "    ipc_bridge/BUILD: added console_only_backend dep"
fi

cd "${COMM_REPO}"

# Set BAZEL_CONFIG first (needed regardless of clean)
if [[ -n "$BAZEL_CPU" ]]; then
    BAZEL_CONFIG="$BAZEL_CPU $BAZEL_PLAT $BAZEL_FPIC"
else
    BAZEL_CONFIG="$BAZEL_FPIC"
fi

# Clean Bazel outputs to avoid mixing architectures (skip with --no-clean)
if [[ $SKIP_BAZEL_CLEAN -eq 0 ]]; then
    echo "==> Cleaning previous Bazel build outputs (bazel clean) ..."
    if [[ -n "$BAZEL_CPU" ]]; then
        bazel clean $BAZEL_CPU $BAZEL_PLAT
    else
        bazel clean
    fi
else
    echo "==> Skipping Bazel cache clean (--no-clean)."
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
    @score_baselibs//score/os/utils:path \
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
# 2b. Build shared library libmw_com.so from the fat archive
#     Extract all objects to a temp dir first — ar x deduplicates by basename
#     (later extraction overwrites earlier ones), avoiding multiple-definition
#     errors that arise from --whole-archive on a fat archive with duplicates.
# ---------------------------------------------------------------------------
SHARED_LIB="${LIB_DIR}/libmw_com.so"
echo "==> Building ${SHARED_LIB} ..."
if [[ -n "$BAZEL_CPU" ]]; then
    SHARED_LINKER="aarch64-linux-gnu-gcc"
else
    SHARED_LINKER="gcc"
fi
TMPOBJ="$(mktemp -d)"
(cd "$TMPOBJ" && ar x "${FAT_ARCHIVE}")
# recorder_factory.o duplicates all symbols already in console_only_recorder_factory.o;
# remove it to avoid multiple-definition errors when linking the shared library.
rm -f "$TMPOBJ/recorder_factory.o"
# Use --whole-archive so all symbols are included, --allow-multiple-definition to
# suppress any remaining duplicate-symbol errors (first definition wins).
"${SHARED_LINKER}" -shared -o "${SHARED_LIB}" \
    -Wl,--whole-archive "${FAT_ARCHIVE}" -Wl,--no-whole-archive \
    -Wl,--allow-multiple-definition \
    -lacl
rm -rf "$TMPOBJ"
echo "    Created ${SHARED_LIB} ($(du -sh "${SHARED_LIB}" | cut -f1))"

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
# MwComConfig.cmake — imported targets for score::mw::com (static + shared)
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

if(EXISTS "${_MWCOM_ROOT}/lib/libmw_com.so" AND NOT TARGET score::mw::com::shared)
    add_library(score::mw::com::shared SHARED IMPORTED GLOBAL)
    set_target_properties(score::mw::com::shared PROPERTIES
        IMPORTED_LOCATION             "${_MWCOM_ROOT}/lib/libmw_com.so"
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
echo "        ├── libmw_com.so  (shared library)"
echo "        └── cmake/MwCom/MwComConfig.cmake"
echo ""
echo "    Note: when using the shared library, copy libmw_com.so to the target device:"
echo "      scp ${SCORE_MW_SYSROOT}/lib/libmw_com.so <user>@<target>:/usr/local/lib/"
echo "      ssh <user>@<target> ldconfig"



GLOBAL_SYSROOT="/usr/local/score_mw_sysroot${CPU_SUFFIX}"
echo ""
echo "==> Copying ${SCORE_MW_SYSROOT} to ${GLOBAL_SYSROOT} (requires sudo) ..."
sudo rm -rf "${GLOBAL_SYSROOT}"
sudo cp -r "${SCORE_MW_SYSROOT}" "${GLOBAL_SYSROOT}"
echo "    Installed global sysroot to ${GLOBAL_SYSROOT}"
