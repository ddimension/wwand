'use strict';
'require view';
'require rpc';
'require ui';

// wwand modem settings editor. All values go through the daemon's QMI-native
// ubus methods; band preferences travel as band-number lists (u64 masks would
// lose precision in JS numbers).

var callStatus = rpc.declare({ object: 'wwand', method: 'status', expect: { modems: {} } });
var callGet  = rpc.declare({ object: 'wwand', method: 'modem_get_settings', params: [ 'modem' ], expect: {} });
var callSet  = rpc.declare({ object: 'wwand', method: 'modem_set_settings', params: [ 'modem', 'settings' ], expect: {} });
var callPlmn = rpc.declare({ object: 'wwand', method: 'modem_plmn_lists', params: [ 'modem' ], expect: {} });

var MODE_BITS = [
	[ 0x04, 'GSM' ],
	[ 0x08, 'UMTS' ],
	[ 0x10, 'LTE' ],
	[ 0x40, 'NR5G' ],
];

// reset-to-defaults preset: everything the modem supports (it clamps unknown
// band bits itself), data-centric, roaming allowed
var DEFAULTS = {
	mode_preference: 0x50,
	usage_preference: 2,
	roaming_preference: 255,
	lte_bands: [], nr5g_sa_bands: [], nr5g_nsa_bands: [],
};

for (var b = 1; b <= 63; b++) DEFAULTS.lte_bands.push(b);
for (var n = 1; n <= 79; n++) { DEFAULTS.nr5g_sa_bands.push(n); DEFAULTS.nr5g_nsa_bands.push(n); }

function parseBandList(text) {
	var out = [];
	(text || '').split(/[,\s]+/).forEach(function(tok) {
		var n = parseInt(tok, 10);
		if (!isNaN(n) && n > 0 && n <= 512 && out.indexOf(n) < 0)
			out.push(n);
	});
	return out.sort(function(a, b) { return a - b });
}

function plmnTable(title, list) {
	if (list == null)
		return E('p', {}, [ E('em', {}, title + ': ' + _('not present on this SIM')) ]);

	var rows = list.map(function(e) {
		var rats = [ 'gsm', 'utran', 'eutran', 'ngran' ]
			.filter(function(k) { return e[k] })
			.map(function(k) { return k.toUpperCase() }).join(' ');
		return E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td' }, e.mcc + '/' + e.mnc),
			E('td', { 'class': 'td' }, rats),
		]);
	});

	return E('div', {}, [
		E('h4', {}, title + ' (' + list.length + ')'),
		E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, 'PLMN'),
				E('th', { 'class': 'th' }, _('Access technologies')),
			]),
		].concat(rows)),
	]);
}

return view.extend({
	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	load: function() {
		return callStatus().then(function(modems) {
			var names = Object.keys(modems || {});

			if (!names.length)
				return { modem: null };

			return Promise.all([ callGet(names[0]), callPlmn(names[0]) ]).then(function(res) {
				return { modem: names[0], settings: res[0], plmn: res[1] };
			});
		});
	},

	apply: function(modem, settings) {
		return callSet(modem, settings).then(function(res) {
			if (res && res.ok)
				ui.addNotification(null, E('p', _('Modem settings applied.')), 'info');
			else
				ui.addNotification(null, E('p', _('Failed: ') + ((res || {}).error || '?')), 'error');
		});
	},

	render: function(data) {
		if (!data || !data.modem)
			return E('p', {}, _('No modem present.'));

		var self = this;
		var s = data.settings || {};
		var modeBoxes = MODE_BITS.map(function(m) {
			return E('label', { 'style': 'margin-right:1em' }, [
				E('input', { type: 'checkbox', 'data-bit': m[0],
					checked: (s.mode_preference & m[0]) ? '' : null }),
				' ' + m[1],
			]);
		});

		var usageSel = E('select', {}, [
			E('option', { value: 1, selected: s.usage_preference == 1 ? '' : null }, _('voice centric')),
			E('option', { value: 2, selected: s.usage_preference == 2 ? '' : null }, _('data centric')),
		]);

		var roamSel = E('select', {}, [
			E('option', { value: 1,   selected: s.roaming_preference == 1 ? '' : null }, _('off')),
			E('option', { value: 255, selected: s.roaming_preference == 255 ? '' : null }, _('any')),
		]);

		var lteIn = E('input', { type: 'text', style: 'width:100%',
			value: (s.lte_bands || []).join(',') });
		var saIn = E('input', { type: 'text', style: 'width:100%',
			value: (s.nr5g_sa_bands || []).join(',') });
		var nsaIn = E('input', { type: 'text', style: 'width:100%',
			value: (s.nr5g_nsa_bands || []).join(',') });

		var collect = function() {
			var mode = 0;
			modeBoxes.forEach(function(l) {
				var cb = l.firstElementChild;
				if (cb.checked)
					mode |= +cb.getAttribute('data-bit');
			});
			return {
				mode_preference: mode,
				usage_preference: +usageSel.value,
				roaming_preference: +roamSel.value,
				lte_bands: parseBandList(lteIn.value),
				nr5g_sa_bands: parseBandList(saIn.value),
				nr5g_nsa_bands: parseBandList(nsaIn.value),
			};
		};

		var row = function(label, node) {
			return E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, label),
				E('div', { 'class': 'cbi-value-field' }, [ node ]),
			]);
		};

		return E('div', {}, [
			E('h2', {}, _('Modem Settings') + ' — ' + data.modem),
			E('div', { 'class': 'cbi-section' }, [
				row(_('Radio technologies'), E('div', {}, modeBoxes)),
				row(_('UE usage'), usageSel),
				row(_('Roaming'), roamSel),
				row(_('LTE bands'), lteIn),
				row(_('NR5G SA bands'), saIn),
				row(_('NR5G NSA bands'), nsaIn),
			]),
			E('div', { 'class': 'cbi-page-actions' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-apply',
					click: ui.createHandlerFn(self, function() {
						return self.apply(data.modem, collect());
					}) }, _('Apply')),
				' ',
				E('button', { 'class': 'btn cbi-button cbi-button-reset',
					click: ui.createHandlerFn(self, function() {
						if (!confirm(_('Reset radio/band/usage/roaming settings to defaults?')))
							return;
						return self.apply(data.modem, DEFAULTS).then(function() {
							window.location.reload();
						});
					}) }, _('Reset to defaults')),
			]),
			E('h3', {}, _('SIM PLMN preference lists')),
			plmnTable(_('User-controlled (editable by CPOL)'), (data.plmn || {}).user),
			plmnTable(_('Operator-controlled'), (data.plmn || {}).operator),
			plmnTable(_('Home PLMN'), (data.plmn || {}).home),
		]);
	},
});
