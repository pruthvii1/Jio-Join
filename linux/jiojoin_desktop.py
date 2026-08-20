#!/usr/bin/env python3
"""Dependency-minimal Tk desktop controller for JioJoin on Linux."""

from __future__ import annotations

import fcntl
import os
from pathlib import Path
import queue
import random
import json
import subprocess
import threading
import tkinter as tk
from tkinter import messagebox, ttk

from jiojoin_controller import (
    AuthorizationRequired, ControllerError, EngineClient, RouterSession,
    default_engine, encode_field, load_or_create_alias, local_address,
    normalize_number,
)


class SingleInstance:
    def __init__(self) -> None:
        runtime = Path(os.environ.get("XDG_RUNTIME_DIR", f"/tmp/jiojoin-{os.getuid()}"))
        runtime.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.handle = (runtime / "desktop.lock").open("w", encoding="ascii")
        try:
            fcntl.flock(self.handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ControllerError("JioJoin Desktop is already running.") from error


def audio_devices(kind: str) -> list[str]:
    command = [str(default_engine()), "--list-audio"]
    try:
        output = subprocess.run(command, text=True, capture_output=True, timeout=8, check=True).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    devices = []
    for line in output.splitlines():
        try: event = json.loads(line)
        except json.JSONDecodeError: continue
        if event.get("event") == "audio-device-option" and event.get(kind) is True:
            devices.append(str(event.get("message")))
    return devices


class Desktop(tk.Tk):
    def __init__(self) -> None:
        super().__init__()
        self.title("JioJoin Desktop")
        self.geometry("520x690")
        self.minsize(460, 620)
        self.protocol("WM_DELETE_WINDOW", self.close)
        self.events: queue.Queue[tuple[str, object]] = queue.Queue()
        self.client: EngineClient | None = None
        self.session: RouterSession | None = None
        self.credentials = None
        self.in_call = False
        self.held = False
        self.connection_generation = 0
        self.status = tk.StringVar(value="Offline")
        self.detail = tk.StringVar(value="Disconnected by user")
        self.number = tk.StringVar()
        self.otp = tk.StringVar()
        self.router = tk.StringVar(value="jiofiber.local.html")
        self.capture = tk.StringVar()
        self.playback = tk.StringVar()
        self._build()
        self.after(100, self._drain)

    def _build(self) -> None:
        root = ttk.Frame(self, padding=20)
        root.pack(fill="both", expand=True)
        ttk.Label(root, text="JioJoin", font=("Sans", 24, "bold")).pack(anchor="w")
        status = ttk.Frame(root, padding=14)
        status.pack(fill="x", pady=(14, 18))
        ttk.Label(status, textvariable=self.status, font=("Sans", 15, "bold")).pack(anchor="w")
        ttk.Label(status, textvariable=self.detail, wraplength=430).pack(anchor="w", pady=(3, 0))

        setup = ttk.LabelFrame(root, text="Connection", padding=12)
        setup.pack(fill="x")
        ttk.Entry(setup, textvariable=self.router).pack(fill="x")
        buttons = ttk.Frame(setup); buttons.pack(fill="x", pady=(8, 0))
        ttk.Button(buttons, text="Connect", command=self.connect).pack(side="left")
        ttk.Button(buttons, text="Request OTP", command=self.request_otp).pack(side="left", padx=6)
        ttk.Entry(buttons, textvariable=self.otp, show="•", width=10).pack(side="left")
        ttk.Button(buttons, text="Verify", command=self.verify_otp).pack(side="left", padx=6)
        ttk.Button(buttons, text="Disconnect", command=self.disconnect).pack(side="right")

        call = ttk.LabelFrame(root, text="Call", padding=12)
        call.pack(fill="x", pady=14)
        ttk.Entry(call, textvariable=self.number, font=("Sans", 18), justify="center").pack(fill="x")
        keypad = ttk.Frame(call); keypad.pack(pady=8)
        for i, value in enumerate("123456789*0#"):
            ttk.Button(keypad, text=value, width=6,
                       command=lambda digit=value: self.number.set(self.number.get() + digit)).grid(row=i // 3, column=i % 3, padx=3, pady=3)
        actions = ttk.Frame(call); actions.pack(fill="x", pady=(5, 0))
        for label, command in (("Call", self.dial), ("Answer", lambda: self.command("ANSWER")),
                               ("Reject", lambda: self.command("REJECT")), ("Hang up", lambda: self.command("HANGUP")),
                               ("Hold / Resume", self.toggle_hold)):
            ttk.Button(actions, text=label, command=command).pack(side="left", expand=True, padx=2)

        audio = ttk.LabelFrame(root, text="Audio devices (applies on reconnect)", padding=12)
        audio.pack(fill="x")
        captures, playbacks = audio_devices("capture"), audio_devices("playback")
        ttk.Label(audio, text="Microphone").grid(row=0, column=0, sticky="w")
        ttk.Combobox(audio, textvariable=self.capture, values=captures, state="readonly").grid(row=0, column=1, sticky="ew")
        ttk.Label(audio, text="Speaker").grid(row=1, column=0, sticky="w")
        ttk.Combobox(audio, textvariable=self.playback, values=playbacks, state="readonly").grid(row=1, column=1, sticky="ew")
        audio.columnconfigure(1, weight=1)

        diag = ttk.LabelFrame(root, text="Redacted diagnostics", padding=8)
        diag.pack(fill="both", expand=True, pady=(14, 0))
        self.log = tk.Text(diag, height=7, state="disabled", wrap="word")
        self.log.pack(fill="both", expand=True)

    def background(self, operation) -> None:
        def run():
            try: operation()
            except Exception as error: self.events.put(("error", error))
        threading.Thread(target=run, daemon=True).start()

    def _session(self) -> RouterSession:
        if self.session is None:
            self.session = RouterSession(self.router.get().strip(), load_or_create_alias())
        return self.session

    def connect(self) -> None:
        self.connection_generation += 1
        generation = self.connection_generation
        self.status.set("Connecting")
        self.detail.set("Refreshing local authorization")
        def work():
            delays = (0.0, 1.5, 4.0, 9.0)
            last_error = None
            for attempt, delay in enumerate(delays):
                if generation != self.connection_generation: return
                if delay: threading.Event().wait(delay + random.uniform(0, delay * 0.2))
                try:
                    credentials = self._session().refresh()
                    self._start(credentials)
                    return
                except AuthorizationRequired: raise
                except ControllerError as error:
                    last_error = error
                    self.events.put(("retry", (attempt + 1, len(delays), str(error))))
            raise last_error or ControllerError("Connection failed.")
        self.background(work)

    def request_otp(self) -> None:
        self.status.set("Authorization required")
        self.detail.set("Requesting an OTP from your JioFiber router")
        def work():
            credentials = self._session().request_otp()
            self.events.put(("otp-requested", credentials))
        self.background(work)

    def verify_otp(self) -> None:
        otp = self.otp.get(); self.otp.set("")
        self.background(lambda: self._start(self._session().verify_otp(otp)))

    def _start(self, credentials) -> None:
        self._stop_client()
        capture = self.capture.get() or None; playback = self.playback.get() or None
        if bool(capture) != bool(playback):
            raise ControllerError("Choose both microphone and speaker, or leave both on system defaults.")
        client = EngineClient(default_engine(), lambda event: self.events.put(("engine", event)), capture, playback)
        try:
            client.launch()
            client.register(credentials, local_address(self._session().connect_ip))
        except Exception:
            client.close()
            raise
        self.client = client
        self.credentials = credentials

    def command(self, value: str) -> None:
        try:
            if not self.client: raise ControllerError("Connect to JioFiber before using call controls.")
            self.client.send(value)
        except ControllerError as error: self._error(error)

    def dial(self) -> None:
        try: self.command("DIAL\t" + encode_field(normalize_number(self.number.get())))
        except ControllerError as error: self._error(error)

    def toggle_hold(self) -> None:
        self.command("RESUME" if self.held else "HOLD")

    def disconnect(self) -> None:
        self.connection_generation += 1
        self._stop_client()
        self.events.put(("offline", None))

    def _stop_client(self) -> None:
        if self.client: self.client.close()
        self.client = None; self.credentials = None; self.in_call = False; self.held = False

    def _drain(self) -> None:
        while True:
            try: kind, value = self.events.get_nowait()
            except queue.Empty: break
            if kind == "error": self._error(value)
            elif kind == "offline": self.status.set("Offline"); self.detail.set("Disconnected by user")
            elif kind == "otp-requested":
                if value is None:
                    self.status.set("Enter OTP"); self.detail.set("Check the SMS sent to the account holder")
                else: self.background(lambda value=value: self._start(value))
            elif kind == "retry":
                attempt, total, reason = value
                self.status.set("Reconnecting")
                self.detail.set(f"Attempt {attempt} of {total}: {reason}")
            elif kind == "engine": self._engine_event(value)
        self.after(100, self._drain)

    def _engine_event(self, event: dict) -> None:
        name, code = event.get("event"), event.get("code")
        message = str(event.get("message", name))
        if name == "registered": self.status.set("Ready for calls"); self.detail.set("Registered on JioFiber (SIP 200)")
        elif name == "registration":
            self.status.set("Connection failed" if isinstance(code, int) and code >= 300 else "Connecting")
            self.detail.set(f"SIP {code}: {message}")
        elif name == "incoming": self.status.set("Incoming call"); self.detail.set("Answer or reject")
        elif name in {"dialing", "call-state", "media", "held", "resumed", "remote-held"}:
            self.status.set("Call on hold" if name in {"held", "remote-held"} else "Call active")
            self.detail.set(message); self.held = name == "held"
        elif name == "error": self.status.set("Engine error"); self.detail.set(f"{message} ({code})")
        if name not in {"hello", "pong", "status"}: self._append(f"{name}: {message} [{code}]")

    def _append(self, line: str) -> None:
        self.log.configure(state="normal"); self.log.insert("end", line + "\n"); self.log.see("end"); self.log.configure(state="disabled")

    def _error(self, error) -> None:
        if isinstance(error, AuthorizationRequired):
            self.status.set("Authorization required"); self.detail.set(str(error))
        else:
            self.status.set("Connection failed"); self.detail.set(str(error)); self._append(f"controller: {error}")

    def close(self) -> None:
        self.disconnect(); self.destroy()


def main() -> int:
    try: lock = SingleInstance()
    except ControllerError as error:
        messagebox.showerror("JioJoin Desktop", str(error)); return 2
    app = Desktop(); app._instance_lock = lock; app.mainloop(); return 0


if __name__ == "__main__":
    raise SystemExit(main())
