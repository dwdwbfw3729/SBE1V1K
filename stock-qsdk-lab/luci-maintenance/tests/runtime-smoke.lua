local config_dir = assert(arg[1], "config directory is required")
local state_dir = assert(arg[2], "state directory is required")
local ubus_socket = assert(arg[3], "ubus test socket is required")

-- CVE-2014-5461: a vararg prototype with many fixed parameters used to
-- reserve only maxstacksize slots when called with too few arguments.
local parameters = {}
for index = 1, 120 do
    parameters[index] = "p" .. index
end
local vararg_factory = assert(loadstring(
    "return function(" .. table.concat(parameters, ",") .. ", ...) return p120, ... end",
    "@cve-2014-5461-regression"
))
local vararg_function = assert(vararg_factory())
assert(pcall(vararg_function))
print("lua_cve_2014_5461=pass")

-- Exercise parser allocation and collection using attacker-controlled chunk
-- names.  The source marker gate proves the CVE-2025-49844 anchor itself;
-- this loop is a runtime crash regression, not a probabilistic proof.
for index = 1, 600 do
    collectgarbage("collect")
    local chunk = assert(loadstring(
        "local t={" .. string.rep("'x',", 64) .. "}; return #t",
        "@cve-2025-49844-" .. index .. string.rep("n", 96)
    ))
    assert(chunk() == 64)
end
print("lua_cve_2025_49844_gc_stress=pass")

local unpack_ok, unpack_error = pcall(unpack, {}, -2147483648, 2147483647)
assert(not unpack_ok)
assert(tostring(unpack_error):find("too many results", 1, true))
print("lua_unpack_overflow=pass")

local uci = assert(require("uci"))
assert(type(uci.cursor) == "function")
local cursor = assert(uci.cursor(config_dir, state_dir))
assert(cursor:get("network", "lan", "proto") == "static")
assert(cursor:get("network", "lan", "ipaddr") == "192.0.2.1")
for _ = 1, 200 do
    local ok, message = pcall(function()
        cursor:set("network", "lan", "proto", {})
    end)
    assert(not ok)
    assert(tostring(message):find("empty table", 1, true))
    assert(type(cursor:changes()) == "table")
end
print("uci_read=pass")
print("uci_lua_error_paths=pass")

local ubus = assert(require("ubus"))
assert(type(ubus.connect) == "function")
local connection = assert(ubus.connect(ubus_socket))
local add_ok, add_error = pcall(function()
    connection:add("not-an-object-table")
end)
assert(not add_ok)
assert(tostring(add_error):find("pass a table", 1, true))
connection:close()
print("ubus_module=pass")
print("ubus_lua_invalid_object=pass")

local iwinfo = assert(require("iwinfo"))
assert(type(iwinfo) == "table")
assert(type(iwinfo.type) == "function")
print("iwinfo_module=pass")
