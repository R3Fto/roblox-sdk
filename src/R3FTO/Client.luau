--!nonstrict
-- R3FTO Roblox SDK: the public client behaviour.
--
-- Every Roblox service reaches this module through one `runtime` table, so the same code runs on a game server
-- (init.luau builds the runtime from the real services) and in the plain-Luau tests (fakes with the same shape).
--
-- What this module does, and what it never does:
-- * observeReceipt() records the first observation time at once, before any yield or network call, queues the work and
--   returns. It never yields, never throws, never grants a product and never returns a ProductPurchaseDecision: the
--   publisher's own receipt handler stays the one handler and decides PurchaseGranted / NotProcessedYet itself.
-- * The work is two independent channels on the Engine's retry schedule: the DataStore copy and the direct R3FTO
--   delivery.
-- * Duplicate calls for the same PurchaseId on this server join the existing work; they never restart it.
-- * The SDK reports evidence. It computes no creator share and no earning.
-- * Every player join whose LaunchData carries an R3FTO creator link value is reported once, as its own job: a player
--   who arrives with A, then B, then A again, or rejoins this server with the same value, is reported each time. The
--   same join seen twice (PlayerAdded and the GetPlayers loop at start) is reported once. An arrival job retries on a
--   longer schedule than a receipt (ARRIVAL_OFFSETS), so a short outage does not lose it.
-- * The server signal tells R3FTO that this server runs the SDK: "started" once after start, "alive" every hour and
--   "closing" once while the server shuts down, each with this server's receipt counts by durability. It runs in its own
--   thread, never inside the receipt handler, never as an Engine job and never retried: a failed signal is followed by
--   the next one on schedule. It never affects a purchase.
-- * The optional key panel opens only when the game calls openKeyPanel(player). The game passes no key: the player types
--   it. Each panel request is one attempt, never an Engine job and never retried; one request runs at a time per player
--   and at most KEY_PANEL_PER_MINUTE a minute on this server, so receipts keep their share of the server's HTTP
--   requests. The panel shows only its own fixed words for each answer.

local Client = {}
Client.__index = Client

Client.DEFAULT_TOKEN_SECRET = "R3FTO_SDK_TOKEN"
Client.DEFAULT_API_BASE_URL = "https://r3f.to"

-- The server signal: one "alive" every hour after "started" (counted from start, so it never drifts), and how long the
-- "closing" signal may hold up shutdown (Roblox gives every BindToClose callback together at most 30 seconds).
Client.HEARTBEAT_INTERVAL = 3600
Client.CLOSING_WAIT_LIMIT = 5
Client.CLOSING_POLL = 0.25

-- A player arrival decides the player's creator from that moment, so its delivery retries for up to an hour: attempt
-- offsets in seconds from the first attempt (eight attempts). Receipts keep Engine.OFFSETS.
Client.ARRIVAL_OFFSETS = table.freeze({ 0, 60, 180, 300, 600, 900, 1800, 3600 })

-- Printed once per server, on the first creator link value R3FTO did not recognize. Later ones are info lines.
Client.UNRECOGNIZED_WARNING = "a creator link value was not recognized. Test mode accepts only the Test keys TSTA, TSTB and TSTC; Production accepts real creator keys."

-- The key panel: why openKeyPanel refused, the per-server request limit and its window in seconds.
Client.KEY_PANEL_NOT_STARTED = "R3FTO.start has not run"
Client.KEY_PANEL_NOT_A_PLAYER = "not a player in this server"
Client.KEY_PANEL_FOLDER_MISSING = "the KeyPanelGui folder is missing"
Client.KEY_PANEL_PER_MINUTE = 60
Client.KEY_PANEL_WINDOW = 60

-- One Output line (info) per key panel answer that came after a request was sent to R3FTO, by answer token. An answer
-- given on this server without a request (busy, throttled, a wrong sender, a closing SDK) prints nothing. No key, no
-- UserId, no player name.
local KEY_PANEL_LINES = {
	accepted = "key panel: accepted",
	unknown_key = "key panel: unknown key",
	unavailable = "key panel: not available",
	failed = "key panel: try again later",
}

local ENVIRONMENTS = { production = true, test = true }

export type Runtime = {
	Engine: any,
	Wire: any,
	sdkVersion: string,
	isServer: () -> boolean,
	-- monotonic seconds for scheduling; Unix milliseconds for the observation time
	now: () -> number,
	unixMillis: () -> number,
	sleep: (seconds: number) -> (),
	spawn: (fn: () -> ()) -> (),
	log: (level: string, message: string) -> (),
	httpEnabled: () -> boolean,
	-- the bearer authorization header value (a Roblox Secret), or nil and a reason
	authorization: (secretName: string) -> (any?, string?),
	poster: (baseUrl: string, authorization: any) -> (path: string, body: any) -> any,
	dataStoreChannel: (environment: string) -> (record: any) -> any,
	universeId: () -> number,
	placeId: () -> number,
	jobId: () -> string,
	generateId: () -> string,
	-- players: calls `callback(userId, launchData, join)` for every player already in the server and every new one. `join`
	-- is an opaque value that is the same for every observation of one join and different for every join (the Player
	-- instance on Roblox); nil means no duplicate check.
	eachPlayer: (callback: (userId: number, launchData: any, join: any) -> ()) -> (),
	-- calls `callback(join)` when that join's player leaves the server (PlayerRemoving on Roblox)
	onPlayerLeaving: ((callback: (join: any) -> ()) -> ())?,
	onClose: (callback: () -> ()) -> (),
	-- true when `player` is a player in this server now
	isPlayerInServer: ((player: any) -> boolean)?,
	-- the key panel opener over the KeyPanelGui folder, looked up on every call, or nil when the folder is missing.
	-- `open(player)` answers true, or false and "player" or "folder" (see RobloxAdapters.keyPanelOpener).
	keyPanelOpener: ((onRequest: (any, any, any, any) -> string) -> ((player: any) -> (boolean, string?))?)?,
}

local function result(accepted: boolean, fields: { [string]: any }): { [string]: any }
	fields.accepted = accepted
	return fields
end

function Client.new(runtime: Runtime)
	local self = setmetatable({}, Client)
	self._runtime = runtime
	self._engine = runtime.Engine.new({
		now = runtime.now,
		sleep = runtime.sleep,
		spawn = runtime.spawn,
		log = runtime.log,
	})
	self._started = false
	self._context = nil :: any
	self._waiting = {} :: { { receipt: any, firstObservedAtUtc: string, simulated: boolean } }
	self._waitingIds = {} :: { [string]: { [string]: any } }
	self._post = nil :: any
	self._store = nil :: any
	self._problems = {} :: { string }
	self._quiet = false
	self._closed = false
	self._signalJobId = nil :: string?
	self._signalRefusalWarned = false
	self._signalNotConfiguredWarned = false
	self._heartbeat = { lastKind = nil :: string?, lastSentAtUtc = nil :: string?, lastResult = nil :: string? }
	-- the joins of players in this server that were already observed, and how many arrivals were reported
	self._joins = {} :: { [any]: boolean }
	self._arrivals = 0
	self._unrecognizedWarned = false
	-- the key panel: the players (by server-seen UserId) whose request is running, the start times of this server's
	-- requests in the last KEY_PANEL_WINDOW seconds, the answers given and the two once-per-server warnings
	self._panelBusy = {} :: { [string]: boolean }
	self._panelTimes = {} :: { number }
	self._panelOutcomes = { accepted = 0, unknown_key = 0, unavailable = 0, busy = 0, throttled = 0, failed = 0 }
	self._panelRefusalWarned = false
	self._panelNotConfiguredWarned = false
	return self
end

function Client:_say(level: string, message: string)
	if self._quiet and level == "info" then
		return
	end
	self._runtime.log(level, "[R3FTO] " .. message)
end

-- R3FTO.start(config). Call once from one server Script. Returns true, or false and the reason it cannot start.
function Client:start(config: any): (boolean, string?)
	local runtime = self._runtime
	if self._started then
		return true, "already started"
	end
	if not runtime.isServer() then
		return false, "R3FTO.start must run on the server (a Script in ServerScriptService)"
	end
	if type(config) ~= "table" then
		return false, "R3FTO.start needs a configuration table"
	end
	local environment = if type(config.environment) == "string" then string.lower(config.environment) else nil
	if environment == nil or not ENVIRONMENTS[environment] then
		return false, 'config.environment must be "test" or "production"'
	end
	local baseUrl = config.apiBaseUrl or Client.DEFAULT_API_BASE_URL
	if type(baseUrl) ~= "string" or string.find(baseUrl, "^https://[%w%.%-]+[%w]$") == nil then
		return false, "config.apiBaseUrl must be an https origin such as https://r3f.to"
	end
	local secretName = config.tokenSecretName or Client.DEFAULT_TOKEN_SECRET
	if type(secretName) ~= "string" or #secretName == 0 then
		return false, "config.tokenSecretName must be a secret name"
	end
	self._quiet = config.quiet == true

	local universe = runtime.Wire.digits(runtime.universeId())
	local place = runtime.Wire.digits(runtime.placeId())
	self._context = {
		environment = environment,
		universeId = universe or "0",
		placeId = place,
		serverJobId = runtime.jobId(),
		sdkVersion = runtime.sdkVersion,
	}

	if universe == nil or universe == "0" then
		table.insert(self._problems, "this place is not published, so DataStores and R3FTO cannot identify the experience")
	end
	if not runtime.httpEnabled() then
		table.insert(self._problems, "Allow HTTP Requests is off, so direct delivery to R3FTO will fail (the DataStore copy still runs)")
	end
	local authorization, why = runtime.authorization(secretName)
	if authorization == nil then
		table.insert(self._problems, "the secret " .. secretName .. " is not available (Roblox: " .. tostring(why) .. "). Add it in Creator Hub Secrets, or as a Studio Local Secret for local tests; direct delivery to R3FTO fails until then")
	end

	self._post = runtime.poster(baseUrl, authorization)
	self._store = runtime.dataStoreChannel(environment)
	self._started = true
	for _, problem in self._problems do
		self:_say("warn", problem)
	end
	self:_say("info", "started for " .. environment .. " (SDK " .. runtime.sdkVersion .. ")")

	-- Receipts observed before start keep their own first observation time.
	local waiting = self._waiting
	self._waiting = {}
	self._waitingIds = {}
	for _, item in waiting do
		self:_submitReceipt(item.receipt, item.firstObservedAtUtc, item.simulated)
	end

	if runtime.onPlayerLeaving then
		runtime.onPlayerLeaving(function(join: any)
			self:_playerLeft(join)
		end)
	end
	runtime.eachPlayer(function(userId: number, launchData: any, join: any)
		self:_observePlayer(userId, launchData, join)
	end)
	runtime.onClose(function()
		self:_onClose()
	end)

	-- Studio has no JobId (it is empty), so a Studio session signals with its own id, made once here.
	local jobId = runtime.jobId()
	self._signalJobId = if type(jobId) == "string" and #jobId > 0 then jobId else "studio-" .. runtime.generateId()
	self:_startHeartbeat()
	return true, nil
end

-- This server's receipts by durability, for the whole life of the server (delivered receipts are not counted).
function Client:_receiptCounts(): { [string]: number }
	local counts = { memory_only = 0, stored_awaiting_delivery = 0, not_durable = 0 }
	for key, job in self._engine:jobs() do
		if string.sub(key, 1, 8) == "receipt:" then
			local durability = self._runtime.Engine.durability(job)
			if counts[durability] ~= nil then
				counts[durability] += 1
			end
		end
	end
	return counts
end

-- Sends one server signal now, in the calling thread: one attempt, never retried. Never throws.
function Client:_signal(kind: string)
	local runtime = self._runtime
	local wire = runtime.Wire
	local sentAtUtc = wire.isoUtcFromMillis(runtime.unixMillis())
	local body = wire.heartbeatBody(kind, sentAtUtc, self:_receiptCounts(), self._context, self._signalJobId)
	local state = self._heartbeat
	state.lastKind = kind
	state.lastSentAtUtc = sentAtUtc
	state.lastResult = "sending"
	local called, outcome = pcall(self._post, wire.HEARTBEATS_PATH, body)
	if not called or type(outcome) ~= "table" then
		outcome = { ok = false, kind = "ambiguous", detail = "the signal raised an error" }
	end
	if outcome.ok then
		state.lastResult = "recorded"
		self:_say("info", "server signal " .. kind .. " sent")
		return
	end
	state.lastResult = tostring(outcome.kind)
	if outcome.kind == "rejected" and not self._signalRefusalWarned then
		-- A refusal (the token, the environment, the universe or the request) repeats on every signal: say it once.
		self._signalRefusalWarned = true
		self:_say("warn", "R3FTO refused the server signal (" .. tostring(outcome.detail) .. "); check the SDK token and the environment. Receipts are not affected")
		return
	end
	if outcome.kind == "not_configured" and not self._signalNotConfiguredWarned then
		-- The secret is missing on this server, so no signal ever leaves it: say it once (the start warning names the fix).
		self._signalNotConfiguredWarned = true
		self:_say("warn", "server signals are not sent: the SDK token secret is not available (see the warning at start). Receipts keep only their DataStore copy until the secret is added")
		return
	end
	self:_say("info", "server signal " .. kind .. " failed (" .. tostring(outcome.kind) .. ", " .. tostring(outcome.detail) .. "); the next one follows on schedule")
end

-- "started" now, then "alive" every HEARTBEAT_INTERVAL seconds from start, in one spawned thread that stops at close.
function Client:_startHeartbeat()
	local runtime = self._runtime
	local startedAt = runtime.now()
	runtime.spawn(function()
		if self._closed then
			return
		end
		pcall(self._signal, self, "started")
		local beat = 1
		while true do
			local wait = startedAt + beat * Client.HEARTBEAT_INTERVAL - runtime.now()
			if wait > 0 then
				runtime.sleep(wait)
			end
			if self._closed then
				return
			end
			pcall(self._signal, self, "alive")
			-- A slow signal never causes a burst: a missed hour is skipped, not caught up.
			beat = math.max(beat + 1, math.floor((runtime.now() - startedAt) / Client.HEARTBEAT_INTERVAL) + 1)
		end
	end)
end

-- "closing": one attempt in its own thread; shutdown waits for it at most CLOSING_WAIT_LIMIT seconds.
function Client:_closingSignal()
	if self._closed then
		return
	end
	self._closed = true
	local runtime = self._runtime
	local done = false
	runtime.spawn(function()
		pcall(self._signal, self, "closing")
		done = true
	end)
	local deadline = runtime.now() + Client.CLOSING_WAIT_LIMIT
	while not done do
		local remaining = deadline - runtime.now()
		if remaining <= 0 then
			return
		end
		runtime.sleep(math.min(Client.CLOSING_POLL, remaining))
	end
end

function Client:_receiptChannels(purchaseId: string)
	local wire = self._runtime.Wire
	local context = self._context
	return {
		{
			name = "storage",
			attempt = function(record: any, attempt: number)
				local outcome = self._store(record)
				if outcome.ok then
					local facts = outcome.facts or {}
					if facts.existingDiffers then
						self:_say("warn", "receipt " .. purchaseId .. ": the DataStore already holds a different record for this PurchaseId; it is kept unchanged")
					end
					self:_say("info", "receipt " .. purchaseId .. ": DataStore copy " .. (if facts.adoptedExistingRecord then "already existed (its first observation time is kept)" else "written"))
				else
					self:_say("warn", "receipt " .. purchaseId .. ": DataStore attempt " .. attempt .. " failed (" .. tostring(outcome.kind) .. ")")
				end
				return outcome
			end,
		},
		{
			name = "delivery",
			attempt = function(record: any, attempt: number)
				local outcome = self._post(wire.RECEIPTS_PATH, wire.receiptBody(record, context))
				if outcome.ok then
					self:_say("info", "receipt " .. purchaseId .. ": delivered to R3FTO (" .. tostring(outcome.facts and outcome.facts.outcome) .. ")")
				else
					self:_say("warn", "receipt " .. purchaseId .. ": delivery attempt " .. attempt .. " failed (" .. tostring(outcome.kind) .. ", " .. tostring(outcome.detail) .. ")")
				end
				return outcome
			end,
		},
	}
end

function Client:_submitReceipt(receipt: any, firstObservedAtUtc: string, simulated: boolean): (any, boolean)
	local record = self._runtime.Wire.receiptRecord(receipt, firstObservedAtUtc, self._context, simulated)
	return self._engine:submit("receipt:" .. receipt.purchaseId, record, self:_receiptChannels(receipt.purchaseId))
end

-- The shared path of observeReceipt and simulateTestReceipt. Never yields, never throws.
function Client:_observe(receiptInfo: any, simulated: boolean): { [string]: any }
	local runtime = self._runtime
	-- The observation time is taken first, before anything that could yield, and it never changes afterwards.
	local firstObservedAtUtc = runtime.Wire.isoUtcFromMillis(runtime.unixMillis())
	local receipt, reason = runtime.Wire.readReceipt(receiptInfo)
	if receipt == nil then
		self:_say("warn", "a receipt was not recorded: " .. tostring(reason))
		return result(false, { reason = reason })
	end
	local purchaseId = receipt.purchaseId

	if not self._started then
		local waiting = self._waitingIds[purchaseId]
		if waiting then
			waiting.duplicates += 1
			return result(true, { purchaseId = purchaseId, firstObservedAtUtc = waiting.firstObservedAtUtc, duplicate = true, queuedUntilStart = true })
		end
		local item = { receipt = receipt, firstObservedAtUtc = firstObservedAtUtc, simulated = simulated, duplicates = 0 }
		self._waitingIds[purchaseId] = item
		table.insert(self._waiting, item)
		return result(true, { purchaseId = purchaseId, firstObservedAtUtc = firstObservedAtUtc, duplicate = false, queuedUntilStart = true })
	end

	local job, created = self:_submitReceipt(receipt, firstObservedAtUtc, simulated)
	if not created then
		self:_say("info", "receipt " .. purchaseId .. ": repeated callback joined the work already running on this server")
	end
	return result(true, {
		purchaseId = purchaseId,
		firstObservedAtUtc = job.record.firstObservedAtUtc,
		duplicate = not created,
	})
end

-- R3FTO.observeReceipt(receiptInfo): call it inside your own receipt handler, with the table Roblox gave you.
function Client:observeReceipt(receiptInfo: any): { [string]: any }
	local ok, answer = pcall(self._observe, self, receiptInfo, false)
	if ok then
		return answer
	end
	return result(false, { reason = "internal error" })
end

-- R3FTO.simulateTestReceipt({ userId = 123, productId = 456, currencySpent = 10, simulationId = "demo-1" }):
-- R3FTO Test environment only. Builds a receipt that Roblox never issued (PurchaseId "r3fto-sim-<simulationId or a new
-- GUID>") and marks it simulated end to end. Passing the same simulationId again behaves like a repeated callback.
function Client:simulateTestReceipt(options: any): { [string]: any }
	if not self._started or self._context.environment ~= "test" then
		return result(false, { reason = "simulated receipts are only for a started SDK in the R3FTO Test environment" })
	end
	if type(options) ~= "table" then
		return result(false, { reason = "simulateTestReceipt needs { userId, productId, currencySpent }" })
	end
	local suffix = options.simulationId
	if suffix ~= nil and (type(suffix) ~= "string" or string.find(suffix, "^[%w%-]+$") == nil or #suffix > 36) then
		return result(false, { reason = "simulationId must be up to 36 letters, digits or hyphens" })
	end
	local ok, answer = pcall(self._observe, self, {
		PurchaseId = self._runtime.Wire.SIMULATED_PREFIX .. string.lower(suffix or self._runtime.generateId()),
		PlayerId = options.userId,
		ProductId = options.productId,
		CurrencySpent = options.currencySpent,
		CurrencyType = "Robux",
		PlaceIdWherePurchased = self._runtime.placeId(),
	}, true)
	if ok then
		return answer
	end
	return result(false, { reason = "internal error" })
end

-- A player arrival: the R3FTO creator link value in this join's LaunchData, with the server-seen UserId. Every join that
-- carries a value is one job with its own key, so a later join is reported again; `join` drops a second observation of
-- the same join. The body is built once, so every retry repeats it (R3FTO answers a retry `already_recorded`).
function Client:_observePlayer(userId: number, launchData: any, join: any)
	if join ~= nil then
		if self._joins[join] then
			return
		end
		self._joins[join] = true
	end
	local wire = self._runtime.Wire
	local reference = wire.launchReference(launchData)
	if reference == nil then
		return
	end
	local user = wire.digits(userId)
	if user == nil or user == "0" then
		return
	end
	local observedAt = wire.isoUtcFromMillis(self._runtime.unixMillis())
	local body = wire.referralBody(user, reference, observedAt, self._context)
	self._arrivals += 1
	self._engine:submit("referral:" .. self._arrivals, body, {
		{
			name = "delivery",
			offsets = Client.ARRIVAL_OFFSETS,
			attempt = function(payload: any, attempt: number)
				local outcome = self._post(wire.REFERRALS_PATH, payload)
				if outcome.ok then
					local answer = outcome.facts and outcome.facts.outcome
					if answer == "unrecognized_reference" then
						self:_unrecognized()
					else
						self:_say("info", "creator-link reference reported (" .. tostring(answer) .. ")")
					end
				else
					self:_say("warn", "creator-link reference attempt " .. attempt .. " failed (" .. tostring(outcome.kind) .. ")")
				end
				return outcome
			end,
		},
	})
end

-- R3FTO answered that it does not know the value: one warning per server, then info lines.
function Client:_unrecognized()
	if not self._unrecognizedWarned then
		self._unrecognizedWarned = true
		self:_say("warn", Client.UNRECOGNIZED_WARNING)
		return
	end
	self:_say("info", "a creator link value was not recognized")
end

-- The player of an observed join left: a later join of the same player is a new arrival.
function Client:_playerLeft(join: any)
	if join ~= nil then
		self._joins[join] = nil
	end
end

function Client:_onClose()
	local memoryOnly = 0
	for key, job in self._engine:jobs() do
		if string.sub(key, 1, 8) == "receipt:" and self._runtime.Engine.durability(job) == "memory_only" then
			memoryOnly += 1
		end
	end
	if memoryOnly > 0 or #self._waiting > 0 then
		-- No extra attempt is made here (the retry schedule caps attempts); this only makes the possible loss visible.
		self:_say("warn", string.format("server closing with %d receipt(s) that have no durable copy yet and %d never started", memoryOnly, #self._waiting))
	end
	self:_closingSignal()
end

-- R3FTO.openKeyPanel(player): opens the optional key panel for one player in this server; a second call for the same
-- player replaces that player's panel. Answers true, or false and the reason (also printed as a warning). Never throws.
-- The KeyPanelGui folder is looked up here, not when the SDK is required, so an install without it still loads and its
-- receipts run.
function Client:openKeyPanel(player: any): (boolean, string?)
	local called, opened, reason = pcall(self._openKeyPanel, self, player)
	if not called then
		-- An unexpected Roblox error while building the panel, most likely because the player left meanwhile.
		opened, reason = false, Client.KEY_PANEL_NOT_A_PLAYER
	end
	if opened then
		return true, nil
	end
	self:_say("warn", "openKeyPanel: " .. tostring(reason))
	return false, reason
end

function Client:_openKeyPanel(player: any): (boolean, string?)
	local runtime = self._runtime
	if not self._started then
		return false, Client.KEY_PANEL_NOT_STARTED
	end
	if runtime.isPlayerInServer == nil or not runtime.isPlayerInServer(player) then
		return false, Client.KEY_PANEL_NOT_A_PLAYER
	end
	local open = if runtime.keyPanelOpener
		then runtime.keyPanelOpener(function(owner: any, invoker: any, action: any, key: any): string
			return self:_keyPanelRequest(owner, invoker, action, key)
		end)
		else nil
	if open == nil then
		return false, Client.KEY_PANEL_FOLDER_MISSING
	end
	local opened, why = open(player)
	if opened then
		return true, nil
	end
	if why == "folder" then
		return false, Client.KEY_PANEL_FOLDER_MISSING
	end
	return false, Client.KEY_PANEL_NOT_A_PLAYER
end

-- Counts one key panel answer and returns the token the panel receives. `sent` is true when the answer came after a
-- request was sent to R3FTO; only those answers print their info line.
function Client:_panelAnswer(answer: string, sent: boolean?): string
	self._panelOutcomes[answer] += 1
	if sent and KEY_PANEL_LINES[answer] ~= nil then
		self:_say("info", KEY_PANEL_LINES[answer])
	end
	return answer
end

-- True when this server may send one more key panel request now: fewer than KEY_PANEL_PER_MINUTE started in the last
-- KEY_PANEL_WINDOW seconds. A request that is let through is counted at once.
function Client:_panelTake(): boolean
	local now = self._runtime.now()
	local times = self._panelTimes
	while #times > 0 and now - times[1] >= Client.KEY_PANEL_WINDOW do
		table.remove(times, 1)
	end
	if #times >= Client.KEY_PANEL_PER_MINUTE then
		return false
	end
	table.insert(times, now)
	return true
end

-- One request from a player's key panel (the panel's remote). `owner` is the player the panel was opened for, `invoker`
-- the player Roblox says sent it. Returns one answer token and never throws:
--   accepted, unknown_key, unavailable   R3FTO's answer
--   busy                                 this player's previous request has not returned yet (nothing sent)
--   throttled                            this server reached its key panel limit for the minute (nothing sent)
--   failed                               anything else: a refusal, no answer, a wrong sender, the SDK closing
-- The UserId is the server-seen one; nothing the device sends but the action and the key is used.
function Client:_keyPanelRequest(owner: any, invoker: any, action: any, key: any): string
	local runtime = self._runtime
	local wire = runtime.Wire
	if invoker ~= owner or not self._started or self._closed or runtime.isPlayerInServer == nil or not runtime.isPlayerInServer(owner) then
		return self:_panelAnswer("failed")
	end
	if action ~= "use" then
		return self:_panelAnswer("failed")
	end
	local panelKey = wire.panelKey(key)
	if panelKey == nil then
		-- The panel itself sends only 4 to 16 letters, so only a changed device gets here.
		return self:_panelAnswer("unknown_key")
	end
	local user = wire.digits(owner.UserId)
	if user == nil or user == "0" then
		return self:_panelAnswer("failed")
	end
	-- One request at a time per player, by UserId, so it also holds across a reopened panel and a rejoin on this server.
	-- It is released only when the request returns, never on a timer.
	if self._panelBusy[user] then
		return self:_panelAnswer("busy")
	end
	if not self:_panelTake() then
		return self:_panelAnswer("throttled")
	end
	self._panelBusy[user] = true
	local body = wire.selectionBody(user, panelKey, self._context)
	local called, outcome = pcall(self._post, wire.SELECTIONS_PATH, body, wire.SELECTION_OUTCOMES)
	self._panelBusy[user] = nil
	if not called or type(outcome) ~= "table" then
		return self:_panelAnswer("failed", true)
	end
	if outcome.ok then
		local answer = outcome.facts and outcome.facts.outcome
		if type(answer) == "string" and wire.SELECTION_OUTCOMES[answer] then
			return self:_panelAnswer(answer, true)
		end
		return self:_panelAnswer("failed", true)
	end
	if outcome.kind == "rejected" and not self._panelRefusalWarned then
		-- A refusal (the token, the environment or the universe) repeats on every request: say it once.
		self._panelRefusalWarned = true
		self._panelOutcomes.failed += 1
		self:_say("warn", "R3FTO refused a key panel request (" .. tostring(outcome.detail) .. "); check the SDK token and the environment")
		return "failed"
	end
	if outcome.kind == "not_configured" and not self._panelNotConfiguredWarned then
		-- The secret is missing on this server, so no request ever leaves it: say it once (the start warning names the fix).
		self._panelNotConfiguredWarned = true
		self._panelOutcomes.failed += 1
		self:_say("warn", "key panel requests are not sent: the SDK token secret is not available (see the warning at start)")
		return "failed"
	end
	-- Without the secret no request left this server: no info line.
	return self:_panelAnswer("failed", outcome.kind ~= "not_configured")
end

-- R3FTO.getReceiptStatus(purchaseId): this server's view of one receipt, or nil.
function Client:getReceiptStatus(purchaseId: string): { [string]: any }?
	local job = self._engine:get("receipt:" .. tostring(purchaseId))
	if job == nil then
		local waiting = self._waitingIds[tostring(purchaseId)]
		if waiting then
			return { purchaseId = purchaseId, durability = "memory_only", queuedUntilStart = true, firstObservedAtUtc = waiting.firstObservedAtUtc }
		end
		return nil
	end
	local snapshot = self._runtime.Engine.snapshot(job)
	snapshot.purchaseId = purchaseId
	snapshot.firstObservedAtUtc = job.record.firstObservedAtUtc
	snapshot.simulated = job.record.simulated == true
	return snapshot
end

-- R3FTO.getDiagnostics(): safe to print. No token, no PlayerId, no creator key. `keyPanelOutcomes` counts the answers
-- the key panel received (no key, no UserId).
function Client:getDiagnostics(): { [string]: any }
	local counts = { delivered = 0, stored_awaiting_delivery = 0, memory_only = 0, not_durable = 0 }
	local referrals = 0
	-- R3FTO's answers to the arrivals; `failed` counts arrivals whose delivery ended without an answer (all attempts used,
	-- or refused). Arrivals still being sent are in none of them.
	local outcomes = { recorded = 0, already_recorded = 0, unrecognized_reference = 0, failed = 0 }
	for key, job in self._engine:jobs() do
		if string.sub(key, 1, 8) == "receipt:" then
			local durability = self._runtime.Engine.durability(job)
			counts[durability] += 1
		else
			referrals += 1
			local delivery = job.byName.delivery
			if delivery and delivery.state == "succeeded" then
				local answer = delivery.facts.outcome
				if answer == "recorded" or answer == "already_recorded" or answer == "unrecognized_reference" then
					outcomes[answer] += 1
				end
			elseif delivery and (delivery.state == "failed" or delivery.state == "rejected") then
				outcomes.failed += 1
			end
		end
	end
	local problems = table.clone(self._problems)
	local heartbeat = self._heartbeat
	return {
		sdkVersion = self._runtime.sdkVersion,
		started = self._started,
		environment = if self._context then self._context.environment else nil,
		universeId = if self._context then self._context.universeId else nil,
		receipts = counts,
		receiptsWaitingForStart = #self._waiting,
		referralObservations = referrals,
		referralOutcomes = outcomes,
		keyPanelOutcomes = table.clone(self._panelOutcomes),
		problems = problems,
		-- The latest server signal: its kind, when it was sent (UTC) and "sending", "recorded" or the failure kind.
		heartbeat = {
			lastKind = heartbeat.lastKind,
			lastSentAtUtc = heartbeat.lastSentAtUtc,
			lastResult = heartbeat.lastResult,
		},
	}
end

return table.freeze(Client)
