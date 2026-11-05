// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand — board abstraction: modem power / reset GPIOs, status LEDs.
//
// Replaces the board-specific vendor helper scripts
// (e.g. Zyxel's /usr/sbin/lte3301): powering the modem, power-cycling a hung or
// vanished modem for the recovery ladder, and driving the mobile/LTE/signal LEDs
// from the modem's registration + signal.
//
// A profile is selected from /etc/board.json's model id: a board file
// `<model id>.json` under BOARD_DIRS if there is one, else the built-in table
// below. An unknown board yields a null profile — every operation is then a safe
// no-op, so the daemon runs unchanged on hardware we don't have a profile for.
// All sysfs access goes through an injectable fx (read/write/list) so the whole
// module is host-testable.

'use strict';

import * as fs from 'fs';
import * as uloop from 'uloop';
import * as ratmod from 'wwand.codec.schema.rat';

const GPIO_DIR = '/sys/class/gpio';
const LED_DIR = '/sys/class/leds';
// how long a power-cycle keeps the modem powered off / a reset GPIO stays asserted
const POWER_OFF_MS = 30000;      // default de-power duration (config repower_time)
const RESET_ASSERT_MS = 30000;   // per spec: invert, wait 30 s, restore

// Board files, searched in this order; a later directory wins. The first is for
// a device's own package or its target's base-files, which then carry the
// modem wiring along with the device itself instead of a PR to this table
// (ddimension/wwand#48). The second is the admin's, and survives a sysupgrade.
export const BOARD_DIRS = [ '/usr/share/wwand/boards.d', '/etc/wwand/boards.d' ];

export function default_fx()
{
	return {
		read: (p) => {
			let f = fs.open(p, 'r');
			if (!f)
				return null;
			let d = f.read('all');
			f.close();
			return d != null ? trim(d) : null;
		},
		write: (p, v) => {
			let f = fs.open(p, 'w');
			if (!f)
				return false;
			f.write(v);
			f.close();
			return true;
		},
		// list entries of a directory (for the named-GPIO enumeration)
		list: (p) => fs.lsdir(p),
		// does a path exist — used to detect an OPTIONAL gpio by its sysfs
		// directory rather than by one read of its value, which a single
		// transient read error would turn into "no such line" for the whole
		// daemon lifetime (Codex review, 2026-09-25)
	};
};

// the board model id, read straight from /etc/board.json (no ubus dependency).
// Parsed as JSON; a malformed file (json() does throw, but catchably) or a
// missing model.id yields null -> the null profile -> safe no-ops.
export function detect_id(fx)
{
	let raw = fx.read('/etc/board.json');

	if (!raw)
		return null;

	let data;

	try {
		data = json(raw);
	}
	catch (e) {
		return null;
	}

	return (type(data) == 'object') ? data.model?.id : null;
};

// all *named* GPIO lines the kernel exposes (i.e. gpio-line-names from the DT),
// for the LuCI reset/power picker. Skips the control pseudo-files and the raw
// gpiochip*/gpioNNN entries — a named line is what an admin can meaningfully pick.
export function list_named_gpios(fx)
{
	let out = [];

	for (let name in (fx.list(GPIO_DIR) ?? [])) {
		if (name == 'export' || name == 'unexport')
			continue;
		if (match(name, /^gpiochip[0-9]+$/) || match(name, /^gpio[0-9]+$/))
			continue;

		push(out, name);
	}

	return sort(out);
};

// A name that goes into a sysfs path: no slash, no '..'. GPIO and LED names
// share it; LED names carry colons (`green:mobile-1`). The instance's
// safe_gpio uses it too: a name the validator passed and the GPIO code then
// refused would give a profile that claims a power line it can never switch.
function safe_name(v)
{
	return type(v) == 'string' && length(v) > 0 && length(v) <= 64 &&
		!!match(v, /^[A-Za-z0-9._:-]+$/) && index(v, '..') < 0;
}

// --- LED rendering helpers (shared by the profiles) --------------------------

// a status LED value is either an integer brightness (0 = off, else on) or a
// trigger name string (e.g. 'timer' to blink). set_led applies whichever and
// returns whether every write landed.
function set_led(fx, name, val)
{
	if (name == null)
		return false;

	let base = sprintf('%s/%s', LED_DIR, name);

	if (type(val) == 'string')
		return !!fx.write(sprintf('%s/trigger', base), val);

	// take manual control, then set brightness (max_brightness would be more
	// correct, but 255 is clamped by the LED core and every panel accepts it)
	return !!fx.write(sprintf('%s/trigger', base), 'none') &&
		!!fx.write(sprintf('%s/brightness', base), val ? '255' : '0');
}

// whether an LED still shows `val`, read back from sysfs. The trigger file
// lists every trigger with the active one in brackets ("none [timer] …",
// led-triggers.c:95-132, 6.18.41); brightness reads the clamped value, 1 on a
// gpio-led, so on means "not 0". Anything unreadable is a mismatch: then the
// LED is written again, which is what an unchanged LED cost before it was
// cached.
function led_shows(fx, name, val)
{
	let base = sprintf('%s/%s', LED_DIR, name);
	let trig = fx.read(sprintf('%s/trigger', base));
	let want = (type(val) == 'string') ? val : 'none';

	if (trig == null)
		return false;

	trig = trim(trig);

	if (trig != want && index(trig, '[' + want + ']') < 0)
		return false;

	if (type(val) == 'string')
		return true;

	let br = fx.read(sprintf('%s/brightness', base));

	return br != null && ((trim(br) == '0') == !val);
}

// map a normalized signal object to a 0..5 bar level. Prefers 5G NR, then LTE
// RSRP, then a raw RSSI; thresholds match the usual "bars" mapping.
export function bars_from_signal(sig)
{
	if (!sig)
		return 0;

	// modems report -32768 (and similar large negatives) as "no measurement";
	// treat anything below a sane floor as absent so it never wins the ?? chain.
	let ok = (v) => v != null && v > -140;
	let pick = (...vals) => {
		for (let v in vals)
			if (ok(v))
				return v;
		return null;
	};

	// top-level rsrp/rssi: the native-MBIM v1 fallback shape is flat
	// ({ rssi, rsrp }) — without these picks a pure-native MBIM modem always
	// rendered 0 bars (LEDs dark despite full signal)
	let rsrp = pick(sig.nr5g?.rsrp, sig.lte?.rsrp, sig.rsrp);

	if (rsrp != null)
		return (rsrp >= -80) ? 5 : (rsrp >= -90) ? 4 : (rsrp >= -100) ? 3 :
		       (rsrp >= -110) ? 2 : 1;

	let rssi = pick(sig.lte?.rssi, sig.gsm_rssi, sig.wcdma?.rssi, sig.rssi);

	if (rssi != null)
		return (rssi >= -65) ? 5 : (rssi >= -75) ? 4 : (rssi >= -85) ? 3 :
		       (rssi >= -95) ? 2 : 1;

	return 0;
};

// The styles below do not write LEDs: each one PLANS, calling put(name, val)
// for every LED it drives, and self.leds() writes the merged plan once. Two
// reasons. A board can list several styles, and two of them may name the same
// LED; writing in style order would let the last one win, which on an RGB LED
// (three channels, one lamp) is a colour nobody chose. And a blink is the
// `timer` trigger: writing it again restarts the cycle, so a tick that
// re-wrote an unchanged LED every 10 s would put a visible stutter into it.

// light `n` of the given LED list, rest off (bar-graph signal indicator)
function plan_bars(put, leds, n)
{
	for (let i = 0; i < length(leds); i++)
		put(leds[i], (i < n) ? 255 : 0);
}

// the classic red/green(+orange) mobile + tech LED set (Zyxel LTE33xx)
function plan_mobile(put, m, s)
{
	// green solid when registered; red blinks while searching, off once up;
	// orange (if present) marks roaming
	put(m.green, s.registered ? 255 : 0);
	put(m.red, s.registered ? 0 : (s.present ? 'timer' : 255));
	if (m.orange != null)
		put(m.orange, s.roaming ? 255 : 0);
	// The tech LED is labelled LTE on these panels and lights only on LTE,
	// as the vendor helper did (`grep lte` over the serving-system state,
	// /usr/sbin/lte3301 in the vpn2go tree, Release_2024.10): a box that fell
	// back to 2G/3G shows it. `s.lte` says so (daemon led_state); a caller
	// that does not know it keeps the old meaning, attached on any RAT.
	if (m.tech != null)
		put(m.tech, (s.registered && (s.lte ?? (s.radio != null))) ? 255 : 0);
}

// the generations a `tech` panel can label, oldest first
const GENERATIONS = [ '2g', '3g', '4g', '5g' ];

// rat.uc family -> generation; NTN has none a panel would label. EVDO shares
// the cdma family with 1x but is CDMA2000's 3G, hence the slug override.
const RAT_GEN = { cdma: '2g', evdo: '3g' };
const FAMILY_GEN = { gsm: '2g', umts: '3g', lte: '4g', nr5g: '5g' };

// QMI NAS radio interfaces (rat.uc from_qmi_radio_if) -> generation; 1x is
// CDMA2000's 2G, EVDO its 3G
const RADIO_IF_GEN = { '1': '2g', '4': '2g', '2': '3g', '5': '3g', '9': '3g', '8': '4g', '12': '5g' };

// The generation a modem is on, for a `tech` panel: '2g'..'5g' or null.
// `rat` is the modem's rat_fine (rat.uc object or slug), which knows 5G NSA
// from the DSD mode while NAS still lists only the LTE anchor; then the
// highest NAS radio interface; then the RAT text an NCM modem reports.
export function generation(o)
{
	let rat = (type(o?.rat) == 'object') ? o.rat.rat : o?.rat;
	let g = RAT_GEN[rat] ?? FAMILY_GEN[ratmod.RAT[rat]?.family];

	if (g)
		return g;

	let best = -1;

	for (let r in (type(o?.radio_ifs) == 'array' ? o.radio_ifs : []))
		best = max(best, index(GENERATIONS, RADIO_IF_GEN[sprintf('%d', r)]));

	if (best >= 0)
		return GENERATIONS[best];

	let t = lc(sprintf('%s', o?.text ?? ''));

	return match(t, /5g|nr/) ? '5g' : match(t, /lte|4g/) ? '4g' :
		match(t, /umts|wcdma|hspa|hsdpa|hsupa|3g|td-scdma|evdo/) ? '3g' :
		match(t, /gsm|gprs|edge|2g|cdma|1x/) ? '2g' : null;
};

// an LED spec is a name, or { led, weak } with weak = on | blink | off
function spec_led(v)
{
	return (type(v) == 'object') ? v.led : v;
}

function spec_weak(v)
{
	return ((type(v) == 'object') ? v.weak : null) ?? 'on';
}

// what a lit LED shows: steady, or what its `weak` says while the signal is
// at or below the entry's weak_bars. bars 0 is "no measurement", not weak.
function lit(v, s, weak_bars)
{
	let weak = s.bars >= 1 && s.bars <= (weak_bars ?? 0);

	if (!weak)
		return 255;

	let w = spec_weak(v);

	return (w == 'blink') ? 'timer' : (w == 'off') ? 0 : 255;
}

// One LED per technology (2G..5G), plus an optional `signal` LED lit while
// registered and an optional `searching` LED. Covers technology panels
// (Xunison Exigo Hub D50: 4G + 5G), a technology LED next to one signal LED,
// and a single RGB lamp whose channels stand for the technologies (AW1000:
// green = LTE, blue = 5G, red = no service; ddimension/wwand#77).
//
// `cumulative` lights every configured generation up to the current one, so
// 5G lights the 4G LED too ("4G = LTE or NR"). Off, only the current
// generation's LED is lit — required when the LEDs are channels of one lamp,
// where two lit at once is a mixed colour. For the same reason `searching` is
// never lit together with a technology LED: it is on while not registered, and
// those are off then.
function plan_tech(put, l, s)
{
	let cur = index(GENERATIONS, s.gen);
	let reg = !!s.registered;

	for (let i = 0; i < length(GENERATIONS); i++) {
		let v = l.leds[GENERATIONS[i]];

		if (v == null)
			continue;

		let on = reg && cur >= 0 && (l.cumulative ? (i <= cur) : (i == cur));

		put(spec_led(v), on ? lit(v, s, l.weak_bars) : 0);
	}

	if (l.signal != null)
		put(spec_led(l.signal), reg ? lit(l.signal, s, l.weak_bars) : 0);

	// solid without a modem, blinking while it searches — the `mobile`
	// style's red LED, whose behaviour the panels above share
	if (l.searching != null)
		put(l.searching, reg ? 0 : (s.present ? 'timer' : 255));
}

// The on/off channel combinations a colour LED shows; the channels of one
// lamp are separate gpio-leds with max_brightness 1 (AW1000, #77), so there
// is no intensity to mix with.
const COLORS = {
	off:     [ 0, 0, 0 ],
	red:     [ 1, 0, 0 ],
	green:   [ 0, 1, 0 ],
	blue:    [ 0, 0, 1 ],
	yellow:  [ 1, 1, 0 ],
	cyan:    [ 0, 1, 1 ],
	magenta: [ 1, 0, 1 ],
	white:   [ 1, 1, 1 ],
};

const CHANNELS = [ 'red', 'green', 'blue' ];

// `colors[i]` at i + 1 bars, from the weakest up
const DEFAULT_COLORS = [ 'red', 'red', 'yellow', 'green', 'green' ];

// One signal LED that shows the bars as a colour (AW1000's RGB signal lamp; a
// red/green LED leaves `blue` out). Registered with no measurement (0 bars)
// shows the weakest colour rather than dark, which on this lamp reads as
// "off". Not registered shows `searching` — blinking while the modem
// searches, steady without a modem, the way `tech` does it — or nothing.
//
// A blinking colour blinks every channel it uses with its own `timer`
// trigger. They are written in the same tick with the trigger's same default
// delays, so they start together; nothing re-syncs them later.
function plan_signal_color(put, l, s)
{
	let color, blink = false;

	if (s.registered) {
		let cs = l.colors ?? DEFAULT_COLORS;

		color = cs[((s.bars >= 1) ? s.bars : 1) - 1];
	}
	else {
		let sr = l.searching;

		color = (type(sr) == 'object') ? sr.color : (sr ?? 'off');
		blink = s.present && type(sr) == 'object' && sr.blink == true;
	}

	let mix = COLORS[color] ?? COLORS.off;

	for (let i = 0; i < length(CHANNELS); i++)
		if (l[CHANNELS[i]] != null)
			put(l[CHANNELS[i]], mix[i] ? (blink ? 'timer' : 255) : 0);
}

// --- what a board file may say about its LEDs --------------------------------
// Each kind returns null when the value is usable, else what is wrong with it.

function check_spec(v, what)
{
	if (type(v) == 'string')
		return safe_name(v) ? null : sprintf('%s: not an LED name: %J', what, v);

	if (type(v) != 'object')
		return sprintf('%s: must be an LED name or { "led": ..., "weak": ... }', what);

	for (let k in keys(v))
		if (k != 'led' && k != 'weak')
			return sprintf('%s: has no %J', what, k);

	if (!safe_name(v.led))
		return sprintf('%s.led: not an LED name: %J', what, v.led);

	if (v.weak != null && !(v.weak in [ 'on', 'blink', 'off' ]))
		return sprintf('%s.weak: must be on, blink or off, not %J', what, v.weak);

	return null;
}

function color_name(v, what)
{
	return (type(v) == 'string' && COLORS[v] != null) ? null
		: sprintf('%s: not a colour: %J (known: %s)', what, v, join(', ', keys(COLORS)));
}

const LED_KINDS = {
	name: (v, what) => (type(v) == 'string' && safe_name(v)) ? null
		: (type(v) == 'array') ? sprintf('%s: must be one LED name', what)
		: sprintf('%s: not an LED name: %J', what, v),

	// a list where the style takes one LED would become a path built from
	// the stringified array, and the other way round
	list: (v, what) => {
		if (type(v) != 'array')
			return sprintf('%s: must be a list', what);

		if (!length(v))
			return sprintf('%s: empty', what);

		for (let n in v)
			if (!safe_name(n))
				return sprintf('%s: not an LED name: %J', what, n);

		return null;
	},

	bool: (v, what) => (type(v) == 'bool') ? null : sprintf('%s: must be true or false', what),

	bars: (v, what) => (type(v) == 'int' && v >= 0 && v <= 5) ? null
		: sprintf('%s: must be a whole number of bars, 0 to 5', what),

	spec: check_spec,

	techs: (v, what) => {
		if (type(v) != 'object' || !length(v))
			return sprintf('%s: must map %s to LEDs', what, join('/', GENERATIONS));

		for (let k, sv in v) {
			if (!(k in GENERATIONS))
				return sprintf('%s: %J is not one of %s', what, k, join(', ', GENERATIONS));

			let e = check_spec(sv, sprintf('%s.%s', what, k));

			if (e)
				return e;
		}

		return null;
	},

	colors: (v, what) => {
		if (type(v) != 'array' || length(v) != 5)
			return sprintf('%s: must list 5 colours, one per bar', what);

		for (let i = 0; i < 5; i++) {
			let e = color_name(v[i], sprintf('%s[%d]', what, i));

			if (e)
				return e;
		}

		return null;
	},

	color_spec: (v, what) => {
		if (type(v) == 'string')
			return color_name(v, what);

		if (type(v) != 'object')
			return sprintf('%s: must be a colour or { "color": ..., "blink": ... }', what);

		for (let k in keys(v))
			if (k != 'color' && k != 'blink')
				return sprintf('%s: has no %J', what, k);

		if (v.blink != null && type(v.blink) != 'bool')
			return sprintf('%s.blink: must be true or false', what);

		return color_name(v.color, sprintf('%s.color', what));
	},
};

// The LED styles a profile can name. A style is code, a profile only names one
// and its LEDs, which is what lets a board file be plain data. A panel that
// needs another behaviour needs a new style here. `check` is what the key
// types cannot say on their own.
const LED_STYLES = {
	// one LED per signal bar, `names` from the weakest bar up; dark while
	// not registered
	signal_bars: {
		keys: { names: 'list' },
		required: [ 'names' ],
		plan: (put, l, s) => plan_bars(put, l.names, s.registered ? s.bars : 0),
	},
	// red/green(+orange) mobile LED and a tech LED, see plan_mobile
	mobile: {
		keys: { red: 'name', green: 'name', orange: 'name', tech: 'name' },
		required: [ 'red', 'green' ],
		plan: (put, l, s) => plan_mobile(put, l, s),
	},
	// one LED per technology, see plan_tech
	tech: {
		keys: { leds: 'techs', signal: 'spec', searching: 'name',
		        cumulative: 'bool', weak_bars: 'bars' },
		required: [ 'leds' ],
		plan: (put, l, s) => plan_tech(put, l, s),
	},
	// the bars as the colour of one LED, see plan_signal_color
	signal_color: {
		keys: { red: 'name', green: 'name', blue: 'name',
		        colors: 'colors', searching: 'color_spec' },
		required: [],
		check: (l) => {
			if (l.red == null && l.green == null && l.blue == null)
				return 'needs at least one of red, green, blue';

			// one LED on two channels cannot show the colours between them
			let seen = {};

			for (let ch in CHANNELS) {
				if (l[ch] != null && seen[l[ch]] != null)
					return sprintf('%s and %s must name different LEDs', seen[l[ch]], ch);

				if (l[ch] != null)
					seen[l[ch]] = ch;
			}

			// a colour this LED cannot show would quietly show another one
			let used = [ ...(l.colors ?? DEFAULT_COLORS),
			             (type(l.searching) == 'object') ? l.searching.color : l.searching ];

			for (let c in used)
				for (let i = 0; i < length(CHANNELS); i++)
					if (c != null && COLORS[c]?.[i] && l[CHANNELS[i]] == null)
						return sprintf('colour %s needs the %s channel, which this entry does not name',
							c, CHANNELS[i]);

			return null;
		},
		plan: (put, l, s) => plan_signal_color(put, l, s),
	},
};

// `leds` is one style entry or a list of them (a panel with signal bars AND
// technology LEDs is one board file); always a list from here on
function led_entries(leds)
{
	return (leds == null) ? [] : (type(leds) == 'array') ? leds : [ leds ];
}

// --- board profiles ----------------------------------------------------------
// The same shape in this table and in a board file:
// power_gpio           — named GPIO that gates modem USB power (power-cycle
//                        target). value 1 = powered by default.
// power_gpio_active_low— the power line is INVERTED: value 0 = powered, 1 = off.
// reset_gpio           — named GPIO wired to the modem RESET line (board
//                        default; a modem config `reset_gpio` overrides)
// reset_run            — the level (0/1) at which that reset line lets the
//                        modem RUN; see reset_pulse for why it is worth stating
// option_ids           — vendor/product pairs to bind to the usb-serial `option`
//                        driver
// leds                 — { style: <LED_STYLES key>, ...that style's keys }, or a
//                        list of such entries
// note                 — free text, ignored; a board file has no comments
const SIGNAL5 = [ 'green:mobile-1', 'green:mobile-2', 'green:mobile-3',
                  'green:mobile-4', 'green:mobile-5' ];

// The OpenWrt port of the LTE3301-M209/Q222 (one shared dtsi) names its
// gpio-leds by color + function only, so the kernel calls them
// `green:mobile`, `red:mobile`, `green:lte` — the vendor image's `lte3301:`
// prefix is gone (mt7620n_zyxel_lte3301.dtsi, lte3301 fork afab7c890b;
// /sys/class/leds HW-observed on an M209, 2026-10-03). An old name would make
// every write here land in a path that does not exist, silently.
const LTE3301_LEDS = { style: 'mobile', red: 'red:mobile', green: 'green:mobile', tech: 'green:lte' };

const PROFILES = {
	'mikrotik,chateau-5g-r17-ax': {
		power_gpio: 'modem-power',
		reset_gpio: 'modem-reset',
		leds: { style: 'signal_bars', names: SIGNAL5 },
	},
	'zyxel,lte3301-plus': {
		power_gpio: 'power_modem',
		leds: {
			style: 'mobile',
			red: 'lte3301-plus:red:mobile', green: 'lte3301-plus:green:mobile',
			orange: 'lte3301-plus:orange:mobile', tech: 'lte3301-plus:white:lte',
		},
	},
	// The LTE3301 variants bind BOTH serial ids, as the vendor helper did on
	// either board (/usr/sbin/lte3301, vpn2go, Release_2024.10): 1435:d181 and
	// 2020:2033 are the two LTE modules these boards shipped with, and the
	// model id does not say which one a given unit carries.
	'zyxel,lte3301-m209': {
		power_gpio: 'usbpower',
		option_ids: [ '1435 d181', '2020 2033' ],
		leds: LTE3301_LEDS,
	},
	'zyxel,lte3301-q222': {
		power_gpio: 'usbpower',
		option_ids: [ '1435 d181', '2020 2033' ],
		leds: LTE3301_LEDS,
	},
	// Zyxel LTE5398-M904: `lte_power` gates the modem's USB power (wired active-low
	// at HW, but the sysfs gpio applies the inversion, so value 1 = on, default 1).
	// The dedicated modem RESET (gpio-531) is not exported by name in board.json,
	// so recovery power-cycles `lte_power`; a user can still point a per-modem
	// `reset_gpio` at an exported reset line. Three gpio-LED status lights.
	'zyxel,lte5398-m904': {
		power_gpio: 'lte_power',
		leds: { style: 'mobile', red: 'red:lte', green: 'green:lte', orange: 'orange:lte' },
	},
	// nr7101: the RG502Q's RESET line is the named gpio_switch `lte_reset`
	// (board.d: gpio 515, exported at /sys/class/gpio/gpio515). Recovery holds it
	// asserted for RESET_ASSERT_MS (30 s), then releases it: the recovery this
	// board has had in the field since 2022, `/sbin/usb-repower` in the
	// vpn-to-go tree (Release_2024.10, commit b89acd795f), which held the same
	// line (then numbered gpio483) at 1 for 30 s behind netifd-qmi.
	//
	// NO POWER LINE, EVEN WHERE ONE IS EXPORTED. An image can export GPIO 18 as
	// `lte_power` (the ddimension NR7101 image does), and switching it off is
	// not a way back for a modem that has left the bus: on 192.168.203.242
	// (image r0-3ab5204, 2026-09-26) GPIO 18 low for 5 s and for 30 s left the
	// bus empty, and a PoE power cycle brought the modem straight back. With
	// the line in the profile, the vanish step would take it (has_power) instead
	// of the reset. Whether the 30 s reset hold revives a vanished modem is not
	// measured either — a hold on 2026-09-25 did not — which leaves PoE as the
	// only proven remedy. Status LEDs are OS-owned -> none.
	'zyxel,nr7101': {
		reset_gpio: 'gpio515',
		// The level at which the modem RUNS. Measured on the device
		// (2026-09-07): driving gpio515 to 1 disconnects the modem from USB in
		// under 5 s, driving it back to 0 re-enumerates it in about 10 — over
		// several independent transitions. Stating it matters: without
		// `reset_run` the pulse INFERS the rest level from the pin, which is
		// right while the line is at rest and wrong the moment it is not. A
		// pulse issued while the line already sat high therefore asserted 0,
		// released back to 1, and left the modem held down — observed exactly
		// once, in the test that produced this measurement.
		reset_run: 0,
	},
	// Cudy LT300 (MT7628, MeiG SLM770A-R): the modem RESET/power-enable line is
	// exported as the named gpio `4g`. The line is ACTIVE LOW: value 0 runs the
	// modem, 1 holds it down — measured on a v3 on 2026-08-23 (the modem
	// enumerates within seconds of the line going to 0 and disconnects the
	// moment it goes to 1, over several independent pulses). An older comment
	// here claimed the opposite; it did not survive the meter. No separate
	// switchable USB power rail; status LEDs are OS-owned -> none here.
	// The SLM770A's serial (AT) interfaces are vendor-class (0xff) and the stock
	// `option` driver has no id for 2dee:4d57/4d58, so no ttyUSB appear and the
	// NCM backend has no AT channel (modem stays ABSENT). Bind them via new_id.
	// HW-verified on the v3.
	'cudy,lt300-v3': {
		reset_gpio: '4g',
		// the level at which the modem RUNS (see above: active low). Stating it
		// removes the need to infer polarity from the live pin — see
		// reset_pulse for why inferring is unsafe.
		reset_run: 0,
		option_ids: [ '2dee 4d57', '2dee 4d58' ],
	},
	// Huasifei WH3000 Pro (MT7981B Filogic 820; 5G M.2 slot wired to USB). The
	// DTS exports the modem power enable as `modem_power` (pio 4) — INVERTED
	// on this board (field-verified on a WH3000 Pro: value 1 cuts the modem,
	// 0 powers it; the T700 re-enumerates slowly after power-off, give it a
	// minute). init() only drives the line when it reads "off". No modem RESET
	// line and no dedicated modem LEDs (the two board LEDs are the OS status
	// pair). The FM350-GL serials are deliberately NOT in option_ids: the
	// kernel option driver binds them itself (since 4.19.318, ADB excepted)
	// and a blanket new_id would grab ADB and crash-loop the card.
	'huasifei,wh3000-pro-emmc': {
		power_gpio: 'modem_power',
		power_gpio_active_low: true,
	},
	'huasifei,wh3000-pro-nand': {
		power_gpio: 'modem_power',
		power_gpio_active_low: true,
	},
};

// --- board files ---------------------------------------------------------------

const PROFILE_KEYS = {
	power_gpio: true, power_gpio_active_low: true, reset_gpio: true,
	reset_run: true, option_ids: true, leds: true, note: true,
};

// Check a profile from a board file. Returns null when it is usable, else the
// first thing wrong with it, as text for the log.
//
// ALL OR NOTHING, and an unknown key is an error. A board file is read by a
// daemon that switches the modem's power: a misspelt `power_gpio_active_low`
// that was skipped would leave a correct-looking profile with the polarity
// reversed, and the first recovery would switch the modem off for good. So a
// file is taken whole or not at all, and the log says why.
export function validate_profile(p)
{
	if (type(p) != 'object')
		return 'not a JSON object';

	for (let k in keys(p))
		if (!PROFILE_KEYS[k])
			return sprintf('unknown key %J', k);

	for (let k in [ 'power_gpio', 'reset_gpio' ])
		if (p[k] != null && !safe_name(p[k]))
			return sprintf('%s: not a GPIO name: %J', k, p[k]);

	if (p.power_gpio_active_low != null && type(p.power_gpio_active_low) != 'bool')
		return 'power_gpio_active_low: must be true or false';

	if (p.reset_run != null && p.reset_run !== 0 && p.reset_run !== 1)
		return 'reset_run: must be 0 or 1';

	if (p.option_ids != null) {
		if (type(p.option_ids) != 'array')
			return 'option_ids: must be a list';

		for (let i in p.option_ids)
			if (type(i) != 'string' || !match(i, /^[0-9A-Fa-f]{4} [0-9A-Fa-f]{4}$/))
				return sprintf('option_ids: not "vvvv pppp": %J', i);
	}

	if (p.note != null && type(p.note) != 'string')
		return 'note: must be text';

	if (p.leds != null) {
		if (type(p.leds) == 'array' && !length(p.leds))
			return 'leds: empty';

		let entries = led_entries(p.leds);

		for (let n = 0; n < length(entries); n++) {
			let l = entries[n];
			let at = (type(p.leds) == 'array') ? sprintf('leds[%d]', n) : 'leds';
			let st = (type(l) == 'object') ? LED_STYLES[l.style] : null;

			if (!st)
				return sprintf('%s: unknown style %J (known: %s)', at, l?.style,
					join(', ', sort(keys(LED_STYLES))));

			for (let k in keys(l)) {
				if (k == 'style')
					continue;

				if (!st.keys[k])
					return sprintf('%s: style %s has no %J', at, l.style, k);

				let e = LED_KINDS[st.keys[k]](l[k], sprintf('%s.%s', at, k));

				if (e)
					return e;
			}

			// a style without the LEDs it drives would validate and then light
			// nothing, which looks exactly like a board with dead LEDs
			for (let k in st.required)
				if (l[k] == null)
					return sprintf('%s.%s: missing for style %s', at, k, l.style);

			let e = st.check?.(l);

			if (e)
				return sprintf('%s: %s', at, e);
		}
	}

	return null;
};

// The profile for a board id: a board file if one exists (the last directory
// in BOARD_DIRS wins), else the built-in entry. Returns { profile, source },
// source being the file's path or 'builtin', or null for neither.
//
// The winning file decides alone. One that does not validate is logged and
// the built-in entry (or none) applies; a file in an earlier directory is NOT
// consulted then. An admin's /etc file exists to replace the packaged one, so
// a typo in it must not quietly bring back exactly what it was there to
// replace.
export function load_profile(fx, id, log, dirs)
{
	if (id == null)
		return null;

	// the id names the file, so it must not be able to name anything else
	if (type(id) == 'string' && match(id, /^[A-Za-z0-9,._+-]+$/) && index(id, '..') < 0) {
		for (let d in reverse([ ...(dirs ?? BOARD_DIRS) ])) {
			let path = sprintf('%s/%s.json', d, id);
			let raw = fx.read(path);

			if (raw == null)
				continue;

			let p = null, why = null;

			try {
				p = json(raw);
			}
			catch (e) {
				why = 'not valid JSON';
			}

			why ??= validate_profile(p);

			if (why == null)
				return { profile: p, source: path };

			log?.('err', sprintf('board %s: ignoring %s: %s', id, path, why));
			break;
		}
	}

	return PROFILES[id] ? { profile: PROFILES[id], source: 'builtin' } : null;
};

// --- instance ----------------------------------------------------------------

export function create(opts)
{
	let fx = opts?.fx ?? default_fx();
	let log = opts?.log ?? ((level, msg) => warn(sprintf('%s: %s\n', level, msg)));
	let id = opts?.id ?? detect_id(fx);
	let found = load_profile(fx, id, log, opts?.dirs);
	let profile = found?.profile;

	if (found && found.source != 'builtin')
		log('notice', sprintf('board %s: profile from %s', id, found.source));
	// in-flight reset pulse (see reset_pulse): one at a time, and the guard is
	// what keeps a concurrent caller from sampling a driven line
	let pulse_timer = null;
	// timings are injectable so tests can drive the deferred halves quickly
	let power_off_ms = opts?.power_off_ms ?? POWER_OFF_MS;
	let reset_ms = opts?.reset_ms ?? RESET_ASSERT_MS;
	// polarity of the modem power line (inverted boards power with 0)
	let power_on = profile?.power_gpio_active_low ? '0' : '1';
	let power_off = profile?.power_gpio_active_low ? '1' : '0';

	// GPIO names are interpolated into sysfs paths, and a per-modem
	// `reset_gpio` comes from uci — restrict to a safe token (no slash, no
	// '..') so a hostile config value can never escape /sys/class/gpio.
	let safe_gpio = (name) => {
		if (safe_name(name))
			return true;

		log('err', sprintf('board: rejecting invalid gpio name %J', name));
		return false;
	};

	let gpio_read = (name) =>
		safe_gpio(name) ? fx.read(sprintf('%s/%s/value', GPIO_DIR, name)) : null;

	// Returns whether the LINE ACTUALLY MOVED. Both callers below decide from
	// it, and they must: a `false` sends the recovery ladder on to the next
	// rung, while a `true` that wrote nothing consumes the hardware rung
	// without touching the hardware, and the box then waits for the reboot rung
	// far above it. A line that does not exist, a read-only sysfs and a name the
	// profile has wrong all land here.
	//
	// Only the VALUE write decides. `direction` is best-effort on purpose: a
	// GPIO already claimed as an output (or exported by a driver) can refuse it
	// while the value write works fine.
	let gpio_set = (name, v) => {
		if (!safe_gpio(name))
			return false;

		fx.write(sprintf('%s/%s/direction', GPIO_DIR, name), 'out');

		if (fx.write(sprintf('%s/%s/value', GPIO_DIR, name), v ? '1' : '0'))
			return true;

		log('err', sprintf('board %s: gpio %s: could not write value', id ?? '?', name));
		return false;
	};

	let self = {
		id: id,
		profile: profile,
		// where the profile came from: a board file's path, 'builtin', or null
		profile_source: found?.source,
		has_power: profile?.power_gpio != null,
		// expose the signal->bars mapping so callers building an LED state don't
		// need to import the module function separately
		bars: bars_from_signal,
		generation: generation,
	};

	// one-time bring-up: ensure the modem is powered and bind any board-specific
	// usb-serial ids. Safe to call repeatedly.
	self.init = function() {
		if (!profile)
			return;

		if (profile.power_gpio) {
			// only assert power if currently off, so we never gratuitously
			// power-cycle a working modem on a daemon restart
			if (gpio_read(profile.power_gpio) == power_off) {
				log('notice', sprintf('board %s: powering modem on (gpio %s)', id, profile.power_gpio));
				gpio_set(profile.power_gpio, power_on == '1');
			}
		}

		for (let ids in (profile.option_ids ?? []))
			fx.write('/sys/module/option/drivers/usb-serial:option1/new_id', ids);
	};

	// power-cycle the board's modem USB power: off, then on after a delay. Used
	// by the recovery ladder to recover a hung / vanished modem. Returns true if
	// a power GPIO exists (i.e. the cycle was initiated).
	// `off_ms` optionally overrides the off duration (config `repower_time`).
	self.power_cycle = function(off_ms) {
		if (!profile?.power_gpio)
			return false;

		let off = (off_ms > 0) ? off_ms : power_off_ms;

		log('err', sprintf('board %s: power-cycling modem (gpio %s, off %ds)',
			id, profile.power_gpio, off / 1000));

		// nothing was switched off -> report it, so the caller can try something
		// else rather than wait out a power cycle that is not happening
		if (!gpio_set(profile.power_gpio, power_off == '1'))
			return false;

		uloop.timer(off, () => {
			// A failure HERE is the dangerous one: the modem is off and stays
			// off. Nothing here can fix it, but it must be in the log, or the
			// box looks like a dead modem instead of a board we switched off.
			if (!gpio_set(profile.power_gpio, power_on == '1'))
				log('err', sprintf('board %s: gpio %s: MODEM LEFT POWERED OFF — the power-on write failed',
					id, profile.power_gpio));
		});

		return true;
	};

	// assert a modem RESET line for RESET_ASSERT_MS then restore it. `name` is a
	// per-modem `reset_gpio` (config) or the board default. Returns true if a
	// usable reset GPIO was found.
	// `hold_ms` optionally overrides the assert duration (config `repower_time`).
	//
	// Two things here are load-bearing, both learned the hard way on a Cudy
	// LT300 whose modem stayed dead until the box was power-cycled:
	//
	//  - ONE pulse at a time. A second call while a pulse is in flight used to
	//    start its own assert/release pair. Its release landed ~7 s after the
	//    first one, on an already-recovered modem, and put it straight back
	//    down. Overlapping callers are real: the recovery ladder, the ubus
	//    modem_reset/modem_repower methods and the LuCI button all land here,
	//    and a second click while nothing visibly happens is the normal human
	//    reaction to a 30 s pulse.
	//
	//  - NEVER infer the resting level from the live pin while it may be
	//    driven. Sampling an asserted line reads the ASSERTED level as the
	//    resting one, so the pulse inverts: its "release" drives the modem
	//    down and leaves it there, and every later pulse inherits the
	//    inversion (modem up for the hold, down forever after). A profile that
	//    knows its wiring says so in `reset_run` — the level at which the
	//    modem runs — and the pin is not consulted at all. Sampling stays the
	//    fallback for boards whose polarity nobody has measured.
	self.reset_pulse = function(name, hold_ms) {
		let g = name ?? profile?.reset_gpio;

		// reject an invalid (config-supplied) name up front so the caller sees
		// false and the recovery ladder can fall through to the next rung
		if (!g || !safe_gpio(g))
			return false;

		if (pulse_timer) {
			log('notice', sprintf('board %s: modem reset already in progress (gpio %s), ignoring',
				id ?? '?', g));
			return true;
		}

		let hold = (hold_ms > 0) ? hold_ms : reset_ms;

		// `reset_run` DESCRIBES THE BOARD'S OWN RESET LINE and nothing else. A
		// modem config `reset_gpio` names a different pin, whose polarity the
		// profile knows nothing about — applying the measured rest level of
		// one line to another inverts it when they disagree, so the "release"
		// at the end of the pulse drove the modem into permanent reset, and
		// the pin-sampling fallback that would have got it right was skipped
		// precisely because the board HAD a measurement.
		let own = (sprintf('%s', g) == sprintf('%s', profile?.reset_gpio ?? ''));
		let run = own ? profile?.reset_run : null;

		if (run == null) {
			// unmeasured board, or a pin the profile does not describe: fall
			// back to the line itself. Safe here because no pulse is in flight
			// (guarded above), so it is at rest.
			let cur = gpio_read(g);
			// default the "rest" level to high (1) when we cannot read it
			run = (cur == '0') ? 0 : 1;
		}

		log('err', sprintf('board %s: asserting modem reset (gpio %s) for %ds',
			id ?? '?', g, hold / 1000));
		// the assert has to land before we claim a reset is under way: arming the
		// release timer for a line that never moved would report a reset, hold
		// the single-pulse latch for its duration, and reset nothing
		if (!gpio_set(g, run ? 0 : 1))
			return false;

		pulse_timer = uloop.timer(hold, () => {
			pulse_timer = null;

			// a release that fails leaves the modem held in reset — it cannot be
			// fixed from here, but it must not be silent
			if (gpio_set(g, run))
				log('notice', sprintf('board %s: modem reset released (gpio %s)', id ?? '?', g));
			else
				log('err', sprintf('board %s: gpio %s: MODEM LEFT IN RESET — the release write failed',
					id ?? '?', g));
		});

		return true;
	};

	// what each LED was last set to, so an unchanged one is not written again
	// (a re-written `timer` restarts the blink; see the planning note above).
	// Only a write that landed is remembered, and only while sysfs still shows
	// it: something else switching the LED (an LED trigger in /etc/config/
	// system, a user's echo) is undone on the next tick, as before the cache.
	let led_last = {};

	// render the status LEDs from a normalized modem state:
	//   { present, registered, radio, lte, gen, roaming, bars }
	// Every entry plans; one LED that two entries name is lit if either
	// lights it (steady over blinking over off), then each LED is written once.
	self.leds = function(state) {
		let want = {};
		let rank = (v) => (v == 'timer') ? 1 : v ? 2 : 0;
		let put = (name, val) => {
			if (name != null && (want[name] == null || rank(val) > rank(want[name])))
				want[name] = val;
		};

		for (let l in led_entries(profile?.leds))
			LED_STYLES[l?.style]?.plan(put, l, state ?? {});

		for (let name, val in want) {
			if (led_last[name] === val && led_shows(fx, name, val))
				continue;

			if (set_led(fx, name, val))
				led_last[name] = val;
			else
				delete led_last[name];
		}
	};

	return self;
};
