'use strict';
'require view';
'require rpc';
'require ui';
'require uci';
'require dom';

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
	params: [ 'modem', 'op', 'slot', 'iccid', 'activation_code', 'confirmation_code', 'auto_notify' ], expect: {} });

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

// lpac emits terse ES10/ES9+ step tokens on its progress lines; map them to the
// download stages a human recognises (order = the SGP.22 download sequence).
var DL_STEPS = [
	[ 'es10b_get_euicc_challenge_and_info', _('eUICC challenge') ],
	[ 'es9p_initiate_authentication',       _('Contacting SM-DP+') ],
	[ 'es10b_authenticate_server',          _('Verifying server') ],
	[ 'es9p_authenticate_client',           _('Authenticating') ],
	[ 'es10b_prepare_download',             _('Preparing download') ],
	[ 'es9p_get_bound_profile_package',     _('Fetching profile') ],
	[ 'es10b_load_bound_profile_package',   _('Installing profile') ],
];

// parse the live bridge log (progress:/result:/data: lines) into a status
function parseActivity(log) {
	var seen = {}, order = [], cancelled = false, msg = null, code = null, m;
	(log || '').split('\n').forEach(function(l) {
		l = l.trim();
		if ((m = l.match(/^progress:\s*(\S+)/))) {
			if (/cancel_session/.test(m[1])) cancelled = true;
			else if (!seen[m[1]]) { seen[m[1]] = true; order.push(m[1]); }
		} else if ((m = l.match(/^result:\s*code=(-?\d+)\s*(.*)$/))) {
			code = parseInt(m[1], 10);
			if (m[2] && m[2].trim() && m[2].trim() != 'success') msg = m[2].trim();
		} else if ((m = l.match(/^data:\s*(.+)$/))) {
			var d = m[1].trim();
			if (d.length && d[0] != '{') msg = d;   // human message, not the chip JSON blob
		}
	});
	return { seen: seen, order: order, cancelled: cancelled, msg: msg, code: code };
}

var ESIM_CSS = '' +
'.wwe-panel{margin-top:.6em;border:1px solid rgba(128,128,128,.28);border-radius:7px;padding:14px 16px;background:rgba(128,128,128,.06)}' +
'.wwe-steps{list-style:none;margin:.2em 0 0;padding:0}' +
'.wwe-step{display:flex;align-items:center;gap:9px;padding:3px 0;color:#8a8a8a;font-size:.95em}' +
'.wwe-step .ic{width:1.35em;text-align:center;font-weight:700}' +
'.wwe-step.done{color:#2c8a2c}.wwe-step.cur{color:#0b6fc2;font-weight:600}' +
'.wwe-bar{height:8px;border-radius:5px;background:rgba(128,128,128,.25);overflow:hidden;margin:11px 0 4px}' +
'.wwe-bar>span{display:block;height:100%;background:#0b6fc2;transition:width .45s ease}' +
'.wwe-bar.ok>span{background:#2c8a2c}.wwe-bar.err>span{background:#c0392b}' +
'.wwe-banner{display:flex;align-items:center;gap:9px;padding:9px 13px;border-radius:6px;margin-top:11px;font-weight:600}' +
'.wwe-banner.run{background:rgba(11,111,194,.12);color:#0b6fc2}' +
'.wwe-banner.ok{background:rgba(44,138,44,.14);color:#1e6b1e}' +
'.wwe-banner.err{background:rgba(192,57,43,.13);color:#b3271a}' +
'.wwe-log{max-height:15em;overflow:auto;background:#1e1e1e;color:#dcdcdc;padding:9px 11px;margin-top:9px;' +
'font:12px/1.55 ui-monospace,Menlo,Consolas,monospace;border-radius:5px;white-space:pre-wrap;word-break:break-all}' +
'.wwe-det{margin-top:9px;font-size:.9em}.wwe-det>summary{cursor:pointer;color:#0b6fc2}' +
'.wwe-spin{display:inline-block;width:1.05em;height:1.05em;border:2px solid rgba(11,111,194,.3);' +
'border-top-color:#0b6fc2;border-radius:50%;animation:wwe-rot .9s linear infinite;flex:none}' +
'@keyframes wwe-rot{to{transform:rotate(360deg)}}';

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

		out.push(E('style', {}, ESIM_CSS));

		// shared activity panel: live progress for downloads / notifications
		var panel = E('div', { 'class': 'wwe-panel', 'style': 'display:none' });

		var mkBanner = function(kind, icon, text) {
			return E('div', { 'class': 'wwe-banner ' + kind }, [
				(kind == 'run') ? E('span', { 'class': 'wwe-spin' }) : E('span', {}, icon),
				E('span', {}, text),
			]);
		};

		var renderPanel = function(st, mode) {
			panel.style.display = '';
			var a = parseActivity(st.log);
			var running = (st.state == 'running');
			var kids = [];

			if (mode == 'download') {
				var doneN = 0;
				var lastSeen = a.order.length ? a.order[a.order.length - 1] : null;
				var items = DL_STEPS.map(function(s) {
					var isDone = !!a.seen[s[0]];
					if (isDone) doneN++;
					var isCur = running && !a.cancelled && a.code === null && s[0] == lastSeen;
					var cls = isDone ? (isCur ? 'wwe-step cur' : 'wwe-step done') : 'wwe-step';
					return E('li', { 'class': cls }, [
						E('span', { 'class': 'ic' }, isDone ? (isCur ? '⟳' : '✓') : '○'),
						E('span', {}, s[1]),
					]);
				});
				// install acknowledgement to the operator (auto_notify) — its
				// state comes from the daemon phase, not an lpac progress token
				var ackDone = (st.notified === true);
				var ackCur = running && st.phase == 'notify';
				items.push(E('li', { 'class': ackDone ? 'wwe-step done' : (ackCur ? 'wwe-step cur' : 'wwe-step') }, [
					E('span', { 'class': 'ic' }, ackDone ? '✓' : (ackCur ? '⟳' : '○')),
					E('span', {}, _('Confirm install to operator')),
				]));

				var pct = Math.round(doneN / DL_STEPS.length * 100);
				var barcls = 'wwe-bar' + (a.code === 0 ? ' ok'
					: (!running && (a.code !== null || a.cancelled)) ? ' err' : '');
				kids.push(E('ul', { 'class': 'wwe-steps' }, items));
				kids.push(E('div', { 'class': barcls }, E('span', { 'style': 'width:' + pct + '%' })));
			}

			if (running)
				kids.push(mkBanner('run', '', mode == 'download' ? _('Downloading profile…') : _('Contacting operator…')));
			else if (a.code === 0 && !a.cancelled)
				kids.push(mkBanner('ok', '✓', mode != 'download' ? _('Done.')
					: (st.notified === false
						? _('Profile downloaded (install not yet confirmed to the operator).')
						: _('Profile downloaded and confirmed — the eUICC will re-initialise.'))));
			else
				kids.push(mkBanner('err', '✕', a.msg || _('The operation failed.')));

			if (st.log)
				kids.push(E('details', { 'class': 'wwe-det' }, [
					E('summary', {}, _('Show raw lpac log')),
					E('pre', { 'class': 'wwe-log' }, st.log),
				]));

			dom.content(panel, kids);
		};

		var pollStatus = function(mode) {
			callEsim(data.modem, 'download_status', 0, '', '', '').then(function(st) {
				renderPanel(st, mode);
				if (st.state == 'running')
					window.setTimeout(function() { pollStatus(mode) }, 1200);
				else if (mode == 'download' && parseActivity(st.log).code === 0)
					window.setTimeout(function() { window.location.reload() }, 3000);
			});
		};

		var startBusy = function(text) {
			panel.style.display = '';
			dom.content(panel, mkBanner('run', '', text));
		};

		var dlHint = (data.esim.backend == 'at')
			? _('The modem downloads over its own network attach — no router data path or APN needed.')
			: _('lpac downloads on the router over your uplink and relays the eUICC APDUs through wwand — no dedicated modem APN needed.');

		out.push(E('h4', {}, _('Download profile')));
		out.push(E('p', {}, E('em', {}, dlHint)));

		var codeIn = E('input', { 'type': 'text', 'class': 'cbi-input-text',
			'style': 'width:min(440px,72%);margin-right:6px',
			'placeholder': 'LPA:1$rsp.example.com$MATCHING-ID' });
		var confIn = E('input', { 'type': 'text', 'class': 'cbi-input-text',
			'style': 'width:min(240px,42%);margin-right:6px',
			'placeholder': _('confirmation code (optional)') });
		var ackChk = E('input', { 'type': 'checkbox', 'checked': 'checked', 'style': 'margin:0 5px 0 0' });

		out.push(E('div', { 'class': 'cbi-section' }, [
			E('div', { 'style': 'margin-bottom:8px' }, [ codeIn, confIn,
				E('button', { 'class': 'btn cbi-button cbi-button-apply',
					'click': ui.createHandlerFn(self, function() {
						if (!(codeIn.value || '').trim()) {
							ui.addNotification(null, E('p', _('Enter an activation code first.')), 'warning');
							return;
						}
						startBusy(_('Starting download…'));
						return callEsim(data.modem, 'download', 0, '', codeIn.value, confIn.value, ackChk.checked).then(function(res) {
							if (res && res.ok === false)
								dom.content(panel, mkBanner('err', '✕', _('Could not start: ') + (res.error || '?')));
							else
								pollStatus('download');
						});
					}) }, _('Download')),
			]),
			E('label', { 'style': 'display:inline-flex;align-items:center;font-weight:normal;color:var(--fg-color-2,#666)' }, [
				ackChk, _('Confirm the install to the operator automatically (recommended; uncheck only for testing)'),
			]),
			panel,
		]));

		// pending eUICC notifications: confirm the download/enable/disable to
		// the operator's SM-DP+ (ES9+). Can be done any time the router has
		// internet — lpac delivers the queued notifications.
		out.push(E('h4', {}, _('Provider confirmations (notifications)')));
		out.push(E('p', {}, E('em', {}, _('After a download or profile change the eUICC queues notifications that confirm the operation to the operator. Send them once the router has internet.'))));
		out.push(E('div', { 'class': 'cbi-section' }, [
			E('button', { 'class': 'btn cbi-button',
				'click': ui.createHandlerFn(self, function() {
					startBusy(_('Listing pending notifications…'));
					return callEsim(data.modem, 'notifications', 0, '', '', '').then(function(r) {
						panel.style.display = '';
						dom.content(panel, [
							mkBanner((r && r.ok) ? 'ok' : 'err', (r && r.ok) ? '✓' : '✕',
								(r && r.log && r.log.trim()) ? _('Pending notifications:') : _('No pending notifications.')),
							(r && r.log && r.log.trim())
								? E('pre', { 'class': 'wwe-log' }, r.log) : '',
						]);
					});
				}) }, _('List pending')),
			' ',
			E('button', { 'class': 'btn cbi-button cbi-button-apply',
				'click': ui.createHandlerFn(self, function() {
					if (!confirm(_('Send all pending notifications to the operator now?')))
						return;
					startBusy(_('Sending confirmations…'));
					return callEsim(data.modem, 'notify', 0, '', '', '').then(function(res) {
						if (res && res.ok === false)
							dom.content(panel, mkBanner('err', '✕', _('Failed: ') + (res.error || '?')));
						else
							pollStatus('notify');
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
