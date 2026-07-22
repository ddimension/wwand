'use strict';
'require view';
'require rpc';
'require ui';
'require uci';

// wwand modem settings editor. All values go through the daemon's QMI-native
// ubus methods; band preferences travel as band-number lists (u64 masks would
// lose precision in JS numbers).

var callStatus = rpc.declare({ object: 'wwand', method: 'status', expect: { modems: {} } });
var callGet  = rpc.declare({ object: 'wwand', method: 'modem_get_settings', params: [ 'modem' ], expect: {} });
var callSet  = rpc.declare({ object: 'wwand', method: 'modem_set_settings', params: [ 'modem', 'settings' ], expect: {} });
var callPlmn = rpc.declare({ object: 'wwand', method: 'modem_plmn_lists', params: [ 'modem' ], expect: {} });
var callSlots = rpc.declare({ object: 'wwand', method: 'modem_sim_slots', params: [ 'modem' ], expect: {} });
var callSwitchSlot = rpc.declare({ object: 'wwand', method: 'modem_sim_switch_slot', params: [ 'modem', 'slot' ], expect: {} });
var callEsim = rpc.declare({ object: 'wwand', method: 'modem_esim',
	params: [ 'modem', 'op', 'slot', 'iccid', 'activation_code', 'confirmation_code' ], expect: {} });

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
		return Promise.all([ callStatus(), uci.load('network') ]).then(function(r) {
			var names = Object.keys(r[0] || {});

			if (!names.length)
				return { modem: null };

			return Promise.all([
				callGet(names[0]),
				callPlmn(names[0]),
				L.resolveDefault(callSlots(names[0]), {}),
				L.resolveDefault(callEsim(names[0], 'profiles', 0, '', '', ''), {}),
				L.resolveDefault(callEsim(names[0], 'backend', 0, '', '', ''), {}),
			]).then(function(res) {
				var esim = res[3] || {};
				esim.backend = (res[4] || {}).backend;
				return { modem: names[0], settings: res[0], plmn: res[1],
				         slots: (res[2] || {}).slots || [], esim: esim };
			});
		});
	},

	simSlotUci: function(slot) {
		// old-style configs carry sim_slot on the first proto-qmi interface
		var target = null;
		uci.sections('network', 'interface', function(s) {
			if (!target && s.proto == 'qmi')
				target = s['.name'];
		});
		if (!target)
			return Promise.reject(new Error('no qmi interface'));
		uci.set('network', target, 'sim_slot', String(slot));
		return uci.save().then(function() { return uci.apply() });
	},

	renderSim: function(data) {
		var self = this;
		var esimOk = data.esim && data.esim.ok !== false && data.esim.profiles;
		var out = [ E('h3', {}, _('SIM')) ];

		var slotRows = (data.slots || []).map(function(sl) {
			var line = [
				E('strong', {}, _('Slot %d').format(sl.physical) +
					(sl.is_euicc ? ' (eSIM)' : '') + (sl.active ? ' ✓' : '')),
				' — ' + sl.card + (sl.iccid ? (', ICCID ' + sl.iccid) : '') +
					(sl.eid ? (', EID ' + sl.eid) : ''), ' '
			];
			line.push(E('button', { 'class': 'btn cbi-button', 'style': 'margin-left:8px',
				'click': ui.createHandlerFn(self, function() {
					return self.simSlotUci(sl.physical).then(function() {
						ui.addNotification(null, E('p', _('Primary SIM set to slot %d (persisted).').format(sl.physical)), 'info');
					});
				}) }, _('Set as primary')));
			if (!sl.active && sl.card == 'present')
				line.push(E('button', { 'class': 'btn cbi-button cbi-button-apply', 'style': 'margin-left:4px',
					'click': ui.createHandlerFn(self, function() {
						if (!confirm(_('Switch to SIM slot %d now? The connection will drop.').format(sl.physical)))
							return;
						return callSwitchSlot(data.modem, sl.physical);
					}) }, _('Switch now')));
			return E('div', { 'style': 'margin-bottom:4px' }, line);
		});

		out.push(E('div', { 'class': 'cbi-section' },
			slotRows.length ? slotRows : [ E('em', {}, _('No slot information available.')) ]));

		if (!esimOk) {
			if (data.esim && data.esim.error == 'esim_not_installed')
				out.push(E('p', {}, E('em', {}, _('eSIM management: package wwand-esim is not installed.'))));
			return out;
		}

		var profRows = (data.esim.profiles || []).map(function(p) {
			var acts = [];
			if (p.state != 'enabled')
				acts.push(E('button', { 'class': 'btn cbi-button cbi-button-apply',
					'click': ui.createHandlerFn(self, function() {
						if (!confirm(_('Enable profile %s? The connection will re-establish.').format(p.iccid)))
							return;
						return callEsim(data.modem, 'enable', 0, p.iccid, '', '').then(function() { window.location.reload() });
					}) }, _('Enable')));
			else
				acts.push(E('button', { 'class': 'btn cbi-button',
					'click': ui.createHandlerFn(self, function() {
						if (!confirm(_('Disable the active profile %s?').format(p.iccid)))
							return;
						return callEsim(data.modem, 'disable', 0, p.iccid, '', '').then(function() { window.location.reload() });
					}) }, _('Disable')));
			acts.push(E('button', { 'class': 'btn cbi-button cbi-button-remove', 'style': 'margin-left:4px',
				'click': ui.createHandlerFn(self, function() {
					if (!confirm(_('Permanently DELETE profile %s from the eUICC?').format(p.iccid)))
						return;
					return callEsim(data.modem, 'delete', 0, p.iccid, '', '').then(function() { window.location.reload() });
				}) }, _('Delete')));
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, p.iccid),
				E('td', { 'class': 'td' }, p.provider || p.name || p.nickname || ''),
				E('td', { 'class': 'td' }, p.state),
				E('td', { 'class': 'td' }, acts),
			]);
		});

		out.push(E('h4', {}, _('eSIM profiles')));
		out.push(E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, 'ICCID'),
				E('th', { 'class': 'th' }, _('Provider')),
				E('th', { 'class': 'th' }, _('State')),
				E('th', { 'class': 'th' }, ''),
			]),
		].concat(profRows.length ? profRows : [
			E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td', 'colspan': 4 }, E('em', {}, _('no profiles'))) ]) ])));

		var codeIn = E('input', { 'type': 'text', 'style': 'width:60%',
			'placeholder': 'LPA:1$rsp.example.com$ACTIVATION-CODE' });
		var confIn = E('input', { 'type': 'text', 'style': 'width:20%', 'placeholder': _('confirmation code (optional)') });
		var dlStatus = E('span', { 'style': 'margin-left:8px; font-weight:bold' });
		var dlLog = E('pre', { 'style': 'max-height:14em; overflow:auto; background:#f5f5f5; ' +
			'padding:6px; margin-top:6px; font-size:90%; display:none' });

		var pollStatus = function() {
			callEsim(data.modem, 'download_status', 0, '', '', '').then(function(st) {
				dlStatus.textContent = _('State: ') + st.state + (st.via ? (' (' + st.via + ')') : '');
				if (st.log) { dlLog.style.display = ''; dlLog.textContent = st.log; dlLog.scrollTop = dlLog.scrollHeight; }
				if (st.state == 'running')
					window.setTimeout(pollStatus, 1500);
				else if (st.state == 'done')
					window.setTimeout(function() { window.location.reload() }, 2500);
			});
		};

		var dlHint = (data.esim.backend == 'at')
			? _('Download runs inside the modem over its own network attach (no router data path needed).')
			: _('Download runs on the router (lpac); requires the wwand-esim lpac helper.');

		out.push(E('h4', {}, _('Download profile')));
		out.push(E('p', {}, E('em', {}, dlHint)));
		out.push(E('div', { 'class': 'cbi-section' }, [
			codeIn, ' ', confIn, ' ',
			E('button', { 'class': 'btn cbi-button cbi-button-apply',
				'click': ui.createHandlerFn(self, function() {
					dlLog.style.display = 'none'; dlLog.textContent = '';
					return callEsim(data.modem, 'download', 0, '', codeIn.value, confIn.value).then(function(res) {
						if (res && res.ok === false)
							ui.addNotification(null, E('p', _('Download failed to start: ') + (res.error || '?')), 'error');
						else
							pollStatus();
					});
				}) }, _('Download')),
			dlStatus,
			dlLog,
		]));

		// pending eUICC notifications: confirm the download/enable/disable to
		// the operator's SM-DP+ (ES9+). Can be done any time the router has
		// internet — lpac delivers the queued notifications.
		out.push(E('h4', {}, _('Provider confirmations (notifications)')));
		out.push(E('p', {}, E('em', {}, _('After a download or profile change the eUICC queues notifications that confirm the operation to the operator. Send them once the router has internet.'))));
		out.push(E('div', { 'class': 'cbi-section' }, [
			E('button', { 'class': 'btn cbi-button',
				'click': ui.createHandlerFn(self, function() {
					return callEsim(data.modem, 'notifications', 0, '', '', '').then(function(r) {
						dlLog.style.display = ''; dlLog.textContent = (r && r.log) || _('(no pending notifications)');
					});
				}) }, _('List pending')),
			' ',
			E('button', { 'class': 'btn cbi-button cbi-button-apply',
				'click': ui.createHandlerFn(self, function() {
					if (!confirm(_('Send all pending notifications to the operator now?')))
						return;
					dlLog.style.display = 'none'; dlLog.textContent = '';
					return callEsim(data.modem, 'notify', 0, '', '', '').then(function(res) {
						if (res && res.ok === false)
							ui.addNotification(null, E('p', _('Failed: ') + (res.error || '?')), 'error');
						else
							pollStatus();
					});
				}) }, _('Send confirmations')),
		]));

		return out;
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
		].concat(this.renderSim(data)).concat([
			E('h3', {}, _('SIM PLMN preference lists')),
			plmnTable(_('User-controlled (editable by CPOL)'), (data.plmn || {}).user),
			plmnTable(_('Operator-controlled'), (data.plmn || {}).operator),
			plmnTable(_('Home PLMN'), (data.plmn || {}).home),
		]));
	},
});
