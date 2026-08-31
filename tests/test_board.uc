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

done('test_board');
