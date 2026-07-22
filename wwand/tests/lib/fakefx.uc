// wwand tests — fake effects object for netlink.uc datapath tests.
// Records every write/run in order and simulates the qmi_wwan sysfs
// behaviors the code depends on (add_mux creating qmimuxN interfaces).

'use strict';

export function create(opts)
{
	let self = {
		files: { ...(opts?.files ?? {}) },
		present: { ...(opts?.present ?? {}) },
		actions: [],
		rc: opts?.rc ?? {},        // 'ip link add ...' -> nonzero rc override
		qmimux_count: 0,
	};

	self.read = function(path) {
		return self.files[path] ?? null;
	};

	self.write = function(path, data) {
		push(self.actions, sprintf('write %s %s', path, trim(data)));
		self.files[path] = data;

		// simulate qmi_wwan creating qmimuxN on add_mux writes
		if (index(path, '/add_mux') >= 0) {
			let name = sprintf('qmimux%d', self.qmimux_count++);
			self.present[sprintf('/sys/class/net/%s', name)] = true;
			self.files[sprintf('/sys/class/net/%s/qmi/mux_id', name)] = trim(data);
		}

		return true;
	};

	self.exists = function(path) {
		return self.present[path] == true;
	};

	self.run = function(argv) {
		let cmd = join(' ', argv);

		push(self.actions, sprintf('run %s', cmd));

		if (self.rc[cmd] != null)
			return self.rc[cmd];

		// simulate link add / rename effects on the fake sysfs
		if (argv[0] == 'ip' && argv[1] == 'link') {
			if (argv[2] == 'add')
				self.present[sprintf('/sys/class/net/%s', argv[3])] = true;

			if (argv[2] == 'set' && argv[5] == 'name') {
				delete self.present[sprintf('/sys/class/net/%s', argv[4])];
				self.present[sprintf('/sys/class/net/%s', argv[6])] = true;
			}
		}

		return 0;
	};

	self.log = function(level, msg) {
		push(self.actions, sprintf('log %s %s', level, msg));
	};

	// native link operations mirroring default_fx (rtnl-based on target);
	// action strings double as rc-override keys
	self.link_set = function(dev, o) {
		let parts = [];

		if (o.up != null)
			push(parts, o.up ? 'up' : 'down');

		if (o.mtu != null)
			push(parts, sprintf('mtu %d', o.mtu));

		if (o.rename != null)
			push(parts, sprintf('name %s', o.rename));

		let action = sprintf('link_set %s %s', dev, join(' ', parts));

		push(self.actions, action);

		if (self.rc[action])
			return false;

		if (o.rename != null) {
			delete self.present[sprintf('/sys/class/net/%s', dev)];
			self.present[sprintf('/sys/class/net/%s', o.rename)] = true;
		}

		return true;
	};

	self.link_add_vlan = function(name, parent, vid) {
		let action = sprintf('link_add_vlan %s link %s id %d', name, parent, vid);

		push(self.actions, action);

		if (self.rc[action])
			return false;

		self.present[sprintf('/sys/class/net/%s', name)] = true;

		return true;
	};

	self.link_add_rmnet = function(name, parent, mux_id, flags) {
		let action = sprintf('link_add_rmnet %s link %s mux_id %d flags 0x%x',
			name, parent, mux_id, flags ?? 0);

		push(self.actions, action);

		if (self.rc[action])
			return false;

		self.present[sprintf('/sys/class/net/%s', name)] = true;

		return true;
	};

	// glob support: explicit pattern -> results map, with a generic fallback
	// matching wildcard patterns against the fake sysfs (present/files keys)
	self.globs = opts?.globs ?? {};

	self.glob = function(...patterns) {
		let out = [];

		for (let p in patterns) {
			if (self.globs[p] != null) {
				for (let r in self.globs[p])
					push(out, r);

				continue;
			}

			let re = regexp('^' + replace(replace(p, /[.^$+()]/g, '\\$&'), /\*/g, '[^/]*') + '$');

			for (let key in sort(keys(self.present)))
				if (self.present[key] && match(key, re))
					push(out, key);
		}

		return out;
	};

	// actions matching a substring, in order
	self.matching = function(needle) {
		return filter(self.actions, (a) => index(a, needle) >= 0);
	};

	// index of first action containing needle, -1 if none
	self.action_index = function(needle) {
		for (let i = 0; i < length(self.actions); i++)
			if (index(self.actions[i], needle) >= 0)
				return i;

		return -1;
	};

	return self;
}
