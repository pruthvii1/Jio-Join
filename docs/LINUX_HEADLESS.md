# Linux headless engine

The first Linux target is x86-64 Ubuntu with ALSA. PipeWire and PulseAudio installations
normally expose an ALSA compatibility device, so the engine does not need to link a
second audio framework. Native PipeWire selection can be added only if testing shows the
compatibility path is inadequate.

## Build dependencies

On Ubuntu/Debian:

```sh
sudo apt-get update
sudo apt-get install -y \
  build-essential git pkg-config libssl-dev libasound2-dev \
  libopencore-amrnb-dev libopencore-amrwb-dev libvo-amrwbenc-dev
```

Build and run the offline protocol checks (the architecture directory follows the build
host, for example `linux-x86_64` or `linux-aarch64`):

```sh
./Scripts/build-engine-linux.sh
./Scripts/test-engine-protocol.sh ./build/headless/linux-$(uname -m)/jiojoin-engine
```

Create the GitHub-release archive:

```sh
./Scripts/package-engine-linux.sh
```

The resulting executable is a headless engine, not a shell that stores credentials.
Use a private parent process to feed its stdin. Do not paste a `START` command into an
interactive terminal because base64-encoded SIP passwords remain reusable secrets.

## Audio selection

By default PJSIP uses the system default capture and playback devices. A controller can
set both of these environment variables before launching the engine:

```text
JIOJOIN_CAPTURE_DEVICE
JIOJOIN_PLAYBACK_DEVICE
```

Both exact device names are required when either override is set. `--audio-device-test`
opens those devices without registering to Jio.

## Current boundary

The engine was compiled and executed natively in an Ubuntu 24.04 ARM64 VM. The stdin/JSON
protocol test passed; the native self-test initialized OpenSSL/TLS and reported both
AMR-NB and AMR-WB. The headless VM correctly reported zero physical audio devices and
used PJSIP's null-audio path for the self-test. The release archive is dynamically linked
to the standard Ubuntu OpenSSL, ALSA, and AMR packages listed above.

This validates the Linux compiler, runtime, protocol, codec, and packaging paths. It does
not prove Jio interoperability on Linux. A real registration, audio-device test, and
consenting call must still be performed from a Linux desktop on the subscriber's own
JioFiber LAN before that claim is made. The checked-in Ubuntu x86-64 CI job remains the
reproducible gate for the primary release architecture.
