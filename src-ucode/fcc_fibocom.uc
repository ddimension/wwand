// Fibocom GTFCCLOCK FCC unlock (MediaTek T7xx laptop modems, e.g. FM350-GL).
//
// WHAT IT IS. A laptop-SKU FM350 ships FCC-locked: GTFCCEFFSTATUS reads mode 2
// ("unlock every time after power on") with unlock status 0 (locked), MBIM
// HwRadioState reads OFF, AT+CFUN is 1 yet the modem never searches
// (+CEREG: 0,0, +COPS=? ERROR). It is NOT a physical W_DISABLE kill — it clears
// from software, but only through the vendor challenge/response below, and it
// re-arms on every modem power cycle (hence mode 2), so the daemon runs it on
// each bring-up that finds the radio off.
//
// THE EXCHANGE (AT, on the modem's AT port):
//   AT+GTFCCLOCKGEN              -> +GTFCCLOCKGEN: 0x<challenge>
//   AT+GTFCCLOCKVER=<response>   -> +GTFCCLOCKVER: 1   (0 = rejected)
//   response = sha256( challenge_BE32 || sha256(model_id)[0:4] )[0:4], as an
//   unsigned decimal. The challenge is taken big-endian (its hex digits in
//   order). model_id is the OEM string the card's firmware keys to; the modem
//   checks the response against its own copy, so the right id is a property of
//   the CARD, not the host.
//
// SOURCES. ModemManager data/dispatcher-fcc-unlock/14c3 (all 14c3:4d75 map to
// it, meson.build) and twh/wwan-unlock modules/14c3:4d75 agree on the formula
// and the big-endian challenge; MM MR!1491 is why the host model_id is read
// from SMBIOS type 133. HW-verified end to end on a Dell DW5931e (MediaTek
// T7xx, 14c3:4d75 / subsystem 1028:5931) in an HP EliteBook 850 G7 — which
// ships no SMBIOS type 133, so the known id below is what released it
// (2026-10-30, challenge 0x40799ebd -> response 3436456810 -> GTFCCLOCKVER: 1).

import * as fs from 'fs';

// sha256 is INJECTED (the `sha` argument: a (string)->64-hex-digest function,
// in production digest.sha256 from ucode-mod-digest, which modem_mbim passes
// in). The module itself imports no crypto so it loads on a host without the
// digest module — the tests exercise the exact byte assembly with a sha256sum-
// backed `sha`, which no top-level import would allow.

// OEM model-id strings whose sha256[0:4] the FM350 firmware verifies. Tried in
// turn after any SMBIOS-derived id; the first the modem accepts wins. The modem
// keys the id to the WWAN card, so a Dell card unlocks with the Dell id even in
// a non-Dell laptop.
//   Dell   'DW5931EFCCLOCK' -> sha256[:4] 4909b5a4   (HW-verified, 2026-10-30)
//   Lenovo 'KHOIHGIUCCHHII' -> sha256[:4] 3df8c719   (ModemManager 14c3)
const KNOWN_MODEL_IDS = [ 'DW5931EFCCLOCK', 'KHOIHGIUCCHHII' ];

// sha256(model_id)[0:4] as 8 lowercase hex — the per-vendor constant mixed into
// the challenge response. `sha`: a (string)->hex-digest function.
export function key_of(model_id, sha)
{
	return substr(sha(model_id), 0, 8);
};

// Response an +GTFCCLOCKVER expects for a GTFCCLOCKGEN `challenge` (a hex string
// with or without a 0x prefix, or an integer) and a `key` from key_of(). Big-
// endian challenge; returns the unsigned decimal number to send. `sha`: as above.
export function response(challenge, key, sha)
{
	let n = (type(challenge) == 'string')
		? hex(replace(challenge, /^0x/i, '')) : challenge;

	// challenge as 8 hex digits (big-endian) then the 8-hex key = 8 raw bytes
	let combined = sprintf('%08x', n) + key;
	let bin = '';
	for (let i = 0; i < length(combined); i += 2)
		bin += chr(hex(substr(combined, i, 2)));

	return hex(substr(sha(bin), 0, 8));
};

// First OEM string in SMBIOS type 133 (what the FM350 unlock derives the host
// model_id from), or null when absent — the usual case on routers and on HP
// laptops, where KNOWN_MODEL_IDS cover it. Reads entry 133-0 the way
// ModemManager MR!1491 does: byte 1 is the formatted-area length, the
// string set follows it, NUL-separated. Never throws.
export function smbios_model_id()
{
	let f = fs.open('/sys/firmware/dmi/entries/133-0/raw', 'r');
	if (!f)
		return null;

	let raw = f.read('all');
	f.close();

	if (!raw || length(raw) < 2)
		return null;

	let flen = ord(raw, 1);
	if (flen >= length(raw))
		return null;

	let s = substr(raw, flen);
	let z = index(s, '\x00');
	let first = (z >= 0) ? substr(s, 0, z) : s;

	return length(first) ? first : null;
};

// Candidate model-id strings for an `option fcc_auth` value. 'fibocom:<id>'
// pins exactly one; otherwise the SMBIOS id (if any) is tried first, then the
// known OEM ids.
export function model_ids(cfg)
{
	let p = split(sprintf('%s', cfg ?? ''), ':');
	if (p[0] == 'fibocom' && p[1] != null && p[1] != '')
		return [ p[1] ];

	let out = [];
	let sm = smbios_model_id();
	if (sm)
		push(out, sm);
	for (let m in KNOWN_MODEL_IDS)
		push(out, m);

	return out;
};

// true when an AT reply carries +GTFCCLOCKVER with a trailing 1 (unlocked).
function ver_ok(lines)
{
	for (let l in (lines ?? [])) {
		let m = match(l, /\+GTFCCLOCKVER:\s*([0-9]+)/);
		if (m)
			return (+m[1] == 1);
	}
	return false;
}

// the hex challenge in a +GTFCCLOCKGEN reply (0x...), or null.
function challenge_of(lines)
{
	for (let l in (lines ?? [])) {
		let m = match(l, /0x([0-9a-fA-F]+)/);
		if (m)
			return m[1];
	}
	return null;
}

// Run the challenge/response unlock over `at` (any engine with
// .send(cmd, cb(err, res)) whose res.lines is the reply, as modem_common's AT
// engines are). Tries each model id from model_ids(cfg) with a fresh challenge.
// cb(true) on the first +GTFCCLOCKVER: 1; cb(false) if none is accepted or the
// firmware has no GTFCCLOCKGEN (not an FM350 FCC lock). `sha`: the injected
// sha256 (see top of file). Never throws.
export function unlock(at, log, cfg, sha, cb)
{
	let ids = model_ids(cfg);
	let i = 0, step;

	step = () => {
		if (i >= length(ids))
			return cb(false);

		let mid = ids[i++];

		at.send('AT+GTFCCLOCKGEN', (err, res) => {
			let chal = err ? null : challenge_of(res?.lines);

			// No challenge at all => the firmware has no GTFCCLOCK (so not an
			// FM350 FCC lock). Stop on the first try rather than resend the
			// same ERROR once per id.
			if (!chal) {
				if (i == 1)
					log('info', 'FCC(fibocom): modem has no GTFCCLOCKGEN — skipping');
				return (i == 1) ? cb(false) : step();
			}

			let resp = response(chal, key_of(mid, sha), sha);

			at.send('AT+GTFCCLOCKVER=' + resp, (e2, r2) => {
				if (!e2 && ver_ok(r2?.lines)) {
					log('notice', sprintf('FCC(fibocom): unlocked (model-id "%s")', mid));
					return cb(true);
				}

				log('info', sprintf('FCC(fibocom): model-id "%s" rejected', mid));
				step();
			});
		});
	};

	step();
};
