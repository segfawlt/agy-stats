# agy-stats zero-bloat user-space installer for Windows PowerShell (Untested)
# Supported surfaces: Antigravity CLI (agy.exe) + Antigravity Desktop / IDE
# Status: (Untested) — only native Linux is verified in production.
# Footprint:
#   - $HOME\.local\bin\agy-stats + $HOME\.local\bin\agy-stats.cmd
#   - $HOME\.config\agy-stats\config.json
#   - Fenced '# >>> agy-stats >>>' block in PowerShell $PROFILE
# Zero admin rights, zero global Registry PATH mutation, zero package bloat.

$ErrorActionPreference = "Stop"

$Repo = if ($env:AGY_STATS_REPO) { $env:AGY_STATS_REPO } else { "segfawlt/agy-stats" }
$ScriptUrl = if ($env:AGY_STATS_URL) { $env:AGY_STATS_URL } else { "https://github.com/$Repo/releases/latest/download/agy-stats" }
$ReleasePubkeyHex = "45fdf468d952accdcac5b6e3624f550cb065d463c82585bd889408816c686ec1"
$InstallDir = Join-Path $HOME ".local\bin"
$TargetBin = Join-Path $InstallDir "agy-stats"

Write-Host "==> Installing agy-stats (user-space, zero global bloat) [Windows PowerShell (Untested)]..." -ForegroundColor Cyan
Write-Host "==> Notice: Windows PowerShell support is marked (Untested) — only native Linux is verified in production." -ForegroundColor Yellow

# Locate working Python 3.8+ (skipping Windows Store stub if not installed)
$PyExe = $null
$PyArgs = @()
if (Get-Command py -CommandType Application -ErrorAction SilentlyContinue) {
    try {
        & py -3 -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $PyExe = "py"
            $PyArgs = @("-3")
        }
    } catch {}
}
if (-not $PyExe -and (Get-Command python -CommandType Application -ErrorAction SilentlyContinue)) {
    try {
        & python -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)" 2>$null
        if ($LASTEXITCODE -eq 0) {
            $PyExe = "python"
            $PyArgs = @()
        }
    } catch {}
}
if (-not $PyExe) {
    throw "Python 3.8+ is required to run agy-stats. Install Python from https://www.python.org/downloads/windows/ and re-run."
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$StageDir = Join-Path $InstallDir (".agy-stats-stage-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Force -Path $StageDir | Out-Null

try {
    $TmpBin = Join-Path $StageDir "agy-stats"
    $TmpSha = Join-Path $StageDir "agy-stats.sha256"
    $TmpSig = Join-Path $StageDir "agy-stats.sig"
    $VerifyPy = Join-Path $StageDir "verify_ed25519.py"

    # Security: ONLY use local file when invoked directly from a local install.ps1 file (never CWD on 'irm | iex')
    $LocalSource = ""
    $SelfPath = $MyInvocation.MyCommand.Path
    if ($SelfPath -and (Split-Path -Leaf $SelfPath) -eq "install.ps1" -and (Test-Path -LiteralPath $SelfPath -PathType Leaf)) {
        $CandBin = Join-Path (Split-Path -Parent $SelfPath) "agy-stats"
        if (Test-Path -LiteralPath $CandBin -PathType Leaf) {
            $LocalSource = $CandBin
        }
    }

    $PersistUrl = ""
    if ($LocalSource -and -not $env:AGY_STATS_URL) {
        Copy-Item -LiteralPath $LocalSource -Destination $TmpBin -Force
        Write-Host "  * Copied local repository binary -> $TargetBin"
    } else {
        if (-not ($ScriptUrl.StartsWith("https://") -or $ScriptUrl.StartsWith("file://"))) {
            throw "Refusing insecure AGY_STATS_URL '$ScriptUrl' (must be https:// or file://)."
        }
        Write-Host "  * Downloading $ScriptUrl ..."
        Invoke-WebRequest -Uri $ScriptUrl -OutFile $TmpBin -UseBasicParsing

        $HaveSha = "0"
        $HaveSig = "0"
        try {
            Invoke-WebRequest -Uri ($ScriptUrl + ".sha256") -OutFile $TmpSha -UseBasicParsing
            $HaveSha = "1"
        } catch {}
        try {
            Invoke-WebRequest -Uri ($ScriptUrl + ".sig") -OutFile $TmpSig -UseBasicParsing
            $HaveSig = "1"
        } catch {}

        $VerifierCode = @'
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
'@
        [System.IO.File]::WriteAllText($VerifyPy, $VerifierCode, [System.Text.UTF8Encoding]::new($false))
        $AllowUnv = if ($env:AGY_STATS_ALLOW_UNVERIFIED -eq "1") { "1" } else { "0" }
        & $PyExe @PyArgs $VerifyPy $TmpBin $TmpSha $TmpSig $ReleasePubkeyHex $HaveSha $HaveSig $AllowUnv
        if ($LASTEXITCODE -ne 0) {
            throw "Signature or checksum verification failed — aborting install."
        }
        Write-Host "  * Verified SHA-256 checksum, Ed25519 release signature & Python bytecode"
        $PersistUrl = $ScriptUrl
    }

    & $PyExe @PyArgs -c "import py_compile, sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)" $TmpBin (Join-Path $StageDir "check.pyc")
    if ($LASTEXITCODE -ne 0) {
        throw "Bytecode verification failed — aborting install."
    }

    Move-Item -LiteralPath $TmpBin -Destination $TargetBin -Force
} finally {
    if (Test-Path -LiteralPath $StageDir) {
        Remove-Item -LiteralPath $StageDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($PersistUrl) {
    & $PyExe @PyArgs $TargetBin --install --update-url $PersistUrl
} else {
    & $PyExe @PyArgs $TargetBin --install
}
