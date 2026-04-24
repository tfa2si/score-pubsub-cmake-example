# Minimal Pub/Sub Example

A minimal publisher/subscriber example using the [Eclipse S-CORE](https://github.com/eclipse-score/communication)
middleware (`score::mw::com`). It demonstrates the full IPC lifecycle over shared memory (SHM):

- **Publisher** — offers a `MotorAngle` service, continuously sends `angle_deg` samples at 20 Hz
  (sinusoidal 90° amplitude at 1 Hz).
- **Subscriber** — discovers the service, subscribes to the `motor_angle` event, and prints each
  received sample via an event-driven receive handler (no polling).

## Repository layout

```
minimal_score_pubsub_cmake/
├── datatype.h / datatype.cpp      # MotorAngle struct + MotorAngleInterface/Proxy/Skeleton
├── publisher.cpp                  # Service skeleton: offers and sends samples
├── subscriber.cpp                 # Service proxy: finds, subscribes, receives samples
├── etc/
│   └── mw_com_config.json         # Service instance manifest (SHM binding, event slots)
├── build/
│   └── score_mw_sysroot/          # Middleware sysroot (headers, libs, CMake config)
├── setup_score_sysroot.sh         # Script to build/install the sysroot
├── toolchain-arm64.cmake          # Example toolchain file for ARM cross-compilation
├── CMakeLists.txt                 # CMake build configuration
└── README.md
```

## Prerequisites

 [Bazel](https://bazel.build/) (tested with 8.x)
> ⚠️ **Note:** The Eclipse SCORE middleware (communication) repository may not be fully compatible with Bazel 8.x Bzlmod (MODULE.bazel) for all dependencies (e.g., `@score_logging`).
> If you encounter errors about missing repositories, check for an updated version of the middleware or contact the maintainers for Bzlmod support.
- C++17-capable compiler (GCC or Clang)
- Linux host (shared memory IPC)

## Setup

### 1. Clone the middleware repository

```bash
git clone https://github.com/eclipse-score/communication /path/to/communication
```

### 2. Build and install the middleware sysroot

The `setup_score_sysroot.sh` script builds the middleware and installs headers + a fat static library into `build/score_mw_sysroot/`. You must pass the path to the cloned repository.

```bash
# x86 (host)
./setup_score_sysroot.sh /path/to/communication

# ARM64 cross-compilation
./setup_score_sysroot.sh /path/to/communication --cpu=arm64
```

This produces the sysroot in `build/score_mw_sysroot/` (x86) or `build/score_mw_sysroot_arm64/` (ARM64).

### 3. Build the example with CMake

```bash
# x86
mkdir -p build/cmake_build && cd build/cmake_build
cmake -DCMAKE_PREFIX_PATH=$(pwd)/../score_mw_sysroot ../..
make -j$(nproc)

# ARM64 (cross-compile)
mkdir -p build/cmake_build_arm64 && cd build/cmake_build_arm64
cmake -DCMAKE_PREFIX_PATH=$(pwd)/../score_mw_sysroot_arm64 \
      -DCMAKE_TOOLCHAIN_FILE=../../toolchain-arm64.cmake ../..
make -j$(nproc)
```

Binaries are placed in the respective build directory:
```
build/cmake_build/publisher
build/cmake_build/subscriber

build/cmake_build_arm64/publisher     (ARM64)
build/cmake_build_arm64/subscriber    (ARM64)
```

## Run

Open two terminals from the `communication/` directory.

**Terminal 1 — Publisher:**

```bash
./build/publisher etc/mw_com_config.json
```

Expected output:
```
[Publisher] Service offered. Sending data...
[Publisher] Sent motor angle [deg]: 0
[Publisher] Sent motor angle [deg]: 27.5664
[Publisher] Sent motor angle [deg]: 52.9919
...
```

**Terminal 2 — Subscriber:**

```bash
./build/subscriber etc/mw_com_config.json
```

Expected output:
```
[Subscriber] Looking for service...
[Subscriber] Service found. Connecting...
[Subscriber] Subscribed. Waiting for events...
[Subscriber] Received motor angle [deg]: 0
[Subscriber] Received motor angle [deg]: 27.5664
...
```

Stop either process with `Ctrl+C`.

## How it works

| Concept | This example |
|---|---|
| Service interface | `MotorAngleInterface<Trait>` — declares the `motor_angle_` event |
| Data type | `MotorAngle` — plain struct with `float angle_deg` |
| Publisher side | `MotorAngleSkeleton::Create()` → `OfferService()` → `Allocate()` → `Send()` |
| Subscriber side | `MotorAngleProxy::FindService()` → `Create()` → `Subscribe()` → `SetReceiveHandler()` |
| Transport | Shared memory (SHM), configured in `etc/mw_com_config.json` |
| Config | `instanceSpecifier: score/examples/MotorAngle`, `serviceId: 6432`, `eventId: 3` |
