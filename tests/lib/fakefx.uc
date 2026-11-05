// wwand tests — fake effects object for netlink.uc datapath tests.
// Records every write/run in order and simulates the qmi_wwan sysfs
// behaviors the code depends on (add_mux creating qmimuxN interfaces).

'use strict';

export function create(opts)
{
	let self = {
		files: { ...(opts?.files ?? {}) },
		present: { ...(opts?.present ?? {}) },
		links: { ...(opts?.links ?? {}) },   // sysfs symlink targets (readlink)
		dirs: { ...(opts?.dirs ?? {}) },     // directory listings (lsdir)
		actions: [],
		rc: opts?.rc ?? {},        // 'ip link add ...' -> nonzero rc override
		qmimux_count: 0,
	};

	self.read = function(path) {
		return self.files[path] ?? null;
	};

	// sysfs helpers used by discovery.uc (readlink/lsdir/access)
	self.readlink = function(path) {
		return self.links[path] ?? null;
	};

	self.lsdir = function(path) {
		return self.dirs[path] ?? null;
	};

	self.access = function(path) {
		return self.present[path] == true || self.files[path] != null;
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

	// default_fx.write_atomic: a whole-file replace, recorded under its own
	// name so a test can tell it from an in-place write
	// `before_rename(path)`: a test's hook between the temporary's write and
	// the rename — where another process's append to `path` is lost
	self.write_atomic = function(path, data) {
		push(self.actions, sprintf('write_atomic %s %s', path, trim(data)));
		self.before_rename?.(path);
		self.files[path] = data;

		return true;
	};

	// default_fx.lock: an exclusive lock per path. `when_unlocked(path, fn)`
	// plays the other process — blocked while the lock is held, run at the
	// release, the way flock(1) waits for it.
	self.locks = {};
	self.lock_waiters = {};

	self.lock = function(path) {
		self.locks[path] = true;

		return () => {
			delete self.locks[path];

			let q = self.lock_waiters[path] ?? [];

			self.lock_waiters[path] = [];

			for (let fn in q)
				fn();
		};
	};

	self.when_unlocked = function(path, fn) {
		if (!self.locks[path])
			return fn();

		self.lock_waiters[path] ??= [];
		push(self.lock_waiters[path], fn);
	};

	self.link_del = function(name) {
		push(self.actions, sprintf('link_del %s', name));
		delete self.present[sprintf('/sys/class/net/%s', name)];

		return true;
	};

	self.exists = function(path) {
		if (self.present[path] == true)
			return true;

		// sysfs directories exist by virtue of their children — a driver that
		// exposes any `qmi/<attr>` also has the `qmi` group. Tests register the
		// attributes; deriving the parent here keeps them honest without
		// listing every directory by hand.
		let pfx = path + '/';

		for (let k in keys(self.present))
			if (self.present[k] == true && substr(k, 0, length(pfx)) == pfx)
				return true;

		for (let k in keys(self.files))
			if (substr(k, 0, length(pfx)) == pfx)
				return true;

		return false;
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

		if (o.noarp)
			push(parts, 'noarp');

		let action = sprintf('link_set %s %s', dev, join(' ', parts));

		push(self.actions, action);

		if (self.rc[action])
			return false;

		if (o.rename != null) {
			// the whole sysfs subtree follows a kernel netdev rename — move
			// every /sys/class/net/<dev>/... entry (attrs incl.), like the kernel
			let from = sprintf('/sys/class/net/%s', dev);
			let to = sprintf('/sys/class/net/%s', o.rename);

			for (let k in keys(self.present))
				if (k == from || index(k, from + '/') == 0) {
					self.present[to + substr(k, length(from))] = self.present[k];
					delete self.present[k];
				}

			for (let k in keys(self.files))
				if (index(k, from + '/') == 0) {
					self.files[to + substr(k, length(from))] = self.files[k];
					delete self.files[k];
				}

			// symlinks move with their netdev, and one that POINTS at it
			// reads the new name: kernfs builds the target from the current
			// names on every read (fs/kernfs/symlink.c:56-125, 6.18.41)
			for (let k in keys(self.links)) {
				let t = self.links[k];

				if (t == dev || substr(t, -(length(dev) + 1)) == '/' + dev)
					self.links[k] = substr(t, 0, length(t) - length(dev)) + o.rename;

				if (index(k, from + '/') == 0) {
					self.links[to + substr(k, length(from))] = self.links[k];
					delete self.links[k];
				}
			}

			self.present[to] = true;
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

		// the kernel refuses NLM_F_EXCL over an existing name; modelling that
		// here (rather than only through an rc override) is what makes the
		// adopt-then-recreate path testable — the same action must fail while
		// the link is there and succeed once it has been deleted
		if (self.present[sprintf('/sys/class/net/%s', name)]) {
			self.last_error = 'File exists';

			return false;
		}

		self.present[sprintf('/sys/class/net/%s', name)] = true;

		return true;
	};

	// netlink changelink of the QMAP flags on an EXISTING rmnet child — the
	// adopt path's format correction. Present here unconditionally because the
	// caller guards on it; an rc override drives the "kernel refused" branch.
	// Models the KERNEL's semantics, not the request: rmnet_changelink() applies
	// `data_format &= ~mask; data_format |= flags & mask`. Recording the
	// resulting format (not just the requested flags) is what lets a test catch
	// a mask too narrow to clear the previous version's bits.
	self.rmnet_data_format = opts?.rmnet_data_format ?? 0;

	self.rmnet_flags_set = function(name, mux_id, flags, mask) {
		let action = sprintf('rmnet_flags_set %s mux_id %d flags 0x%x mask 0x%x',
			name, mux_id ?? -1, flags ?? 0, mask ?? 0);

		push(self.actions, action);

		if (self.rc[action]) {
			self.last_error = 'mock: changelink refused';

			return false;
		}

		self.rmnet_data_format &= ~(mask ?? 0);
		self.rmnet_data_format |= (flags ?? 0) & (mask ?? 0);

		return true;
	};

	// ethtool TX-aggregation coalesce (uplink QMAP aggregation); records the
	// call, honors an rc override for the "unsupported" path
	self.rmnet_tx_aggr = function(name, bytes, frames, usecs) {
		let action = sprintf('rmnet_tx_aggr %s bytes %d frames %d usecs %d',
			name, bytes, frames, usecs);

		push(self.actions, action);

		return !self.rc[action];
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
