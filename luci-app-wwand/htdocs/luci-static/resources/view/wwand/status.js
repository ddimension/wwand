'use strict';
'require view';
'require poll';
'require dom';
'require rpc';
'require ui';

var callStatus = rpc.declare({ object: 'wwand', method: 'status', expect: { modems: {} } });
var callSignal = rpc.declare({ object: 'wwand', method: 'modem_signal', params: [ 'modem' ], expect: {} });
var callCells  = rpc.declare({ object: 'wwand', method: 'modem_cells',  params: [ 'modem' ], expect: {} });

/* LTE EARFCN -> band/frequency (common bands), NR ARFCN -> MHz/band. */
var LTE_BANDS = [
	[1,0,599,2110],[2,600,1199,1930],[3,1200,1949,1805],[4,1950,2399,2110],
	[5,2400,2649,869],[7,2750,3449,2620],[8,3450,3799,925],[12,5010,5179,729],
	[13,5180,5279,746],[17,5730,5849,734],[18,5850,5999,860],[19,6000,6149,875],
	[20,6150,6449,791],[25,8040,8689,1930],[26,8690,9039,859],[28,9210,9659,758],
	[32,9770,9919,1452],[38,37750,38249,2570],[40,38650,39649,2300],
	[41,39650,41589,2496],[42,41590,43589,3400],[43,43590,45589,3600]
];
var NR_BANDS = [['n1',2110,2170],['n3',1805,1880],['n7',2620,2690],['n8',925,960],
	['n20',791,821],['n28',758,803],['n38',2570,2620],['n40',2300,2400],
	['n41',2496,2690],['n77',3300,4200],['n78',3300,3800]];

function lteEarfcn(e) {
	for (var i = 0; i < LTE_BANDS.length; i++) {
		var b = LTE_BANDS[i];
		if (e >= b[1] && e <= b[2]) return { band: 'B'+b[0], mhz: b[3]+0.1*(e-b[1]) };
	}
	return null;
}
function nrArfcn(a) {
	if (a == null) return null;
	var mhz = a/200, band = null;
	for (var i = 0; i < NR_BANDS.length; i++)
		if (mhz >= NR_BANDS[i][1] && mhz <= NR_BANDS[i][2]) { band = NR_BANDS[i][0]; break; }
	return { band: band, mhz: mhz };
}

/* peak-hold across polls, per modem, for antenna alignment */
var peak = {};
function trackPeak(name, key, val) {
	if (val == null) return null;
	peak[name] = peak[name] || {};
	if (peak[name][key] == null || val > peak[name][key]) peak[name][key] = val;
	return peak[name][key];
}

/* colour by quality thresholds [good, fair] (higher = better) */
function qcolor(v, good, fair) {
	if (v == null) return '#888';
	if (v >= good) return '#3c3'; if (v >= fair) return '#da3'; return '#e33';
}

/* a labelled bar: value mapped from [min,max] to 0..100% */
function bar(label, val, unit, min, max, good, fair) {
	var pct = (val == null) ? 0 : Math.max(0, Math.min(100, (val - min) / (max - min) * 100));
	var col = qcolor(val, good, fair);
	return E('div', { 'style': 'margin:4px 0' }, [
		E('div', { 'style': 'display:flex;justify-content:space-between' }, [
			E('span', {}, label),
			E('strong', { 'style': 'color:%s'.format(col) },
				(val == null) ? '—' : '%s %s'.format(val, unit))
		]),
		E('div', { 'style': 'background:#eee;border-radius:3px;height:10px;overflow:hidden' },
			E('div', { 'style': 'width:%d%%;height:100%%;background:%s'.format(pct, col) }))
	]);
}

function tbl(rows) {
	return E('table', { 'class': 'table' }, rows.map(function(r) {
		return E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left', 'width': '30%' }, r[0]),
			E('td', { 'class': 'td left' }, r[1]) ]);
	}));
}

function renderLive(name, modem) {
	return Promise.all([
		L.resolveDefault(callSignal(name), {}),
		L.resolveDefault(callCells(name), {})
	]).then(function(res) {
		var sig = res[0] || {}, cells = (res[1] || {}).cells || {};
		var reg = modem.registration || {};
		var lte = sig.lte || {}, nr = sig.nr5g || {};
		var cols = [];

		/* --- signal panel (alignment) --- */
		var sigRows = [];
		if (lte.rsrp != null && lte.rsrp > -32768) {
			sigRows.push(bar(_('LTE RSRP'), lte.rsrp, 'dBm', -120, -70, -90, -105));
			sigRows.push(bar(_('LTE RSRQ'), lte.rsrq, 'dB', -20, -3, -10, -15));
			sigRows.push(bar(_('LTE SINR'), (lte.snr/10), 'dB', -5, 30, 13, 0));
			var pk = trackPeak(name, 'rsrp', lte.rsrp);
			var pkq = trackPeak(name, 'sinr', lte.snr/10);
			sigRows.push(E('div', { 'style': 'margin-top:6px;color:#666;font-size:90%' },
				_('Peak: RSRP %s dBm · SINR %s dB').format(pk, (pkq != null) ? pkq.toFixed(1) : '—')));
		}
		if (nr.rsrp != null && nr.rsrp > -32768) {
			sigRows.push(E('hr'));
			sigRows.push(bar(_('5G RSRP'), nr.rsrp, 'dBm', -120, -70, -90, -105));
			sigRows.push(bar(_('5G SINR'), (nr.snr/10), 'dB', -5, 30, 13, 0));
		}
		if (!sigRows.length)
			sigRows.push(E('em', {}, _('no signal (modem not registered)')));

		cols.push(E('div', { 'class': 'cbi-section', 'style': 'flex:1;min-width:280px' }, [
			E('h3', {}, _('Signal — aim the antenna for the highest RSRP/SINR')),
			E('div', {}, sigRows)
		]));

		/* --- serving/registration panel --- */
		var lc = cells.lte_intra;
		var ef = lc ? lteEarfcn(lc.earfcn) : null;
		var plmn = reg.plmn;
		var srvRows = [
			[ _('State'), modem.state || '?' ],
			[ _('Registration'), (reg.registration == 1) ? _('registered') : _('searching') ]
		];
		if (plmn) srvRows.push([ _('Operator'), '%s (%s/%s)%s'.format((plmn.description||'').trim(),
			plmn.mcc, plmn.mnc, reg.roaming ? ' · '+_('roaming') : '') ]);
		if (lc) {
			srvRows.push([ _('Technology'), 'LTE' + (nr.rsrp > -32768 ? ' + 5G NR' : '') ]);
			srvRows.push([ _('Band'), ef ? ef.band : '—' ]);
			srvRows.push([ _('Frequency'), ef ? ef.mhz.toFixed(1)+' MHz' : '—' ]);
			srvRows.push([ _('EARFCN / PCI'), '%d / %d'.format(lc.earfcn, lc.serving_cell_id) ]);
			srvRows.push([ _('TAC / Cell ID'), '%d / %d'.format(lc.tac, lc.global_cell_id) ]);
		}
		var nc = cells.nr5g_cell, nf = nc ? nrArfcn(cells.nr5g_arfcn) : null;
		if (nc) srvRows.push([ _('5G cell'), '%s · ARFCN %s · PCI %d'.format(
			nf && nf.band ? nf.band : '?', cells.nr5g_arfcn || '?', nc.pci) ]);

		cols.push(E('div', { 'class': 'cbi-section', 'style': 'flex:1;min-width:280px' }, [
			E('h3', {}, _('Serving cell')), tbl(srvRows)
		]));

		var out = [ E('div', { 'style': 'display:flex;gap:16px;flex-wrap:wrap' }, cols) ];

		/* --- neighbour cells --- */
		if (lc && lc.cells && lc.cells.length > 1) {
			var neigh = lc.cells.filter(function(c){ return c.pci != lc.serving_cell_id; });
			out.push(E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('LTE neighbour cells')),
				E('table', { 'class': 'table' }, [
					E('tr', { 'class': 'tr table-titles' }, [
						E('th', { 'class':'th' }, 'PCI'), E('th', { 'class':'th' }, 'RSRP'),
						E('th', { 'class':'th' }, 'RSRQ'), E('th', { 'class':'th' }, _('lock value'))
					])
				].concat(neigh.map(function(c){
					return E('tr', { 'class': 'tr' }, [
						E('td', { 'class':'td' }, ''+c.pci),
						E('td', { 'class':'td' }, (c.rsrp/10).toFixed(1)+' dBm'),
						E('td', { 'class':'td' }, (c.rsrq/10).toFixed(1)+' dB'),
						E('td', { 'class':'td' }, '%d:%d'.format(lc.earfcn, c.pci)) ]);
				}))) ]));
		}

		return E('div', {}, out);
	});
}

return view.extend({
	load: function() {
		return L.resolveDefault(callStatus(), {});
	},

	render: function(modems) {
		var current = null;
		var selWrap = E('span', {});   // filled with a modem selector when >1
		var live = E('div', { 'id': 'wwand-live' }, E('em', {}, _('loading…')));

		function buildSelector(ms) {
			var names = Object.keys(ms || {});
			if (names.length < 2) { dom.content(selWrap, ''); return; }
			var sel = E('select', { 'class': 'cbi-input-select',
				'change': function(ev){ current = ev.target.value; peak[current] = {}; refresh(); } },
				names.map(function(n){
					var m = ms[n];
					return E('option', { 'value': n,
						'selected': (n == current) ? 'selected' : null },
						'%s (%s)'.format(m.netdev || n, m.model || '?'));
				}));
			dom.content(selWrap, [ _('Modem') + ': ', sel ]);
		}

		function refresh() {
			return callStatus().then(function(ms) {
				ms = ms || {};
				var names = Object.keys(ms);
				var el = document.getElementById('wwand-live');
				if (!el) return;

				if (!names.length) {
					current = null;
					dom.content(selWrap, '');
					dom.content(el, E('em', {}, _('wwand is not running or no modem present yet.')));
					return;
				}

				if (!current || !ms[current]) current = names[0];
				buildSelector(ms);
				return renderLive(current, ms[current]).then(function(node){
					var e2 = document.getElementById('wwand-live');
					if (e2) dom.content(e2, node);
				});
			});
		}

		var resetBtn = E('button', { 'class': 'btn cbi-button', 'click': function(){
			if (current) peak[current] = {}; refresh();
		} }, _('Reset peak'));

		poll.add(refresh, 1);
		refresh();

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Modem Status')),
			E('div', { 'class': 'cbi-map-descr' },
				_('Live cellular signal and cell environment — updates about once per second. Aim the antenna for the highest RSRP / SINR; the peak values below help while turning it.')),
			E('div', { 'class': 'cbi-section', 'style': 'display:flex;gap:12px;align-items:center' },
				[ selWrap, resetBtn ]),
			live
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
