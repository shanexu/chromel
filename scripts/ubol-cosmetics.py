#!/usr/bin/env python3
"""Compile uBOL's cosmetic rulesets into a flat stylesheet table.

uBOL ships cosmetic filtering as `scripting/specific/<list>.json` (per-site
selectors, index-encoded) and `scripting/generic/<list>.js` (site-independent
selectors).  The encoding is documented by uBOL's own decoder,
`chromium/js/scripting/css-specific.js`:

    selectorLists[i] holds a JSON array literal without its brackets; a
    positive number indexes `selectors`, a negative number is `~n` -- an
    exception for that host.

Version 1 keeps only what a plain stylesheet can express: the `highlyGeneric`
blob from the generic files, and per-host selector lists.  Regex rules and
procedural cosmetics are counted and dropped.

Output format (one rule per line, tab separated):

    g <selector>;<selector>            hide these on every page
    h <hostname> <selector>;<selector> hide these on this host and its children

Each `<selectors>` is a `;` separated list so the backend can emit one rule per
selector (one unparsable selector must not void the others).
"""

import argparse
import json
import re
import sys


def split_selectors(css):
    """Split a CSS selector list on top-level commas (quotes, (), [] aware)."""
    parts, depth, quote, start = [], 0, "", 0
    for index, char in enumerate(css):
        if quote:
            if char == quote:
                quote = ""
        elif char in "\"'":
            quote = char
        elif char in "([":
            depth += 1
        elif char in ")]":
            depth = max(0, depth - 1)
        elif char == "," and depth == 0:
            parts.append(css[start:index].strip())
            start = index + 1
    parts.append(css[start:].strip())
    return [part for part in parts if part]


def parse_selector_list(entry, selectors):
    """Decode one `selectorLists` entry into (hidden, excepted) selectors."""
    hidden, excepted = [], []
    for index in json.loads(f"[{entry}]"):
        if index >= 0:
            hidden.append(selectors[index])
        else:
            excepted.append(selectors[~index])
    return hidden, excepted


def host_selectors(data):
    """Yield (hostname, [selectors]) for every host with specific rules."""
    selectors = data["selectors"]
    lists = data["selectorLists"]
    for host, ref in zip(data["hostnames"], data["selectorListRefs"]):
        hidden, excepted = parse_selector_list(lists[ref], selectors)
        drop = set(excepted)
        kept = [selector for selector in hidden if selector not in drop]
        if kept:
            yield host, kept


def generic_selectors(source):
    """Return the `highlyGeneric` blob with uBOL's global exceptions removed."""
    blob = re.search(r'const highlyGeneric = /\* \d+ \*/((?:"(?:[^"\\]|\\.)*"))\s*;',
                     source, re.S)
    if blob is None:
        return ""
    parts = split_selectors(json.loads(blob.group(1)))
    skip = set()
    block = re.search(r"const exceptions = /\* \d+ \*/(\[[^\]]*\])\s*;", source, re.S)
    if block is not None:
        skip = {str(item).strip() for item in json.loads(block.group(1))}
    kept = [part for part in parts if part and part not in skip]
    # One selector per rule: a single unparsable selector would otherwise void
    # the whole comma list.
    return ";".join(kept)


def compile_cosmetics(specific_documents, generic_sources):
    """Return (generic css, [(host, css)], stats)."""
    generic = [generic_selectors(source) for source in generic_sources]
    generic = [blob for blob in generic if blob]
    hosts, seen = [], set()
    for data in specific_documents:
        for host, selectors in host_selectors(data):
            if host in seen:
                continue
            seen.add(host)
            hosts.append((host, ";".join(selectors)))
    stats = {"hosts": len(hosts), "generic": len(generic)}
    return ";".join(blob for blob in generic), sorted(hosts), stats


def render(generic, hosts, stats, label):
    head = [
        "# chromel-cosmetics 1",
        f"# source: {label}",
        f"# generic: {len(generic)} chars  hosts: {stats['hosts']}",
    ]
    lines = head
    if generic:
        lines.append(f"g\t{generic}")
    lines.extend(f"h\t{host}\t{css}" for host, css in hosts)
    return "\n".join(lines) + "\n"


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("specific", nargs="+", help="scripting/specific/*.json files")
    parser.add_argument("--generic", nargs="*", default=[],
                        help="scripting/generic/*.js files")
    parser.add_argument("-o", "--out", required=True)
    parser.add_argument("--label", default="")
    arguments = parser.parse_args(argv)

    documents = [json.load(open(path, encoding="utf-8")) for path in arguments.specific]
    sources = [open(path, encoding="utf-8").read() for path in arguments.generic]
    generic, hosts, stats = compile_cosmetics(documents, sources)
    text = render(generic, hosts, stats, arguments.label)
    with open(arguments.out, "w", encoding="utf-8") as output:
        output.write(text)
    size = len(text.encode("utf-8"))
    print(f"generic={len(generic)} chars hosts={stats['hosts']} bytes={size} -> {arguments.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
