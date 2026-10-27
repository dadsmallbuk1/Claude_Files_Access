#!/usr/bin/env python3
"""Inject ClaudeBridge.framework into an iOS app's IPA (built for Madeira).

The bridge runs inside the app's own process, so Claude can read and change that
app's data folder through your Claude Files relay without the Files picker.

Usage (Python 3.8+, any OS, no extra packages):

    python inject_claude_bridge.py Madeira-0.1.3.ipa ClaudeBridge.framework.zip \
        --connector-url https://claude-files-relay.<you>.workers.dev/<secret>/mcp

Writes Madeira-0.1.3-claude.ipa next to the input. Sign and install it as usual
(e.g. with Signulous): the signer signs the added framework along with the app.

--connector-url is the URL shown in the Claude Files app. Reusing it means the
connector you already added in Claude keeps working, but only one of the two (the
Claude Files app or the patched app) can be connected at a time. Pass --relay
instead to generate a fresh secret and get a new connector URL to add in Claude.
"""

import argparse
import io
import json
import os
import plistlib
import secrets
import struct
import sys
import zipfile
from urllib.parse import urlparse

FRAMEWORK = "ClaudeBridge.framework"
# The short form needs an LC_RPATH of @executable_path/Frameworks (Swift apps have one)
# and takes less of the scarce space after the load commands.
RPATH_LOAD_PATH = "@rpath/ClaudeBridge.framework/ClaudeBridge"
FULL_LOAD_PATH = "@executable_path/Frameworks/ClaudeBridge.framework/ClaudeBridge"
LOAD_PATHS = (RPATH_LOAD_PATH, FULL_LOAD_PATH)

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
LC_LOAD_DYLIB = 0xC
LC_SEGMENT_64 = 0x19
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_RPATH = 0x8000001C


class InjectError(Exception):
    pass


def parse_connector_url(url):
    parsed = urlparse(url.strip())
    parts = [p for p in parsed.path.split("/") if p]
    if parsed.scheme not in ("https", "http") or len(parts) < 2 or parts[-1] != "mcp":
        raise InjectError("--connector-url should look like https://<relay>/<secret>/mcp")
    base = f"{parsed.scheme}://{parsed.netloc}" + "".join("/" + p for p in parts[:-2])
    return base, parts[-2]


def dylib_command(path):
    name = path.encode() + b"\0"
    size = (24 + len(name) + 7) & ~7
    # cmd, cmdsize, name offset, timestamp, current_version, compatibility_version
    return struct.pack("<IIIIII", LC_LOAD_DYLIB, size, 24, 2, 0x10000, 0x10000) + name.ljust(size - 24, b"\0")


def load_commands(data, offset):
    magic, _, _, _, ncmds, sizeofcmds = struct.unpack_from("<IiiIII", data, offset)
    position = offset + 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, position)
        yield position, cmd, cmdsize
        position += cmdsize


def inject_slice(data, offset, size):
    """Adds the load command to one 64-bit Mach-O slice. Returns False if already present."""
    magic, cputype, _, _, ncmds, sizeofcmds = struct.unpack_from("<IiiIII", data, offset)
    if magic != MH_MAGIC_64:
        raise InjectError(f"Unsupported Mach-O slice (magic {magic:#x}); only 64-bit apps are supported.")

    first_content = size
    has_frameworks_rpath = False
    for position, cmd, cmdsize in load_commands(data, offset):
        if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_RPATH):
            name_offset = struct.unpack_from("<I", data, position + 8)[0]
            name = bytes(data[position + name_offset : position + cmdsize]).split(b"\0")[0].decode(errors="replace")
            if cmd != LC_RPATH and name in LOAD_PATHS:
                return False
            if cmd == LC_RPATH and name.rstrip("/") == "@executable_path/Frameworks":
                has_frameworks_rpath = True
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", data, position + 64)[0]
            fileoff, filesize = struct.unpack_from("<QQ", data, position + 40)
            if filesize and fileoff:
                first_content = min(first_content, fileoff)
            for index in range(nsects):
                section = position + 72 + index * 80
                sect_size, sect_offset = struct.unpack_from("<QI", data, section + 40)
                if sect_size and sect_offset:
                    first_content = min(first_content, sect_offset)

    command = dylib_command(RPATH_LOAD_PATH if has_frameworks_rpath else FULL_LOAD_PATH)
    start = offset + 32 + sizeofcmds
    free = first_content - 32 - sizeofcmds
    if len(command) > free:
        raise InjectError(
            f"Not enough free space after the load commands to add the framework "
            f"({free} bytes free, {len(command)} needed)."
        )
    if any(data[start : start + len(command)]):
        raise InjectError("The space after the load commands is not empty; refusing to overwrite it.")
    data[start : start + len(command)] = command
    struct.pack_into("<II", data, offset + 16, ncmds + 1, sizeofcmds + len(command))
    return True


def inject_executable(data):
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        count = struct.unpack_from(">I", data, 4)[0]
        changed = False
        for index in range(count):
            if magic == FAT_MAGIC:
                _, _, slice_offset, slice_size, _ = struct.unpack_from(">iiIII", data, 8 + index * 20)
            else:
                _, _, slice_offset, slice_size, _, _ = struct.unpack_from(">iiQQII", data, 8 + index * 32)
            changed |= inject_slice(data, slice_offset, slice_size)
        return changed
    return inject_slice(data, 0, len(data))


def find_app(names):
    apps = {n.split("/")[1] for n in names if n.startswith("Payload/") and n.count("/") >= 2 and n.split("/")[1].endswith(".app")}
    if len(apps) != 1:
        raise InjectError(f"Expected one app inside Payload/, found: {sorted(apps) or 'none'}")
    return f"Payload/{apps.pop()}/"


def read_framework(path):
    """Returns {relative path inside ClaudeBridge.framework: bytes} from a folder or zip."""
    files = {}
    if os.path.isdir(path):
        root = path.rstrip("/\\")
        for folder, _, names in os.walk(root):
            for name in names:
                full = os.path.join(folder, name)
                files[os.path.relpath(full, root).replace(os.sep, "/")] = open(full, "rb").read()
    else:
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                if info.is_dir():
                    continue
                marker = info.filename.find(FRAMEWORK + "/")
                if marker < 0:
                    continue
                files[info.filename[marker + len(FRAMEWORK) + 1 :]] = archive.read(info)
    if "ClaudeBridge" not in files or "Info.plist" not in files:
        raise InjectError(f"{path} does not contain {FRAMEWORK} (with its ClaudeBridge binary and Info.plist).")
    return files


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("ipa", help="The app's IPA, e.g. Madeira-0.1.3.ipa")
    parser.add_argument("framework", help="ClaudeBridge.framework folder, or the zip downloaded from CI")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--connector-url", help="Connector URL from the Claude Files app (reuses its secret)")
    group.add_argument("--relay", help="Relay base URL; a new secret is generated")
    parser.add_argument("--read-only", action="store_true", help="Don't let Claude change files")
    parser.add_argument("-o", "--output", help="Output IPA (default: <input>-claude.ipa)")
    args = parser.parse_args()

    if args.connector_url:
        relay, token = parse_connector_url(args.connector_url)
    else:
        relay = args.relay.strip().rstrip("/")
        if not relay.startswith(("https://", "http://")):
            relay = "https://" + relay
        token = secrets.token_urlsafe(32)
    if len(token) < 32:
        raise InjectError("The secret in the connector URL is too short.")

    framework = read_framework(args.framework)
    framework["ClaudeBridge.json"] = json.dumps(
        {"relayURL": relay, "token": token, "allowChanges": not args.read_only}, indent=2
    ).encode()

    output = args.output or os.path.splitext(args.ipa)[0] + "-claude.ipa"
    with zipfile.ZipFile(args.ipa) as source:
        names = source.namelist()
        app = find_app(names)
        info = plistlib.loads(source.read(app + "Info.plist"))
        executable_name = app + info["CFBundleExecutable"]
        executable = bytearray(source.read(executable_name))
        injected = inject_executable(executable)
        framework_prefix = app + "Frameworks/" + FRAMEWORK + "/"

        print(f"App: {info.get('CFBundleDisplayName') or info.get('CFBundleName')} ({info.get('CFBundleIdentifier')})")
        print("Load command: " + ("added" if injected else "already present"))
        with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as target:
            for item in source.infolist():
                if item.filename.startswith(framework_prefix):
                    continue  # replaced below
                data = bytes(executable) if item.filename == executable_name else source.read(item)
                target.writestr(item, data, compress_type=item.compress_type)
            for relative, data in sorted(framework.items()):
                entry = zipfile.ZipInfo(framework_prefix + relative)
                entry.external_attr = (0o755 if relative == "ClaudeBridge" else 0o644) << 16
                entry.compress_type = zipfile.ZIP_DEFLATED
                target.writestr(entry, data)

    print(f"Wrote {output}")
    print(f"Connector URL for Claude: {relay}/{token}/mcp")
    if args.connector_url:
        print("This reuses the Claude Files app's secret: keep that app closed while the patched app is open.")
    print("Next: sign and install the new IPA (e.g. Signulous), open it, then ask Claude for device_status.")
    print("The bridge logs to Files > On My iPhone > <app> > ClaudeBridge > bridge.log")


if __name__ == "__main__":
    try:
        main()
    except InjectError as error:
        print(f"Error: {error}", file=sys.stderr)
        sys.exit(1)
