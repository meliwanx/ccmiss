#!/usr/bin/env python3
"""Check Git's publishable source set without printing matching secret values.

Uses only the Python standard library. Run from a clone or a source archive.
An optional --history scan checks every reachable commit before publication.
"""
from __future__ import annotations

import argparse
import ipaddress
import os
import pathlib
import re
import struct
import subprocess
import sys
from urllib.parse import urlsplit

ROOT = pathlib.Path(__file__).resolve().parent.parent
ROOT_FILES = {
    ".gitignore", ".gitattributes", "LICENSE", "README.md", "README.zh-CN.md",
    "SECURITY.md", "CONTRIBUTING.md", "THIRD_PARTY_NOTICES.md", "build.sh",
}
PUBLIC_PNG_ASSETS = {
    "Resources/Brand/ccmiss-logo.png",
    "docs/images/account-workspace.png",
    "docs/images/add-profile.png",
    "docs/images/claude-code-tools.png",
    "docs/images/claude-network-check.png",
}
DOC_NETS = tuple(ipaddress.ip_network(value) for value in
                ("192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24", "2001:db8::/32"))
PUBLIC_SERVICE_IPS = {"1.1.1.1", "1.0.0.1", "8.8.8.8", "9.9.9.9", "223.5.5.5", "160.79.104.0"}
PATTERNS = {
    "private-key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----"),
    "github-token": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{25,}|github_pat_[A-Za-z0-9_]{35,})\b"),
    "cloud-access-key": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "service-api-key": re.compile(r"\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{24,}\b"),
    "slack-token": re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{20,}\b"),
    "signed-token": re.compile(r"\beyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\b"),
}
PATH_PATTERN = re.compile(r"/(?:Users|home|Volumes)/([^/\s\"'`]+)")
URI_PATTERN = re.compile(r"(?:socks5h?|vless|https?)://[^\s\"'`<>]+")
IPV4_PATTERN = re.compile(r"(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])")
FORBIDDEN_PARTS = {".deps", ".build", "dist", "outputs", "node_modules", "backups", "handoff", "private"}
FORBIDDEN_NAMES = {".env", ".DS_Store", "credentials.json", "profiles.json", "state.json", "settings.local.json"}


def git(*args: str) -> bytes:
    return subprocess.check_output(["git", "-C", str(ROOT), *args], stderr=subprocess.DEVNULL)


def allowed(name: str) -> bool:
    p = pathlib.PurePosixPath(name)
    if any(part in FORBIDDEN_PARTS for part in p.parts) or p.name in FORBIDDEN_NAMES:
        return False
    if name in ROOT_FILES:
        return True
    if p.parts[0] == "Sources":
        return p.suffix in {".swift", ".plist"}
    if p.parts[0] == "Tools":
        return p.suffix in {".py", ".swift", ".sh"} or name == "Tools/dependencies.json"
    if p.parts[0] == "docs":
        return p.suffix == ".md" or name in PUBLIC_PNG_ASSETS
    if p.parts[0] == ".github":
        return p.suffix in {".yml", ".yaml", ".md"}
    if p.parts[0] == "Resources":
        return (p.suffix in {".js", ".cjs"} or p.name.endswith("LICENSE.txt") or
                name in {"Resources/mihomo-provenance.json", "Resources/Brand/ccmiss-logo.png"})
    return False


def example_host(host: str | None) -> bool:
    if not host:
        return True  # A dynamic URL prefix is source code, not a static credential.
    host = host.lower()
    if host in {"localhost", "ip", "host", "proxy", "hostname", "server"}:
        return True
    if host.endswith((".example", ".test", ".invalid", ".localhost")) or any(
            host == suffix or host.endswith("." + suffix) for suffix in ("example.com", "example.net", "example.org")):
        return True
    try:
        address = ipaddress.ip_address(host)
        return address.is_loopback or any(address in network for network in DOC_NETS if address.version == network.version)
    except ValueError:
        return False


def findings(name: str, data: bytes) -> list[tuple[int, str]]:
    result: list[tuple[int, str]] = []
    if not allowed(name):
        result.append((1, "unexpected-file"))
    if len(data) > 2 * 1024 * 1024:
        result.append((1, "oversized-file"))
    if name in PUBLIC_PNG_ASSETS:
        # Only explicitly reviewed branding and redacted documentation images
        # may be published. Disallow creator, location and provenance metadata.
        if not data.startswith(b"\x89PNG\r\n\x1a\n"):
            return result + [(1, "invalid-artwork")]
        offset = 8
        try:
            while offset < len(data):
                size = struct.unpack(">I", data[offset:offset + 4])[0]
                kind = data[offset + 4:offset + 8]
                if kind not in {b"IHDR", b"PLTE", b"tRNS", b"IDAT", b"IEND", b"sRGB", b"gAMA", b"cHRM", b"iCCP"}:
                    result.append((1, "artwork-metadata"))
                offset += size + 12
            if offset != len(data):
                result.append((1, "invalid-artwork"))
        except (ValueError, struct.error):
            result.append((1, "invalid-artwork"))
        return result
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return result + [(1, "unexpected-binary")]
    for label, pattern in PATTERNS.items():
        for match in pattern.finditer(text):
            result.append((text.count("\n", 0, match.start()) + 1, label))
    # Third-party author notices must remain intact; never sanitize their license.
    if name.endswith("LICENSE.txt") or name == "LICENSE":
        return result
    for match in PATH_PATTERN.finditer(text):
        if match.group(1).lower() not in {"test", "fixture", "example", "user", "alice", "bob"}:
            result.append((text.count("\n", 0, match.start()) + 1, "personal-absolute-path"))
    for match in URI_PATTERN.finditer(text):
        try:
            url = urlsplit(match.group())
            if (url.username or url.password) and not example_host(url.hostname):
                result.append((text.count("\n", 0, match.start()) + 1, "credential-url"))
        except ValueError:
            pass  # Deliberately malformed URLs are useful parser fixtures.
    for match in IPV4_PATTERN.finditer(text):
        try:
            address = ipaddress.ip_address(match.group())
        except ValueError:
            continue
        if (address.is_global and str(address) not in PUBLIC_SERVICE_IPS and
                not any(address in network for network in DOC_NETS if network.version == 4)):
            result.append((text.count("\n", 0, match.start()) + 1, "unreviewed-public-ip"))
    return sorted(set(result))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--history", action="store_true", help="scan every reachable commit too")
    args = parser.parse_args()
    try:
        if pathlib.Path(git("rev-parse", "--show-toplevel").decode().strip()).resolve() != ROOT:
            raise subprocess.CalledProcessError(1, "git repository boundary")
        names = sorted(set(git("ls-files", "--cached", "--others", "--exclude-standard", "-z").decode().split("\0")) - {""})
        commits = git("rev-list", "--all").decode().splitlines() if args.history else []
    except subprocess.CalledProcessError:
        # Downloaded source archives have no Git history. Never inspect a parent
        # workspace's repository, and omit the same local build directories.
        names = []
        for folder, directories, files in os.walk(ROOT):
            directories[:] = [name for name in directories if name not in FORBIDDEN_PARTS | {".git", "__pycache__"}]
            names.extend(str((pathlib.Path(folder) / name).relative_to(ROOT)) for name in files)
        commits = []
    errors = []
    for name in names:
        path = ROOT / name
        if path.is_symlink():
            errors.append((name, 1, "symbolic-link"))
        elif path.is_file():
            errors.extend((name, line, kind) for line, kind in findings(name, path.read_bytes()))
        else:
            errors.append((name, 1, "missing-file"))
    seen = set()
    for commit in commits:
        for entry in git("ls-tree", "-r", "-z", commit).split(b"\0"):
            if not entry:
                continue
            metadata, raw_name = entry.split(b"\t", 1)
            mode, kind, oid = metadata.decode().split()
            name = raw_name.decode()
            if (name, oid) in seen:
                continue
            seen.add((name, oid))
            if mode == "120000" or kind != "blob":
                errors.append((name, 1, "non-source-git-object"))
                continue
            errors.extend((name, line, label) for line, label in findings(name, git("cat-file", "blob", oid)))
    if errors:
        for name, line, kind in sorted(set(errors)):
            print(f"{name}:{line}: {kind}", file=sys.stderr)
        print("Public-source check failed; matching values were not printed.", file=sys.stderr)
        return 1
    print(f"Public-source check passed: {len(names)} files, {len(commits)} commits; no matching values printed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
