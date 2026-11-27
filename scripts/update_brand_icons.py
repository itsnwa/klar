#!/usr/bin/env python3
"""Regenerates the brand icons the icomoji picker offers for groups and spaces
(Klar/Assets.xcassets/brands/brand-<name>.imageset) from Simple Icons
(https://simpleicons.org), and the list of where each one comes from and its
license: docs/brand-icons.md for the repository, and BrandIconCredits in the
asset catalog's Acknowledgements folder for Klar's acknowledgements page.

Simple Icons draws each brand as a single shape in a 24 × 24 box. Klar shows it
as a template image, tinted like an SF Symbol, and writes it as an SVG 16 points
square, the size its icons have always been. Simple Icons is CC0, but some icons
list a license of the brand's own, and those that don't allow commercial use are
left out. Either way the logos are their owners' trademarks.

Klar's names stay as they are, since a group's or space's icon is stored by name
(and synced): BRANDS maps them to Simple Icons' slugs. Icons in brands/ that
aren't in BRANDS are removed; the picker's icons with no artwork any more are
CuratedFolderIcons.retiredBrandIcons, which this checks against.

Usage: scripts/update_brand_icons.py [simple-icons version, default the latest]
"""

import io
import json
import os
import re
import shutil
import sys
import tarfile
import urllib.request

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
BRANDS_DIR = os.path.join(ROOT, "Klar", "Assets.xcassets", "brands")
CREDITS = os.path.join(ROOT, "docs", "brand-icons.md")
ACKNOWLEDGEMENTS_DIR = os.path.join(ROOT, "Klar", "Assets.xcassets", "Acknowledgements")
APP_CREDITS = os.path.join(ACKNOWLEDGEMENTS_DIR, "BrandIconCredits.dataset")
CURATED = os.path.join(ROOT, "Klar", "Features", "Sidebar", "Utilities", "CuratedFolderIcons.swift")

# Klar's name for each brand icon, and its Simple Icons slug where that differs.
BRANDS = {
    # Languages
    "swift": None, "c": None, "cplusplus": None, "java": "openjdk", "kotlin": None, "scala": None,
    "groovy": "apachegroovy", "go": None, "rust": None, "python": None, "ruby": None, "php": None,
    "perl": None, "r": None, "dart": None, "clojure": None, "javascript": None, "typescript": None,
    "html5": None, "css3": "css", "sass": None, "less": None, "bash": "gnubash", "latex": None, "markdown": None,
    "processing": "processingfoundation",
    # Frameworks
    "react": None, "redux": None, "vuejs": "vuedotjs", "angularjs": "angular", "svelte": None,
    "ember": "emberdotjs", "backbonejs": "backbonedotjs", "jquery": None, "nextjs": "nextdotjs",
    "nuxtjs": "nuxt", "gatsby": None, "hugo": None, "eleventy": None, "meteor": None,
    "nodejs": "nodedotjs", "express": None, "django": None, "flask": None, "rails": "rubyonrails",
    "laravel": None, "symfony": None, "spring": None, "dotnet": None, "flutter": None, "electron": None,
    "bootstrap": None, "d3js": "d3", "threejs": "threedotjs", "opengl": None,
    "handlebars": "handlebarsdotjs", "babel": None, "grunt": None, "gulp": None, "npm": None,
    "wordpress": None, "drupal": None, "webflow": None, "unity": None,
    # AI
    "anthropic": None, "deepseek": None, "mistral": "mistralai", "perplexity": None, "ollama": None,
    "openrouter": None, "mcp": "modelcontextprotocol", "pytorch": None, "tensorflow": None,
    # Tools
    "git": None, "github": None, "gitlab": None, "docker": None, "kubernetes": None, "firebase": None,
    "vercel": None, "mysql": None, "postgresql": None, "xcode": None, "vim": None, "emacs": "gnuemacs",
    "figma": None, "sketch": None, "blender": None, "maya": "autodeskmaya", "jira": None,
    "raycast": None, "arduino": None, "raspberrypi": None, "gnu": None,
    # Companies
    "apple": None, "google": None, "meta": None, "alibaba": "alibabadotcom", "x": None, "youtube": None,
}

PATH_DATA = re.compile(r"^[MmLlHhVvCcSsQqTtAaZzEe0-9.,+\- ]+$")
NUMBER = re.compile(r"[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?")
# How many numbers each path command takes (repeated for each segment)
ARGUMENTS = {"M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "S": 4, "Q": 4, "T": 2, "A": 7, "Z": 0}


def download(url):
    print(f"Downloading {url}")
    request = urllib.request.Request(url, headers={"User-Agent": "Klar brand icons updater"})
    with urllib.request.urlopen(request) as response:
        return response.read()


def simple_icons(version):
    """Simple Icons' version, its icons' data by slug, and a function reading an icon's SVG."""
    meta = json.loads(download(f"https://registry.npmjs.org/simple-icons/{version}"))
    # Read from the archive in memory: nothing in it is written to disk as it is
    archive = tarfile.open(fileobj=io.BytesIO(download(meta["dist"]["tarball"])), mode="r:gz")

    def read(name):
        return archive.extractfile(f"package/{name}").read().decode()

    data = {icon["slug"]: icon for icon in json.loads(read("data/simple-icons.json"))}
    return meta["version"], data, lambda slug: read(f"icons/{slug}.svg")


def spelled_out(path):
    """The path's data with every number apart. Simple Icons packs an arc's
    flags with the number after them ("a1 1 0 011 1"), which is valid SVG but
    CoreSVG, and so the asset catalog, reads as too few numbers, drawing the
    icon wrong."""
    commands, position, command, count = [], 0, None, 0
    while position < len(path):
        character = path[position]
        if character in " ,":
            position += 1
        elif character.upper() in ARGUMENTS:
            command, count = character, 0
            commands.append([character])
            position += 1
        else:
            if command is None or ARGUMENTS[command.upper()] == 0:
                raise ValueError(f"a number without a command at {position}")
            if command in "Aa" and count % 7 in (3, 4):
                # An arc's large-arc and sweep flags: one digit each
                if character not in "01":
                    raise ValueError(f"an arc flag that isn't 0 or 1 at {position}")
                number, position = character, position + 1
            else:
                match = NUMBER.match(path, position)
                if not match:
                    raise ValueError(f"unreadable path data at {position}")
                number, position = match.group(), match.end()
            commands[-1].append(number)
            count += 1
    return "".join(command[0] + " ".join(command[1:]) for command in commands)


def icon_svg(source):
    """The icon's one path, in an SVG 16 points square."""
    paths = re.findall(r'<path d="([^"]*)"\s*/>', source)
    if len(paths) != 1 or not PATH_DATA.match(paths[0]):
        raise ValueError("expected a single path")
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24">'
            f'<path d="{spelled_out(paths[0])}"/></svg>\n')


def contents_json(filename):
    contents = {
        "images": [{"filename": filename, "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"},
    }
    return json.dumps(contents, indent=2, separators=(",", " : ")) + "\n"


def is_commercial_use_allowed(icon):
    return "NC" not in icon.get("license", {}).get("type", "").upper().split("-")


def license_text(icon):
    license = icon.get("license")
    if not license:
        return "Not listed"
    kind = "Custom terms" if license["type"] == "custom" else license["type"]
    if "url" in license:
        return f"[{kind}]({license['url']})"
    return kind


def write_credits(version, icons):
    rows = []
    for name, icon in icons:
        links = [f"[Source]({icon['source']})"]
        if "guidelines" in icon:
            links.append(f"[Guidelines]({icon['guidelines']})")
        rows.append(f"| `brand-{name}` | {icon['title']} | {license_text(icon)} | {' · '.join(links)} |")
    text = f"""# Brand icons

The brand icons you can give a group or space in Klar are from [Simple Icons](https://simpleicons.org) {version}, written by `scripts/update_brand_icons.py`. Simple Icons releases its work under [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/). Some icons are available under a license of their own, listed below; "Not listed" means Simple Icons has no license data for that icon.

All brand names and logos are trademarks of their respective owners. Klar shows them so you can mark a group or space with a brand you know, which doesn't imply any affiliation with or endorsement by their owners. If you own one of these brands and want its icon removed, please open an issue.

| Icon | Brand | License | Links |
| --- | --- | --- | --- |
"""
    os.makedirs(os.path.dirname(CREDITS), exist_ok=True)
    with open(CREDITS, "w") as file:
        file.write(text + "\n".join(rows) + "\n")


def write_app_credits(version, icons):
    """The credits the app shows on klar://acknowledgements (AcknowledgementsPage), as a data asset."""
    credits = {"version": version, "icons": []}
    for name, icon in icons:
        license = icon.get("license", {})
        credits["icons"].append({
            "name": f"brand-{name}",
            "brand": icon["title"],
            "license": ("Custom terms" if license.get("type") == "custom" else license.get("type")),
            "licenseURL": license.get("url"),
            "source": icon["source"],
        })
    os.makedirs(APP_CREDITS, exist_ok=True)
    group = os.path.join(ACKNOWLEDGEMENTS_DIR, "Contents.json")
    if not os.path.exists(group):
        with open(group, "w") as file:
            file.write(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2, separators=(",", " : ")) + "\n")
    with open(os.path.join(APP_CREDITS, "brand-icon-credits.json"), "w") as file:
        file.write(json.dumps(credits, indent=2, ensure_ascii=False) + "\n")
    contents = {
        "data": [{"filename": "brand-icon-credits.json", "idiom": "universal", "universal-type-identifier": "public.json"}],
        "info": {"author": "xcode", "version": 1},
    }
    with open(os.path.join(APP_CREDITS, "Contents.json"), "w") as file:
        file.write(json.dumps(contents, indent=2, separators=(",", " : ")) + "\n")


def curated_names(block, pattern=r'"brand-([a-z0-9]+)"'):
    """The `brand-…` names in a declaration of CuratedFolderIcons.swift."""
    source = open(CURATED).read()
    start = source.index(f"static let {block}")
    end = source.index("\n\n", start)
    return set(re.findall(pattern, source[start:end]))


def main():
    version, data, read_svg = simple_icons(sys.argv[1] if len(sys.argv) > 1 else "latest")
    written, left_out = [], []
    for name, slug in BRANDS.items():
        slug = slug or name
        icon = data.get(slug)
        if icon is None:
            left_out.append(f"{name} (no {slug} in Simple Icons)")
            continue
        if not is_commercial_use_allowed(icon):
            left_out.append(f"{name} ({icon['license']['type']})")
            continue
        svg = icon_svg(read_svg(slug))
        folder = os.path.join(BRANDS_DIR, f"brand-{name}.imageset")
        if os.path.isdir(folder):
            shutil.rmtree(folder)
        os.makedirs(folder)
        with open(os.path.join(folder, f"brand-{name}.svg"), "w") as file:
            file.write(svg)
        with open(os.path.join(folder, "Contents.json"), "w") as file:
            file.write(contents_json(f"brand-{name}.svg"))
        written.append((name, icon))

    kept = {f"brand-{name}.imageset" for name, _ in written}
    removed = sorted(entry for entry in os.listdir(BRANDS_DIR) if entry.endswith(".imageset") and entry not in kept)
    for entry in removed:
        shutil.rmtree(os.path.join(BRANDS_DIR, entry))

    write_credits(version, written)
    write_app_credits(version, written)
    print(f"Simple Icons {version}: wrote {len(written)} icons, {os.path.relpath(CREDITS, ROOT)} and their credits for the app")
    if removed:
        print("Removed: " + ", ".join(entry.removeprefix("brand-").removesuffix(".imageset") for entry in removed))
    if left_out:
        print("Left out: " + ", ".join(left_out))

    names = {name for name, _ in written}
    offered = curated_names("brandGroups")
    retired = curated_names("retiredBrandIcons") | curated_names("renamedBrandIcons", r'"brand-([a-z0-9]+)"\s*:')
    if offered - names:
        print("In the picker without an icon (retire them in CuratedFolderIcons.swift): " +
              ", ".join(sorted(offered - names)))
    if names - offered:
        print("Not in the picker (add them to brandGroups): " + ", ".join(sorted(names - offered)))
    if retired & names:
        print("Retired in CuratedFolderIcons.swift but written: " + ", ".join(sorted(retired & names)))


if __name__ == "__main__":
    main()
