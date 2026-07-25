import importlib.util
import plistlib
import sys
import tempfile
import textwrap
import unittest
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

    def test_forwarding_requires_windows_host(self):
        with self.assertRaisesRegex(ValueError, "windows_host"):
            self.load_config(
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


if __name__ == "__main__":
    unittest.main()
