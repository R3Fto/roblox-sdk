--!nonstrict
-- R3FTO Roblox SDK: the public client behaviour.
--
-- Every Roblox service reaches this module through one `runtime` table, so the same code runs on a game server
-- (init.luau builds the runtime from the real services) and in the plain-Luau tests (fakes with the same shape).
--
-- What this module does, and what it never does (report §10.19, §10.21, K-42–K-46):
-- * observeReceipt() records the first observation time at once, before any yield or network call, queues the work and
--   returns. It never yields, never throws, never grants a product and never returns a ProductPurchaseDecision: the
--   publisher's own receipt handler stays the one handler and decides PurchaseGranted / NotProcessedYet itself.
-- * The work is two independent channels with the K-46 schedule: the DataStore copy and the direct R3FTO delivery.
-- * Duplicate calls for the same PurchaseId on this server join the existing work; they never restart it.
-- * The SDK reports evidence. It computes no creator share and no earning.

local Client = {}
Client.__index = Client

Client.DEFAULT_TOKEN_SECRET = "R3FTO_SDK_TOKEN"
Client.DEFAULT_API_BASE_URL = "https://r3f.to"

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
	-- players: calls `callback(userId, launchData)` for every player already in the server and every new one
	eachPlayer: (callback: (userId: number, launchData: any) -> ()) -> (),
	onClose: (callback: () -> ()) -> (),
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
		table.insert(self._problems, "the secret " .. secretName .. " is not available (" .. tostring(why) .. "), so direct delivery to R3FTO will fail")
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

	runtime.eachPlayer(function(userId: number, launchData: any)
		self:_observePlayer(userId, launchData)
	end)
	runtime.onClose(function()
		self:_onClose()
	end)
	return true, nil
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
	-- K-43: the observation time is taken first, before anything that could yield.
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

-- A referral observation: the R3FTO creator-link reference in this player's LaunchData, with the server-seen UserId.
function Client:_observePlayer(userId: number, launchData: any)
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
	self._engine:submit("referral:" .. user .. ":" .. reference, body, {
		{
			name = "delivery",
			attempt = function(payload: any, attempt: number)
				local outcome = self._post(wire.REFERRALS_PATH, payload)
				if outcome.ok then
					self:_say("info", "creator-link reference reported (" .. tostring(outcome.facts and outcome.facts.outcome) .. ")")
				else
					self:_say("warn", "creator-link reference attempt " .. attempt .. " failed (" .. tostring(outcome.kind) .. ")")
				end
				return outcome
			end,
		},
	})
end

function Client:_onClose()
	local memoryOnly = 0
	for key, job in self._engine:jobs() do
		if string.sub(key, 1, 8) == "receipt:" and self._runtime.Engine.durability(job) == "memory_only" then
			memoryOnly += 1
		end
	end
	if memoryOnly > 0 or #self._waiting > 0 then
		-- No extra attempt is made here (K-46 caps attempts); this only makes the possible loss visible.
		self:_say("warn", string.format("server closing with %d receipt(s) that have no durable copy yet and %d never started", memoryOnly, #self._waiting))
	end
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

-- R3FTO.getDiagnostics(): safe to print. No token, no PlayerId.
function Client:getDiagnostics(): { [string]: any }
	local counts = { delivered = 0, stored_awaiting_delivery = 0, memory_only = 0, not_durable = 0 }
	local referrals = 0
	for key, job in self._engine:jobs() do
		if string.sub(key, 1, 8) == "receipt:" then
			local durability = self._runtime.Engine.durability(job)
			counts[durability] += 1
		else
			referrals += 1
		end
	end
	local problems = table.clone(self._problems)
	return {
		sdkVersion = self._runtime.sdkVersion,
		started = self._started,
		environment = if self._context then self._context.environment else nil,
		universeId = if self._context then self._context.universeId else nil,
		receipts = counts,
		receiptsWaitingForStart = #self._waiting,
		referralObservations = referrals,
		problems = problems,
	}
end

return table.freeze(Client)
