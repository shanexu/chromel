"""Unit tests for the uBOL -> Chromel blocklist compiler."""

import importlib.machinery
import importlib.util
import unittest

loader = importlib.machinery.SourceFileLoader("ubol", "scripts/ubol-to-blocklist.py")
spec = importlib.util.spec_from_loader("ubol", loader)
ubol = importlib.util.module_from_spec(spec)
loader.exec_module(ubol)


class ConvertTest(unittest.TestCase):
    def test_host_rule_becomes_one_line(self):
        lines, stats = ubol.compile_rules([{"id": 1, "priority": 10,
            "action": {"type": "block"}, "condition": {"urlFilter": "||ads.example.com^"}}])
        self.assertEqual(lines, ["b\t0\t\th=ads.example.com"])
        self.assertEqual(stats["emitted"], 1)

    def test_path_and_substring_rules_are_dropped_in_v1(self):
        lines, stats = ubol.compile_rules([
            {"id": 1, "action": {"type": "block"}, "condition": {"urlFilter": "||ads.example.com/a.js"}},
            {"id": 2, "action": {"type": "block"}, "condition": {"urlFilter": "/tracker.gif"}}])
        self.assertEqual(lines, [])
        self.assertEqual(stats["dropped_pattern"], 2)

    def test_allow_survives_and_resource_type_becomes_a_mask(self):
        lines, _ = ubol.compile_rules([{"id": 3, "priority": 30,
            "action": {"type": "allow"},
            "condition": {"requestDomains": ["good.example"], "resourceTypes": ["script"]}}])
        self.assertEqual(lines, ["a\t%x\t\th=good.example" % (1 << ubol.RESOURCE_TYPES.index("script"))])


if __name__ == "__main__":
    unittest.main()
