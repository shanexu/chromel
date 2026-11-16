"""Unit tests for the uBOL -> Chromel cosmetics compiler."""

import importlib.machinery
import importlib.util
import json
import unittest

loader = importlib.machinery.SourceFileLoader("ubolcss", "scripts/ubol-cosmetics.py")
spec = importlib.util.spec_from_loader("ubolcss", loader)
ubolcss = importlib.util.module_from_spec(spec)
loader.exec_module(ubolcss)


def document(selectors, lists, refs, hosts):
    return {"selectors": selectors, "selectorLists": lists,
            "selectorListRefs": refs, "hostnames": hosts}


class SelectorListTest(unittest.TestCase):
    def test_positive_index_is_a_selector_to_hide(self):
        hidden, excepted = ubolcss.parse_selector_list("0,2", ["a", "b", "c"])
        self.assertEqual(hidden, ["a", "c"])
        self.assertEqual(excepted, [])

    def test_negative_index_is_an_exception(self):
        # uBOL stores exceptions as ~n, so -1 means selectors[0].
        hidden, excepted = ubolcss.parse_selector_list("-1", ["a", "b"])
        self.assertEqual(hidden, [])
        self.assertEqual(excepted, ["a"])

    def test_host_rule_drops_its_own_exceptions(self):
        doc = document(["keep", "drop", "other"], ["0,1", "-1,2"], [0, 1],
                       ["keep.example", "drop.example"])
        self.assertEqual(list(ubolcss.host_selectors(doc)),
                         [("keep.example", ["keep", "drop"]),
                          ("drop.example", ["other"])])

    def test_selector_lists_split_on_top_level_commas_only(self):
        self.assertEqual(ubolcss.split_selectors('a,[x="1,2"],b:not(.c,.d)'),
                         ["a", '[x="1,2"]', "b:not(.c,.d)"])

    def test_host_with_only_exceptions_emits_nothing(self):
        doc = document(["a"], ["-1"], [0], ["only.example"])
        self.assertEqual(list(ubolcss.host_selectors(doc)), [])


class GenericTest(unittest.TestCase):
    def test_generic_blob_is_unquoted_and_exceptions_removed(self):
        source = 'const exceptions = /* 2 */[".b","#c"];' \
                 'const highlyGeneric = /* 3 */"a,.b,#c,[d=\\"e\\"]";'
        self.assertEqual(ubolcss.generic_selectors(source), "a;[d=\"e\"]")

    def test_missing_blob_yields_empty_css(self):
        self.assertEqual(ubolcss.generic_selectors("const x = 1;"), "")


class CompileTest(unittest.TestCase):
    def test_hosts_are_deduplicated_across_lists(self):
        one = document(["a"], ["0"], [0], ["same.example"])
        two = document(["b"], ["0"], [0], ["same.example"])
        generic, hosts, stats = ubolcss.compile_cosmetics([one, two], [])
        self.assertEqual(generic, "")
        self.assertEqual(hosts, [("same.example", "a")])
        self.assertEqual(stats, {"hosts": 1, "generic": 0})

    def test_render_marks_generic_and_host_lines(self):
        text = ubolcss.render("div.ad", [("a.example", "b")],
                              {"hosts": 1, "generic": 1}, "lab")
        self.assertIn("# chromel-cosmetics 1", text)
        self.assertIn("# source: lab", text)
        self.assertIn("g\tdiv.ad", text)
        self.assertIn("h\ta.example\tb", text)


if __name__ == "__main__":
    unittest.main()
