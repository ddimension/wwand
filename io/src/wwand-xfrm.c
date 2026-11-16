// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
/*
 * ucode-mod-wwand-ims-xfrm — the kernel IPsec SAs and policies of IMS
 * sec-agree (3GPP TS 33.203 7), over NETLINK_XFRM. No key management: the
 * keys come from the USIM's CK/IK, the SPIs and ports from the
 * Security-Client/Server headers; the protocol logic lives in ucode
 * (ue/secagree.uc). One request per call on a socket of its own, answered
 * synchronously by the kernel.
 *
 *   import * as xfrm from 'wwand_ims_xfrm';
 *
 *   xfrm.alloc_spi({ src, dst, min, max })            -> spi | null
 *   xfrm.sa_add({ src, dst, spi, reqid,
 *                 auth: { name, key, trunc },          // key: binary string
 *                 enc:  { name, key },                 // optional; null cipher if absent
 *                 sel:  { src, dst, sport, dport, proto, dev },
 *                 if_id, replay_window, update })     -> true | null
 *   xfrm.sa_del({ src, dst, spi })                     -> true | null
 *   xfrm.policy_add({ dir: 'in'|'out'|'fwd', sel, priority, if_id,
 *                     tmpl: { src, dst, reqid }, update }) -> true | null
 *   xfrm.policy_del({ dir, sel, if_id })               -> true | null
 *   xfrm.error()                                       -> string | null
 *
 * Addresses are IPv4 or IPv6 strings; all addresses of one SA or policy are
 * one family. Only ESP in transport mode, which is all sec-agree uses.
 * `sel.proto` is 'udp', 'tcp' or a number; `sel.dev` an interface name
 * (selector ifindex). `update` turns NEWSA/NEWPOLICY into UPDSA/UPDPOLICY:
 * that is how a SPI reserved with alloc_spi (a larval SA) gets its keys.
 */

#define _GNU_SOURCE

#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>

#include <linux/netlink.h>
#include <linux/xfrm.h>

/* lib.h/vm.h, NOT module.h: module.h defines the module entry point
 * (uc_module_entry), and wwand-io.c already provides it for this module. */
#include <ucode/lib.h>
#include <ucode/vm.h>

#define XFRM_BUFSIZE 4096

static int last_errno;
static const char *last_msg;

static void
set_error(int err, const char *msg)
{
	last_errno = err;
	last_msg = msg;
}

static uc_value_t *
x_error(uc_vm_t *vm, size_t nargs)
{
	char buf[160];

	if (!last_errno && !last_msg)
		return NULL;

	if (last_msg && last_errno)
		snprintf(buf, sizeof(buf), "%s: %s", last_msg, strerror(last_errno));
	else if (last_msg)
		snprintf(buf, sizeof(buf), "%s", last_msg);
	else
		snprintf(buf, sizeof(buf), "%s", strerror(last_errno));

	return ucv_string_new(buf);
}

/* ---- arguments --------------------------------------------------------- */

static uc_value_t *
field(uc_value_t *obj, const char *name)
{
	return ucv_type(obj) == UC_OBJECT ? ucv_object_get(obj, name, NULL) : NULL;
}

/* ucv_string_get() is a macro over the ADDRESS of its argument: a short
 * string (up to 7 bytes: "in", "out", "ims", "1.2.3.4") is a tagged pointer
 * that carries its bytes in the value itself, so the result points into the
 * variable passed. Returning it from a local is a dangling pointer, which
 * the host build happened to survive and aarch64 -O2 did not ("dir must be
 * in, out or fwd" on a policy whose dir was "out"). Copy into a small ring
 * instead: every caller uses the result before the 8th next call. */
#define FIELD_STR_SLOTS 8
#define FIELD_STR_LEN 128

static const char *
field_str(uc_value_t *obj, const char *name)
{
	static char ring[FIELD_STR_SLOTS][FIELD_STR_LEN];
	static unsigned int next;
	uc_value_t *v = field(obj, name);
	const char *s;
	char *slot;
	size_t n;

	if (ucv_type(v) != UC_STRING)
		return NULL;

	s = ucv_string_get(v);
	n = ucv_string_length(v);
	if (n >= FIELD_STR_LEN)
		return NULL;

	slot = ring[next++ % FIELD_STR_SLOTS];
	memcpy(slot, s, n);
	slot[n] = 0;

	return slot;
}

static bool
field_u32(uc_value_t *obj, const char *name, uint32_t *out)
{
	uc_value_t *v = field(obj, name);
	int64_t n;

	if (ucv_type(v) != UC_INTEGER)
		return false;

	n = ucv_int64_get(v);
	if (n < 0 || n > UINT32_MAX)
		return false;

	*out = (uint32_t)n;
	return true;
}

/* parse an address; *family is set on first use and checked after */
static bool
parse_addr(const char *s, uint16_t *family, xfrm_address_t *out)
{
	uint16_t f;

	memset(out, 0, sizeof(*out));

	if (!s)
		return false;

	if (inet_pton(AF_INET, s, &out->a4) == 1)
		f = AF_INET;
	else if (inet_pton(AF_INET6, s, out->a6) == 1)
		f = AF_INET6;
	else
		return false;

	if (*family && *family != f)
		return false;

	*family = f;
	return true;
}

static bool
parse_proto(uc_value_t *v, uint8_t *out)
{
	const char *s;
	int64_t n;

	if (!v) {
		*out = 0;
		return true;
	}

	if (ucv_type(v) == UC_INTEGER) {
		n = ucv_int64_get(v);
		if (n < 0 || n > 255)
			return false;
		*out = (uint8_t)n;
		return true;
	}

	s = ucv_type(v) == UC_STRING ? ucv_string_get(v) : NULL;
	if (!s)
		return false;
	if (!strcmp(s, "udp"))
		*out = IPPROTO_UDP;
	else if (!strcmp(s, "tcp"))
		*out = IPPROTO_TCP;
	else if (!strcmp(s, "any"))
		*out = 0;
	else
		return false;

	return true;
}

/*
 * selector: src/dst are host addresses (full prefix); ports exact when given.
 * Ports without a proto are allowed: the kernel matches them on the flow for
 * any protocol, which is what sec-agree needs (one SA pair carries the SIP
 * traffic of a port pair over UDP and TCP alike, TS 33.203 7.1).
 */
static bool
parse_sel(uc_value_t *o, uint16_t *family, struct xfrm_selector *sel)
{
	uint32_t port;
	const char *dev;

	memset(sel, 0, sizeof(*sel));

	if (ucv_type(o) != UC_OBJECT) {
		set_error(0, "selector missing");
		return false;
	}

	if (!parse_addr(field_str(o, "src"), family, &sel->saddr) ||
	    !parse_addr(field_str(o, "dst"), family, &sel->daddr)) {
		set_error(0, "selector address invalid or mixed families");
		return false;
	}

	sel->family = *family;
	sel->prefixlen_s = sel->prefixlen_d = (*family == AF_INET) ? 32 : 128;

	if (!parse_proto(field(o, "proto"), &sel->proto)) {
		set_error(0, "selector proto invalid");
		return false;
	}

	if (field_u32(o, "sport", &port)) {
		if (port > 65535) {
			set_error(0, "selector sport invalid");
			return false;
		}
		sel->sport = htons((uint16_t)port);
		sel->sport_mask = 0xffff;
	}

	if (field_u32(o, "dport", &port)) {
		if (port > 65535) {
			set_error(0, "selector dport invalid");
			return false;
		}
		sel->dport = htons((uint16_t)port);
		sel->dport_mask = 0xffff;
	}

	dev = field_str(o, "dev");
	if (dev) {
		sel->ifindex = (int)if_nametoindex(dev);
		if (!sel->ifindex) {
			set_error(errno, "selector dev");
			return false;
		}
	}

	return true;
}

static void
lifetime_inf(struct xfrm_lifetime_cfg *lft)
{
	lft->soft_byte_limit = lft->hard_byte_limit = XFRM_INF;
	lft->soft_packet_limit = lft->hard_packet_limit = XFRM_INF;
}

/* ---- netlink ----------------------------------------------------------- */

static void *
nl_put(struct nlmsghdr *nlh, unsigned short type, const void *data, size_t len)
{
	struct nlattr *nla;

	if (NLMSG_ALIGN(nlh->nlmsg_len) + NLA_HDRLEN + NLA_ALIGN(len) > XFRM_BUFSIZE)
		return NULL;

	nla = (struct nlattr *)((char *)nlh + NLMSG_ALIGN(nlh->nlmsg_len));
	nla->nla_type = type;
	nla->nla_len = NLA_HDRLEN + len;
	if (data)
		memcpy((char *)nla + NLA_HDRLEN, data, len);
	else
		memset((char *)nla + NLA_HDRLEN, 0, len);
	nlh->nlmsg_len = NLMSG_ALIGN(nlh->nlmsg_len) + NLA_ALIGN(nla->nla_len);

	return (char *)nla + NLA_HDRLEN;
}

/*
 * Send one request and read its answer. With `reply` the kernel answers with
 * a message of `reply_type` (ALLOCSPI -> NEWSA), copied into reply/reply_len;
 * otherwise only the ACK (nlmsgerr) is expected.
 */
static bool
nl_talk(struct nlmsghdr *nlh, uint16_t reply_type, void *reply, size_t reply_len)
{
	struct sockaddr_nl sa = { .nl_family = AF_NETLINK };
	struct timeval tv = { .tv_sec = 2 };
	char buf[XFRM_BUFSIZE];
	struct nlmsghdr *r;
	ssize_t n;
	int fd;
	bool ok = false;

	fd = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_XFRM);
	if (fd < 0) {
		set_error(errno, "socket");
		return false;
	}

	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

	nlh->nlmsg_flags |= NLM_F_REQUEST | (reply ? 0 : NLM_F_ACK);
	nlh->nlmsg_seq = 1;

	if (sendto(fd, nlh, nlh->nlmsg_len, 0, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		set_error(errno, "sendto");
		goto out;
	}

	do {
		n = recv(fd, buf, sizeof(buf), 0);
	} while (n < 0 && errno == EINTR);

	if (n < 0) {
		set_error(errno, "recv");
		goto out;
	}

	for (r = (struct nlmsghdr *)buf; NLMSG_OK(r, (size_t)n); r = NLMSG_NEXT(r, n)) {
		if (r->nlmsg_type == NLMSG_ERROR) {
			struct nlmsgerr *e = NLMSG_DATA(r);

			if (r->nlmsg_len < NLMSG_LENGTH(sizeof(*e))) {
				set_error(0, "short netlink error");
				goto out;
			}
			if (e->error) {
				set_error(-e->error, "kernel");
				goto out;
			}
			ok = !reply;
			goto out;
		}

		if (reply && r->nlmsg_type == reply_type) {
			if (r->nlmsg_len < NLMSG_LENGTH(reply_len)) {
				set_error(0, "short netlink reply");
				goto out;
			}
			memcpy(reply, NLMSG_DATA(r), reply_len);
			ok = true;
			goto out;
		}
	}

	set_error(0, "no netlink answer");

out:
	close(fd);
	return ok;
}

static struct nlmsghdr *
nl_begin(char *buf, uint16_t type, uint16_t flags, size_t hdrlen)
{
	struct nlmsghdr *nlh = (struct nlmsghdr *)buf;

	memset(buf, 0, XFRM_BUFSIZE);
	nlh->nlmsg_len = NLMSG_LENGTH(hdrlen);
	nlh->nlmsg_type = type;
	nlh->nlmsg_flags = flags;

	return nlh;
}

static bool
put_if_id(struct nlmsghdr *nlh, uc_value_t *args)
{
	uint32_t if_id;

	if (!field(args, "if_id"))
		return true;

	if (!field_u32(args, "if_id", &if_id)) {
		set_error(0, "if_id invalid");
		return false;
	}

	if (!nl_put(nlh, XFRMA_IF_ID, &if_id, sizeof(if_id))) {
		set_error(0, "message too long");
		return false;
	}

	return true;
}

/* ---- SAs --------------------------------------------------------------- */

static uc_value_t *
x_alloc_spi(uc_vm_t *vm, size_t nargs)
{
	uc_value_t *args = uc_fn_arg(0);
	char buf[XFRM_BUFSIZE];
	struct xfrm_userspi_info *spi;
	struct xfrm_usersa_info reply;
	struct nlmsghdr *nlh;
	uint16_t family = 0;
	uint32_t min = 0x100, max = 0x0fffffff;

	set_error(0, NULL);

	nlh = nl_begin(buf, XFRM_MSG_ALLOCSPI, 0, sizeof(*spi));
	spi = NLMSG_DATA(nlh);

	if (!parse_addr(field_str(args, "src"), &family, &spi->info.saddr) ||
	    !parse_addr(field_str(args, "dst"), &family, &spi->info.id.daddr)) {
		set_error(0, "address invalid or mixed families");
		return NULL;
	}

	field_u32(args, "min", &min);
	field_u32(args, "max", &max);
	if (min < 0x100 || min > max) {
		set_error(0, "spi range invalid (SPIs below 256 are reserved)");
		return NULL;
	}

	spi->info.family = family;
	spi->info.id.proto = IPPROTO_ESP;
	spi->info.mode = XFRM_MODE_TRANSPORT;
	spi->min = min;
	spi->max = max;

	if (!nl_talk(nlh, XFRM_MSG_NEWSA, &reply, sizeof(reply)))
		return NULL;

	return ucv_int64_new(ntohl(reply.id.spi));
}

static bool
put_auth(struct nlmsghdr *nlh, uc_value_t *auth)
{
	const char *name = field_str(auth, "name");
	uc_value_t *key = field(auth, "key");
	struct xfrm_algo_auth *a;
	uint32_t trunc = 96;
	size_t klen;

	if (!name || strlen(name) >= sizeof(a->alg_name) || ucv_type(key) != UC_STRING) {
		set_error(0, "auth needs name and key");
		return false;
	}

	field_u32(auth, "trunc", &trunc);
	klen = ucv_string_length(key);

	a = nl_put(nlh, XFRMA_ALG_AUTH_TRUNC, NULL, sizeof(*a) + klen);
	if (!a) {
		set_error(0, "message too long");
		return false;
	}

	strcpy(a->alg_name, name);
	a->alg_key_len = klen * 8;
	a->alg_trunc_len = trunc;
	memcpy(a->alg_key, ucv_string_get(key), klen);

	return true;
}

static bool
put_enc(struct nlmsghdr *nlh, uc_value_t *enc)
{
	const char *name = enc ? field_str(enc, "name") : "ecb(cipher_null)";
	uc_value_t *key = enc ? field(enc, "key") : NULL;
	struct xfrm_algo *a;
	size_t klen = 0;

	if (!name || strlen(name) >= sizeof(a->alg_name)) {
		set_error(0, "enc name invalid");
		return false;
	}

	if (key) {
		if (ucv_type(key) != UC_STRING) {
			set_error(0, "enc key invalid");
			return false;
		}
		klen = ucv_string_length(key);
	}

	a = nl_put(nlh, XFRMA_ALG_CRYPT, NULL, sizeof(*a) + klen);
	if (!a) {
		set_error(0, "message too long");
		return false;
	}

	strcpy(a->alg_name, name);
	a->alg_key_len = klen * 8;
	if (klen)
		memcpy(a->alg_key, ucv_string_get(key), klen);

	return true;
}

static uc_value_t *
x_sa_add(uc_vm_t *vm, size_t nargs)
{
	uc_value_t *args = uc_fn_arg(0);
	char buf[XFRM_BUFSIZE];
	struct xfrm_usersa_info *sa;
	struct nlmsghdr *nlh;
	uint16_t family = 0;
	uint32_t spi, rw = 0;
	bool update = ucv_is_truish(field(args, "update"));

	set_error(0, NULL);

	nlh = nl_begin(buf, update ? XFRM_MSG_UPDSA : XFRM_MSG_NEWSA, 0, sizeof(*sa));
	sa = NLMSG_DATA(nlh);

	if (!parse_addr(field_str(args, "src"), &family, &sa->saddr) ||
	    !parse_addr(field_str(args, "dst"), &family, &sa->id.daddr)) {
		set_error(0, "address invalid or mixed families");
		return NULL;
	}

	if (!field_u32(args, "spi", &spi) || spi < 0x100) {
		set_error(0, "spi missing or reserved");
		return NULL;
	}

	if (field(args, "sel") && !parse_sel(field(args, "sel"), &family, &sa->sel))
		return NULL;

	field_u32(args, "reqid", &sa->reqid);
	field_u32(args, "replay_window", &rw);

	sa->id.spi = htonl(spi);
	sa->id.proto = IPPROTO_ESP;
	sa->family = family;
	sa->mode = XFRM_MODE_TRANSPORT;
	sa->replay_window = rw > 255 ? 255 : (uint8_t)rw;
	lifetime_inf(&sa->lft);

	if (!put_auth(nlh, field(args, "auth")) ||
	    !put_enc(nlh, field(args, "enc")) ||
	    !put_if_id(nlh, args))
		return NULL;

	return nl_talk(nlh, 0, NULL, 0) ? ucv_boolean_new(true) : NULL;
}

static uc_value_t *
x_sa_del(uc_vm_t *vm, size_t nargs)
{
	uc_value_t *args = uc_fn_arg(0);
	char buf[XFRM_BUFSIZE];
	struct xfrm_usersa_id *id;
	struct nlmsghdr *nlh;
	xfrm_address_t saddr;
	uint16_t family = 0;
	uint32_t spi;

	set_error(0, NULL);

	nlh = nl_begin(buf, XFRM_MSG_DELSA, 0, sizeof(*id));
	id = NLMSG_DATA(nlh);

	if (!parse_addr(field_str(args, "dst"), &family, &id->daddr) ||
	    (field_str(args, "src") && !parse_addr(field_str(args, "src"), &family, &saddr))) {
		set_error(0, "address invalid or mixed families");
		return NULL;
	}

	if (!field_u32(args, "spi", &spi)) {
		set_error(0, "spi missing");
		return NULL;
	}

	id->spi = htonl(spi);
	id->family = family;
	id->proto = IPPROTO_ESP;

	if (field_str(args, "src") && !nl_put(nlh, XFRMA_SRCADDR, &saddr, sizeof(saddr))) {
		set_error(0, "message too long");
		return NULL;
	}

	return nl_talk(nlh, 0, NULL, 0) ? ucv_boolean_new(true) : NULL;
}

/* ---- policies ---------------------------------------------------------- */

static bool
parse_dir(const char *s, uint8_t *dir)
{
	if (!s)
		return false;
	if (!strcmp(s, "in"))
		*dir = XFRM_POLICY_IN;
	else if (!strcmp(s, "out"))
		*dir = XFRM_POLICY_OUT;
	else if (!strcmp(s, "fwd"))
		*dir = XFRM_POLICY_FWD;
	else
		return false;
	return true;
}

static uc_value_t *
x_policy_add(uc_vm_t *vm, size_t nargs)
{
	uc_value_t *args = uc_fn_arg(0), *tmpl_arg = field(args, "tmpl");
	char buf[XFRM_BUFSIZE];
	struct xfrm_userpolicy_info *pol;
	struct xfrm_user_tmpl *t;
	struct nlmsghdr *nlh;
	uint16_t family = 0;
	bool update = ucv_is_truish(field(args, "update"));

	set_error(0, NULL);

	nlh = nl_begin(buf, update ? XFRM_MSG_UPDPOLICY : XFRM_MSG_NEWPOLICY, 0, sizeof(*pol));
	pol = NLMSG_DATA(nlh);

	if (!parse_dir(field_str(args, "dir"), &pol->dir)) {
		set_error(0, "dir must be in, out or fwd");
		return NULL;
	}

	if (!parse_sel(field(args, "sel"), &family, &pol->sel))
		return NULL;

	field_u32(args, "priority", &pol->priority);
	pol->action = XFRM_POLICY_ALLOW;
	pol->share = XFRM_SHARE_ANY;
	lifetime_inf(&pol->lft);

	if (ucv_type(tmpl_arg) != UC_OBJECT) {
		set_error(0, "tmpl missing");
		return NULL;
	}

	t = nl_put(nlh, XFRMA_TMPL, NULL, sizeof(*t));
	if (!t) {
		set_error(0, "message too long");
		return NULL;
	}

	if (!parse_addr(field_str(tmpl_arg, "src"), &family, &t->saddr) ||
	    !parse_addr(field_str(tmpl_arg, "dst"), &family, &t->id.daddr)) {
		set_error(0, "tmpl address invalid or mixed families");
		return NULL;
	}

	t->id.proto = IPPROTO_ESP;
	t->family = family;
	t->mode = XFRM_MODE_TRANSPORT;
	t->share = XFRM_SHARE_ANY;
	t->aalgos = t->ealgos = t->calgos = ~0U;
	field_u32(tmpl_arg, "reqid", &t->reqid);

	if (!put_if_id(nlh, args))
		return NULL;

	return nl_talk(nlh, 0, NULL, 0) ? ucv_boolean_new(true) : NULL;
}

static uc_value_t *
x_policy_del(uc_vm_t *vm, size_t nargs)
{
	uc_value_t *args = uc_fn_arg(0);
	char buf[XFRM_BUFSIZE];
	struct xfrm_userpolicy_id *id;
	struct nlmsghdr *nlh;
	uint16_t family = 0;

	set_error(0, NULL);

	nlh = nl_begin(buf, XFRM_MSG_DELPOLICY, 0, sizeof(*id));
	id = NLMSG_DATA(nlh);

	if (!parse_dir(field_str(args, "dir"), &id->dir)) {
		set_error(0, "dir must be in, out or fwd");
		return NULL;
	}

	if (!parse_sel(field(args, "sel"), &family, &id->sel) || !put_if_id(nlh, args))
		return NULL;

	return nl_talk(nlh, 0, NULL, 0) ? ucv_boolean_new(true) : NULL;
}

static const uc_function_list_t xfrm_fns[] = {
	{ "alloc_spi",  x_alloc_spi },
	{ "sa_add",     x_sa_add },
	{ "sa_del",     x_sa_del },
	{ "policy_add", x_policy_add },
	{ "policy_del", x_policy_del },
	{ "error",      x_error },
};

/* Registered as a sub-namespace `xfrm` of the wwand_io module: these functions
 * are a generic NETLINK_XFRM (IPsec SA/policy) binding, merged into wwand_io.so
 * so a consumer (wwand-ims sec-agree) needs no native module of its own. Called
 * from wwand-io.c's uc_module_init; there is no uc_module_init of its own. */
void
wwand_xfrm_register(uc_vm_t *vm, uc_value_t *scope)
{
	uc_value_t *o = ucv_object_new(vm);
	uc_function_list_register(o, xfrm_fns);
	ucv_object_add(scope, "xfrm", o);
}
