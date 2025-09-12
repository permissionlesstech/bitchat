/* Copyright (c) 2019-2021, The Tor Project, Inc. */
/* See LICENSE for licensing information */

#ifndef TOR_PROTO_HAPROXY_H
#define TOR_PROTO_HAPROXY_H

struct tor_addr_port_t;

char *haproxy_format_proxy_header_line(
                                    const struct tor_addr_port_t *addr_port);

#endif /* !defined(TOR_PROTO_HAPROXY_H) */
