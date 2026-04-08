# Minimal Pub/Sub Example

A minimal publisher/subscriber example using the [Eclipse S-CORE](https://github.com/eclipse-score/communication)
middleware (`score::mw::com`). It demonstrates the full IPC lifecycle over shared memory (SHM):

- **Publisher** — offers a `MotorAngle` service, continuously sends `angle_deg` samples at 20 Hz
  (sinusoidal 90° amplitude at 1 Hz).
- **Subscriber** — discovers the service, subscribes to the `motor_angle` event, and prints each
  received sample via an event-driven receive handler (no polling).

## Repository layout

```
minimal_score_pubsub/
├── datatype.h / datatype.cpp   # MotorAngle struct + MotorAngleInterface/Proxy/Skeleton
├── publisher.cpp               # Service skeleton: offers and sends samples
├── subscriber.cpp              # Service proxy: finds, subscribes, receives samples
├── etc/
│   └── mw_com_config.json      # Service instance manifest (SHM binding, event slots)
└── BUILD                       # Bazel build targets
```

## Prerequisites

- [Bazel](https://bazel.build/) (tested with 8.x)
- C++17-capable compiler (GCC or Clang)
- Linux host (shared memory IPC)

## Setup

### 1. Clone the middleware

```bash
git clone https://github.com/eclipse-score/communication.git
```

### 2. Clone this repo (as a sibling)

```bash
git clone <url-of-this-repo> minimal_score_pubsub_cmake
```

Your directory layout should look like:
```
repos/
├── communication/        ← Eclipse S-CORE middleware (Bazel)
└── minimal_score_pubsub_cmake/   ← this repo (CMake app)
```

## Build

### Step 1 — Install the middleware sysroot (once)

From inside `minimal_score_pubsub_cmake/`:

```bash
./install_sysroot.sh
```

This will:
- Build `//score/mw/com` via Bazel inside `../communication` (~490 targets, cached on repeat)
- Pack all middleware objects into `sysroot/lib/libmw_com.a`
- Install all headers to `sysroot/include/`
- Generate `sysroot/lib/cmake/MwCom/MwComConfig.cmake`

If your communication repo is in a non-default location:
```bash
./install_sysroot.sh /path/to/communication [/path/to/sysroot]
```

### Step 2 — Build the example with CMake

```bash
mkdir build && cd build
cmake -DCMAKE_PREFIX_PATH="$(pwd)/../sysroot" ..
make -j$(nproc)
```

Binaries are placed in `build/`:
```
build/publisher
build/subscriber
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
