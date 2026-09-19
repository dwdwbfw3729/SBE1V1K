-- Compatibility helpers shared by the native controller; no core restrictions.
local fs = require "nixio.fs"
local nixio = require "nixio"
local M = {}

function M.valid_id(value)
	return type(value) == "string" and value:match("^[A-Za-z0-9_%-]+$") ~= nil
end

-- Keep the upstream web upload limit (10 MiB), accept all node/config types,
-- reset the first chunk, and reject a reordered upload instead of corrupting it.
function M.receive_upload(path, chunk, index, total, base64)
	local state = path .. ".state"
	if type(chunk) ~= "string" or type(index) ~= "number" or type(total) ~= "number" or
		index % 1 ~= 0 or total % 1 ~= 0 or index < 0 or total < 1 or index >= total then
		return nil, "Invalid upload sequence"
	end
	local decoded = chunk
	if base64 then decoded = nixio.bin.b64decode(chunk) end
	if not decoded then return nil, "Invalid upload data" end
	if index == 0 then
		fs.remove(path)
		fs.remove(state)
	elseif fs.readfile(state) ~= tostring(total) .. ":" .. tostring(index) then
		return nil, "Out-of-order upload"
	end
	local size = tonumber(fs.stat(path, "size")) or 0
	if size + #decoded > 10 * 1024 * 1024 then return nil, "File size exceeds 10MB limit." end
	local handle = io.open(path, index == 0 and "wb" or "ab")
	if not handle then return nil, "Cannot create upload file" end
	local written, error = handle:write(decoded)
	handle:close()
	if not written then return nil, error end
	if index + 1 == total then
		fs.remove(state)
		return true, true
	end
	fs.writefile(state, tostring(total) .. ":" .. tostring(index + 1))
	return true, false
end

return M
