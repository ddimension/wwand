#!/usr/bin/env python3
"""Capture a LuCI page as a documentation screenshot, with the subscriber
identifiers masked.

The screenshots in docs/images/ used to be produced by hand, which is why they
went stale the moment the status page was rebuilt: nothing recorded how they
were made, so redoing them meant redoing the masking by eye as well. This does
both, the same way every time.

    tools/luci-screenshot.py --url http://192.168.203.245/cgi-bin/luci/admin/status/wwand \
                             --out docs/images/luci-status-chateau.png

Three things make a LuCI page hard to screenshot, and each is handled here:

  * IT REPAINTS EVERY SECOND. Masking the DOM and then capturing races the
    poll, which rebuilds the panels and restores the real values — so the poll
    is stopped first (L.Poll.stop(), the same thing that puts "PAUSED" in the
    header of the older screenshots).
  * THE INTERESTING PART TAKES TIME. The signal graphs draw a browser-side
    ring buffer that starts empty, so a page captured on load shows three empty
    canvases. --settle waits, by default long enough for a minute of history.
  * THE PAGE IS TALLER THAN ANY WINDOW. captureBeyondViewport gives the whole
    document in one PNG instead of a viewport-sized crop.

Masking keeps the first 5 and last 2 characters of an identifier and replaces
the middle, preserving its length — the format stays legible (an ICCID still
looks like an ICCID) while the card, the subscriber and the line do not. The
same shape as the hand-masked screenshots this replaces. Addresses are masked
too, which the older ones did not do: a public IPv6 prefix identifies a
subscriber line as surely as an IMSI does.
"""

import argparse
import asyncio
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

# Runs in the page. Order matters: stop the poll BEFORE masking, or the next
# tick paints the real values back in.
MASK_JS = r"""
(() => {
  /* Report, do not assume. Everything below can fail on a LuCI whose internals
     moved, and a masker that fails quietly writes an UNMASKED screenshot of a
     live router — the one outcome this tool must never produce. The caller
     refuses to save the image unless this returns ok:true. */
  let polled = false;

  try { polled = !!(window.L && L.Poll && L.Poll.stop && (L.Poll.stop(), true)); } catch (e) {}

  const keep = (s, head, tail) =>
    s.length <= head + tail ? s
      : s.slice(0, head) + 'X'.repeat(s.length - head - tail) + s.slice(s.length - tail);

  /* An identifier is masked by LENGTH, not by the label next to it: the same
     15-digit run is an IMSI in one row and an IMEI in another, and a run that
     long is never a cell id, an EARFCN or a byte counter. 14 is the floor
     because the longest thing we must NOT touch is a 9-digit cell id. */
  const maskText = (t) => t
    .replace(/\d{14,}/g, (m) => keep(m, 5, 2))
    /* IPv4: the last two octets carry the host, the first two the operator's
       block — enough to show the shape without publishing the line. */
    .replace(/\b(\d{1,3}\.\d{1,3})\.\d{1,3}\.\d{1,3}\b/g, '$1.XXX.XXX')
    /* IPv6: keep only the leading hextet. A /64 delegated prefix identifies a
       subscriber line as surely as an IMSI does. The GROUP COUNT is preserved
       and a `::` left intact, so the result still reads as an IPv6 address of
       the right shape rather than a shorter string that no longer looks like
       one.

       A MAC IS NOT AN IPv6 ADDRESS, and this rule used to eat one: the
       interfaces page prints `04:1b:6f:xx:xx:xx`, six colon-separated hex
       groups, which this pattern matched happily and rewrote to
       `04:XXXX:XXXX:XXXX:XXXX:XXXX` — no longer a MAC, no longer anything.
       Six two-digit groups are left for the MAC rule below. Greedy matching
       makes that guard sufficient on the first pass: the whole MAC is matched
       as one candidate, never a three-group prefix of it.

       THE SECOND GUARD IS FOR THE SECOND PASS. This function has to be
       idempotent, because the verification below re-runs it to prove nothing
       repainted over the mask. An already-masked MAC leaves its OUI behind as
       `04:1b:6f`, three two-digit hex groups, which this pattern would then eat
       as a short IPv6 — every capture of a page showing a MAC would have been
       refused as "residue". No real IPv6 address is three two-digit groups
       (it needs four groups or a `::`), so skipping that exact shape costs
       nothing.

       The pattern also has to END on a real group. Allowing a trailing empty
       one let it match `04:1b:6f:` — OUI plus the colon before the masked
       octets — which slipped past both guards and re-masked a MAC on the
       second pass. */
    .replace(/\b[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{0,4}){1,6}:[0-9a-fA-F]{1,4}\b/g, (m) =>
      (/^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$/.test(m) ||
       /^[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){2}$/.test(m)) ? m
        : m.split(':').map((g, i) => (i === 0 || g === '') ? g : 'XXXX').join(':'))
    /* MAC: keep the OUI — it names the vendor and is worth seeing — and mask
       the three octets that identify the individual device. */
    .replace(/\b([0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){2})(?::[0-9a-fA-F]{2}){3}\b/g,
             '$1:XX:XX:XX');

  const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  let n, count = 0;

  while ((n = walk.nextNode())) {
    const masked = maskText(n.nodeValue);

    if (masked !== n.nodeValue) { n.nodeValue = masked; count++; }
  }

  /* input values and titles are not text nodes and hold the same data */
  for (const el of document.querySelectorAll('input[value], [title]')) {
    if (el.value) el.value = maskText(el.value);
    if (el.title) el.title = maskText(el.title);
  }

  /* A second pass proves the first one held: if a repaint slipped in between,
     these matches are what it painted back, and the caller is told. */
  let residue = 0;
  const w2 = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);

  while ((n = w2.nextNode()))
    if (maskText(n.nodeValue) !== n.nodeValue) residue++;

  return { ok: polled && residue === 0, polled: polled,
           masked: count, residue: residue };
})()
"""


def luci_login(url, user, password):
    """Get a LuCI session cookie the way a browser does, without a browser.

    LuCI does NOT accept a session minted with `ubus call session login` — that
    yields a valid ubus session, and the dispatcher still answers 403, because
    LuCI keeps its own session data. So post the login form and keep what it
    sets. The password is read from the environment, never from the command
    line, and on a lab router it is empty.
    """
    import http.cookiejar
    import urllib.parse

    base = url.split('/cgi-bin/luci')[0] + '/cgi-bin/luci/'
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar),
                                         NoRedirect())
    body = urllib.parse.urlencode({'luci_username': user,
                                   'luci_password': password}).encode()

    try:
        opener.open(urllib.request.Request(base, data=body), timeout=15)
    except urllib.error.HTTPError:
        pass          # the 302 IS the success case

    for c in jar:
        if c.name.startswith('sysauth'):
            return c.name, c.value

    sys.exit('LuCI login did not return a session cookie — wrong password?')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **kw):
        return None


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def find_chrome():
    for exe in ('google-chrome', 'google-chrome-stable', 'chromium',
                'chromium-browser', '/opt/google/chrome/chrome'):
        path = shutil.which(exe) or (exe if os.path.exists(exe) else None)
        if path:
            return path
    sys.exit('no chrome/chromium found')


async def capture(ws_url, url, settle, mask, out, cookies, steps):
    import websockets

    # ping_interval=None: Chrome's CDP socket does not answer websocket pings,
    # so the default keepalive kills the connection during the settle wait —
    # "sent 1011 (internal error) keepalive ping timeout", right before the
    # screenshot would have been taken.
    async with websockets.connect(ws_url, max_size=None,
                                  ping_interval=None, close_timeout=5) as ws:
        seq = 0

        async def cmd(method, **params):
            nonlocal seq
            seq += 1
            await ws.send(json.dumps({'id': seq, 'method': method, 'params': params}))

            while True:
                msg = json.loads(await ws.recv())

                if msg.get('id') == seq:
                    if 'error' in msg:
                        sys.exit('%s: %s' % (method, msg['error']))
                    return msg.get('result', {})

        await cmd('Page.enable')
        await cmd('Network.enable')

        for c in cookies:
            name, _, value = c.partition('=')
            # path explicitly: LuCI sets its cookie on /cgi-bin/luci/, and
            # letting Chrome derive one from the deep URL scopes it too tightly
            await cmd('Network.setCookie', name=name, value=value, url=url,
                      path='/cgi-bin/luci/')

        await cmd('Page.navigate', url=url)

        print('  loading, then settling %ds (the graphs fill from empty)' % settle)
        await asyncio.sleep(settle)

        # Some pages are only reachable by clicking: an interface dialog is a
        # modal, not a URL. Each --eval runs in the page, with a pause after it
        # for whatever it opened to render.
        for step in steps:
            r = await cmd('Runtime.evaluate', expression=step, returnByValue=True,
                          awaitPromise=True)
            print('  eval -> %s' % r.get('result', {}).get('value'))
            await asyncio.sleep(3)

        if mask:
            r = await cmd('Runtime.evaluate', expression=MASK_JS, returnByValue=True)

            # CDP reports a thrown exception in exceptionDetails, NOT in the
            # command's own `error` — checking only the latter let a masker that
            # died on the first line look like a masker that found nothing to do.
            if 'exceptionDetails' in r:
                sys.exit('masking threw in the page: %s\nrefusing to save an '
                         'unmasked screenshot' %
                         r['exceptionDetails'].get('exception', {}).get('description',
                                                                       r['exceptionDetails']))

            v = r.get('result', {}).get('value')

            if not isinstance(v, dict) or not v.get('ok'):
                sys.exit('masking did not complete (%s) — refusing to save. A '
                         'residue count above zero means the page repainted over '
                         'the mask; polled=false means L.Poll.stop() is gone or '
                         'renamed in this LuCI.' % v)

            print('  poll stopped, %d text nodes masked, 0 residue' % v['masked'])

        shot = await cmd('Page.captureScreenshot', format='png',
                         captureBeyondViewport=True)

        import base64
        data = base64.b64decode(shot['data'])

        with open(out, 'wb') as fh:
            fh.write(data)

        print('  wrote %s (%d bytes)' % (out, len(data)))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--url', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--width', type=int, default=1440,
                    help='viewport width; the existing docs images are 1440')
    ap.add_argument('--height', type=int, default=1200)
    ap.add_argument('--settle', type=int, default=75,
                    help='seconds to let the page run before capturing — the '
                         'signal graphs need history to show anything (default 75)')
    ap.add_argument('--cookie', action='append', default=[], metavar='NAME=VALUE',
                    help='session cookie to set before navigating. A fresh '
                         'browser profile has no LuCI session and lands on the '
                         'login form; mint one on the router instead of typing '
                         'a password into a browser:  ssh root@BOX \'ubus call '
                         'session login \'"\'"\'{"username":"root","password":""}\'"\'"\'\' '
                         'and pass sysauth_http=<ubus_rpc_session>')
    ap.add_argument('--login', metavar='USER',
                    help='log in as USER first and use the session it returns. '
                         'The password comes from $LUCI_PASSWORD (empty if '
                         'unset), never from the command line.')
    ap.add_argument('--eval', action='append', default=[], metavar='JS',
                    help='JavaScript to run after the page settles, before '
                         'masking — for views reachable only by clicking, such '
                         'as the interface dialog. Repeatable, in order.')
    ap.add_argument('--no-mask', action='store_true',
                    help='capture unmasked (never for anything committed)')
    args = ap.parse_args()

    cookies = list(args.cookie)

    if args.login:
        name, value = luci_login(args.url, args.login,
                                 os.environ.get('LUCI_PASSWORD', ''))
        cookies.append('%s=%s' % (name, value))
        print('  logged in as %s (%s)' % (args.login, name))

    chrome = find_chrome()
    port = free_port()

    with tempfile.TemporaryDirectory(prefix='luci-shot-') as profile:
        proc = subprocess.Popen(
            [chrome, '--headless=new', '--remote-debugging-port=%d' % port,
             '--user-data-dir=%s' % profile, '--no-first-run',
             '--no-default-browser-check', '--disable-gpu', '--hide-scrollbars',
             '--force-device-scale-factor=1',
             '--window-size=%d,%d' % (args.width, args.height)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        try:
            ws_url = None

            for _ in range(50):
                try:
                    with urllib.request.urlopen('http://127.0.0.1:%d/json' % port,
                                                timeout=1) as fh:
                        for t in json.load(fh):
                            if t.get('type') == 'page':
                                ws_url = t['webSocketDebuggerUrl']
                                break
                except Exception:
                    pass

                if ws_url:
                    break

                time.sleep(0.2)

            if not ws_url:
                sys.exit('chrome did not expose a debugging target')

            asyncio.run(capture(ws_url, args.url, args.settle,
                                not args.no_mask, args.out, cookies,
                                getattr(args, 'eval')))
        finally:
            proc.terminate()
            proc.wait(timeout=10)


if __name__ == '__main__':
    main()
