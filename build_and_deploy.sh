#!/usr/bin/env bash
# build_and_deploy.sh — Interactive build and optional deploy for minimal_score_pubsub_cmake
#
# Usage (fully interactive):
#   ./build_and_deploy.sh
#
# Usage (non-interactive via flags):
#   ./build_and_deploy.sh [OPTIONS]
#
# Options:
#   --arch=x86|arm            Target architecture (default: interactive)
#   --link=static|shared      Linking mode (default: interactive)
#   --comm-repo=PATH          Path to eclipse-score/communication repo
#   --skip-sysroot            Skip rebuilding the middleware sysroot
#   --clean-cache=yes|no     Clean Bazel cache before sysroot build (default: interactive)
#   --deploy=yes|no           Deploy to remote target after build
#   --target=USER@HOST        SSH target for deployment (e.g. pi@192.168.1.10)
#   --deploy-dir=PATH         Remote directory to deploy to (default: ~/score_pubsub)
#   -y, --yes                 Accept all defaults non-interactively
#   -h, --help                Show this help and exit
#
# Examples:
#   # Fully interactive
#   ./build_and_deploy.sh
#
#   # ARM static build, no deploy
#   ./build_and_deploy.sh --arch=arm --link=static --deploy=no
#
#   # ARM shared build, deploy to Pi
#   ./build_and_deploy.sh --arch=arm --link=shared --deploy=yes \
#       --target=pi@192.168.1.10 --comm-repo=/path/to/communication

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
OPT_ARCH=""
OPT_LINK=""
OPT_COMM_REPO=""
OPT_SKIP_SYSROOT=0
OPT_CLEAN_CACHE=""
OPT_DEPLOY=""
OPT_TARGET=""
OPT_DEPLOY_DIR="~/score_pubsub"
OPT_YES=0

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --arch=*)       OPT_ARCH="${arg#--arch=}"; [[ "$OPT_ARCH" == "arm" ]] && OPT_ARCH="arm64" ;;
        --link=*)       OPT_LINK="${arg#--link=}" ;;
        --comm-repo=*)  OPT_COMM_REPO="${arg#--comm-repo=}" ;;
        --skip-sysroot) OPT_SKIP_SYSROOT=1 ;;
        --clean-cache=*) OPT_CLEAN_CACHE="${arg#--clean-cache=}" ;;
        --deploy=*)     OPT_DEPLOY="${arg#--deploy=}" ;;
        --target=*)     OPT_TARGET="${arg#--target=}" ;;
        --deploy-dir=*) OPT_DEPLOY_DIR="${arg#--deploy-dir=}" ;;
        -y|--yes)       OPT_YES=1 ;;
        -h|--help)
            grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//' | head -30
            exit 0
            ;;
        *) echo "Unknown option: $arg"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# ask VAR "Question" "default"
ask() {
    local -n _ref="$1"
    local question="$2"
    local default="${3:-}"
    if [[ $OPT_YES -eq 1 ]]; then
        _ref="$default"
        printf "  %-30s %s\n" "$question:" "[auto: ${default:-<empty>}]"
        return
    fi
    local prompt="$question"
    [[ -n "$default" ]] && prompt+=" [$default]"
    read -rp "  $prompt: " input
    _ref="${input:-$default}"
}

# ask_choice VAR "Question" option1 option2 ...
ask_choice() {
    local varname="$1"
    local question="$2"
    shift 2
    local choices=("$@")
    local default="${choices[0]}"
    local joined
    joined=$(IFS="|"; echo "${choices[*]}")
    while true; do
        ask "$varname" "$question ($joined)" "$default"
        local val="${!varname}"
        for c in "${choices[@]}"; do
            [[ "$val" == "$c" ]] && return
        done
        echo "    Invalid choice '$val'. Please enter one of: ${choices[*]}"
    done
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo ""
echo "========================================"
echo " minimal_score_pubsub — Build & Deploy"
echo "========================================"
echo ""

# ---------------------------------------------------------------------------
# 1. Architecture
# ---------------------------------------------------------------------------
if [[ -z "$OPT_ARCH" ]]; then
    ask_choice OPT_ARCH "Target architecture" "x86" "arm"
fi
# normalise: accept "arm" or "arm64" → internal value "arm64"
[[ "$OPT_ARCH" == "arm" || "$OPT_ARCH" == "arm64" ]] && OPT_ARCH="arm64"
case "$OPT_ARCH" in
    x86)
        CPU_FLAG=""
        CPU_SUFFIX=""
        BUILD_DIR_NAME="cmake_build"
        TOOLCHAIN_FLAG=""
        ;;
    arm64)
        CPU_FLAG="--cpu=arm64"
        CPU_SUFFIX="_arm64"
        BUILD_DIR_NAME="cmake_build_arm64"
        TOOLCHAIN_FLAG="-DCMAKE_TOOLCHAIN_FILE=${SCRIPT_DIR}/toolchain-arm64.cmake"
        ;;
    *)
        echo "ERROR: --arch must be 'x86' or 'arm'"; exit 1 ;;
esac

SYSROOT_DIR="${SCRIPT_DIR}/build/score_mw_sysroot${CPU_SUFFIX}"
FAT_LIB="${SYSROOT_DIR}/lib/libmw_com.a"

# ---------------------------------------------------------------------------
# 2. Linking mode
# ---------------------------------------------------------------------------
if [[ -z "$OPT_LINK" ]]; then
    ask_choice OPT_LINK "Linking mode" "static" "shared"
fi
case "$OPT_LINK" in
    static) SHARED_FLAG="" ;;
    shared) SHARED_FLAG="-DSCORE_MW_SHARED=ON" ;;
    *)      echo "ERROR: --link must be 'static' or 'shared'"; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# 3. Sysroot check / build
# ---------------------------------------------------------------------------
SYSROOT_HINT="./setup_score_sysroot.sh /path/to/communication${CPU_FLAG:+ $CPU_FLAG}"

if [[ $OPT_SKIP_SYSROOT -eq 1 ]]; then
    # Explicit skip requested — validate it exists
    if [[ ! -f "$FAT_LIB" ]]; then
        echo ""
        echo "ERROR: --skip-sysroot given but fat library not found:"
        echo "       $FAT_LIB"
        echo ""
        echo "       Build the sysroot first:"
        echo "         $SYSROOT_HINT"
        exit 1
    fi
elif [[ -f "$FAT_LIB" ]]; then
    # Sysroot already present — ask whether to rebuild
    echo ""
    echo "  Sysroot already exists: $SYSROOT_DIR"
    REBUILD_SYSROOT="no"
    if [[ $OPT_YES -eq 0 ]]; then
        ask_choice REBUILD_SYSROOT "Rebuild middleware sysroot?" "no" "yes"
    fi
    if [[ "$REBUILD_SYSROOT" == "yes" ]]; then
        OPT_SKIP_SYSROOT=0
    else
        OPT_SKIP_SYSROOT=1
    fi
else
    # Sysroot not found — build it automatically
    echo ""
    echo "  Middleware sysroot not found for arch '$OPT_ARCH'."
    echo "  Expected: $FAT_LIB"
    echo "  Will build it now..."
    OPT_SKIP_SYSROOT=0
fi

if [[ $OPT_SKIP_SYSROOT -eq 0 ]]; then
    # Auto-detect comm repo location (relative to script dir or home)
    if [[ -z "$OPT_COMM_REPO" ]]; then
        for candidate in \
            "${SCRIPT_DIR}/../score/communication" \
            "${SCRIPT_DIR}/../communication" \
            "${HOME}/score/communication" \
            "${HOME}/communication"; do
            if [[ -d "$candidate/.git" ]]; then
                OPT_COMM_REPO="$(realpath "$candidate")"
                break
            fi
        done
    fi
    if [[ -z "$OPT_COMM_REPO" ]]; then
        # No repo found anywhere — ask where to clone it
        DEFAULT_CLONE_PATH="${HOME}/score/communication"
        echo ""
        echo "  eclipse-score/communication repo not found on this host."
        ask OPT_COMM_REPO "Clone it to" "$DEFAULT_CLONE_PATH"
        if [[ -z "$OPT_COMM_REPO" ]]; then
            echo "ERROR: A communication repo path is required."
            exit 1
        fi
    fi
    if [[ ! -d "${OPT_COMM_REPO}/.git" ]]; then
        echo ""
        echo "  '${OPT_COMM_REPO}' does not exist or is not a git repo."
        CLONE_IT="yes"
        if [[ $OPT_YES -eq 0 ]]; then
            ask_choice CLONE_IT "Clone eclipse-score/communication there now?" "yes" "no"
        fi
        if [[ "$CLONE_IT" == "yes" ]]; then
            echo "==> Cloning eclipse-score/communication into ${OPT_COMM_REPO} ..."
            git clone https://github.com/eclipse-score/communication "${OPT_COMM_REPO}"
        else
            echo ""
            echo "  Clone it manually first:"
            echo "    git clone https://github.com/eclipse-score/communication ${OPT_COMM_REPO}"
            exit 0
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 4. Deploy?
# ---------------------------------------------------------------------------
if [[ -z "$OPT_DEPLOY" ]]; then
    ask_choice OPT_DEPLOY "Deploy to remote target after build?" "no" "yes"
fi
case "$OPT_DEPLOY" in
    yes|no) ;;
    *) echo "ERROR: --deploy must be 'yes' or 'no'"; exit 1 ;;
esac

if [[ "$OPT_DEPLOY" == "yes" ]]; then
    if [[ -z "$OPT_TARGET" ]]; then
        ask OPT_TARGET "SSH target (user@host, e.g. pi@192.168.1.10)" ""
        if [[ -z "$OPT_TARGET" ]]; then
            echo ""
            echo "ERROR: A target (user@host) is required for deployment."
            echo "       Pass --target=USER@HOST or choose --deploy=no."
            exit 1
        fi
    fi
    ask OPT_DEPLOY_DIR "Remote deploy directory" "$OPT_DEPLOY_DIR"
fi

# ---------------------------------------------------------------------------
# Summary + confirmation
# ---------------------------------------------------------------------------
echo ""
echo "----------------------------------------"
echo " Build configuration"
echo "----------------------------------------"
printf "  %-20s %s\n" "Architecture:"  "$OPT_ARCH"
printf "  %-20s %s\n" "Linking:"       "$OPT_LINK"
if [[ $OPT_SKIP_SYSROOT -eq 0 ]]; then
    printf "  %-20s %s\n" "Comm repo:"     "$OPT_COMM_REPO"
    printf "  %-20s %s\n" "Sysroot:"       "(will build → $SYSROOT_DIR)"
    [[ -n "$OPT_CLEAN_CACHE" ]] && printf "  %-20s %s\n" "Clean cache:" "$OPT_CLEAN_CACHE"
else
    printf "  %-20s %s\n" "Sysroot:"       "$SYSROOT_DIR (existing, skip rebuild)"
fi
printf "  %-20s %s\n" "Deploy:"        "$OPT_DEPLOY"
[[ "$OPT_DEPLOY" == "yes" ]] && printf "  %-20s %s → %s\n" "Target:" "$OPT_TARGET" "$OPT_DEPLOY_DIR"
echo "----------------------------------------"
echo ""

if [[ $OPT_YES -eq 0 ]]; then
    read -rp "Proceed? [Y/n] " confirm
    [[ "${confirm,,}" == "n" ]] && echo "Aborted." && exit 0
fi

# ---------------------------------------------------------------------------
# 5. Build sysroot
# ---------------------------------------------------------------------------
if [[ $OPT_SKIP_SYSROOT -eq 0 ]]; then
    # Ask about Bazel cache clean
    if [[ -z "$OPT_CLEAN_CACHE" ]]; then
        ask_choice OPT_CLEAN_CACHE "Clean Bazel cache before sysroot build?" "yes" "no"
    fi
    case "$OPT_CLEAN_CACHE" in
        yes|no) ;;
        *) echo "ERROR: --clean-cache must be 'yes' or 'no'"; exit 1 ;;
    esac

    echo ""
    echo "==> Building middleware sysroot ..."
    cd "$SCRIPT_DIR"
    CLEAN_FLAG=""
    [[ "$OPT_CLEAN_CACHE" == "no" ]] && CLEAN_FLAG="--no-clean"
    bash setup_score_sysroot.sh "$OPT_COMM_REPO" ${CPU_FLAG:+"$CPU_FLAG"} ${CLEAN_FLAG:+"$CLEAN_FLAG"}
fi

# ---------------------------------------------------------------------------
# 6. CMake + make
# ---------------------------------------------------------------------------
CMAKE_BUILD_DIR="${SCRIPT_DIR}/build/${BUILD_DIR_NAME}"
mkdir -p "$CMAKE_BUILD_DIR"
cd "$CMAKE_BUILD_DIR"

echo ""
echo "==> Running CMake in ${CMAKE_BUILD_DIR} ..."
cmake \
    ${TOOLCHAIN_FLAG:+"$TOOLCHAIN_FLAG"} \
    -DCMAKE_PREFIX_PATH="${SYSROOT_DIR}" \
    ${SHARED_FLAG:+"$SHARED_FLAG"} \
    "${SCRIPT_DIR}"

echo ""
echo "==> Building ..."
make -j"$(nproc)"

BINARIES=(publisher subscriber torque_subscriber)
echo ""
echo "==> Built binaries:"
ls -lh "${BINARIES[@]}"

# ---------------------------------------------------------------------------
# 7. Deploy
# ---------------------------------------------------------------------------
if [[ "$OPT_DEPLOY" == "yes" ]]; then
    echo ""
    echo "==> Deploying to ${OPT_TARGET}:${OPT_DEPLOY_DIR} ..."

    ssh "$OPT_TARGET" "mkdir -p ${OPT_DEPLOY_DIR}/etc"

    echo "    Copying binaries ..."
    scp "${BINARIES[@]}" "$OPT_TARGET:${OPT_DEPLOY_DIR}/"

    echo "    Copying config ..."
    scp "${SCRIPT_DIR}/etc/mw_com_config.json" "$OPT_TARGET:${OPT_DEPLOY_DIR}/etc/"

    if [[ "$OPT_LINK" == "shared" ]]; then
        echo "    Copying libmw_com.so ..."
        # Try /usr/local/lib first; fall back to deploy dir with LD_LIBRARY_PATH hint
        if ssh "$OPT_TARGET" "sudo mkdir -p /usr/local/lib && sudo cp /dev/stdin /usr/local/lib/libmw_com.so && sudo chmod 755 /usr/local/lib/libmw_com.so && sudo ldconfig" \
               < "${SYSROOT_DIR}/lib/libmw_com.so" 2>/dev/null; then
            echo "    Installed libmw_com.so to /usr/local/lib on target."
            LD_PREFIX=""
        else
            scp "${SYSROOT_DIR}/lib/libmw_com.so" "$OPT_TARGET:${OPT_DEPLOY_DIR}/"
            echo "    Note: could not install to /usr/local/lib — copied to ${OPT_DEPLOY_DIR} instead."
            LD_PREFIX="LD_LIBRARY_PATH=${OPT_DEPLOY_DIR} "
        fi
    else
        LD_PREFIX=""
    fi

    echo ""
    echo "==> Deployment complete."
    echo ""
    echo "    Deployed to: ${OPT_TARGET}:${OPT_DEPLOY_DIR}"
    echo ""
    echo "    On the target (${OPT_TARGET}), run:"
    echo "      cd ${OPT_DEPLOY_DIR}"
    echo "      ${LD_PREFIX}./publisher etc/mw_com_config.json"
    echo "      ${LD_PREFIX}./subscriber etc/mw_com_config.json"
    echo "      ${LD_PREFIX}./torque_subscriber etc/mw_com_config.json"
fi

echo ""
echo "==> Done."
