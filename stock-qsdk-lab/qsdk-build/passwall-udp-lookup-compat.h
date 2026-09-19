/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * SBE1V1K factory-kernel compatibility overlay.
 *
 * The factory p25 kernel exports __udp4_lib_lookup(),
 * __udp6_lib_lookup(), and udp_table, but not the conditional
 * udp4_lib_lookup()/udp6_lib_lookup() wrappers.  The wrappers below are an
 * exact source-level transcription of Linux 5.4's conditional wrappers.  A
 * caller must already hold rcu_read_lock(), just as for the upstream API.
 *
 * This header is force-included only for the four nf_socket/nf_tproxy
 * translation units.  It deliberately does not modify the locked public
 * QSDK kernel checkout.
 */
#ifndef SBE_PASSWALL_UDP_LOOKUP_COMPAT_H
#define SBE_PASSWALL_UDP_LOOKUP_COMPAT_H

#include <net/udp.h>
#include <net/sock.h>

#if defined(SBE_UDP_LOOKUP_COMPAT_IPV4) && defined(SBE_UDP_LOOKUP_COMPAT_IPV6)
#error "select only one SBE UDP lookup compatibility family"
#elif defined(SBE_UDP_LOOKUP_COMPAT_IPV4)
static __always_inline struct sock *
sbe_udp4_lib_lookup(struct net *net, __be32 saddr, __be16 sport,
			    __be32 daddr, __be16 dport, int dif)
{
	struct sock *sk;

	sk = __udp4_lib_lookup(net, saddr, sport, daddr, dport,
			       dif, 0, &udp_table, NULL);
	if (sk && !refcount_inc_not_zero(&sk->sk_refcnt))
		sk = NULL;
	return sk;
}
#define udp4_lib_lookup sbe_udp4_lib_lookup
#elif defined(SBE_UDP_LOOKUP_COMPAT_IPV6)
static __always_inline struct sock *
sbe_udp6_lib_lookup(struct net *net, const struct in6_addr *saddr,
			    __be16 sport, const struct in6_addr *daddr,
			    __be16 dport, int dif)
{
	struct sock *sk;

	sk = __udp6_lib_lookup(net, saddr, sport, daddr, dport,
			       dif, 0, &udp_table, NULL);
	if (sk && !refcount_inc_not_zero(&sk->sk_refcnt))
		sk = NULL;
	return sk;
}
#define udp6_lib_lookup sbe_udp6_lib_lookup
#else
#error "select exactly one SBE UDP lookup compatibility family"
#endif

/* nf_socket sources define their own module-specific pr_fmt before their
 * normal includes.  A forced include necessarily happens earlier, so those
 * two targets ask us to discard the default first.  nf_tproxy sources do not
 * redefine pr_fmt and must retain the default pulled in by the headers. */
#if defined(SBE_COMPAT_SOURCE_DEFINES_PR_FMT) && defined(pr_fmt)
#undef pr_fmt
#endif

#endif /* SBE_PASSWALL_UDP_LOOKUP_COMPAT_H */
