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
 *
 * SPDX-License-Identifier: GPL-2.0
 */

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
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#include <linux/netlink.h>
#include <linux/rtnetlink.h>

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

	if (pipe(in) < 0) {
		last_errno = errno;
		free_argv(args);

		return NULL;
	}

	if (pipe(out) < 0) {
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
		/* child: stdin <- in[0], stdout -> out[1], stderr inherited */
		dup2(in[0], STDIN_FILENO);
		dup2(out[1], STDOUT_FILENO);
		close(in[0]);
		close(in[1]);
		close(out[0]);
		close(out[1]);
		execvp(args[0], args);
		_exit(127);
	}

	/* parent */
	close(in[0]);
	close(out[1]);
	free_argv(args);

	fl = fcntl(out[0], F_GETFL, 0);
	fcntl(out[0], F_SETFL, (fl < 0 ? 0 : fl) | O_NONBLOCK);
	fcntl(out[0], F_SETFD, FD_CLOEXEC);

	/* the write end is non-blocking too: a stalled child must never block the
	 * single-threaded uloop in write() */
	fl = fcntl(in[1], F_GETFL, 0);
	fcntl(in[1], F_SETFL, (fl < 0 ? 0 : fl) | O_NONBLOCK);
	fcntl(in[1], F_SETFD, FD_CLOEXEC);

	t = calloc(1, sizeof(*t));

	if (!t) {
		last_errno = ENOMEM;
		close(out[0]);
		close(in[1]);

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

			/* partial tty writes are resumable by the caller */
			if (off && (errno == EAGAIN || errno == EWOULDBLOCK))
				break;

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

		/* spawn: reap the child and hand back its exit status */
		if (t->pid > 0) {
			while (waitpid(t->pid, &status, 0) < 0 && errno == EINTR)
				;
			t->pid = -1;

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

		/* a spawn handle GC'd without close(): signal the child and reap it so
		 * it neither lingers nor turns into a zombie */
		if (t->pid > 0) {
			int status;

			kill(t->pid, SIGTERM);
			while (waitpid(t->pid, &status, 0) < 0 && errno == EINTR)
				;
		}

		free(t);
	}
}

static const uc_function_list_t transport_fns[] = {
	{ "read",   qmit_read },
	{ "write",  qmit_write },
	{ "fileno", qmit_fileno },
	{ "flush",  qmit_flush },
	{ "close",  qmit_close },
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
	char resp[1024];
	ssize_t rlen;
	int fd, err;

	last_errno = 0;

	if (ucv_type(name) != UC_STRING || ucv_type(parent) != UC_STRING ||
	    ucv_type(mux_id) != UC_INTEGER) {
		last_errno = EINVAL;

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

	linkinfo = nla_begin(&req.nlh, sizeof(req), IFLA_LINKINFO);
	nla_put(&req.nlh, sizeof(req), IFLA_INFO_KIND, "rmnet", 6);
	infodata = nla_begin(&req.nlh, sizeof(req), IFLA_INFO_DATA);

	mux = (uint16_t)ucv_int64_get(mux_id);
	nla_put(&req.nlh, sizeof(req), IFLA_RMNET_MUX_ID, &mux, sizeof(mux));

	if (flags && ucv_type(flags) == UC_INTEGER && ucv_int64_get(flags) > 0) {
		rf.flags = (uint32_t)ucv_int64_get(flags);
		rf.mask = rf.flags;
		nla_put(&req.nlh, sizeof(req), IFLA_RMNET_FLAGS, &rf, sizeof(rf));
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

	rlen = recv(fd, resp, sizeof(resp), 0);
	close(fd);

	if (rlen >= (ssize_t)NLMSG_LENGTH(sizeof(struct nlmsgerr))) {
		struct nlmsghdr *rh = (struct nlmsghdr *)resp;

		if (rh->nlmsg_type == NLMSG_ERROR) {
			err = ((struct nlmsgerr *)NLMSG_DATA(rh))->error;

			if (err != 0) {
				last_errno = -err;

				return ucv_boolean_new(false);
			}
		}
	}

	return ucv_boolean_new(true);
}

static const uc_function_list_t global_fns[] = {
	{ "open",       qmit_open },
	{ "open_tty",   qmit_open_tty },
	{ "spawn",      qmit_spawn },
	{ "rmnet_add",  qmit_rmnet_add },
	{ "last_error", qmit_last_error },
};

void
uc_module_init(uc_vm_t *vm, uc_value_t *scope)
{
	uc_function_list_register(scope, global_fns);

	transport_type = uc_type_declare(vm, "wwand.io", transport_fns, qmit_free);
}
