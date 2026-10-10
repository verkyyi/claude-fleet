#!/usr/bin/env python3
"""fleet_tls.py — the ONE TLS context every Python that talks to the hub uses
(claude-fleet#2878).

A newcomer's Mac: `curl … /install | sh` worked (curl reads the system
keychain), then `fleet login` died with CERTIFICATE_VERIFY_FAILED — the first
python3 on PATH (python.org / Homebrew / pyenv) reads no keychain, its certifi
was missing or too old, and urllib's default context had nothing to verify the
hub's chain with. The certificate keeper renews through the same road, so it
kept saying «renewal failed».

So the context is the UNION of every CA source this computer has, each tried in
turn and kept when it loads:

  1. FLEET_CA_BUNDLE / SSL_CERT_FILE   a file the person points at
  2. certifi                            when it imports
  3. macOS system roots                 `security export … SystemRootCertificates.keychain`
                                        into a cache file (FLEET_CA_CACHE,
                                        ~/.cache/claude-fleet/ca-roots.pem), refreshed
                                        once it is 24 hours old
  4. OpenSSL's default paths            what ssl.create_default_context() reads

Union, not first-wins: an old certifi that lacks a new root must not hide the
system's. Every source is a public root store, so the union trusts nothing a
browser on this computer would not.

  import fleet_tls; fleet_tls.install()   urllib.request.urlopen (no context=)
                                          now verifies with it, process-wide
  fleet_tls.context()                     the context itself (a raw socket)
  fleet_tls.hint(err)                     '' or one sentence for a verify failure:
                                          this python, the sources it tried, the fix

CLI (the doctor's `tls` row):
  fleet_tls.py check <url>   one line `PASS|FAIL<TAB>text`; exit 0 PASS, 1 FAIL
  fleet_tls.py sources       the sources that loaded, one per line

Seams: FLEET_TLS_SYSTEM_ROOTS=0 (no keychain export) · FLEET_TLS_CERTIFI=0 ·
FLEET_TLS_DEFAULTS=0 (no OpenSSL default paths) · FLEET_TLS_KEYCHAIN (the
keychain file) — the doctor's FAIL drill takes every road away.
"""
import os
import socket
import ssl
import subprocess
import sys
import time
import urllib.parse

KEYCHAIN = "/System/Library/Keychains/SystemRootCertificates.keychain"
REFRESH_SECS = 24 * 3600

_ctx = None
_sources = []


def _off(name):
    return os.environ.get(name, "1") == "0"


def cache_path():
    p = os.environ.get("FLEET_CA_CACHE")
    if p:
        return p
    base = os.environ.get("XDG_CACHE_HOME") or os.path.join(os.path.expanduser("~"), ".cache")
    return os.path.join(base, "claude-fleet", "ca-roots.pem")


def system_roots():
    """macOS: the system root store as a PEM file (cached, 24 h), or ''."""
    if sys.platform != "darwin" or _off("FLEET_TLS_SYSTEM_ROOTS"):
        return ""
    path = cache_path()
    try:
        fresh = time.time() - os.path.getmtime(path) < REFRESH_SECS and os.path.getsize(path) > 0
    except OSError:
        fresh = False
    if fresh:
        return path
    keychain = os.environ.get("FLEET_TLS_KEYCHAIN") or KEYCHAIN
    tmp = "%s.%d.tmp" % (path, os.getpid())
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        subprocess.run(["/usr/bin/security", "export", "-t", "certs", "-f", "pemseq", "-k", keychain, "-o", tmp],
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       timeout=15, check=True)
        if os.path.getsize(tmp) == 0:
            raise OSError("empty export")
        os.replace(tmp, path)
    except (OSError, subprocess.SubprocessError):
        try:
            os.remove(tmp)
        except OSError:
            pass
        # an older export still verifies better than none
        return path if os.path.isfile(path) and os.path.getsize(path) > 0 else ""
    return path


def _build():
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)  # verify + hostname check on
    got = []

    def load(label, **kw):
        try:
            ctx.load_verify_locations(**kw)
            got.append(label)
        except (OSError, ssl.SSLError, ValueError):
            pass

    for var in ("FLEET_CA_BUNDLE", "SSL_CERT_FILE"):
        f = os.environ.get(var, "")
        if f and os.path.isfile(f):
            load("%s=%s" % (var, f), cafile=f)
    if not _off("FLEET_TLS_CERTIFI"):
        try:
            import certifi  # noqa: E402 — optional
            load("certifi", cafile=certifi.where())
        except Exception:  # not installed, or broken
            pass
    sr = system_roots()
    if sr:
        load("macOS 系统根", cafile=sr)
    if not _off("FLEET_TLS_DEFAULTS"):
        before = ctx.cert_store_stats().get("x509_ca", 0)
        try:
            ctx.set_default_verify_paths()
        except (OSError, ssl.SSLError):
            pass
        # OpenSSL's paths load lazily (a hashed dir counts nothing up front):
        # name it only when it added a root, or when it is all there is
        if ctx.cert_store_stats().get("x509_ca", 0) > before or not got:
            got.append("OpenSSL 默认路径")
    return ctx, got


def context():
    global _ctx, _sources
    if _ctx is None:
        _ctx, _sources = _build()
    return _ctx


def sources():
    context()
    return list(_sources)


def install():
    """Every urllib.request.urlopen / http.client.HTTPSConnection without its
    own context= verifies with context() from here on."""
    ssl._create_default_https_context = context


def is_verify_error(err):
    seen = 0
    while err is not None and seen < 4:
        if isinstance(err, ssl.SSLCertVerificationError):
            return True
        if "CERTIFICATE_VERIFY_FAILED" in str(err):
            return True
        err = getattr(err, "reason", None) or err.__cause__ or err.__context__
        seen += 1
    return False


def fix_text():
    if sys.platform == "darwin":
        return ("修法：重装让 fleet 用 macOS 自带的 /usr/bin/python3（curl -fsSL <入口>/install | sh），"
                "或导出系统根并指给它：security export -t certs -f pemseq -k %s -o ~/.config/ca-roots.pem"
                " && export FLEET_CA_BUNDLE=~/.config/ca-roots.pem" % KEYCHAIN)
    return ("修法：装系统的 CA 包（Debian/Ubuntu: apt install ca-certificates；Fedora: dnf install ca-certificates），"
            "或 pip install certifi，或 export FLEET_CA_BUNDLE=<CA 包文件>")


def describe():
    s = sources()
    return "python %s · CA 来源：%s" % (sys.executable, "、".join(s) if s else "无")


def hint(err):
    """'' unless err is a certificate verify failure; then one sentence: this
    python has no CA store that verifies the hub, which roads it tried, the fix."""
    if not is_verify_error(err):
        return ""
    return "这台电脑的 python3 验不了入口的证书（%s）。%s" % (describe(), fix_text())


def check(url, timeout=10):
    """(ok, text): one TLS handshake with verification against url's host."""
    u = urllib.parse.urlsplit(url if "://" in url else "https://" + url)
    if u.scheme not in ("https", "wss"):
        return True, "%s 不是 https，不用验证书" % url
    host, port = u.hostname, u.port or 443
    try:
        with socket.create_connection((host, port), timeout=timeout) as raw:
            with context().wrap_socket(raw, server_hostname=host):
                pass
    except (ssl.SSLError, ssl.CertificateError) as e:
        if is_verify_error(e):
            return False, "%s 的证书验不过（%s）— %s" % (host, describe(), fix_text())
        return False, "%s TLS 握手失败：%s（%s）" % (host, e, describe())
    except OSError as e:
        return None, "%s 连不上，未验证（%s）" % (host, e)
    return True, "%s 证书验证通过（%s）" % (host, describe())


def main(argv):
    if len(argv) >= 2 and argv[0] == "check":
        ok, text = check(argv[1])
        print("%s\t%s" % ({True: "PASS", False: "FAIL", None: "WARN"}[ok], text))
        return 0 if ok else 1
    if argv and argv[0] == "sources":
        for s in sources():
            print(s)
        return 0
    sys.stderr.write("usage: fleet_tls.py check <url> | sources\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
