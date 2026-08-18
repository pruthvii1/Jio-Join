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

The archive contains `jiojoin-engine`, the CLI controller, the Tk desktop interface, and
install/uninstall scripts. The controllers use only Python 3's standard library, Tk, and
the system `curl` executable. They own local router OTP
authorization and feeds credentials to the engine through an anonymous stdin pipe. It
does not save SIP credentials, cookies, or OTPs to disk.

Extract the archive, then install it with `sudo ./install.sh`. The launcher appears as
**JioJoin Desktop**. `sudo ./uninstall.sh` removes application files but deliberately
preserves the non-secret per-user device alias.

Do not paste a `START` command into an interactive terminal because base64-encoded SIP
passwords remain reusable secrets.

## Authorize and run

First verify the engine can open the selected physical devices:

```sh
./build/headless/linux-$(uname -m)/jiojoin-engine --audio-device-test
```

Then explicitly request the router OTP and authorize this Linux device:

```sh
./linux/jiojoin_controller.py authorize \
  --engine ./build/headless/linux-$(uname -m)/jiojoin-engine
```

OTP entry is hidden. The controller saves only a generated non-secret device alias under
`$XDG_CONFIG_HOME/jiojoin/device.json` (or `~/.config/jiojoin/device.json`) with mode
`0600`. Provisioned SIP credentials remain in memory and are sent only through the
private engine pipe. On later starts, refresh the already authorized device with:

```sh
./linux/jiojoin_controller.py run \
  --engine ./build/headless/linux-$(uname -m)/jiojoin-engine
```

Interactive calling commands are `status`, `dial NUMBER`, `answer`, `reject`, `hangup`,
`hold`, `resume`, and `quit`. PJSIP diagnostics are discarded by default because they can
contain private call metadata.

## Audio selection

By default PJSIP uses the system default capture and playback devices. A controller can
set both of these environment variables before launching the engine:

```text
JIOJOIN_CAPTURE_DEVICE
JIOJOIN_PLAYBACK_DEVICE
```

Both exact device names are required when either override is set. `--audio-device-test`
opens those devices without registering to Jio.
The desktop UI obtains exact native PJSIP names from `--list-audio` and applies the pair
on the next connection.

## Current boundary

The engine was compiled and executed natively in an Ubuntu 24.04 ARM64 VM. The stdin/JSON
protocol test passed; the native self-test initialized OpenSSL/TLS and reported both
AMR-NB and AMR-WB. The headless VM correctly reported zero physical audio devices and
used PJSIP's null-audio path for the self-test. The release archive is dynamically linked
to the standard Ubuntu OpenSSL, ALSA, and AMR packages listed above.

Linux Mint 22 on x86-64 has also passed the protocol, TLS, AMR-NB/AMR-WB, packaging, and
physical capture/playback device tests. This validates the Linux compiler, runtime,
protocol, codec, audio-open, controller, and packaging paths. It does not yet prove Jio
interoperability on Linux. A real registration and consenting two-way call must still
pass on the subscriber's own JioFiber LAN before that claim is made. The checked-in
Ubuntu x86-64 CI job remains the reproducible release gate.
