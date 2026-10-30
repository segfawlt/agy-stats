#!/usr/bin/env bash
# agy-stats release artifact builder & Ed25519 signer
# Usage:
#   ./release.sh --local              # Build & verify agy-stats.sha256 + agy-stats.sig locally
#   ./release.sh v1.0.0               # Verify tag/version & build artifacts (dry preview for gh release)
#   ./release.sh v1.0.0 --publish     # Build, verify, and publish GitHub Release via 'gh release create'

set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_DIR}"

SIGNING_KEY="${AGY_STATS_SIGNING_KEY:-${HOME}/.config/agy-stats/keys/release_ed25519.key}"
MODE="local"
TAG=""
PUBLISH=0

for arg in "$@"; do
    case "${arg}" in
        --local)
            MODE="local"
            ;;
        --publish)
            PUBLISH=1
            ;;
        v*.*.*)
            MODE="tag"
            TAG="${arg}"
            ;;
        -h|--help)
            sed -n '2,6p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown argument: ${arg}" >&2
            exit 1
            ;;
    esac
done

# Safety guard: ensure signing key is NEVER inside the Git repository
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

echo "==> [1/4] Compiling & inspecting agy-stats ..."
SCRIPT_VERSION="$(python3 - <<'PY'
import py_compile, re
py_compile.compile("agy-stats", doraise=True)
with open("agy-stats", "r", encoding="utf-8") as f:
    src = f.read()
m = re.search(r'^__version__\s*=\s*["\']([^"\']+)["\']', src, re.MULTILINE)
if not m:
    raise SystemExit("Could not find __version__ in agy-stats")
print(m.group(1))
PY
)"
echo "  • Binary version: v${SCRIPT_VERSION}"

if [ "${MODE}" = "tag" ]; then
    EXPECTED_TAG="v${SCRIPT_VERSION}"
    if [ "${TAG}" != "${EXPECTED_TAG}" ]; then
        echo "Error: Tag '${TAG}' does not match __version__ ('${EXPECTED_TAG}') in agy-stats." >&2
        exit 1
    fi
fi

echo "==> [2/4] Generating SHA-256 & RFC 8032 Ed25519 signature ..."
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

# RFC 8032 Ed25519 signing using curve primitives verified in agy-stats
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

echo "==> [3/4] Running independent verification checks ..."
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

# ASN.1 SubjectPublicKeyInfo prefix for Ed25519 (OID 1.3.101.112)
spki_der = bytes.fromhex("302a300506032b6570032100") + bytes.fromhex(pub_hex)
with tempfile.NamedTemporaryFile(suffix=".der") as pubf, tempfile.NamedTemporaryFile(suffix=".sig") as sigf:
    pubf.write(spki_der)
    pubf.flush()
    sigf.write(sig_bytes)
    sigf.flush()
    r = subprocess.run(
        ["openssl", "pkeyutl", "-verify", "-pubin", "-keyform", "DER", "-inkey", pubf.name,
         "-rawin", "-in", "agy-stats", "-sigfile", sigf.name],
        capture_output=True, text=True, check=True
    )
print("  • OpenSSL Ed25519 cross-verification: OK")
PYOPENSSL
fi

if [ "${MODE}" = "local" ]; then
    echo "==> [4/4] Local release artifacts ready: agy-stats, agy-stats.sha256, agy-stats.sig"
    exit 0
fi

ASSETS=(agy-stats agy-stats.sha256 agy-stats.sig install.sh install.ps1)
if [ "${PUBLISH}" -eq 1 ]; then
    if [ -n "$(git status --porcelain)" ]; then
        echo "Error: Git working tree has uncommitted changes. Commit before --publish." >&2
        exit 1
    fi
    echo "==> [4/4] Publishing GitHub Release ${TAG} ..."
    gh release create "${TAG}" "${ASSETS[@]}" \
        --title "agy-stats ${TAG}" \
        --notes "Cryptographically signed single-file release (${TAG}). Verified with Ed25519 (\`agy-stats.sig\`) and SHA-256 (\`agy-stats.sha256\`)."
else
    echo "==> [4/4] Dry preview complete. To publish ${TAG} to GitHub Releases, run:"
    echo "    ./release.sh ${TAG} --publish"
fi
