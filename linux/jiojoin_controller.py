#!/usr/bin/env python3
"""Local Linux provisioning and call controller for JioJoin Desktop.

The controller deliberately keeps SIP credentials in memory only. Router requests are
passed to curl through stdin so OTPs, cookies, and provisioned values never appear in
argv, shell history, or controller output.

SPDX-License-Identifier: GPL-2.0-only
"""

from __future__ import annotations

import argparse
import base64
import getpass
import ipaddress
import json
import os
from pathlib import Path
import queue
import re
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from typing import Iterable
from urllib.parse import urlencode
import uuid
import xml.etree.ElementTree as ET


PROTOCOL_VERSION = 1
DEFAULT_ROUTER = "jiofiber.local.html"
ROUTER_SERVICE_HOST = "jiofiber.local.html"
ROUTER_PORT = 8443
ALIAS_PATTERN = re.compile(r"^[A-Za-z0-9._-]{1,48}$")


class ControllerError(RuntimeError):
    pass


class AuthorizationRequired(ControllerError):
    pass


@dataclass(frozen=True)
class SIPCredentials:
    public_id: str
    auth_user: str
    password: str
    realm: str
    registrar: str
    instance_id: str
    pani: str


@dataclass(frozen=True)
class ProvisioningValue:
    path: tuple[str, ...]
    name: str
    value: str


def is_private_router(host: str) -> bool:
    if host == ROUTER_SERVICE_HOST:
        return True
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        return False
    return address.version == 4 and (address.is_private or address.is_link_local)


def device_hash(alias: str) -> int:
    value = 0
    for byte in alias.encode("utf-8"):
        value = ((value * 33) + byte) & 0xFFFFFFFF
    return value


def device_mac(alias: str) -> str:
    value = device_hash(alias)
    octets = [0, 0, value & 0xFF, (value >> 8) & 0xFF,
              (value >> 16) & 0xFF, (value >> 24) & 0xFF]
    return ":".join(f"{octet:02x}" for octet in octets)


def instance_id(mac: str) -> str:
    return f"<00000000-0000-1000-8000-{mac.replace(':', '').upper()}>"


def normalize_number(raw: str) -> str:
    cleaned = "".join(character for character in raw if character.isdigit() or character == "+")
    if not cleaned or any(not character.isdigit() for character in cleaned[1:]):
        raise ControllerError("Enter a valid telephone number.")
    if cleaned.startswith("+91") and len(cleaned) == 13:
        return "0" + cleaned[3:]
    if len(cleaned) == 10 and cleaned[0] in "6789":
        return "0" + cleaned
    if cleaned.startswith("+"):
        return cleaned[1:]
    return cleaned


def default_gateway() -> str:
    try:
        with open("/proc/net/route", "r", encoding="ascii") as routes:
            next(routes, None)
            for line in routes:
                fields = line.split()
                if len(fields) >= 4 and fields[1] == "00000000" and int(fields[3], 16) & 2:
                    return socket.inet_ntoa(struct.pack("<L", int(fields[2], 16)))
    except (OSError, ValueError):
        pass
    raise ControllerError("Could not determine the private default gateway.")


def local_address(connect_ip: str) -> str:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
            probe.connect((connect_ip, 9))
            address = probe.getsockname()[0]
    except OSError as error:
        raise ControllerError("Could not determine the LAN address used for JioFiber.") from error
    if not is_private_router(address):
        raise ControllerError("The selected route does not use a private LAN address.")
    return address


def config_path() -> Path:
    base = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    return base / "jiojoin" / "device.json"


def load_or_create_alias(override: str | None = None) -> str:
    path = config_path()
    if override is not None:
        if not ALIAS_PATTERN.fullmatch(override):
            raise ControllerError("Device alias must use 1-48 letters, numbers, dots, dashes, or underscores.")
        alias = override
    elif path.exists():
        if path.is_symlink():
            raise ControllerError("Refusing a symbolic-link device configuration.")
        try:
            alias = json.loads(path.read_text(encoding="utf-8"))["device_alias"]
        except (OSError, KeyError, TypeError, json.JSONDecodeError) as error:
            raise ControllerError("The local JioJoin device configuration is invalid.") from error
        if not isinstance(alias, str) or not ALIAS_PATTERN.fullmatch(alias):
            raise ControllerError("The saved JioJoin device alias is invalid.")
        return alias
    else:
        alias = f"JioJoinLinux-{uuid.uuid4().hex[:8]}"

    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.exists() and path.is_symlink():
        raise ControllerError("Refusing a symbolic-link device configuration.")
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump({"schema": 1, "device_alias": alias}, output)
            output.write("\n")
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
    return alias


def normalized(value: str) -> str:
    return "".join(character.lower() for character in value if character.isalnum())


class ProvisioningDocument:
    def __init__(self, data: bytes):
        try:
            root = ET.fromstring(data)
        except ET.ParseError as error:
            raise ControllerError("The router returned malformed provisioning XML.") from error
        self.values: list[ProvisioningValue] = []
        self._walk(root, ())

    @staticmethod
    def _tag(element: ET.Element) -> str:
        return element.tag.rsplit("}", 1)[-1].lower()

    @staticmethod
    def _attributes(element: ET.Element) -> dict[str, str]:
        return {name.lower(): value for name, value in element.attrib.items()}

    def _walk(self, element: ET.Element, path: tuple[str, ...]) -> None:
        attributes = self._attributes(element)
        child_path = path
        if self._tag(element) == "characteristic":
            child_path = path + (attributes.get("type", "characteristic"),)
        elif self._tag(element) == "parm" and "name" in attributes and "value" in attributes:
            self.values.append(ProvisioningValue(path, attributes["name"], attributes["value"]))
        for child in element:
            self._walk(child, child_path)

    def value(self, name: str, path_terms: Iterable[str] = ()) -> str | None:
        wanted_name = normalized(name)
        wanted_terms = [normalized(term) for term in path_terms]
        for entry in self.values:
            if normalized(entry.name) != wanted_name:
                continue
            candidate_path = [normalized(component) for component in entry.path]
            if all(any(term in component for component in candidate_path) for term in wanted_terms):
                return entry.value
        return None

    def preferred_proxy(self) -> str | None:
        return (self.value("address", ("lbo", "pcscf"))
                or self.value("lbo_p-cscf_address")
                or next((entry.value for entry in self.values
                         if normalized(entry.name) == "address" and "5068" in entry.value), None)
                or self.value("address"))


def parse_credentials(data: bytes, alias: str) -> SIPCredentials:
    document = ProvisioningDocument(data)

    def required(name: str, description: str) -> str:
        value = document.value(name)
        if not value:
            raise ControllerError(f"Provisioning succeeded but {description} was missing.")
        return value

    realm = required("realm", "the SIP realm")
    password = required("userpwd", "the SIP password")
    public_value = required("public_user_identity", "the public identity")
    public_id = public_value if public_value.lower().startswith("sip:") else f"sip:{public_value}"
    auth_user = document.value("username") or document.value("private_user_identity") or ""
    auth_user = re.sub(r"^sip:", "", auth_user, flags=re.IGNORECASE)
    if not auth_user:
        raise ControllerError("Provisioning succeeded but the authentication identity was missing.")
    address = document.preferred_proxy() or "jiofiber.local.html:5068"
    registrar = address if address.lower().startswith("sip:") else f"sip:{address}"
    if "transport=" not in registrar.lower():
        registrar += ";transport=tls"
    mac = device_mac(alias)
    provisioned_uuid = document.value("uuid_value")
    device_instance = (provisioned_uuid if provisioned_uuid and provisioned_uuid.startswith("<")
                       else f"<{provisioned_uuid}>" if provisioned_uuid else instance_id(mac))
    digits = "".join(character for character in public_id if character.isdigit())
    psap = document.value("psoltid") or f"+{digits}"
    pani = f"GPON;PSAPId={psap if psap.startswith('+') else '+' + psap}"
    return SIPCredentials(public_id, auth_user, password, realm, registrar, device_instance, pani)


BASE_ITEMS = [
    ("terminal_sw_version", "7.1.2"), ("SMS_port", "0"), ("act_type", "volatile"),
    ("IMSI", ""), ("msisdn", ""), ("IMEI", ""), ("vers", "0"), ("token", ""),
    ("rcs_state", "0"), ("rcs_version", "5.1B"), ("rcs_profile", "joyn_blackbird"),
    ("client_vendor", "WITS"), ("default_sms_app", "1"), ("default_vvm_app", "0"),
    ("device_type", "vvm"), ("client_version", "RCSAndrd-5.3"),
    ("provisioning_version", "2.0"), ("nwk_intf", "wifi"),
]


class RouterSession:
    def __init__(self, router: str, alias: str, curl: str | None = None):
        if not is_private_router(router):
            raise ControllerError("The router must be jiofiber.local.html or a private IPv4 address.")
        self.router = router
        self.alias = alias
        self.mac = device_mac(alias)
        self.connect_ip = default_gateway() if router == ROUTER_SERVICE_HOST else router
        if not is_private_router(self.connect_ip):
            raise ControllerError("The Jio router did not resolve to a private gateway.")
        self.cookie: str | None = None
        self.curl = curl or shutil.which("curl") or ""
        if not self.curl:
            raise ControllerError("The system curl executable is required.")

    def account_items(self) -> list[tuple[str, str]]:
        return BASE_ITEMS + [
            ("terminal_vendor", self.alias), ("terminal_model", self.alias),
            ("mac_address", self.mac), ("alias", self.alias), ("op_type", "add"),
        ]

    @staticmethod
    def _curl_escape(value: str) -> str:
        return value.replace("\\", "\\\\").replace('"', '\\"')

    @staticmethod
    def parse_response(raw: bytes) -> tuple[bytes, int, str | None]:
        if len(raw) > 2 * 1024 * 1024:
            raise ControllerError("The Jio router response exceeded the safe size limit.")
        marker = b"\nX-JioJoin-Status: "
        marker_index = raw.rfind(marker)
        if marker_index < 0:
            raise ControllerError("The Jio router returned an unexpected HTTPS response.")
        try:
            status = int(raw[marker_index + len(marker):].strip())
        except ValueError as error:
            raise ControllerError("The Jio router returned an invalid HTTP status.") from error
        response = raw[:marker_index]
        separator = b"\r\n\r\n"
        header_end = response.find(separator)
        if header_end < 0:
            raise ControllerError("The Jio router returned invalid HTTP headers.")
        headers = response[:header_end].decode("iso-8859-1", errors="replace")
        body = response[header_end + len(separator):]
        cookie = None
        for line in headers.split("\r\n"):
            if line.lower().startswith("set-cookie:"):
                cookie = line.split(":", 1)[1].strip().split(";", 1)[0]
                break
        return body, status, cookie

    def request(self, items: list[tuple[str, str]]) -> tuple[bytes, int]:
        url = f"https://{ROUTER_SERVICE_HOST}:{ROUTER_PORT}/?{urlencode(items)}"
        configuration = f'url = "{self._curl_escape(url)}"\nheader = "User-Agent: JioJoinLinux/0.8"\n'
        if self.cookie:
            configuration += f'cookie = "{self._curl_escape(self.cookie)}"\n'
        command = [
            self.curl, "--disable", "--silent", "--show-error", "--insecure", "--http1.1",
            "--noproxy", "*",
            "--connect-timeout", "10", "--max-time", "15",
            "--resolve", f"{ROUTER_SERVICE_HOST}:{ROUTER_PORT}:{self.connect_ip}",
            "--include", "--write-out", "\nX-JioJoin-Status: %{http_code}\n", "--config", "-",
        ]
        try:
            result = subprocess.run(command, input=configuration.encode("utf-8"),
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    check=False, timeout=20)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ControllerError("The private Jio router HTTPS connection failed.") from error
        if result.returncode != 0:
            raise ControllerError(f"The private Jio router HTTPS connection failed (transport {result.returncode}).")
        body, status, received_cookie = self.parse_response(result.stdout)
        if received_cookie:
            self.cookie = received_cookie
        return body, status

    def refresh(self) -> SIPCredentials:
        body, status = self.request(self.account_items())
        if status != 200:
            raise ControllerError(f"The router rejected configuration refresh (HTTP {status}).")
        if not body.strip():
            raise AuthorizationRequired("This Linux device needs router OTP authorization.")
        return parse_credentials(body, self.alias)

    def authorize(self) -> SIPCredentials:
        body, status = self.request(self.account_items())
        if status != 200:
            raise ControllerError(f"The router rejected the OTP request (HTTP {status}).")
        if body.strip():
            try:
                return parse_credentials(body, self.alias)
            except ControllerError:
                pass
        print("OTP requested. Check the SMS sent to the JioFiber account holder.")
        otp = getpass.getpass("OTP (input hidden): ").strip()
        if not otp.isdigit() or not 4 <= len(otp) <= 10:
            raise ControllerError("The OTP must contain 4-10 digits.")
        verify_body, verify_status = self.request([("OTP", otp)])
        otp = ""
        if verify_status != 200:
            raise ControllerError(f"The router rejected the OTP (HTTP {verify_status}).")
        if not verify_body.strip():
            verify_body, refresh_status = self.request(self.account_items())
            if refresh_status != 200:
                raise ControllerError(f"The router rejected configuration retrieval (HTTP {refresh_status}).")
        return parse_credentials(verify_body, self.alias)


def encode_field(value: str) -> str:
    return base64.b64encode(value.encode("utf-8")).decode("ascii")


def start_command(credentials: SIPCredentials, address: str) -> str:
    fields = [credentials.public_id, credentials.auth_user, credentials.password,
              credentials.realm, credentials.registrar, credentials.instance_id,
              address, credentials.pani]
    return "START\t" + "\t".join(encode_field(field) for field in fields)


class EngineClient:
    def __init__(self, executable: Path):
        if not executable.is_file() or not os.access(executable, os.X_OK):
            raise ControllerError(f"The engine is missing or not executable: {executable}")
        self.executable = executable
        self.process: subprocess.Popen[str] | None = None
        self.events: queue.Queue[dict[str, object]] = queue.Queue()
        self.condition = threading.Condition()
        self.registered = False
        self.registration_code: int | None = None
        self.running = False
        self.write_lock = threading.Lock()

    def launch(self) -> None:
        self.process = subprocess.Popen(
            [str(self.executable), "--stdio"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, encoding="utf-8", bufsize=1,
        )
        self.running = True
        threading.Thread(target=self._read_events, name="jiojoin-events", daemon=True).start()
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            try:
                event = self.events.get(timeout=max(0.1, deadline - time.monotonic()))
            except queue.Empty:
                break
            if event.get("event") == "hello":
                if event.get("protocol") != PROTOCOL_VERSION:
                    self.close()
                    raise ControllerError(f"Unsupported engine protocol: {event.get('protocol')}")
                print(f"Engine {event.get('engine_version')} on {event.get('platform')}/{event.get('architecture')}")
                threading.Thread(target=self._heartbeat, name="jiojoin-heartbeat", daemon=True).start()
                return
        self.close()
        raise ControllerError("The engine did not complete its protocol handshake.")

    def _read_events(self) -> None:
        assert self.process is not None and self.process.stdout is not None
        for line in self.process.stdout:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            self.events.put(event)
            event_name = event.get("event")
            code = event.get("code") if isinstance(event.get("code"), int) else None
            with self.condition:
                if event_name == "registered" or (event_name == "registration" and code == 200):
                    self.registered = True
                    self.registration_code = 200
                elif event_name == "registration" and code is not None and code >= 300:
                    self.registered = False
                    self.registration_code = code
                elif event_name == "status":
                    self.registered = event.get("registered") is True
                    self.registration_code = code
                self.condition.notify_all()
            self._display(event)
        self.running = False
        with self.condition:
            self.condition.notify_all()

    @staticmethod
    def _display(event: dict[str, object]) -> None:
        name = str(event.get("event", "event"))
        if name in {"hello", "pong", "status"}:
            return
        message = str(event.get("message", name))
        code = event.get("code")
        if name == "registered":
            print("\nRegistered on JioFiber. Ready for calls.")
        elif name == "registration":
            print(f"\nRegistration: {message} ({code})")
        elif name == "incoming":
            print(f"\nIncoming call: {message} — type 'answer' or 'reject'")
        elif name == "error":
            print(f"\nEngine error: {message} ({code})")
        elif name in {"call-state", "media", "dialing", "held", "resumed", "remote-held"}:
            print(f"\n{name}: {message}")

    def _heartbeat(self) -> None:
        counter = 0
        while self.running:
            time.sleep(10)
            if not self.running:
                return
            try:
                self.send("PING")
                counter += 1
                if counter % 3 == 0:
                    self.send("STATUS")
            except ControllerError:
                return

    def send(self, command: str) -> None:
        if not self.process or not self.process.stdin or self.process.poll() is not None:
            raise ControllerError("The calling engine is unavailable.")
        try:
            with self.write_lock:
                self.process.stdin.write(command + "\n")
                self.process.stdin.flush()
        except (BrokenPipeError, OSError) as error:
            raise ControllerError("The calling engine pipe closed unexpectedly.") from error

    def register(self, credentials: SIPCredentials, address: str, timeout: float = 35) -> None:
        self.registration_code = None
        self.send(start_command(credentials, address))
        deadline = time.monotonic() + timeout
        with self.condition:
            while self.running and time.monotonic() < deadline:
                if self.registered:
                    return
                if self.registration_code is not None and self.registration_code >= 300:
                    raise ControllerError(f"Jio registration failed with SIP {self.registration_code}.")
                self.condition.wait(timeout=max(0.1, deadline - time.monotonic()))
        raise ControllerError("Jio registration timed out after 35 seconds.")

    def close(self) -> None:
        self.running = False
        if self.process and self.process.poll() is None:
            try:
                self.send("QUIT")
                self.process.wait(timeout=5)
            except (ControllerError, subprocess.TimeoutExpired):
                self.process.terminate()
                try:
                    self.process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    self.process.kill()


def interactive(client: EngineClient) -> None:
    print("Commands: status, dial NUMBER, answer, reject, hangup, hold, resume, quit")
    while client.running:
        try:
            raw = input("jiojoin> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return
        if not raw:
            continue
        command, _, argument = raw.partition(" ")
        command = command.lower()
        if command == "quit":
            return
        if command == "status":
            client.send("STATUS")
        elif command == "dial":
            number = normalize_number(argument)
            client.send(f"DIAL\t{encode_field(number)}")
        elif command in {"answer", "reject", "hangup", "hold", "resume"}:
            client.send(command.upper())
        else:
            print("Unknown command. Use: status, dial NUMBER, answer, reject, hangup, hold, resume, quit")


def default_engine() -> Path:
    root = Path(__file__).resolve().parent.parent
    architecture = os.uname().machine
    built = root / "build" / "headless" / f"linux-{architecture}" / "jiojoin-engine"
    adjacent = Path(__file__).resolve().with_name("jiojoin-engine")
    return adjacent if adjacent.is_file() else built


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Local JioFiberVoice controller for Linux")
    parser.add_argument("mode", choices=("run", "authorize"),
                        help="refresh an authorized device, or explicitly request an OTP")
    parser.add_argument("--router", default=DEFAULT_ROUTER,
                        help="jiofiber.local.html or the private router IPv4 address")
    parser.add_argument("--alias", help="stable device alias; generated and saved by default")
    parser.add_argument("--engine", type=Path, default=default_engine(), help="jiojoin-engine path")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    client: EngineClient | None = None
    try:
        alias = load_or_create_alias(arguments.alias)
        session = RouterSession(arguments.router, alias)
        credentials = session.authorize() if arguments.mode == "authorize" else session.refresh()
        address = local_address(session.connect_ip)
        client = EngineClient(arguments.engine)
        client.launch()
        print(f"Registering device {alias} from {address}…")
        client.register(credentials, address)
        interactive(client)
        return 0
    except AuthorizationRequired as error:
        print(f"Authorization required: {error}", file=sys.stderr)
        print("Run the same command with mode 'authorize' to request an OTP.", file=sys.stderr)
        return 3
    except ControllerError as error:
        print(f"JioJoin: {error}", file=sys.stderr)
        return 1
    finally:
        if client:
            client.close()


if __name__ == "__main__":
    raise SystemExit(main())
