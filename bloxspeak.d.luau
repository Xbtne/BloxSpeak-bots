-- Type definitions for the BloxSpeak bot SDK, for luau-lsp (add this file to "luau-lsp.types.definitionFiles").
-- Every method except Connect, Disconnect, StartTyping and HasPermission yields and returns ok, result | Error.
-- Times are Unix seconds. Ids are 9-character strings.

type BloxSpeakConnection = {
	Connected: boolean,
	Disconnect: (self: BloxSpeakConnection) -> (),
}

type BloxSpeakSignal<T...> = {
	Connect: (self: BloxSpeakSignal<T...>, handler: (T...) -> ()) -> BloxSpeakConnection,
	Once: (self: BloxSpeakSignal<T...>, handler: (T...) -> ()) -> BloxSpeakConnection,
	Wait: (self: BloxSpeakSignal<T...>) -> T...,
}

type BloxSpeakError = {
	Code: string,
	Message: string,
	-- Seconds to wait before trying again (RATE_LIMITED, COOLDOWN, DAILY_LIMIT).
	RetryAfter: number?,
}

type BloxSpeakStatus = "Online" | "Idle" | "DoNotDisturb" | "Offline"

type BloxSpeakPermission =
	"ViewChannels"
	| "SendMessages"
	| "ManageMessages"
	| "ManageChannels"
	| "ManageRoles"
	| "ManageServer"
	| "Kick"
	| "Ban"
	| "CreateInvite"
	| "PingAll"
	| "PingActive"
	| "MuteMembers"
	| "ViewAuditLog"
	| "ManageFilter"

type BloxSpeakUser = {
	Id: string,
	Username: string?,
	SendDM: (self: BloxSpeakUser, content: string, options: BloxSpeakSendOptions?) -> (boolean, BloxSpeakMessage | BloxSpeakError),
}

type BloxSpeakRole = {
	Id: string,
	Name: string,
	Color: string?,
	Position: number,
	Permissions: number,
	IsDefault: boolean,
}

type BloxSpeakServer = {
	Id: string,
	Name: string,
	OwnerId: string,
	GetChannels: (self: BloxSpeakServer) -> (boolean, { BloxSpeakRoom } | BloxSpeakError),
	GetRoles: (self: BloxSpeakServer) -> (boolean, { BloxSpeakRole } | BloxSpeakError),
	GetMember: (self: BloxSpeakServer, userId: string) -> (boolean, BloxSpeakMember | BloxSpeakError),
	-- One page by user id; pass the last member's User.Id for the next page. The third value is hasMore.
	GetMembers: (self: BloxSpeakServer, after: string?) -> (boolean, { BloxSpeakMember } | BloxSpeakError, boolean?),
	CreateChannel: (self: BloxSpeakServer, name: string, folderId: string?) -> (boolean, BloxSpeakRoom | BloxSpeakError),
	Leave: (self: BloxSpeakServer) -> (boolean, true | BloxSpeakError),
}

type BloxSpeakMember = {
	User: BloxSpeakUser,
	Server: BloxSpeakServer,
	Roles: { BloxSpeakRole },
	JoinedAt: number?,
	MutedUntil: number?,
	HasPermission: (self: BloxSpeakMember, permission: BloxSpeakPermission) -> boolean,
	AddRole: (self: BloxSpeakMember, role: BloxSpeakRole | string) -> (boolean, true | BloxSpeakError),
	RemoveRole: (self: BloxSpeakMember, role: BloxSpeakRole | string) -> (boolean, true | BloxSpeakError),
	-- 60 to 604800 seconds.
	Mute: (self: BloxSpeakMember, seconds: number, reason: string?) -> (boolean, true | BloxSpeakError),
	Unmute: (self: BloxSpeakMember) -> (boolean, true | BloxSpeakError),
	Kick: (self: BloxSpeakMember, reason: string?) -> (boolean, true | BloxSpeakError),
	Ban: (self: BloxSpeakMember, reason: string?, deleteMessages: boolean?) -> (boolean, true | BloxSpeakError),
}

type BloxSpeakSendOptions = {
	ReplyTo: string?,
	-- Upload tokens from POST /api/uploads, up to 10.
	Attachments: { string }?,
}

type BloxSpeakRoom = {
	Id: string,
	Name: string?,
	Kind: "Channel" | "Chat" | "Room",
	Server: BloxSpeakServer?,
	Send: (self: BloxSpeakRoom, content: string, options: BloxSpeakSendOptions?) -> (boolean, BloxSpeakMessage | BloxSpeakError),
	-- Oldest first. Limit 1-50 (default 50); Before: a message id.
	GetMessages: (self: BloxSpeakRoom, options: { Limit: number?, Before: string? }?) -> (boolean, { BloxSpeakMessage } | BloxSpeakError),
	StartTyping: (self: BloxSpeakRoom) -> (),
}

type BloxSpeakAttachment = {
	Id: string,
	Url: string,
	Name: string,
	Type: string,
	Size: number,
	Width: number?,
	Height: number?,
}

type BloxSpeakMessage = {
	Id: string,
	Content: string,
	Author: BloxSpeakUser,
	Room: BloxSpeakRoom,
	Server: BloxSpeakServer?,
	ReplyTo: { Id: string, AuthorId: string?, Excerpt: string?, Deleted: boolean }?,
	Attachments: { BloxSpeakAttachment },
	IsSystem: boolean,
	CreatedAt: number,
	EditedAt: number?,
	Reply: (self: BloxSpeakMessage, content: string, options: BloxSpeakSendOptions?) -> (boolean, BloxSpeakMessage | BloxSpeakError),
	Edit: (self: BloxSpeakMessage, content: string) -> (boolean, BloxSpeakMessage | BloxSpeakError),
	Delete: (self: BloxSpeakMessage) -> (boolean, true | BloxSpeakError),
	React: (self: BloxSpeakMessage, emoji: string) -> (boolean, true | BloxSpeakError),
	Unreact: (self: BloxSpeakMessage, emoji: string) -> (boolean, true | BloxSpeakError),
}

type BloxSpeakReaction = {
	Emoji: string,
	MessageId: string,
	User: BloxSpeakUser,
	Room: BloxSpeakRoom,
}

type BloxSpeakUsage = {
	ActionsUsed: number,
	ActionsLimit: number,
	Connections: number,
	ResetsAt: number,
}

type BloxSpeakBot = {
	Connected: BloxSpeakSignal<BloxSpeakUser>,
	Disconnected: BloxSpeakSignal<BloxSpeakError>,
	MessageCreated: BloxSpeakSignal<BloxSpeakMessage>,
	MessageEdited: BloxSpeakSignal<BloxSpeakMessage>,
	MessageDeleted: BloxSpeakSignal<string, BloxSpeakRoom>,
	ReactionAdded: BloxSpeakSignal<BloxSpeakReaction>,
	ReactionRemoved: BloxSpeakSignal<BloxSpeakReaction>,
	MemberJoined: BloxSpeakSignal<BloxSpeakUser, BloxSpeakServer>,
	MemberLeft: BloxSpeakSignal<BloxSpeakUser, BloxSpeakServer>,
	ServerJoined: BloxSpeakSignal<BloxSpeakServer>,
	ServerLeft: BloxSpeakSignal<BloxSpeakServer>,

	Connect: (self: BloxSpeakBot) -> (),
	Disconnect: (self: BloxSpeakBot) -> (),
	SetStatus: (self: BloxSpeakBot, status: BloxSpeakStatus) -> (boolean, BloxSpeakStatus | BloxSpeakError),
	GetServers: (self: BloxSpeakBot) -> (boolean, { BloxSpeakServer } | BloxSpeakError),
	GetRoom: (self: BloxSpeakBot, id: string) -> (boolean, BloxSpeakRoom | BloxSpeakError),
	GetUsage: (self: BloxSpeakBot) -> (boolean, BloxSpeakUsage | BloxSpeakError),
}

declare sdkVersion: string
declare luneVersion: string
declare net: any
declare task: any
declare serde: any
declare fs: any
declare stdio: any
declare datetime: any
declare process: any

declare BloxSpeak: {
	new: (token: string, options: { BaseUrl: string? }?) -> BloxSpeakBot,
	Permissions: { [BloxSpeakPermission]: number },
	Version: string,
}
