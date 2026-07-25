import importlib.util
import plistlib
import sys
import tempfile
import textwrap
import unittest
import zlib
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "src" / "discovery_test.py"
SPEC = importlib.util.spec_from_file_location("windrop_discovery_test", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class DiscoveryConfigTests(unittest.TestCase):
    def load_config(self, contents: str):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.toml"
            path.write_text(textwrap.dedent(contents), encoding="utf-8")
            return MODULE.DiscoveryConfig.load(path)

    def test_config_and_discover_response(self):
        config = self.load_config(
            """
            [receiver]
            display_name = "UniDrop"
            model_name = "Windows PC"
            service_id = "7c91d40a88f2"
            bonjour_host = "halils-windows-pc-windrop"
            [network]
            interface = "awdl0"
            port = 8873
            """
        )
        response = plistlib.loads(MODULE.build_discover_response(config))
        self.assertEqual(response["ReceiverComputerName"], "UniDrop")
        self.assertEqual(response["ReceiverModelName"], "Windows PC")
        self.assertEqual(response["ReceiverMediaCapabilities"], b'{"Version":1}')

    def test_rejects_invalid_service_id(self):
        with self.assertRaisesRegex(ValueError, "12 hexadecimal"):
            self.load_config(
                """
                [receiver]
                display_name = "test"
                model_name = "test"
                service_id = "not-an-id"
                bonjour_host = "test"
                [network]
                interface = "awdl0"
                port = 8873
                """
            )

    def test_rejects_privileged_port(self):
        with self.assertRaisesRegex(ValueError, "between 1024"):
            self.load_config(
                """
                [receiver]
                display_name = "test"
                model_name = "test"
                service_id = "001122334455"
                bonjour_host = "test"
                [network]
                interface = "awdl0"
                port = 443
                """
            )

    def test_forwarding_allows_auto_receiver_discovery(self):
        config = self.load_config(
            """
            [receiver]
            display_name = "test"
            model_name = "test"
            service_id = "001122334455"
            bonjour_host = "test"
            [network]
            interface = "awdl0"
            port = 8873
            [forwarding]
            enabled = true
            """
        )
        self.assertEqual(config.windows_host, "")
        self.assertTrue(config.forwarding_enabled)

    def test_parse_dvzip_flagged_big_endian_length(self):
        self.assertEqual(MODULE.parse_dvzip_chunk_length(bytes.fromhex("80020000")), 131072)
        header = MODULE.parse_dvzip_chunk_header(bytes.fromhex("80020000"))
        self.assertEqual(header.length, 131072)
        self.assertTrue(header.raw)

    def test_expand_dvzip_to_cpio(self):
        cpio = b"070701" + b"0" * 128 + b"payload"
        compressed = zlib.compress(cpio)
        with tempfile.TemporaryDirectory() as directory:
            input_path = Path(directory) / "input.dvzip"
            output_path = Path(directory) / "output.cpio"
            input_path.write_bytes(len(compressed).to_bytes(4, "big") + compressed)

            total = MODULE.expand_dvzip_to_cpio(input_path, output_path)

            self.assertEqual(total, len(cpio))
            self.assertEqual(output_path.read_bytes(), cpio)

    def test_expand_dvzip_raw_flagged_chunk_to_cpio(self):
        cpio = b"070707000000payload"
        with tempfile.TemporaryDirectory() as directory:
            input_path = Path(directory) / "input.dvzip"
            output_path = Path(directory) / "output.cpio"
            input_path.write_bytes((len(cpio) | 0x80000000).to_bytes(4, "big") + cpio)

            total = MODULE.expand_dvzip_to_cpio(input_path, output_path)

            self.assertEqual(total, len(cpio))
            self.assertEqual(output_path.read_bytes(), cpio)

    def test_resolve_receiver_reuses_cached_target(self):
        config = self.load_config(
            """
            [receiver]
            display_name = "S10 von Serhat"
            model_name = "Android Phone"
            service_id = "001122334455"
            bonjour_host = "test"
            [network]
            interface = "awdl0"
            port = 8873
            windows_port = 8873
            [forwarding]
            enabled = true
            """
        )
        receiver = MODULE.ReceiverProbe("192.168.178.60", "S10 von Serhat", "android")
        calls = {"discover": 0, "probe": 0}
        original_discover = MODULE.discover_receiver
        original_probe = MODULE.probe_receiver
        MODULE.clear_cached_receiver(config)

        def fake_discover(_config):
            calls["discover"] += 1
            return receiver

        def fake_probe(_config, host, timeout=None):
            calls["probe"] += 1
            self.assertEqual(host, receiver.host)
            return receiver

        try:
            MODULE.discover_receiver = fake_discover
            MODULE.probe_receiver = fake_probe
            self.assertEqual(MODULE.resolve_receiver(config), receiver)
            self.assertEqual(MODULE.resolve_receiver(config), receiver)
        finally:
            MODULE.discover_receiver = original_discover
            MODULE.probe_receiver = original_probe
            MODULE.clear_cached_receiver(config)

        self.assertEqual(calls["discover"], 1)
        self.assertEqual(calls["probe"], 1)

    def test_ask_can_continue_without_blocking_auto_discovery(self):
        config = self.load_config(
            """
            [receiver]
            display_name = "S10 von Serhat"
            model_name = "Android Phone"
            service_id = "001122334455"
            bonjour_host = "test"
            [network]
            interface = "awdl0"
            port = 8873
            windows_port = 8873
            [forwarding]
            enabled = true
            """
        )
        calls = {"threads": 0}
        original_thread = MODULE.threading.Thread
        MODULE.clear_cached_receiver(config)

        class FakeThread:
            def __init__(self, *args, **kwargs):
                pass

            def start(self):
                calls["threads"] += 1

        try:
            MODULE.threading.Thread = FakeThread
            self.assertTrue(MODULE.ask_can_continue(config))
        finally:
            MODULE.threading.Thread = original_thread
            MODULE.clear_cached_receiver(config)

        self.assertEqual(calls["threads"], 1)


if __name__ == "__main__":
    unittest.main()
