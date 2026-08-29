// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
/*
 * ucode-mod-wwand-io — minimal message-oriented I/O for wwand.
 *
 * Provides non-blocking open/read/write on QMI control character devices
 * (/dev/cdc-wdmX, where one read(2) returns exactly one QMUX message) and
 * raw tty access for AT commands. All protocol logic lives in ucode.
 *
 *   import * as qmit from 'wwand_io';
 *
 *   let h = qmit.open("/dev/cdc-wdm0");
 *   h.fileno();          // int, for uloop.handle()
 *   h.read();            // one message | null (EAGAIN) | false (device gone)
 *   h.write(buf);        // bytes written | false on error
 *   h.close();
 *
 *   let t = qmit.open_tty("/dev/ttyUSB2", 115200);
 *   qmit.last_error();   // string | null
 */

/* pipe2() */
#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <signal.h>
#include <stdio.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <linux/genetlink.h>

#include <ucode/module.h>

/* larger than max supported QMAP aggregation size (31 KiB) + QMUX header */
#define QMIT_READ_BUFSIZE (32 * 1024)

static uc_resource_type_t *transport_type;
static int last_errno;

typedef struct {
	int fd;       /* primary/read fd (nonblock): device, or a child's stdout */
	int wfd;      /* spawn: write fd to the child's stdin; -1 for devices */
	int pid;      /* spawn: child pid (reaped on close); -1 for devices */
	bool is_tty;
} wwand_io_t;

static uc_value_t *
qmit_last_error(uc_vm_t *vm, size_t nargs)
{
	if (!last_errno)
		return NULL;

	return ucv_string_new(strerror(last_errno));
}

static wwand_io_t *
qmit_this(uc_vm_t *vm)
{
	wwand_io_t **tp = uc_fn_this("wwand.io");

	return (tp && *tp) ? *tp : NULL;
}

static uc_value_t *
qmit_open_common(uc_vm_t *vm, const char *path, bool is_tty, int baud)
{
	wwand_io_t *t;
	int fd;

	last_errno = 0;

	fd = open(path, O_RDWR | O_NONBLOCK | O_NOCTTY | O_CLOEXEC);

	if (fd < 0) {
		last_errno = errno;

		return NULL;
	}

	if (is_tty) {
		struct termios tio;
		speed_t speed;

		if (tcgetattr(fd, &tio) < 0) {
			last_errno = errno;
			close(fd);

			return NULL;
		}

		cfmakeraw(&tio);
		tio.c_cflag |= CLOCAL | CREAD;
		tio.c_cflag &= ~CRTSCTS;
		tio.c_cc[VMIN] = 0;
		tio.c_cc[VTIME] = 0;

		switch (baud) {
		case 9600:    speed = B9600;    break;
		case 19200:   speed = B19200;   break;
		case 38400:   speed = B38400;   break;
		case 57600:   speed = B57600;   break;
		case 0:
		case 115200:  speed = B115200;  break;
		case 230400:  speed = B230400;  break;
		case 460800:  speed = B460800;  break;
		case 921600:  speed = B921600;  break;
		default:
			last_errno = EINVAL;
			close(fd);

			return NULL;
		}

		cfsetispeed(&tio, speed);
		cfsetospeed(&tio, speed);

		if (tcsetattr(fd, TCSANOW, &tio) < 0) {
			last_errno = errno;
			close(fd);

			return NULL;
		}

		tcflush(fd, TCIOFLUSH);
	}

	t = calloc(1, sizeof(*t));

	if (!t) {
		last_errno = ENOMEM;
		close(fd);

		return NULL;
	}

	t->fd = fd;
	t->wfd = -1;
	t->pid = -1;
	t->is_tty = is_tty;

	return uc_resource_new(transport_type, t);
}

static void
free_argv(char **args)
{
	size_t k;

	if (!args)
		return;

	for (k = 0; args[k]; k++)
		free(args[k]);

	free(args);
}

/*
 * spawn(argv) — fork/exec argv[] with the child's stdin and stdout wired to
 * pipes; the child's stderr is inherited (redirect it in the argv via a shell
 * if needed). The returned handle reads (non-blocking) the child's stdout and
 * writes to its stdin, so a uloop.handle() drain loop can bridge a line
 * protocol without ever blocking the daemon. close() reaps the child and
 * returns its exit status.
 */
static uc_value_t *
qmit_spawn(uc_vm_t *vm, size_t nargs)
{
	uc_value_t *argv = uc_fn_arg(0);
	wwand_io_t *t;
	char **args;
	size_t n, i;
	int in[2], out[2], fl;
	pid_t pid;

	last_errno = 0;

	if (ucv_type(argv) != UC_ARRAY || (n = ucv_array_length(argv)) == 0) {
		last_errno = EINVAL;

		return NULL;
	}

	args = calloc(n + 1, sizeof(*args));

	if (!args) {
		last_errno = ENOMEM;

		return NULL;
	}

	for (i = 0; i < n; i++) {
		uc_value_t *a = ucv_array_get(argv, i);

		/* strdup: ucv_string_get pointers are not stable across the fork */
		if (ucv_type(a) != UC_STRING || !(args[i] = strdup(ucv_string_get(a)))) {
			last_errno = (ucv_type(a) != UC_STRING) ? EINVAL : ENOMEM;
			free_argv(args);

			return NULL;
		}
	}

	/* O_CLOEXEC on both pipe ends at creation: the child's dup2() below clears
	 * it on the duped stdio fds (dup2 never copies FD_CLOEXEC), and every other
	 * end vanishes on execvp — so no pipe fd can leak into the child, nor into
	 * any other process this module ever spawns. */
	if (pipe2(in, O_CLOEXEC) < 0) {
		last_errno = errno;
		free_argv(args);

		return NULL;
	}

	if (pipe2(out, O_CLOEXEC) < 0) {
		last_errno = errno;
		close(in[0]);
		close(in[1]);
		free_argv(args);

		return NULL;
	}

	pid = fork();

	if (pid < 0) {
		last_errno = errno;
		close(in[0]);
		close(in[1]);
		close(out[0]);
		close(out[1]);
		free_argv(args);

		return NULL;
	}

	if (pid == 0) {
		/* Own process group. The command we spawn is a SHELL PIPELINE, so the
		 * shell forks the real worker (e.g. lpac, which in turn runs curl) and
		 * signalling the shell alone would orphan it. A group of our own lets
		 * kill() below take the whole tree — and costs nothing else here, as
		 * the daemon has no job control to inherit. */
		setpgid(0, 0);

		/* child: stdin <- in[0], stdout -> out[1], stderr inherited */
		if (dup2(in[0], STDIN_FILENO) < 0 ||
		    dup2(out[1], STDOUT_FILENO) < 0)
			_exit(127);
		close(in[0]);
		close(in[1]);
		close(out[0]);
		close(out[1]);
		execvp(args[0], args);
		_exit(127);
	}

	/* parent (pipe fds are already FD_CLOEXEC from pipe2) */

	/* also set the group from HERE: whichever side runs first wins, so a
	 * kill() right after spawn can never race the child's own setpgid() */
	setpgid(pid, pid);

	close(in[0]);
	close(out[1]);
	free_argv(args);

	fl = fcntl(out[0], F_GETFL, 0);
	fcntl(out[0], F_SETFL, (fl < 0 ? 0 : fl) | O_NONBLOCK);

	/* the write end is non-blocking too: a stalled child must never block the
	 * single-threaded uloop in write() */
	fl = fcntl(in[1], F_GETFL, 0);
	fcntl(in[1], F_SETFL, (fl < 0 ? 0 : fl) | O_NONBLOCK);

	t = calloc(1, sizeof(*t));

	if (!t) {
		last_errno = ENOMEM;
		close(out[0]);
		close(in[1]);
		/* nobody holds the pid anymore — terminate and reap the child so it
		 * neither runs on detached nor lingers as a zombie */
		kill(pid, SIGTERM);
		while (waitpid(pid, NULL, 0) < 0 && errno == EINTR)
			;

		return NULL;
	}

	t->fd = out[0];
	t->wfd = in[1];
	t->pid = pid;
	t->is_tty = false;

	return uc_resource_new(transport_type, t);
}

static uc_value_t *
qmit_open(uc_vm_t *vm, size_t nargs)
{
	uc_value_t *path = uc_fn_arg(0);

	if (ucv_type(path) != UC_STRING) {
		last_errno = EINVAL;

		return NULL;
	}

	return qmit_open_common(vm, ucv_string_get(path), false, 0);
}

static uc_value_t *
qmit_open_tty(uc_vm_t *vm, size_t nargs)
{
	uc_value_t *path = uc_fn_arg(0);
	uc_value_t *baud = uc_fn_arg(1);

	if (ucv_type(path) != UC_STRING ||
	    (baud && ucv_type(baud) != UC_INTEGER)) {
		last_errno = EINVAL;

		return NULL;
	}

	return qmit_open_common(vm, ucv_string_get(path), true,
	                        baud ? (int)ucv_int64_get(baud) : 0);
}

static uc_value_t *
qmit_read(uc_vm_t *vm, size_t nargs)
{
	wwand_io_t *t = qmit_this(vm);
	char buf[QMIT_READ_BUFSIZE];
	ssize_t r;

	last_errno = 0;

	if (!t || t->fd < 0) {
		last_errno = EBADF;

		return ucv_boolean_new(false);
	}

	do {
		r = read(t->fd, buf, sizeof(buf));
	} while (r < 0 && errno == EINTR);

	if (r > 0)
		return ucv_string_new_length(buf, (size_t)r);

	if (r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
		return NULL;

	/* r == 0 (EOF) or hard error: device is gone */
	if (r < 0)
		last_errno = errno;

	return ucv_boolean_new(false);
}

static uc_value_t *
qmit_write(uc_vm_t *vm, size_t nargs)
{
	wwand_io_t *t = qmit_this(vm);
	uc_value_t *data = uc_fn_arg(0);
	const char *p;
	size_t len, off = 0;
	ssize_t w;
	int wfd;

	last_errno = 0;

	if (!t || ucv_type(data) != UC_STRING) {
		last_errno = (ucv_type(data) != UC_STRING) ? EINVAL : EBADF;

		return ucv_boolean_new(false);
	}

	/* spawn handles write to the child's stdin; devices write to their fd */
	wfd = (t->wfd >= 0) ? t->wfd : t->fd;

	if (wfd < 0) {
		last_errno = EBADF;

		return ucv_boolean_new(false);
	}

	p = ucv_string_get(data);
	len = ucv_string_length(data);

	while (off < len) {
		w = write(wfd, p + off, len - off);

		if (w < 0) {
			if (errno == EINTR)
				continue;

			last_errno = errno;

			if (errno == EAGAIN || errno == EWOULDBLOCK) {
				/* partial tty writes are resumable by the caller */
				if (off)
					break;

				/* nothing written, would block: null — "try again",
				 * distinct from false = hard error (mirrors read()). A
				 * hard EIO must not be retried forever as congestion. */
				return NULL;
			}

			return ucv_boolean_new(false);
		}

		off += (size_t)w;
	}

	return ucv_int64_new((int64_t)off);
}

static uc_value_t *
qmit_fileno(uc_vm_t *vm, size_t nargs)
{
	wwand_io_t *t = qmit_this(vm);

	if (!t || t->fd < 0)
		return NULL;

	return ucv_int64_new(t->fd);
}

static uc_value_t *
qmit_flush(uc_vm_t *vm, size_t nargs)
{
	wwand_io_t *t = qmit_this(vm);

	if (!t || t->fd < 0)
		return ucv_boolean_new(false);

	if (t->is_tty)
		tcflush(t->fd, TCIOFLUSH);

	return ucv_boolean_new(true);
}

static uc_value_t *
qmit_close(uc_vm_t *vm, size_t nargs)
{
	wwand_io_t *t = qmit_this(vm);
	int status = 0;

	if (t) {
		if (t->fd >= 0) {
			close(t->fd);
			t->fd = -1;
		}

		if (t->wfd >= 0) {
			close(t->wfd);
			t->wfd = -1;
		}

		/* spawn: reap the child WITHOUT blocking. close() runs on the single
		 * uloop; a blocking waitpid() would freeze the daemon (no status, no
		 * events) if the child closed stdout but lingers. WNOHANG only: if the
		 * child hasn't exited yet, uloop's SIGCHLD handler reaps it later
		 * (waitpid(-1)), so no zombie. The status is then UNKNOWN (also when
		 * that reaper already collected it, ECHILD) -> return null; callers
		 * needing the real code carry it in-band (esim_bridge's __EXIT marker). */
		if (t->pid > 0) {
			pid_t r;

			while ((r = waitpid(t->pid, &status, WNOHANG)) < 0 && errno == EINTR)
				;
			t->pid = -1;

			if (r <= 0)
				return NULL;

			return ucv_int64_new(WIFEXITED(status) ? WEXITSTATUS(status) : -1);
		}
	}

	return ucv_boolean_new(true);
}

static void
qmit_free(void *ptr)
{
	wwand_io_t *t = ptr;

	if (t) {
		if (t->fd >= 0)
			close(t->fd);

		if (t->wfd >= 0)
			close(t->wfd);

		/* a spawn handle GC'd without close(): try to reap; only signal a
		 * child that is provably still ours. Probing with WNOHANG first
		 * matters twice: (a) if uloop's SIGCHLD handler already reaped it,
		 * the pid may be RECYCLED — a blind kill() would signal an unrelated
		 * process; (b) a blocking waitpid() on an ignoring child would hang
		 * the single-threaded uloop. If it still runs after SIGTERM, uloop's
		 * global reaper collects it on exit — no zombie either way. */
		if (t->pid > 0) {
			int status;
			pid_t r;

			while ((r = waitpid(t->pid, &status, WNOHANG)) < 0 && errno == EINTR)
				;

			if (r == 0) {
				/* the group (see setpgid in spawn), so a shell's
				 * worker child goes down with it */
				if (kill(-t->pid, SIGTERM) < 0)
					kill(t->pid, SIGTERM);

				while (waitpid(t->pid, &status, WNOHANG) < 0 && errno == EINTR)
					;
			}
		}

		free(t);
	}
}

/*
 * h.kill([signal]) -> true when the child was signalled
 *
 * Terminate a still-running spawn child. close() deliberately does NOT do this
 * (it only closes the pipes and reaps without blocking), which is right for the
 * normal path where the child has already exited — but closing the pipes does
 * not stop a child that is blocked elsewhere: an lpac waiting on curl in a dead
 * TCP connection keeps running after an aborted run. Callers that abort a run
 * (a watchdog firing) must say so explicitly.
 *
 * The whole process GROUP is signalled (see setpgid() in spawn): the direct
 * child is a shell, and the worker it forked is the process that actually
 * hangs.
 *
 * Probed with WNOHANG first for the same reason as the destructor: once uloop's
 * SIGCHLD handler has reaped the child, the pid may be RECYCLED and a blind
 * kill() would hit an unrelated process. r != 0 therefore means "already gone,
 * nothing to signal", not a failure to report.
 */
static uc_value_t *
qmit_kill(uc_vm_t *vm, size_t nargs)
{
	wwand_io_t *t = qmit_this(vm);
	uc_value_t *sig = uc_fn_arg(0);
	int s = (ucv_type(sig) == UC_INTEGER) ? (int)ucv_int64_get(sig) : SIGTERM;
	int status;
	pid_t r;

	last_errno = 0;

	if (!t || t->pid <= 0)
		return ucv_boolean_new(false);

	while ((r = waitpid(t->pid, &status, WNOHANG)) < 0 && errno == EINTR)
		;

	if (r != 0) {
		t->pid = -1;

		return ucv_boolean_new(false);
	}

	if (kill(-t->pid, s) < 0 && kill(t->pid, s) < 0) {
		last_errno = errno;

		return ucv_boolean_new(false);
	}

	return ucv_boolean_new(true);
}

static const uc_function_list_t transport_fns[] = {
	{ "read",   qmit_read },
	{ "write",  qmit_write },
	{ "fileno", qmit_fileno },
	{ "flush",  qmit_flush },
	{ "close",  qmit_close },
	{ "kill",   qmit_kill },
};

/*
 * rmnet link creation with IFLA_RMNET_FLAGS (deaggregation, MAPv5 checksum
 * offload). The generic ucode rtnl module cannot encode this attribute, so
 * it lives here as a small raw-netlink helper.
 *
 *   qmit.rmnet_add("wwan0m1", "wwan0", 1, flags)
 *     flags: RMNET_FLAGS_* bitmask (e.g. 0x01 deagg, 0x31 deagg+cksum v5)
 */

#ifndef IFLA_RMNET_MAX
enum {
	IFLA_RMNET_UNSPEC,
	IFLA_RMNET_MUX_ID,
	IFLA_RMNET_FLAGS,
	__IFLA_RMNET_MAX,
};

struct ifla_rmnet_flags {
	uint32_t flags;
	uint32_t mask;
};
#endif

static struct rtattr *
nla_begin(struct nlmsghdr *nlh, size_t maxlen, unsigned short type)
{
	struct rtattr *rta = (struct rtattr *)((char *)nlh + NLMSG_ALIGN(nlh->nlmsg_len));

	if (NLMSG_ALIGN(nlh->nlmsg_len) + RTA_LENGTH(0) > maxlen)
		return NULL;

	rta->rta_type = type;
	rta->rta_len = RTA_LENGTH(0);
	nlh->nlmsg_len = NLMSG_ALIGN(nlh->nlmsg_len) + RTA_LENGTH(0);

	return rta;
}

static void
nla_end(struct nlmsghdr *nlh, struct rtattr *rta)
{
	rta->rta_len = (char *)nlh + NLMSG_ALIGN(nlh->nlmsg_len) - (char *)rta;
}

static bool
nla_put(struct nlmsghdr *nlh, size_t maxlen, unsigned short type,
        const void *data, size_t len)
{
	struct rtattr *rta = nla_begin(nlh, maxlen, type);

	if (!rta || NLMSG_ALIGN(nlh->nlmsg_len) + RTA_ALIGN(len) > maxlen)
		return false;

	rta->rta_len = RTA_LENGTH(len);
	memcpy(RTA_DATA(rta), data, len);
	nlh->nlmsg_len = NLMSG_ALIGN(nlh->nlmsg_len) + RTA_ALIGN(len);

	return true;
}

/* recv a netlink reply, retrying on EINTR (plain recv() here would miss the
 * ACK on a signal and the caller would misreport the operation). A receive
 * timeout guards the single-threaded uloop: the kernel answers these requests
 * synchronously, but a driver/rmnet in a bad state could otherwise leave the
 * daemon blocked in recv() forever (no status, no events). On timeout recv
 * returns EAGAIN and the caller sees a short read -> clean failure. */
static ssize_t
nl_recv(int fd, void *buf, size_t len)
{
	struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
	ssize_t r;

	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

	do {
		r = recv(fd, buf, len, 0);
	} while (r < 0 && errno == EINTR);

	return r;
}

static uc_value_t *
qmit_rmnet_add(uc_vm_t *vm, size_t nargs)
{
	uc_value_t *name = uc_fn_arg(0);
	uc_value_t *parent = uc_fn_arg(1);
	uc_value_t *mux_id = uc_fn_arg(2);
	uc_value_t *flags = uc_fn_arg(3);

	struct {
		struct nlmsghdr nlh;
		struct ifinfomsg ifi;
		char buf[512];
	} req;

	struct rtattr *linkinfo, *infodata;
	struct ifla_rmnet_flags rf;
	struct sockaddr_nl sa = { .nl_family = AF_NETLINK };
	unsigned int parent_idx;
	uint16_t mux;
	/* union: guarantees nlmsghdr alignment of the recv buffer (a plain char
	 * array is unaligned-cast UB and traps into the kernel fixup on mips) */
	union { char b[1024]; struct nlmsghdr h; } resp;
	ssize_t rlen;
	int fd, err;

	last_errno = 0;

	if (ucv_type(name) != UC_STRING || ucv_type(parent) != UC_STRING ||
	    ucv_type(mux_id) != UC_INTEGER) {
		last_errno = EINVAL;

		return ucv_boolean_new(false);
	}

	/* IFLA_RMNET_MUX_ID is a u16 on the wire but a QMAP channel is 8 bit:
	 * the kernel rejects > RMNET_MAX_LOGICAL_EP - 1 (254) with -ERANGE.
	 * Refuse out-of-range here rather than let the cast below wrap it —
	 * 65537 would otherwise become a perfectly valid-looking channel 1 and
	 * silently collide with whatever really uses channel 1. */
	if (ucv_int64_get(mux_id) < 0 || ucv_int64_get(mux_id) > 254) {
		last_errno = ERANGE;

		return ucv_boolean_new(false);
	}

	parent_idx = if_nametoindex(ucv_string_get(parent));

	if (!parent_idx) {
		last_errno = ENODEV;

		return ucv_boolean_new(false);
	}

	memset(&req, 0, sizeof(req));
	req.nlh.nlmsg_len = NLMSG_LENGTH(sizeof(struct ifinfomsg));
	req.nlh.nlmsg_type = RTM_NEWLINK;
	req.nlh.nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE | NLM_F_EXCL;
	req.nlh.nlmsg_seq = 1;
	req.ifi.ifi_family = AF_UNSPEC;

	if (!nla_put(&req.nlh, sizeof(req), IFLA_IFNAME,
	             ucv_string_get(name), ucv_string_length(name) + 1) ||
	    !nla_put(&req.nlh, sizeof(req), IFLA_LINK, &parent_idx, sizeof(parent_idx))) {
		last_errno = EMSGSIZE;

		return ucv_boolean_new(false);
	}

	/* every nla_* checked: a long ifname can fill the tail so that a later
	 * nla_begin returns NULL — nla_end would then deref it */
	linkinfo = nla_begin(&req.nlh, sizeof(req), IFLA_LINKINFO);

	if (!linkinfo ||
	    !nla_put(&req.nlh, sizeof(req), IFLA_INFO_KIND, "rmnet", 6)) {
		last_errno = EMSGSIZE;

		return ucv_boolean_new(false);
	}

	infodata = nla_begin(&req.nlh, sizeof(req), IFLA_INFO_DATA);

	mux = (uint16_t)ucv_int64_get(mux_id);

	if (!infodata ||
	    !nla_put(&req.nlh, sizeof(req), IFLA_RMNET_MUX_ID, &mux, sizeof(mux))) {
		last_errno = EMSGSIZE;

		return ucv_boolean_new(false);
	}

	if (flags && ucv_type(flags) == UC_INTEGER && ucv_int64_get(flags) > 0) {
		rf.flags = (uint32_t)ucv_int64_get(flags);
		rf.mask = rf.flags;

		if (!nla_put(&req.nlh, sizeof(req), IFLA_RMNET_FLAGS, &rf, sizeof(rf))) {
			last_errno = EMSGSIZE;

			return ucv_boolean_new(false);
		}
	}

	nla_end(&req.nlh, infodata);
	nla_end(&req.nlh, linkinfo);

	fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);

	if (fd < 0) {
		last_errno = errno;

		return ucv_boolean_new(false);
	}

	if (sendto(fd, &req, req.nlh.nlmsg_len, 0,
	           (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		last_errno = errno;
		close(fd);

		return ucv_boolean_new(false);
	}

	rlen = nl_recv(fd, resp.b, sizeof(resp.b));
	close(fd);

	/* NLM_F_ACK guarantees an nlmsgerr reply — a missed/short read must NOT
	 * be reported as success (the caller would believe the link exists) */
	if (rlen < (ssize_t)NLMSG_LENGTH(sizeof(struct nlmsgerr)) ||
	    resp.h.nlmsg_len > (size_t)rlen ||
	    resp.h.nlmsg_type != NLMSG_ERROR) {
		last_errno = EIO;

		return ucv_boolean_new(false);
	}

	err = ((struct nlmsgerr *)NLMSG_DATA(&resp.h))->error;

	if (err != 0) {
		last_errno = -err;

		return ucv_boolean_new(false);
	}

	return ucv_boolean_new(true);
}

/* find the first rtattr of `type` within [buf, buf+len); NULL if absent */
static struct rtattr *
rta_find(void *buf, size_t len, unsigned short type)
{
	struct rtattr *rta = buf;

	for (; RTA_OK(rta, len); rta = RTA_NEXT(rta, len))
		if (rta->rta_type == type)
			return rta;

	return NULL;
}

/*
 * rmnet_mux_id(name): read the QMAP MAP id (IFLA_RMNET_MUX_ID) of an existing
 * rmnet link straight from the kernel — the authoritative value on a daemon
 * restart (adopt), where the config id may be stale. Returns the id (number) or
 * null (link absent, not an rmnet link, or no mux id). qmi_wwan's qmimux has no
 * such attribute, so that backend keeps its daemon-remembered mapping instead.
 *   qmit.rmnet_mux_id("wwan0m1")  ->  1 | null
 */
static uc_value_t *
qmit_rmnet_mux_id(uc_vm_t *vm, size_t nargs)
{
	uc_value_t *name = uc_fn_arg(0);
	struct {
		struct nlmsghdr nlh;
		struct ifinfomsg ifi;
	} req;
	struct sockaddr_nl sa = { .nl_family = AF_NETLINK };
	struct rtattr *linkinfo, *kind, *infodata, *muxa;
	struct nlmsghdr *rh;
	unsigned int idx;
	/* a single-link RTM_GETLINK reply (stats64, AF_SPEC, alt-names, ...) can
	 * exceed 2 KB on current kernels — size generously; union for alignment */
	union { char b[16384]; struct nlmsghdr h; } resp;
	void *attrs;
	size_t alen;
	ssize_t rlen;
	int fd;

	last_errno = 0;

	if (ucv_type(name) != UC_STRING) {
		last_errno = EINVAL;

		return NULL;
	}

	idx = if_nametoindex(ucv_string_get(name));

	if (!idx) {
		last_errno = ENODEV;

		return NULL;
	}

	memset(&req, 0, sizeof(req));
	req.nlh.nlmsg_len = NLMSG_LENGTH(sizeof(struct ifinfomsg));
	req.nlh.nlmsg_type = RTM_GETLINK;
	req.nlh.nlmsg_flags = NLM_F_REQUEST;
	req.nlh.nlmsg_seq = 1;
	req.ifi.ifi_family = AF_UNSPEC;
	req.ifi.ifi_index = idx;

	fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);

	if (fd < 0) {
		last_errno = errno;

		return NULL;
	}

	if (sendto(fd, &req, req.nlh.nlmsg_len, 0,
	           (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		last_errno = errno;
		close(fd);

		return NULL;
	}

	rlen = nl_recv(fd, resp.b, sizeof(resp.b));
	close(fd);

	if (rlen < (ssize_t)NLMSG_LENGTH(sizeof(struct ifinfomsg))) {
		last_errno = EIO;

		return NULL;
	}

	rh = &resp.h;

	/* a truncated datagram keeps the FULL length in nlmsg_len — walking that
	 * far would read past the buffer (OOB) */
	if (rh->nlmsg_len > (size_t)rlen) {
		last_errno = EMSGSIZE;

		return NULL;
	}

	if (rh->nlmsg_type == NLMSG_ERROR) {
		int e = ((struct nlmsgerr *)NLMSG_DATA(rh))->error;

		last_errno = e ? -e : EIO;

		return NULL;
	}

	if (rh->nlmsg_type != RTM_NEWLINK)
		return NULL;

	attrs = (char *)NLMSG_DATA(rh) + NLMSG_ALIGN(sizeof(struct ifinfomsg));
	alen = rh->nlmsg_len - NLMSG_LENGTH(sizeof(struct ifinfomsg));

	linkinfo = rta_find(attrs, alen, IFLA_LINKINFO);

	if (!linkinfo)
		return NULL;

	kind = rta_find(RTA_DATA(linkinfo), RTA_PAYLOAD(linkinfo), IFLA_INFO_KIND);

	if (!kind || strcmp((char *)RTA_DATA(kind), "rmnet") != 0)
		return NULL;   /* not an rmnet link */

	infodata = rta_find(RTA_DATA(linkinfo), RTA_PAYLOAD(linkinfo), IFLA_INFO_DATA);

	if (!infodata)
		return NULL;

	muxa = rta_find(RTA_DATA(infodata), RTA_PAYLOAD(infodata), IFLA_RMNET_MUX_ID);

	if (!muxa || RTA_PAYLOAD(muxa) < sizeof(uint16_t))
		return NULL;

	return ucv_int64_new(*(uint16_t *)RTA_DATA(muxa));
}

/*
 * ethtool-netlink (genl) constants for the TX aggregation coalesce params.
 * Defined locally (stable UAPI values) so the build never depends on the host
 * carrying a recent linux/ethtool_netlink.h.
 */
#define WW_ETHTOOL_GENL_NAME                     "ethtool"
#define WW_ETHTOOL_GENL_VERSION                  1
/* ethtool_message_types: ...CHANNELS_SET=18, COALESCE_GET=19, COALESCE_SET=20,
 * PAUSE_GET=21. This was 21 — i.e. every uplink-aggregation request was sent
 * as PAUSE_GET carrying coalesce attributes, which the kernel answers with
 * EINVAL. Host-side UL QMAP aggregation therefore never actually engaged on
 * any transport; the log line said "unavailable, kernel default kept" and was
 * taken at face value. Verified against
 * include/uapi/linux/ethtool_netlink_generated.h (6.18). */
#define WW_ETHTOOL_MSG_COALESCE_SET              20
#define WW_ETHTOOL_A_COALESCE_HEADER             1
#define WW_ETHTOOL_A_HEADER_DEV_NAME             2
#define WW_ETHTOOL_A_COALESCE_TX_AGGR_MAX_BYTES  26
#define WW_ETHTOOL_A_COALESCE_TX_AGGR_MAX_FRAMES 27
#define WW_ETHTOOL_A_COALESCE_TX_AGGR_TIME_USECS 28

/* resolve the "ethtool" genl family id on `fd`; 0 on failure */
static uint16_t
genl_resolve_family(int fd, const char *name)
{
	struct {
		struct nlmsghdr nlh;
		struct genlmsghdr genl;
		char buf[128];
	} req;
	struct sockaddr_nl sa = { .nl_family = AF_NETLINK };
	struct nlmsghdr *rh;
	struct rtattr *fa;
	/* the GETFAMILY reply carries the full ops/mcast-group lists and routinely
	 * exceeds 1 KB — a truncated reply must not be walked; union for alignment */
	union { char b[8192]; struct nlmsghdr h; } resp;
	ssize_t rlen;
	void *attrs;
	size_t alen;

	memset(&req, 0, sizeof(req));
	req.nlh.nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN);
	req.nlh.nlmsg_type = GENL_ID_CTRL;
	req.nlh.nlmsg_flags = NLM_F_REQUEST;
	req.nlh.nlmsg_seq = 1;
	req.genl.cmd = CTRL_CMD_GETFAMILY;
	req.genl.version = 1;

	if (!nla_put(&req.nlh, sizeof(req), CTRL_ATTR_FAMILY_NAME,
	             name, strlen(name) + 1))
		return 0;

	if (sendto(fd, &req, req.nlh.nlmsg_len, 0,
	           (struct sockaddr *)&sa, sizeof(sa)) < 0)
		return 0;

	rlen = nl_recv(fd, resp.b, sizeof(resp.b));

	if (rlen < (ssize_t)NLMSG_LENGTH(GENL_HDRLEN))
		return 0;

	rh = &resp.h;

	if (rh->nlmsg_len > (size_t)rlen)
		return 0;   /* truncated — never walk past the buffer */

	if (rh->nlmsg_type == NLMSG_ERROR || rh->nlmsg_type != GENL_ID_CTRL)
		return 0;

	attrs = (char *)NLMSG_DATA(rh) + GENL_HDRLEN;
	alen = rh->nlmsg_len - NLMSG_LENGTH(GENL_HDRLEN);
	fa = rta_find(attrs, alen, CTRL_ATTR_FAMILY_ID);

	if (!fa || RTA_PAYLOAD(fa) < sizeof(uint16_t))
		return 0;

	return *(uint16_t *)RTA_DATA(fa);
}

/*
 * rmnet_tx_aggr(name, max_bytes, max_frames, time_usecs): turn on mainline
 * rmnet uplink (egress) QMAP aggregation via the ethtool-netlink coalesce API
 * (ETHTOOL_A_COALESCE_TX_AGGR_*). The kernel default is max_frames=1 —
 * aggregation off — so the WDA-negotiated modem maxima only take effect once
 * the host side is switched on here. Best-effort: a false return simply leaves
 * the kernel default in place (no datapath impact).
 *   qmit.rmnet_tx_aggr("wwan0m1", 8192, 11, 800) -> true | false
 */
static uc_value_t *
qmit_rmnet_tx_aggr(uc_vm_t *vm, size_t nargs)
{
	uc_value_t *name = uc_fn_arg(0);
	uc_value_t *bytes = uc_fn_arg(1);
	uc_value_t *frames = uc_fn_arg(2);
	uc_value_t *usecs = uc_fn_arg(3);

	struct {
		struct nlmsghdr nlh;
		struct genlmsghdr genl;
		char buf[256];
	} req;
	struct sockaddr_nl sa = { .nl_family = AF_NETLINK };
	struct rtattr *hdr;
	uint32_t v_bytes, v_frames, v_usecs;
	uint16_t family;
	union { char b[1024]; struct nlmsghdr h; } resp;
	ssize_t rlen;
	int fd, err;

	last_errno = 0;

	if (ucv_type(name) != UC_STRING || ucv_type(bytes) != UC_INTEGER ||
	    ucv_type(frames) != UC_INTEGER || ucv_type(usecs) != UC_INTEGER) {
		last_errno = EINVAL;

		return ucv_boolean_new(false);
	}

	v_bytes = (uint32_t)ucv_int64_get(bytes);
	v_frames = (uint32_t)ucv_int64_get(frames);
	v_usecs = (uint32_t)ucv_int64_get(usecs);

	fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_GENERIC);

	if (fd < 0) {
		last_errno = errno;

		return ucv_boolean_new(false);
	}

	family = genl_resolve_family(fd, WW_ETHTOOL_GENL_NAME);

	if (!family) {
		last_errno = EPROTONOSUPPORT;
		close(fd);

		return ucv_boolean_new(false);
	}

	memset(&req, 0, sizeof(req));
	req.nlh.nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN);
	req.nlh.nlmsg_type = family;
	req.nlh.nlmsg_flags = NLM_F_REQUEST | NLM_F_ACK;
	req.nlh.nlmsg_seq = 2;
	req.genl.cmd = WW_ETHTOOL_MSG_COALESCE_SET;
	req.genl.version = WW_ETHTOOL_GENL_VERSION;

	hdr = nla_begin(&req.nlh, sizeof(req),
	                WW_ETHTOOL_A_COALESCE_HEADER | NLA_F_NESTED);

	if (!hdr ||
	    !nla_put(&req.nlh, sizeof(req), WW_ETHTOOL_A_HEADER_DEV_NAME,
	             ucv_string_get(name), ucv_string_length(name) + 1)) {
		last_errno = EMSGSIZE;
		close(fd);

		return ucv_boolean_new(false);
	}

	nla_end(&req.nlh, hdr);

	if (!nla_put(&req.nlh, sizeof(req), WW_ETHTOOL_A_COALESCE_TX_AGGR_MAX_BYTES,
	             &v_bytes, sizeof(v_bytes)) ||
	    !nla_put(&req.nlh, sizeof(req), WW_ETHTOOL_A_COALESCE_TX_AGGR_MAX_FRAMES,
	             &v_frames, sizeof(v_frames)) ||
	    !nla_put(&req.nlh, sizeof(req), WW_ETHTOOL_A_COALESCE_TX_AGGR_TIME_USECS,
	             &v_usecs, sizeof(v_usecs))) {
		last_errno = EMSGSIZE;
		close(fd);

		return ucv_boolean_new(false);
	}

	if (sendto(fd, &req, req.nlh.nlmsg_len, 0,
	           (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		last_errno = errno;
		close(fd);

		return ucv_boolean_new(false);
	}

	rlen = nl_recv(fd, resp.b, sizeof(resp.b));
	close(fd);

	/* NLM_F_ACK: a missed/short ACK is a failure, not success (see rmnet_add) */
	if (rlen < (ssize_t)NLMSG_LENGTH(sizeof(struct nlmsgerr)) ||
	    resp.h.nlmsg_len > (size_t)rlen ||
	    resp.h.nlmsg_type != NLMSG_ERROR) {
		last_errno = EIO;

		return ucv_boolean_new(false);
	}

	err = ((struct nlmsgerr *)NLMSG_DATA(&resp.h))->error;

	if (err != 0) {
		last_errno = -err;

		return ucv_boolean_new(false);
	}

	return ucv_boolean_new(true);
}

/* --- syslog seam ----------------------------------------------------------
 * Log to /dev/log with real RFC3164 priorities so the daemon passes per-message
 * severity to the system logger, instead of everything arriving as daemon.err
 * through procd's stderr capture. connect()ing the datagram socket lets the
 * caller learn whether /dev/log is available and fall back to stderr when not.
 * Stock ucode has no AF_UNIX socket support, hence this small native seam. */
static int syslog_fd = -1;
static int syslog_facility = 3;            /* LOG_DAEMON */
static char syslog_ident[32] = "wwand";

static bool
syslog_connect(void)
{
	struct sockaddr_un sa = { .sun_family = AF_UNIX };
	int fd;

	fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);

	if (fd < 0)
		return false;

	strncpy(sa.sun_path, "/dev/log", sizeof(sa.sun_path) - 1);

	if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		last_errno = errno;
		close(fd);

		return false;
	}

	syslog_fd = fd;

	return true;
}

/* syslog_open(ident?, facility?) -> bool available. Re-opens if already open. */
static uc_value_t *
qmit_syslog_open(uc_vm_t *vm, size_t nargs)
{
	uc_value_t *ident = uc_fn_arg(0);
	uc_value_t *facility = uc_fn_arg(1);

	last_errno = 0;

	if (ucv_type(ident) == UC_STRING) {
		strncpy(syslog_ident, ucv_string_get(ident), sizeof(syslog_ident) - 1);
		syslog_ident[sizeof(syslog_ident) - 1] = 0;
	}

	if (ucv_type(facility) == UC_INTEGER)
		syslog_facility = (int)ucv_int64_get(facility);

	if (syslog_fd >= 0) {
		close(syslog_fd);
		syslog_fd = -1;
	}

	return ucv_boolean_new(syslog_connect());
}

/* syslog_emit(severity, msg) -> bool sent. severity 0..7 (syslog numeric).
 * Reconnects once if logd was restarted; false lets the caller use stderr. */
static uc_value_t *
qmit_syslog_emit(uc_vm_t *vm, size_t nargs)
{
	uc_value_t *sev = uc_fn_arg(0);
	uc_value_t *msg = uc_fn_arg(1);
	char buf[2048];
	int pri, n;

	last_errno = 0;

	if (ucv_type(sev) != UC_INTEGER || ucv_type(msg) != UC_STRING) {
		last_errno = EINVAL;

		return ucv_boolean_new(false);
	}

	if (syslog_fd < 0 && !syslog_connect())
		return ucv_boolean_new(false);

	pri = (syslog_facility << 3) | ((int)ucv_int64_get(sev) & 7);
	n = snprintf(buf, sizeof(buf), "<%d>%s[%d]: %s",
	             pri, syslog_ident, (int)getpid(), ucv_string_get(msg));

	if (n < 0)
		return ucv_boolean_new(false);

	if (n >= (int)sizeof(buf))
		n = sizeof(buf) - 1;

	if (send(syslog_fd, buf, n, MSG_NOSIGNAL) < 0) {
		/* logd may have restarted — drop the stale socket, reconnect, retry */
		last_errno = errno;
		close(syslog_fd);
		syslog_fd = -1;

		if (!syslog_connect())
			return ucv_boolean_new(false);

		if (send(syslog_fd, buf, n, MSG_NOSIGNAL) < 0) {
			last_errno = errno;

			return ucv_boolean_new(false);
		}
	}

	return ucv_boolean_new(true);
}

static uc_value_t *
qmit_syslog_close(uc_vm_t *vm, size_t nargs)
{
	if (syslog_fd >= 0) {
		close(syslog_fd);
		syslog_fd = -1;
	}

	return ucv_boolean_new(true);
}

static const uc_function_list_t global_fns[] = {
	{ "open",          qmit_open },
	{ "open_tty",      qmit_open_tty },
	{ "spawn",         qmit_spawn },
	{ "rmnet_add",     qmit_rmnet_add },
	{ "rmnet_mux_id",  qmit_rmnet_mux_id },
	{ "rmnet_tx_aggr", qmit_rmnet_tx_aggr },
	{ "last_error",    qmit_last_error },
	{ "syslog_open",   qmit_syslog_open },
	{ "syslog_emit",   qmit_syslog_emit },
	{ "syslog_close",  qmit_syslog_close },
};

void
uc_module_init(uc_vm_t *vm, uc_value_t *scope)
{
	uc_function_list_register(scope, global_fns);

	transport_type = uc_type_declare(vm, "wwand.io", transport_fns, qmit_free);
}
