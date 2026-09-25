--!strict
-- Complete Tickets Bot with Direct Message (DM) Notifications for BloxSpeak
-- Built with BloxSpeak SDK (Lune runtime)

local BOT_TOKEN = "bsb_0QvB0iMjPKwHHz8wHiSTmE9qkOSD5gRR"
local PREFIX = "!"
local DATA_FILE = "tickets_data.json"

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

-- Create a new ticket channel (Sends notification via DM to the user)
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
				author:SendDM("❌ **Failed to create ticket channel.** Please contact an administrator to verify bot permissions.", nil)
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

	-- DM the user directly instead of sending a message in the origin/panel channel
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

			-- Add reaction buttons to the welcome message
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
		message:Reply("🏓 **Pong!** BloxSpeak Tickets Bot is online! 🚀", nil)
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
		local activeCount = 0
		for _, _ in pairs(db.tickets) do
			activeCount += 1
		end
		local closedCount = 0
		for _, _ in pairs(db.closedTickets) do
			closedCount += 1
		end

		local statsContent = string.format(
			"📊 **TICKET SYSTEM STATISTICS**\n" ..
			"━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n" ..
			"• **Total Tickets Created:** `%d`\n" ..
			"• **Currently Open Tickets:** `%d`\n" ..
			"• **Archived / Closed Tickets:** `%d`\n" ..
			"━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
			db.ticketCounter,
			activeCount,
			closedCount
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

-- Start Bot
log("INFO", "Starting BloxSpeak Tickets Bot with DM notifications...")
bot:Connect()

-- Keep process alive
while true do
	task.wait(60)
end
