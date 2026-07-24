// wwand tests — board abstraction (board.uc): model detection, named-GPIO
// enumeration, modem power-cycle + reset-pulse (incl. the deferred restore), and
// status-LED rendering per board profile. sysfs is faked via a recording fx.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as uloop from 'uloop';
import * as board from 'wwand/board.uc';

uloop.init();

function mkfx(files, dirs) {
	let writes = [];
	return {
		writes: writes,
		read: (p) => files[p],
		write: (p, v) => { push(writes, sprintf('%s=%s', p, v)); files[p] = v; return true; },
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

done('test_board');
