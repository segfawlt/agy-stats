#!/usr/bin/env bash
# agy-stats local/server release builder, Ed25519 signer & GitHub publisher
# Usage:
#   ./release.sh --local                  # Run gates & sign agy-stats.sha256 + agy-stats.sig locally
#   ./release.sh patch|minor|major|vX.Y.Z # Dry-run preview (gates + next version + changelog, zero writes)
#   ./release.sh minor --publish          # Bump version, sign, commit, tag, push & publish GitHub Release
#   ./release.sh vX.Y.Z --publish         # Same with explicit version tag (add --clobber to replace assets)

set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_DIR}"

SIGNING_KEY="${AGY_STATS_SIGNING_KEY:-${HOME}/.config/agy-stats/keys/release_ed25519.key}"
MODE="local"
TARGET_SPEC=""
PUBLISH=0
CLOBBER=0

for arg in "$@"; do
    case "${arg}" in
        --local)
            MODE="local"
            ;;
        --publish)
            PUBLISH=1
            ;;
        --clobber)
            CLOBBER=1
            ;;
        patch|minor|major|v[0-9]*.[0-9]*.[0-9]*)
            MODE="release"
            TARGET_SPEC="${arg}"
            ;;
        -h|--help)
            sed -n '2,7p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown argument: ${arg}" >&2
            sed -n '2,7p' "$0" >&2
            exit 1
            ;;
    esac
done

if [ "${PUBLISH}" -eq 1 ] && [ "${MODE}" != "release" ]; then
    echo "Error: --publish requires a version target (patch, minor, major, or vX.Y.Z)." >&2
    exit 1
fi

# 1. Signing key isolation check (private key must NEVER live inside the Git repo)
REAL_REPO="$(realpath "${REPO_DIR}")"
if [ ! -f "${SIGNING_KEY}" ]; then
    echo "Error: Ed25519 private seed not found at ${SIGNING_KEY}" >&2
    echo "Keep your private key outside Git (e.g. ~/.config/agy-stats/keys/release_ed25519.key, mode 0600)." >&2
    exit 1
fi
REAL_KEY="$(realpath "${SIGNING_KEY}")"
case "${REAL_KEY}" in
    "${REAL_REPO}"/*)
        echo "CRITICAL: Refusing to sign — private key (${REAL_KEY}) is inside the Git repository!" >&2
        exit 1
        ;;
esac

run_preflight_gates() {
    echo "==> [1/5] Running pre-flight quality & security gates ..."
    mkdir -p plugins/stats/bin
    cp agy-stats plugins/stats/bin/agy-stats
    chmod +x plugins/stats/bin/agy-stats
    CURRENT_VERSION="$(python3 - <<'PY'
import os, py_compile, re, subprocess, sys, tempfile

py_compile.compile("agy-stats", doraise=True)
with open("agy-stats", "r", encoding="utf-8") as f:
    src = f.read()

m = re.search(r'^__version__\s*=\s*["\']([^"\']+)["\']', src, re.MULTILINE)
if not m:
    raise SystemExit("Error: Could not find __version__ in agy-stats")
ver = m.group(1)

# Embedded Web JS syntax check (when node is available)
import shutil
if shutil.which("node"):
    scripts = re.findall(r"<script>(.*?)</script>", src, flags=re.S)
    if not scripts:
        raise SystemExit("Error: No embedded <script> block found in agy-stats")
    with tempfile.NamedTemporaryFile("w", suffix=".js", encoding="utf-8") as tf:
        tf.write(scripts[-1])
        tf.flush()
        subprocess.run(["node", "--check", tf.name], check=True)

# Standalone purity & zero-emoji checks across tracked release files
forbidden_terms = [
    "\x6f\x6d\x70",
    "\x61\x64\x76\x69\x73\x6f\x72",
    "\x73\x69\x64\x65\x6b\x69\x63\x6b",
    "\x74\x61\x73\x6b\x2d\x65\x6e\x67\x69\x6e\x65\x65\x72",
    "\x73\x70\x65\x65\x63\x68\x2d\x62\x72\x69\x64\x67\x65",
]
forbidden_re = re.compile(r"\b(" + "|".join(re.escape(w) for w in forbidden_terms) + r")\b", re.I)
emoji_re = re.compile(r"[\U0001F300-\U0001FAFF]")

for fname in (
    "agy-stats",
    "install.sh",
    "install.ps1",
    "release.sh",
    "README.md",
    "plugins/stats/plugin.json",
    "plugins/stats/hooks.json",
    "plugins/stats/README.md",
    "plugins/stats/skills/stats/SKILL.md",
):
    with open(fname, "r", encoding="utf-8") as fh:
        txt = fh.read()
    bad = forbidden_re.findall(txt)
    if bad:
        raise SystemExit(f"Error: Forbidden external reference {bad[0]!r} found in {fname}")
    em = emoji_re.findall(txt)
    if em:
        raise SystemExit(f"Error: Emoji character {em[0]!r} found in {fname} (zero-emoji policy)")

# CLI smoke check
out = subprocess.check_output([sys.executable, "./agy-stats", "--version"], text=True, timeout=10).strip()
if f"v{ver}" not in out:
    raise SystemExit(f"Error: Unexpected --version output: {out}")

# Antigravity plugin strict validation check (when agy binary is present)
agy_bin = shutil.which("agy") or os.path.expanduser("~/.local/bin/agy")
if os.path.isfile(agy_bin) and os.access(agy_bin, os.X_OK):
    subprocess.run([agy_bin, "plugin", "validate", "plugins/stats", "--strict"], check=True, stdout=subprocess.DEVNULL)

print(ver)
PY
)"
    echo "  • Bytecode, embedded JS, standalone purity, zero-emoji, plugin --strict & CLI smoke gates: OK (current v${CURRENT_VERSION})"
}

sign_and_verify() {
    echo "==> [2/5] Generating SHA-256 & RFC 8032 Ed25519 signature ..."
    python3 - "${SIGNING_KEY}" <<'PYSIGN'
import hashlib, importlib.machinery, importlib.util, re, sys

key_path = sys.argv[1]
with open(key_path, "r", encoding="utf-8") as f:
    seed_hex = f.read().strip().split()[0]
if not re.fullmatch(r"[0-9a-fA-F]{64}", seed_hex):
    raise SystemExit("Error: Signing key must be a 64-hex-char (32-byte) Ed25519 seed.")
seed = bytes.fromhex(seed_hex)

loader = importlib.machinery.SourceFileLoader("agy_stats_mod", "agy-stats")
spec = importlib.util.spec_from_loader("agy_stats_mod", loader)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

h = hashlib.sha512(seed).digest()
a = int.from_bytes(h[:32], "little")
a &= (1 << 254) - 8
a |= (1 << 254)
prefix = h[32:]
pub_bytes = mod._ed_encode(mod._ed_mul(mod._ED_B, a))
derived_pub_hex = pub_bytes.hex()

if derived_pub_hex.lower() != mod.RELEASE_PUBKEY_HEX.lower():
    raise SystemExit(
        f"Error: Derived public key ({derived_pub_hex}) does not match "
        f"RELEASE_PUBKEY_HEX in agy-stats ({mod.RELEASE_PUBKEY_HEX})!"
    )

with open("agy-stats", "rb") as f:
    payload = f.read()

sha_hex = hashlib.sha256(payload).hexdigest()
r = int.from_bytes(hashlib.sha512(prefix + payload).digest(), "little") % mod._ED_L
R_enc = mod._ed_encode(mod._ed_mul(mod._ED_B, r))
k = int.from_bytes(hashlib.sha512(R_enc + pub_bytes + payload).digest(), "little") % mod._ED_L
S = (r + k * a) % mod._ED_L
sig_bytes = R_enc + S.to_bytes(32, "little")

if not mod.ed25519_verify(pub_bytes, payload, sig_bytes):
    raise SystemExit("Error: Internal Ed25519 self-verification failed!")

with open("agy-stats.sha256", "w", encoding="utf-8") as f:
    f.write(f"{sha_hex}  agy-stats\n")

with open("agy-stats.sig", "w", encoding="utf-8") as f:
    f.write(f"{sig_bytes.hex()}  agy-stats\n")

print(f"  • SHA-256:    {sha_hex}")
print(f"  • Public key: {derived_pub_hex}")
print(f"  • Signature:  {sig_bytes.hex()[:32]}...{sig_bytes.hex()[-16:]}")
PYSIGN

    echo "==> [3/5] Running independent verification checks ..."
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -c agy-stats.sha256 >/dev/null
        echo "  • sha256sum -c agy-stats.sha256: OK"
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 -c agy-stats.sha256 >/dev/null
        echo "  • shasum -a 256 -c agy-stats.sha256: OK"
    fi

    if command -v openssl >/dev/null 2>&1; then
        python3 - <<'PYOPENSSL'
import re, subprocess, tempfile

with open("agy-stats", "r", encoding="utf-8") as f:
    pub_hex = re.search(r'^RELEASE_PUBKEY_HEX\s*=\s*"([0-9a-fA-F]{64})"', f.read(), re.M).group(1)
with open("agy-stats.sig", "r", encoding="utf-8") as f:
    sig_bytes = bytes.fromhex(f.read().strip().split()[0])

spki_der = bytes.fromhex("302a300506032b6570032100") + bytes.fromhex(pub_hex)
with tempfile.NamedTemporaryFile(suffix=".der") as pubf, tempfile.NamedTemporaryFile(suffix=".sig") as sigf:
    pubf.write(spki_der)
    pubf.flush()
    sigf.write(sig_bytes)
    sigf.flush()
    subprocess.run(
        ["openssl", "pkeyutl", "-verify", "-pubin", "-keyform", "DER", "-inkey", pubf.name,
         "-rawin", "-in", "agy-stats", "-sigfile", sigf.name],
        capture_output=True, text=True, check=True
    )
print("  • OpenSSL Ed25519 cross-verification: OK")
PYOPENSSL
    fi
}

run_preflight_gates

if [ "${MODE}" = "local" ]; then
    sign_and_verify
    echo "==> [4/5] Local release artifacts ready: agy-stats, agy-stats.sha256, agy-stats.sig"
    exit 0
fi

# Resolve target semver & tag for release mode
NEXT_VERSION="$(python3 - "${CURRENT_VERSION}" "${TARGET_SPEC}" <<'PYVER'
import re, sys

cur_s, spec = sys.argv[1], sys.argv[2]
m = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)", cur_s)
if not m:
    raise SystemExit(f"Error: Current __version__ ({cur_s!r}) is not strict X.Y.Z semver")
maj, min_, pat = map(int, m.groups())

if spec == "patch":
    nxt = (maj, min_, pat + 1)
elif spec == "minor":
    nxt = (maj, min_ + 1, 0)
elif spec == "major":
    nxt = (maj + 1, 0, 0)
elif spec.startswith("v"):
    mv = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", spec)
    if not mv:
        raise SystemExit(f"Error: Explicit tag {spec!r} must match vX.Y.Z")
    nxt = tuple(map(int, mv.groups()))
else:
    raise SystemExit(f"Error: Unsupported version target {spec!r}")

if nxt < (maj, min_, pat):
    raise SystemExit(f"Error: Target version {'.'.join(map(str, nxt))} is lower than current {cur_s}")

print(f"{nxt[0]}.{nxt[1]}.{nxt[2]}")
PYVER
)"
TAG="v${NEXT_VERSION}"

# Determine previous release tag for changelog generation
PREV_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' 2>/dev/null || true)"
if [ -z "${PREV_TAG}" ] && command -v gh >/dev/null 2>&1; then
    PREV_TAG="$(gh release view --json tagName --jq '.tagName' 2>/dev/null || true)"
fi

NOTES_BODY="$(python3 - "${TAG}" "${PREV_TAG}" <<'PYNOTES'
import subprocess, sys

tag, prev = sys.argv[1], sys.argv[2]
rev_range = None
if prev and prev != tag:
    chk = subprocess.run(["git", "rev-parse", "--verify", "--quiet", f"{prev}^{{commit}}"], capture_output=True, text=True)
    if chk.returncode == 0:
        rev_range = f"{prev}..HEAD"
    else:
        rem = subprocess.run(["git", "ls-remote", "--tags", "origin", f"refs/tags/{prev}", f"refs/tags/{prev}^{{}}"], capture_output=True, text=True)
        if rem.returncode == 0 and rem.stdout.strip():
            rem_sha = rem.stdout.strip().splitlines()[-1].split()[0]
            if subprocess.run(["git", "cat-file", "-e", f"{rem_sha}^{{commit}}"], capture_output=True).returncode == 0:
                rev_range = f"{rem_sha}..HEAD"

cmd = ["git", "log", "--no-merges", "--pretty=format:%h%x09%s"]
if rev_range:
    cmd.append(rev_range)
else:
    cmd.extend(["-n", "20"])

raw = subprocess.check_output(cmd, text=True).splitlines()
feats, fixes, others = [], [], []
for row in raw:
    if "\t" not in row:
        continue
    sha, subj = row.split("\t", 1)
    if subj.startswith("chore(release):"):
        continue
    entry = f"- {subj} (`{sha}`)"
    if subj.startswith("feat"):
        feats.append(entry)
    elif subj.startswith("fix"):
        fixes.append(entry)
    else:
        others.append(entry)

lines = [f"Cryptographically signed single-file release (`{tag}`). Verified with Ed25519 (`agy-stats.sig`) and SHA-256 (`agy-stats.sha256`).", ""]
if feats:
    lines.extend(["### Features", *feats, ""])
if fixes:
    lines.extend(["### Fixes", *fixes, ""])
if others:
    lines.extend(["### Maintenance & Refactors", *others, ""])
lines.extend([
    "### Quick Install / Upgrade",
    "```sh",
    "agy stats --update",
    "# Fresh install (Linux):",
    "curl -fsSL https://github.com/segfawlt/agy-stats/releases/latest/download/install.sh | sh",
    "```",
])
print("\n".join(lines))
PYNOTES
)"

DIRTY_STATUS="$(git status --porcelain)"

if [ "${PUBLISH}" -eq 0 ]; then
    echo ""
    echo "==> [DRY-RUN PREVIEW] Target release: ${TAG} (current: v${CURRENT_VERSION}${PREV_TAG:+, previous release: ${PREV_TAG}})"
    if [ -n "${DIRTY_STATUS}" ]; then
        echo "  ! Warning: Working tree currently has uncommitted tracked/untracked files:"
        echo "${DIRTY_STATUS}" | sed 's/^/    /'
    else
        echo "  • Working tree: clean"
    fi
    echo ""
    echo "--- Generated Release Notes (${TAG}) ---"
    echo "${NOTES_BODY}"
    echo "----------------------------------------"
    echo ""
    echo "==> Dry-run complete (no files modified). To cut & publish ${TAG} end-to-end, run:"
    echo "    ./release.sh ${TARGET_SPEC} --publish"
    exit 0
fi

# --publish execution path
if [ -n "${DIRTY_STATUS}" ]; then
    echo "Error: Git working tree is not clean. Commit or stash changes before running --publish:" >&2
    echo "${DIRTY_STATUS}" >&2
    exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "Error: GitHub CLI ('gh') is required for --publish." >&2
    exit 1
fi
gh auth status >/dev/null

if [ "${NEXT_VERSION}" = "${CURRENT_VERSION}" ] && [ "${CLOBBER}" -eq 0 ]; then
    if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null || gh release view "${TAG}" >/dev/null 2>&1; then
        echo "Error: ${TAG} already exists and __version__ is still ${CURRENT_VERSION}." >&2
        echo "Pass 'patch', 'minor', 'major', or a newer vX.Y.Z (or add --clobber to replace ${TAG} assets)." >&2
        exit 1
    fi
fi

if [ "${NEXT_VERSION}" != "${CURRENT_VERSION}" ]; then
    echo "==> Bumping agy-stats version: v${CURRENT_VERSION} -> v${NEXT_VERSION} ..."
    python3 - "${NEXT_VERSION}" <<'PYBUMP'
import re, sys

ver = sys.argv[1]
with open("agy-stats", "r", encoding="utf-8") as f:
    src = f.read()

src_new, n1 = re.subn(
    r'^(__version__\s*=\s*["\'])([^"\']+)(["\'])',
    rf'\g<1>{ver}\g<3>',
    src,
    count=1,
    flags=re.MULTILINE,
)
if n1 != 1:
    raise SystemExit("Error: Failed to update __version__ in agy-stats")

src_new = re.sub(
    r'(<span[^>]*id="settingVersionBadge"[^>]*>)v[0-9]+\.[0-9]+\.[0-9]+(</span>)',
    rf'\g<1>v{ver}\g<2>',
    src_new,
    count=1,
)

with open("agy-stats", "w", encoding="utf-8") as f:
    f.write(src_new)

import os
pjson = "plugins/stats/plugin.json"
if os.path.exists(pjson):
    with open(pjson, "r", encoding="utf-8") as f:
        ptxt = f.read()
    ptxt_new = re.sub(r'("version"\s*:\s*")[0-9]+\.[0-9]+\.[0-9]+(")', rf'\g<1>{ver}\g<2>', ptxt, count=1)
    with open(pjson, "w", encoding="utf-8") as f:
        f.write(ptxt_new)
PYBUMP
    run_preflight_gates
fi

sign_and_verify

if [ -x "${HOME}/.local/bin/agy-stats" ] && [ -x "./install.sh" ]; then
    ./install.sh < /dev/null >/dev/null
    echo "  • Synced local binary -> ${HOME}/.local/bin/agy-stats (v${NEXT_VERSION})"
fi

echo "==> [4/5] Committing, tagging & pushing ${TAG} to origin ..."
git add agy-stats agy-stats.sha256 agy-stats.sig plugins/stats/plugin.json plugins/stats/bin/agy-stats
if ! git diff --cached --quiet; then
    git commit -m "chore(release): ${TAG}"
fi

if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    if [ "${CLOBBER}" -eq 1 ]; then
        git tag -fa "${TAG}" -m "agy-stats ${TAG}"
    fi
else
    git tag -a "${TAG}" -m "agy-stats ${TAG}"
fi

if [ "${CLOBBER}" -eq 1 ]; then
    git push origin HEAD
    git push --force origin "refs/tags/${TAG}"
else
    git push origin HEAD
    git push origin "refs/tags/${TAG}"
fi

ASSETS=(agy-stats agy-stats.sha256 agy-stats.sig install.sh install.ps1)
NOTES_FILE="$(mktemp)"
trap 'rm -f "${NOTES_FILE}"' EXIT
printf '%s\n' "${NOTES_BODY}" > "${NOTES_FILE}"

echo "==> [5/5] Publishing GitHub Release ${TAG} ..."
if gh release view "${TAG}" >/dev/null 2>&1; then
    if [ "${CLOBBER}" -eq 1 ]; then
        gh release upload "${TAG}" "${ASSETS[@]}" --clobber
        gh release edit "${TAG}" --title "agy-stats ${TAG}" --notes-file "${NOTES_FILE}"
    else
        echo "Error: GitHub Release ${TAG} already exists (pass --clobber to overwrite assets)." >&2
        exit 1
    fi
else
    gh release create "${TAG}" "${ASSETS[@]}" \
        --verify-tag \
        --title "agy-stats ${TAG}" \
        --notes-file "${NOTES_FILE}"
fi

echo "==> Published ${TAG}: https://github.com/segfawlt/agy-stats/releases/tag/${TAG}"
