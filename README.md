# Minimal Pub/Sub Example

A minimal publisher/subscriber example using the [Eclipse S-CORE](https://github.com/eclipse-score/communication)
middleware (`score::mw::com`). It demonstrates the full IPC lifecycle over shared memory (SHM):

- **Publisher** — offers a `MotorAngle` service, continuously sends `angle_deg` samples at 20 Hz
  (sinusoidal 90° amplitude at 1 Hz).
- **Subscriber** — discovers the service, subscribes to the `motor_angle` event, and prints each
  received sample via an event-driven receive handler (no polling).
- **TorqueSubscriber** — subscribes to a `MotorTorque` service and prints `torque_nm` samples;
  intended as a companion to the `example_scorePubSub` MATLAB External Mode example
  where Simulink publishes `MotorTorque`.

For a detailed walkthrough of the manual build process, prerequisites, and how the patching works,
see [README_advanced.md](README_advanced.md).

## Repository layout

```
minimal_score_pubsub_cmake/
├── datatype.h / datatype.cpp      # MotorAngle/MotorTorque structs + Interface/Proxy/Skeleton
├── publisher.cpp                  # Service skeleton: offers and sends MotorAngle samples
├── subscriber.cpp                 # Service proxy: finds, subscribes, receives MotorAngle samples
├── torque_subscriber.cpp          # Service proxy: subscribes to MotorTorque (published by Simulink)
├── etc/
│   └── mw_com_config.json         # Service instance manifest (SHM binding, event slots)
├── build/
│   └── score_mw_sysroot/          # Middleware sysroot (headers, libs, CMake config)
├── setup_score_sysroot.sh         # Builds the middleware sysroot (auto-applies patches)
├── build_and_deploy.sh            # Interactive build + deploy script (recommended entry point)
├── toolchain-arm64.cmake          # ARM64 cross-compilation toolchain file
├── CMakeLists.txt                 # CMake build configuration
└── README.md
```

## Prerequisites

- [Bazel](https://bazel.build/) 8.x
- C++17-capable compiler (GCC or Clang)
- Linux host (shared memory IPC)

For ARM64 cross-compilation (e.g. Raspberry Pi 5), you also need the `aarch64-linux-gnu` cross-toolchain.
See [README_advanced.md](README_advanced.md#arm64-cross-compilation-prerequisites) for setup instructions.

> **Tested communication repo commit:**
> [`1e03b3110c120ae3f9aff07a366ba8c99cf267d3`](https://github.com/eclipse-score/communication/commit/1e03b3110c120ae3f9aff07a366ba8c99cf267d3)
> (2026-05-06 — *Adding clang-tidy checks*)
> If the upstream repo has been updated past this commit, the sysroot patches in
> `setup_score_sysroot.sh` may need updating. See the
> [Troubleshooting](#sysroot-build-fails-after-a-git-pull-on-the-communication-repo) section.

## Quick start — `build_and_deploy.sh`

The recommended way to build (and optionally deploy to a remote target) is via the interactive script:

```bash
./build_and_deploy.sh
```

The script will guide you through:
1. Target architecture (`x86` or `arm`)
2. Linking mode (`static` or `shared`)
3. Whether to (re)build the middleware sysroot, and which communication repo to use
4. Whether to clean the Bazel cache before building
5. Whether to deploy the binaries to a remote SSH target

### Non-interactive usage

```bash
# ARM static build, no deploy
./build_and_deploy.sh --arch=arm --link=static --deploy=no

# ARM static build, skip sysroot rebuild, deploy to Pi
./build_and_deploy.sh --arch=arm --link=static --skip-sysroot \
    --deploy=yes --target=pi@192.168.1.10

# ARM shared build, deploy to Pi, fully non-interactive
./build_and_deploy.sh --arch=arm --link=shared --clean-cache=no \
    --deploy=yes --target=pi@192.168.1.10 -y
```

All options:

| Option | Description |
|---|---|
| `--arch=x86\|arm` | Target architecture |
| `--link=static\|shared` | Linking mode |
| `--comm-repo=PATH` | Path to eclipse-score/communication repo |
| `--skip-sysroot` | Skip rebuilding the middleware sysroot |
| `--clean-cache=yes\|no` | Clean Bazel cache before sysroot build |
| `--deploy=yes\|no` | Deploy to remote target after build |
| `--target=USER@HOST` | SSH target (e.g. `pi@192.168.1.10`) |
| `--deploy-dir=PATH` | Remote deploy directory (default: `~/score_pubsub`) |
| `-y`, `--yes` | Accept all defaults non-interactively |
| `-h`, `--help` | Show help and exit |

## Run

After building, open two terminals on the target device (or locally for x86):

**Terminal 1 — Publisher:**
```bash
cd ~/score_pubsub
./publisher etc/mw_com_config.json
```
```
[Publisher] Service offered. Sending data...
[Publisher] Sent motor angle [deg]: 0
[Publisher] Sent motor angle [deg]: 27.5664
...
```

**Terminal 2 — Subscriber:**
```bash
cd ~/score_pubsub
./subscriber etc/mw_com_config.json
```
```
[Subscriber] Service found. Connecting...
[Subscriber] Received motor angle [deg]: 0
[Subscriber] Received motor angle [deg]: 27.5664
...
```

**Terminal 3 — Torque Subscriber** (used with the `example_scorePubSub` MATLAB External Mode example):
```bash
cd ~/score_pubsub
./torque_subscriber etc/mw_com_config.json
```
```
[TorqueSubscriber] Received motor torque [Nm]: 0.5
...
```

Stop any process with `Ctrl+C`.

## How it works

| Concept | This example |
|---|---|
| Service interface | `MotorAngleInterface<Trait>` — declares the `motor_angle_` event |
| Data type | `MotorAngle` — plain struct with `float angle_deg` |
| Publisher side | `MotorAngleSkeleton::Create()` → `OfferService()` → `Allocate()` → `Send()` |
| Subscriber side | `MotorAngleProxy::FindService()` → `Create()` → `Subscribe()` → `SetReceiveHandler()` |
| Torque subscriber | `MotorTorqueProxy::FindService()` → `Create()` → `Subscribe()` → `SetReceiveHandler()` |
| Torque data type | `MotorTorque` — plain struct with `float torque_nm`; published by Simulink in `example_scorePubSub` |
| Transport | Shared memory (SHM), configured in `etc/mw_com_config.json` |
| Config | `instanceSpecifier: score/examples/MotorAngle`, `serviceId: 6432`, `eventId: 3` |
| Torque config | `instanceSpecifier: score/examples/MotorTorque` (see `etc/mw_com_config.json`) |

## Troubleshooting

### Sysroot build fails after a `git pull` on the communication repo

The patches applied by `setup_score_sysroot.sh` were tested against a specific commit.
If the upstream repo has moved past it, the build may fail with compile or Bazel errors.

**First, pin to the tested commit and retry:**

```bash
git -C ~/score/communication checkout 1e03b3110c120ae3f9aff07a366ba8c99cf267d3
./setup_score_sysroot.sh ~/score/communication --cpu=arm64
```

If that succeeds, the issue is a newer upstream change. See
[README_advanced.md — Patch maintenance](README_advanced.md#patch-maintenance) for how to
update the patches for the new commit.

### `ERROR: no such package 'platforms'`

The `platforms/` directory is missing from the communication repo. Run the sysroot script
once — it will copy it automatically. Or copy it manually:

```bash
cp -r /path/to/minimal_score_pubsub_cmake/../hello_world_bazel_cross_comp/platforms \
    ~/score/communication/platforms
```

### `error: could not convert … from 'StdVariantType' to 'VariantType'`

The `tracing_runtime.cpp` patch is needed but was not applied. Delete the communication
repo's Bazel cache and re-run the sysroot script (it will patch and rebuild):

```bash
bazel -C ~/score/communication clean
./setup_score_sysroot.sh ~/score/communication --cpu=arm64
```

### `undefined reference to score::os::Path::Default`

The `@score_baselibs//score/os/utils:path` target is missing from the fat library. This is
fixed in `setup_score_sysroot.sh` — make sure you have the latest version of the script and
rebuild the sysroot.

### `syntax error at '\': expected expression` in MODULE.bazel

A previous run left literal `\n` sequences in `MODULE.bazel` (shell quoting issue). Fix:

```bash
python3 - ~/score/communication/MODULE.bazel <<'EOF'
import sys
path = sys.argv[1]
with open(path) as f: src = f.read()
src = src.replace('\\n', '\n')
with open(path, 'w') as f: f.write(src)
print("Fixed")
EOF
```

Then re-run the sysroot script.

### Binaries run but no data is received

- Ensure publisher and subscriber use the **same** `mw_com_config.json`.
- Both processes must run as the **same user** (shared memory permissions).
- On a remote target: verify the config was deployed to `etc/mw_com_config.json` relative to
  the working directory, and run from inside the deploy directory:
  ```bash
  cd ~/score_pubsub && ./publisher etc/mw_com_config.json
  ```

### Shared library not found on target (`error while loading shared libraries`)

The `libmw_com.so` was not installed to a system library path. Either:

```bash
# Option A — install system-wide (requires sudo on target)
sudo cp libmw_com.so /usr/local/lib/
sudo ldconfig

# Option B — set LD_LIBRARY_PATH at runtime
LD_LIBRARY_PATH=~/score_pubsub ./publisher etc/mw_com_config.json
```

