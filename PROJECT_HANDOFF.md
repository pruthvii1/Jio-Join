# JioJoin project handoff

This directory is the clean continuation point for the independent JioFiberVoice client.
The former working copy at `/Users/codetorso/Desktop/cracking/JioJoinMac` was preserved as
a backup; development should continue from `/Users/codetorso/Desktop/jioJoin`.

## What was carried forward

- SwiftUI macOS application source, tests, app metadata, icon, and entitlements.
- Native `jiojoin_engine.c` PJSIP command engine.
- Reviewed Jio interoperability patch for official PJSIP 2.17 and pinned-upstream build script.
- Packaging and offline verification scripts.
- Router provisioning, Keychain storage, call history, notifications, menu-bar UI,
  launch-at-login, missed-call indicator, and hold/resume.
- GPL license, upstream provenance, and research notes.

The experimental Python AgentBridge, Hindi agent, soundboard, recording code, tests,
and former macOS integration source were moved out of the calling client to
`/Users/codetorso/Desktop/cracking/JioJoin-AgentBridge`. They are not built or packaged
with this project.

Generated files were intentionally not copied: `.build`, `dist`, the large `vendor`
checkout, Python caches, logs, packet captures, and credentials. `Scripts/build.sh` clones
the pinned official PJSIP 2.17 revision and reapplies the reviewed patch when needed.

## Architecture

```text
SwiftUI app
  -> EngineManager text commands and JSON events
  -> native jiojoin-engine / upstream PJSIP 2.17 plus reviewed Jio patch
  -> SIP over TLS plus RTP/AMR
  -> subscriber's JioFiber router and Jio IMS
```

Router authorization is a separate local HTTPS/OTP flow implemented by
`RouterProvisioner.swift`. SIP credentials are stored in the macOS Keychain and must not
be printed, committed, or placed in issue reports.

## Build and verification

```sh
cd "/Users/codetorso/Desktop/jioJoin"
./Scripts/build.sh
./Scripts/verify.sh
open "dist/JioJoin for Mac.app"
```

The graphical build currently targets Apple-silicon macOS. Headless engine protocol 1
is implemented as a versioned stdin/JSON process boundary, with Linux build and packaging
scripts plus compile-time Windows support. Future Linux and Windows native interfaces
should remain thin controllers over this engine and provide platform adapters for secure
storage, notifications, startup and recovery. A pure browser app is best treated as a
UI/controller over a native local engine, because ordinary browsers cannot directly
provide reliable SIP/RTP/AMR and background incoming calls.

The Linux engine has been built and executed in an Ubuntu 24.04 ARM64 VM. Its protocol,
TLS, AMR-NB, AMR-WB, and packaging checks passed. No live Linux registration or call has
yet been performed, and the VM had no physical audio device; keep that boundary explicit.

## Current evidence boundary

The macOS UI, native engine self-tests, packaging, notifications, history, and automatic
registration path have been exercised on this Mac. Revalidate a short consenting
end-to-end call before claiming release-quality interoperability, audio reliability, or
background incoming-call behavior. Router firmware and Jio service behavior may differ.

## Licensing and publication

The project is GPL-2.0-only and links the GPL build of upstream PJSIP. Review
`LICENSE.md` and `RESEARCH.md` before publication. Do not copy code from the unlicensed
JioFiber bridge sources; they were used only as public behavioral corroboration.
