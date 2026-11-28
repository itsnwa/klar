#!/usr/bin/env python3
"""Regenerates the trackers Klar blocks
(Klar/Assets.xcassets/TrackerBlockList.dataset/trackers.json.deflate).

The list is EasyPrivacy (https://easylist.to), turned into WebKit's content
blocker rules (WKContentRuleList), compressed with raw DEFLATE, which
NSData's `.zlib` decompresses: the JSON is over 6 MB, the same few
characters over and over, and a data asset is stored as it is. Klar
compiles it once per version of the file (TrackerBlocker). `ship` runs this
for every release; the new list replaces the old one only if it has at
least MIN_RULES rules and WebKit compiles it (check_tracker_list.swift),
since one rule WebKit rejects fails the whole list.

What WebKit can't do is left out and counted: regular expressions, cosmetic
filters (hiding parts of pages; EasyPrivacy has few), and options that
rewrite or redirect a request rather than block it. Exceptions (@@) become
ignore-previous-rules after the blocking rules, then $important rules, and
last a rule that never blocks the page itself: a tab's own address always
loads, only what it loads from trackers doesn't.

Usage: scripts/update_tracker_list.py [easyprivacy.txt] [output folder]
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zlib

LIST_URL = "https://easylist.to/easylist/easyprivacy.txt"
OUTPUT = os.path.join(os.path.dirname(__file__), "..", "Klar", "Assets.xcassets", "TrackerBlockList.dataset")
CHECKER = os.path.join(os.path.dirname(__file__), "check_tracker_list.swift")
# EasyPrivacy has about 56,000; far fewer means a download cut short
MIN_RULES = 30_000

# WebKit's resource types for Adblock Plus's
TYPES = {
    "script": ["script"],
    "image": ["image"],
    "stylesheet": ["style-sheet"],
    "font": ["font"],
    "media": ["media"],
    "xmlhttprequest": ["raw"],
    "websocket": ["raw"],
    "other": ["raw"],
    "ping": ["ping"],
    "beacon": ["ping"],
    "subdocument": ["document"],
    "popup": ["popup"],
}
ALL_TYPES = sorted({t for ts in TYPES.values() for t in ts if t != "popup"} | {"svg-document"})
# Options that leave the rule as it is
IGNORED = {"match-case", "important", "all"}
# Options that change what the rule does to something WebKit can't do
UNSUPPORTED = {"redirect", "redirect-rule", "rewrite", "csp", "removeparam", "removeheader", "method",
               "header", "permissions", "replace", "denyallow", "to", "badfilter", "elemhide",
               "generichide", "specifichide", "genericblock", "content", "jsinject", "urlblock",
               "cookie", "stealth", "network", "object", "object-subrequest", "webrtc"}

HOST_CHARS = re.compile(r"[a-z0-9.-]+")
DOMAIN = re.compile(r"~?[a-z0-9][a-z0-9.-]*[a-z0-9]")
# What `^` stands for: anything but a letter, digit or one of _-.%
SEPARATOR = "[^a-zA-Z0-9_.%-]"


def escape(text):
    return re.sub(r"([.?+(){}\[\]\\$|])", r"\\\1", text)


def url_filter(pattern):
    """The Adblock Plus pattern as WebKit's regular expression, or None."""
    if not pattern.isascii() or not pattern:
        return None
    start, end = "", ""
    if pattern.startswith("||"):
        pattern = pattern[2:]
        # The host, with any subdomain, after the scheme
        start = r"^[^:]+://+([^:/]+\.)?"
        host = HOST_CHARS.match(pattern)
        # A host on its own ends there: a port or the path comes next
        if host and pattern[host.end():host.end() + 1] == "^":
            start += escape(host.group()) + "[:/]"
            pattern = pattern[host.end() + 1:]
    elif pattern.startswith("|"):
        start, pattern = "^", pattern[1:]
    if pattern.endswith("|"):
        end, pattern = "$", pattern[:-1]
    if pattern.endswith("^") and not end:
        # A separator or the end of the address
        end, pattern = "(" + SEPARATOR + ".*)?$", pattern[:-1]
    body = "".join(".*" if c == "*" else SEPARATOR if c == "^" else escape(c) for c in pattern)
    regex = start + body + end
    # A leading or trailing .* matches anyway, and makes WebKit's compiler slower
    if not start:
        regex = regex.removeprefix(".*")
    if not end:
        regex = regex.removesuffix(".*")
    return regex or ".*"


def convert(line, skipped):
    """(kind, rule) for one line of the list, kind being block, exception or important."""
    line = line.strip()
    if not line or line.startswith(("!", "[")):
        return None
    if re.search(r"#[@?$%]?#|#@\$#|#@%#", line):
        skipped["cosmetic"] += 1
        return None
    exception = line.startswith("@@")
    if exception:
        line = line[2:]
    pattern, options = line, ""
    if "$" in line and not (line.startswith("/") and line.endswith("/")):
        pattern, _, options = line.rpartition("$")
    if pattern.startswith("/") and pattern.endswith("/") and len(pattern) > 1:
        skipped["regular expression"] += 1
        return None

    trigger, important = {}, False
    types, not_types = [], []
    for option in filter(None, options.split(",")):
        name, _, value = option.partition("=")
        negated = name.startswith("~")
        name = name.lstrip("~")
        if name in ("third-party", "3p"):
            trigger["load-type"] = ["first-party" if negated else "third-party"]
        elif name in ("first-party", "1p"):
            trigger["load-type"] = ["third-party" if negated else "first-party"]
        elif name in TYPES:
            (not_types if negated else types).extend(TYPES[name])
        elif name == "document" and exception and not negated:
            types.append("document-exception")
        elif name == "domain":
            domains = value.split("|")
            if not all(DOMAIN.fullmatch(d) for d in domains):
                skipped["domain WebKit can't match"] += 1
                return None
            included = ["*" + d for d in domains if not d.startswith("~")]
            excluded = ["*" + d[1:] for d in domains if d.startswith("~")]
            if included and excluded:
                skipped["domain both included and excluded"] += 1
                return None
            trigger["if-domain" if included else "unless-domain"] = included or excluded
        elif name == "important":
            important = True
        elif name in IGNORED:
            pass
        else:
            skipped["option " + (name if name in UNSUPPORTED else "unknown: " + name)] += 1
            return None

    regex = url_filter(pattern)
    if regex is None:
        skipped["not ASCII"] += 1
        return None
    trigger = {"url-filter": regex, **trigger}
    if "document-exception" in types:
        # @@||site^$document: nothing is blocked on that site's pages
        if not (pattern.startswith("||") and HOST_CHARS.fullmatch(pattern[2:].rstrip("^"))):
            skipped["document exception that isn't a site"] += 1
            return None
        return "exception", {"trigger": {"url-filter": ".*", "if-domain": ["*" + pattern[2:].rstrip("^")]},
                             "action": {"type": "ignore-previous-rules"}}
    if not_types and not types:
        types = [t for t in ALL_TYPES if t not in not_types]
    if types:
        trigger["resource-type"] = sorted(set(types))
        # A frame, not the page itself
        if "document" in types:
            trigger["load-context"] = ["child-frame"]
    action = "ignore-previous-rules" if exception else "block"
    kind = "exception" if exception else "important" if important else "block"
    return kind, {"trigger": trigger, "action": {"type": action}}


def main():
    source = sys.argv[1] if len(sys.argv) > 1 else None
    output = sys.argv[2] if len(sys.argv) > 2 else OUTPUT
    if source:
        text = open(source, encoding="utf-8").read()
    else:
        print(f"Downloading {LIST_URL}")
        request = urllib.request.Request(LIST_URL, headers={"User-Agent": "Klar tracker list updater"})
        with urllib.request.urlopen(request) as response:
            text = response.read().decode("utf-8")
    version = re.search(r"^! Version: (\S+)", text, re.M).group(1)

    from collections import Counter
    skipped = Counter()
    rules = {"block": [], "exception": [], "important": []}
    seen = set()
    for line in text.splitlines():
        converted = convert(line, skipped)
        if not converted:
            continue
        kind, rule = converted
        key = json.dumps(rule, sort_keys=True)
        if key in seen:
            skipped["duplicate"] += 1
            continue
        seen.add(key)
        rules[kind].append(rule)

    # The page itself always loads (a tab opened on a tracker's own site)
    top = {"trigger": {"url-filter": ".*", "resource-type": ["document"], "load-context": ["top-frame"]},
           "action": {"type": "ignore-previous-rules"}}
    everything = rules["block"] + rules["exception"] + rules["important"] + [top]
    data = ("[\n" + ",\n".join(json.dumps(r, separators=(",", ":")) for r in everything) + "\n]\n").encode()
    deflate = zlib.compressobj(9, zlib.DEFLATED, -15)
    compressed = deflate.compress(data) + deflate.flush()

    # `ship` reads this line
    print(f"EasyPrivacy {version}: {len(everything):,} rules ({len(rules['block']):,} blocking, "
          f"{len(rules['exception']):,} exceptions, {len(rules['important']):,} important), "
          f"{len(data) / 1e6:.1f} MB, {len(compressed) / 1e3:.0f} KB compressed")
    for reason, count in skipped.most_common():
        print(f"  left out: {count} {reason}")

    # The list in the app stays as it is unless the new one is whole and WebKit takes it
    if len(rules["block"]) < MIN_RULES:
        sys.exit(f"Only {len(rules['block'])} blocking rules, fewer than {MIN_RULES:,}: the download looks cut short")
    with tempfile.TemporaryDirectory() as folder:
        candidate = os.path.join(folder, "trackers.json.deflate")
        with open(candidate, "wb") as f:
            f.write(compressed)
        # Its line after this script's, which a pipe would otherwise hold back
        sys.stdout.flush()
        if subprocess.run(["xcrun", "swift", CHECKER, candidate]).returncode != 0:
            sys.exit("Kept the list that was there")
        os.makedirs(output, exist_ok=True)
        shutil.move(candidate, os.path.join(output, "trackers.json.deflate"))
    with open(os.path.join(output, "Contents.json"), "w") as f:
        json.dump({"data": [{"filename": "trackers.json.deflate", "idiom": "universal",
                             "universal-type-identifier": "public.data"}],
                   "info": {"author": "xcode", "version": 1}}, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
