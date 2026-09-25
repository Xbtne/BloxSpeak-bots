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

-- Types
type TicketRecord = {
	id: number,
	channelId: string,
	channelName: string,
	welcomeMessageId: string?,
	serverId: string,
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

-- Load or Initialize Database
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

local function saveData()
	pcall(function()
		local encoded = serde.encode("json", db, true)
		fs.writeFile(DATA_FILE, encoded)
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

-- Initialize Bot Client
local bot = BloxSpeak.new(BOT_TOKEN)

-- Ensure transcripts directory exists
pcall(function()
	if not fs.isDir("transcripts") then
		fs.writeDir("transcripts")
	end
end)

-- Generate Transcript function
local function generateTranscript(room: any, ticket: TicketRecord?): string
	local msgsOk, messages = room:GetMessages({ Limit = 50 })
	local lines = {}
	table.insert(lines, "==================================================")
	table.insert(lines, string.format("         BLOXSPEAK TICKET TRANSCRIPT #%s", ticket and formatTicketNumber(ticket.id) or "0000"))
	table.insert(lines, "==================================================")
	if ticket then
		table.insert(lines, string.format("Creator: %s (ID: %s)", ticket.creatorName, ticket.creatorId))
		table.insert(lines, string.format("Created At: %s UTC", os.date("!%Y-%m-%d %H:%M:%S", ticket.createdAt)))
		table.insert(lines, string.format("Channel Name: #%s", ticket.channelName or "ticket"))
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
		table.insert(lines, "(Could not retrieve message history)")
	end
	table.insert(lines, "==================================================")
	return table.concat(lines, "\n")
end

-- Close a ticket with countdown and deletion
local function closeTicket(room: any, server: any, user: any, closeReason: string?)
	local ticket = db.tickets[room.Id]
	if not ticket then
		room:Send("⚠️ This channel is not recognized as an active ticket.", nil)
		return
	end

	local closerName = user.Username or ("User_" .. string.sub(user.Id, 1, 4))
	local reason = (closeReason and #closeReason > 0) and closeReason or "No reason specified"

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

	room:Send(string.format(
		"━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n" ..
		"🔒 **TICKET #%04d CLOSED**\n" ..
		"━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n" ..
		"• **Closed By:** @%s\n" ..
		"• **Reason:** %s\n" ..
		"• **Transcript:** Saved successfully\n\n" ..
		"🗑️ *This ticket channel will be automatically deleted in 5 seconds...*\n" ..
		"━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
		ticket.id,
		closerName,
		reason
	), nil)

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

-- Create a new ticket channel (Sends notification via DM to user)
local function createTicket(server: any, author: any, initialReason: string?, originRoom: any?, sourceMessage: any?)
	local creatorId = author.Id
	local creatorName = author.Username or ("User_" .. string.sub(creatorId, 1, 4))
	local reason = (initialReason and #initialReason > 0) and initialReason or "No reason provided"

	-- Check if user already has an active ticket in this server
	for _, ticket in pairs(db.tickets) do
		if ticket.serverId == server.Id and ticket.creatorId == creatorId and ticket.status == "open" then
			local msgText = string.format("⚠️ You already have an open ticket in **%s** (**#%s**)! Please check your existing ticket channel.", server.Name, ticket.channelName or ("ticket-" .. ticket.id))
			task.spawn(function()
				pcall(function()
					author:SendDM(msgText, nil)
				end)
			end)
			return
		end
	end

	db.ticketCounter += 1
	local ticketNum = db.ticketCounter
	local formattedNum = formatTicketNumber(ticketNum)
	local cleanUser = string.gsub(string.lower(creatorName), "[^%w]", "")
	if #cleanUser == 0 then cleanUser = "user" end
	local channelName = string.format("ticket-%s-%s", formattedNum, string.sub(cleanUser, 1, 8))

	log("INFO", string.format("Creating ticket #%s for user %s (%s)", formattedNum, creatorName, creatorId))

	local createOk, roomOrErr = server:CreateChannel(channelName)
	if not createOk or not roomOrErr then
		local errText = string.format("Failed to create ticket channel: %s", tostring(roomOrErr))
		log("ERROR", errText)
		task.spawn(function()
			pcall(function()
				author:SendDM("❌ **Failed to create ticket channel.** Please verify bot permissions (`ManageChannels`).", nil)
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
		creatorId = creatorId,
		creatorName = creatorName,
		reason = reason,
		createdAt = os.time(),
		claimedBy = nil,
		claimedByName = nil,
		priority = "Normal",
		status = "open",
	}

	db.tickets[room.Id] = newTicket
	saveData()

	-- Send DM to the user directly
	task.spawn(function()
		local dmText = string.format("✅ **Ticket Created!** Your support ticket channel is ready in **%s**: **#%s**", server.Name, channelName)
		local dmOk, dmErr = pcall(function()
			return author:SendDM(dmText, nil)
		end)
		if not dmOk then
			log("WARN", string.format("Failed to DM user %s: %s", creatorName, tostring(dmErr)))
		end
	end)

	-- Send welcome banner inside new ticket channel
	local welcomeContent = string.format(
		"━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n" ..
		"🎫 **TICKET #%s - SUPPORT REQUEST**\n" ..
		"━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n" ..
		"👋 Welcome @%s! Support staff will assist you shortly.\n\n" ..
		"📋 **Ticket Information:**\n" ..
		"• **Ticket ID:** `#%s`\n" ..
		"• **Created By:** @%s (ID: `%s`)\n" ..
		"• **Topic:** `%s`\n" ..
		"• **Priority:** `Normal`\n" ..
		"• **Status:** 🟢 Open\n\n" ..
		"⚡ **Quick Reactions Controls:**\n" ..
		"• React 🔒 to **Close Ticket**\n" ..
		"• React 🙋‍♂️ to **Claim Ticket**\n" ..
		"• React 📜 to **View Transcript**\n\n" ..
		"🛠️ **Commands:** `!close` | `!claim` | `!unclaim` | `!transcript` | `!priority` | `!topic`\n" ..
		"━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
		formattedNum,
		creatorName,
		formattedNum,
		creatorName,
		creatorId,
		reason
	)

	task.spawn(function()
		local sendOk, welcomeMsg = room:Send(welcomeContent, nil)
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

-- Bot Event: Connected
bot.Connected:Connect(function(user)
	log("INFO", string.format("Connected to BloxSpeak as %s (ID: %s)", user.Username or "TicketBot", user.Id))
	bot:SetStatus("Online")
end)

-- Bot Event: Disconnected
bot.Disconnected:Connect(function(err)
	log("WARN", string.format("Disconnected: %s (%s)", err.Message or "Unknown error", err.Code or "NO_CODE"))
end)

-- Bot Event: MessageCreated (Commands)
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

	-- Help Command
	if command == "help" or command == "tickethelp" or command == "commands" then
		local helpText = 
			"🎫 **BloxSpeak Ticket Bot - Help Menu**\n" ..
			"━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n" ..
			"📌 **User Commands & Controls:**\n" ..
			"• `!panel` / `!ticket-panel` - Post interactive 🎫 Ticket Reaction Panel\n" ..
			"• `!new [reason]` / `!ticket [reason]` - Open a new ticket channel\n" ..
			"• `!close [reason]` - Close and delete the ticket channel\n" ..
			"• `!transcript` - View ticket transcript\n" ..
			"• `!info` - View ticket details\n" ..
			"• `!ping` - Bot latency & health\n\n" ..
			"🛡️ **Staff Commands:**\n" ..
			"• `!claim` - Claim active ticket\n" ..
			"• `!unclaim` - Release claimed ticket\n" ..
			"• `!priority <low|normal|high|urgent>` - Update priority\n" ..
			"• `!topic <new reason>` - Update topic\n" ..
			"• `!stats` - View total ticket statistics\n\n" ..
			"⚡ **Reactions:**\n" ..
			"• React 🎫 or 📩 on panel -> Opens ticket (Sends confirmation via DM)\n" ..
			"• React 🔒 in ticket -> Closes ticket\n" ..
			"• React 🙋‍♂️ in ticket -> Claims ticket\n" ..
			"• React 📜 in ticket -> Generates transcript\n" ..
			"━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
		message:Reply(helpText, nil)
		return
	end

	-- Ping Command
	if command == "ping" then
		message:Reply("🏓 **Pong!** BloxSpeak Tickets Bot is online and healthy! 🚀", nil)
		return
	end

	-- Open Ticket Command
	if command == "new" or command == "ticket" or command == "open" then
		if not server then
			message:Reply("⚠️ Tickets can only be created inside a server channel.", nil)
			return
		end
		createTicket(server, author, argString, room, message)
		return
	end

	-- Panel Creation Command
	if command == "panel" or command == "ticket-panel" or command == "setup" then
		if not server then
			message:Reply("⚠️ This command must be executed in a server channel.", nil)
			return
		end

		local panelContent = 
			"━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n" ..
			"🎫 **SUPPORT TICKET SYSTEM**\n" ..
			"━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n" ..
			"Need assistance, have questions, or want to report an issue?\n\n" ..
			"📩 **How to open a ticket:**\n" ..
			"• React with **🎫** or **📩** to open a support ticket\n" ..
			"• Or type `!new [reason]`\n\n" ..
			"A dedicated private channel will be created for you automatically!\n" ..
			"━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

		local sendOk, sentMsg = room:Send(panelContent, nil)
		if sendOk and sentMsg then
			db.panelMessageIds[sentMsg.Id] = true
			saveData()
			log("INFO", string.format("Created ticket panel in channel %s (Msg ID: %s)", room.Id, sentMsg.Id))

			task.spawn(function()
				pcall(function() sentMsg:React("🎫") end)
				pcall(function() sentMsg:React("📩") end)
			end)
		else
			message:Reply("❌ Failed to send ticket panel.", nil)
		end
		return
	end

	-- Close Command
	if command == "close" then
		if not server then return end
		closeTicket(room, server, author, argString)
		return
	end

	-- Transcript Command
	if command == "transcript" or command == "log" then
		local ticket = db.tickets[room.Id]
		local transcript = generateTranscript(room, ticket)
		
		local preview = string.sub(transcript, 1, 1400)
		if #transcript > 1400 then
			preview = preview .. "\n... [Transcript Truncated due to size limit]"
		end

		message:Reply(string.format("📜 **Ticket Transcript:**\n```\n%s\n```", preview), nil)
		return
	end

	-- Claim Command
	if command == "claim" then
		local ticket = db.tickets[room.Id]
		if not ticket then
			message:Reply("⚠️ This command can only be used inside an active ticket channel.", nil)
			return
		end

		if ticket.claimedBy then
			message:Reply(string.format("⚠️ This ticket is already claimed by **@%s**!", ticket.claimedByName or "Staff"), nil)
			return
		end

		ticket.claimedBy = author.Id
		ticket.claimedByName = author.Username or ("User_" .. string.sub(author.Id, 1, 4))
		saveData()

		message:Reply(string.format("🙋‍♂️ **Ticket #%04d has been claimed by @%s!** They will be assisting you.", ticket.id, ticket.claimedByName), nil)
		return
	end

	-- Unclaim Command
	if command == "unclaim" then
		local ticket = db.tickets[room.Id]
		if not ticket then
			message:Reply("⚠️ This command can only be used inside an active ticket channel.", nil)
			return
		end

		if not ticket.claimedBy then
			message:Reply("⚠️ This ticket is not currently claimed.", nil)
			return
		end

		local prevClaimer = ticket.claimedByName
		ticket.claimedBy = nil
		ticket.claimedByName = nil
		saveData()

		message:Reply(string.format("🔄 **Ticket #%04d has been unclaimed** (previously by @%s). Another staff member may claim it.", ticket.id, prevClaimer or "Staff"), nil)
		return
	end

	-- Priority Command
	if command == "priority" or command == "setpriority" then
		local ticket = db.tickets[room.Id]
		if not ticket then
			message:Reply("⚠️ This command can only be used inside an active ticket channel.", nil)
			return
		end

		if #args == 0 then
			message:Reply("⚠️ Please specify a priority: `!priority <low|normal|high|urgent>`", nil)
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
			message:Reply("⚠️ Invalid priority! Choose from: `low`, `normal`, `high`, `urgent`", nil)
			return
		end

		ticket.priority = formattedPriority
		saveData()

		message:Reply(string.format("⚡ **Ticket priority updated:** %s", formattedPriority), nil)
		return
	end

	-- Topic / Reason Command
	if command == "topic" or command == "reason" or command == "settopic" then
		local ticket = db.tickets[room.Id]
		if not ticket then
			message:Reply("⚠️ This command can only be used inside an active ticket channel.", nil)
			return
		end

		if #argString == 0 then
			message:Reply("⚠️ Please specify the new topic: `!topic <description>`", nil)
			return
		end

		ticket.reason = argString
		saveData()

		message:Reply(string.format("📝 **Ticket topic updated to:** `%s`", argString), nil)
		return
	end

	-- Info Command
	if command == "info" or command == "ticketinfo" then
		local ticket = db.tickets[room.Id]
		if not ticket then
			message:Reply("⚠️ This channel is not an active ticket.", nil)
			return
		end

		local infoContent = string.format(
			"━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n" ..
			"📋 **TICKET #%04d INFORMATION**\n" ..
			"━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n" ..
			"• **Channel:** #%s\n" ..
			"• **Creator:** @%s (`%s`)\n" ..
			"• **Opened At:** %s UTC\n" ..
			"• **Status:** %s\n" ..
			"• **Priority:** %s\n" ..
			"• **Claimed By:** %s\n" ..
			"• **Topic:** %s\n" ..
			"━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
			ticket.id,
			ticket.channelName or ("ticket-" .. ticket.id),
			ticket.creatorName,
			ticket.creatorId,
			os.date("!%Y-%m-%d %H:%M:%S", ticket.createdAt),
			ticket.status == "open" and "🟢 Open" or "🔴 Closed",
			ticket.priority,
			ticket.claimedByName and string.format("@%s (`%s`)", ticket.claimedByName, ticket.claimedBy or "") or "*Unclaimed*",
			ticket.reason
		)
		message:Reply(infoContent, nil)
		return
	end

	-- Stats Command
	if command == "stats" or command == "ticketstats" then
		local statsContent = string.format(
			"📊 **TICKET SYSTEM STATISTICS**\n" ..
			"━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n" ..
			"• **Total Tickets Created:** `%d`\n" ..
			"• **Currently Open Tickets:** `%d`\n" ..
			"• **Archived / Closed Tickets:** `%d`\n" ..
			"━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
			db.ticketCounter,
			getActiveCount(),
			getClosedCount()
		)
		message:Reply(statsContent, nil)
		return
	end
end)

-- Bot Event: ReactionAdded (Interactive Panel & Ticket Controls)
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

	log("INFO", string.format("ReactionAdded: emoji=%s user=%s room=%s msg=%s", tostring(emoji), user.Username or user.Id, room.Name or room.Id, tostring(messageId)))

	local server = room.Server

	-- 1. PANEL REACTION: Open a new ticket
	local isPanel = db.panelMessageIds[messageId] == true
	local isPanelEmoji = emoji == "🎫" or emoji == "📩" or emoji == "🎟️"

	-- If the message is a panel OR emoji is 🎫/📩 in a channel with ticket in name
	if isPanel or (isPanelEmoji and server and string.find(string.lower(room.Name or ""), "ticket")) then
		if server then
			log("INFO", string.format("Panel reaction by %s -> creating ticket", user.Username or user.Id))
			createTicket(server, user, "Created via Ticket Panel reaction", room, nil)
			return
		end
	end

	-- 2. TICKET CHANNEL CONTROLS REACTION
	local ticket = db.tickets[room.Id]
	if ticket and server then
		-- Close Ticket Reaction (🔒 or ❌)
		if emoji == "🔒" or emoji == "❌" or emoji == "🔐" then
			log("INFO", string.format("Close reaction by %s in ticket #%04d", user.Username or user.Id, ticket.id))
			closeTicket(room, server, user, "Closed via 🔒 reaction")
			return
		end

		-- Claim Ticket Reaction (🙋‍♂️ or ✋ or 📌)
		if emoji == "🙋‍♂️" or emoji == "✋" or emoji == "📌" or emoji == "🙋" or emoji == "👋" then
			if ticket.claimedBy then
				room:Send(string.format("⚠️ This ticket is already claimed by **@%s**!", ticket.claimedByName or "Staff"), nil)
			else
				ticket.claimedBy = user.Id
				ticket.claimedByName = user.Username or ("User_" .. string.sub(user.Id, 1, 4))
				saveData()
				room:Send(string.format("🙋‍♂️ **Ticket #%04d has been claimed by @%s!**", ticket.id, ticket.claimedByName), nil)
			end
			return
		end

		-- Transcript Reaction (📜 or 📄 or 📝)
		if emoji == "📜" or emoji == "📄" or emoji == "📝" then
			local transcript = generateTranscript(room, ticket)
			local preview = string.sub(transcript, 1, 1400)
			if #transcript > 1400 then
				preview = preview .. "\n... [Transcript Truncated due to size limit]"
			end
			room:Send(string.format("📜 **Ticket Transcript:**\n```\n%s\n```", preview), nil)
			return
		end
	end
end)

-- Web Dashboard Generator
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
    <title>%s | BloxSpeak Tickets</title>
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
            <p>High-performance customer support system for BloxSpeak with reaction panels, instant private DMs, transcripts, and channel lifecycle management.</p>
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
                    <span class="cmd-desc">Deploys ticket reaction panel</span>
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
log("INFO", "Starting BloxSpeak Tickets Bot with Dashboard & Web Server...")
bot:Connect()

-- Keep process alive
while true do
	task.wait(60)
end
