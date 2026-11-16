# `blocklist.txt`

A compiled snapshot of the uBOL rulesets Chromel ships: `ublock-filters`,
`ublock-badware`, `easylist`, `easyprivacy`, `urlhaus-full`, `pgl`, `chn-0`
(AdGuard Chinese), `jpn-1` (AdGuard Japanese) and `kor-1` (Korean). It is committed so that a fresh checkout blocks ads
without any setup step; `chromel-blocklist-file` defaults to this file.

Current snapshot: uBOL commit `a58a26f1` (2026-11-13), 110,616 host rules, 2.9 MB.
The header of the file records the same facts.

## Regenerating

`raw.githubusercontent.com` is blocked from some machines; the blobs API works
everywhere GitHub is reachable. Fetch the rulesets by their tree SHAs:

```bash
cd /tmp
curl -sS "https://api.github.com/repos/uBlockOrigin/uBOL-home/git/trees/main?recursive=1" -o tree.json
python3 - <<'PY'
import base64, json, urllib.request
tree = json.load(open('/tmp/tree.json'))['tree']
want = {'ublock-filters', 'ublock-badware', 'easylist', 'easyprivacy',
        'urlhaus-full', 'pgl', 'chn-0', 'jpn-1', 'kor-1'}
for t in tree:
    name = t['path'].split('/')[-1][:-5]
    if t['path'].startswith('chromium/rulesets/main/') and t['path'].endswith('.json') and name in want:
        blob = json.load(urllib.request.urlopen(
            f"https://api.github.com/repos/uBlockOrigin/uBOL-home/git/blobs/{t['sha']}"))
        open(f"/tmp/{name}.json", "wb").write(base64.b64decode(blob['content']))
        print(name, t['sha'][:12])
PY
```

Then compile and check the header:

```bash
cd /path/to/chromel
python3 scripts/ubol-to-blocklist.py /tmp/ublock-filters.json /tmp/ublock-badware.json \
  /tmp/easylist.json /tmp/easyprivacy.json /tmp/urlhaus-full.json /tmp/pgl.json /tmp/chn-0.json \
  /tmp/jpn-1.json /tmp/kor-1.json \
  -o data/blocklist.txt --label "uBlockOrigin/uBOL-home@<commit> chromium/rulesets/main/... generated <date>"
head -3 data/blocklist.txt
```

Record the uBOL commit in `--label`; the number that matters is `emitted`, which
must stay in the same ballpark (a large drop means uBOL changed a field name and
the compiler needs updating). Restart Emacs after replacing the file — the list
is read once, when CEF starts.

## Lists uBOL does not ship

`uBlock filters – Privacy`, `– Quick fixes` and `– Unbreak` are uBO lists with
no declarativeNetRequest ruleset in uBOL (its `ruleset-details.json` has 56
entries and none of them is one of these), so they cannot be part of this
snapshot. Blocking rules from them that are host-shaped may still arrive through
`ublock-filters`, whose uBOL name is "Ads, trackers, and more".

## Why some rules are missing

Version 1 matches hosts only. Rules that need paths, substrings or regular
expressions are dropped, and the header counts them under `dropped(pattern)`.
`dropped(action)` counts rules whose action Chromel cannot perform at all
(`redirect`, `modifyHeaders`, `upgradeScheme`, …).

## Cosmetics

`cosmetics.txt` holds the element hiding rules from the same snapshot.  uBOL
keeps them as index-encoded selector lists in
`chromium/rulesets/scripting/specific/<list>.json` and as plain strings in
`chromium/rulesets/scripting/generic/<list>.js`; the encoding is documented by
uBOL's own decoder (`chromium/js/scripting/css-specific.js`): a positive index
into `selectors` means "hide", `~n` means "exception for this host".

```
python3 scripts/ubol-cosmetics.py /tmp/ubol/{chn-0,easylist,easyprivacy,jpn-1,kor-1,ublock-badware,ublock-filters}.json \
  --generic /tmp/ubol/{chn-0,easylist,easyprivacy,jpn-1,kor-1,ublock-badware,ublock-filters}.js \
  -o data/cosmetics.txt --label "uBlockOrigin/uBOL-home@<sha> ..."
```

Only `highlyGeneric`, the per-host lists and their `~n` exceptions survive;
framework cosmetics (procedural selectors like `:has-text`), `regexes`, and the
`lowlyGeneric` maps are counted and dropped.  Selectors are joined with `;` so
the backend can emit one rule per selector.
