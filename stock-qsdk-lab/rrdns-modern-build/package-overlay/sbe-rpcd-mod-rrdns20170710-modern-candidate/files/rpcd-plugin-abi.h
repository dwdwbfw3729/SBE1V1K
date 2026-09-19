/* Minimal compile-time view of the locked rpcd plugin ABI.
 *
 * The canonical rpcd plugin.h is SHA-256
 * 66caee7f53582767feecd451502004d85fe74df9bcb973196e99b454649c1999.
 * rrdns does not dereference rpc_daemon_ops, so retaining only the opaque
 * pointer and exact rpc_plugin layout avoids rebuilding or replacing rpcd.
 */
#ifndef SBE_RRDNS_RPCD_PLUGIN_ABI_H
#define SBE_RRDNS_RPCD_PLUGIN_ABI_H

#include <libubox/list.h>
#include <libubus.h>

struct rpc_daemon_ops;

struct rpc_plugin {
	struct list_head list;
	int (*init)(const struct rpc_daemon_ops *ops, struct ubus_context *ctx);
};

#endif
