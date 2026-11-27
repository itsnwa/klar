---
name: add-xcode-file
description: Add a Swift (or other source) file to the Klar Xcode project so it shows up in the navigator AND gets compiled. Use this whenever you create a new file with the Write tool inside the Klar source tree — Xcode-managed projects don't pick up files automatically and missing pbxproj entries surface as `Cannot find 'TypeName' in scope` build errors.
---

# Add a file to the Klar Xcode project

Klar uses a single-target `Klar.xcodeproj` with classic Xcode-managed groups (not file-system synchronized folders). New `.swift` files written to disk must be registered in `project.pbxproj` in **four** places before they compile:

1. `PBXBuildFile` — declares the file is compiled into a target.
2. `PBXFileReference` — declares the file exists.
3. The enclosing `PBXGroup`'s `children` list — places it in the navigator.
4. The target's `PBXSourcesBuildPhase` `files` list — adds it to the Compile Sources phase.

A file missing from (1) and (4) surfaces at build time as `Cannot find '<TypeName>' in scope`, even though SourceKit may compile it fine in isolation (SourceKit indexes the workspace; the build phase is what actually compiles).

## When to use

Use this skill any time you create a brand-new source file under `Klar/` with the `Write` tool. Editing existing files needs no project-file changes; this is only for additions.

If the file is being added to a **test target**, this skill needs adapting (Klar currently has a single `Klar` target — see "Limitations" below).

## Procedure

The script below uses an **anchor-file pattern**: find a sibling file already registered in the same Xcode group, and clone its four registration lines for the new file with fresh GUIDs. This avoids parsing the pbxproj's group hierarchy from scratch.

1. Pick an anchor: an existing `.swift` file that lives in the **same Xcode group** (typically the same folder on disk) as the new file. Any sibling works.
2. Run the script with the new file's basename and the anchor's basename.

```bash
python3 - <<'PY'
import re
import secrets
import subprocess
import sys

# ---- EDIT THESE TWO LINES ----
NEW_FILE = "KlarCompactHoverButton.swift"          # basename of the new file
ANCHOR   = "SidebarCollectionHeaderView.swift"     # basename of an existing sibling
# ------------------------------

ROOT = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()
PBXPROJ = f"{ROOT}/Klar.xcodeproj/project.pbxproj"

with open(PBXPROJ) as f:
    s = f.read()

# Anchor must be registered to clone from.
if f"/* {ANCHOR} */" not in s:
    sys.exit(f"Anchor not found in pbxproj: {ANCHOR}")
if f"/* {NEW_FILE} */" in s:
    sys.exit(f"Already registered: {NEW_FILE}")

# Pull the anchor's two GUIDs (PBXBuildFile id and PBXFileReference id).
m_build = re.search(
    rf'\t\t([0-9A-F]{{24}}) /\* {re.escape(ANCHOR)} in Sources \*/ = \{{isa = PBXBuildFile; fileRef = ([0-9A-F]{{24}}) /\* {re.escape(ANCHOR)} \*/; \}};',
    s,
)
if not m_build:
    sys.exit(f"Could not find PBXBuildFile entry for anchor {ANCHOR}")
anchor_build_id, anchor_file_id = m_build.group(1), m_build.group(2)

def gen_id():
    while True:
        i = secrets.token_hex(12).upper()
        if i not in s:
            return i

new_build_id = gen_id()
new_file_id  = gen_id()

# 1. PBXBuildFile — clone the anchor's line, add the new line right after.
build_pat = (
    rf'(\t\t{anchor_build_id} /\* {re.escape(ANCHOR)} in Sources \*/ '
    rf'= \{{isa = PBXBuildFile; fileRef = {anchor_file_id} /\* {re.escape(ANCHOR)} \*/; \}};\n)'
)
new_build_line = f'\t\t{new_build_id} /* {NEW_FILE} in Sources */ = {{isa = PBXBuildFile; fileRef = {new_file_id} /* {NEW_FILE} */; }};\n'
s, n1 = re.subn(build_pat, lambda m: m.group(1) + new_build_line, s, count=1)

# 2. PBXFileReference — match the anchor's full reference line (its
#    attribute set varies between files: some have `includeInIndex = 1`,
#    others don't), then clone with the path swapped to the new file.
m_ref = re.search(
    rf'\t\t{anchor_file_id} /\* {re.escape(ANCHOR)} \*/ = \{{isa = PBXFileReference;([^}}]+)\}};\n',
    s,
)
if not m_ref:
    sys.exit(f"No PBXFileReference entry for {ANCHOR}")
# A path with anything but letters, digits, `_`, `.` or `/` (a `+` in
# `Manager+CloudSync.swift`, a space) must be quoted, or Xcode can't open
# the project. The anchor's path may be quoted as well.
def pbx_string(value):
    return value if re.fullmatch(r'[A-Za-z0-9_./]+', value) else f'"{value}"'
new_ref_attrs = re.sub(
    rf'path = "?{re.escape(ANCHOR)}"?;',
    lambda m: f'path = {pbx_string(NEW_FILE)};',
    m_ref.group(1),
)
new_ref_line = f'\t\t{new_file_id} /* {NEW_FILE} */ = {{isa = PBXFileReference;{new_ref_attrs}}};\n'
s, n2 = re.subn(re.escape(m_ref.group(0)), lambda m: m.group(0) + new_ref_line, s, count=1)

# 3. PBXGroup children — add to the same group as the anchor.
group_pat = rf'(\t\t\t\t{anchor_file_id} /\* {re.escape(ANCHOR)} \*/,\n)'
new_group_line = f'\t\t\t\t{new_file_id} /* {NEW_FILE} */,\n'
s, n3 = re.subn(group_pat, lambda m: m.group(1) + new_group_line, s, count=1)

# 4. PBXSourcesBuildPhase — add to the same Compile Sources list as the anchor.
src_pat = rf'(\t\t\t\t{anchor_build_id} /\* {re.escape(ANCHOR)} in Sources \*/,\n)'
new_src_line = f'\t\t\t\t{new_build_id} /* {NEW_FILE} in Sources */,\n'
s, n4 = re.subn(src_pat, lambda m: m.group(1) + new_src_line, s, count=1)

if (n1, n2, n3, n4) != (1, 1, 1, 1):
    sys.exit(f"Insertion mismatch (build={n1}, ref={n2}, group={n3}, src={n4}) — pbxproj layout may have changed; inspect manually.")

with open(PBXPROJ, 'w') as f:
    f.write(s)

print(f"Added {NEW_FILE} (file id {new_file_id}, build id {new_build_id})")
PY
```

## Verify

```bash
PBXPROJ="$(git rev-parse --show-toplevel)/Klar.xcodeproj/project.pbxproj"
plutil -convert json -o /dev/null "$PBXPROJ" && echo parses
grep -c "<NEW_FILE_BASENAME>" "$PBXPROJ"
```

Expect `4` (one match in each of the four sections). If you see `0` the script aborted; if you see `2` the group/sources insertions failed and the file is registered but not compiled.

## Choosing a good anchor

- Must be an existing `.swift` (or whatever `lastKnownFileType` matches) — the patterns assume `sourcecode.swift`. For non-Swift sources adapt the `lastKnownFileType` token.
- Must live in the **same on-disk folder** as the new file, since classic Xcode groups mirror folder layout via `path = <basename>; sourceTree = "<group>"`.
- The script asserts this implicitly by requiring the anchor exist in the pbxproj.

## Limitations

- **Single target.** Klar has one `PBXNativeTarget`. The script's `PBXSourcesBuildPhase` insertion targets the only Sources phase. If a test target is added later, this skill needs updating to also clone the anchor's entry in the second target.
- **No-op safe.** The script aborts if the file is already registered, so re-running is safe.
- **Doesn't create the .swift file.** Use the `Write` tool first, then run this skill.
- **Doesn't open Xcode.** If Xcode is open, it will reload the pbxproj automatically. Sometimes a `Cmd-Opt-Shift-K` clean is needed if Xcode caches stale state.

## Why not the `xcodeproj` Ruby gem?

The Ruby gem is more robust but requires Ruby + the gem installed, and the operation we need is simple enough (clone one anchor's four entries) that a self-contained Python script is a better fit. If the pbxproj layout changes in a future Xcode release the script's regexes will need adjusting.
