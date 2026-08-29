// wwand tests — esim_bridge lpac stdio-protocol line classifier.
//
// The bridge pulls lpac's JSON protocol fields with match() (ucode's json()
// throws uncatchably), which is brittle against lpac output changes — this
// suite pins the exact classification for every line shape the lpac 2.3
// stdio driver emits, plus the noise cases.

'use strict';

import * as fs from 'fs';
import * as uloop from 'uloop';
import { eq, ok, done } from './lib/check.uc';

let bridge = require('wwand.esim_bridge');

ok(type(bridge) == 'object', 'bridge: module loads via require()');
ok(type(bridge.parse_lpac_line) == 'function', 'bridge: parser exposed');

let P = bridge.parse_lpac_line;

// --- APDU requests (the four driver funcs) -----------------------------------

let r = P('{"type":"apdu","payload":{"func":"connect","param":""}}');
eq(r.kind, 'apdu', 'apdu connect: kind');
eq(r.func, 'connect', 'apdu connect: func');
eq(r.param, '', 'apdu connect: empty param');

r = P('{"type":"apdu","payload":{"func":"logic_channel_open","param":"a0000005591010ffffffff8900000100"}}');
eq(r.func, 'logic_channel_open', 'apdu open: func');
eq(r.param, 'a0000005591010ffffffff8900000100', 'apdu open: AID param');

r = P('{"type":"apdu","payload":{"func":"transmit","param":"80E2910003BF3E00"}}');
eq(r.func, 'transmit', 'apdu transmit: func');
eq(r.param, '80E2910003BF3E00', 'apdu transmit: hex param (case preserved)');

r = P('{"type":"apdu","payload":{"func":"logic_channel_close","param":""}}');
eq(r.func, 'logic_channel_close', 'apdu close: func');

// --- progress + lpa result ---------------------------------------------------

r = P('{"type":"progress","payload":{"message":"es10b_get_euicc_challenge_and_info"}}');
eq(r.kind, 'progress', 'progress: kind');
eq(r.message, 'es10b_get_euicc_challenge_and_info', 'progress: message');

r = P('{"type":"progress","payload":{}}');
eq(r.message, 'step', 'progress: missing message falls back to "step"');

r = P('{"type":"lpa","payload":{"code":0,"message":"success","data":"89490200002170148903"}}');
eq(r.kind, 'lpa', 'lpa ok: kind');
eq(r.code, '0', 'lpa ok: code 0');
eq(r.message, 'success', 'lpa ok: message');
eq(r.data, '89490200002170148903', 'lpa ok: data');

r = P('{"type":"lpa","payload":{"code":-1,"message":"es10c_enable_profile","data":"profile not in disabled state"}}');
eq(r.code, '-1', 'lpa refusal: negative code');
eq(r.message, 'es10c_enable_profile', 'lpa refusal: message');
eq(r.data, 'profile not in disabled state', 'lpa refusal: detail data');

// --- noise / robustness ------------------------------------------------------

eq(P(''), null, 'empty line -> null');
eq(P(null), null, 'null -> null');

r = P('curl: (6) Could not resolve host');
eq(r.kind, 'log', 'plain stderr noise: logged');
eq(r.text, 'curl: (6) Could not resolve host', 'plain noise: text preserved');

r = P('{"type":"future_thing","payload":{}}');
eq(r.kind, 'log', 'unknown JSON object: kept visible as log');

r = P('{broken json');
eq(r.kind, 'log', 'malformed JSON: logged, never thrown');

// --- modem_esim op router (the done-routing surface LuCI calls) --------------
//
// No lpac on the host (lpac_path points at nothing) -> every lpac path takes
// the esim_not_installed branch — side-effect-free and exercises the exact
// error routing (missing_argument / invalid_argument / fallback) that guards
// the shell call. Each op must clear _esim_op and surface errors as
// { error: 'esim', detail: ... }.
let dl_at_called = null;
let backend_at = false;   // flipped for the in-modem download test
let dl_auto = true, dl_completion = null;   // download completion control
let esim_fake = {
	backend: (m, s, cb) => cb(backend_at ? 'at' : 'qmi'),
	// async completion (like the real in-modem download): fires AFTER the
	// start-ack, so the quiet re-raise ordering is what the test pins
	download_at: (m, code, conf, cb) => {
		dl_at_called = code;
		if (dl_auto) uloop.timer(0, () => cb(null, { ret: 0 }));
		else dl_completion = cb;
	},
	profiles: (m, s, cb) => cb(null, { profiles: [] }),
	get_eid: (m, s, cb) => cb(null, { eid: '89000000000000000000000000000000' }),
	enable: (m, s, iccid, cb) => cb(null, { ok: true, via: 'esim' }),
	disable: (m, s, iccid, cb) => cb(null, { ok: true, via: 'esim' }),
	del: (m, s, iccid, cb) => cb(null, { ok: true, via: 'esim' }),
};

// _esim_op is a REFCOUNT (0 = idle, n>0 = quiet); readers only test
// truthiness, so the assertions below pin exactly that contract
let entry = { modem: { id: 'm0', _esim_op: 0 } };
let br = bridge.create({ esim: esim_fake, log: () => null,
	modem_of: (r) => (r == 'm0') ? entry : null,
	lpac_path: '/nonexistent-lpac' });

let chain = [];

let expect = (op, params, err_name, then) =>
	push(chain, { op: op, params: params, err: err_name, then: then });

let lpac_stdio_tests;   // declared here: the chain end calls it (defined below)
let run_chain;   // forward-declared (self-referencing arrow — ucode TDZ)
run_chain = (idx) => {
	if (idx >= length(chain)) {
		// the last download's run is still open (its completion was parked):
		// quiet stays raised until the modem reports the download finished.
		uloop.timer(0, () => {
			eq(!!entry.modem._esim_op, true, 'router: quiet raised while the download runs');

			// the refcount contract: a SECOND op that starts and finishes
			// while the download is still running must not re-open the AT
			// queue — as a plain flag its done() cleared the download's
			// claim too (the daemon's bring-up refresh races user ops here)
			br.modem_esim('m0', 'profiles', {}, () => {
				eq(!!entry.modem._esim_op, true,
					'router: a parallel op completing leaves the running download quiet');

				dl_completion(null, { ret: 0 });   // simulate the modem finishing
				eq(!!entry.modem._esim_op, false, 'router: quiet cleared at download completion');
				lpac_stdio_tests();
			});
		});
		return;
	}

	let c = chain[idx];

	br.modem_esim('m0', c.op, c.params, (err, res) => {
		if (c.err != null) {
			eq(err?.error, 'esim', sprintf('router %s: error wrapper shape', c.op));
			eq(err?.detail?.error, c.err, sprintf('router %s: %s', c.op, c.err));
		}
		else
			eq(err, null, sprintf('router %s: no error', c.op));
		if (c.then) c.then(res);
		run_chain(idx + 1);
	});
};

expect('download', {}, 'missing_argument');
expect('download', { activation_code: 'LPA:1$x;rm$y' }, 'invalid_argument');
expect('download', { activation_code: 'LPA:1$a$b' }, 'esim_not_installed');
expect('notifications', {}, 'esim_not_installed');
expect('notify', {}, 'esim_not_installed');
expect('download_status', {}, null, (res) => {
	// the failed lpac starts must not wedge dl 'running' (the notify leak fix)
	eq(res?.state, 'failed', 'router download_status: dl never wedged running');
});
expect('enable', { iccid: 'x' }, 'invalid_argument');
expect('enable', {}, 'missing_argument');
expect('enable', { iccid: '89358152000000075749' }, null, (res) => {
	eq(res, { ok: true, via: 'esim' }, 'router enable: no lpac -> esim.enable fallback');
});
expect('profiles', {}, null, (res) => {
	eq(res, { profiles: [] }, 'router profiles: passthrough');
});
expect('eid', {}, null, (res) => {
	eq(res?.eid, '89000000000000000000000000000000', 'router eid: passthrough');
	backend_at = true;   // the final download takes the in-modem AT path
	dl_auto = false;     // and its completion is parked (chain end drives it)
});
expect('download', { activation_code: 'LPA:1$a$b' }, null, (res) => {
	// the fake esim.backend reports 'at' -> the in-modem download path. The
	// ack fires first; the quiet-flag states are pinned at the chain end.
	eq(res, { started: true, via: 'modem' }, 'router download: AT backend starts in-modem');
	eq(dl_at_called, 'LPA:1$a$b', 'router download: code handed to download_at');
});

// --- the lpac stdio bridge, over a REAL spawned child -----------------------
//
// A stub standing in for /usr/bin/lpac: it speaks the stdio protocol and exits
// straight away, which is exactly the case the drain loop used to lose. A pipe
// whose writer is gone hands the buffered bytes to the first read() and EOF to
// the SECOND one — so data and EOF land in the SAME uloop cycle, and returning
// on EOF (as the old code did) dropped every complete line still in the buffer:
// lpac's `result: code=0` line and the __EXIT marker among them, turning a
// successful download into a reported failure.

let tmp = getenv('TMPDIR') ?? '/tmp';
let fake_ok = sprintf('%s/wwand-test-lpac-ok.sh', tmp);
let fake_mute = sprintf('%s/wwand-test-lpac-mute.sh', tmp);

let write_stub = (path, body) => {
	let f = fs.open(path, 'w');
	f.write(body);
	f.close();
	fs.chmod(path, 0o755);
};

// lpac_run opens the log file before the child runs; without the directory it
// silently logs nowhere (and the bridge then sees no result line at all)
try { fs.mkdir('/tmp/wwand'); } catch (e) { }

write_stub(fake_ok,
	"#!/bin/sh\n" +
	"printf '%s\\n' '{\"type\":\"progress\",\"payload\":{\"message\":\"es9p_initiate_authentication\"}}'\n" +
	"printf '%s\\n' '{\"type\":\"lpa\",\"payload\":{\"code\":0,\"message\":\"success\",\"data\":\"8900\"}}'\n" +
	"exit 0\n");

// stays silent past the (test-shortened) inactivity watchdog, like an lpac
// blocked in curl on a dead SM-DP+ socket
write_stub(fake_mute, "#!/bin/sh\nsleep 1\nexit 0\n");

let entry2 = { modem: { id: 'm0', _esim_op: 0 } };
let mk = (path, idle) => bridge.create({ esim: esim_fake, log: () => null,
	modem_of: (r) => (r == 'm0') ? entry2 : null,
	lpac_path: path, idle_ms: idle });

// poll download_status until the run leaves 'running' (bounded, so a
// regression fails the suite instead of hanging it)
let await_state;   // forward-declared (self-referencing arrow — ucode TDZ)
await_state = (b, left, cb) =>
	b.modem_esim('m0', 'download_status', {}, (e, res) => {
		if (res?.state != 'running' || left <= 0)
			return cb(res);

		uloop.timer(50, () => await_state(b, left - 1, cb));
	});

lpac_stdio_tests = () => {
	backend_at = false;   // back to the host-side (lpac) download path
	dl_auto = true;

	let b = mk(fake_ok, null);

	b.modem_esim('m0', 'download', { activation_code: 'LPA:1$a$b' }, (err, res) => {
		eq(err, null, 'lpac stdio: download starts');
		eq(res?.via, 'lpac', 'lpac stdio: takes the lpac path');

		await_state(b, 40, (st) => {
			eq(st?.state, 'done',
				'lpac stdio: result line arriving with EOF is still parsed');
			eq(!!entry2.modem._esim_op, false, 'lpac stdio: quiet claim released');

			// the watchdog: a child that says nothing must not wedge the
			// bridge at 'running' forever (every later op would answer 'busy')
			let bm = mk(fake_mute, 150);

			bm.modem_esim('m0', 'download', { activation_code: 'LPA:1$a$b' }, () => {
				await_state(bm, 40, (mst) => {
					eq(mst?.state, 'failed', 'lpac stdio: silent lpac times out');
					eq(!!entry2.modem._esim_op, false,
						'lpac stdio: timeout releases the quiet claim');

					fs.unlink(fake_ok);
					fs.unlink(fake_mute);
					done('test_esim_bridge');
				});
			});
		});
	});
};

// the no_such_modem early return precedes the done wrapper (no flag set yet) —
// the raw error shape, not the esim wrapper
br.modem_esim('nosuchref', 'eid', {}, (err) => {
	eq(err?.error, 'no_such_modem', 'router: unknown modem errors raw');
	run_chain(0);
});

uloop.run();
