--!strict
--[[
    BloxSpeak Tickets Bot - Ultimate Edition
    Instant Channel Creation on Reaction, Reaction Cleanup, Discord-Style Embed Cards,
    Direct Message Notifications, Transcripts, Staff Claims & Render Dashboard.
]]

local process = process or require("@lune/process")
local net = net or require("@lune/net")
local fs = fs or require("@lune/fs")
local serde = serde or require("@lune/serde")
local task = task or require("@lune/task")
local datetime = datetime or require("@lune/datetime")

local BloxSpeak = BloxSpeak or (function()
	local ok, mod = pcall(function() return require("./bloxspeak") end)
	if ok then return mod end
	error("BloxSpeak SDK module failed to load: " .. tostring(mod))
end)()

local BOT_TOKEN = (process and process.env and process.env.BOT_TOKEN and #process.env.BOT_TOKEN > 0) and process.env.BOT_TOKEN or "bsb_0QvB0iMjPKwHHz8wHiSTmE9qkOSD5gRR"
local PREFIX = (process and process.env and process.env.PREFIX and #process.env.PREFIX > 0) and process.env.PREFIX or "!"
local DATA_FILE = "tickets_data.json"
local START_TIME = os.time()

--------------------------------------------------------------------------------
-- 1. Database & Persistence
--------------------------------------------------------------------------------
type TicketRecord = {
	id: number,
	channelId: string,
	channelName: string,
	welcomeMessageId: string?,
	serverId: string,
	serverName: string?,
	creatorId: string,
	creatorName: string,
	reason: string,
	createdAt: number,
	claimedBy: string?,
	claimedByName: string?,
	priority: string,
	status: "open" | "closed",
}

type BotData = {
	ticketCounter: number,
	panelMessageIds: { [string]: boolean },
	ticketWelcomeMessageIds: { [string]: boolean },
	tickets: { [string]: TicketRecord }, -- channelId -> TicketRecord
	closedTickets: { [string]: TicketRecord }, -- ticketId -> TicketRecord
}

local function loadData(): BotData
	local defaultData: BotData = {
		ticketCounter = 0,
		panelMessageIds = {},
		ticketWelcomeMessageIds = {},
		tickets = {},
		closedTickets = {},
	}

	if fs.isFile(DATA_FILE) then
		local ok, content = pcall(function()
			return fs.readFile(DATA_FILE)
		end)
		if ok and content and #content > 0 then
			local decodeOk, decoded = pcall(function()
				return serde.decode("json", content)
			end)
			if decodeOk and type(decoded) == "table" then
				if type(decoded.ticketCounter) == "number" then
					defaultData.ticketCounter = decoded.ticketCounter
				end
				if type(decoded.panelMessageIds) == "table" then
					defaultData.panelMessageIds = decoded.panelMessageIds
				end
				if type(decoded.ticketWelcomeMessageIds) == "table" then
					defaultData.ticketWelcomeMessageIds = decoded.ticketWelcomeMessageIds
				end
				if type(decoded.tickets) == "table" then
					defaultData.tickets = decoded.tickets
				end
				if type(decoded.closedTickets) == "table" then
					defaultData.closedTickets = decoded.closedTickets
				end
			end
		end
	end
	return defaultData
end

local db: BotData = loadData()

local saveScheduled = false
local function saveData()
	if saveScheduled then return end
	saveScheduled = true
	task.delay(0.3, function()
		saveScheduled = false
		pcall(function()
			fs.writeFile(DATA_FILE, serde.encode("json", db, true))
		end)
	end)
end

-- Logging helper
local function log(level: string, msg: string)
	local timeStr = os.date("!%Y-%m-%d %H:%M:%S")
	print(string.format("[%s] [%s] %s", timeStr, level, msg))
end

local function formatTicketNumber(num: number): string
	return string.format("%04d", num)
end

local function getActiveCount(): number
	local count = 0
	for _, _ in pairs(db.tickets) do
		count += 1
	end
	return count
end

local function getClosedCount(): number
	local count = 0
	for _, _ in pairs(db.closedTickets) do
		count += 1
	end
	return count
end

--------------------------------------------------------------------------------
-- 2. Embed Engine
--------------------------------------------------------------------------------
type EmbedField = {
	name: string,
	value: string,
}

type EmbedOptions = {
	title: string?,
	color: string?,
	author: string?,
	description: string?,
	fields: { EmbedField }?,
	footer: string?,
}

local function formatEmbed(opts: EmbedOptions): string
	local lines = {}

	if opts.title and opts.title ~= "" then
		local icon = opts.color or "🔹"
		table.insert(lines, string.format("### %s **%s**", icon, opts.title))
	end

	table.insert(lines, "> ━━━━━━━━━━━━━━━━━━━━━━━━━")

	if opts.author and opts.author ~= "" then
		table.insert(lines, string.format("> 👤 *%s*", opts.author))
		table.insert(lines, "> ")
	end

	if opts.description and opts.description ~= "" then
		for descLine in string.gmatch(opts.description, "[^\r\n]+") do
			table.insert(lines, "> " .. descLine)
		end
	end

	if opts.fields and #opts.fields > 0 then
		if opts.description and opts.description ~= "" then
			table.insert(lines, "> ")
		end
		for _, field in opts.fields do
			table.insert(lines, string.format("> **%s**", field.name))
			for valLine in string.gmatch(field.value, "[^\r\n]+") do
				table.insert(lines, string.format("> • %s", valLine))
			end
		end
	end

	table.insert(lines, "> ━━━━━━━━━━━━━━━━━━━━━━━━━")
	if opts.footer and opts.footer ~= "" then
		table.insert(lines, string.format("> *%s*", opts.footer))
	else
		table.insert(lines, "> *BloxSpeak Tickets System • Fast & Secure*")
	end

	return table.concat(lines, "\n")
end

local function errorEmbed(title: string, message: string): string
	return formatEmbed({
		title = title or "Error",
		color = "❌",
		description = message,
		footer = "BloxSpeak Tickets • Error Notification",
	})
end

local function successEmbed(title: string, message: string, footer: string?): string
	return formatEmbed({
		title = title or "Success",
		color = "✅",
		description = message,
		footer = footer or "BloxSpeak Tickets • Operation Completed",
	})
end

local function warnEmbed(title: string, message: string): string
	return formatEmbed({
		title = title or "Warning",
		color = "⚠️",
		description = message,
		footer = "BloxSpeak Tickets • Notice",
	})
end

local function infoEmbed(title: string, message: string, fields: { EmbedField }?): string
	return formatEmbed({
		title = title or "Information",
		color = "ℹ️",
		description = message,
		fields = fields,
		footer = "BloxSpeak Tickets • Information Card",
	})
end

--------------------------------------------------------------------------------
-- 3. Transcripts & Helpers
--------------------------------------------------------------------------------
pcall(function()
	if not fs.isDir("transcripts") then
		fs.writeDir("transcripts")
	end
end)

local function generateTranscript(room: any, ticket: TicketRecord?): string
	local msgsOk, messages = room:GetMessages({ Limit = 50 })
	local lines = {}
	table.insert(lines, "==================================================")
	table.insert(lines, string.format("         BLOXSPEAK TICKET TRANSCRIPT #%s", ticket and formatTicketNumber(ticket.id) or "0000"))
	table.insert(lines, "==================================================")
	if ticket then
		table.insert(lines, string.format("Creator: %s (ID: %s)", ticket.creatorName, ticket.creatorId))
		table.insert(lines, string.format("Created At: %s UTC", os.date("!%Y-%m-%d %H:%M:%S", ticket.createdAt)))
		table.insert(lines, string.format("Channel: #%s", ticket.channelName or "ticket"))
		table.insert(lines, string.format("Topic/Reason: %s", ticket.reason))
		table.insert(lines, string.format("Priority: %s", ticket.priority))
		if ticket.claimedByName then
			table.insert(lines, string.format("Claimed By: %s (%s)", ticket.claimedByName, ticket.claimedBy or "N/A"))
		end
	end
	table.insert(lines, "--------------------------------------------------")
	table.insert(lines, "MESSAGES LOG:")
	table.insert(lines, "--------------------------------------------------")

	if msgsOk and type(messages) == "table" then
		for _, msg in ipairs(messages) do
			local authorName = (msg.Author and msg.Author.Username) or (msg.Author and msg.Author.Id) or "Unknown"
			local timeStr = msg.CreatedAt and os.date("!%Y-%m-%d %H:%M:%S", msg.CreatedAt) or "N/A"
			local content = msg.Content or ""
			table.insert(lines, string.format("[%s] %s: %s", timeStr, authorName, content))
		end
	else
		table.insert(lines, "(Could not retrieve past message history)")
	end
	table.insert(lines, "==================================================")
	return table.concat(lines, "\n")
end

local function formatUptime(seconds: number): string
	local d = math.floor(seconds / 86400)
	local h = math.floor((seconds % 86400) / 3600)
	local m = math.floor((seconds % 3600) / 60)
	local s = seconds % 60
	if d > 0 then
		return string.format("%dd %dh %dm %ds", d, h, m, s)
	elseif h > 0 then
		return string.format("%dh %dm %ds", h, m, s)
	elseif m > 0 then
		return string.format("%dm %ds", m, s)
	else
		return string.format("%ds", s)
	end
end

--------------------------------------------------------------------------------
-- 4. Bot Core & Instant Ticket Actions
--------------------------------------------------------------------------------
local bot = BloxSpeak.new(BOT_TOKEN)

-- Instant Ticket Creation
local function createTicket(server: any, author: any, initialReason: string?, originRoom: any?, sourceMessage: any?)
	local creatorId = author.Id
	local creatorName = author.Username or ("User_" .. string.sub(creatorId, 1, 4))
	local reason = (initialReason and #initialReason > 0) and initialReason or "General Support / Inquiry"

	db.ticketCounter += 1
	local ticketNum = db.ticketCounter
	local formattedNum = formatTicketNumber(ticketNum)
	local cleanUser = string.gsub(string.lower(creatorName), "[^%w]", "")
	if #cleanUser == 0 then cleanUser = "user" end
	local channelName = string.format("ticket-%s-%s", formattedNum, string.sub(cleanUser, 1, 8))

	log("INFO", string.format("⚡ Instant creation: ticket #%s for %s (%s)", formattedNum, creatorName, creatorId))

	local createOk, roomOrErr = server:CreateChannel(channelName)
	if not createOk or not roomOrErr then
		local errText = string.format("Failed to create ticket channel: %s", tostring(roomOrErr))
		log("ERROR", errText)
		task.spawn(function()
			pcall(function()
				author:SendDM(errorEmbed("Ticket Creation Failed", "Could not create ticket channel. Please contact server admins to ensure bot has `ManageChannels` permission."), nil)
			end)
		end)
		return
	end

	local room = roomOrErr
	local newTicket: TicketRecord = {
		id = ticketNum,
		channelId = room.Id,
		channelName = channelName,
		welcomeMessageId = nil,
		serverId = server.Id,
		serverName = server.Name,
		creatorId = creatorId,
		creatorName = creatorName,
		reason = reason,
		createdAt = os.time(),
		claimedBy = nil,
		claimedByName = nil,
		priority = "🔵 Normal",
		status = "open",
	}

	db.tickets[room.Id] = newTicket
	saveData()

	-- Asynchronously send DM confirmation to user
	task.spawn(function()
		local dmEmbed = formatEmbed({
			title = "Ticket Created Successfully",
			color = "🎫",
			description = string.format("Your private support ticket has been created in **%s**!", server.Name or "Server"),
			fields = {
				{ name = "📌 Channel Name", value = string.format("`#%s`", channelName) },
				{ name = "🆔 Ticket ID", value = string.format("`#%s`", formattedNum) },
				{ name = "📝 Topic", value = reason },
			},
			footer = "Please navigate to your channel to speak with support staff.",
		})
		pcall(function()
			author:SendDM(dmEmbed, nil)
		end)
	end)

	-- Asynchronously send rich welcome embed in new ticket channel
	task.spawn(function()
		local welcomeEmbed = formatEmbed({
			title = string.format("SUPPORT TICKET #%s", formattedNum),
			color = "🎫",
			author = string.format("Opened by @%s", creatorName),
			description = "👋 Welcome to your dedicated support channel! Our staff team will assist you shortly. Please explain your inquiry in detail below.",
			fields = {
				{
					name = "📋 Ticket Information",
					value = string.format("**Ticket ID:** `#%s`\n**Creator:** <@%s>\n**Priority:** `🔵 Normal`\n**Status:** 🟢 Open", formattedNum, creatorId),
				},
				{
					name = "📝 Inquiry / Topic",
					value = string.format("`%s`", reason),
				},
				{
					name = "⚡ Quick Action Reactions",
					value = "🔒 React **🔒** to **Close & Delete**\n🙋‍♂️ React **🙋‍♂️** to **Claim Ticket (Staff)**\n📜 React **📜** to **View Transcript**",
				},
				{
					name = "🛠️ Chat Commands",
					value = string.format("`%sclose` • `%sclaim` • `%sunclaim` • `%spriority` • `%stopic`", PREFIX, PREFIX, PREFIX, PREFIX, PREFIX),
				},
			},
			footer = "BloxSpeak Tickets • React below or use chat commands",
		})

		local sendOk, welcomeMsg = room:Send(welcomeEmbed, nil)
		if sendOk and welcomeMsg then
			newTicket.welcomeMessageId = welcomeMsg.Id
			db.ticketWelcomeMessageIds[welcomeMsg.Id] = true
			saveData()

			pcall(function() welcomeMsg:React("🔒") end)
			pcall(function() welcomeMsg:React("🙋‍♂️") end)
			pcall(function() welcomeMsg:React("📜") end)
		end
	end)

	log("INFO", string.format("Successfully created ticket #%s in channel %s (#%s)", formattedNum, room.Id, channelName))
end

-- Close a ticket with countdown, transcript, and deletion
local function closeTicket(room: any, server: any, user: any, closeReason: string?)
	local ticket = db.tickets[room.Id]
	if not ticket then
		room:Send(warnEmbed("Invalid Channel", "This channel is not recognized as an active support ticket."), nil)
		return
	end

	local closerName = user.Username or ("User_" .. string.sub(user.Id, 1, 4))
	local reason = (closeReason and #closeReason > 0) and closeReason or "Resolved / Closed by user"

	log("INFO", string.format("Closing ticket #%04d by %s (Reason: %s)", ticket.id, closerName, reason))

	-- Generate transcript and save to disk
	local transcript = generateTranscript(room, ticket)
	local transcriptFile = string.format("transcripts/transcript_ticket_%04d_%d.txt", ticket.id, os.time())
	pcall(function()
		fs.writeFile(transcriptFile, transcript)
	end)

	-- Update database
	ticket.status = "closed"
	db.closedTickets[tostring(ticket.id)] = ticket
	db.tickets[room.Id] = nil
	saveData()

	local closeEmbed = formatEmbed({
		title = string.format("Ticket #%04d Closed", ticket.id),
		color = "🔒",
		description = "This ticket has been marked as resolved and closed.",
		fields = {
			{ name = "👤 Closed By", value = string.format("<@%s>", user.Id) },
			{ name = "📝 Reason", value = reason },
			{ name = "📜 Transcript", value = "Archived & saved to database" },
			{ name = "🗑️ Channel Deletion", value = "**This channel will be automatically deleted in 5 seconds...**" },
		},
		footer = "Thank you for contacting support!",
	})

	room:Send(closeEmbed, nil)

	-- Asynchronous deletion countdown
	task.spawn(function()
		task.wait(5)
		log("INFO", string.format("Deleting channel %s for closed ticket #%04d", room.Id, ticket.id))
		local delOk, delRes = bot:_request("DELETE", "/api/servers/" .. server.Id .. "/channels/" .. room.Id)
		if not delOk then
			log("ERROR", string.format("Failed to delete channel %s: %s", room.Id, tostring(delRes)))
		else
			log("INFO", string.format("Successfully deleted channel %s", room.Id))
		end
	end)
end

--------------------------------------------------------------------------------
-- 5. Bot Events
--------------------------------------------------------------------------------
bot.Connected:Connect(function(user)
	log("INFO", string.format("Connected to BloxSpeak as @%s (ID: %s)", user.Username or "TicketBot", user.Id))
	bot:SetStatus("Online")
end)

bot.Disconnected:Connect(function(err)
	log("WARN", string.format("Disconnected: %s (%s)", err.Message or "Unknown error", err.Code or "NO_CODE"))
end)

--------------------------------------------------------------------------------
-- 6. Message Commands Handler
--------------------------------------------------------------------------------
bot.MessageCreated:Connect(function(message)
	if message.IsSystem then return end
	if not message.Author or not message.Content then return end
	if bot._me and message.Author.Id == bot._me.Id then return end

	local content = message.Content
	if string.sub(content, 1, #PREFIX) ~= PREFIX then return end

	local withoutPrefix = string.sub(content, #PREFIX + 1)
	local args = {}
	for word in string.gmatch(withoutPrefix, "%S+") do
		table.insert(args, word)
	end
	if #args == 0 then return end

	local command = string.lower(args[1])
	table.remove(args, 1)
	local argString = table.concat(args, " ")

	local room = message.Room
	local server = message.Server
	local author = message.Author

	-- !help [command]
	if command == "help" or command == "tickethelp" or command == "commands" then
		local subCmd = args[1]
		if subCmd then
			subCmd = string.lower(subCmd)
			local details: { [string]: { title: string, usage: string, desc: string } } = {
				panel = { title = "Ticket Reaction Panel", usage = PREFIX .. "panel", desc = "Deploys the interactive 🎫 Ticket Panel embed with 1-click reaction support." },
				new = { title = "Open Ticket", usage = PREFIX .. "new [reason]", desc = "Opens a new dedicated support ticket channel with full embed controls." },
				close = { title = "Close Ticket", usage = PREFIX .. "close [reason]", desc = "Closes the ticket, archives the transcript, and deletes the channel after 5s." },
				claim = { title = "Claim Ticket", usage = PREFIX .. "claim", desc = "Claims the active ticket so other staff know you are handling it." },
				unclaim = { title = "Unclaim Ticket", usage = PREFIX .. "unclaim", desc = "Releases the ticket claim back to the general staff queue." },
				priority = { title = "Set Priority", usage = PREFIX .. "priority <low|normal|high|urgent>", desc = "Updates the ticket urgency priority level." },
				topic = { title = "Update Topic", usage = PREFIX .. "topic <new reason>", desc = "Updates the inquiry topic and reason for the ticket." },
				transcript = { title = "Export Transcript", usage = PREFIX .. "transcript", desc = "Generates and displays a complete formatted log of ticket messages." },
				info = { title = "Ticket Info", usage = PREFIX .. "info", desc = "Displays creator, claimer, priority, and metadata for current ticket." },
				stats = { title = "System Stats", usage = PREFIX .. "stats", desc = "Displays total open, active, and archived ticket statistics." },
				ping = { title = "Bot Status", usage = PREFIX .. "ping", desc = "Checks bot latency, runtime, and uptime health." },
			}

			local info = details[subCmd]
			if info then
				message:Reply(formatEmbed({
					title = "Command: " .. info.title,
					color = "📖",
					fields = {
						{ name = "📖 Usage", value = string.format("`%s`", info.usage) },
						{ name = "📝 Description", value = info.desc },
					},
					footer = "BloxSpeak Tickets • Command Reference",
				}), nil)
				return
			end
		end

		local helpEmbed = formatEmbed({
			title = "BloxSpeak Tickets Bot - Command Guide",
			color = "🎫",
			description = "High-performance customer support system with rich embed cards and instant reaction controls.",
			fields = {
				{
					name = "📌 User Commands",
					value = string.format("`%snew [reason]` • Open a support ticket\n`%sclose [reason]` • Close & archive ticket\n`%stranscript` • Export message log\n`%sinfo` • View current ticket details\n`%sping` • Check bot health & latency", PREFIX, PREFIX, PREFIX, PREFIX, PREFIX),
				},
				{
					name = "🛡️ Staff Commands",
					value = string.format("`%spanel` • Deploy interactive ticket panel\n`%sclaim` • Claim the active ticket\n`%sunclaim` • Release ticket claim\n`%spriority <level>` • Low, Normal, High, Urgent\n`%stopic <reason>` • Update ticket topic\n`%sstats` • Server ticket metrics", PREFIX, PREFIX, PREFIX, PREFIX, PREFIX, PREFIX),
				},
				{
					name = "⚡ Quick Reactions",
					value = "🎫 **Panel 🎫/📩** ➔ Opens a new ticket instantly & removes reaction\n🔒 **Ticket 🔒** ➔ Closes & deletes ticket channel in 5s\n🙋‍♂️ **Ticket 🙋‍♂️** ➔ Claims ticket for staff\n📜 **Ticket 📜** ➔ Exports message transcript",
				},
			},
			footer = string.format("Type %shelp <command> for parameter details.", PREFIX),
		})

		message:Reply(helpEmbed, nil)
		return
	end

	-- !ping
	if command == "ping" then
		local uptime = formatUptime(os.time() - START_TIME)
		message:Reply(formatEmbed({
			title = "Pong! Bot is Operational",
			color = "🏓",
			description = "BloxSpeak Tickets Bot is running with optimal performance.",
			fields = {
				{ name = "⚡ Status", value = "🟢 Online & Ready" },
				{ name = "⏱️ Uptime", value = string.format("`%s`", uptime) },
				{ name = "🎫 Active Tickets", value = string.format("`%d active`", getActiveCount()) },
			},
			footer = "BloxSpeak Tickets System",
		}), nil)
		return
	end

	-- !new / !ticket / !open [reason]
	if command == "new" or command == "ticket" or command == "open" then
		if not server then
			message:Reply(errorEmbed("Server Only", "Tickets can only be opened inside a server channel."), nil)
			return
		end
		createTicket(server, author, argString, room, message)
		return
	end

	-- !panel / !ticket-panel / !setup
	if command == "panel" or command == "ticket-panel" or command == "setup" then
		if not server then
			message:Reply(errorEmbed("Server Only", "The ticket panel must be deployed in a server channel."), nil)
			return
		end

		local panelEmbed = formatEmbed({
			title = "SUPPORT TICKET SYSTEM",
			color = "🎫",
			description = "Welcome to our customer support center! If you need assistance, want to report an issue, or have questions, open a ticket below.",
			fields = {
				{
					name = "📩 How to Open a Ticket",
					value = "• Click the **🎫** or **📩** reaction below\n• Or type `" .. PREFIX .. "new [your inquiry]` in chat",
				},
				{
					name = "🔒 Instant Support Channel",
					value = "A private dedicated support channel will be created for you instantly, and you will receive a direct message notification!",
				},
			},
			footer = "Click 🎫 below to open a support ticket",
		})

		local sendOk, sentMsg = room:Send(panelEmbed, nil)
		if sendOk and sentMsg then
			db.panelMessageIds[sentMsg.Id] = true
			saveData()
			log("INFO", string.format("Created ticket panel in channel %s (Msg ID: %s)", room.Id, sentMsg.Id))

			task.spawn(function()
				pcall(function() sentMsg:React("🎫") end)
				pcall(function() sentMsg:React("📩") end)
			end)
		else
			message:Reply(errorEmbed("Panel Error", "Failed to deploy the ticket panel. Please check bot permissions."), nil)
		end
		return
	end

	-- !close [reason]
	if command == "close" then
		if not server then return end
		closeTicket(room, server, author, argString)
		return
	end

	-- !transcript
	if command == "transcript" or command == "log" then
		local ticket = db.tickets[room.Id]
		local transcript = generateTranscript(room, ticket)
		
		local preview = string.sub(transcript, 1, 1400)
		if #transcript > 1400 then
			preview = preview .. "\n... [Transcript Truncated due to size limit]"
		end

		message:Reply(formatEmbed({
			title = string.format("Ticket Transcript #%04d", ticket and ticket.id or 0),
			color = "📜",
			description = string.format("```\n%s\n```", preview),
			footer = "BloxSpeak Tickets • Transcript Archive",
		}), nil)
		return
	end

	-- !claim
	if command == "claim" then
		local ticket = db.tickets[room.Id]
		if not ticket then
			message:Reply(warnEmbed("Invalid Channel", "This command can only be used inside an active ticket channel."), nil)
			return
		end

		if ticket.claimedBy then
			message:Reply(warnEmbed("Already Claimed", string.format("This ticket is already claimed by **@%s**!", ticket.claimedByName or "Staff")), nil)
			return
		end

		ticket.claimedBy = author.Id
		ticket.claimedByName = author.Username or ("User_" .. string.sub(author.Id, 1, 4))
		saveData()

		message:Reply(successEmbed("Ticket Claimed", string.format("🙋‍♂️ <@%s> has claimed **Ticket #%04d** and will be assisting you!", author.Id, ticket.id)), nil)
		return
	end

	-- !unclaim
	if command == "unclaim" then
		local ticket = db.tickets[room.Id]
		if not ticket then
			message:Reply(warnEmbed("Invalid Channel", "This command can only be used inside an active ticket channel."), nil)
			return
		end

		if not ticket.claimedBy then
			message:Reply(warnEmbed("Not Claimed", "This ticket is not currently claimed."), nil)
			return
		end

		local prevClaimer = ticket.claimedByName
		ticket.claimedBy = nil
		ticket.claimedByName = nil
		saveData()

		message:Reply(infoEmbed("Ticket Unclaimed", string.format("🔄 **Ticket #%04d** has been released by @%s. Another staff member may now claim it.", ticket.id, prevClaimer or "Staff")), nil)
		return
	end

	-- !priority <low|normal|high|urgent>
	if command == "priority" or command == "setpriority" then
		local ticket = db.tickets[room.Id]
		if not ticket then
			message:Reply(warnEmbed("Invalid Channel", "This command can only be used inside an active ticket channel."), nil)
			return
		end

		if #args == 0 then
			message:Reply(warnEmbed("Missing Priority", "Usage: `" .. PREFIX .. "priority <low|normal|high|urgent>`"), nil)
			return
		end

		local validPriorities: { [string]: string } = {
			low = "🟢 Low",
			normal = "🔵 Normal",
			medium = "🔵 Medium",
			high = "🟠 High",
			urgent = "🔴 URGENT",
		}

		local requested = string.lower(args[1])
		local formattedPriority = validPriorities[requested]
		if not formattedPriority then
			message:Reply(errorEmbed("Invalid Priority", "Valid priorities: `low`, `normal`, `high`, `urgent`"), nil)
			return
		end

		ticket.priority = formattedPriority
		saveData()

		message:Reply(successEmbed("Priority Updated", string.format("⚡ Ticket priority set to **%s**", formattedPriority)), nil)
		return
	end

	-- !topic <description>
	if command == "topic" or command == "reason" or command == "settopic" then
		local ticket = db.tickets[room.Id]
		if not ticket then
			message:Reply(warnEmbed("Invalid Channel", "This command can only be used inside an active ticket channel."), nil)
			return
		end

		if #argString == 0 then
			message:Reply(warnEmbed("Missing Topic", "Usage: `" .. PREFIX .. "topic <new inquiry description>`"), nil)
			return
		end

		ticket.reason = argString
		saveData()

		message:Reply(successEmbed("Topic Updated", string.format("📝 Ticket topic updated to:\n`%s`", argString)), nil)
		return
	end

	-- !info
	if command == "info" or command == "ticketinfo" then
		local ticket = db.tickets[room.Id]
		if not ticket then
			message:Reply(warnEmbed("Invalid Channel", "This channel is not an active support ticket."), nil)
			return
		end

		local claimText = ticket.claimedByName and string.format("<@%s> (`%s`)", ticket.claimedBy or "", ticket.claimedByName) or "*Unclaimed (Staff Queue)*"
		local infoCard = formatEmbed({
			title = string.format("TICKET #%04d METADATA", ticket.id),
			color = "📋",
			fields = {
				{ name = "📌 Channel", value = string.format("`#%s`", ticket.channelName or "ticket") },
				{ name = "👤 Creator", value = string.format("<@%s> (`%s`)", ticket.creatorId, ticket.creatorName) },
				{ name = "🕒 Opened At", value = string.format("`%s UTC`", os.date("!%Y-%m-%d %H:%M:%S", ticket.createdAt)) },
				{ name = "⚡ Priority", value = ticket.priority },
				{ name = "🛡️ Staff Assigned", value = claimText },
				{ name = "📝 Inquiry Topic", value = string.format("`%s`", ticket.reason) },
			},
			footer = "BloxSpeak Tickets • Ticket Details",
		})

		message:Reply(infoCard, nil)
		return
	end

	-- !stats
	if command == "stats" or command == "ticketstats" then
		local statsCard = formatEmbed({
			title = "TICKET SYSTEM STATISTICS",
			color = "📊",
			fields = {
				{ name = "🎫 Total Tickets Created", value = string.format("`#%04d`", db.ticketCounter) },
				{ name = "🟢 Currently Active Tickets", value = string.format("`%d open`", getActiveCount()) },
				{ name = "📦 Archived Tickets", value = string.format("`%d closed`", getClosedCount()) },
				{ name = "⏱️ Bot Uptime", value = string.format("`%s`", formatUptime(os.time() - START_TIME)) },
			},
			footer = "BloxSpeak Tickets • Live Metrics",
		})

		message:Reply(statsCard, nil)
		return
	end
end)

--------------------------------------------------------------------------------
-- 7. Reaction Added Handler (Instant Reaction & Auto-Cleanup)
--------------------------------------------------------------------------------
bot.ReactionAdded:Connect(function(reaction)
	local emoji = reaction.Emoji
	local user = reaction.User
	local room = reaction.Room
	local messageId = reaction.MessageId

	if not user or not room then return end

	-- Ignore bot's own reaction
	if bot._me and user.Id == bot._me.Id then
		return
	end

	local server = room.Server

	-- 1. PANEL REACTION: Open a new ticket instantly
	local isPanel = db.panelMessageIds[messageId] == true
	local isPanelEmoji = emoji == "🎫" or emoji == "📩" or emoji == "🎟️" or emoji == "✉️" or emoji == "➕"

	if isPanel or (isPanelEmoji and server and string.find(string.lower(room.Name or ""), "ticket")) then
		if server then
			log("INFO", string.format("Panel reaction by %s (%s) -> creating ticket instantly", user.Username or user.Id, emoji))

			-- Clean up user reaction from the panel message so it can be clicked again
			task.spawn(function()
				pcall(function()
					local ok, conn = bot:_connOf(room)
					if ok and conn then
						bot:_roomOp(conn, { type = "unreact", id = messageId, emoji = emoji, userId = user.Id, nonce = (tostring(os.clock()) .. tostring(math.random(1000, 9999))) }, nil, true)
					end
				end)
			end)

			-- Create ticket immediately
			task.spawn(function()
				createTicket(server, user, "Created via Ticket Panel reaction", room, nil)
			end)
			return
		end
	end

	-- 2. TICKET CHANNEL CONTROLS REACTION
	local ticket = db.tickets[room.Id]
	if ticket and server then
		-- Close Ticket Reaction (🔒 or ❌)
		if emoji == "🔒" or emoji == "❌" or emoji == "🔐" then
			log("INFO", string.format("Close reaction by %s in ticket #%04d", user.Username or user.Id, ticket.id))
			task.spawn(function()
				closeTicket(room, server, user, "Closed via 🔒 reaction")
			end)
			return
		end

		-- Claim Ticket Reaction (🙋‍♂️ or ✋ or 📌)
		if emoji == "🙋‍♂️" or emoji == "✋" or emoji == "📌" or emoji == "🙋" or emoji == "👋" then
			task.spawn(function()
				if ticket.claimedBy then
					room:Send(warnEmbed("Already Claimed", string.format("This ticket is already claimed by **@%s**!", ticket.claimedByName or "Staff")), nil)
				else
					ticket.claimedBy = user.Id
					ticket.claimedByName = user.Username or ("User_" .. string.sub(user.Id, 1, 4))
					saveData()
					room:Send(successEmbed("Ticket Claimed", string.format("🙋‍♂️ <@%s> has claimed **Ticket #%04d**!", user.Id, ticket.id)), nil)
				end
			end)
			return
		end

		-- Transcript Reaction (📜 or 📄 or 📝)
		if emoji == "📜" or emoji == "📄" or emoji == "📝" then
			task.spawn(function()
				local transcript = generateTranscript(room, ticket)
				local preview = string.sub(transcript, 1, 1400)
				if #transcript > 1400 then
					preview = preview .. "\n... [Transcript Truncated due to size limit]"
				end
				room:Send(formatEmbed({
					title = string.format("Ticket Transcript #%04d", ticket.id),
					color = "📜",
					description = string.format("```\n%s\n```", preview),
					footer = "BloxSpeak Tickets • Transcript Export",
				}), nil)
			end)
			return
		end
	end
end)

--------------------------------------------------------------------------------
-- 8. Web Dashboard Generator & Render Server
--------------------------------------------------------------------------------
local function generateDashboardHtml(): string
	local botName = (bot._me and bot._me.Username) or "Tickets Bot"
	local botId = (bot._me and bot._me.Id) or "0QvB0iMjP"
	local uptime = formatUptime(os.time() - START_TIME)
	local totalTickets = db.ticketCounter
	local activeTickets = getActiveCount()
	local closedTickets = getClosedCount()

	return string.format([[<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>%s | BloxSpeak Tickets Dashboard</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;500;600;700;800&display=swap" rel="stylesheet">
    <style>
        :root {
            --bg-base: #0B0E14;
            --bg-card: #151A23;
            --bg-card-hover: #1C222E;
            --accent-primary: #5865F2;
            --accent-glow: rgba(88, 101, 242, 0.35);
            --accent-success: #23A55A;
            --accent-warning: #F0B232;
            --text-main: #F2F3F5;
            --text-muted: #949BA4;
            --border: #232836;
        }

        * { margin: 0; padding: 0; box-sizing: border-box; font-family: 'Plus Jakarta Sans', sans-serif; }
        body { background-color: var(--bg-base); color: var(--text-main); min-height: 100vh; display: flex; flex-direction: column; }
        
        .navbar {
            display: flex;
            justify-content: space-between;
            align-items: center;
            padding: 1.25rem 2.5rem;
            background: rgba(21, 26, 35, 0.8);
            backdrop-filter: blur(12px);
            border-bottom: 1px solid var(--border);
            position: sticky;
            top: 0;
            z-index: 100;
        }
        .logo { display: flex; align-items: center; gap: 0.75rem; font-size: 1.35rem; font-weight: 800; color: #fff; }
        .badge-status {
            display: inline-flex;
            align-items: center;
            gap: 0.5rem;
            background: rgba(35, 165, 90, 0.15);
            border: 1px solid rgba(35, 165, 90, 0.4);
            color: var(--accent-success);
            padding: 0.35rem 0.9rem;
            border-radius: 999px;
            font-size: 0.85rem;
            font-weight: 700;
        }
        .status-dot { width: 8px; height: 8px; background: var(--accent-success); border-radius: 50%; box-shadow: 0 0 10px var(--accent-success); animation: pulse 2s infinite; }
        @keyframes pulse { 0%% { transform: scale(0.95); opacity: 0.8; } 50%% { transform: scale(1.2); opacity: 1; } 100%% { transform: scale(0.95); opacity: 0.8; } }

        .container { max-width: 1100px; margin: 0 auto; padding: 3rem 1.5rem; flex: 1; }
        .hero { text-align: center; margin-bottom: 3.5rem; }
        .hero h1 { font-size: 2.8rem; font-weight: 800; margin-bottom: 0.75rem; background: linear-gradient(135deg, #fff 30%%, var(--accent-primary) 100%%); -webkit-background-clip: text; -webkit-text-fill-color: transparent; }
        .hero p { color: var(--text-muted); font-size: 1.15rem; max-width: 650px; margin: 0 auto; line-height: 1.6; }

        .stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 1.5rem; margin-bottom: 3.5rem; }
        .stat-card {
            background: var(--bg-card);
            border: 1px solid var(--border);
            padding: 1.75rem;
            border-radius: 16px;
            transition: all 0.2s ease;
            position: relative;
            overflow: hidden;
        }
        .stat-card:hover { transform: translateY(-4px); border-color: var(--accent-primary); box-shadow: 0 10px 25px -5px var(--accent-glow); }
        .stat-label { color: var(--text-muted); font-size: 0.85rem; font-weight: 600; text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 0.5rem; }
        .stat-value { font-size: 2.25rem; font-weight: 800; color: #fff; }

        .section-title { font-size: 1.4rem; font-weight: 700; margin-bottom: 1.5rem; display: flex; align-items: center; gap: 0.5rem; }
        .grid-2 { display: grid; grid-template-columns: repeat(auto-fit, minmax(320px, 1fr)); gap: 1.5rem; }
        
        .card {
            background: var(--bg-card);
            border: 1px solid var(--border);
            border-radius: 16px;
            padding: 1.75rem;
        }
        .command-item {
            display: flex;
            align-items: flex-start;
            justify-content: space-between;
            padding: 0.85rem 0;
            border-bottom: 1px solid rgba(255, 255, 255, 0.05);
        }
        .command-item:last-child { border-bottom: none; }
        .cmd-badge {
            background: rgba(88, 101, 242, 0.15);
            color: #8A98FE;
            padding: 0.25rem 0.6rem;
            border-radius: 6px;
            font-family: monospace;
            font-weight: 600;
            font-size: 0.9rem;
        }
        .cmd-desc { color: var(--text-muted); font-size: 0.9rem; text-align: right; max-width: 60%%; }

        .footer { text-align: center; padding: 2rem; color: var(--text-muted); font-size: 0.85rem; border-top: 1px solid var(--border); margin-top: auto; }
    </style>
</head>
<body>
    <nav class="navbar">
        <div class="logo">
            <span>🎫</span> %s
        </div>
        <div class="badge-status">
            <div class="status-dot"></div>
            <span>ONLINE & OPERATIONAL</span>
        </div>
    </nav>

    <div class="container">
        <div class="hero">
            <h1>BloxSpeak Tickets Dashboard</h1>
            <p>Customer support automation with Discord-style rich embed cards, reaction panels, transcripts, and channel management.</p>
        </div>

        <div class="stats-grid">
            <div class="stat-card">
                <div class="stat-label">Total Tickets Created</div>
                <div class="stat-value">#%04d</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Currently Open</div>
                <div class="stat-value" style="color: var(--accent-success);">%d</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">Archived / Closed</div>
                <div class="stat-value">%d</div>
            </div>
            <div class="stat-card">
                <div class="stat-label">System Uptime</div>
                <div class="stat-value" style="font-size: 1.6rem; margin-top: 0.5rem;">%s</div>
            </div>
        </div>

        <div class="grid-2">
            <div class="card">
                <div class="section-title">⚡ Interactive Reactions</div>
                <div class="command-item">
                    <span class="cmd-badge">🎫 Panel Reaction</span>
                    <span class="cmd-desc">Opens private ticket & sends DM to user</span>
                </div>
                <div class="command-item">
                    <span class="cmd-badge">🔒 Close Reaction</span>
                    <span class="cmd-desc">Saves transcript and deletes channel in 5s</span>
                </div>
                <div class="command-item">
                    <span class="cmd-badge">🙋‍♂️ Claim Reaction</span>
                    <span class="cmd-desc">Assigns staff member to ticket</span>
                </div>
                <div class="command-item">
                    <span class="cmd-badge">📜 Transcript Reaction</span>
                    <span class="cmd-desc">Generates message history log</span>
                </div>
            </div>

            <div class="card">
                <div class="section-title">🛠️ Chat Commands</div>
                <div class="command-item">
                    <span class="cmd-badge">!panel</span>
                    <span class="cmd-desc">Deploys rich ticket reaction panel</span>
                </div>
                <div class="command-item">
                    <span class="cmd-badge">!new [reason]</span>
                    <span class="cmd-desc">Opens support ticket</span>
                </div>
                <div class="command-item">
                    <span class="cmd-badge">!close [reason]</span>
                    <span class="cmd-desc">Archives & deletes ticket</span>
                </div>
                <div class="command-item">
                    <span class="cmd-badge">!priority &lt;level&gt;</span>
                    <span class="cmd-desc">Low, Normal, High, Urgent</span>
                </div>
                <div class="command-item">
                    <span class="cmd-badge">!stats</span>
                    <span class="cmd-desc">Displays server ticket metrics</span>
                </div>
            </div>
        </div>
    </div>

    <footer class="footer">
        BloxSpeak Bot ID: <code>%s</code> • Powered by Lune Runtime • Hosted on Render
    </footer>
</body>
</html>]], botName, botName, totalTickets, activeTickets, closedTickets, uptime, botId)
end

-- Start Embedded HTTP Web Server for Render Hosting
local PORT = tonumber(process.env.PORT) or 8080

task.spawn(function()
	local ok, serverOrErr = pcall(function()
		return net.serve(PORT, function(req)
			local path = req.path or "/"
			if path == "/healthz" or path == "/health" or path == "/ping" then
				return {
					status = 200,
					headers = { ["content-type"] = "text/plain" },
					body = "OK",
				}
			elseif path == "/api/stats" then
				return {
					status = 200,
					headers = { ["content-type"] = "application/json", ["access-control-allow-origin"] = "*" },
					body = serde.encode("json", {
						status = "online",
						botId = bot._me and bot._me.Id or "0QvB0iMjP",
						botName = bot._me and bot._me.Username or "Tickets",
						totalTickets = db.ticketCounter,
						activeTickets = getActiveCount(),
						closedTickets = getClosedCount(),
						uptime = os.time() - START_TIME,
					}),
				}
			else
				return {
					status = 200,
					headers = { ["content-type"] = "text/html; charset=utf-8" },
					body = generateDashboardHtml(),
				}
			end
		end)
	end)

	if ok then
		log("INFO", string.format("Web Dashboard & Healthcheck Server listening on port %d", PORT))
	else
		log("ERROR", string.format("Failed to start web server: %s", tostring(serverOrErr)))
	end
end)

-- Start Bot
log("INFO", "Starting BloxSpeak Tickets Bot with Instant Reactions & Auto-Removal...")
bot:Connect()

-- Keep process alive
while true do
	task.wait(60)
end
