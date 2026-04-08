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
cd communication
```

### 2. Clone this example into the workspace

```bash
cd score/mw/com/example
git clone <url-of-this-repo> minimal_score_pubsub
cd ../../../..   # back to communication/
```

## Build

### Step 1 — Build the middleware (once, results are cached)

```bash
bazel build //score/mw/com
```

This compiles ~490 targets. Subsequent builds reuse the cache and finish in seconds.

### Step 2 — Build the example

```bash
bazel build //score/mw/com/example/minimal_score_pubsub/...
```

Only ~21 targets compile (your source files + linking). Binaries are placed under `bazel-bin/`:

```
bazel-bin/score/mw/com/example/minimal_score_pubsub/publisher
bazel-bin/score/mw/com/example/minimal_score_pubsub/subscriber
```

## Run

Open two terminals from the `communication/` directory.

**Terminal 1 — Publisher:**

```bash
bazel-bin/score/mw/com/example/minimal_score_pubsub/publisher \
    score/mw/com/example/minimal_score_pubsub/etc/mw_com_config.json
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
bazel-bin/score/mw/com/example/minimal_score_pubsub/subscriber \
    score/mw/com/example/minimal_score_pubsub/etc/mw_com_config.json
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
| Config | `instanceSpecifier: score/cp60/MapApiLanesStamped`, `serviceId: 6432`, `eventId: 3` |
