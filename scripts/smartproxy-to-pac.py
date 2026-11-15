#!/usr/bin/env python3
"""Turn a SmartProxy full backup into a PAC file Chromium can evaluate.

Chromium resolves proxies once, at startup, from --proxy-pac-url; CEF has no
runtime equivalent of Chrome's chrome.proxy API.  So the rules live here, in a
file, and the browser reads them when it starts.

SmartProxy's own rule order is preserved: the first matching rule wins, exactly
like the extension.  Hosts that match nothing are DIRECT unless --default-proxy
says otherwise (which is what the "Smart Proxy" profile does).

Usage:
    python3 scripts/smartproxy-to-pac.py ~/Downloads/SmartProxy-FullBackup.json \
        -o ~/chromel/proxy.pac

Known limits, reported on stderr rather than hidden:
  * PAC cannot authenticate.  A rule pointing at a server with a username will
    provoke 407 responses that Chromium surfaces as failed loads.
  * Chromium strips the path and query of https URLs before calling the PAC
    script, so path rules only work for http.
"""

import argparse
import datetime
import ipaddress
import json
import re
import sys

# src/core/definitions.ts: ProxyRuleType
RULE_TYPES = {
    0: "MatchPatternHost",
    1: "MatchPatternUrl",
    2: "RegexHost",
    3: "RegexUrl",
    4: "Exact",
    5: "DomainSubdomain",
    6: "DomainExact",
    7: "DomainAndPath",
    8: "DomainSubdomainAndPath",
    9: "SearchUrl",
    10: "IpCidrNotation",
}

PROTOCOLS = {
    "HTTP": "PROXY",
    "PROXY": "PROXY",
    "HTTPS": "HTTPS",
    "SOCKS": "SOCKS",
    "SOCKS4": "SOCKS4",
    "SOCKS5": "SOCKS5",
}


def js(value):
    """A JavaScript string literal."""
    return json.dumps(value, ensure_ascii=False)


def rule_type(rule):
    raw = rule.get("ruleType")
    if isinstance(raw, str) and raw.isdigit():
        raw = int(raw)
    return raw


def rule_pattern(rule):
    """The text the rule matches on (SmartProxy keeps it in several fields)."""
    for key in ("ruleSearch", "hostName", "rule"):
        value = rule.get(key)
        if isinstance(value, str) and value:
            return value
    return ""


def servers_by_id(backup):
    return {server.get("id"): server for server in backup.get("proxyServers", [])}


def pick_profile(backup, wanted):
    profiles = backup.get("proxyProfiles", [])
    if not wanted:
        active = backup.get("activeProfileId")
        for profile in profiles:
            if profile.get("profileId") == active:
                return profile
        return profiles[0] if profiles else None
    for profile in profiles:
        if wanted in (profile.get("profileId"), profile.get("profileName")):
            return profile
    raise SystemExit(f"No such profile: {wanted}")


def resolve_server(rule, profile, servers, default_id):
    """Which proxy a rule routes to, or None for DIRECT."""
    custom = rule.get("proxy")
    if isinstance(custom, dict) and custom.get("host"):
        return custom
    for candidate in (profile.get("profileProxyServerId"), default_id):
        if candidate:
            server = servers.get(candidate)
            if server and server.get("host"):
                return server
    return None


def directive(server):
    if not server:
        return None
    protocol = str(server.get("protocol") or "HTTP").upper()
    token = PROTOCOLS.get(protocol)
    if not token:
        raise SystemExit(f"Unsupported proxy protocol: {protocol}")
    return f"{token} {server['host']}:{int(server['port'])}"


def cidr_netmask(cidr):
    network = ipaddress.ip_network(cidr, strict=False)
    return str(network.network_address), str(network.netmask)


def predicate(rtype, pattern, warnings):
    """A JavaScript expression that is true when this rule matches."""
    if rtype == 5:  # DomainSubdomain: the domain itself or any subdomain
        return f'host === {js(pattern)} || shExpMatch(host, {js("*." + pattern)})'
    if rtype == 6:  # DomainExact
        return f"host === {js(pattern)}"
    if rtype in (7, 8):  # DomainAndPath / DomainSubdomainAndPath
        warnings.add("path")
        host_part = js(f"*.{pattern}") if rtype == 8 else None
        base = f'shExpMatch(url, "http://{pattern}/*") || shExpMatch(url, "https://{pattern}/*")'
        # SmartProxy treats the rule text as "domain/path"; split it back out.
        if "/" in pattern:
            domain, path = pattern.split("/", 1)
            path = "/" + path.lstrip("/")
            base = f"shExpMatch(url, {js(f'{domain}{path}')} + '*')"
            if rtype == 8:
                base = (f"shExpMatch(url, {js('*.' + domain + path)} + '*') || "
                        f"{base}")
        return base
    if rtype in (0, 1):
        # SmartProxy wildcards: * spans anything; ? is literal there, but
        # shExpMatch's ? (one character) is close enough and rarely used.
        return (f"shExpMatch(host, {js(pattern)})" if rtype == 0
                else f"shExpMatch(url, {js(pattern)})")
    if rtype == 2:
        return f"new RegExp({js(pattern)}).test(host)"
    if rtype == 3:
        return f"new RegExp({js(pattern)}).test(url)"
    if rtype == 4:  # Exact URL
        return f"url === {js(pattern)}"
    if rtype == 9:  # SearchUrl
        return f"url.indexOf({js(pattern)}) !== -1"
    if rtype == 10:  # IpCidrNotation
        network, mask = cidr_netmask(pattern)
        warnings.add("dns")
        return f"isInNet(host, {js(network)}, {js(mask)})"
    return None


def build_pac(backup, profile, source, default_is_direct):
    warnings = set()
    servers = servers_by_id(backup)
    default_id = backup.get("defaultProxyServerId")
    lines = []
    emitted = skipped = 0
    authenticated = set()

    for rule in profile.get("proxyRules") or []:
        if rule.get("enabled") is False:
            skipped += 1
            continue
        pattern = rule_pattern(rule)
        rtype = rule_type(rule)
        if not pattern or rtype is None:
            skipped += 1
            continue
        if rule.get("whiteList"):
            target = "DIRECT"
        else:
            server = resolve_server(rule, profile, servers, default_id)
            if server and server.get("username"):
                authenticated.add(server.get("name") or server.get("id"))
            target = directive(server) or "DIRECT"
        expression = predicate(rtype, pattern, warnings)
        if expression is None:
            warnings.add(f"unknown rule type {rtype} ({pattern})")
            skipped += 1
            continue
        name = RULE_TYPES.get(rtype, str(rtype))
        lines.append(f"  // {name}: {pattern}")
        lines.append(f"  if ({expression}) return {js(target)};")
        emitted += 1

    fallback = "DIRECT" if default_is_direct else (directive(servers.get(default_id)) or "DIRECT")
    body = "\n".join(lines)
    generated = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    pac = f"""// Generated by scripts/smartproxy-to-pac.py on {generated}
// Source: {source}
// Profile: {profile.get('profileName')} ({profile.get('profileId')})
// Rules: {emitted} active, {skipped} skipped; unmatched hosts -> {fallback}
//
// Chromium reads this file once, when its browser process starts.

function FindProxyForURL(url, host) {{
{body}
  return {js(fallback)};
}}
"""
    return pac, emitted, skipped, warnings, authenticated


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("backup", help="SmartProxy-FullBackup.json")
    parser.add_argument("-o", "--out", help="Write the PAC here (default: stdout)")
    parser.add_argument("--profile", help="Profile name or id (default: the active one)")
    parser.add_argument("--default-proxy", action="store_true",
                        help="Route unmatched hosts through the default server "
                             "instead of DIRECT")
    args = parser.parse_args()

    with open(args.backup, encoding="utf-8") as handle:
        backup = json.load(handle)
    if backup.get("product") != "SmartProxy":
        print(f"warning: {args.backup} does not look like a SmartProxy backup",
              file=sys.stderr)

    profile = pick_profile(backup, args.profile)
    if profile is None:
        raise SystemExit("The backup contains no profiles")

    pac, emitted, skipped, warnings, authenticated = build_pac(
        backup, profile, args.backup, default_is_direct=not args.default_proxy)

    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(pac)
        print(f"{args.out}: {emitted} rules ({skipped} skipped), "
              f"unmatched -> {'default proxy' if args.default_proxy else 'DIRECT'}",
              file=sys.stderr)
    else:
        sys.stdout.write(pac)

    if authenticated:
        print("warning: these servers need a password, which PAC cannot supply: "
              + ", ".join(sorted(authenticated)), file=sys.stderr)
    if "path" in warnings:
        print("warning: path rules only work for http; Chromium strips the path "
              "of https URLs before calling this script", file=sys.stderr)
    if "dns" in warnings:
        print("warning: CIDR rules call isInNet, which needs synchronous DNS and "
              "is unreliable in Chromium", file=sys.stderr)
    for note in sorted(w for w in warnings if w.startswith("unknown")):
        print(f"warning: {note}", file=sys.stderr)


if __name__ == "__main__":
    main()
