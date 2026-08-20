# JioJoin Desktop

An independent desktop client for authorized JioFiberVoice calls on the local JioFiber
network. It includes graphical controllers for Apple-silicon macOS, Linux Mint/Ubuntu
x86_64, and Windows 11 x86_64 over the same native engine boundary. It does not tether
to an Android phone, run an Android emulator, or require Asterisk/VPS infrastructure.

The primary product is deliberately calling-only. Experimental AI, soundboard,
transcription, and recording features are maintained separately and are not included in
the application, native engine, or release bundle.

This is an interoperability prototype, not an official Jio application. The app bundle is built and offline-verified, but live Jio registration and a real call have deliberately not been attempted without the subscriber's explicit approval. Treat live interoperability as unverified until those tests pass.

## What is implemented

- Minimal native SwiftUI interface inspired by the structure of iPhone's Phone app, with dedicated Keypad, Recents, and Settings areas.
- Menu-bar-first operation: closing the window keeps JioJoin connected in the macOS menu bar, and the app does not occupy the Dock.
- Native Launch at Login support is enabled by default and can be changed independently from JioFiberVoice auto-registration in Settings.
- A small unread dot appears on the menu-bar icon after a missed call and clears when Recents is opened.
- Automatic registration when the app opens after one-time Keychain authorization, with a Settings toggle and manual reconnect control.
- Persistent on-device history for incoming, outgoing, missed, declined, completed, and failed calls (up to 500 entries).
- Native macOS incoming-call and missed-call notifications, including foreground banners, sounds, and direct **Answer** / **Decline** actions when permission is granted.
- One-time OTP authorization, dialing, incoming-call answer/reject, and hangup.
- Direct local provisioning against the router's HTTPS service on port 8443, using an ephemeral cookie session and the documented `wifi` authorization flow.
- Credentials stored in macOS Keychain with the this-device-only accessibility class. Credentials are never shown in the UI, command-line arguments, or app activity log.
- Native arm64 calling engine based on upstream PJSIP 2.17 plus a small reviewed Jio interoperability patch, using TLS signaling, SIP digest authentication, RFC 5626 device identity, the Jio access-network header on every outbound SIP request, RTP, CoreAudio, AMR-NB, and AMR-WB.
- Explicit safety boundaries: OTP is sent only by clicking **Request OTP**; automatic registration uses only an existing Keychain authorization and can be disabled; a call starts only by clicking **Call** or **Answer**.
- Incoming calls can be received while the app is running and successfully registered. There is no FCM/APNs push wake-up, so a quit app cannot receive a call.

## Build and open

Requirements: Apple-silicon Mac, macOS 13 or newer, Xcode command-line tools, and Homebrew.

```sh
cd "/Users/codetorso/Desktop/jioJoin"
./Scripts/build.sh
open "dist/JioJoin for Mac.app"
```

The built bundle is `dist/JioJoin for Mac.app`. It is a menu-bar app, so use the phone icon in the top-right of the macOS menu bar to reopen its window or quit. It is ad-hoc signed for local testing, not Developer-ID signed or notarized. If Gatekeeper blocks the first launch, use Finder's **Open** command from the context menu. Do not bypass system security globally.

## Portable headless engine

Engine protocol 1 / engine 0.8.0 adds an explicit `HELLO` capability handshake and
portable macOS, Linux and Windows compile-time boundaries while retaining the Mac app's
existing stdin/JSON contract. The Linux build instructions are in
`docs/LINUX_HEADLESS.md`; the complete controller contract is in
`docs/ENGINE_PROTOCOL.md`.

On Apple silicon, build only the headless engine with:

```sh
./Scripts/build-engine-macos.sh
./Scripts/test-engine-protocol.sh ./build/headless/macos-arm64/jiojoin-engine
```

The Linux engine has also been built and executed natively in an Ubuntu 24.04 ARM64 VM.
Its protocol test passed, TLS initialized, and AMR-NB/AMR-WB were available. That VM had
no physical audio device, and no Linux Jio registration or call was attempted, so this is
a runtime/toolchain validation rather than a Linux interoperability claim. The checked-in
Ubuntu workflow produces the intended x86-64 release build.

Linux includes a dependency-minimal local controller at `linux/jiojoin_controller.py`
and a Python/Tk desktop UI at `linux/jiojoin_desktop.py`.
It performs the router OTP flow, keeps provisioned credentials in memory, negotiates
engine protocol 1 before registration, and provides calling controls over private stdio.
See `docs/LINUX_HEADLESS.md` for authorization and test commands.

Windows 11 uses the native PowerShell/WPF controller in `windows/JioJoinDesktop.ps1`.
`Scripts/build-engine-windows.sh` performs a real MSYS2 MinGW64 build of the same pinned
PJSIP source, and the Windows CI workflow runs protocol, TLS, AMR, and packaging checks.
Live Windows registration and calls remain explicitly unverified until tested on the
subscriber's Windows hardware.

Version 0.7.0 routes only the local provisioning exchange through macOS's system cURL because URLSession rejects some Jio router self-signed certificates before its trust delegate runs. The connection remains HTTPS, is pinned by name to the private default gateway, and sends query data through standard input so OTPs never appear in a process listing.

The 0.7 reliability supervisor adds native heartbeat/status reconciliation, bounded registration retries with jitter, network-path recovery, call operation timeouts, and a locally exported diagnostic report that redacts credentials and telephone identities. Manual disconnect remains authoritative, and registration is never restarted during an active call.

## Authorized live test sequence

1. Connect the Mac directly to the subscriber's own JioFiber Wi-Fi/LAN.
2. Open the app. Leave the default router name `jiofiber.local.html`; it preserves the expected TLS name. Use the private router address only if local DNS does not resolve it.
3. Keep the generated stable device name. Click **Request OTP** once. This asks the router to whitelist this Mac and sends an SMS to the line's registered mobile number.
4. Enter that OTP and click **Verify and save to Keychain**.
5. The app refreshes the rotating local SIP password and registers automatically. You can disable this under **Settings → Account & registration** or use **Register now** to reconnect manually.
6. Confirm the status becomes **Registered on JioFiber** before attempting an outgoing call. Use a number belonging to the subscriber or a consenting test recipient.

**Forget authorization** removes the local Keychain item, but it does not de-whitelist the device on the router. Router-side removal is intentionally not automated.

## Verification performed without live Jio actions

`Scripts/verify.sh` checks the unit tests, bundle signature, property list, idle engine contract, native TLS initialization, CoreAudio enumeration, both AMR codecs, and absence of Homebrew paths in the packaged engine.

Current verified result on this Mac:

- Swift unit tests: 16 passed, 0 failed.
- UI launch smoke test: passed; 0 network sockets while idle.
- Native self-test: arm64, TLS available, AMR-NB available, AMR-WB available, 6 CoreAudio devices enumerated.
- Bundle: strict deep code-sign verification passed; only the five required third-party dylibs are loaded from `Contents/Frameworks`.

The self-test opens only an ephemeral local TLS listener and uses a null audio device. It does not provision, register, or call.

## Known boundaries

- Live `200 OK` registration through this subscriber's router is not yet verified.
- Outgoing audio, incoming call routing, long-call AMR stability, PRACK/100rel behavior, DTMF, and simultaneous phone/Mac registration are not yet verified.
- Voice calling is implemented; video and conference calling are not.
- macOS targets arm64; Linux and Windows target x86_64.
- Router implementations and Jio service behavior may vary by model, region, firmware, and Fiber versus AirFiber.
- If live registration fails, collect only redacted status codes and headers. Never paste SIP passwords, authorization headers, XML configuration, OTPs, or reusable tokens into issues or chat.

## Source and provenance

The native foundation is official [`pjsip/pjproject`](https://github.com/pjsip/pjproject) 2.17, pinned at commit `5a457451fa2712ba18e12b01738e8ff3af2b26fd`. The small, reversible local patch adds Jio-compatible AMR mode negotiation, applies the device instance parameter consistently without repeated accumulation, and builds `jiojoin_engine` as a PJSIP sample. The JFC GPL fork remains cited as interoperability evidence, not as the vendored runtime.

No source was copied from the unlicensed `jiofiber-bridge` repository. Its public documentation helped corroborate current runtime behavior; this implementation was written independently against upstream GPL PJSIP and public protocol descriptions. See `RESEARCH.md` for the source audit.

The project is GPL-2.0-only. See `LICENSE.md` and the bundled license files before redistribution.
