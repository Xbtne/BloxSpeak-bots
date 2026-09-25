-- BloxSpeak bot SDK for Lune (https://github.com/lune-org/lune).
-- The bloxspeak-sdk runner loads this file as the global `BloxSpeak`, after setting the Lune libraries
-- (net, task, serde, fs, stdio, datetime, process) as globals.
--
-- How a bot talks to BloxSpeak (the same routes and sockets as the website, signed in with "Authorization: Bot <token>"):
--   REST:    /api/...  (servers, members, roles, chats, status, usage)
--   Sockets: /api/me/ws (UserHub: servers joined and left, new chats), /api/me/presence (online status),
--            /api/servers/:id/hub (ServerHub: members joined and left), one socket per channel or chat
--            (messages, edits, deletes, reactions, and sending).
-- Every connect and request counts toward the bot's 2,000 daily actions (an open socket reconnects about 24 times a day).

local net = net
local task = task
local serde = serde
local datetime = datetime

local DEFAULT_URL = "https://bloxspeak.com"
local OP_TIMEOUT = 15 -- seconds to wait for the answer to a socket action
local PING_EVERY = 30 -- keepalive "ping" text frame, answered by the server without waking it
local CHAT_IDLE = 15 * 60 -- chat sockets close after this long unused
local BACKOFF_MAX = 60
-- A message that arrives while a room's socket is still opening is caught up from the room's first page.
local LATE_WINDOW_MS = 15000
local NEWEST_ID = "fFgnDxSe7" -- the largest public id (2^53 - 1), used to ask for the newest page
local ID_EPOCH_MS = 1767225600000 -- 2026-01-01 UTC, from worker/ids.js
local USER_AGENT = "BloxSpeakSDK/0.1.0 (+https://bloxspeak.com/dev)"

local PERMISSIONS = {
	ViewChannels = 1,
	SendMessages = 2,
	ManageMessages = 4,
	ManageChannels = 8,
	ManageRoles = 16,
	ManageServer = 32,
	Kick = 64,
	Ban = 128,
	CreateInvite = 256,
	PingAll = 512,
	PingActive = 1024,
	MuteMembers = 2048,
	ViewAuditLog = 4096,
	ManageFilter = 8192,
}
local STATUSES = { Online = 0, Idle = 1, DoNotDisturb = 2, Offline = 3 }

math.randomseed(os.time() + math.floor(os.clock() * 1e6))

-- ---------------------------------------------------------------- helpers

local function nowMs()
	return datetime.now().unixTimestampMillis
end

local function encode(value)
	return serde.encode("json", value)
end

local function decode(text)
	local ok, value = pcall(serde.decode, "json", text)
	return ok and value or nil
end

local BASE62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

-- Same as toPublicId in worker/ids.js: 9 base62 characters, which sort like the numbers.
local function toPublicId(n)
	local out = {}
	while n > 0 do
		local digit = n % 62
		table.insert(out, 1, string.sub(BASE62, digit + 1, digit + 1))
		n = (n - digit) / 62
	end
	return string.rep("0", 9 - #out) .. table.concat(out)
end

local function fromPublicId(id)
	local n = 0
	for i = 1, #id do
		n = n * 62 + (string.find(BASE62, string.sub(id, i, i), 1, true) - 1)
	end
	return n
end

-- The smallest message id at a given time.
local function idAt(ms)
	return toPublicId(math.max(0, ms - ID_EPOCH_MS) * 4096)
end

-- First line of a Lua error (no stack trace).
local function firstLine(err)
	return string.match(tostring(err), "^[^\n]*")
end

local function nonce()
	return string.format("%08x%08x", math.random(0, 0x7fffffff), math.random(0, 0x7fffffff))
end

-- ---------------------------------------------------------------- Error

local Error = {}
Error.__index = Error
Error.__tostring = function(e)
	return e.Code .. ": " .. e.Message
end

local function newError(code, message, retryAfter)
	return setmetatable({ Code = code, Message = message, RetryAfter = retryAfter }, Error)
end

-- From a server error body or frame: { code, error, retryAfter (ms)?, resetAt (ms)? }.
local function errorFrom(t)
	local retry = nil
	if type(t.retryAfter) == "number" then
		retry = t.retryAfter / 1000
	elseif type(t.resetAt) == "number" then
		retry = math.max(0, (t.resetAt - nowMs()) / 1000)
	end
	return newError(t.code or "SERVER_ERROR", t.error or "Something went wrong.", retry)
end

-- ---------------------------------------------------------------- Signal

local Connection = {}
Connection.__index = Connection
Connection.__tostring = function()
	return "Connection"
end

function Connection:Disconnect()
	if not self.Connected then
		return
	end
	self.Connected = false
	local list = self._signal._handlers
	local i = table.find(list, self)
	if i then
		table.remove(list, i)
	end
end

local Signal = {}
Signal.__index = Signal
Signal.__tostring = function()
	return "Signal"
end

local function newSignal()
	return setmetatable({ _handlers = {} }, Signal)
end

function Signal:Connect(fn)
	local c = setmetatable({ Connected = true, _fn = fn, _signal = self }, Connection)
	table.insert(self._handlers, c)
	return c
end

function Signal:Once(fn)
	local c
	c = self:Connect(function(...)
		c:Disconnect()
		fn(...)
	end)
	return c
end

function Signal:Wait()
	local thread = coroutine.running()
	self:Once(function(...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

-- Every handler runs in its own thread, so one slow or failing handler never blocks the others.
function Signal:_fire(...)
	for _, c in table.clone(self._handlers) do
		if c.Connected then
			task.spawn(c._fn, ...)
		end
	end
end

-- ---------------------------------------------------------------- WebSocket client
-- Lune's net.socket can't send headers, and bots sign in with an Authorization header, so this is a small
-- RFC 6455 client over net.tcp (text frames, fragments, ping/pong and close).

local WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64(s)
	local out = {}
	for i = 1, #s, 3 do
		local a, b, c = string.byte(s, i, i + 2)
		local n = bit32.lshift(a, 16) + bit32.lshift(b or 0, 8) + (c or 0)
		local chunk = {}
		for k = 0, 3 do
			local idx = bit32.band(bit32.rshift(n, 18 - 6 * k), 63) + 1
			chunk[k + 1] = string.sub(B64, idx, idx)
		end
		if not b then
			chunk[3], chunk[4] = "=", "="
		elseif not c then
			chunk[4] = "="
		end
		table.insert(out, table.concat(chunk))
	end
	return table.concat(out)
end

local function randomBytes(n)
	local t = table.create(n)
	for i = 1, n do
		t[i] = math.random(0, 255)
	end
	return string.char(table.unpack(t))
end

local function xorMask(data, mask)
	local m = { string.byte(mask, 1, 4) }
	local buf = buffer.fromstring(data)
	for i = 0, #data - 1 do
		buffer.writeu8(buf, i, bit32.bxor(buffer.readu8(buf, i), m[i % 4 + 1]))
	end
	return buffer.tostring(buf)
end

local Socket = {}
Socket.__index = Socket

function Socket:_fill()
	local ok, chunk = pcall(self._tcp.read, self._tcp, 65536)
	if not ok or chunk == nil or chunk == "" then
		return false
	end
	self._buf ..= chunk
	return true
end

function Socket:_take(n)
	while #self._buf < n do
		if not self:_fill() then
			return nil
		end
	end
	local s = string.sub(self._buf, 1, n)
	self._buf = string.sub(self._buf, n + 1)
	return s
end

function Socket:_write(op, payload)
	local len = #payload
	local header
	if len < 126 then
		header = string.char(0x80 + op, 0x80 + len)
	elseif len < 65536 then
		header = string.char(0x80 + op, 0x80 + 126) .. string.pack(">I2", len)
	else
		header = string.char(0x80 + op, 0x80 + 127) .. string.pack(">I8", len)
	end
	local mask = randomBytes(4)
	self._tcp:write(header .. mask .. xorMask(payload, mask))
end

function Socket:_finish(code)
	if self.CloseCode == nil then
		self.CloseCode = code
	end
	pcall(self._tcp.close, self._tcp)
end

function Socket:Send(text)
	if self.CloseCode ~= nil then
		return false
	end
	local ok = pcall(self._write, self, 1, text)
	return ok
end

function Socket:Close(code)
	if self.CloseCode ~= nil then
		return
	end
	pcall(self._write, self, 8, string.pack(">I2", code or 1000))
	self:_finish(code or 1000)
end

-- Yields until the next text message; nil once the socket is closed (CloseCode says why, 1006 for a dropped line).
function Socket:Next()
	local parts = nil
	while true do
		local head = self:_take(2)
		if not head then
			self:_finish(1006)
			return nil
		end
		local b1, b2 = string.byte(head, 1, 2)
		local fin = bit32.band(b1, 0x80) ~= 0
		local op = bit32.band(b1, 0x0F)
		local len = bit32.band(b2, 0x7F)
		if len == 126 then
			local ext = self:_take(2)
			len = ext and string.unpack(">I2", ext)
		elseif len == 127 then
			local ext = self:_take(8)
			len = ext and string.unpack(">I8", ext)
		end
		local mask = len and bit32.band(b2, 0x80) ~= 0 and self:_take(4) or nil
		local data = len and (len == 0 and "" or self:_take(len))
		if not data then
			self:_finish(1006)
			return nil
		end
		if mask then
			data = xorMask(data, mask)
		end
		if op == 8 then
			local code = #data >= 2 and string.unpack(">I2", data) or 1005
			pcall(self._write, self, 8, string.sub(data, 1, 2))
			self:_finish(code)
			return nil
		elseif op == 9 then
			pcall(self._write, self, 10, data)
		elseif op == 0 or op == 1 or op == 2 then
			parts = parts or {}
			table.insert(parts, data)
			if fin then
				return table.concat(parts)
			end
		end
	end
end

-- Opens a TCP (or TLS) stream for an http(s):// or ws(s):// URL. Returns tcp, "host[:port]", path | nil, Error.
local function openTcp(url)
	local scheme, rest = string.match(url, "^(%a+)://(.+)$")
	local secure = scheme == "https" or scheme == "wss"
	if not secure and scheme ~= "http" and scheme ~= "ws" then
		return nil, newError("INVALID_URL", "Not a valid URL: " .. url)
	end
	local hostPort, path = string.match(rest, "^([^/]+)(.*)$")
	local host, port = string.match(hostPort, "^(.-):(%d+)$")
	host = host or hostPort
	port = tonumber(port) or (secure and 443 or 80)
	local ok, tcp = pcall(net.tcp.connect, host, port, { tls = secure })
	if not ok then
		return nil, newError("NETWORK_ERROR", "Couldn't reach BloxSpeak: " .. firstLine(tcp))
	end
	return tcp, hostPort, path ~= "" and path or "/"
end

-- One HTTP/1.1 request over its own connection. Lune's net.request sends the full URL as the request target,
-- which local dev servers refuse, so requests go over net.tcp too. Returns { statusCode, ok, body } | nil, Error.
local function httpRequest(url, method, headers, body)
	local tcp, hostPort, path = openTcp(url)
	if not tcp then
		return nil, hostPort
	end
	local lines = { method .. " " .. path .. " HTTP/1.1", "Host: " .. hostPort, "Connection: close" }
	for name, value in headers do
		table.insert(lines, name .. ": " .. value)
	end
	table.insert(lines, "Content-Length: " .. #(body or ""))
	-- Reads until the whole answer is in (by Content-Length, the end of a chunked body, or the connection closing).
	local raw, split, head = "", nil, nil
	local ok = pcall(function()
		tcp:write(table.concat(lines, "\r\n") .. "\r\n\r\n" .. (body or ""))
		while true do
			if not split then
				split = string.find(raw, "\r\n\r\n", 1, true)
				head = split and string.lower(string.sub(raw, 1, split - 1))
			end
			if head then
				local length = tonumber(string.match(head, "\r\ncontent%-length:%s*(%d+)"))
				if length and #raw - split - 3 >= length then
					break
				elseif string.find(head, "\r\ntransfer%-encoding:%s*chunked") and string.find(raw, "\r\n0\r\n\r\n$") then
					break
				end
			end
			local chunk = tcp:read(65536)
			if chunk == nil or chunk == "" then
				break
			end
			raw ..= chunk
		end
	end)
	pcall(tcp.close, tcp)
	local status = tonumber(string.match(raw, "^HTTP/[%d%.]+ (%d+)"))
	if not split or not status then
		return nil, newError("NETWORK_ERROR", ok and "BloxSpeak sent an unreadable answer." or "The connection dropped.")
	end
	local rest = string.sub(raw, split + 4)
	if string.find(head, "\r\ntransfer%-encoding:%s*chunked") then
		local out, pos = {}, 1
		while true do
			local size, after = string.match(rest, "^(%x+)[^\r\n]*\r\n()", pos)
			size = size and tonumber(size, 16)
			if not size or size == 0 then
				break
			end
			table.insert(out, string.sub(rest, after, after + size - 1))
			pos = after + size + 2
		end
		rest = table.concat(out)
	end
	return { statusCode = status, ok = status >= 200 and status < 300, body = rest }
end

-- Opens a WebSocket. Returns the socket, or nil and an Error.
local function connectSocket(url, headers)
	local tcp, hostPort, path = openTcp(url)
	if not tcp then
		return nil, hostPort
	end
	local key = base64(randomBytes(16))
	local lines = {
		"GET " .. path .. " HTTP/1.1",
		"Host: " .. hostPort,
		"Upgrade: websocket",
		"Connection: Upgrade",
		"Sec-WebSocket-Key: " .. key,
		"Sec-WebSocket-Version: 13",
	}
	for name, value in headers do
		table.insert(lines, name .. ": " .. value)
	end
	local sock = setmetatable({ _tcp = tcp, _buf = "", CloseCode = nil }, Socket)
	if not pcall(tcp.write, tcp, table.concat(lines, "\r\n") .. "\r\n\r\n") then
		sock:_finish(1006)
		return nil, newError("NETWORK_ERROR", "Couldn't reach BloxSpeak.")
	end

	local head
	while true do
		local i = string.find(sock._buf, "\r\n\r\n", 1, true)
		if i then
			head = string.sub(sock._buf, 1, i - 1)
			sock._buf = string.sub(sock._buf, i + 4)
			break
		end
		if #sock._buf > 16384 or not sock:_fill() then
			sock:_finish(1006)
			return nil, newError("NETWORK_ERROR", "The connection closed during the handshake.")
		end
	end

	local status = tonumber(string.match(head, "^HTTP/[%d%.]+ (%d+)"))
	if status ~= 101 then
		sock:_fill()
		sock:_finish(1006)
		local body = decode(string.match(sock._buf, "{.*}") or "")
		if type(body) == "table" and body.code then
			return nil, errorFrom(body)
		end
		return nil, newError("HTTP_" .. tostring(status), "BloxSpeak refused the connection (" .. tostring(status) .. ").")
	end
	local accept
	for line in string.gmatch(head, "[^\r\n]+") do
		local name, value = string.match(line, "^([^:]+):%s*(.-)%s*$")
		if name and string.lower(name) == "sec-websocket-accept" then
			accept = value
		end
	end
	local digest = string.gsub(serde.hash("sha1", key .. WS_GUID), "%x%x", function(x)
		return string.char(tonumber(x, 16))
	end)
	if accept ~= base64(digest) then
		sock:_finish(1006)
		return nil, newError("NETWORK_ERROR", "Bad WebSocket handshake.")
	end
	return sock
end

-- ---------------------------------------------------------------- snapshots

local User = {}
User.__index = User
local Server = {}
Server.__index = Server
local Room = {}
Room.__index = Room
local Message = {}
Message.__index = Message
local Member = {}
Member.__index = Member
local Role = {}
Role.__index = Role

-- print() shows a short label instead of every field (which would include the bot and its token).
User.__tostring = function(u)
	return "User " .. (u.Username or u.Id)
end
Server.__tostring = function(s)
	return "Server " .. (s.Name or s.Id)
end
Room.__tostring = function(r)
	return r.Kind .. " " .. (r.Name or r.Id)
end
Message.__tostring = function(m)
	return "Message " .. m.Id
end
Member.__tostring = function(m)
	return "Member " .. (m.User.Username or m.User.Id)
end
Role.__tostring = function(r)
	return "Role " .. (r.Name or r.Id)
end

local function newUser(bot, id, username)
	return setmetatable({ Id = id, Username = username, _bot = bot }, User)
end

local function newRole(bot, r, serverId)
	return setmetatable({
		Id = r.id,
		Name = r.name,
		Color = r.color,
		Position = r.position,
		Permissions = r.permissions,
		IsDefault = r.isDefault == true,
		_serverId = serverId,
		_bot = bot,
	}, Role)
end

local function newServer(bot, s)
	return setmetatable({ Id = s.id, Name = s.name, OwnerId = s.ownerId, _bot = bot }, Server)
end

-- kind: "Channel" | "Chat" | "Room"
local function newRoom(bot, kind, id, name, serverInfo)
	return setmetatable({
		Id = id,
		Name = name,
		Kind = kind,
		Server = serverInfo and newServer(bot, serverInfo) or nil,
		_bot = bot,
	}, Room)
end

local function secondsOf(ms)
	return type(ms) == "number" and ms / 1000 or nil
end

local function newMessage(bot, m, room)
	local reply = nil
	if type(m.replyTo) == "table" then
		reply = {
			Id = m.replyTo.id,
			AuthorId = m.replyTo.authorId,
			Excerpt = m.replyTo.excerpt,
			Deleted = m.replyTo.deleted == true,
		}
	end
	local attachments = {}
	for _, a in (type(m.attachments) == "table" and m.attachments or {}) do
		table.insert(attachments, { Id = a.id, Url = a.url, Name = a.name, Type = a.type, Size = a.size, Width = a.width, Height = a.height })
	end
	return setmetatable({
		Id = m.id,
		Content = m.content or "",
		Author = newUser(bot, m.authorId, bot._names[m.authorId]),
		Room = room,
		Server = room.Server,
		ReplyTo = reply,
		Attachments = attachments,
		IsSystem = m.type == 1,
		CreatedAt = secondsOf(m.createdAt),
		EditedAt = secondsOf(m.editedAt),
		_bot = bot,
	}, Message)
end

local function newMember(bot, m, state)
	local roles = {}
	local permissions = 0
	local owner = state.info.ownerId == m.id
	for _, r in state.roles do
		if r.isDefault or table.find(m.roleIds or {}, r.id) then
			permissions = bit32.bor(permissions, r.permissions or 0)
			if not r.isDefault then
				table.insert(roles, newRole(bot, r, state.info.id))
			end
		end
	end
	if m.username then
		bot._names[m.id] = m.username
	end
	return setmetatable({
		User = newUser(bot, m.id, m.username),
		Server = newServer(bot, state.info),
		Roles = roles,
		JoinedAt = secondsOf(m.joinedAt),
		MutedUntil = secondsOf(m.mutedUntil),
		_owner = owner,
		_permissions = permissions,
		_bot = bot,
	}, Member)
end

-- ---------------------------------------------------------------- Bot

local Bot = {}
Bot.__index = Bot
Bot.__tostring = function(b)
	return "Bot " .. (b._me and (b._me.Username or b._me.Id) or "(not connected)")
end

local function new(token, options)
	assert(type(token) == "string" and token ~= "", "BloxSpeak.new needs the bot token as a string")
	options = options or {}
	local base = string.gsub(options.BaseUrl or DEFAULT_URL, "/+$", "")
	return setmetatable({
		Connected = newSignal(),
		Disconnected = newSignal(),
		MessageCreated = newSignal(),
		MessageEdited = newSignal(),
		MessageDeleted = newSignal(),
		ReactionAdded = newSignal(),
		ReactionRemoved = newSignal(),
		MemberJoined = newSignal(),
		MemberLeft = newSignal(),
		ServerJoined = newSignal(),
		ServerLeft = newSignal(),
		_token = string.gsub(token, "%s", ""),
		_base = base,
		_wsBase = (string.gsub(string.gsub(base, "^https://", "wss://"), "^http://", "ws://")),
		_running = false,
		_me = nil,
		_names = {}, -- user id -> username
		_servers = {}, -- server id -> { info, roles, channels, hub }
		_rooms = {}, -- "c:<id>" / "d:<id>" -> socket connection
	}, Bot)
end

-- One REST call. Returns ok, data | Error.
function Bot:_request(method, path, body)
	local headers = { Authorization = "Bot " .. self._token, Accept = "application/json", ["User-Agent"] = USER_AGENT }
	local payload = nil
	if method ~= "GET" and method ~= "DELETE" then
		headers["Content-Type"] = "application/json"
		payload = body and encode(body) or "{}"
	end
	local res, netErr = httpRequest(self._base .. path, method, headers, payload)
	if not res then
		return false, netErr
	end
	local data = decode(res.body)
	if res.ok then
		return true, type(data) == "table" and data or {}
	end
	local err
	if type(data) == "table" and data.code then
		err = errorFrom(data)
	elseif res.statusCode == 429 then
		err = newError("RATE_LIMITED", "Too many requests. Try again later.")
	else
		err = newError("HTTP_" .. res.statusCode, "BloxSpeak answered " .. res.statusCode .. ".")
	end
	if res.statusCode == 401 then
		self:_stop(err)
	end
	return false, err
end

-- Fills the username cache for ids it doesn't know yet (1 request per 50 unknown ids).
function Bot:_resolveNames(ids)
	local missing, seen = {}, {}
	for _, id in ids do
		if id and self._names[id] == nil and not seen[id] then
			seen[id] = true
			table.insert(missing, id)
		end
	end
	for i = 1, #missing, 50 do
		local chunk = table.move(missing, i, math.min(i + 49, #missing), 1, {})
		local ok, data = self:_request("GET", "/api/users?ids=" .. table.concat(chunk, ","))
		if ok and data.users then
			for _, u in data.users do
				self._names[u.id] = u.username or false
			end
		end
	end
end

function Bot:_serverInfo(serverId)
	local state = serverId and self._servers[serverId]
	return state and state.info or nil
end

function Bot:_roomFor(conn)
	if conn.kind == "channel" then
		return newRoom(self, "Channel", conn.id, conn.name, self:_serverInfo(conn.serverId))
	end
	return newRoom(self, "Chat", conn.id, conn.name, nil)
end

-- ---- sockets

-- Keeps one socket open (reconnecting with backoff) until conn.stopped. handlers: onFrame(frame), onOpen(),
-- onGone(code, errFrame) for lost access (4003) or a deleted target (4004).
function Bot:_keep(conn)
	task.spawn(function()
		local backoff = 1
		while self._running and not conn.stopped do
			local ws, err = connectSocket(self._wsBase .. conn.path, { Authorization = "Bot " .. self._token, ["User-Agent"] = USER_AGENT })
			local closeFrame = nil
			if ws then
				conn.ws = ws
				if conn.stopped then
					ws:Close(1000)
				end
				local pinger = task.spawn(function()
					while ws.CloseCode == nil do
						task.wait(PING_EVERY)
						ws:Send("ping")
					end
				end)
				while true do
					local text = ws:Next()
					if not text then
						break
					end
					if text ~= "pong" then
						local frame = decode(text)
						if type(frame) == "table" then
							if frame.type == "error" and frame.close then
								closeFrame = frame
							elseif frame.type == "ready" then
								backoff = 1
								if conn.onOpen then
									conn.onOpen(frame)
								end
							end
							if conn.onFrame then
								conn.onFrame(frame)
							end
						end
					end
				end
				pcall(task.cancel, pinger)
				conn.ws = nil
				if conn.onClosed then
					conn.onClosed()
				end
			end
			if conn.stopped or not self._running then
				break
			end
			local code = (closeFrame and closeFrame.close) or (ws and ws.CloseCode) or 1006
			local reason = closeFrame and errorFrom(closeFrame) or err
			if code == 4401 or (reason and (reason.Code == "INVALID_TOKEN" or reason.Code == "BOT_DISABLED" or reason.Code == "NOT_AUTHENTICATED")) then
				self:_stop(reason or newError("NOT_AUTHENTICATED", "The bot token was reset or the bot was disabled."))
				break
			elseif code == 4003 or code == 4004 or (reason and (reason.Code == "NOT_FOUND" or reason.Code == "NOT_A_MEMBER")) then
				conn.stopped = true
				if conn.onGone then
					conn.onGone(code, closeFrame)
				end
				break
			elseif code ~= 4001 then
				if conn.onDrop then
					conn.onDrop(reason or newError("DISCONNECTED", "The connection dropped."))
				end
				local wait = backoff
				if reason and reason.RetryAfter then
					wait = math.max(wait, reason.RetryAfter + 1)
				end
				task.wait(wait)
				backoff = math.min(backoff * 2, BACKOFF_MAX)
			end
		end
		conn.ws = nil
	end)
	return conn
end

function Bot:_closeConn(conn)
	if not conn then
		return
	end
	conn.stopped = true
	if conn.ws then
		conn.ws:Close(1000)
	end
end

-- ---- rooms (channel and chat sockets)

local function failPending(conn, err)
	local list = conn.pending
	conn.pending = {}
	for _, op in list do
		task.spawn(op.thread, false, err)
	end
end

-- Resolves the first waiting op that this frame answers.
local function settle(conn, frame)
	for i, op in conn.pending do
		local result = op.match(frame)
		if result ~= nil then
			table.remove(conn.pending, i)
			task.spawn(op.thread, true, result)
			return
		end
	end
end

function Bot:_emitMessage(conn, m, signal)
	local room = self:_roomFor(conn)
	self:_resolveNames({ m.authorId })
	signal:_fire(newMessage(self, m, room))
end

function Bot:_onRoomFrame(conn, frame)
	local t = frame.type
	conn.lastUsed = os.clock()
	if t == "ready" then
		-- Catch up on messages sent while this socket was closed or still opening.
		local newest = conn.lastId
		for _, m in frame.messages or {} do
			if conn.lastId and m.id > conn.lastId then
				task.spawn(self._emitMessage, self, conn, m, self.MessageCreated)
			end
			if not newest or m.id > newest then
				newest = m.id
			end
		end
		conn.lastId = newest or idAt(nowMs())
		conn.ready = true
		for _, thread in conn.readyWaiters do
			task.spawn(thread, true)
		end
		conn.readyWaiters = {}
	elseif t == "message" and frame.message then
		if not conn.lastId or frame.message.id > conn.lastId then
			conn.lastId = frame.message.id
		end
		settle(conn, frame)
		task.spawn(self._emitMessage, self, conn, frame.message, self.MessageCreated)
	elseif t == "edit" and frame.message then
		settle(conn, frame)
		task.spawn(self._emitMessage, self, conn, frame.message, self.MessageEdited)
	elseif t == "delete" then
		settle(conn, frame)
		self.MessageDeleted:_fire(frame.id, self:_roomFor(conn))
	elseif t == "reaction" then
		settle(conn, frame)
		task.spawn(function()
			self:_resolveNames({ frame.userId })
			local reaction = {
				Emoji = frame.emoji,
				MessageId = frame.messageId,
				User = newUser(self, frame.userId, self._names[frame.userId]),
				Room = self:_roomFor(conn),
			}
			;(frame.on and self.ReactionAdded or self.ReactionRemoved):_fire(reaction)
		end)
	elseif t == "history" then
		settle(conn, frame)
	elseif t == "error" and not frame.close then
		local err = errorFrom(frame)
		-- Sends carry a nonce; other actions are answered in order.
		for i, op in conn.pending do
			if (frame.nonce and op.nonce == frame.nonce) or (not frame.nonce and not op.isSend) then
				table.remove(conn.pending, i)
				task.spawn(op.thread, false, err)
				return
			end
		end
	end
end

-- kind "channel" (serverId given) or "chat". `late`: opened after the bot connected, so messages from the last
-- few seconds (the one that caused the open) are delivered too.
function Bot:_openRoom(kind, id, serverId, name, late)
	local key = (kind == "channel" and "c:" or "d:") .. id
	local conn = self._rooms[key]
	if conn and not conn.stopped then
		return conn
	end
	conn = {
		kind = kind,
		id = id,
		serverId = serverId,
		name = name,
		path = kind == "channel" and ("/api/servers/" .. serverId .. "/channels/" .. id .. "/ws") or ("/api/dms/" .. id .. "/ws"),
		pending = {},
		readyWaiters = {},
		lastId = late and idAt(nowMs() - LATE_WINDOW_MS) or nil,
		lastUsed = os.clock(),
	}
	conn.onFrame = function(frame)
		self:_onRoomFrame(conn, frame)
	end
	conn.onClosed = function()
		conn.ready = false
		failPending(conn, newError("DISCONNECTED", "The connection dropped. Try again."))
	end
	conn.onGone = function(_, frame)
		self._rooms[key] = nil
		local err = frame and errorFrom(frame) or newError("NOT_FOUND", "That room is gone.")
		for _, thread in conn.readyWaiters do
			task.spawn(thread, false, err)
		end
		conn.readyWaiters = {}
	end
	self._rooms[key] = conn
	return self:_keep(conn)
end

-- Waits until the room's socket is ready. Returns ok, Error?
local function awaitReady(conn)
	if conn.ready then
		return true
	end
	local thread = coroutine.running()
	table.insert(conn.readyWaiters, thread)
	local timer = task.delay(OP_TIMEOUT, function()
		local i = table.find(conn.readyWaiters, thread)
		if i then
			table.remove(conn.readyWaiters, i)
			task.spawn(thread, false, newError("TIMEOUT", "Couldn't connect to the room in time."))
		end
	end)
	local ok, err = coroutine.yield()
	pcall(task.cancel, timer)
	return ok, err
end

-- Sends a frame on a room socket and yields for the answer. match(frame) returns the result or nil.
-- `quietOk`: no answer in time counts as done (reacting twice to the same emoji changes nothing and sends nothing).
function Bot:_roomOp(conn, frame, match, quietOk)
	local ok, err = awaitReady(conn)
	if not ok then
		return false, err
	end
	conn.lastUsed = os.clock()
	local thread = coroutine.running()
	local op = { thread = thread, match = match, nonce = frame.nonce, isSend = frame.type == "send" }
	table.insert(conn.pending, op)
	if not conn.ws or not conn.ws:Send(encode(frame)) then
		table.remove(conn.pending, table.find(conn.pending, op))
		return false, newError("DISCONNECTED", "The connection dropped. Try again.")
	end
	local timer = task.delay(quietOk and 5 or OP_TIMEOUT, function()
		local i = table.find(conn.pending, op)
		if i then
			table.remove(conn.pending, i)
			if quietOk then
				task.spawn(thread, true, true)
			else
				task.spawn(thread, false, newError("TIMEOUT", "BloxSpeak didn't answer in time."))
			end
		end
	end)
	local okResult, result = coroutine.yield()
	pcall(task.cancel, timer)
	return okResult, result
end

-- The socket connection for a Room snapshot, opening a chat socket on demand.
function Bot:_connOf(room)
	if room.Kind == "Channel" then
		local conn = self._rooms["c:" .. room.Id]
		if conn and not conn.stopped then
			return conn
		end
		local serverId = room.Server and room.Server.Id
		if not serverId or not self._servers[serverId] then
			return nil, newError("NOT_FOUND", "Channel not found.")
		end
		return self:_openRoom("channel", room.Id, serverId, room.Name, true)
	elseif room.Kind == "Chat" then
		return self:_openRoom("chat", room.Id, nil, room.Name, true)
	end
	return nil, newError("NOT_ALLOWED", "Bots can't be in rooms.")
end

-- ---- servers

function Bot:_leaveServer(serverId, fire)
	local state = self._servers[serverId]
	if not state then
		return
	end
	self._servers[serverId] = nil
	self:_closeConn(state.hub)
	for key, conn in self._rooms do
		if conn.serverId == serverId then
			self._rooms[key] = nil
			self:_closeConn(conn)
		end
	end
	if fire then
		self.ServerLeft:_fire(newServer(self, state.info))
	end
end

-- Loads a server and opens its hub and channel sockets. Returns the state or nil, Error.
function Bot:_loadServer(serverId, late)
	local ok, data = self:_request("GET", "/api/servers/" .. serverId)
	if not ok then
		return nil, data
	end
	local state = self._servers[serverId]
	if not state then
		state = {}
		self._servers[serverId] = state
		state.hub = self:_keep({
			path = "/api/servers/" .. serverId .. "/hub",
			onFrame = function(frame)
				self:_onHubFrame(serverId, frame)
			end,
			onGone = function()
				self:_leaveServer(serverId, true)
			end,
		})
	end
	state.info = data.server
	state.roles = data.roles or {}
	state.channels = data.channels or {}
	state.me = data.me
	local open = {}
	for _, ch in state.channels do
		open[ch.id] = true
		local conn = self._rooms["c:" .. ch.id]
		if conn then
			conn.name = ch.name
		else
			self:_openRoom("channel", ch.id, serverId, ch.name, late)
		end
	end
	for key, conn in self._rooms do
		if conn.serverId == serverId and not open[conn.id] then
			self._rooms[key] = nil
			self:_closeConn(conn)
		end
	end
	return state
end

function Bot:_onHubFrame(serverId, frame)
	if frame.type == "member" then
		local state = self._servers[serverId]
		if not state then
			return
		end
		task.spawn(function()
			self:_resolveNames({ frame.userId })
			local user = newUser(self, frame.userId, self._names[frame.userId])
			local server = newServer(self, state.info)
			if frame.action == "join" then
				self.MemberJoined:_fire(user, server)
			else
				self.MemberLeft:_fire(user, server)
			end
		end)
	elseif frame.type == "head" and frame.channelId and not self._rooms["c:" .. frame.channelId] then
		-- A channel this bot has no socket for yet (created since, or newly visible): reload the channel list.
		local state = self._servers[serverId]
		if state and not state.reloading then
			state.reloading = true
			task.spawn(function()
				self:_loadServer(serverId, true)
				state.reloading = false
			end)
		end
	end
end

function Bot:_onUserHubFrame(frame)
	if frame.type == "server" and frame.serverId then
		if frame.action == "join" and not self._servers[frame.serverId] then
			task.spawn(function()
				local state = self:_loadServer(frame.serverId, true)
				if state then
					self.ServerJoined:_fire(newServer(self, state.info))
				end
			end)
		elseif frame.action == "leave" then
			self:_leaveServer(frame.serverId, true)
		end
	elseif (frame.type == "unread" or (frame.type == "dm" and frame.action == "add")) and frame.dmId then
		-- A chat got a message while its socket was closed: open it and catch up.
		if not self._rooms["d:" .. frame.dmId] then
			self:_openRoom("chat", frame.dmId, nil, nil, true)
		end
	elseif frame.type == "dmGone" and frame.dmId then
		local conn = self._rooms["d:" .. frame.dmId]
		self._rooms["d:" .. frame.dmId] = nil
		self:_closeConn(conn)
	end
end

-- Loads the server list, opening new servers and dropping ones the bot left. `fire`: announce the changes.
function Bot:_syncServers(fire)
	local ok, data = self:_request("GET", "/api/servers")
	if not ok then
		return false, data
	end
	local listed = {}
	for _, s in data.servers or {} do
		listed[s.id] = true
		if not self._servers[s.id] then
			local state = self:_loadServer(s.id, fire)
			if state and fire then
				self.ServerJoined:_fire(newServer(self, state.info))
			end
		end
	end
	for id in table.clone(self._servers) do
		if not listed[id] then
			self:_leaveServer(id, fire)
		end
	end
	return true
end

function Bot:_stop(err)
	if not self._running then
		return
	end
	self._running = false
	for _, state in self._servers do
		self:_closeConn(state.hub)
	end
	for _, conn in self._rooms do
		self:_closeConn(conn)
		failPending(conn, err)
	end
	self:_closeConn(self._userHub)
	self:_closeConn(self._presence)
	self._servers, self._rooms = {}, {}
	self.Disconnected:_fire(err)
end

-- ---- public: Bot

-- Starts connecting and returns at once. Connected(me) fires when ready, and again after each reconnect.
function Bot:Connect()
	if self._running then
		return
	end
	self._running = true
	task.spawn(function()
		local backoff = 1
		while self._running do
			local ok, data = self:_request("GET", "/api/me")
			if ok and type(data.profile) ~= "table" then
				self:_stop(newError("NOT_BLOXSPEAK", "The server at " .. self._base .. " isn't a BloxSpeak API."))
				return
			end
			if ok then
				self._me = newUser(self, data.profile.id, data.profile.username)
				self._names[data.profile.id] = data.profile.username
				break
			end
			if not self._running then
				return
			end
			if backoff == 1 then
				self.Disconnected:_fire(data)
			end
			task.wait(math.max(backoff, (data.RetryAfter or 0) + 1))
			backoff = math.min(backoff * 2, BACKOFF_MAX)
		end
		if not self._running then
			return
		end
		local dropped = false
		self._userHub = self:_keep({
			path = "/api/me/ws",
			onFrame = function(frame)
				self:_onUserHubFrame(frame)
			end,
			onOpen = function()
				-- The first open connects everything; a reopen after a drop re-syncs and fires Connected again.
				if dropped then
					dropped = false
					task.spawn(function()
						self:_syncServers(true)
						self.Connected:_fire(self._me)
					end)
				end
			end,
			onDrop = function(err)
				if not dropped then
					dropped = true
					self.Disconnected:_fire(err)
				end
			end,
		})
		self._presence = self:_keep({ path = "/api/me/presence" })
		self:_syncServers(false)
		if self._running then
			-- Sweeps chat sockets nobody used for a while.
			task.spawn(function()
				while self._running do
					task.wait(60)
					for key, conn in self._rooms do
						if conn.kind == "chat" and os.clock() - conn.lastUsed > CHAT_IDLE and #conn.pending == 0 then
							self._rooms[key] = nil
							self:_closeConn(conn)
						end
					end
				end
			end)
			self.Connected:_fire(self._me)
		end
	end)
end

-- Closes every connection. The bot stays offline until Connect is called again.
function Bot:Disconnect()
	self:_stop(newError("DISCONNECTED", "Disconnect was called."))
end

-- status: "Online" | "Idle" | "DoNotDisturb" | "Offline"
function Bot:SetStatus(status)
	local value = STATUSES[status]
	if value == nil then
		return false, newError("INVALID_FIELD", "Status must be Online, Idle, DoNotDisturb or Offline.")
	end
	local ok, data = self:_request("PUT", "/api/me/status", { status = value })
	return ok, ok and status or data
end

function Bot:GetServers()
	local ok, data = self:_request("GET", "/api/servers")
	if not ok then
		return false, data
	end
	local list = {}
	for _, s in data.servers or {} do
		table.insert(list, newServer(self, s))
	end
	return true, list
end

-- Any channel in the bot's servers, or a chat the bot is in.
function Bot:GetRoom(id)
	for serverId, state in self._servers do
		for _, ch in state.channels or {} do
			if ch.id == id then
				return true, newRoom(self, "Channel", ch.id, ch.name, self._servers[serverId].info)
			end
		end
	end
	local ok, data = self:_request("GET", "/api/dms")
	if not ok then
		return false, data
	end
	for _, dm in data.dms or {} do
		if dm.id == id then
			if dm.type ~= "dm" then
				return false, newError("NOT_ALLOWED", "Bots can't be in rooms.")
			end
			local other = dm.recipient
			return true, newRoom(self, "Chat", dm.id, other and other.username or nil, nil)
		end
	end
	return false, newError("NOT_FOUND", "Room not found.")
end

-- { ActionsUsed, ActionsLimit, Connections, ResetsAt (Unix seconds) }
function Bot:GetUsage()
	local ok, data = self:_request("GET", "/api/bots/me/usage")
	if not ok then
		return false, data
	end
	return true, {
		ActionsUsed = data.actionsUsed,
		ActionsLimit = data.actionsLimit,
		Connections = data.connections,
		ResetsAt = secondsOf(data.resetsAt),
	}
end

-- ---- public: User

function User:SendDM(content, options)
	local bot = self._bot
	local ok, data = bot:_request("POST", "/api/dms", { profileId = self.Id })
	if not ok then
		return false, data
	end
	return newRoom(bot, "Chat", data.dm.id, self.Username, nil):Send(content, options)
end

-- ---- public: Room

-- options: { ReplyTo: string?, Attachments: {string}? (upload tokens) }
function Room:Send(content, options)
	local bot = self._bot
	local conn, err = bot:_connOf(self)
	if not conn then
		return false, err
	end
	options = options or {}
	local frame = { type = "send", content = content, nonce = nonce() }
	if options.ReplyTo then
		frame.replyTo = options.ReplyTo
	end
	if options.Attachments and #options.Attachments > 0 then
		frame.attachments = options.Attachments
	end
	local room = self
	local ok, result = bot:_roomOp(conn, frame, function(f)
		if f.type == "message" and f.nonce == frame.nonce then
			return f.message
		end
		return nil
	end)
	if not ok then
		return false, result
	end
	return true, newMessage(bot, result, room)
end

-- options: { Limit: number? (1-50, default 50), Before: string? (message id) }. Oldest first.
function Room:GetMessages(options)
	local bot = self._bot
	local conn, err = bot:_connOf(self)
	if not conn then
		return false, err
	end
	options = options or {}
	local frame = { type = "history", before = options.Before or NEWEST_ID, nonce = nonce() }
	local ok, result = bot:_roomOp(conn, frame, function(f)
		return f.type == "history" and f.around == nil and f or nil
	end)
	if not ok then
		return false, result
	end
	local list = result.messages or {}
	local limit = math.clamp(options.Limit or 50, 1, 50)
	local ids = {}
	for _, m in list do
		table.insert(ids, m.authorId)
	end
	bot:_resolveNames(ids)
	local out = {}
	for i = math.max(1, #list - limit + 1), #list do
		table.insert(out, newMessage(bot, list[i], self))
	end
	return true, out
end

-- Shows "typing" to others for a few seconds. Doesn't yield.
function Room:StartTyping()
	local conn = self._bot:_connOf(self)
	if conn and conn.ws and conn.ready then
		conn.ws:Send(encode({ type = "typing" }))
	end
end

-- ---- public: Message

function Message:Reply(content, options)
	options = table.clone(options or {})
	options.ReplyTo = self.Id
	return self.Room:Send(content, options)
end

function Message:Edit(content)
	local bot = self._bot
	local conn, err = bot:_connOf(self.Room)
	if not conn then
		return false, err
	end
	local id, room = self.Id, self.Room
	local ok, result = bot:_roomOp(conn, { type = "edit", id = id, content = content, nonce = nonce() }, function(f)
		return f.type == "edit" and f.message and f.message.id == id and f.message or nil
	end)
	if not ok then
		return false, result
	end
	return true, newMessage(bot, result, room)
end

function Message:Delete()
	local bot = self._bot
	local conn, err = bot:_connOf(self.Room)
	if not conn then
		return false, err
	end
	local id = self.Id
	local ok, result = bot:_roomOp(conn, { type = "delete", id = id, nonce = nonce() }, function(f)
		return f.type == "delete" and f.id == id or nil
	end)
	return ok, ok and true or result
end

local function react(message, emoji, on)
	local bot = message._bot
	local conn, err = bot:_connOf(message.Room)
	if not conn then
		return false, err
	end
	local id, me = message.Id, bot._me and bot._me.Id
	local frame = { type = on and "react" or "unreact", id = id, emoji = emoji, nonce = nonce() }
	local ok, result = bot:_roomOp(conn, frame, function(f)
		local mine = f.type == "reaction" and f.messageId == id and f.emoji == emoji and f.userId == me and f.on == on
		return mine or nil
	end, true)
	return ok, ok and true or result
end

function Message:React(emoji)
	return react(self, emoji, true)
end

function Message:Unreact(emoji)
	return react(self, emoji, false)
end

-- ---- public: Server

local function serverState(server)
	local bot = server._bot
	local state = bot._servers[server.Id]
	if state and state.roles then
		return true, state
	end
	local ok, data = bot:_request("GET", "/api/servers/" .. server.Id)
	if not ok then
		return false, data
	end
	return true, { info = data.server, roles = data.roles or {}, channels = data.channels or {} }
end

function Server:GetChannels()
	local bot = self._bot
	local ok, data = bot:_request("GET", "/api/servers/" .. self.Id)
	if not ok then
		return false, data
	end
	local list = {}
	for _, ch in data.channels or {} do
		table.insert(list, newRoom(bot, "Channel", ch.id, ch.name, data.server))
	end
	return true, list
end

function Server:GetRoles()
	local bot = self._bot
	local ok, data = bot:_request("GET", "/api/servers/" .. self.Id)
	if not ok then
		return false, data
	end
	local list = {}
	for _, r in data.roles or {} do
		table.insert(list, newRole(bot, r, self.Id))
	end
	return true, list
end

-- One page of members (up to the server's page size), by user id. Pass the last member's User.Id as `after`
-- for the next page. Returns ok, {Member}, hasMore.
function Server:GetMembers(after)
	local ok, state = serverState(self)
	if not ok then
		return false, state
	end
	local path = "/api/servers/" .. self.Id .. "/members" .. (after and ("?after=" .. after) or "")
	local okList, data = self._bot:_request("GET", path)
	if not okList then
		return false, data
	end
	local list = {}
	for _, m in data.members or {} do
		table.insert(list, newMember(self._bot, m, state))
	end
	return true, list, data.hasMore == true
end

function Server:GetMember(userId)
	local ok, state = serverState(self)
	if not ok then
		return false, state
	end
	-- Members are paged by id, so the page after (id - 1) starts with this member if they're in the server.
	local n = fromPublicId(userId)
	local path = "/api/servers/" .. self.Id .. "/members" .. (n > 0 and ("?after=" .. toPublicId(n - 1)) or "")
	local okList, data = self._bot:_request("GET", path)
	if not okList then
		return false, data
	end
	local first = data.members and data.members[1]
	if not first or first.id ~= userId then
		return false, newError("NOT_FOUND", "That user isn't in this server.")
	end
	return true, newMember(self._bot, first, state)
end

-- folderId: optional folder to put the channel in.
function Server:CreateChannel(name, folderId)
	local bot = self._bot
	local ok, data = bot:_request("POST", "/api/servers/" .. self.Id .. "/channels", { name = name, categoryId = folderId })
	if not ok then
		return false, data
	end
	local state = bot._servers[self.Id]
	if state then
		table.insert(state.channels, data.channel)
		bot:_openRoom("channel", data.channel.id, self.Id, data.channel.name, true)
	end
	return true, newRoom(bot, "Channel", data.channel.id, data.channel.name, bot:_serverInfo(self.Id) or { id = self.Id, name = self.Name })
end

function Server:Leave()
	local bot = self._bot
	local ok, data = bot:_request("POST", "/api/servers/" .. self.Id .. "/leave", { wipe = false })
	if ok then
		bot:_leaveServer(self.Id, false)
	end
	return ok, ok and true or data
end

-- ---- public: Member

-- name: a permission such as "SendMessages" or "ManageMessages". Uses this snapshot's roles. Doesn't yield.
function Member:HasPermission(name)
	local flag = PERMISSIONS[name]
	assert(flag, "Unknown permission: " .. tostring(name))
	return self._owner or bit32.band(self._permissions, flag) ~= 0
end

local function memberCall(member, method, suffix, body)
	local path = "/api/servers/" .. member.Server.Id .. "/members/" .. member.User.Id .. suffix
	local ok, data = member._bot:_request(method, path, body)
	return ok, ok and true or data
end

local function roleId(role)
	return type(role) == "table" and role.Id or role
end

function Member:AddRole(role)
	return memberCall(self, "PUT", "/roles/" .. roleId(role))
end

function Member:RemoveRole(role)
	return memberCall(self, "DELETE", "/roles/" .. roleId(role))
end

-- seconds: 60 to 604800 (7 days).
function Member:Mute(seconds, reason)
	return memberCall(self, "POST", "/mute", { durationSeconds = seconds, reason = reason })
end

function Member:Unmute()
	return memberCall(self, "DELETE", "/mute")
end

function Member:Kick(reason)
	return memberCall(self, "POST", "/kick", { reason = reason })
end

-- deleteMessages: also delete their messages in this server (default true).
function Member:Ban(reason, deleteMessages)
	return memberCall(self, "POST", "/ban", { reason = reason, wipe = deleteMessages ~= false })
end

return table.freeze({
	new = new,
	Permissions = table.freeze(table.clone(PERMISSIONS)),
	Version = "0.1.0",
})
