// wwand — board abstraction: modem power / reset GPIOs, status LEDs.
//
// Absorbs the board-specific bits that used to live in vendor helper scripts
// (e.g. Zyxel's /usr/sbin/lte3301): powering the modem, power-cycling a hung or
// vanished modem for the recovery ladder, and driving the mobile/LTE/signal LEDs
// from the modem's registration + signal.
//
// A profile is selected from /etc/board.json's model id. An unknown board yields
// a null profile — every operation is then a safe no-op, so the daemon runs
// unchanged on hardware we don't have a profile for. All sysfs access goes
// through an injectable fx (read/write/list) so the whole module is host-testable.

'use strict';

import * as fs from 'fs';
import * as uloop from 'uloop';

const GPIO_DIR = '/sys/class/gpio';
const LED_DIR = '/sys/class/leds';
// how long a power-cycle keeps the modem powered off / a reset GPIO stays asserted
const POWER_OFF_MS = 3000;
const RESET_ASSERT_MS = 30000;   // per spec: invert, wait 30 s, restore

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
	};
}

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
}

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
}

// --- LED rendering helpers (shared by the profiles) --------------------------

// a status LED value is either an integer brightness (0 = off, else on) or a
// trigger name string (e.g. 'timer' to blink). set_led applies whichever.
function set_led(fx, name, val)
{
	if (name == null)
		return;

	let base = sprintf('%s/%s', LED_DIR, name);

	if (type(val) == 'string') {
		fx.write(sprintf('%s/trigger', base), val);
	}
	else {
		// take manual control, then set brightness (max_brightness would be more
		// correct, but 255 is clamped by the LED core and every panel accepts it)
		fx.write(sprintf('%s/trigger', base), 'none');
		fx.write(sprintf('%s/brightness', base), val ? '255' : '0');
	}
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

	let rsrp = pick(sig.nr5g?.rsrp, sig.lte?.rsrp);

	if (rsrp != null)
		return (rsrp >= -80) ? 5 : (rsrp >= -90) ? 4 : (rsrp >= -100) ? 3 :
		       (rsrp >= -110) ? 2 : 1;

	let rssi = pick(sig.lte?.rssi, sig.gsm_rssi, sig.wcdma?.rssi);

	if (rssi != null)
		return (rssi >= -65) ? 5 : (rssi >= -75) ? 4 : (rssi >= -85) ? 3 :
		       (rssi >= -95) ? 2 : 1;

	return 0;
}

// light `n` of the given LED list, rest off (bar-graph signal indicator)
function render_bars(fx, leds, n)
{
	for (let i = 0; i < length(leds); i++)
		set_led(fx, leds[i], (i < n) ? 255 : 0);
}

// the classic red/green(+orange) mobile + tech LED set (Zyxel LTE33xx)
function render_mobile(fx, m, s)
{
	// green solid when registered; red blinks while searching, off once up;
	// orange (if present) marks roaming
	set_led(fx, m.green, s.registered ? 255 : 0);
	set_led(fx, m.red, s.registered ? 0 : (s.present ? 'timer' : 255));
	if (m.orange != null)
		set_led(fx, m.orange, s.roaming ? 255 : 0);
	// the tech LED lights once attached (any RAT)
	if (m.tech != null)
		set_led(fx, m.tech, (s.registered && s.radio != null) ? 255 : 0);
}

// --- board profiles ----------------------------------------------------------
// power_gpio  — named GPIO that gates modem USB power (power-cycle target)
// reset_gpio  — named GPIO wired to the modem RESET line (board default; a modem
//               config `reset_gpio` overrides per modem)
// option_ids  — vendor/product pairs to bind to the usb-serial `option` driver
// leds(fx, s) — render the panel from the modem state s
const SIGNAL5 = [ 'green:mobile-1', 'green:mobile-2', 'green:mobile-3',
                  'green:mobile-4', 'green:mobile-5' ];

const PROFILES = {
	'mikrotik,chateau-5g-r17-ax': {
		power_gpio: 'modem-power',
		reset_gpio: 'modem-reset',
		leds: (fx, s) => render_bars(fx, SIGNAL5, s.registered ? s.bars : 0),
	},
	'zyxel,lte3301-plus': {
		power_gpio: 'power_modem',
		leds: (fx, s) => render_mobile(fx, {
			red: 'lte3301-plus:red:mobile', green: 'lte3301-plus:green:mobile',
			orange: 'lte3301-plus:orange:mobile', tech: 'lte3301-plus:white:lte',
		}, s),
	},
	'zyxel,lte3301-m209': {
		power_gpio: 'usbpower',
		option_ids: [ '2020 2033' ],
		leds: (fx, s) => render_mobile(fx, {
			red: 'lte3301:red:mobile', green: 'lte3301:green:mobile',
			tech: 'lte3301:green:lte',
		}, s),
	},
	'zyxel,lte3301-q222': {
		power_gpio: 'usbpower',
		option_ids: [ '1435 d181' ],
		leds: (fx, s) => render_mobile(fx, {
			red: 'lte3301:red:mobile', green: 'lte3301:green:mobile',
			tech: 'lte3301:green:lte',
		}, s),
	},
	// nr7101: no modem-power GPIO and only shared system LEDs (owned by the OS) —
	// a deliberately empty profile (detected, but every op a no-op).
	'zyxel,nr7101': {},
};

// --- instance ----------------------------------------------------------------

export function create(opts)
{
	let fx = opts?.fx ?? default_fx();
	let log = opts?.log ?? ((level, msg) => warn(sprintf('%s: %s\n', level, msg)));
	let id = opts?.id ?? detect_id(fx);
	let profile = (id != null) ? PROFILES[id] : null;
	// timings are injectable so tests can drive the deferred halves quickly
	let power_off_ms = opts?.power_off_ms ?? POWER_OFF_MS;
	let reset_ms = opts?.reset_ms ?? RESET_ASSERT_MS;

	let gpio_read = (name) => fx.read(sprintf('%s/%s/value', GPIO_DIR, name));

	let gpio_set = (name, v) => {
		fx.write(sprintf('%s/%s/direction', GPIO_DIR, name), 'out');
		fx.write(sprintf('%s/%s/value', GPIO_DIR, name), v ? '1' : '0');
	};

	let self = {
		id: id,
		profile: profile,
		has_power: profile?.power_gpio != null,
		// expose the signal->bars mapping so callers building an LED state don't
		// need to import the module function separately
		bars: bars_from_signal,
	};

	// one-time bring-up: ensure the modem is powered and bind any board-specific
	// usb-serial ids. Safe to call repeatedly.
	self.init = function() {
		if (!profile)
			return;

		if (profile.power_gpio) {
			// only assert power if currently off, so we never gratuitously
			// power-cycle a working modem on a daemon restart
			if (gpio_read(profile.power_gpio) == '0') {
				log('notice', sprintf('board %s: powering modem on (gpio %s)', id, profile.power_gpio));
				gpio_set(profile.power_gpio, 1);
			}
		}

		for (let ids in (profile.option_ids ?? []))
			fx.write('/sys/module/option/drivers/usb-serial:option1/new_id', ids);
	};

	// power-cycle the board's modem USB power: off, then on after a delay. Used
	// by the recovery ladder to recover a hung / vanished modem. Returns true if
	// a power GPIO exists (i.e. the cycle was initiated).
	self.power_cycle = function() {
		if (!profile?.power_gpio)
			return false;

		log('err', sprintf('board %s: power-cycling modem (gpio %s)', id, profile.power_gpio));
		gpio_set(profile.power_gpio, 0);
		uloop.timer(power_off_ms, () => gpio_set(profile.power_gpio, 1));

		return true;
	};

	// assert a modem RESET line for RESET_ASSERT_MS then restore it. `name` is a
	// per-modem `reset_gpio` (config) or the board default. Per spec: read the
	// current level, drive the inverse, wait 30 s, drive the original back.
	// Returns true if a usable reset GPIO was found.
	self.reset_pulse = function(name) {
		let g = name ?? profile?.reset_gpio;

		if (!g)
			return false;

		let cur = gpio_read(g);
		// default the "rest" level to high (1) when we cannot read it
		let rest = (cur == '0') ? 0 : 1;

		log('err', sprintf('board %s: asserting modem reset (gpio %s) for %ds',
			id ?? '?', g, RESET_ASSERT_MS / 1000));
		gpio_set(g, rest ? 0 : 1);
		uloop.timer(reset_ms, () => {
			gpio_set(g, rest);
			log('notice', sprintf('board %s: modem reset released (gpio %s)', id ?? '?', g));
		});

		return true;
	};

	// render the status LEDs from a normalized modem state:
	//   { present, registered, radio, roaming, bars }
	self.leds = function(state) {
		if (profile?.leds)
			profile.leds(fx, state ?? {});
	};

	return self;
}
