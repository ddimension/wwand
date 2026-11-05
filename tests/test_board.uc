// wwand tests — board abstraction (board.uc): model detection, named-GPIO
// enumeration, modem power-cycle + reset-pulse (incl. the deferred restore), and
// status-LED rendering per board profile. sysfs is faked via a recording fx.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as board from 'wwand/board.uc';

uloop.init();

// `fail` marks paths whose write reports failure, the way fs.open() does for a
// line that does not exist or a read-only sysfs.
function mkfx(files, dirs, fail) {
	let writes = [];
	return {
		writes: writes,
		read: (p) => files[p],
		write: (p, v) => {
			push(writes, sprintf('%s=%s', p, v));

			if (fail?.[p])
				return false;

			files[p] = v;
			return true;
		},
		list: (p) => dirs?.[p] ?? [],
		has: function(s) { for (let w in writes) if (w == s) return true; return false; },
	};
}

const G = '/sys/class/gpio';
const L = '/sys/class/leds';

// --- 1. board detection from /etc/board.json ---------------------------------
// pretty-printed, tab-indented layout as OpenWrt actually writes it
let fx = mkfx({ '/etc/board.json':
	'{\n\t"model": {\n\t\t"id": "mikrotik,chateau-5g-r17-ax",\n\t\t"name": "MikroTik Chateau"\n\t},\n\t"led": {}\n}' });
eq(board.detect_id(fx), 'mikrotik,chateau-5g-r17-ax', 'detect: model id from pretty-printed board.json');
eq(board.detect_id(mkfx({})), null, 'detect: no board.json -> null');

// --- 2. named-GPIO enumeration (for the LuCI picker) -------------------------
fx = mkfx({}, { [G]: [ 'export', 'unexport', 'gpiochip512', 'gpio577',
                       'modem-power', 'modem-reset' ] });
let gpios = board.list_named_gpios(fx);
eq(join(',', gpios), 'modem-power,modem-reset', 'gpios: only named lines, sorted');

// --- 3. Chateau profile: power + reset + signal-bar LEDs ----------------------
fx = mkfx({ [`${G}/modem-power/value`]: '1', [`${G}/modem-reset/value`]: '1' });
let b = board.create({ id: 'mikrotik,chateau-5g-r17-ax', fx: fx,
                       power_off_ms: 5, reset_ms: 5, log: () => {} });
ok(b.has_power, 'chateau: has power gpio');

// power-cycle: immediate off, then on after the (short) delay
ok(b.power_cycle(), 'power_cycle returns true (power gpio present)');
ok(fx.has(`${G}/modem-power/value=0`), 'power_cycle: powered off immediately');

// reset pulse on the board default reset gpio: inverted now (1 -> 0)
ok(b.reset_pulse(), 'reset_pulse returns true (board reset gpio)');
ok(fx.has(`${G}/modem-reset/value=0`), 'reset_pulse: asserted inverted level');

// drive the deferred halves (restore) via uloop
uloop.timer(40, () => uloop.end());
uloop.run();
ok(fx.has(`${G}/modem-power/value=1`), 'power_cycle: powered back on after delay');
ok(fx.has(`${G}/modem-reset/value=1`), 'reset_pulse: released back to rest level');

// signal LEDs: registered with 3 bars -> mobile-1..3 on, 4..5 off
fx = mkfx({});
b = board.create({ id: 'mikrotik,chateau-5g-r17-ax', fx: fx, log: () => {} });
b.leds({ present: true, registered: true, radio: 'nr5g', bars: 3 });
ok(fx.has(`${L}/green:mobile-3/brightness=255`), 'leds: bar 3 lit');
ok(fx.has(`${L}/green:mobile-5/brightness=0`), 'leds: bar 5 dark');

// not registered -> all bars off
fx = mkfx({});
b = board.create({ id: 'mikrotik,chateau-5g-r17-ax', fx: fx, log: () => {} });
b.leds({ present: true, registered: false, bars: 5 });
ok(fx.has(`${L}/green:mobile-1/brightness=0`), 'leds: unregistered -> bars off');

// --- 4. lte3301-plus profile: mobile + LTE LEDs, per-modem reset gpio ---------
fx = mkfx({ [`${G}/power_modem/value`]: '1' });
b = board.create({ id: 'zyxel,lte3301-plus', fx: fx, log: () => {} });
b.leds({ present: true, registered: true, radio: 'lte', roaming: false });
ok(fx.has(`${L}/lte3301-plus:green:mobile/brightness=255`), 'lte3301: green mobile on when registered');
ok(fx.has(`${L}/lte3301-plus:red:mobile/brightness=0`), 'lte3301: red mobile off when registered');
ok(fx.has(`${L}/lte3301-plus:white:lte/brightness=255`), 'lte3301: LTE led on when attached');

// ...but only on LTE: a box that fell back to 3G keeps the LTE led dark, as
// the vendor helper's `grep lte` did
fx = mkfx({});
b = board.create({ id: 'zyxel,lte3301-plus', fx: fx, log: () => {} });
b.leds({ present: true, registered: true, radio: 5, lte: false });
ok(fx.has(`${L}/lte3301-plus:white:lte/brightness=0`), 'lte3301: LTE led off on 3G');
ok(fx.has(`${L}/lte3301-plus:green:mobile/brightness=255`), 'lte3301: ...while green still says registered');

// both LTE3301 variants: usbpower switched on when off, both modem ids bound,
// the OpenWrt port's LED names: color:function, no board prefix
for (let v in [ 'zyxel,lte3301-m209', 'zyxel,lte3301-q222' ]) {
	fx = mkfx({ [`${G}/usbpower/value`]: '0' });
	b = board.create({ id: v, fx: fx, log: () => {} });
	b.init();
	ok(fx.has(`${G}/usbpower/value=1`), sprintf('%s: usbpower switched on', v));
	ok(fx.has('/sys/module/option/drivers/usb-serial:option1/new_id=1435 d181') &&
	   fx.has('/sys/module/option/drivers/usb-serial:option1/new_id=2020 2033'),
		sprintf('%s: both modem ids bound to option', v));
	b.leds({ present: true, registered: true, radio: 8, lte: true });
	ok(fx.has(`${L}/green:mobile/brightness=255`) && fx.has(`${L}/green:lte/brightness=255`) &&
	   fx.has(`${L}/red:mobile/brightness=0`),
		sprintf('%s: green mobile + LTE led on LTE', v));
}

// searching (present, not registered) -> red blinks via the timer trigger
fx = mkfx({});
b = board.create({ id: 'zyxel,lte3301-plus', fx: fx, log: () => {} });
b.leds({ present: true, registered: false });
ok(fx.has(`${L}/lte3301-plus:red:mobile/trigger=timer`), 'lte3301: red blinks while searching');

// a per-modem reset gpio overrides the (absent) board default
fx = mkfx({ [`${G}/mygpio/value`]: '0' });
b = board.create({ id: 'zyxel,lte3301-plus', fx: fx, reset_ms: 5, log: () => {} });
ok(b.reset_pulse('mygpio'), 'reset_pulse: per-modem gpio accepted');
ok(fx.has(`${G}/mygpio/value=1`), 'reset_pulse: inverted from 0 to 1');

// --- 4b. Zyxel LTE5398-M904: lte_power power-cycle + :lte status LEDs ---------
fx = mkfx({ [`${G}/lte_power/value`]: '1' });
b = board.create({ id: 'zyxel,lte5398-m904', fx: fx, power_off_ms: 5, log: () => {} });
ok(b.has_power, 'lte5398: has power gpio (lte_power)');
ok(b.power_cycle(), 'lte5398: power_cycle returns true');
ok(fx.has(`${G}/lte_power/value=0`), 'lte5398: powered off via lte_power');

fx = mkfx({});
b = board.create({ id: 'zyxel,lte5398-m904', fx: fx, log: () => {} });
b.leds({ present: true, registered: true, radio: 'lte', roaming: false });
ok(fx.has(`${L}/green:lte/brightness=255`), 'lte5398: green:lte on when registered');
ok(fx.has(`${L}/red:lte/brightness=0`), 'lte5398: red:lte off when registered');
ok(fx.has(`${L}/orange:lte/brightness=0`), 'lte5398: orange:lte off when not roaming');

// --- 4c. Zyxel NR7101: no power rail, RESET via the named gpio515 (lte_reset) --
// The board has no switchable modem-power GPIO, but exposes the RG502Q reset as
// gpio515 -> the recovery ladder must be able to pulse it (instead of rebooting).
fx = mkfx({ [`${G}/gpio515/value`]: '0' });
b = board.create({ id: 'zyxel,nr7101', fx: fx, reset_ms: 5, log: () => {} });
ok(!b.has_power, 'nr7101: no modem-power rail');
eq(b.power_cycle(), false, 'nr7101: power_cycle no-op (no power gpio)');
ok(b.reset_pulse(), 'nr7101: reset_pulse uses the board default reset gpio (gpio515)');
ok(fx.has(`${G}/gpio515/value=1`), 'nr7101: reset asserted (0 -> 1) on gpio515');

uloop.timer(20, () => uloop.end());
uloop.run();
ok(fx.has(`${G}/gpio515/value=0`), 'nr7101: reset released back to rest level (0)');

// A PER-MODEM reset_gpio IS NOT THE BOARD'S RESET LINE, and reset_run describes
// only the latter. Applying the board's measured rest level to a pin the
// profile knows nothing about inverts it when the two disagree: the assert
// wrote the OTHER pin's rest level (so nothing reset) and the release drove it
// into permanent reset — and the pin-sampling fallback that would have got it
// right was skipped precisely because the board HAD a measurement. Here the
// nr7101 profile says reset_run 0 while the named pin rests at 1. Found by a
// full review, 2026-09-19.
fx = mkfx({ [`${G}/othergpio/value`]: '1' });
b = board.create({ id: 'zyxel,nr7101', fx: fx, reset_ms: 5, log: () => {} });
ok(b.reset_pulse('othergpio'), 'nr7101: a per-modem reset gpio is accepted');
ok(fx.has(`${G}/othergpio/value=0`),
	'nr7101: asserted against THAT pin\'s rest level (1 -> 0), not the board\'s');
uloop.timer(20, () => uloop.end());
uloop.run();
ok(fx.has(`${G}/othergpio/value=1`),
	'nr7101: released back to 1 — not left holding the modem in reset');

// --- 4d. NR7101 with GPIO 18 exported as `lte_power` ---------------------------
// The line is not a way back for a modem that left the bus (switched off 5 s and
// 30 s on 192.168.203.242, 2026-09-26: bus stayed empty; PoE revived it), so the
// profile does not use it even where the image exports it: recovery must reach
// the 30 s reset hold, which it would not with has_power set.
fx = mkfx({ [`${G}/gpio515/value`]: '0', [`${G}/lte_power/value`]: '1' });
b = board.create({ id: 'zyxel,nr7101', fx: fx, reset_ms: 5, log: () => {} });
ok(!b.has_power, 'nr7101+lte_power: the exported line is not taken as power control');
eq(b.power_cycle(), false, 'nr7101+lte_power: power_cycle stays a no-op');
ok(!fx.has(`${G}/lte_power/value=0`), 'nr7101+lte_power: the line is never switched off');
ok(b.reset_pulse(), 'nr7101+lte_power: recovery is the reset hold');
ok(fx.has(`${G}/gpio515/value=1`), 'nr7101+lte_power: ...asserting gpio515');

// --- 4d. Cudy LT300 (MeiG SLM770A): serial ports are vendor-class (0xff) and the
// stock `option` driver has no id for them, so init() must bind them via new_id —
// otherwise no ttyUSB appear and the NCM backend has no AT channel (modem ABSENT).
fx = mkfx({});
b = board.create({ id: 'cudy,lt300-v3', fx: fx, log: () => {} });
b.init();
let NEWID = '/sys/module/option/drivers/usb-serial:option1/new_id';
ok(fx.has(`${NEWID}=2dee 4d58`), 'cudy: binds SLM770A 2dee:4d58 to the option driver via new_id');
ok(fx.has(`${NEWID}=2dee 4d57`), 'cudy: binds the 2dee:4d57 variant too');

// --- 4f. Huasifei WH3000 Pro: modem_power gpio, INVERTED (field-verified:
// 1 = modem off, 0 = on). init() must only drive the line when it reads
// "off"; the recovery ladder power-cycles with the inverted levels. NO
// option_ids: the kernel option driver binds the FM350-GL serials itself
// (since 4.19.318, ADB excepted) and a blanket new_id would grab ADB and
// crash-loop the card (forum-observed).
fx = mkfx({ [`${G}/modem_power/value`]: '1' });
b = board.create({ id: 'huasifei,wh3000-pro-emmc', fx: fx, log: () => {} });
ok(b.has_power, 'wh3000-pro: has power gpio (modem_power)');
b.init();
ok(fx.has(`${G}/modem_power/value=0`), 'wh3000-pro: init powers on (reads 1 -> sets 0)');
ok(!fx.has(`${NEWID}=0e8d 7127`) && !fx.has(`${NEWID}=0e8d 7126`),
	'wh3000-pro: no blanket new_id for the FM350-GL (ADB crash-loop risk)');

// already-on line (0): init must not touch it
fx = mkfx({ [`${G}/modem_power/value`]: '0' });
b = board.create({ id: 'huasifei,wh3000-pro-emmc', fx: fx, log: () => {} });
b.init();
ok(!fx.has(`${G}/modem_power/direction`), 'wh3000-pro: on-line init leaves the gpio alone');

fx = mkfx({});
b = board.create({ id: 'huasifei,wh3000-pro-nand', fx: fx, power_off_ms: 5, log: () => {} });
ok(b.power_cycle(), 'wh3000-pro-nand: power_cycle returns true');
ok(fx.has(`${G}/modem_power/value=1`), 'wh3000-pro-nand: powered off with value 1 (inverted)');
uloop.timer(20, () => uloop.end());
uloop.run();
ok(fx.has(`${G}/modem_power/value=0`), 'wh3000-pro-nand: powered back on with value 0 (inverted)');

// --- 4e. GPIO name sanitizer: a config-supplied reset_gpio is interpolated into
// a sysfs path — hostile values (slash, '..', oversized) must be rejected, never
// written. reset_pulse takes the per-modem uci value directly, so drive it there.
fx = mkfx({});
b = board.create({ id: 'cudy,lt300-v3', fx: fx, reset_ms: 5, log: () => {} });
eq(b.reset_pulse('../../class/leds/evil'), false, 'sanitize: path traversal name rejected');
eq(b.reset_pulse('..'), false, 'sanitize: bare .. rejected');
eq(b.reset_pulse('a/b'), false, 'sanitize: slash rejected');
eq(length(fx.writes), 0, 'sanitize: nothing written to sysfs for bad names');
ok(b.reset_pulse('gpio7'), 'sanitize: clean name still accepted');
ok(fx.has(`${G}/gpio7/direction=out`), 'sanitize: clean name written');
uloop.timer(20, () => uloop.end());
uloop.run();

// power_cycle / reset_pulse accept a per-modem duration override (repower_time)
fx = mkfx({ [`${G}/lte_power/value`]: '1' });
b = board.create({ id: 'zyxel,lte5398-m904', fx: fx, log: () => {} });
ok(b.power_cycle(2000), 'repower_time: power_cycle accepts an off-duration override');
ok(fx.has(`${G}/lte_power/value=0`), 'repower_time: power-cycle still de-powers');
fx = mkfx({ [`${G}/mygpio/value`]: '1' });
b = board.create({ id: 'zyxel,lte3301-plus', fx: fx, log: () => {} });
ok(b.reset_pulse('mygpio', 2000), 'repower_time: reset_pulse accepts a hold override');
ok(fx.has(`${G}/mygpio/value=0`), 'repower_time: reset still asserted');

// --- 5. unknown board: every op a safe no-op ---------------------------------
fx = mkfx({});
b = board.create({ id: 'acme,unknown-router', fx: fx, log: () => {} });
ok(!b.has_power, 'unknown board: no power');
eq(b.power_cycle(), false, 'unknown board: power_cycle no-op');
eq(b.reset_pulse(), false, 'unknown board: reset_pulse no-op (no board default)');
b.leds({ registered: true, bars: 5 });
eq(length(fx.writes), 0, 'unknown board: leds write nothing');

// --- 6. signal -> bars mapping ------------------------------------------------
eq(board.bars_from_signal({ lte: { rsrp: -75 } }), 5, 'bars: strong lte rsrp -> 5');
eq(board.bars_from_signal({ lte: { rsrp: -105 } }), 2, 'bars: weak lte rsrp -> 2');
eq(board.bars_from_signal({ nr5g: { rsrp: -85 } }), 4, 'bars: nr5g preferred');
// the -32768 "no measurement" sentinel must not win over a valid lte value
eq(board.bars_from_signal({ nr5g: { rsrp: -32768 }, lte: { rsrp: -66 } }), 5,
	'bars: invalid nr5g sentinel ignored, strong lte -> 5');
eq(board.bars_from_signal(null), 0, 'bars: no signal -> 0');
// native-MBIM v1 fallback shape is FLAT ({ rssi, rsrp }) — used to render 0
// bars (LEDs dark) on a pure-native MBIM modem
eq(board.bars_from_signal({ rsrp: -85 }), 4, 'bars: flat rsrp (native MBIM) -> 4');
eq(board.bars_from_signal({ rssi: -80 }), 3, 'bars: flat rssi (native MBIM) -> 3');


// --- 9. reset_pulse: one pulse at a time, and a stated polarity --------------
//
// Field failure on a Cudy LT300 (2026-08-23): the modem was pulsed twice ~7 s
// apart — the recovery ladder and an operator both land in reset_pulse, and a
// 30 s pulse shows nothing, so a second click is the natural reaction. The
// second call sampled the ALREADY-ASSERTED line, took the asserted level for
// the resting one and inverted itself: its release drove the modem down and
// left it there, and every later pulse inherited the inversion (modem up for
// the hold, down for good afterwards). The box needed a mains power cycle.

// (a) a second pulse while one is in flight is ignored, not stacked
let fx9 = mkfx({ [`${G}/4g/value`]: '0' });
let b9 = board.create({ id: 'cudy,lt300-v3', fx: fx9, reset_ms: 30, log: () => {} });

ok(b9.reset_pulse(), 'reset_pulse: first pulse runs');
ok(fx9.has(`${G}/4g/value=1`), 'reset_pulse: asserted (cudy runs at 0, so assert is 1)');

let writes_before = length(fx9.writes);
ok(b9.reset_pulse(), 'reset_pulse: an overlapping call reports success (the reset IS happening)');
eq(length(fx9.writes), writes_before, 'reset_pulse: but it drives the line exactly zero more times');

uloop.timer(60, () => uloop.end());
uloop.run();

ok(fx9.has(`${G}/4g/value=0`), 'reset_pulse: released back to the run level');
// exactly one assert + one release, no second pair
eq(length(filter(fx9.writes, (w) => w == `${G}/4g/value=1`)), 1, 'reset_pulse: one assert total');
eq(length(filter(fx9.writes, (w) => w == `${G}/4g/value=0`)), 1, 'reset_pulse: one release total');

// (b) a stated reset_run is authoritative: the pin is NOT consulted, so a line
// left in the wrong state cannot invert the next pulse
let fx9b = mkfx({ [`${G}/4g/value`]: '1' });   // line sitting at the asserted level
let b9b = board.create({ id: 'cudy,lt300-v3', fx: fx9b, reset_ms: 30, log: () => {} });

ok(b9b.reset_pulse(), 'reset_pulse: runs with the line left asserted');
ok(fx9b.has(`${G}/4g/value=1`), 'reset_pulse: still asserts the same level (no inversion)');

uloop.timer(60, () => uloop.end());
uloop.run();

ok(fx9b.has(`${G}/4g/value=0`), 'reset_pulse: still releases to the run level — recovers a stuck line');

// (c) back-to-back pulses stay in phase: after two sequential pulses the line
// is at the run level, not flipped
let fx9c = mkfx({ [`${G}/4g/value`]: '0' });
let b9c = board.create({ id: 'cudy,lt300-v3', fx: fx9c, reset_ms: 20, log: () => {} });

b9c.reset_pulse();
uloop.timer(50, () => uloop.end());
uloop.run();
b9c.reset_pulse();
uloop.timer(50, () => uloop.end());
uloop.run();

eq(fx9c.read(`${G}/4g/value`), '0', 'reset_pulse: two sequential pulses leave the modem running');

// (d) an unmeasured board keeps the sampled-polarity fallback
let fx9d = mkfx({ [`${G}/modem-reset/value`]: '1' });
let b9d = board.create({ id: 'mikrotik,chateau-5g-r17-ax', fx: fx9d, reset_ms: 20, log: () => {} });

ok(b9d.reset_pulse(), 'reset_pulse: profile without reset_run still works');
ok(fx9d.has(`${G}/modem-reset/value=0`), 'reset_pulse: sampled polarity drives the inverse');

uloop.timer(50, () => uloop.end());
uloop.run();
ok(fx9d.has(`${G}/modem-reset/value=1`), 'reset_pulse: sampled polarity restores the rest level');

// --- a GPIO write that fails must not be reported as a completed action ------
// The recovery ladder reads these return values: false sends it on to the next
// rung, true means the hardware was driven. A true that wrote nothing consumes
// the hardware rung without touching the hardware, and the box then sits until
// the reboot rung far above it -- which on a remote installation is the
// difference between an automatic recovery and a site visit.
let ffx = mkfx({ [`${G}/modem-power/value`]: '1', [`${G}/modem-reset/value`]: '1' },
	{}, { [`${G}/modem-power/value`]: true, [`${G}/modem-reset/value`]: true });
let fb = board.create({ id: 'mikrotik,chateau-5g-r17-ax', fx: ffx,
                        power_off_ms: 5, reset_ms: 5, log: () => {} });

eq(fb.power_cycle(), false, 'gpio-fail: a power cycle that could not switch the line reports false');
eq(fb.reset_pulse('modem-reset', 5), false, 'gpio-fail: and so does a reset pulse');

// ...and the failed pulse must not have taken the single-pulse latch with it:
// a later attempt on a working line has to be able to run
let okfx = mkfx({ [`${G}/modem-reset/value`]: '1' });
let okb = board.create({ id: 'mikrotik,chateau-5g-r17-ax', fx: okfx,
                         power_off_ms: 5, reset_ms: 5, log: () => {} });
eq(okb.reset_pulse('modem-reset', 5), true, 'gpio-fail: a working line still pulses');

// --- board files (ddimension/wwand#48) ---------------------------------------
const USR = '/usr/share/wwand/boards.d', ETC = '/etc/wwand/boards.d';

// every built-in profile passes the validator a board file has to pass, so
// the table and the files cannot drift into two dialects
for (let bid in [ 'mikrotik,chateau-5g-r17-ax', 'zyxel,lte3301-plus', 'zyxel,lte3301-m209',
                  'zyxel,lte3301-q222', 'zyxel,lte5398-m904', 'zyxel,nr7101',
                  'cudy,lt300-v3', 'huasifei,wh3000-pro-emmc', 'huasifei,wh3000-pro-nand' ]) {
	let pb = board.create({ id: bid, fx: mkfx({}), log: () => {} });
	eq(pb.profile_source, 'builtin', `builtin ${bid}: found in the table`);
	eq(board.validate_profile(pb.profile), null, `builtin ${bid}: passes the board-file validator`);
}

// a board wwand does not know, described by a file: power, reset, LEDs
let logs = [];
let blog = (lv, m) => push(logs, `${lv}: ${m}`);
let bfx = mkfx({
	[`${USR}/tuoshi,t22m.json`]: '{ "power_gpio": "modem_pwr", "power_gpio_active_low": true,'
		+ ' "reset_gpio": "modem_rst", "reset_run": 1, "option_ids": [ "1e0e 9001" ],'
		+ ' "leds": { "style": "mobile", "green": "green:4g", "red": "red:sig" },'
		+ ' "note": "measured on a T22M" }',
	[`${G}/modem_pwr/value`]: '1',
});
let fb1 = board.create({ id: 'tuoshi,t22m', fx: bfx, log: blog });
eq(fb1.profile_source, `${USR}/tuoshi,t22m.json`, 'file: an unknown board gets its profile from the file');
ok(fb1.has_power, 'file: its power line counts');
ok(length(filter(logs, (l) => index(l, 'profile from') >= 0)) == 1, 'file: the log names the file');
fb1.init();
ok(bfx.has(`${G}/modem_pwr/value=0`), 'file: active_low applies (1 read as off, powered with 0)');
ok(bfx.has('/sys/module/option/drivers/usb-serial:option1/new_id=1e0e 9001'), 'file: option_ids are bound');
fb1.leds({ present: true, registered: true, radio: 'lte' });
ok(bfx.has(`${L}/green:4g/brightness=255`), 'file: a named LED style renders');
ok(bfx.has(`${L}/red:sig/brightness=0`), 'file: ...on the names the file gave');

// a file overrides the built-in entry, and /etc wins over /usr/share
let ofx = mkfx({
	[`${USR}/mikrotik,chateau-5g-r17-ax.json`]: '{ "power_gpio": "from-usr" }',
	[`${ETC}/mikrotik,chateau-5g-r17-ax.json`]: '{ "power_gpio": "from-etc", "reset_run": 0 }',
});
let ob = board.create({ id: 'mikrotik,chateau-5g-r17-ax', fx: ofx, log: () => {} });
eq(ob.profile.power_gpio, 'from-etc', 'override: /etc beats /usr/share beats the table');
eq(ob.profile.leds, null, 'override: a file replaces the entry whole, nothing is merged in');

// a broken file is ignored whole and logged; the table still applies
let bad = (body, why) => {
	let l2 = [];
	let x = board.create({ id: 'mikrotik,chateau-5g-r17-ax', log: (lv, m) => push(l2, m),
		fx: mkfx({ [`${ETC}/mikrotik,chateau-5g-r17-ax.json`]: body }) });
	eq(x.profile_source, 'builtin', `invalid (${why}): falls back to the table`);
	ok(length(filter(l2, (m) => index(m, why) >= 0)) == 1, `invalid (${why}): the log says ${why}`);
};
bad('{ "power_gpio": "x", "power_gpio_activ_low": true }', 'unknown key');
bad('{ "power_gpio": "x", ', 'not valid JSON');
bad('[ 1 ]', 'not a JSON object');
bad('{ "power_gpio": "../../x" }', 'not a GPIO name');
bad('{ "power_gpio_active_low": 1 }', 'must be true or false');
bad('{ "reset_run": 2 }', 'reset_run');
bad('{ "option_ids": [ "2dee:4d57" ] }', 'option_ids');
bad('{ "leds": { "style": "sweep" } }', 'unknown style');
bad('{ "leds": { "style": "mobile", "blue": "b" } }', 'has no');
bad('{ "leds": { "style": "signal_bars", "names": [ "a/b" ] } }', 'not an LED name');
bad('{ "leds": { "style": "signal_bars", "names": "one" } }', 'must be a list');
bad('{ "leds": { "style": "mobile", "green": [ "green:a", "green:b" ] } }', 'must be one LED name');
bad('{ "power_gpio": "modem+power" }', 'not a GPIO name');
bad('{ "leds": { "style": "signal_bars" } }', 'leds.names: missing');
bad('{ "leds": { "style": "mobile", "green": "g" } }', 'leds.red: missing');
bad('{ "reset_run": 0.0 }', 'reset_run');
bad('{ "leds": { "style": "signal_bars", "names": [] } }', 'empty');

bad('{ "leds": [] }', 'leds: empty');
bad('{ "leds": [ { "style": "signal_bars", "names": [ "a" ] }, { "style": "nope" } ] }', 'leds[1]: unknown style');
bad('{ "leds": { "style": "tech" } }', 'leds.leds: missing');
bad('{ "leds": { "style": "tech", "leds": { "6g": "x" } } }', 'is not one of');
bad('{ "leds": { "style": "tech", "leds": {} } }', 'must map');
bad('{ "leds": { "style": "tech", "leds": { "4g": { "led": "g", "weak": "flash" } } } }', 'must be on, blink or off');
bad('{ "leds": { "style": "tech", "leds": { "4g": { "led": "g", "blink": true } } } }', 'has no');
bad('{ "leds": { "style": "tech", "leds": { "4g": { "led": "../x" } } } }', 'not an LED name');
bad('{ "leds": { "style": "tech", "leds": { "4g": "g" }, "weak_bars": 6 } }', '0 to 5');
bad('{ "leds": { "style": "tech", "leds": { "4g": "g" }, "cumulative": 1 } }', 'must be true or false');
bad('{ "leds": { "style": "signal_color" } }', 'at least one of red, green, blue');
bad('{ "leds": { "style": "signal_color", "red": "r", "green": "g", "colors": [ "red" ] } }', 'must list 5');
bad('{ "leds": { "style": "signal_color", "red": "r", "green": "g", "colors": [ "red", "red", "pink", "green", "green" ] } }', 'not a colour');
// a red/green LED cannot show blue: refused, not silently shown as something else
bad('{ "leds": { "style": "signal_color", "red": "r", "green": "g", "colors": [ "red", "red", "yellow", "cyan", "green" ] } }', 'needs the blue channel');
bad('{ "leds": { "style": "signal_color", "red": "r", "green": "g", "searching": { "color": "blue" } } }', 'needs the blue channel');
bad('{ "leds": { "style": "signal_color", "red": "r", "searching": { "color": "red", "blink": "yes" } } }', 'blink: must be true or false');

// --- 7. technology and colour panels (ddimension/wwand#77) -------------------
//
// The board files are the ones the reporters described: a Xunison Exigo Hub
// D50 (4G + 5G LEDs, red 5G for searching) and an Arcadyan AW1000 (two RGB
// lamps, each three on/off gpio-leds).
function led_board(leds) {
	let f = mkfx({ [`${ETC}/test,board.json`]: sprintf('%J', { leds: leds }) });
	let b = board.create({ id: 'test,board', fx: f, dirs: [ ETC ], log: () => {} });

	return { fx: f, b: b, state: (name) => {
		// the last value written to an LED: 'timer', 255 or 0
		let v = null;

		for (let w in f.writes) {
			if (w == `${L}/${name}/trigger=timer`)
				v = 'timer';
			else if (w == `${L}/${name}/brightness=255`)
				v = 255;
			else if (w == `${L}/${name}/brightness=0`)
				v = 0;
		}

		return v;
	} };
}

{
	let xun = { style: 'tech', cumulative: true, weak_bars: 1, searching: 'red:5g',
		leds: { '4g': { led: 'green:4g', weak: 'blink' }, '5g': { led: 'green:5g', weak: 'off' } } };
	let t = led_board(xun);

	ok(t.b.profile != null, 'tech: the Xunison board file validates');

	t.b.leds({ present: true, registered: true, gen: '5g', bars: 4 });
	eq([ t.state('green:4g'), t.state('green:5g'), t.state('red:5g') ], [ 255, 255, 0 ],
		'tech: cumulative 5G lights 4G too, searching off');

	t.b.leds({ present: true, registered: true, gen: '5g', bars: 1 });
	eq([ t.state('green:4g'), t.state('green:5g') ], [ 'timer', 0 ],
		'tech: weak 5G blinks 4G and turns 5G off, each by its own `weak`');

	t.b.leds({ present: true, registered: true, gen: '4g', bars: 3 });
	eq([ t.state('green:4g'), t.state('green:5g') ], [ 255, 0 ], 'tech: on LTE only the 4G LED');

	t.b.leds({ present: true, registered: false, bars: 0 });
	eq([ t.state('green:4g'), t.state('green:5g'), t.state('red:5g') ], [ 0, 0, 'timer' ],
		'tech: searching blinks, technologies dark');

	t.b.leds({ present: false, registered: false });
	eq(t.state('red:5g'), 255, 'tech: no modem: searching LED steady');

	// registered with no measurement is not "weak"
	t.b.leds({ present: true, registered: true, gen: '4g', bars: 0 });
	eq(t.state('green:4g'), 255, 'tech: 0 bars (no measurement) is not weak');

	// unchanged LEDs are not rewritten: a re-written timer restarts the blink
	t.b.leds({ present: true, registered: true, gen: '5g', bars: 1 });
	let n = length(t.fx.writes);
	t.b.leds({ present: true, registered: true, gen: '5g', bars: 1 });
	eq(length(t.fx.writes), n, 'tech: a tick with nothing changed writes nothing');
}

{
	// the AW1000's 5G lamp: one RGB LED, one technology at a time
	let aw5g = { style: 'tech', cumulative: false, weak_bars: 1, searching: 'red:5g',
		leds: { '4g': { led: 'green:5g', weak: 'on' }, '5g': { led: 'blue:5g', weak: 'blink' } } };
	let awsig = { style: 'signal_color', red: 'red:signal', green: 'green:signal', blue: 'blue:signal',
		colors: [ 'red', 'red', 'yellow', 'green', 'green' ],
		searching: { color: 'red', blink: true } };
	let t = led_board([ aw5g, awsig ]);

	ok(t.b.profile != null, 'list: the AW1000 board file (two entries) validates');

	t.b.leds({ present: true, registered: true, gen: '5g', bars: 5 });
	eq([ t.state('red:5g'), t.state('green:5g'), t.state('blue:5g') ], [ 0, 0, 255 ],
		'tech: not cumulative, 5G is blue alone — no mixed colour');
	eq([ t.state('red:signal'), t.state('green:signal'), t.state('blue:signal') ], [ 0, 255, 0 ],
		'signal_color: 5 bars green');

	t.b.leds({ present: true, registered: true, gen: '5g', bars: 3 });
	eq([ t.state('red:signal'), t.state('green:signal'), t.state('blue:signal') ], [ 255, 255, 0 ],
		'signal_color: 3 bars yellow = red + green');

	t.b.leds({ present: true, registered: true, gen: '5g', bars: 1 });
	eq(t.state('blue:5g'), 'timer', 'tech: weak 5G blinks blue');
	eq([ t.state('red:signal'), t.state('green:signal') ], [ 255, 0 ], 'signal_color: 1 bar red');

	t.b.leds({ present: true, registered: true, gen: '4g', bars: 4 });
	eq([ t.state('red:5g'), t.state('green:5g'), t.state('blue:5g') ], [ 0, 255, 0 ], 'tech: LTE is green alone');

	t.b.leds({ present: true, registered: false, bars: 0 });
	eq([ t.state('red:5g'), t.state('green:5g'), t.state('blue:5g') ], [ 'timer', 0, 0 ],
		'tech: searching red alone — never mixed with a technology');
	eq([ t.state('red:signal'), t.state('green:signal'), t.state('blue:signal') ], [ 'timer', 0, 0 ],
		'signal_color: searching blinks red');

	t.b.leds({ present: false, registered: false });
	eq(t.state('red:signal'), 255, 'signal_color: no modem: the searching colour, steady');
}

{
	// a red/green signal LED: no blue, default colours
	let t = led_board({ style: 'signal_color', red: 'r:sig', green: 'g:sig' });

	ok(t.b.profile != null, 'signal_color: a bi-colour LED validates with the default colours');
	t.b.leds({ present: true, registered: true, bars: 3 });
	eq([ t.state('r:sig'), t.state('g:sig') ], [ 255, 255 ], 'signal_color: default 3 bars = yellow');
	t.b.leds({ present: true, registered: false });
	eq([ t.state('r:sig'), t.state('g:sig') ], [ 0, 0 ], 'signal_color: no `searching`: dark while searching');
	t.b.leds({ present: true, registered: true, bars: 0 });
	eq([ t.state('r:sig'), t.state('g:sig') ], [ 255, 0 ], 'signal_color: registered, no measurement: weakest colour');
}

{
	// a technology LED beside one signal LED (the Telstra panel), 2G..4G
	// without cumulative; the signal LED blinks when weak
	let t = led_board({ style: 'tech', weak_bars: 2,
		leds: { '2g': 'g:2g', '3g': 'g:3g', '4g': 'g:4g' },
		signal: { led: 'g:sig', weak: 'blink' } });

	t.b.leds({ present: true, registered: true, gen: '3g', bars: 2 });
	eq([ t.state('g:2g'), t.state('g:3g'), t.state('g:4g'), t.state('g:sig') ], [ 0, 255, 0, 'timer' ],
		'tech: 3G alone; a plain-name LED stays on when weak, the signal LED blinks');
	t.b.leds({ present: true, registered: true, gen: '5g', bars: 4 });
	eq([ t.state('g:4g'), t.state('g:sig') ], [ 0, 255 ],
		'tech: a generation the panel has no LED for lights none of them');
}

{
	// two entries naming one LED: lit if either lights it
	let t = led_board([ { style: 'signal_bars', names: [ 'x' ] },
	                    { style: 'tech', leds: { '4g': 'x' } } ]);
	t.b.leds({ present: true, registered: true, gen: '5g', bars: 1 });
	eq(t.state('x'), 255, 'list: an LED two entries share is on when one lights it');
}

{
	// a write that failed is tried again on the next tick, not remembered
	let t = led_board({ style: 'tech', leds: { '4g': 'g:4g' } });
	let fail = true;
	let w = t.fx.write;
	t.fx.write = (p, v) => (fail && p == `${L}/g:4g/brightness`) ? (push(t.fx.writes, p + '=x'), false) : w(p, v);
	t.b.leds({ present: true, registered: true, gen: '4g', bars: 3 });
	fail = false;
	t.b.leds({ present: true, registered: true, gen: '4g', bars: 3 });
	eq(t.state('g:4g'), 255, 'cache: a failed write is retried on the next tick');

	// something else switched the LED: the next tick puts it back
	let n = length(t.fx.writes);
	t.b.leds({ present: true, registered: true, gen: '4g', bars: 3 });
	eq(length(t.fx.writes), n, 'cache: ...and then left alone while sysfs still shows it');
	t.fx.write(`${L}/g:4g/trigger`, 'heartbeat');
	t.b.leds({ present: true, registered: true, gen: '4g', bars: 3 });
	ok(t.fx.has(`${L}/g:4g/trigger=none`) && t.state('g:4g') == 255 &&
	   length(t.fx.writes) > n + 1, 'cache: an LED someone else switched is restored');

	// the kernel's trigger list shows the active one in brackets
	let k = led_board({ style: 'tech', leds: { '4g': { led: 'k', weak: 'blink' } }, weak_bars: 1 });
	k.b.leds({ present: true, registered: true, gen: '4g', bars: 1 });
	k.fx.write(`${L}/k/trigger`, 'none [timer] heartbeat');
	n = length(k.fx.writes);
	k.b.leds({ present: true, registered: true, gen: '4g', bars: 1 });
	eq(length(k.fx.writes), n, 'cache: "[timer]" in the kernel\'s list counts as blinking');
}

bad('{ "leds": { "style": "signal_color", "red": "x", "green": "x" } }', 'must name different LEDs');
eq(board.generation({ rat: 'evdo' }), '3g', 'gen: EVDO is CDMA2000\'s 3G, not 2G like 1x');
eq(board.generation({ rat: 'cdma' }), '2g', 'gen: CDMA 1x');

// the generation the daemon hands the panel
eq(board.generation({ rat: { rat: 'nr5g', mode: 'nsa' }, radio_ifs: [ 8 ] }), '5g',
	'gen: 5G NSA from rat_fine though NAS lists only the LTE anchor');
eq(board.generation({ rat: null, radio_ifs: [ 8, 12 ] }), '5g', 'gen: the highest NAS radio interface');
eq(board.generation({ radio_ifs: [ 5 ] }), '3g', 'gen: UMTS');
eq(board.generation({ rat: 'edge' }), '2g', 'gen: a fine slug maps by family');
eq(board.generation({ text: 'wcdma' }), '3g', 'gen: NCM RAT text');
eq(board.generation({ text: 'lte' }), '4g', 'gen: NCM LTE');
eq(board.generation({ rat: 'ntn' }), null, 'gen: NTN has no panel generation');
eq(board.generation({}), null, 'gen: nothing known');

// a broken /etc file does not fall back to the packaged one it was there to
// replace: the built-in entry applies
let pfx = mkfx({
	[`${USR}/mikrotik,chateau-5g-r17-ax.json`]: '{ "power_gpio": "from-usr" }',
	[`${ETC}/mikrotik,chateau-5g-r17-ax.json`]: '{ "power_gpio": "from-etc", "typo": 1 }',
});
let pb2 = board.create({ id: 'mikrotik,chateau-5g-r17-ax', fx: pfx, log: () => {} });
eq(pb2.profile_source, 'builtin', 'precedence: a broken /etc file falls back to the table, not to /usr/share');
eq(pb2.profile.power_gpio, 'modem-power', 'precedence: ...the built-in power line');

// a broken file for an unknown board leaves it unknown, i.e. all no-ops
let ub = board.create({ id: 'tuoshi,t22m', log: () => {},
	fx: mkfx({ [`${USR}/tuoshi,t22m.json`]: '{ "power_gpio": 5 }' }) });
eq(ub.profile, null, 'invalid, no built-in: no profile at all');

// the model id names the file and must not be able to name anything else
let rfx = mkfx({});
let reads = [];
rfx.read = (p) => { push(reads, p); return null; };
board.create({ id: '../../etc/passwd', fx: rfx, log: () => {} });
eq(length(reads), 0, 'id: a model id with a path in it reads no file');

done('test_board');
