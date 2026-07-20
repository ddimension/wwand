'use strict';
'require rpc';
'require dom';
'require form';
'require network';
'require wwand.bands as bands';

/* Talk to the wwand daemon directly over ubus (it exposes the 'wwand'
   object). Read-only queries only; interface configuration is written to
   /etc/config/network via the normal uci path. */
var callStatus = rpc.declare({
	object: 'wwand',
	method: 'status',
	expect: { modems: {} }
});

var callSignal = rpc.declare({
	object: 'wwand',
	method: 'modem_signal',
	params: [ 'modem' ],
	expect: { }
});

var callCells = rpc.declare({
	object: 'wwand',
	method: 'modem_cells',
	params: [ 'modem' ],
	expect: { }
});

/* Fallback enumeration of control devices, like the stock qmi/ncm handlers */
var callFileList = rpc.declare({
	object: 'file',
	method: 'list',
	params: [ 'path' ],
	expect: { entries: [] },
	filter: function(list, params) {
		var rv = [];
		for (var i = 0; i < list.length; i++)
			if (list[i].name.match(/^cdc-wdm/))
				rv.push(params.path + list[i].name);
		return rv.sort();
	}
});

/* Band/frequency helpers live in the shared wwand.bands module (single
   source of truth across the proto handler and the status page). */
var lteEarfcn = function(earfcn) { return bands.lteEarfcn(earfcn); };
var nrArfcn = function(arfcn) { return bands.nrArfcn(arfcn); };

/* Find the wwand modem that owns a given l3 interface device: the modem's
   netdev (wwan0) is a prefix of the interface device (wwan0m1). */
function pickModem(modems, netdev) {
	var names = Object.keys(modems || {});
	if (!names.length)
		return null;
	if (netdev) {
		for (var i = 0; i < names.length; i++) {
			var nd = modems[names[i]].netdev;
			if (nd && (netdev == nd || netdev.indexOf(nd) == 0))
				return names[i];
		}
	}
	for (var j = 0; j < names.length; j++)
		if (modems[names[j]].state == 'READY')
			return names[j];
	return names[0];
}

function tbl(rows) {
	return E('table', { 'class': 'table' }, rows.map(function(r) {
		return E('tr', { 'class': 'tr' }, [
			E('td', { 'class': 'td left', 'width': '33%' }, r[0]),
			E('td', { 'class': 'td left' }, r[1])
		]);
	}));
}

/* Compact modem/registration/signal summary for the general tab. */
function renderStatus(netdev) {
	return L.resolveDefault(callStatus(), {}).then(function(modems) {
		var name = pickModem(modems, netdev);
		if (!name)
			return E('em', {}, _('wwand daemon not running or no modem present'));

		var modem = modems[name];
		return Promise.all([
			L.resolveDefault(callSignal(name), {}),
			L.resolveDefault(callCells(name), {})
		]).then(function(res) {
			var sig = res[0] || {}, cells = (res[1] || {}).cells || {};
			var reg = modem.registration || {};
			var rows = [];

			rows.push([ _('Modem'), '%s%s'.format(modem.model || '?',
				modem.imei ? ' / IMEI %s'.format(modem.imei) : '') ]);
			rows.push([ _('State'), modem.state || '?' ]);

			var plmn = reg.plmn;
			if (plmn)
				rows.push([ _('Operator'), '%s (%s/%s)%s'.format(
					(plmn.description || '').trim(), plmn.mcc, plmn.mnc,
					reg.roaming ? ' — ' + _('roaming') : '') ]);
			rows.push([ _('Registration'),
				(reg.registration == 1) ? _('registered') : _('searching') ]);

			var lte = sig.lte;
			if (lte && lte.rsrp != null && lte.rsrp > -32768)
				rows.push([ _('LTE signal'), 'RSRP %d dBm · RSRQ %d dB · SNR %s dB · RSSI %d dBm'.format(
					lte.rsrp, lte.rsrq, (lte.snr/10).toFixed(1), lte.rssi) ]);
			var nr = sig.nr5g;
			if (nr && nr.rsrp != null && nr.rsrp > -32768)
				rows.push([ _('5G signal'), 'RSRP %d dBm · SNR %s dB'.format(
					nr.rsrp, (nr.snr/10).toFixed(1)) ]);

			var lc = cells.lte_intra;
			if (lc) {
				var ef = lteEarfcn(lc.earfcn);
				rows.push([ _('Serving cell'), 'LTE %s%s · EARFCN %d · PCI %d · TAC %d'.format(
					ef ? ef.band : '?', ef ? ' (%s MHz)'.format(ef.mhz.toFixed(1)) : '',
					lc.earfcn, lc.serving_cell_id, lc.tac) ]);
			}

			return tbl(rows);
		});
	}).catch(function() { return E('em', {}, _('status unavailable')); });
}

/* A small "add to lock" button. onAdd(kind, value, section_id, btn) writes the
   value into the lock_4g list / lock_5g field. Returns '' when no handler is
   wired (e.g. the read-only status tab), so the same renderer serves both. */
function lockBtn(onAdd, section_id, kind, value, label) {
	if (!onAdd || value == null)
		return '';
	return E('button', {
		'class': 'btn cbi-button cbi-button-add',
		'style': 'margin-left:8px;padding:1px 8px',
		'title': _('Add %s to the cell lock').format(value),
		'click': function(ev) {
			ev.preventDefault();
			onAdd(kind, value, section_id, ev.currentTarget);
		}
	}, label || _('+ Lock'));
}

/* Detailed cell environment for the cell-lock tab: current serving + 5G cell
   and the neighbour list with signal, so the user can see which
   EARFCN:PCI / 5G cell to lock to. When onAdd is given, each candidate gets a
   button that appends its lock value to the corresponding form field. */
function renderCellScan(netdev, onAdd, section_id) {
	return L.resolveDefault(callStatus(), {}).then(function(modems) {
		var name = pickModem(modems, netdev);
		if (!name)
			return E('em', {}, _('no modem'));

		return Promise.all([
			L.resolveDefault(callSignal(name), {}),
			L.resolveDefault(callCells(name), {})
		]).then(function(res) {
			var sig = res[0] || {}, cells = (res[1] || {}).cells || {};
			var out = [];
			var lc = cells.lte_intra;
			var fmt = function(x, unit) { return (x == null) ? '—' : x + (unit || ''); };
			var mhz = function(f) { return (f == null) ? '—' : f.mhz.toFixed(1) + ' MHz'; };

			if (lc) {
				var ef = lteEarfcn(lc.earfcn);
				var srv = null;
				(lc.cells || []).forEach(function(c) { if (c.pci == lc.serving_cell_id) srv = c; });
				var srvLock = '%d:%d'.format(lc.earfcn, lc.serving_cell_id);

				out.push(E('p', {}, E('strong', {}, _('LTE serving cell'))));
				out.push(tbl([
					[ _('Technology'), 'LTE' ],
					[ _('Band'), ef ? ef.band : '—' ],
					[ _('Frequency'), mhz(ef) ],
					[ _('Bandwidth'), fmt(lc.bandwidth != null ? (lc.bandwidth/1000 + ' MHz') : null) ],
					[ _('EARFCN'), '' + lc.earfcn ],
					[ _('PCI'), E('span', {}, [
						'%d  →  '.format(lc.serving_cell_id), E('code', {}, srvLock),
						lockBtn(onAdd, section_id, '4g', srvLock, _('Lock this cell')) ]) ],
					[ _('Signal'), 'RSRP %s · RSRQ %s · SNR %s · RSSI %s'.format(
						srv ? (srv.rsrp/10).toFixed(1) + ' dBm' : (sig.lte ? sig.lte.rsrp + ' dBm' : '—'),
						srv ? (srv.rsrq/10).toFixed(1) + ' dB' : (sig.lte ? sig.lte.rsrq + ' dB' : '—'),
						sig.lte ? (sig.lte.snr/10).toFixed(1) + ' dB' : '—',
						sig.lte ? sig.lte.rssi + ' dBm' : '—') ]
				]));

				var neigh = (lc.cells || []).filter(function(c) { return c.pci != lc.serving_cell_id; });
				if (neigh.length) {
					out.push(E('p', {}, E('strong', {}, _('LTE neighbour cells (lock candidates)'))));
					out.push(E('table', { 'class': 'table' }, [
						E('tr', { 'class': 'tr table-titles' }, [
							E('th', { 'class': 'th' }, 'PCI'),
							E('th', { 'class': 'th' }, 'RSRP'),
							E('th', { 'class': 'th' }, 'RSRQ'),
							E('th', { 'class': 'th' }, _('lock value')),
							E('th', { 'class': 'th', 'style': 'width:1%' }, '')
						])
					].concat(neigh.map(function(c) {
						var v = '%d:%d'.format(lc.earfcn, c.pci);
						return E('tr', { 'class': 'tr' }, [
							E('td', { 'class': 'td' }, '' + c.pci),
							E('td', { 'class': 'td' }, '%s dBm'.format((c.rsrp/10).toFixed(1))),
							E('td', { 'class': 'td' }, '%s dB'.format((c.rsrq/10).toFixed(1))),
							E('td', { 'class': 'td' }, E('code', {}, v)),
							E('td', { 'class': 'td' }, lockBtn(onAdd, section_id, '4g', v))
						]);
					}))));
				}
			}

			var nc = cells.nr5g_cell;
			if (nc) {
				var nf = nrArfcn(cells.nr5g_arfcn);
				/* lock_5g format: pci:arfcn:scs:band. QMI gives pci + arfcn;
				   band is inferred from the ARFCN, scs defaults to 1 (30 kHz,
				   the usual FR1 spacing) — the user should verify both. */
				var nrBand = (nf && nf.band) ? nf.band.replace(/^n/, '') : null;
				var nrLock = (cells.nr5g_arfcn != null && nrBand != null)
					? '%d:%d:1:%s'.format(nc.pci, cells.nr5g_arfcn, nrBand) : null;

				out.push(E('p', {}, E('strong', {}, _('5G NR cell'))));
				out.push(tbl([
					[ _('Technology'), '5G NR' ],
					[ _('Band'), nf && nf.band ? nf.band : '—' ],
					[ _('Frequency'), mhz(nf) ],
					[ _('Bandwidth'), fmt(nc.bandwidth != null ? (nc.bandwidth/1000 + ' MHz') : null) ],
					[ _('ARFCN'), '' + (cells.nr5g_arfcn || '?') ],
					[ _('PCI'), E('span', {}, [
						'' + nc.pci,
						nrLock ? E('span', {}, [ '   →  ', E('code', {}, nrLock),
							lockBtn(onAdd, section_id, '5g', nrLock, _('Lock this 5G cell')) ]) : '' ]) ],
					[ _('Signal'), 'RSRP %s dBm · RSRQ %s dB · SNR %s dB'.format(
						(nc.rsrp/10).toFixed(1), (nc.rsrq/10).toFixed(1), (nc.snr/10).toFixed(1)) ]
				]));
				if (onAdd && nrLock)
					out.push(E('p', { 'style': 'color:#666;font-size:90%' },
						_('5G SA lock is only supported in standalone mode; the scs value defaults to 1 (30 kHz) and the band is inferred — verify both before applying.')));
			}

			if (!out.length)
				out.push(E('em', {}, _('no cell information (modem not registered yet)')));

			return E('div', {}, out);
		});
	}).catch(function() { return E('em', {}, _('cell scan unavailable')); });
}

/* A self-refreshing DummyValue driven by one of the render functions above.
   The 5s poll is registered once per element id to avoid stacking pollers
   across form re-renders. */
var _polled = {};
function liveField(s, tab, name, title, renderFn, onAdd) {
	var o = s.taboption(tab, form.DummyValue, name, title);
	o.load = function(section_id) {
		var elId = 'wwand-%s-%s'.format(name, section_id);
		var node = E('div', { 'id': elId }, E('em', {}, _('loading…')));
		var nd = o._netdev;
		var refresh = function() {
			return renderFn(nd, onAdd, section_id).then(function(content) {
				var cur = document.getElementById(elId);
				if (cur) dom.content(cur, content);
			});
		};
		refresh();
		if (!_polled[elId]) {
			_polled[elId] = true;
			L.Poll.add(refresh, 5);
		}
		return node;
	};
	return o;
}

network.registerPatternVirtual(/^qmi-.+$/);
network.registerErrorCode('NO_DAEMON',      _('wwand daemon is not running'));
network.registerErrorCode('CONNECT_FAILED', _('Connection attempt failed'));
network.registerErrorCode('PIN_FAILED',     _('SIM PIN error'));
network.registerErrorCode('NO_CONTEXT',     _('Context not found'));
network.registerErrorCode('NO_IFACE',       _('The interface could not be found'));

return network.registerProtocol('qmi', {
	getI18n: function() {
		return _('QMI/5G Cellular (wwand)');
	},

	getIfname: function() {
		return this._ubus('l3_device') || 'qmi-%s'.format(this.sid);
	},

	getPackageName: function() {
		return 'wwand';
	},

	isFloating: function() {
		return true;
	},

	isVirtual: function() {
		return true;
	},

	getDevices: function() {
		return null;
	},

	containsDevice: function(ifname) {
		return (network.getIfnameOf(ifname) == this.getIfname());
	},

	renderFormOptions: function(s) {
		var o, dev = this.getL3Device() || this.getDevice();
		var netdev = dev ? dev.getName() : null;

		s.tab('celllock', _('Cell Lock'), _('Lock the modem to specific radio cells. The current cell environment is shown below.'));

		/* ---- live status (top of general tab) ---- */
		o = liveField(s, 'general', '_status', _('Modem status'), renderStatus);
		o._netdev = netdev;

		/* ---- general ---- */
		o = s.taboption('general', form.Value, '_modem_device', _('Modem device'),
			_('Parent network device or /dev/cdc-wdmX. Mux child names like wwan0m1 are allowed.'));
		o.ucioption = 'device';
		o.rmempty = false;
		o.load = function(section_id) {
			return Promise.all([
				L.resolveDefault(callStatus(), {}),
				L.resolveDefault(callFileList('/dev/'), [])
			]).then(L.bind(function(res) {
				var modems = res[0] || {}, ctrls = res[1] || [];
				Object.keys(modems).forEach(L.bind(function(n) {
					var m = modems[n];
					if (m.netdev)
						this.value(m.netdev, '%s (%s%s)'.format(m.netdev,
							m.model || '?', m.imei ? ' / ' + m.imei : ''));
				}, this));
				ctrls.forEach(L.bind(function(d) { this.value(d); }, this));
				return form.Value.prototype.load.apply(this, [section_id]);
			}, this));
		};

		o = s.taboption('general', form.Value, 'apn', _('APN'),
			_('Leave empty for the default APN, or "#N" to use modem profile N as-is.'));

		o = s.taboption('general', form.ListValue, 'pdptype', _('PDP type'));
		o.default = 'ipv4v6';
		o.value('ipv4v6', _('IPv4 + IPv6'));
		o.value('ipv4', _('IPv4'));
		o.value('ipv6', _('IPv6'));

		o = s.taboption('general', form.Value, 'pincode', _('PIN'));
		o.datatype = 'and(uinteger,minlength(4),maxlength(8))';

		o = s.taboption('general', form.ListValue, 'auth', _('Authentication type'));
		o.default = 'none';
		o.value('none', _('None'));
		o.value('pap', 'PAP');
		o.value('chap', 'CHAP');
		o.value('both', 'PAP/CHAP');

		o = s.taboption('general', form.Value, 'username', _('PAP/CHAP username'));
		o.depends('auth', 'pap');
		o.depends('auth', 'chap');
		o.depends('auth', 'both');

		o = s.taboption('general', form.Value, 'password', _('PAP/CHAP password'));
		o.depends('auth', 'pap');
		o.depends('auth', 'chap');
		o.depends('auth', 'both');
		o.password = true;

		/* ---- advanced ---- */
		o = s.taboption('advanced', form.ListValue, 'modes', _('Radio technology'),
			_('Restrict the modem to certain radio access technologies.'));
		o.value('', _('Modem default'));
		o.value('all', _('All'));
		o.value('lte', 'LTE');
		o.value('nr5g', '5G NR');
		o.value('lte,nr5g', 'LTE + 5G NR');
		o.value('umts', 'UMTS');
		o.value('gsm', 'GSM');
		o.value('td-scdma', 'TD-SCDMA');
		o.value('cdma', 'CDMA');

		o = s.taboption('advanced', form.Value, 'mcc', _('MCC'),
			_('Mobile Country Code for manual network selection.'));
		o.datatype = 'uinteger';

		o = s.taboption('advanced', form.Value, 'mnc', _('MNC'),
			_('Mobile Network Code (requires MCC).'));
		o.datatype = 'uinteger';

		o = s.taboption('advanced', form.Value, 'mtu', _('Override MTU'));
		o.placeholder = dev ? (dev.getMTU() || 1500) : 1500;
		o.datatype = 'max(9200)';

		o = s.taboption('advanced', form.Flag, 'use_pushed_mtu', _('Use modem-pushed MTU'));
		o.default = '1';

		o = s.taboption('advanced', form.Flag, 'use_pushed_prefix', _('Use network-pushed IPv4 prefix'),
			_('Off (default): the IPv4 address is configured as /32 point-to-point.'));
		o.default = '0';

		o = s.taboption('advanced', form.Value, 'delay', _('Modem init delay'),
			_('Seconds to wait before initializing the modem.'));
		o.placeholder = '0';
		o.datatype = 'min(0)';

		o = s.taboption('advanced', form.Value, 'failreboot', _('Reboot after N failures'),
			_('Reboot the router after this many failed connection attempts (0 = never).'));
		o.placeholder = '100';
		o.datatype = 'uinteger';

		o = s.taboption('advanced', form.Value, 'zero_rx_timeout', _('Zero-RX timeout'),
			_('Restart the connection after this many seconds without received packets (0 = off).'));
		o.placeholder = '21600';
		o.datatype = 'uinteger';

		o = s.taboption('advanced', form.Flag, 'location', _('Enable GPS/location'));
		o.default = '0';

		o = s.taboption('advanced', form.DynamicList, 'at_init', _('Extra AT init commands'));
		o.placeholder = 'ATE0';

		o = s.taboption('advanced', form.Flag, 'defaultroute', _('Use default gateway'),
			_('If unchecked, no default route is configured.'));
		o.default = o.enabled;

		o = s.taboption('advanced', form.Value, 'metric', _('Use gateway metric'));
		o.placeholder = '0';
		o.datatype = 'uinteger';
		o.depends('defaultroute', '1');

		o = s.taboption('advanced', form.Flag, 'peerdns', _('Use DNS servers advertised by peer'));
		o.default = o.enabled;

		/* ---- cell lock (with live cell environment) ---- */
		/* Forward-declared so the cell-scan buttons (rendered first, clicked
		   later) can reach the lock widgets by the time the user clicks. */
		var lock4gOpt, lock5gOpt;
		var addToLock = function(kind, value, section_id, btn) {
			var opt = (kind == '5g') ? lock5gOpt : lock4gOpt;
			var el = opt && opt.getUIElement(section_id);
			if (!el) return;

			if (kind == '5g') {
				el.setValue(value);
			} else {
				var vals = el.getValue() || [];
				if (!Array.isArray(vals))
					vals = (vals != null && vals !== '') ? [ vals ] : [];
				if (vals.indexOf(value) < 0) {
					vals.push(value);
					el.setValue(vals);
				}
			}

			/* brief visual confirmation on the clicked button */
			if (btn) {
				var prev = btn.textContent;
				btn.textContent = '✓';
				btn.disabled = true;
				window.setTimeout(function() {
					btn.textContent = prev;
					btn.disabled = false;
				}, 1200);
			}
		};

		o = liveField(s, 'celllock', '_cellscan', _('Current cells'), renderCellScan, addToLock);
		o._netdev = netdev;

		lock4gOpt = s.taboption('celllock', form.DynamicList, 'lock_4g', _('LTE cell lock'),
			_('Lock to LTE cells, one entry "earfcn:pci" each (several entries = cell list). Use the "Lock" buttons above to add the current or a neighbour cell.'));
		lock4gOpt.placeholder = '1300:246';

		lock5gOpt = s.taboption('celllock', form.Value, 'lock_5g', _('5G NR SA cell lock'),
			_('Lock to a 5G SA cell: "pci:arfcn:scs:band". Use the "Lock this 5G cell" button above to prefill it from the current cell.'));
		lock5gOpt.placeholder = '242:431070:15:1';
		o = lock5gOpt;

		o = s.taboption('celllock', form.Flag, 'lock_persist', _('Persist lock in modem'),
			_('Store the cell lock in modem non-volatile memory.'));
		o.default = '0';
	}
});
