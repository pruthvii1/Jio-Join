# JioJoin headless engine protocol

Protocol version: **1**
Engine version: **0.8.0**

`jiojoin-engine` is a UI-independent PJSIP process. A desktop controller starts it with
private stdin/stdout pipes, sends one command per line, and reads one JSON event per
stdout line. PJSIP logs go to stderr and must not be treated as protocol output.

The engine performs SIP registration, call control, RTP and system-audio routing. The
controller owns router provisioning, secure credential storage, network monitoring,
timeouts, recovery policy, history, notifications and user consent.

## Startup and negotiation

The engine emits `hello`, then `engine`, immediately after startup. Controllers must
require protocol `1` before sending credentials.

```json
{"event":"hello","message":"JioJoin headless engine","code":0,"protocol":1,"engine_version":"0.8.0","platform":"linux","architecture":"x86_64","audio_backend":"ALSA/PipeWire","commands":"HELLO,START,PING,STATUS,DIAL,ANSWER,REJECT,HANGUP,HOLD,RESUME,QUIT"}
{"event":"engine","message":"Ready; no network registration has started","code":0}
```

`HELLO` can be sent again at any time and `--version` prints the same JSON object without
starting the command loop. `--list-audio` emits one `audio-device-option` JSON event per
native device, including `capture` and `playback` booleans, without registering.

## Commands

Commands are tab-separated. Text fields use standard base64 so tabs and newlines cannot
change the command boundary.

| Command | Fields | Effect |
|---|---:|---|
| `HELLO` | 0 | Report protocol and platform capabilities. |
| `PING` | 0 | Return `pong`; no SIP action. |
| `STATUS` | 0 | Return authoritative registration and active-call booleans. |
| `START` | 8 | Start or safely replace SIP registration. |
| `DIAL` | 1 | Dial a normalized telephone number. |
| `ANSWER` | 0 | Answer the current incoming call. |
| `REJECT` | 0 | Decline the current incoming call. |
| `HANGUP` | 0 | End the active call. |
| `HOLD` | 0 | Place the connected call on hold. |
| `RESUME` | 0 | Resume a locally held call. |
| `QUIT` | 0 | Destroy PJSIP cleanly and exit. |

`START` fields, in order, are `public_id`, `auth_user`, `password`, `realm`, `registrar`,
`instance_id`, `local_ip`, and `pani`. Every field is base64-encoded independently.
`DIAL` contains one base64-encoded normalized number.

Base64 is framing, not encryption. The controller must use anonymous pipes, must never
put `START` in argv, shell history or logs, and must never expose the engine socket or
stdio bridge to other users or the network.

## Events

Every event has `event`; normal events also provide `message` and integer `code`.
Failures provide `operation` when a specific native operation failed. Stable event names:

- `hello`, `engine`, `pong`, `status`
- `registered`, `registration`
- `incoming`, `dialing`, `call-state`
- `media`, `audio-device`, `audio-device-option`, `held`, `resumed`, `remote-held`
- `error`, `self-test`

Unknown JSON fields must be ignored for forward compatibility. Controllers must use
`call-state` containing `CONFIRMED` as the connected boundary and `DISCON` as the terminal
boundary. `STATUS` is authoritative when an event was missed.

## Reliability contract

- Send `PING` every 10 seconds and allow 8 seconds for `pong`.
- Request `STATUS` periodically and after a delayed call operation.
- Allow 30 seconds for registration, 45 seconds for dialing, 20 seconds after answering,
  and 10 seconds for hangup confirmation.
- Refresh the authorized router configuration before a registration retry.
- Use bounded backoff with jitter; do not busy-loop.
- Never replace registration during a healthy active call.
- A user-requested disconnect must suppress automatic recovery.

These values match the macOS v0.7 supervisor and are part of the desktop-client behavior,
not hard-coded policy inside the media engine.

## Offline checks

`--self-test` initializes PJSIP, TLS, AMR-NB, AMR-WB and audio enumeration without Jio
registration. `Scripts/test-engine-protocol.sh` checks negotiation, heartbeat, status,
unknown-command handling and command-line error behavior without making network calls.
