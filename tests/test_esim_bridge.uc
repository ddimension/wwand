// wwand tests — esim_bridge lpac stdio-protocol line classifier.
//
// The bridge pulls lpac's JSON protocol fields with match() (ucode's json()
// throws uncatchably), which is brittle against lpac output changes — this
// suite pins the exact classification for every line shape the lpac 2.3
// stdio driver emits, plus the noise cases.

'use strict';

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

done('test_esim_bridge');
