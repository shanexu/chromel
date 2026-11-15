#!/usr/bin/env python3
"""Compile uBlock Origin Lite (declarativeNetRequest) rulesets into a flat list.

uBOL ships its filter lists pre-compiled as DNR JSON.  That is the one part of
uBOL we can reuse: Chromium's declarativeNetRequest engine does not exist in
CEF, but the rules themselves are plain data we can match in the browser
process before a request leaves.

Version 1 keeps only rules that name a host: `||ads.example.com^` and
`requestDomains`.  Paths, substrings and regular expressions need the part of
the matcher we have not built yet, so they are counted and dropped instead of
being silently mis-applied.

Output format (one rule per line, tab separated):

    b|a <types-hex> <flags> <spec>

  types   bitmask of CEF resource types, 0 = every type
  flags   reserved; always empty in version 1
  spec    `h=<suffix>` plus optional `i=<suffix>`, `;` joined

Lines starting with "#" are comments and are skipped when loading.
"""

import argparse
import base64
import json
import sys
import urllib.request

# DNR resource type -> bit index in the emitted mask.  Keep this order in sync
# with the mapping in native/blocklist.mm.
RESOURCE_TYPES = [
    "main_frame",
    "sub_frame",
    "stylesheet",
    "script",
    "image",
    "font",
    "object",
    "xmlhttprequest",
    "ping",
    "media",
    "websocket",
    "other",
]

SUPPORTED_ACTIONS = {"block": "b", "allow": "a"}
ALL_TYPES = (1 << len(RESOURCE_TYPES)) - 1


def fetch(url: str) -> bytes:
    """Fetch through the GitHub API when raw.githubusercontent is blocked."""
    if "raw.githubusercontent.com/" in url:
        path = url.split("raw.githubusercontent.com/", 1)[1]
        parts = path.split("/", 3)
        api = "https://api.github.com/repos/%s/%s/contents/%s" % (
            parts[0],
            parts[1],
            parts[3],
        )
        with urllib.request.urlopen(api, timeout=60) as response:
            payload = json.load(response)
        return base64.b64decode(payload["content"])
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read()


def load_rules(path: str) -> list:
    if path.startswith("http://") or path.startswith("https://"):
        return json.loads(fetch(path))
    with open(path, "rb") as handle:
        return json.load(handle)


def type_mask(names) -> int:
    mask = 0
    for name in names or ():
        key = name.lower()
        if key not in RESOURCE_TYPES:
            raise ValueError("unknown resource type: %s" % name)
        mask |= 1 << RESOURCE_TYPES.index(key)
    return mask


def host_suffix(domain: str):
    domain = (domain or "").strip().lower().lstrip(".")
    if not domain:
        return None
    for bad in ("/", " ", ":", "*", "^", "|"):
        if bad in domain:
            return None
    return domain


def filter_host(pattern: str):
    """Return the host a `||host^` filter names, or None for anything else."""
    if not pattern or not pattern.startswith("||"):
        return None
    rest = pattern[2:]
    for marker in ("^", "|"):
        if marker in rest:
            rest = rest.split(marker, 1)[0]
    return host_suffix(rest)


def compile_rules(rules) -> tuple:
    """Turn DNR rule dictionaries into (lines, stats)."""
    lines = []
    stats = {"rules": 0, "emitted": 0, "dropped_action": 0, "dropped_pattern": 0}
    for rule in rules:
        stats["rules"] += 1
        action = (rule.get("action") or {}).get("type", "")
        if action not in SUPPORTED_ACTIONS:
            stats["dropped_action"] += 1
            continue

        condition = rule.get("condition") or {}
        if condition.get("regexFilter"):
            stats["dropped_pattern"] += 1
            continue
        if condition.get("excludedRequestDomains") or condition.get(
            "excludedInitiatorDomains"
        ):
            stats["dropped_pattern"] += 1
            continue

        try:
            mask = type_mask(condition.get("resourceTypes"))
            excluded = type_mask(condition.get("excludedResourceTypes"))
        except ValueError:
            stats["dropped_pattern"] += 1
            continue
        if excluded:
            if mask:
                stats["dropped_pattern"] += 1
                continue
            mask = ALL_TYPES & ~excluded

        request_domains = [
            host for host in (host_suffix(x) for x in condition.get("requestDomains") or ()) if host
        ]
        pattern = condition.get("urlFilter")
        filter_host_name = filter_host(pattern) if pattern else None
        if pattern and not filter_host_name:
            stats["dropped_pattern"] += 1
            continue
        if filter_host_name and request_domains and request_domains != [filter_host_name]:
            stats["dropped_pattern"] += 1
            continue

        hosts = request_domains or ([filter_host_name] if filter_host_name else [])
        if not hosts:
            stats["dropped_pattern"] += 1
            continue

        initiators = [
            host for host in (host_suffix(x) for x in condition.get("initiatorDomains") or ()) if host
        ]

        for host in hosts:
            for initiator in initiators or [None]:
                spec = "h=%s" % host
                if initiator:
                    spec += ";i=%s" % initiator
                lines.append("%s\t%x\t\t%s" % (SUPPORTED_ACTIONS[action], mask, spec))
                stats["emitted"] += 1
    return lines, stats


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rulesets", nargs="+", help="uBOL DNR JSON files or URLs")
    parser.add_argument("-o", "--out", required=True)
    parser.add_argument("--label", default="", help="what to record in the header")
    args = parser.parse_args()

    lines = []
    totals = {"rules": 0, "emitted": 0, "dropped_action": 0, "dropped_pattern": 0}
    for path in args.rulesets:
        part, stats = compile_rules(load_rules(path))
        lines.extend(part)
        for key in totals:
            totals[key] += stats[key]

    with open(args.out, "w", encoding="utf-8") as handle:
        handle.write("# chromel-blocklist 1\n")
        handle.write("# source: %s\n" % (args.label or " ".join(args.rulesets)))
        handle.write(
            "# rules: %(rules)d  emitted: %(emitted)d  dropped(action): "
            "%(dropped_action)d  dropped(pattern): %(dropped_pattern)d\n" % totals
        )
        handle.write("\n".join(lines))
        handle.write("\n")

    print(
        f"rules={totals['rules']} emitted={totals['emitted']} "
        f"dropped-action={totals['dropped_action']} "
        f"dropped-pattern={totals['dropped_pattern']} -> {args.out}",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
