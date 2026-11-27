#!/usr/bin/env python3
"""Regenerates the emoji the icomoji picker offers
(Klar/Assets.xcassets/EmojiCatalog.dataset/emoji-catalog.txt).

From Unicode's emoji-test.txt: every fully-qualified emoji in its group and
order (the order Apple's own picker follows), without skin-tone variants,
which can still be typed into the picker's search. Writes a "# Group" line
per group, then one "emoji<TAB>name" line per emoji.

Usage: scripts/update_emoji_catalog.py [version]
The version defaults to the newest one every macOS Klar runs on draws.
"""

import os
import sys
import urllib.request

VERSION = sys.argv[1] if len(sys.argv) > 1 else "16.0"
URL = f"https://unicode.org/Public/emoji/{VERSION}/emoji-test.txt"

OUTPUT = os.path.join(os.path.dirname(__file__), "..", "Klar", "Assets.xcassets",
                      "EmojiCatalog.dataset", "emoji-catalog.txt")

# Hair and skin tones on their own; not something to pick.
SKIPPED_GROUPS = {"Component"}
SKIN_TONES = set(range(0x1F3FB, 0x1F400))

# Shorter names for the picker's section headers.
GROUP_TITLES = {
    "Smileys & Emotion": "Smileys",
    "People & Body": "People",
}


def main():
    with urllib.request.urlopen(URL) as response:
        lines = response.read().decode("utf-8").splitlines()

    output = []
    group = None
    count = 0
    for line in lines:
        if line.startswith("# group:"):
            group = line.split(":", 1)[1].strip()
            if group not in SKIPPED_GROUPS:
                output.append("# " + GROUP_TITLES.get(group, group))
            continue
        if group in SKIPPED_GROUPS or not line or line.startswith("#"):
            continue
        codes, rest = line.split(";", 1)
        if rest.split("#", 1)[0].strip() != "fully-qualified":
            continue
        scalars = [int(code, 16) for code in codes.split()]
        if any(scalar in SKIN_TONES for scalar in scalars):
            continue
        # "# 😀 E1.0 grinning face"
        name = rest.split("#", 1)[1].strip().split(" ", 2)[2]
        output.append("".join(chr(scalar) for scalar in scalars) + "\t" + name)
        count += 1

    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    with open(OUTPUT, "w", encoding="utf-8") as file:
        file.write("\n".join(output) + "\n")
    print(f"Wrote {count} emoji to {os.path.normpath(OUTPUT)}")


if __name__ == "__main__":
    main()
