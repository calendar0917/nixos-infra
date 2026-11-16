#!/usr/bin/env python3
"""
Ruijie campus network auto-login & keep-alive.
Zero dependencies beyond the stdlib + requests.

One-shot:     python3 campus-login.py -u PHONE
Daemon mode:  python3 campus-login.py -u PHONE -d
Check only:   python3 campus-login.py -c

Password defaults to last 8 digits of the phone number when no credential
file is available.
Env vars: WIFI_USERNAME, WIFI_PASSWORD (manual-run override).
systemd: CREDENTIALS_DIRECTORY/username and /password (LoadCredential).

Exit codes: 0 verified online, 1 login failed, 3 login page passed but
connectivity unconfirmed, 42 requests missing, 78 missing credentials.
"""

import re
import os
import sys
import time
import base64
import logging
import argparse
from urllib.parse import urlparse, parse_qs

try:
    import requests
except ImportError:
    sys.stderr.write("campus-login: the requests module is missing\n")
    sys.exit(42)

# ── AES-128-ECB + PKCS7 (pure Python, no crypto deps) ─────────────────

def _xtime(a):
    r = (a << 1) & 0xFF
    return r ^ 0x1B if a & 0x80 else r

_SBOX = (
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
)

# pre-computed: GF(2^8) multiply by 2 and 3
_GF2 = [_xtime(i) for i in range(256)]
_GF3 = [_GF2[i] ^ i for i in range(256)]

_RCON = (0x01,0x02,0x04,0x08,0x10,0x20,0x40,0x80,0x1b,0x36)


def _key_expansion(key):
    w = list(key[i] << 24 | key[i+1] << 16 | key[i+2] << 8 | key[i+3]
            for i in range(0, 16, 4))
    for i in range(4, 44):
        t = w[i - 1]
        if i % 4 == 0:
            t = ((t << 8) | (t >> 24)) & 0xFFFFFFFF
            t = (_SBOX[(t >> 24) & 0xFF] << 24 |
                 _SBOX[(t >> 16) & 0xFF] << 16 |
                 _SBOX[(t >> 8) & 0xFF] << 8 |
                 _SBOX[t & 0xFF])
            t ^= (_RCON[i // 4 - 1] << 24)
        w.append(w[i - 4] ^ t)
    return w


def _aes_block(state, w):
    def _add_rk(r):
        for c in range(4):
            k = w[r * 4 + c]
            state[0][c] ^= (k >> 24) & 0xFF
            state[1][c] ^= (k >> 16) & 0xFF
            state[2][c] ^= (k >> 8) & 0xFF
            state[3][c] ^= k & 0xFF

    _add_rk(0)
    for rnd in range(1, 10):
        for r in range(4):
            for c in range(4):
                state[r][c] = _SBOX[state[r][c]]
        # shift rows
        state[1] = [state[1][1], state[1][2], state[1][3], state[1][0]]
        state[2] = [state[2][2], state[2][3], state[2][0], state[2][1]]
        state[3] = [state[3][3], state[3][0], state[3][1], state[3][2]]
        # mix columns
        for c in range(4):
            a = [state[r][c] for r in range(4)]
            state[0][c] = _GF2[a[0]] ^ _GF3[a[1]] ^ a[2] ^ a[3]
            state[1][c] = a[0] ^ _GF2[a[1]] ^ _GF3[a[2]] ^ a[3]
            state[2][c] = a[0] ^ a[1] ^ _GF2[a[2]] ^ _GF3[a[3]]
            state[3][c] = _GF3[a[0]] ^ a[1] ^ a[2] ^ _GF2[a[3]]
        _add_rk(rnd)
    # final round (no mix columns)
    for r in range(4):
        for c in range(4):
            state[r][c] = _SBOX[state[r][c]]
    state[1] = [state[1][1], state[1][2], state[1][3], state[1][0]]
    state[2] = [state[2][2], state[2][3], state[2][0], state[2][1]]
    state[3] = [state[3][3], state[3][0], state[3][1], state[3][2]]
    _add_rk(10)


def _aes_ecb_encrypt(plaintext, key):
    wk = _key_expansion(key)
    pad_len = 16 - (len(plaintext) % 16)
    padded = plaintext + bytes([pad_len] * pad_len)
    result = b''
    for i in range(0, len(padded), 16):
        block = padded[i:i+16]
        state = [[block[r + c * 4] for c in range(4)] for r in range(4)]
        _aes_block(state, wk)
        result += bytes(state[c][r] for r in range(4) for c in range(4))
    return result


def aes_b64(key_b64, plaintext):
    key = base64.b64decode(key_b64)
    ct = _aes_ecb_encrypt(plaintext.encode(), key)
    return base64.b64encode(ct).decode()

# ── End of AES ────────────────────────────────────────────────────────

log = logging.getLogger("campus-login")

TEST_URL = "http://www.baidu.com"
ONLINE_URL = "http://connect.rom.miui.com/generate_204"
HTTPS_CHECK_URL = "https://www.baidu.com/"
PORTAL = "http://110.184.24.61"
POST_LOGIN_WAIT = 3.0  # seconds to poll for connectivity after submit
CREDENTIAL_NAMES = ("username", "password")

USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
)


class AlreadyOnline(Exception):
    pass


class LoginError(Exception):
    pass


class CredentialError(Exception):
    pass


def _session():
    """Build a session that never inherits the system HTTP proxy.

    The portal is reached over the campus link, not through Mihomo. If the
    system proxy environment leaked into this process the login could loop
    through a proxy that itself needs the campus network.
    """
    sess = requests.Session()
    sess.trust_env = False
    sess.headers.update({
        "User-Agent": USER_AGENT,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9",
    })
    return sess


def _normal_site_redirect(response):
    """Distinguish Baidu's ordinary HTTP redirect from a captive portal."""
    if response.status_code not in (301, 302, 303, 307, 308):
        return False
    location = response.headers.get("Location", "")
    target = urlparse(location)
    host = (target.hostname or "").lower()
    return host == "baidu.com" or host.endswith(".baidu.com")


def _http_204_probe(timeout=3):
    """Return the HTTP status, or None when transport failed.

    A portal commonly answers an intercepted request with ``200`` and an HTML
    login page. A plain 200 is therefore *not* proof of connectivity.
    """
    try:
        with _session() as sess:
            r = sess.get(ONLINE_URL, timeout=timeout, allow_redirects=False)
        return r.status_code, r
    except requests.RequestException:
        return None, None


def https_reachable(timeout=5):
    """Independent certificate-checked HTTPS probe used for ambiguous HTTP."""
    try:
        with _session() as sess:
            r = sess.get(
                HTTPS_CHECK_URL,
                timeout=timeout,
                allow_redirects=False,
                proxies={"http": None, "https": None},
            )
        return r.status_code in (200, 204, 301, 302, 303, 307, 308)
    except requests.RequestException:
        return False


def probe_connectivity(timeout=3):
    """Return ``(state, detail)`` without logging any portal URL.

    ``online`` requires the dedicated 204 endpoint or a verified HTTPS
    connection. ``captive`` means an intercepting redirect/HTML was seen;
    ``uncertain`` is deliberately separate from both online and offline.
    """
    status, response = _http_204_probe(timeout=timeout)
    if status == 204:
        return "online", "http-204"
    if https_reachable():
        return "online", "https-verified"
    if status is None:
        return "uncertain", "http-unreachable"
    if status in (301, 302, 303, 307, 308):
        return "captive", f"http-{status}"
    if status == 200:
        # This is exactly the captive-portal page case that must not be
        # mistaken for "already online".
        return "captive", "http-200-without-https"
    return "uncertain", f"http-{status}"


def is_online(timeout=3):
    return probe_connectivity(timeout=timeout)[0] == "online"


def wait_online(budget=POST_LOGIN_WAIT):
    """Poll until the portal grants access, instead of a fixed sleep."""
    deadline = time.monotonic() + budget
    delay = 0.15
    while True:
        if is_online():
            return True
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return False
        time.sleep(min(delay, remaining))
        delay = min(delay * 1.7, 0.8)


def get_portal_params(sess):
    """Probe the portal and extract the one-time CAS parameters.

    Rewrite the redirected host to the reachable portal while keeping the
    path and query intact. Query values are used locally and never logged.
    """
    log.info("Probing the campus probe URL for a portal redirect...")
    r = sess.get(TEST_URL, timeout=15, allow_redirects=False)

    if r.status_code == 204:
        if https_reachable():
            raise AlreadyOnline
        raise LoginError(
            "HTTP probe returned 204 but HTTPS is not reachable; "
            "state=portal-unknown"
        )

    if r.status_code == 200 or _normal_site_redirect(r):
        # A 200 can be Baidu itself or an intercepting login page. Do not
        # declare success from the status alone.
        if https_reachable():
            raise AlreadyOnline
        raise LoginError(
            "HTTP probe returned an ambiguous response and HTTPS failed; "
            "state=portal-unknown"
        )

    location = r.headers.get("Location", "")
    if not location:
        raise LoginError(
            "No portal redirect was returned by the HTTP probe; "
            "state=portal-unknown"
        )

    parsed = urlparse(location)
    redirect_url = f"{PORTAL}{parsed.path}?{parsed.query}"
    log.info("Following portal redirect (host=%s)", parsed.hostname or "unknown")
    r = sess.get(redirect_url, timeout=15, allow_redirects=True)
    final_host = (urlparse(r.url).hostname or "").lower()
    log.info("Portal chain finished: status=%s host=%s", r.status_code, final_host or "unknown")

    if "baidu" in final_host:
        if https_reachable():
            raise AlreadyOnline
        raise LoginError(
            "Portal redirect returned to Baidu but HTTPS is still unavailable; "
            "state=portal-unknown"
        )

    q = parse_qs(urlparse(r.url).query)
    sid = q.get("sessionId", [None])[0]
    uip = q.get("userIp", [None])[0]
    nas = q.get("nasIp", [None])[0]
    cid = q.get("customPageId", [None])[0]

    if not all([sid, cid]):
        raise LoginError(
            "Portal page is missing session/customPageId parameters; "
            "state=portal-unknown"
        )

    # Do not log the session, user/nas IPs, customPageId or full URL.
    log.info("Portal parameters received")
    return PORTAL, sid, uip, nas, cid


def _cas_url(portal, sid, cid, nas, uip, extra=""):
    t = str(int(time.time() * 1000))
    return (
        f"{portal}/cas-sso/login"
        f"?flowSessionId={sid}&customPageId={cid}"
        f"&preview=false&appType=normal&language=zh-CN"
        f"&timer={t}&nasIp={nas}&userIp={uip}{extra}"
    )


def fetch_cas_page(sess, portal, sid, cid, nas, uip):
    r = sess.get(_cas_url(portal, sid, cid, nas, uip), timeout=15)
    r.raise_for_status()

    m = re.search(r'<p\s+id="login-page-flowkey">([^<]+)</p>', r.text)
    if not m:
        raise LoginError("execution token not found")
    execution = m.group(1)

    m = re.search(r'<p\s+id="login-croypto">([^<]*)</p>', r.text)
    if not m:
        raise LoginError("croypto key not found")
    croypto = m.group(1)

    cap = re.search(r'<p\s+id="captcha-url">([^<]*)</p>', r.text)
    ven = re.search(r'<p\s+id="recaptchaVendor">([^<]*)</p>', r.text)
    cap_url = cap.group(1) if cap else ""
    cap_vendor = ven.group(1) if ven else ""
    if cap_url and cap_vendor != "none":
        log.warning("Captcha detected (%s), may fail", cap_vendor)

    return execution, croypto


def submit_login(sess, portal, user, pwd, execution, croypto, sid, cid, nas, uip):
    url = _cas_url(portal, sid, cid, nas, uip, "&accept-language=zh-CN")
    data = {
        "_eventId": "submit",
        "type": "UsernamePassword",
        "execution": execution,
        "geolocation": "",
        "username": user,
        "password": aes_b64(croypto, pwd),
        "croypto": croypto,
        "captcha_code": "",
        "captcha_payload": aes_b64(croypto, "{}"),
    }
    log.info("Submitting campus credentials...")
    r = sess.post(url, data=data, allow_redirects=True, timeout=30)
    final_host = (urlparse(r.url).hostname or "").lower()
    log.info("Login response: status=%s host=%s", r.status_code, final_host or "unknown")

    if "/cas-sso/login" not in r.url:
        return True

    m = re.search(r'<p\s+id="login-error-msg"[^>]*>([^<]+)</p>', r.text)
    if m and m.group(1).strip():
        log.error("State: auth-failed (%s)", m.group(1).strip())
        return False

    m = re.search(r'"loginFailMessage"[^>]*>([^<]+)</p>', r.text)
    if m and m.group(1).strip():
        log.error("State: auth-failed (%s)", m.group(1).strip())
        return False

    log.error("State: auth-failed (still on the login page)")
    return False


def do_login(user, pwd):
    with _session() as sess:
        portal, sid, uip, nas, cid = get_portal_params(sess)
        execution, croypto = fetch_cas_page(sess, portal, sid, cid, nas, uip)
        ok = submit_login(sess, portal, user, pwd, execution, croypto, sid, cid, nas, uip)
    if ok:
        log.info("Login submission accepted")
    return ok


def login_until_ok(user, pwd, retries, interval):
    """Return 0 when verified online, 3 when login passed but unverified, 1 otherwise."""
    result = 1
    last_state = "auth-failed"
    for i in range(1, retries + 1):
        log.info("=== Attempt %d/%d ===", i, retries)
        try:
            if do_login(user, pwd):
                if wait_online():
                    log.info("State: online (verified)")
                    return 0
                result = 3
                last_state = "submitted-unverified"
                log.warning("State: submitted-unverified (login accepted, connectivity not restored)")
        except AlreadyOnline:
            log.info("State: already-online")
            return 0
        except LoginError as e:
            last_state = "portal-unknown" if "portal-unknown" in str(e) else "auth-failed"
            log.error("State: %s (%s)", last_state, e)
        except requests.RequestException as e:
            last_state = "network-error"
            # Exception text can contain the full URL. Log only its type.
            log.error("State: network-error (%s)", type(e).__name__)
        if i < retries:
            log.info("Retrying in %ds...", interval)
            time.sleep(interval)
    log.error("State: %s", last_state)
    return result


def daemon(user, pwd, interval):
    log.info("Daemon started, interval=%ds", interval)
    while True:
        try:
            state, detail = probe_connectivity()
            if state == "online":
                log.debug("State: online (%s)", detail)
            else:
                log.info("State: %s (%s), re-authenticating...", state, detail)
                login_until_ok(user, pwd, 3, 5)
            time.sleep(interval)
        except KeyboardInterrupt:
            log.info("Daemon stopped")
            return
        except Exception as e:
            # Never include exception text: it may contain a URL or token.
            log.error("Unexpected error (%s); retrying in %ds", type(e).__name__, interval)
            time.sleep(interval)


def _read_credential(credential_dir, name):
    path = os.path.join(credential_dir, name)
    try:
        with open(path, "r", encoding="utf-8") as handle:
            value = handle.read()
    except FileNotFoundError:
        raise CredentialError(f"missing credential file: {path}")
    except OSError as exc:
        raise CredentialError(f"cannot read credential file {path}: {exc.strerror or type(exc).__name__}")
    value = value.rstrip("\r\n")
    if name == "username":
        value = value.strip()
    if not value:
        raise CredentialError(f"credential file is empty: {path}")
    return value


def resolve_credentials(username=None, password=None):
    """Resolve credentials without ever logging their values.

    Priority when systemd provides CREDENTIALS_DIRECTORY:
      explicit -u/-p, then the credential files.
    Manual runs without CREDENTIALS_DIRECTORY keep the original environment
    fallback: WIFI_USERNAME/WIFI_PASSWORD and the phone-number suffix default.
    """
    credential_dir = os.environ.get("CREDENTIALS_DIRECTORY")
    if credential_dir:
        user = username or _read_credential(credential_dir, "username")
        pwd = password or _read_credential(credential_dir, "password")
        return user, pwd

    user = username or os.environ.get("WIFI_USERNAME", "")
    pwd = password or os.environ.get("WIFI_PASSWORD", "")
    if not user:
        raise CredentialError(
            "username is required (-u PHONE, WIFI_USERNAME, or "
            "CREDENTIALS_DIRECTORY/username)"
        )
    if not pwd:
        pwd = user[-8:]
    return user, pwd


def main():
    env_u = os.environ.get("WIFI_USERNAME", "")
    env_p = os.environ.get("WIFI_PASSWORD", "")

    p = argparse.ArgumentParser(
        description="Ruijie campus network auto-login & keep-alive",
        epilog=(
            "Examples:\n"
            "  python3 campus-login.py -u 13800138000\n"
            "  python3 campus-login.py -u 13800138000 -d\n"
            "  python3 campus-login.py -c"
        ),
    )
    p.add_argument("-u", "--username", default=env_u or None,
                   help="phone number (env: WIFI_USERNAME)")
    p.add_argument("-p", "--password", default=env_p or None,
                   help="password override; defaults to credential file or last 8 digits of username")
    p.add_argument("-d", "--daemon", action="store_true",
                   help="keep-alive daemon mode")
    p.add_argument("--daemon-interval", type=int, default=60,
                   help="seconds between checks (default: 60)")
    p.add_argument("-r", "--retry", type=int, default=3)
    p.add_argument("-i", "--interval", type=int, default=5)
    p.add_argument("-c", "--check", action="store_true",
                   help="check connectivity only")
    p.add_argument("-v", "--verbose", action="store_true")
    args = p.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    if args.check:
        state, detail = probe_connectivity()
        log.info("State: %s (%s)", state, detail)
        sys.exit(0 if state == "online" else 1)

    try:
        user, password = resolve_credentials(args.username, args.password)
    except CredentialError as e:
        log.error("Credential configuration error: %s", e)
        sys.exit(78)

    if args.daemon:
        daemon(user, password, args.daemon_interval)
    else:
        sys.exit(login_until_ok(user=user, pwd=password,
                                retries=args.retry, interval=args.interval))


if __name__ == "__main__":
    main()
