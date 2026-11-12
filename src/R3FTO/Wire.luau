--!strict
-- R3FTO Roblox SDK: wire helpers (pure Luau, no Roblox service).
--
-- * Validates the receiptInfo table Roblox passes to the publisher's own receipt handler.
-- * Builds the DataStore record (DataStore "R3FTO_Receipts_v1", scope = environment, key = PurchaseId, schema 1).
-- * Builds the JSON bodies of POST /v1/roblox-sdk/receipts, /v1/roblox-sdk/referral-observations and
--   /v1/roblox-sdk/heartbeats. Roblox ids and Robux amounts travel as decimal STRINGS so nothing can round them (Luau
--   numbers are doubles).
-- * Classifies an HTTP answer into the engine's attempt result.
-- * Reads the R3FTO creator-link reference from LaunchData.

local Wire = {}

Wire.SCHEMA = 1
Wire.DATASTORE_NAME = "R3FTO_Receipts_v1"
Wire.MAX_DATASTORE_KEY = 50 -- Roblox: key names are at most 50 characters
Wire.MAX_PURCHASE_ID = 100 -- R3FTO: purchase_id is at most 100 characters
Wire.RECEIPTS_PATH = "/v1/roblox-sdk/receipts"
Wire.REFERRALS_PATH = "/v1/roblox-sdk/referral-observations"
Wire.HEARTBEATS_PATH = "/v1/roblox-sdk/heartbeats"
Wire.SIMULATED_PREFIX = "r3fto-sim-"

local MAX_SAFE_INTEGER = 9007199254740991 -- 2^53 - 1: above it a Luau number is no longer an exact integer

-- An exact non-negative integer as a decimal string, or nil.
function Wire.digits(value: any): string?
	if type(value) ~= "number" then
		return nil
	end
	if value ~= value or value < 0 or value > MAX_SAFE_INTEGER or math.floor(value) ~= value then
		return nil
	end
	return string.format("%d", value)
end

-- The name of a Roblox EnumItem (Enum.CurrencyType.Robux -> "Robux"), a plain string as is, otherwise nil.
local function enumName(value: any): string?
	if value == nil then
		return nil
	end
	if type(value) == "string" then
		return value
	end
	local ok, name = pcall(function()
		return (value :: any).Name
	end)
	if ok and type(name) == "string" then
		return name
	end
	return nil
end

local function printable(text: string): boolean
	-- Visible ASCII only; PurchaseIds are GUID-like.
	return string.find(text, "^[%w%-_%.:{}]+$") ~= nil
end

export type Receipt = {
	purchaseId: string,
	playerId: string,
	productId: string,
	currencySpent: string,
	currencyType: string,
	placeIdWherePurchased: string?,
	purchaseChannel: string?,
}

-- Validates and normalises a receiptInfo table. Returns the receipt, or nil and a short reason.
function Wire.readReceipt(receiptInfo: any): (Receipt?, string?)
	if type(receiptInfo) ~= "table" then
		return nil, "receiptInfo must be the table Roblox passed to the receipt handler"
	end
	local purchaseId = receiptInfo.PurchaseId
	if type(purchaseId) ~= "string" or #purchaseId == 0 then
		return nil, "PurchaseId is missing"
	end
	if #purchaseId > Wire.MAX_PURCHASE_ID or not printable(purchaseId) then
		return nil, "PurchaseId has an unexpected format"
	end
	local playerId = Wire.digits(receiptInfo.PlayerId)
	if playerId == nil or playerId == "0" then
		return nil, "PlayerId is missing or not a whole number"
	end
	local productId = Wire.digits(receiptInfo.ProductId)
	if productId == nil or productId == "0" then
		return nil, "ProductId is missing or not a whole number"
	end
	local currencySpent = Wire.digits(receiptInfo.CurrencySpent)
	if currencySpent == nil then
		return nil, "CurrencySpent is missing or not a whole number"
	end
	local currencyType = enumName(receiptInfo.CurrencyType) or "Robux"
	local place = receiptInfo.PlaceIdWherePurchased
	local placeId = if place ~= nil then Wire.digits(place) else nil
	return {
		purchaseId = purchaseId :: string,
		playerId = playerId,
		productId = productId,
		currencySpent = currencySpent,
		currencyType = currencyType,
		placeIdWherePurchased = placeId,
		purchaseChannel = enumName(receiptInfo.ProductPurchaseChannel),
	},
		nil
end

-- Days since 1970-01-01 -> civil date (Howard Hinnant's days_from_civil inverse), all integer arithmetic.
local function civilFromDays(days: number): (number, number, number)
	local z = days + 719468
	local era = (if z >= 0 then z else z - 146096) // 146097
	local doe = z - era * 146097
	local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	local y = yoe + era * 400
	local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	local mp = (5 * doy + 2) // 153
	local d = doy - (153 * mp + 2) // 5 + 1
	local m = if mp < 10 then mp + 3 else mp - 9
	if m <= 2 then
		y += 1
	end
	return y, m, d
end

-- An ISO 8601 UTC time with milliseconds from Unix milliseconds: 2026-11-11T10:30:45.123Z.
function Wire.isoUtcFromMillis(unixMillis: number): string
	local ms = math.floor(unixMillis)
	local seconds = ms // 1000
	local millis = ms - seconds * 1000
	local days = seconds // 86400
	local secondOfDay = seconds - days * 86400
	local year, month, day = civilFromDays(days)
	local hour = secondOfDay // 3600
	local minute = (secondOfDay - hour * 3600) // 60
	local second = secondOfDay - hour * 3600 - minute * 60
	return string.format("%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", year, month, day, hour, minute, second, millis)
end

export type Context = {
	environment: string, -- "production" | "test"
	universeId: string,
	placeId: string?,
	serverJobId: string?,
	sdkVersion: string,
}

-- The DataStore value (schema 1). camelCase, as Roblox data usually is; R3FTO's recovery check reads it back through the
-- Roblox DataStore API.
function Wire.receiptRecord(receipt: Receipt, firstObservedAtUtc: string, context: Context, simulated: boolean)
	return {
		schema = Wire.SCHEMA,
		purchaseId = receipt.purchaseId,
		playerId = receipt.playerId,
		productId = receipt.productId,
		currencySpent = receipt.currencySpent,
		currencyType = receipt.currencyType,
		placeIdWherePurchased = receipt.placeIdWherePurchased,
		purchaseChannel = receipt.purchaseChannel,
		universeId = context.universeId,
		environment = context.environment,
		firstObservedAtUtc = firstObservedAtUtc,
		firstObservedServerJobId = context.serverJobId,
		sdkVersion = context.sdkVersion,
		simulated = simulated,
	}
end

-- True when an existing DataStore value is a usable schema-1 receipt record for this PurchaseId.
function Wire.isRecord(value: any, purchaseId: string): boolean
	return type(value) == "table"
		and value.schema == Wire.SCHEMA
		and value.purchaseId == purchaseId
		and type(value.firstObservedAtUtc) == "string"
		and type(value.playerId) == "string"
		and type(value.productId) == "string"
		and type(value.currencySpent) == "string"
end

-- The purchase facts two records of one PurchaseId must share. The observation time is NOT compared: when another
-- server observed the receipt first, its earlier time is the one kept (the first observation time never changes) and
-- that is not a mismatch.
function Wire.samePurchase(a: any, b: any): boolean
	return a.purchaseId == b.purchaseId
		and a.playerId == b.playerId
		and a.productId == b.productId
		and a.currencySpent == b.currencySpent
end

-- POST /v1/roblox-sdk/receipts body. Built from the CANONICAL record (an adopted DataStore record wins).
function Wire.receiptBody(record: any, context: Context)
	return {
		environment = context.environment,
		universe_id = context.universeId,
		place_id = context.placeId,
		server_job_id = context.serverJobId,
		sdk_version = context.sdkVersion,
		simulated = record.simulated == true,
		receipt = {
			purchase_id = record.purchaseId,
			player_id = record.playerId,
			product_id = record.productId,
			currency_spent = record.currencySpent,
			currency_type = record.currencyType,
			place_id_where_purchased = record.placeIdWherePurchased,
			purchase_channel = record.purchaseChannel,
		},
		first_observed_at = record.firstObservedAtUtc,
		record_source = "sdk_direct",
	}
end

-- POST /v1/roblox-sdk/referral-observations body.
function Wire.referralBody(userId: string, reference: string, observedAtUtc: string, context: Context)
	return {
		environment = context.environment,
		universe_id = context.universeId,
		place_id = context.placeId,
		server_job_id = context.serverJobId,
		sdk_version = context.sdkVersion,
		roblox_user_id = userId,
		launch_reference = reference,
		observed_at = observedAtUtc,
	}
end

-- This server's receipts by durability (see Engine.durability), as the server signal reports them.
export type ReceiptCounts = {
	memory_only: number,
	stored_awaiting_delivery: number,
	not_durable: number,
}

-- POST /v1/roblox-sdk/heartbeats body: one server signal ("started" | "alive" | "closing"). Integration data only: the
-- environment, universe, place, server job id, SDK version, the kind, the send time and this server's receipt counts.
-- No PlayerId and nothing about players.
function Wire.heartbeatBody(kind: string, sentAtUtc: string, counts: ReceiptCounts, context: Context, serverJobId: string)
	return {
		environment = context.environment,
		universe_id = context.universeId,
		place_id = context.placeId,
		server_job_id = serverJobId,
		sdk_version = context.sdkVersion,
		kind = kind,
		sent_at = sentAtUtc,
		receipts = {
			memory_only = counts.memory_only,
			stored_awaiting_delivery = counts.stored_awaiting_delivery,
			not_durable = counts.not_durable,
		},
	}
end

-- The R3FTO creator-link reference in LaunchData: exactly an R3FTO referral token ("rt_" + 26 base32 characters).
-- Anything else (no launch data, the publisher's own launch data) is not an R3FTO reference and is ignored.
function Wire.launchReference(launchData: any): string?
	if type(launchData) ~= "string" then
		return nil
	end
	if string.find(launchData, "^rt_[a-z2-7]+$") ~= nil and #launchData == 29 then
		return launchData
	end
	return nil
end

local OUTCOMES = { recorded = true, already_recorded = true, unrecognized_reference = true }

local function header(headers: any, name: string): string?
	if type(headers) ~= "table" then
		return nil
	end
	local wanted = string.lower(name)
	for key, value in headers do
		if type(key) == "string" and string.lower(key) == wanted and type(value) == "string" then
			return value
		end
	end
	return nil
end

-- Classifies an HTTP answer. `body` is the decoded JSON body or nil.
--   2xx with a known outcome           ok (R3FTO committed it to PostgreSQL before answering)
--   2xx without one                    ambiguous, retried with the same identity
--   408, 425, 429, 5xx                 retryable; Retry-After (seconds) is honoured when present
--   any other 4xx                      rejected: retrying the same request cannot succeed
function Wire.classifyHttp(statusCode: number, headers: any, body: any): { [string]: any }
	if statusCode >= 200 and statusCode < 300 then
		if type(body) == "table" and OUTCOMES[body.outcome] then
			local facts: { [string]: any } = { outcome = body.outcome }
			if type(body.receipt_id) == "string" then
				facts.receiptId = body.receipt_id
			end
			if type(body.matches_first_record) == "boolean" then
				facts.matchesFirstRecord = body.matches_first_record
			end
			if type(body.first_observed_at) == "string" then
				facts.storedFirstObservedAt = body.first_observed_at
			end
			return { ok = true, facts = facts }
		end
		return { ok = false, kind = "ambiguous", retryable = true, detail = "unexpected answer " .. statusCode }
	end

	local code = if type(body) == "table" and type(body.error) == "table" and type(body.error.code) == "string"
		then body.error.code
		else nil
	local detail = "HTTP " .. statusCode .. (if code then " " .. code else "")
	if statusCode == 408 or statusCode == 425 or statusCode == 429 or statusCode >= 500 then
		local retryAfter = tonumber(header(headers, "Retry-After") or "")
		local throttled = statusCode == 429 or (statusCode == 503 and retryAfter ~= nil)
		return {
			ok = false,
			kind = if throttled then "throttled" else "transport_failed",
			retryable = true,
			retryAfter = if retryAfter and retryAfter > 0 then retryAfter else nil,
			detail = detail,
		}
	end
	return { ok = false, kind = "rejected", retryable = false, detail = detail }
end

return table.freeze(Wire)
