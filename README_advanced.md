# Advanced Setup Guide — Minimal Pub/Sub Example

This document covers the manual step-by-step preparation, build, and deployment process.
Use this if you want to understand what `build_and_deploy.sh` does internally, need to
debug a build failure, or want to integrate the middleware sysroot into your own build system.

For the quick start, see [README.md](README.md).

---

## Tested communication repo commit

The patching logic in `setup_score_sysroot.sh` has been tested against:

```
eclipse-score/communication
Commit : 1e03b3110c120ae3f9aff07a366ba8c99cf267d3
Date   : 2026-05-06
Subject: Merge pull request #374 from sahithi-nukala/sah_add_clang_tidy_checks
```

> ⚠️ **If the `eclipse-score/communication` repo has been updated past this commit**, the
> patches applied by `setup_score_sysroot.sh` may no longer apply cleanly.  Common failure
> modes are Bazel build errors or link-time undefined-reference errors during the sysroot
> build step.  In that case, compare the failing file against the patched version and update
> the corresponding patch in `setup_score_sysroot.sh` (section `0. Apply cross-compilation
> patches`).  See [Patch maintenance](#patch-maintenance) below for details.

---

## Prerequisites

### Common (x86 and ARM64)

- **Bazel 8.x** — the middleware is built with Bazel.
  Install via [Bazelisk](https://github.com/bazelbuild/bazelisk) (recommended):
  ```bash
  sudo curl -Lo /usr/local/bin/bazel \
      https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-amd64
  sudo chmod +x /usr/local/bin/bazel
  ```
- **GCC / G++ 11+** with C++17 support
- **Linux host** — the middleware uses POSIX shared memory IPC
- **Python 3** — used by `setup_score_sysroot.sh` for patching

### ARM64 cross-compilation prerequisites

To cross-compile for ARM64 (e.g. Raspberry Pi 5) you need:

- `gcc-aarch64-linux-gnu` and `g++-aarch64-linux-gnu`
- ARM64 sysroot headers (e.g. `/usr/aarch64-linux-gnu/include/`)

If your system lacks these or has a broken apt repository, use the bootstrap scripts:

```bash
git clone https://github.com/tfa2si/bazel-aarch64-cross-bootstrap
cd bazel-aarch64-cross-bootstrap
sudo bash bootstrap_aarch64_toolchain_sysroot.sh
```

This installs the cross-toolchain and the required sysroot headers system-wide.

---

## Step 1 — Clone the middleware repository

```bash
git clone https://github.com/eclipse-score/communication ~/score/communication
```

Pin to the tested commit for a reproducible build:
```bash
git -C ~/score/communication checkout 1e03b3110c120ae3f9aff07a366ba8c99cf267d3
```

---

## Step 2 — Apply cross-compilation patches

`setup_score_sysroot.sh` applies these patches automatically and idempotently each time it
runs.  If you want to apply them manually (e.g. to use the repo with Bazel directly), they
are described here.

### 2a. Add cross-toolchain and platform definitions

The upstream repo does not ship a cross-toolchain for `aarch64-linux-gnu`.  Copy the
required files into the repo:

```bash
COMM=~/score/communication
# Platform constraint definitions (//platforms:rpi5_aarch64)
cp -r /path/to/platforms/      "$COMM/platforms/"
# Bazel CC toolchain for aarch64-linux-gnu
cp -r /path/to/toolchain/      "$COMM/toolchain/"
# Local ACL library (required by score_baselibs for ARM64)
cp -r /path/to/local_libs/     "$COMM/local_libs/"
```

### 2b. Register toolchain and overrides in MODULE.bazel

Add to the top of `~/score/communication/MODULE.bazel` immediately after the `module()`
declaration:

```python
# Register minimal cross toolchain and platforms
register_toolchains("//toolchain:arm64_linux_gcc_toolchain_entry")
register_execution_platforms("//platforms:local_x86_64", "//platforms:rpi5_aarch64")

# Override score_baselibs with local fork (contains ARM64-compatible ACL)
local_path_override(
    module_name = "score_baselibs",
    path = "/path/to/score_forks/score_baselibs",
)

# Make local_acl visible to all modules (including score_baselibs)
bazel_dep(name = "local_acl", version = "1.0")
local_path_override(
    module_name = "local_acl",
    path = "./local_libs/acl",
)
```

### 2c. Suppress a -Werror warning in .bazelrc

```bash
echo 'build --copt=-Wno-error=deprecated-declarations' \
    >> ~/score/communication/.bazelrc
```

### 2d. Fix tracing_runtime.cpp

The upstream `ConvertToTracingServiceInstanceElement()` uses `score::cpp::variant` with a
`std::variant`-style constructor that is not available in the score variant implementation.
Replace the variant-based block with direct field assignment:

File: `score/mw/com/impl/bindings/lola/tracing/tracing_runtime.cpp`

Replace the section that constructs `element_variant` and returns
`ServiceInstanceElement{..., element_variant}` with:

```cpp
ServiceInstanceElement output_service_instance_element{};
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
// ... set instance_id, major_version, minor_version ...
return output_service_instance_element;
```

### 2e. Fix flag_file.cpp

`CreateDirectories()` returns `score::ResultBlank`, not `score::Result<void>`.
In `score/mw/com/impl/bindings/lola/service_discovery/flag_file.cpp` (around line 250):

```cpp
// Change:
score::Result<void> result{};
// To:
score::ResultBlank result{};

// And change the success assignment:
result = Result<void>{};
// To:
result = ResultBlank{};
```

---

## Step 3 — Build the middleware sysroot

```bash
cd /path/to/minimal_score_pubsub_cmake

# x86 host build
./setup_score_sysroot.sh ~/score/communication

# ARM64 cross-build
./setup_score_sysroot.sh ~/score/communication --cpu=arm64

# Skip Bazel cache clean (faster if re-running after a failed build)
./setup_score_sysroot.sh ~/score/communication --cpu=arm64 --no-clean
```

Output:
```
build/score_mw_sysroot/          (x86)
build/score_mw_sysroot_arm64/    (ARM64)
  ├── include/
  └── lib/
      ├── libmw_com.a            (fat static library)
      ├── libmw_com.so           (shared library)
      └── cmake/MwCom/MwComConfig.cmake
```

The script also copies the sysroot to `/usr/local/score_mw_sysroot[_arm64]/` for
system-wide access.

---

## Step 4 — Build the application with CMake

```bash
# x86
mkdir -p build/cmake_build && cd build/cmake_build
cmake -DCMAKE_PREFIX_PATH="$(pwd)/../score_mw_sysroot" ../..
make -j$(nproc)

# ARM64 (static linking)
mkdir -p build/cmake_build_arm64 && cd build/cmake_build_arm64
cmake -DCMAKE_TOOLCHAIN_FILE=../../toolchain-arm64.cmake \
      -DCMAKE_PREFIX_PATH="$(pwd)/../score_mw_sysroot_arm64" \
      ../..
make -j$(nproc)

# ARM64 (shared linking — libmw_com.so must be on the target)
cmake -DCMAKE_TOOLCHAIN_FILE=../../toolchain-arm64.cmake \
      -DCMAKE_PREFIX_PATH="$(pwd)/../score_mw_sysroot_arm64" \
      -DSCORE_MW_SHARED=ON \
      ../..
make -j$(nproc)
```

Binaries are placed in the build directory: `publisher`, `subscriber`, `torque_subscriber`.

---

## Step 5 — Deploy to target (ARM64)

```bash
TARGET=user@192.168.1.10
DEPLOY_DIR=~/score_pubsub
SYSROOT=build/score_mw_sysroot_arm64

# Create remote directory
ssh "$TARGET" "mkdir -p ${DEPLOY_DIR}/etc"

# Copy binaries and config
scp build/cmake_build_arm64/{publisher,subscriber,torque_subscriber} "$TARGET:${DEPLOY_DIR}/"
scp etc/mw_com_config.json "$TARGET:${DEPLOY_DIR}/etc/"

# If using shared linking — install the .so on the target
scp "${SYSROOT}/lib/libmw_com.so" "$TARGET:/tmp/"
ssh "$TARGET" "sudo mv /tmp/libmw_com.so /usr/local/lib/ && \
               sudo chmod 755 /usr/local/lib/libmw_com.so && \
               sudo ldconfig"
```

---

## Step 6 — Run on the target

```bash
ssh user@192.168.1.10
cd ~/score_pubsub

# Terminal 1
./publisher etc/mw_com_config.json

# Terminal 2
./subscriber etc/mw_com_config.json

# Terminal 3 (when a MotorTorque publisher is active, e.g. Simulink External Mode)
./torque_subscriber etc/mw_com_config.json
```

---

## Patch maintenance

`setup_score_sysroot.sh` applies patches in section `0. Apply cross-compilation patches`.
Each patch is guarded by a condition so it only runs when the unpatched version is detected —
making the script safe to re-run after a `git pull`.

If a new upstream commit breaks the build, follow these steps:

1. **Identify the failing file** from the Bazel error output.
2. **Compare** it against the previously patched version (or the `test/communication/`
   reference workspace if available).
3. **Update the patch block** in `setup_score_sysroot.sh`:
   - For text substitutions: update the `sed -i` pattern or add a new one.
   - For structural rewrites: update the Python heredoc that rewrites the file.
4. **Update the tested commit hash** at the top of this file.
5. **Re-run** `./setup_score_sysroot.sh /path/to/communication --cpu=arm64` to verify.

The patches currently applied and their guard conditions:

| File | Guard condition | Fix |
|---|---|---|
| `MODULE.bazel` | `arm64_linux_gcc_toolchain_entry` missing | Add toolchain/platform registration and `score_baselibs` override |
| `.bazelrc` | `-Wno-error=deprecated-declarations` missing | Append the flag |
| `tracing/tracing_runtime.cpp` | `StdVariantType element_variant` present | Replace with direct field assignment |
| `service_discovery/flag_file.cpp` | `score::Result<void> result{}` present | Replace with `score::ResultBlank` |
| `example/ipc_bridge/BUILD` | `console_only_backend` dep missing | Add the dep |
| `platforms/` dir | directory missing | Copy from local bootstrap |
| `toolchain/` dir | `cc_toolchain_config.bzl` missing | Copy from local bootstrap |
| `local_libs/` dir | directory missing | Copy from local bootstrap |
