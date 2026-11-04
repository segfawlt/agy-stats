#!/bin/sh
# agy-stats zero-bloat user-space installer
# Supported surfaces: Antigravity CLI (agy) + Antigravity Desktop / IDE
# Platforms: Linux (Tested), macOS (Untested), WSL2 (Untested)
# Footprint:
#   - ~/.local/bin/agy-stats
#   - ~/.config/agy-stats/config.json
#   - ~/.config/fish/functions/agy.fish (if Fish is present)
#   - Fenced '# >>> agy-stats >>>' block in ~/.bashrc / ~/.zshrc
# Zero sudo, zero global PATH mutation, zero package bloat.

set -eu

REPO="${AGY_STATS_REPO:-segfawlt/agy-stats}"
SCRIPT_URL="${AGY_STATS_URL:-https://github.com/${REPO}/releases/latest/download/agy-stats}"
RELEASE_PUBKEY_HEX="45fdf468d952accdcac5b6e3624f550cb065d463c82585bd889408816c686ec1"
INSTALL_DIR="${HOME}/.local/bin"
TARGET_BIN="${INSTALL_DIR}/agy-stats"

BOLD=""
GREEN=""
CYAN=""
YELLOW=""
RED=""
RESET=""
if [ -t 1 ]; then
    BOLD="\033[1m"
    GREEN="\033[32m"
    CYAN="\033[36m"
    YELLOW="\033[33m"
    RED="\033[31m"
    RESET="\033[0m"
fi

OS_NAME="$(uname -s 2>/dev/null || echo Unknown)"
PLATFORM_LABEL="${OS_NAME}"
IS_TESTED_LINUX=0
case "${OS_NAME}" in
    Linux*)
        if [ -r /proc/version ] && grep -qiE "microsoft|wsl" /proc/version 2>/dev/null; then
            PLATFORM_LABEL="WSL2 (Untested)"
        else
            PLATFORM_LABEL="Linux (Tested)"
            IS_TESTED_LINUX=1
        fi
        ;;
    Darwin*)
        PLATFORM_LABEL="macOS (Untested)"
        ;;
    *)
        PLATFORM_LABEL="${OS_NAME} (Untested)"
        ;;
esac

printf "${BOLD}${CYAN}==> Installing agy-stats (user-space, zero global bloat) [${PLATFORM_LABEL}]...${RESET}\n"
if [ "${IS_TESTED_LINUX}" -eq 0 ]; then
    printf "${YELLOW}==> Notice: ${PLATFORM_LABEL} — only native Linux is verified in production.${RESET}\n"
fi

if ! command -v python3 >/dev/null 2>&1; then
    printf "${RED}Error: python3 is required to run agy-stats.${RESET}\n" >&2
    exit 1
fi

mkdir -p "${TMPDIR:-/tmp}"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agy-stats-stage.XXXXXX")"
cleanup() {
    rm -rf "${STAGE_DIR}"
}
trap cleanup EXIT INT TERM

TMP_BIN="${STAGE_DIR}/agy-stats"
TMP_SHA="${STAGE_DIR}/agy-stats.sha256"
TMP_SIG="${STAGE_DIR}/agy-stats.sig"

# Security: ONLY use a local file when $0 is explicitly a file named install.sh (never CWD on 'curl | sh' or 'sh < install.sh')
LOCAL_SOURCE=""
if [ -f "$0" ] && [ "$(basename -- "$0")" = "install.sh" ]; then
    SCRIPT_SELF_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
    if [ -f "${SCRIPT_SELF_DIR}/agy-stats" ]; then
        LOCAL_SOURCE="${SCRIPT_SELF_DIR}/agy-stats"
    fi
fi

fetch_url() {
    src="$1"
    dst="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "${src}" -o "${dst}"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "${dst}" "${src}"
    else
        python3 - "${src}" "${dst}" <<'PYEOF'
import sys, urllib.request
req = urllib.request.Request(sys.argv[1], headers={"User-Agent": "agy-stats-installer/1.0"})
with urllib.request.urlopen(req, timeout=15) as r, open(sys.argv[2], "wb") as f:
    f.write(r.read())
PYEOF
    fi
}

PERSIST_URL_ARG=""
if [ -n "${LOCAL_SOURCE}" ] && [ -z "${AGY_STATS_URL:-}" ]; then
    cp "${LOCAL_SOURCE}" "${TMP_BIN}"
    printf "  • Staged local repository binary (%s)\n" "${LOCAL_SOURCE}"
else
    case "${SCRIPT_URL}" in
        https://*|file://*) ;;
        *)
            printf "${RED}Error: Refusing insecure AGY_STATS_URL '${SCRIPT_URL}' (must be https:// or file://).${RESET}\n" >&2
            exit 1
            ;;
    esac
    printf "  • Downloading %s ...\n" "${SCRIPT_URL}"
    fetch_url "${SCRIPT_URL}" "${TMP_BIN}"

    HAVE_SHA=0
    HAVE_SIG=0
    if fetch_url "${SCRIPT_URL}.sha256" "${TMP_SHA}" 2>/dev/null; then
        HAVE_SHA=1
    fi
    if fetch_url "${SCRIPT_URL}.sig" "${TMP_SIG}" 2>/dev/null; then
        HAVE_SIG=1
    fi

    # Verify SHA-256 and RFC 8032 Ed25519 signature BEFORE executing a single byte of the downloaded script
    python3 - "${TMP_BIN}" "${TMP_SHA}" "${TMP_SIG}" "${RELEASE_PUBKEY_HEX}" "${HAVE_SHA}" "${HAVE_SIG}" "${AGY_STATS_ALLOW_UNVERIFIED:-0}" <<'PYVERIFY'
import hashlib, py_compile, re, sys

bin_path, sha_path, sig_path, pub_hex, have_sha_s, have_sig_s, allow_unv_s = sys.argv[1:8]
have_sha = (have_sha_s == "1")
have_sig = (have_sig_s == "1")
allow_unverified = (allow_unv_s == "1")

with open(bin_path, "rb") as f:
    raw = f.read()

P = (1 << 255) - 19
L = (1 << 252) + 27742317777372353535851937790883648493
D = (-121665 * pow(121666, P - 2, P)) % P
I = pow(2, (P - 1) // 4, P)

def xrecover(y):
    xx = (y * y - 1) * pow(D * y * y + 1, P - 2, P) % P
    x = pow(xx, (P + 3) // 8, P)
    if (x * x - xx) % P != 0:
        x = (x * I) % P
    return P - x if (x & 1) else x

BY = (4 * pow(5, P - 2, P)) % P
BX = xrecover(BY)
B = (BX, BY, 1, (BX * BY) % P)

def ed_add(Pt, Qt):
    X1, Y1, Z1, T1 = Pt
    X2, Y2, Z2, T2 = Qt
    A = ((Y1 - X1) * (Y2 - X2)) % P
    Bb = ((Y1 + X1) * (Y2 + X2)) % P
    C = (T1 * 2 * D * T2) % P
    Dd = (Z1 * 2 * Z2) % P
    E, F, G, H = (Bb - A) % P, (Dd - C) % P, (Dd + C) % P, (Bb + A) % P
    return ((E * F) % P, (G * H) % P, (F * G) % P, (E * H) % P)

def ed_mul(Pt, e):
    R = (0, 1, 1, 0)
    Q = Pt
    while e > 0:
        if e & 1:
            R = ed_add(R, Q)
        Q = ed_add(Q, Q)
        e >>= 1
    return R

def ed_enc(Pt):
    X, Y, Z, _ = Pt
    zi = pow(Z, P - 2, P)
    x, y = (X * zi) % P, (Y * zi) % P
    return (y | ((x & 1) << 255)).to_bytes(32, "little")

def ed_dec(bs):
    if len(bs) != 32:
        return None
    y = int.from_bytes(bs, "little") & ((1 << 255) - 1)
    if y >= P:
        return None
    xs = (bs[31] >> 7) & 1
    u, v = (y * y - 1) % P, (D * y * y + 1) % P
    x = (u * pow(v, 3, P) * pow(u * pow(v, 7, P), (P - 5) // 8, P)) % P
    vxx = (v * x * x) % P
    if vxx != u:
        if vxx == (-u) % P:
            x = (x * I) % P
        else:
            return None
    if x == 0 and xs == 1:
        return None
    if (x & 1) != xs:
        x = P - x
    return (x, y, 1, (x * y) % P)

def verify(pub32, msg, sig64):
    if len(pub32) != 32 or len(sig64) != 64:
        return False
    S = int.from_bytes(sig64[32:], "little")
    if S >= L:
        return False
    A, R = ed_dec(pub32), ed_dec(sig64[:32])
    if A is None or R is None:
        return False
    k = int.from_bytes(hashlib.sha512(sig64[:32] + pub32 + msg).digest(), "little") % L
    return ed_enc(ed_mul(B, S)) == ed_enc(ed_add(R, ed_mul(A, k)))

if have_sha:
    with open(sha_path, "r", encoding="utf-8", errors="replace") as f:
        exp_sha = (f.read().strip().split() or [""])[0].lower()
    if not re.fullmatch(r"[0-9a-f]{64}", exp_sha):
        sys.exit("Error: Malformed .sha256 file.")
    act_sha = hashlib.sha256(raw).hexdigest().lower()
    if act_sha != exp_sha:
        sys.exit(f"Error: SHA-256 mismatch! Expected {exp_sha[:12]}..., got {act_sha[:12]}...")

if have_sig:
    with open(sig_path, "rb") as f:
        sraw = f.read()
    sig_b = None
    try:
        tok = (sraw.decode("utf-8").strip().split() or [""])[0]
        if re.fullmatch(r"[0-9a-fA-F]{128}", tok):
            sig_b = bytes.fromhex(tok)
    except Exception:
        if len(sraw) == 64:
            sig_b = sraw
    if sig_b is None or not verify(bytes.fromhex(pub_hex), raw, sig_b):
        sys.exit("Error: Ed25519 signature verification FAILED! Aborting untrusted install.")

if not (have_sha and have_sig) and not allow_unverified:
    sys.exit("Error: Missing .sig or .sha256 verification artifact (set AGY_STATS_ALLOW_UNVERIFIED=1 only for unsigned custom builds).")

if not raw.startswith(b"#!/usr/bin/env python3"):
    sys.exit("Error: Downloaded payload is not a valid agy-stats Python script.")

py_compile.compile(bin_path, cfile=bin_path + ".pyc", doraise=True)
PYVERIFY
    printf "  • Verified SHA-256 checksum, Ed25519 release signature & Python bytecode\n"
    PERSIST_URL_ARG="${SCRIPT_URL}"
fi

# Bytecode compile gate for local installs too
python3 -c 'import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' "${TMP_BIN}" "${STAGE_DIR}/check.pyc"

chmod 755 "${TMP_BIN}"

# Configure shell wrappers & launch interactive onboarding wizard if on a TTY
if [ -n "${PERSIST_URL_ARG}" ]; then
    python3 "${TMP_BIN}" --install --update-url "${PERSIST_URL_ARG}" "$@"
else
    python3 "${TMP_BIN}" --install "$@"
fi
