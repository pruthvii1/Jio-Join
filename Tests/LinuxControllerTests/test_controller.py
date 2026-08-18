import importlib.util
import pathlib
import sys
import tempfile
import textwrap
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("jiojoin_controller", ROOT / "linux" / "jiojoin_controller.py")
controller = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = controller
SPEC.loader.exec_module(controller)


SAMPLE_XML = b"""<?xml version="1.0"?>
<wap-provisioningdoc>
  <characteristic type="APPLICATION">
    <parm name="realm" value="ims.example"/>
    <parm name="userpwd" value="test-password-not-a-real-secret"/>
    <parm name="public_user_identity" value="sip:+911234@example"/>
    <parm name="private_user_identity" value="sip:test-user@example"/>
    <parm name="uuid_value" value="00000000-0000-1000-8000-001122334455"/>
    <parm name="psoltid" value="1234"/>
    <characteristic type="LBO_P-CSCF_Address">
      <parm name="Address" value="router.example:5068"/>
    </characteristic>
  </characteristic>
</wap-provisioningdoc>
"""


class LinuxControllerTests(unittest.TestCase):
    def test_device_identity_matches_mac_client(self):
        self.assertEqual(controller.device_mac("AnkurSIPProxy"), "00:00:0f:10:ea:f2")
        self.assertEqual(controller.instance_id("00:00:0f:10:ea:f2"),
                         "<00000000-0000-1000-8000-00000F10EAF2>")

    def test_router_scope_is_private_only(self):
        self.assertTrue(controller.is_private_router("jiofiber.local.html"))
        self.assertTrue(controller.is_private_router("192.168.31.1"))
        self.assertFalse(controller.is_private_router("8.8.8.8"))
        self.assertFalse(controller.is_private_router("example.com"))

    def test_provisioning_parser_preserves_hierarchy(self):
        credentials = controller.parse_credentials(SAMPLE_XML, "AnkurSIPProxy")
        self.assertEqual(credentials.realm, "ims.example")
        self.assertEqual(credentials.auth_user, "test-user@example")
        self.assertEqual(credentials.registrar, "sip:router.example:5068;transport=tls")
        self.assertEqual(credentials.pani, "GPON;PSAPId=+1234")

    def test_start_command_frames_secret_without_plaintext(self):
        credentials = controller.parse_credentials(SAMPLE_XML, "AnkurSIPProxy")
        command = controller.start_command(credentials, "192.168.31.107")
        self.assertTrue(command.startswith("START\t"))
        self.assertEqual(len(command.split("\t")), 9)
        self.assertNotIn(credentials.password, command)

    def test_response_parser_extracts_ephemeral_cookie(self):
        raw = (b"HTTP/1.1 200 OK\r\nSet-Cookie: session=temporary; Path=/\r\n\r\n"
               + SAMPLE_XML + b"\nX-JioJoin-Status: 200\n")
        body, status, cookie = controller.RouterSession.parse_response(raw)
        self.assertEqual(status, 200)
        self.assertEqual(cookie, "session=temporary")
        self.assertEqual(body, SAMPLE_XML)

    def test_otp_and_cookie_are_sent_via_stdin_not_argv(self):
        response = (b"HTTP/1.1 200 OK\r\n\r\n"
                    + SAMPLE_XML + b"\nX-JioJoin-Status: 200\n")
        completed = controller.subprocess.CompletedProcess([], 0, stdout=response, stderr=b"")
        session = controller.RouterSession("192.168.31.1", "JioJoinLinux-test", curl="/usr/bin/curl")
        session.cookie = "session=private-cookie"
        with mock.patch.object(controller.subprocess, "run", return_value=completed) as run:
            body, status = session.request([("OTP", "123456")])
        command = run.call_args.args[0]
        configuration = run.call_args.kwargs["input"].decode("utf-8")
        self.assertNotIn("123456", " ".join(command))
        self.assertNotIn("private-cookie", " ".join(command))
        self.assertIn("123456", configuration)
        self.assertIn("private-cookie", configuration)
        self.assertEqual(command[1], "--disable")
        self.assertIn("--noproxy", command)
        self.assertEqual(body, SAMPLE_XML)
        self.assertEqual(status, 200)

    def test_dial_normalization_matches_desktop(self):
        self.assertEqual(controller.normalize_number("98765 43210"), "09876543210")
        self.assertEqual(controller.normalize_number("+91 98765-43210"), "09876543210")
        with self.assertRaises(controller.ControllerError):
            controller.normalize_number("hello")

    def test_controller_negotiates_and_registers_over_private_stdio(self):
        fake_source = textwrap.dedent("""\
            #!/usr/bin/env python3
            import json
            import sys
            print(json.dumps({"event":"hello", "protocol":1, "engine_version":"test",
                              "platform":"linux", "architecture":"x86_64"}), flush=True)
            print(json.dumps({"event":"engine", "message":"ready", "code":0}), flush=True)
            for line in sys.stdin:
                command = line.split("\\t", 1)[0].strip()
                if command == "START":
                    print(json.dumps({"event":"registered", "message":"OK", "code":200}), flush=True)
                elif command == "PING":
                    print(json.dumps({"event":"pong", "message":"ok", "code":0}), flush=True)
                elif command == "QUIT":
                    break
            """)
        with tempfile.TemporaryDirectory() as directory:
            fake_engine = pathlib.Path(directory) / "fake-engine"
            fake_engine.write_text(fake_source, encoding="utf-8")
            fake_engine.chmod(0o700)
            credentials = controller.parse_credentials(SAMPLE_XML, "AnkurSIPProxy")
            client = controller.EngineClient(fake_engine)
            try:
                client.launch()
                client.register(credentials, "192.168.31.107", timeout=2)
                self.assertTrue(client.registered)
            finally:
                client.close()


if __name__ == "__main__":
    unittest.main()
