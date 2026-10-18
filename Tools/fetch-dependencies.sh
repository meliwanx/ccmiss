#!/bin/bash
# Downloads public, pinned build dependencies only. Never installs or starts them.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in
  ''|--verify-only) ;;
  *) printf '%s\n' 'Usage: ./Tools/fetch-dependencies.sh [--verify-only]' >&2; exit 1 ;;
esac
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  printf '%s\n' 'The current release build supports Apple Silicon macOS (darwin-arm64).' >&2
  exit 1
fi
command -v python3 >/dev/null || { printf '%s\n' 'Python 3 is required.' >&2; exit 1; }
mkdir -p "$PROJECT_DIR/.deps"
STAGING_DIR="$(mktemp -d "$PROJECT_DIR/.deps/.fetch.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
python3 - "$PROJECT_DIR" "$STAGING_DIR" "${1:-}" <<'PY'
import gzip, hashlib, json, pathlib, shutil, subprocess, sys, tarfile
project, stage = map(pathlib.Path, sys.argv[1:3])
manifest = json.loads((project / 'Tools/dependencies.json').read_text())
target = project / '.deps' / manifest['platform']
if sys.argv[3] == '--verify-only':
    if not (target / 'SHA256SUMS').is_file():
        raise SystemExit('Run ./Tools/fetch-dependencies.sh to download the pinned dependencies first.')
    if json.loads((target / 'provenance.json').read_text()) != manifest:
        raise SystemExit('Dependency manifest changed; fetch dependencies again.')
    expected_names = {'node', 'node-LICENSE.txt', 'mihomo', 'mihomo-LICENSE.txt', f"mihomo-source-v{manifest['mihomo']['version']}.tar.gz"}
    checksums = dict(line.split('  ', 1)[::-1] for line in (target / 'SHA256SUMS').read_text().splitlines())
    if set(checksums) != expected_names:
        raise SystemExit('Dependency checksum manifest is incomplete.')
    for name, digest in checksums.items():
        if pathlib.PurePath(name).name != name or hashlib.sha256((target / name).read_bytes()).hexdigest() != digest:
            raise SystemExit(f'Dependency checksum mismatch: {name}')
    for name, expected in [('node', manifest['node']['binarySHA256']),
                           ('mihomo', manifest['mihomo']['binarySHA256']),
                           (f"mihomo-source-v{manifest['mihomo']['version']}.tar.gz", manifest['mihomo']['sourceSHA256'])]:
        if checksums[name] != expected:
            raise SystemExit(f'Pinned dependency checksum mismatch: {name}')
    print('All cached dependency checksums verified; no downloads or binaries executed.')
    raise SystemExit(0)

def fetch(url, expected, name):
    if not url.startswith('https://'):
        raise SystemExit('Dependency URLs must use HTTPS.')
    path = stage / name
    subprocess.run(['/usr/bin/curl', '--proto', '=https', '--proto-redir', '=https', '--tlsv1.2',
                    '--fail', '--location', '--show-error', '--silent', '--retry', '2',
                    '--connect-timeout', '20', '--max-time', '600', '--output', str(path), url], check=True)
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit(f'Checksum mismatch for {name}; nothing was installed.')
    return path

node = manifest['node']
archive = fetch(node['archiveURL'], node['archiveSHA256'], 'node.tar.gz')
prefix = f"node-v{node['version']}-darwin-arm64/"
# Extract only known regular files; never follow archive links or paths.
with tarfile.open(archive, 'r:gz') as tar:
    for member_name, output in [('bin/node', 'node'), ('LICENSE', 'node-LICENSE.txt')]:
        member = tar.getmember(prefix + member_name)
        if not member.isfile() or member.size > 150 * 1024 * 1024:
            raise SystemExit('Unexpected Node.js archive member.')
        with tar.extractfile(member) as src, (stage / output).open('wb') as dst:
            shutil.copyfileobj(src, dst)
if hashlib.sha256((stage / 'node').read_bytes()).hexdigest() != node['binarySHA256']:
    raise SystemExit('Extracted Node.js checksum mismatch.')

core = manifest['mihomo']
archive = fetch(core['archiveURL'], core['archiveSHA256'], 'mihomo.gz')
with gzip.open(archive, 'rb') as src, (stage / 'mihomo').open('wb') as dst:
    shutil.copyfileobj(src, dst)
if hashlib.sha256((stage / 'mihomo').read_bytes()).hexdigest() != core['binarySHA256']:
    raise SystemExit('Decompressed Mihomo checksum mismatch.')
source_name = f"mihomo-source-v{core['version']}.tar.gz"
fetch(core['sourceURL'], core['sourceSHA256'], source_name)
with tarfile.open(stage / source_name, 'r:gz') as tar:
    member = tar.getmember(f"mihomo-{core['version']}/LICENSE")
    if not member.isfile() or member.size > 1024 * 1024:
        raise SystemExit('Unexpected Mihomo license member.')
    with tar.extractfile(member) as src, (stage / 'mihomo-LICENSE.txt').open('wb') as dst:
        shutil.copyfileobj(src, dst)

files = ['node', 'node-LICENSE.txt', 'mihomo', 'mihomo-LICENSE.txt', source_name]
(stage / 'provenance.json').write_text(json.dumps(manifest, indent=2) + '\n')
(stage / 'SHA256SUMS').write_text(''.join(hashlib.sha256((stage / f).read_bytes()).hexdigest() + '  ' + f + '\n' for f in files))
target.mkdir(exist_ok=True)
for name in files + ['provenance.json', 'SHA256SUMS']:
    shutil.copyfile(stage / name, target / name)
for name in ['node', 'mihomo']:
    (target / name).chmod(0o755)
print(f'Verified public dependencies: {target}')
print('No applications, helpers, proxies or DNS settings were installed or changed.')
PY
