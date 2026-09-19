"""Small explicit transforms on the locked upstream tree; no feature pruning."""
from __future__ import annotations


def replace(text: str, old: str, new: str, count: int = 1) -> str:
    if text.count(old) != count:
        raise ValueError(f"upstream context changed: {old[:100]!r}")
    return text.replace(old, new)


def function(text: str, name: str, body: str) -> str:
    start = text.index("function " + name + "(")
    end = text.find("\nfunction ", start + 1)
    if end < 0:
        raise ValueError("function boundary not found: " + name)
    return text[:start] + body.strip() + "\n" + text[end:]


def apply_fixups(tree: dict) -> list[str]:
    def read(name):
        return tree[name][0].decode()

    def save(name, text):
        tree[name] = (text.encode(), tree[name][1])

    makefile = replace(read("Makefile"), "PKG_RELEASE:=1\n", "PKG_RELEASE:=1-qsdk6\n")
    makefile = replace(makefile, "PKG_PO_VERSION:=$(PKG_VERSION)\n",
                       "PKG_PO_VERSION:=$(PKG_VERSION)\nLUCI_NAME:=luci-app-passwall\noverride PKG_BUILD_DIR:=$(BUILD_DIR)/luci-app-passwall-native-$(PKG_VERSION)\n")
    # Upstream Kconfig selects these at image-build time. A feed-only install
    # has no Kconfig step, so the QSDK fw3 variant needs real runtime Depends.
    # This installs userspace only; it does not claim or fake kernel support.
    makefile = replace(makefile, "+microsocks +resolveip +tcping +lyaml\n",
                       "+microsocks +resolveip +tcping +lyaml\nLUCI_DEPENDS+=+ipset +iptables +ip6tables +ipt2socks +sbe-passwall-iptables-extensions\n")
    save("Makefile", makefile)

    # Xray's latest tagged release (26.3.27) uses these original tunnel keys.
    # The upstream development branch also accepts them as compatibility
    # aliases. Unknown new keys pass `xray -test` but silently select TCP-only,
    # breaking the UDP DNS inbound. Keep the core itself unmodified.
    name = "luasrc/passwall/util_xray.lua"
    text = read(name)
    for old, new, count in (("allowedNetwork", "network", 6),
                            ("rewriteAddress", "address", 2), ("rewritePort", "port", 2)):
        text = replace(text, old, new, count)
    save(name, text)

    controller = "luasrc/controller/passwall.lua"
    text = read(controller)
    # Separate legacy-dispatcher fix: string.dump(index) loses outer upvalues.
    text = replace(text, 'function index()\n\tif not nixio.fs.access(',
                   'function index()\n\tlocal nixio = require "nixio"\n\tif not nixio.fs.access(')
    text = replace(text, 'local fs = api.fs\nlocal http',
                   'local fs = api.fs\nlocal nixio = require "nixio"\nlocal compat = require "luci.passwall.compat"\nlocal http')
    text = function(text, "link_add_node", r'''
function link_add_node()
	local path = "/tmp/passwall-links-upload"
	local group = http.formvalue("group") or "default"
	local ok, complete = compat.receive_upload(path, http.formvalue("chunk"),
		tonumber(http.formvalue("chunk_index")), tonumber(http.formvalue("total_chunks")), false)
	if not ok then http.status(400, complete); return end
	if complete then
		luci.sys.call("lua /usr/share/passwall/subscribe.lua add " .. util.shellquote(group))
		fs.remove(path)
	end
	http.status(200, "OK")
end
''')
    # The upstream subscriber consumes this exact input file.
    text = replace(text, 'local path = "/tmp/passwall-links-upload"', 'local path = "/tmp/links.conf"')
    text = replace(text, 'url = "-w %{http_code}:%{time_pretransfer} " .. url',
                   'url = "-w %{http_code}:%{time_pretransfer} " .. util.shellquote(url or "")')
    text = replace(text, '"-x socks5h://" .. socks_server .. " " .. url',
                   '"-x " .. util.shellquote("socks5h://" .. socks_server) .. " " .. url', 2)
    text = replace(text, '''local code = tonumber(luci.sys.exec("echo -n '" .. result .. "' | awk -F ':' '{print $1}'") or "0")''',
                   '''local code = tonumber((result or ""):match("^(%d+):")) or 0''', 2)
    text = replace(text, '''local use_time_str = luci.sys.exec("echo -n '" .. result .. "' | awk -F ':' '{print $2}'")''',
                   '''local use_time_str = (result or ""):match(":([0-9.]+)") or ""''', 2)
    # Preserve native TCP Ping and every node type, quoting only its arguments.
    text = replace(text, 'port, address))', 'util.shellquote(tostring(port or "")), util.shellquote(address)))')
    text = replace(text, '"echo -n $(ping -c 1 -W 1 %q 2>&1', '"echo -n $(ping -c 1 -W 1 %s 2>&1')
    text = replace(text, '''2>/dev/null" % address)''', '''2>/dev/null" % util.shellquote(address))''')
    text = replace(text, 'local aliyun = string.find(url, "aliyun")', 'local aliyun = string.find(url or "", "aliyun", 1, true)')
    text = replace(text, 'local config_file = api.TMP_PATH .. "/config_" .. id',
                   'if not compat.valid_id(id) then http.status(400, "Invalid node id"); return end\n\tlocal config_file = api.TMP_PATH .. "/config_" .. id')
    text = replace(text, 'id, id, config_file))',
                   'util.shellquote(id), util.shellquote(id), util.shellquote(config_file)))')
    text = replace(text, 'http.write(luci.sys.exec("cat " .. config_file))\n\t\tluci.sys.call("rm -f " .. config_file)',
                   'http.write(fs.readfile(config_file) or "")\n\t\tfs.remove(config_file)')
    text = replace(text, 'id, "urltest_node"))', 'util.shellquote(id), "urltest_node"))')
    text = replace(text, 'local result = luci.sys.exec(string.format("/usr/share/passwall/test.sh url_test_node',
                   'if not compat.valid_id(id) then http.status(400, "Invalid node id"); return end\n\tlocal result = luci.sys.exec(string.format("/usr/share/passwall/test.sh url_test_node')
    # A quoted filename is not a shell fragment. Use regular file APIs for logs.
    text = replace(text, 'luci.sys.exec("cat " .. f_file)', 'fs.readfile(f_file) or ""')
    text = replace(text, 'local f_file = api.S_TMP_PATH .. "/" .. id .. ".log"',
                   'if not compat.valid_id(id) then http.status(400, "Invalid log id"); return end\n\tlocal f_file = api.S_TMP_PATH .. "/" .. id .. ".log"')
    text = replace(text, 'local path = api.TMP_PATH .. "/acl/" .. id',
                   'if not compat.valid_id(id) then http.status(400, "Invalid log id"); return end\n\tlocal path = api.TMP_PATH .. "/acl/" .. id')
    text = replace(text, 'local path = api.TMP_PATH .. "/" .. name .. ".log"',
                   'if not compat.valid_id(name) then http.status(400, "Invalid log id"); return end\n\tlocal path = api.TMP_PATH .. "/" .. name .. ".log"')
    text = replace(text, 'local path = api.TMP_PATH .. "/acl/" .. flag .. "/chinadns_ng.log"',
                   'if not compat.valid_id(flag) then http.status(400, "Invalid log id"); return end\n\tlocal path = api.TMP_PATH .. "/acl/" .. flag .. "/chinadns_ng.log"')
    text = replace(text, '"tail -n 5000 ".. path .. "/" .. name .. ".log"',
                   '"tail -n 5000 " .. util.shellquote(path .. "/" .. name .. ".log")')
    text = replace(text, '"tail -n 5000 ".. path', '"tail -n 5000 " .. util.shellquote(path)', 2)
    text = replace(text, '''local cmd = "tar -czf " .. tar_file .. " " .. table.concat(backup_files, " ") .. " " .. "-C /tmp passwall-version"''',
                   '''local names = {}\n\tfor _, file in ipairs(backup_files) do\n\t\tif fs.access(file) then names[#names + 1] = util.shellquote(file) end\n\tend\n\t-- BusyBox tar keeps only one -C directory; absolute inputs retain their\n\t-- native archive names after tar strips the leading slash.\n\tlocal cmd = "tar -C /tmp -czf " .. util.shellquote(tar_file) .. " " .. table.concat(names, " ") .. " passwall-version"''')
    # Restore still supports client/server/all and keeps upstream restart behavior.
    text = replace(text, 'local type = http.formvalue("type")\n\tlocal result = { status = "error", message = "unknown error" }',
                   'local restore_type = http.formvalue("type")\n\tlocal result = { status = "error", message = "unknown error" }')
    start = text.index('\t\tlocal filename = http.formvalue("filename")', text.index('function restore_backup()'))
    end = text.index('\n\t\tif chunk_index + 1 == total_chunks then', start)
    text = text[:start] + '''\t\tif restore_type ~= "client" and restore_type ~= "server" and restore_type ~= "all" then
			result.message = "Invalid restore type"; return
		end
		local file_path = "/tmp/passwall-backup-upload.tar.gz"
		local received, complete = compat.receive_upload(file_path, http.formvalue("chunk"),
			tonumber(http.formvalue("chunk_index")), tonumber(http.formvalue("total_chunks")), true)
		if not received then result.message = complete; return end''' + text[end:]
    text = replace(text, '\t\tif chunk_index + 1 == total_chunks then', '\t\tif complete then')
    text = replace(text, "local temp_dir = '/tmp/passwall_bak'\n\t\t\tluci.sys.call(\"mkdir -p \" .. temp_dir)",
                   '''local temp_dir = api.trim(luci.sys.exec("mktemp -d /tmp/passwall-backup.XXXXXX"))\n\t\t\tif temp_dir == "" then result.message = "Cannot create backup workspace"; return end''')
    text = replace(text, 'luci.sys.call("tar -xzf " .. file_path .. " -C " .. temp_dir)',
                   'luci.sys.call("/usr/libexec/passwall-backup-extract " .. util.shellquote(file_path) .. " " .. util.shellquote(temp_dir))')
    # These occurrences exist only inside restore_backup().
    start = text.index('function restore_backup()')
    end = text.index('\nfunction reset_config()', start)
    body = text[start:end].replace('if type == ', 'if restore_type == ').replace('or type == ', 'or restore_type == ').replace('(type == ', '(restore_type == ')
    body = body.replace('"tar -xOf " .. file_path', '"tar -xOzf " .. util.shellquote(file_path)')
    body = body.replace('"cp -f " .. temp_file .. " " .. backup_file', '"cp -f " .. util.shellquote(temp_file) .. " " .. util.shellquote(backup_file)')
    body = body.replace('"rm -rf " .. temp_dir', '"rm -rf " .. util.shellquote(temp_dir)')
    text = text[:start] + body + text[end:]
    text = replace(text, 'api.log(" * PassWall 备份文件上传成功…")',
                   'api.log(" * " .. i18n.translate("PassWall backup upload completed."))')
    text = replace(text, 'api.log(" * 备份文件由 PassWall " .. version .. " 生成。")',
                   'api.log(" * " .. i18n.translatef("The backup was created by PassWall %s.", version))')
    text = replace(text, 'api.log(" * PassWall 备份还原成功…")',
                   'api.log(" * " .. i18n.translate("PassWall backup restored successfully."))')
    text = replace(text, 'api.log(" * 重启 PassWall 服务中…\\n")',
                   'api.log(" * " .. i18n.translate("Restarting PassWall service…") .. "\\n")')
    text = replace(text, 'api.log(" * PassWall 备份文件解压失败，请重试！")',
                   'api.log(" * " .. i18n.translate("Failed to extract the PassWall backup. Please try again."))')
    text = replace(text, 'api.log(" * 恢复默认配置成功。")',
                   'api.log(" * " .. i18n.translate("Default configuration restored successfully."))')
    text = replace(text, 'api.log(" * 找不到默认配置文件，重置失败！")',
                   'api.log(" * " .. i18n.translate("Default configuration file was not found; reset failed."))')
    save(controller, text)

    name = "luasrc/passwall/api.lua"
    text = read(name)
    text = replace(text, 'i18n = require "luci.i18n"\n\nappname = "passwall"', '''i18n = require "luci.i18n"
local language_ok, configured_language = pcall(uci.get, uci, "luci", "main", "lang")
if language_ok and configured_language and configured_language ~= "" and configured_language ~= "auto" then
	i18n.setlanguage(configured_language)
end

appname = "passwall"''')
    text = function(text, "sh_uci_get", '''function sh_uci_get(config, section, option)
	local key = table.concat({config, section, option}, ".")
	local _, val = exec_call("uci -q get " .. util.shellquote(key))
	return val
end''')
    text = function(text, "sh_uci_set", '''function sh_uci_set(config, section, option, val, commit)
	local key = table.concat({config, section, option}, ".") .. "=" .. tostring(val)
	exec_call("uci -q set " .. util.shellquote(key))
	if commit then sh_uci_commit(config) end
end''')
    text = function(text, "sh_uci_del", '''function sh_uci_del(config, section, option, commit)
	local key = config .. "." .. section .. (option and ("." .. option) or "")
	exec_call("uci -q delete " .. util.shellquote(key))
	if commit then sh_uci_commit(config) end
end''')
    text = function(text, "sh_uci_add_list", '''function sh_uci_add_list(config, section, option, val, commit)
	local key = table.concat({config, section, option}, ".") .. "=" .. tostring(val)
	exec_call("uci -q del_list " .. util.shellquote(key))
	exec_call("uci -q add_list " .. util.shellquote(key))
	if commit then sh_uci_commit(config) end
end''')
    text = function(text, "sh_uci_commit", '''function sh_uci_commit(config)
	exec_call("uci -q commit " .. util.shellquote(config))
end''')
    text = function(text, "get_cache_var", '''function get_cache_var(key)
	local val = trim(sys.exec('. /usr/share/passwall/utils.sh ; get_cache_var ' .. util.shellquote(key)))
	return val ~= "" and val or nil
end''')
    text = function(text, "set_cache_var", '''function set_cache_var(key, val)
	sys.call('. /usr/share/passwall/utils.sh ; set_cache_var ' .. util.shellquote(key) .. " " .. util.shellquote(tostring(val)))
end''')
    text = function(text, "finded_com", '''function finded_com(e)
	local bin = get_app_path(e)
	if not bin then return end
	local value = trim(sys.exec("command -v " .. util.shellquote(bin) .. " 2>/dev/null | head -n1"))
	return value ~= "" and value or nil
end''')
    text = function(text, "finded", '''function finded(e)
	return trim(sys.exec("command -v " .. util.shellquote(e) .. " 2>/dev/null | head -n1"))
end''')
    text = replace(text, 'args[#args + 1] = "-o " .. file', 'args[#args + 1] = "-o " .. util.shellquote(file)')
    text = replace(text, '''local cmd = string.format('curl %s "%s"', table_join(args), url)''',
                   '''local cmd = "curl " .. table_join(args) .. " -- " .. util.shellquote(url)''')
    text = replace(text, '"-x socks5h://" .. socks_server', '"-x " .. util.shellquote("socks5h://" .. socks_server)')
    text = replace(text, '"--resolve " .. domain .. ":" .. port .. ":" .. ip',
                   '"--resolve " .. util.shellquote(domain .. ":" .. port .. ":" .. ip)')
    text = replace(text, '''"echo -n $(md5sum " .. file .. " | awk '{print $1}')"''',
                   '''"echo -n $(md5sum " .. util.shellquote(file) .. " | awk '{print $1}')"''')
    text = replace(text, 'string.format("echo -n $(%s %s)", file, cmd)',
                   'string.format("echo -n $(%s %s)", util.shellquote(file), cmd)')
    # Updater uses explicit argv already. Limit its temporary input to the file
    # it downloaded, not a user core destination; custom core paths remain native.
    text = replace(text, 'local tmp_file = trim(util.exec("mktemp -u -t ".. app_name .."_download.XXXXXX"))',
                   'local tmp_file = trim(util.exec("mktemp -t ".. app_name .."_download.XXXXXX"))')
    start = text.index('\tif tools_name then\n\t\tif tools_name == "unzip" then', text.index('function to_extract('))
    end = text.index('\n\tlocal files = util.split(table.concat(output))', start)
    text = text[:start] + '''\tif tools_name then
		local status = exec("/usr/libexec/passwall-core-extract", {tools_name, file, com[app_name].name:lower(), tmp_dir})
		if status ~= 0 then
			return {code = 1, error = i18n.translate("Failed to extract the component archive.")}
		end
	end
''' + text[end:]
    save(name, text)

    name = "luasrc/passwall/server_app.lua"
    text = replace(read(name),
                   'log(string.format("%s 生成配置文件并运行 - %s", remarks, config_file))',
                   'log(api.i18n.translatef("%s generated a configuration and started: %s", remarks, config_file))')
    save(name, text)

    name = "luasrc/passwall/util_sing-box.lua"
    text = read(name)
    text = replace(text, 'api.log("！！！注意：缺少 Geoview 组件或版本过低，Sing-Box 分流无法启用！")',
                   'api.log(api.i18n.translate("Warning: Geoview is missing or too old; Sing-Box routing cannot be enabled."))')
    text = replace(text, 'api.log(string.format("  - %s:%s 转换为srs格式：%s", prefix, rule_name, status))',
                   'api.log(api.i18n.translatef("Failed to convert %s:%s to SRS format: %s", prefix, rule_name, status))')
    save(name, text)

    for name in ("luasrc/passwall/util_shadowsocks.lua", "luasrc/passwall/util_naiveproxy.lua", "luasrc/passwall/util_hysteria2.lua"):
        text = replace(read(name), 'print("node 不能为空")',
                       'print(api.i18n.translate("Node cannot be empty."))')
        save(name, text)

    name = "luasrc/view/passwall/global/backup.htm"
    text = replace(read(name), 'throw new Error("备份失败！");',
                   'throw new Error("<%:Backup failed!%>");')
    save(name, text)

    name = "root/usr/share/passwall/subscribe.lua"
    text = replace(read(name), "'--user-agent \"' .. ua .. '\"'", '"--user-agent " .. api.util.shellquote(ua)')
    save(name, text)

    name = "root/usr/share/passwall/0_default_config"
    text = read(name)
    text = replace(text, "option prefer_nft '1'", "option prefer_nft '0'")
    text = replace(text, "option dns_shunt 'chinadns-ng'", "option dns_shunt 'dnsmasq'")
    text = replace(text, "option dns_mode 'tcp'", "option dns_mode 'xray'")
    save(name, text)
    name = "root/etc/uci-defaults/luci-app-passwall"
    text = read(name)
    text = replace(text, 'if [ -e "/etc/config/ucitrack" ]; then\n'
                         '\tuci -q batch <<-EOF\n'
                         ' \t\tdelete ucitrack.@passwall[-1]', '''if [ -e "/etc/config/ucitrack" ]; then
	uci -q delete ucitrack.@passwall[-1] 2>/dev/null || true
	uci -q batch <<-EOF''')
    text = replace(text, '''uci -q batch <<-EOF
	delete firewall.passwall''', '''uci -q delete firewall.passwall 2>/dev/null || true
uci -q batch <<-EOF''')
    save(name, text)
    name = "root/etc/uci-defaults/luci-app-passwall_server"
    text = replace(read(name), '''if [ -e "/etc/config/ucitrack" ]; then
	uci -q batch <<-EOF
		delete ucitrack.@passwall_server[-1]''', '''if [ -e "/etc/config/ucitrack" ]; then
	uci -q delete ucitrack.@passwall_server[-1] 2>/dev/null || true
	uci -q batch <<-EOF''')
    save(name, text)

    name = "po/zh-cn/passwall.po"
    text = read(name)
    translations = {
        "%s generated a configuration and started: %s": "%s 已生成配置并启动：%s",
        "Backup failed!": "备份失败！",
        "Default configuration file was not found; reset failed.": "找不到默认配置文件，重置失败。",
        "Default configuration restored successfully.": "已恢复默认配置。",
        "Failed to convert %s:%s to SRS format: %s": "%s:%s 转换为 SRS 格式失败：%s",
        "Failed to extract the PassWall backup. Please try again.": "PassWall 备份文件解压失败，请重试。",
        "Node cannot be empty.": "节点不能为空。",
        "PassWall backup restored successfully.": "PassWall 备份还原成功。",
        "PassWall backup upload completed.": "PassWall 备份文件上传成功。",
        "Restarting PassWall service…": "正在重启 PassWall 服务……",
        "The backup was created by PassWall %s.": "备份文件由 PassWall %s 生成。",
        "Warning: Geoview is missing or too old; Sing-Box routing cannot be enabled.": "警告：缺少 Geoview 组件或版本过低，无法启用 Sing-Box 分流。",
    }
    for msgid in translations:
        if f'msgid "{msgid}"' in text:
            raise ValueError(f"translation already exists: {msgid}")
    for msgid, msgstr in translations.items():
        text += f'\nmsgid "{msgid}"\nmsgstr "{msgstr}"\n'
    save(name, text)

    return ["candidate-release-and-isolated-build-directory", "legacy-index-local-require", "quoted-arguments-and-trimmed-results",
            "ordered-uploads-and-fixed-member-backup-extraction", "fw3-and-dnsmasq-xray-defaults", "legacy-uci-first-install-delete",
            "english-source-and-simplified-chinese-runtime-messages", "released-xray-tunnel-schema"]
