-- Plain-Luau tests of the R3FTO Roblox SDK logic. Run from the repository root:
--   luau sdk/roblox/tests/run.luau
-- They use the SDK's real Engine, Wire, Client and RobloxAdapters over fakes (tests/Fakes.luau). They do NOT prove real
-- Roblox behaviour (DataStore, HttpService, Secrets, LaunchData, purchases); see sdk/roblox/README.md "Validation".

local Fakes = require("./Fakes")
local Wire = Fakes.Wire

local tests = {}
local function test(name, fn)
	table.insert(tests, { name = name, fn = fn })
end

local function eq(actual, expected, label)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", label or "value", tostring(expected), tostring(actual)), 2)
	end
end

local function times(requests)
	local list = {}
	for _, request in requests do
		table.insert(list, tostring(request.at))
	end
	return table.concat(list, ",")
end

local function failing(status, headers)
	return function()
		return { status = status, headers = headers, body = { error = { code = "X", message = "x" } } }
	end
end

-- Wire ---------------------------------------------------------------------------------------------------------------

test("ISO UTC time with milliseconds from Unix milliseconds", function()
	eq(Wire.isoUtcFromMillis(0), "1970-01-01T00:00:00.000Z")
	eq(Wire.isoUtcFromMillis(951782400000), "2000-02-29T00:00:00.000Z")
	eq(Wire.isoUtcFromMillis(4102444799999), "2099-12-31T23:59:59.999Z")
	eq(Wire.isoUtcFromMillis(1762857045123), "2025-11-11T10:30:45.123Z")
end)

test("ids and amounts travel as exact decimal strings", function()
	eq(Wire.digits(0), "0")
	eq(Wire.digits(9007199254740991), "9007199254740991")
	eq(Wire.digits(9007199254740992), nil, "2^53")
	eq(Wire.digits(1.5), nil, "fraction")
	eq(Wire.digits(-1), nil, "negative")
	eq(Wire.digits(0 / 0), nil, "NaN")
	eq(Wire.digits("12"), nil, "string")
end)

test("readReceipt accepts the Roblox receipt table and refuses anything else", function()
	local receipt = assert(Wire.readReceipt(Fakes.receipt()))
	eq(receipt.playerId, "1234567")
	eq(receipt.currencySpent, "200")
	eq(receipt.placeIdWherePurchased, "222")
	eq((Wire.readReceipt(nil)), nil, "nil")
	eq((Wire.readReceipt(Fakes.receipt({ PurchaseId = "" }))), nil, "empty id")
	eq((Wire.readReceipt(Fakes.receipt({ PurchaseId = string.rep("a", 101) }))), nil, "long id")
	eq((Wire.readReceipt(Fakes.receipt({ PurchaseId = "bad id\n" }))), nil, "control characters")
	eq((Wire.readReceipt(Fakes.receipt({ CurrencySpent = 2.5 }))), nil, "fractional Robux")
	eq((Wire.readReceipt(Fakes.receipt({ PlayerId = 0 }))), nil, "player 0")
	eq(assert(Wire.readReceipt(Fakes.receipt({ CurrencySpent = 0 }))).currencySpent, "0", "free purchase kept")
end)

test("LaunchData carries an R3FTO referral token only when it is exactly one", function()
	local token = "rt_abcdefghijklmnopqrstuvwxyz"
	eq(#token, 29)
	eq(Wire.launchReference(token), token)
	eq(Wire.launchReference(nil), nil)
	eq(Wire.launchReference(""), nil)
	eq(Wire.launchReference("rt_ABCDEFGHIJKLMNOPQRSTUVWXYZ"), nil, "upper case")
	eq(Wire.launchReference("rt_abcdefghijklmnopqrstuvwxy1"), nil, "1 is not base32")
	eq(Wire.launchReference('{"level":3}'), nil, "publisher launch data")
	eq(Wire.launchReference(token .. "x"), nil, "too long")
end)

test("a creator link value is r3f_ and a key of 4 to 16 letters or digits, sent in upper case", function()
	eq(Wire.launchReference("r3f_kael"), "r3f_KAEL", "lower case key")
	eq(Wire.launchReference("R3F_Kael"), "r3f_KAEL", "upper case prefix, mixed case key")
	eq(Wire.launchReference("r3f_B4CD5FGH"), "r3f_B4CD5FGH", "a generated key with digits")
	eq(Wire.launchReference("r3f_TSTA"), "r3f_TSTA", "a Test key")
	eq(Wire.launchReference("r3f_" .. string.rep("K", 16)), "r3f_" .. string.rep("K", 16), "16 characters")
	eq(Wire.launchReference("r3f_ab"), nil, "too short")
	eq(Wire.launchReference("r3f_ABC"), nil, "3 characters")
	eq(Wire.launchReference("r3f_" .. string.rep("K", 17)), nil, "17 characters")
	eq(Wire.launchReference("r3f_KA-EL"), nil, "a hyphen")
	eq(Wire.launchReference("r3f_KA_EL"), nil, "an underscore")
	eq(Wire.launchReference("r3f_KAEL "), nil, "a trailing space")
	eq(Wire.launchReference(" r3f_KAEL"), nil, "a leading space")
	eq(Wire.launchReference("r3f_KAEL\n"), nil, "a new line")
	eq(Wire.launchReference("xr3f_KAEL"), nil, "anything before the prefix")
	eq(Wire.launchReference("r3f_"), nil, "no key")
	eq(Wire.launchReference("r3fKAEL"), nil, "no underscore")
	eq(Wire.launchReference("r3f_KÄEL"), nil, "a non-ASCII letter")
	eq(Wire.launchReference(5), nil, "not a string")
	eq(Wire.launchReference({ r3f = "KAEL" }), nil, "a table")
	eq(Wire.launchReference('{"r3f":"KAEL"}'), nil, "JSON")
end)

test("HTTP classification", function()
	eq(Wire.classifyHttp(200, {}, { outcome = "recorded" }).ok, true)
	eq(Wire.classifyHttp(200, {}, { outcome = "already_recorded" }).ok, true)
	local odd = Wire.classifyHttp(200, {}, nil)
	eq(odd.ok, false)
	eq(odd.kind, "ambiguous")
	eq(odd.retryable, true)
	local throttled = Wire.classifyHttp(429, { ["retry-after"] = "120" }, nil)
	eq(throttled.kind, "throttled")
	eq(throttled.retryAfter, 120)
	eq(Wire.classifyHttp(503, {}, nil).kind, "transport_failed")
	eq(Wire.classifyHttp(500, {}, nil).retryable, true)
	local rejected = Wire.classifyHttp(401, {}, { error = { code = "AUTHENTICATION_REQUIRED" } })
	eq(rejected.kind, "rejected")
	eq(rejected.retryable, false)
	eq(rejected.detail, "HTTP 401 AUTHENTICATION_REQUIRED")
	eq(Wire.classifyHttp(403, {}, nil).retryable, false)
end)

-- Retry schedule -----------------------------------------------------------------------------------------------------

test("a failing channel is attempted at 0, 60, 180 and 300 seconds, then stops", function()
	local f = Fakes.runtime({ server = failing(503) })
	assert(f.client:start({ environment = "production" }))
	local answer = f.client:observeReceipt(Fakes.receipt())
	eq(answer.accepted, true)
	f.scheduler.run()
	local deliveries = Fakes.requestsTo(f.http, Wire.RECEIPTS_PATH)
	eq(times(deliveries), "0,60,180,300", "delivery attempt times")
	local status = assert(f.client:getReceiptStatus(answer.purchaseId))
	eq(status.channels.delivery.state, "failed")
	eq(status.channels.delivery.attempts, 4)
	eq(status.channels.storage.state, "succeeded")
	eq(status.durability, "stored_awaiting_delivery")
end)

test("a channel that succeeds stops; the other keeps its own schedule", function()
	local calls = 0
	local f = Fakes.runtime({
		server = function(url)
			if string.sub(url, -#Wire.RECEIPTS_PATH) ~= Wire.RECEIPTS_PATH then
				return { status = 200, body = { outcome = "recorded" } }
			end
			calls += 1
			if calls == 1 then
				return { status = 500 }
			end
			return { status = 200, body = { outcome = "recorded" } }
		end,
	})
	f.dataStores.failAlways = true
	assert(f.client:start({ environment = "production" }))
	local answer = f.client:observeReceipt(Fakes.receipt())
	f.scheduler.run()
	eq(times(Fakes.requestsTo(f.http, Wire.RECEIPTS_PATH)), "0,60", "delivery stopped after its success")
	eq(table.concat(f.dataStores.callTimes, ","), "0,60,180,300", "storage kept all four of its attempts")
	local status = assert(f.client:getReceiptStatus(answer.purchaseId))
	eq(status.channels.storage.state, "failed")
	eq(status.durability, "delivered")
end)

test("offsets count from each channel's own first attempt", function()
	local f = Fakes.runtime({ server = failing(500) })
	f.dataStores.latency = 5 -- the first DataStore call takes 5 s, so delivery starts at 5
	assert(f.client:start({ environment = "production" }))
	f.client:observeReceipt(Fakes.receipt())
	f.scheduler.run()
	eq(times(Fakes.requestsTo(f.http, Wire.RECEIPTS_PATH)), "5,65,185,305")
end)

test("Retry-After skips early slots and never adds an attempt", function()
	local f = Fakes.runtime({ server = failing(429, { ["Retry-After"] = "120" }) })
	assert(f.client:start({ environment = "production" }))
	local answer = f.client:observeReceipt(Fakes.receipt())
	f.scheduler.run()
	eq(times(Fakes.requestsTo(f.http, Wire.RECEIPTS_PATH)), "0,180,300", "the 60 s slot is skipped")
	local status = assert(f.client:getReceiptStatus(answer.purchaseId))
	eq(status.channels.delivery.skippedSlots, 1)
	eq(status.channels.delivery.lastError, "throttled")

	local g = Fakes.runtime({ server = failing(503, { ["Retry-After"] = "3600" }) })
	assert(g.client:start({ environment = "production" }))
	local other = g.client:observeReceipt(Fakes.receipt())
	g.scheduler.run()
	eq(#Fakes.requestsTo(g.http, Wire.RECEIPTS_PATH), 1, "a long Retry-After ends this round")
	eq(assert(g.client:getReceiptStatus(other.purchaseId)).channels.delivery.state, "failed")
end)

test("a rejected request (401) is not retried", function()
	local f = Fakes.runtime({ server = failing(401) })
	assert(f.client:start({ environment = "production" }))
	local answer = f.client:observeReceipt(Fakes.receipt())
	f.scheduler.run()
	eq(#Fakes.requestsTo(f.http, Wire.RECEIPTS_PATH), 1)
	local status = assert(f.client:getReceiptStatus(answer.purchaseId))
	eq(status.channels.delivery.state, "rejected")
	eq(status.durability, "stored_awaiting_delivery")
end)

-- Identity, duplicates, first observation ----------------------------------------------------------------------------

test("duplicate callbacks join the running work and never restart the schedule", function()
	local f = Fakes.runtime({ server = failing(500) })
	assert(f.client:start({ environment = "production" }))
	local first = f.client:observeReceipt(Fakes.receipt())
	f.scheduler.run(30)
	local second = f.client:observeReceipt(Fakes.receipt())
	f.scheduler.run(100)
	local third = f.client:observeReceipt(Fakes.receipt())
	f.scheduler.run()
	eq(first.duplicate, false)
	eq(second.duplicate, true)
	eq(third.duplicate, true)
	eq(second.firstObservedAtUtc, first.firstObservedAtUtc, "first observation unchanged")
	eq(times(Fakes.requestsTo(f.http, Wire.RECEIPTS_PATH)), "0,60,180,300", "one schedule only")
	eq(f.dataStores.calls, 1, "one DataStore write")
	eq(assert(f.client:getReceiptStatus(first.purchaseId)).duplicateSubmits, 2)
end)

test("an existing DataStore record (another server saw it first) keeps its first observation time", function()
	local f = Fakes.runtime()
	local earlier = "2025-11-11T10:29:00.000Z"
	local existing = Wire.receiptRecord(assert(Wire.readReceipt(Fakes.receipt())), earlier, {
		environment = "production", universeId = "111", placeId = "222", serverJobId = "job-0", sdkVersion = "0.1.0",
	}, false)
	f.dataStores:GetDataStore(Wire.DATASTORE_NAME, "production")
	f.dataStores.stores[Wire.DATASTORE_NAME .. "/production"][existing.purchaseId] = existing
	assert(f.client:start({ environment = "production" }))
	local answer = f.client:observeReceipt(Fakes.receipt())
	f.scheduler.run()
	local sent = Fakes.requestsTo(f.http, Wire.RECEIPTS_PATH)
	eq(#sent, 1)
	eq(sent[1].body.first_observed_at, earlier, "R3FTO receives the durable first observation")
	eq(assert(f.client:getReceiptStatus(answer.purchaseId)).firstObservedAtUtc, earlier)
	eq(f.dataStores.stores[Wire.DATASTORE_NAME .. "/production"][existing.purchaseId].firstObservedAtUtc, earlier, "not overwritten")
end)

test("a lost DataStore answer is retried with the same identity and converges", function()
	local f = Fakes.runtime()
	f.dataStores.writeThenFail = 1
	assert(f.client:start({ environment = "production" }))
	local answer = f.client:observeReceipt(Fakes.receipt())
	f.scheduler.run()
	eq(f.dataStores.calls, 2, "retried once")
	local stored = f.dataStores.stores[Wire.DATASTORE_NAME .. "/production"][answer.purchaseId]
	eq(stored.firstObservedAtUtc, answer.firstObservedAtUtc, "the first write's time is kept")
	local status = assert(f.client:getReceiptStatus(answer.purchaseId))
	eq(status.channels.storage.state, "succeeded")
	eq(status.channels.storage.facts.adoptedExistingRecord, true)
	eq(f.dataStores.userIds[answer.purchaseId][1], 1234567, "record tagged with the buyer's UserId")
end)

test("a failed DataStore write still delivers directly with the same receipt and time", function()
	local f = Fakes.runtime()
	f.dataStores.failures = 2
	assert(f.client:start({ environment = "production" }))
	local answer = f.client:observeReceipt(Fakes.receipt())
	f.scheduler.run()
	local sent = Fakes.requestsTo(f.http, Wire.RECEIPTS_PATH)
	eq(#sent, 1)
	eq(sent[1].at, 0, "delivery did not wait for the DataStore")
	eq(sent[1].body.first_observed_at, answer.firstObservedAtUtc)
	eq(sent[1].body.receipt.currency_spent, "200")
	eq(table.concat(f.dataStores.callTimes, ","), "0,60,180", "storage retried on its own schedule until it worked")
	local stored = f.dataStores.stores[Wire.DATASTORE_NAME .. "/production"][answer.purchaseId]
	eq(stored.firstObservedAtUtc, answer.firstObservedAtUtc, "the late DataStore copy has the original time")
end)

test("nothing durable: memory_only while attempts remain, not_durable after, and a warning on close", function()
	local f = Fakes.runtime({ server = failing(500) })
	f.dataStores.failAlways = true
	assert(f.client:start({ environment = "production" }))
	local answer = f.client:observeReceipt(Fakes.receipt())
	f.scheduler.run(100)
	eq(assert(f.client:getReceiptStatus(answer.purchaseId)).durability, "memory_only")
	f.close()
	local warned = false
	for _, line in f.logs do
		if string.find(line.message, "no durable copy", 1, true) then
			warned = true
		end
	end
	eq(warned, true, "close warning")
	eq(#Fakes.requestsTo(f.http, Wire.RECEIPTS_PATH), 2, "closing adds no attempt")
	f.scheduler.run()
	eq(assert(f.client:getReceiptStatus(answer.purchaseId)).durability, "not_durable")
end)

test("a timeout is ambiguous and retried with the same PurchaseId and time", function()
	local calls = 0
	local f = Fakes.runtime({
		server = function(url)
			if string.sub(url, -#Wire.RECEIPTS_PATH) ~= Wire.RECEIPTS_PATH then
				return { status = 200, body = { outcome = "recorded" } }
			end
			calls += 1
			if calls == 1 then
				error("HttpError: Timedout")
			end
			return { status = 200, body = { outcome = "already_recorded", matches_first_record = true } }
		end,
	})
	assert(f.client:start({ environment = "production" }))
	local answer = f.client:observeReceipt(Fakes.receipt())
	f.scheduler.run()
	local sent = Fakes.requestsTo(f.http, Wire.RECEIPTS_PATH)
	eq(#sent, 2)
	eq(sent[1].body.receipt.purchase_id, sent[2].body.receipt.purchase_id)
	eq(sent[1].body.first_observed_at, sent[2].body.first_observed_at)
	local status = assert(f.client:getReceiptStatus(answer.purchaseId))
	eq(status.channels.delivery.facts.outcome, "already_recorded")
	eq(status.durability, "delivered")
end)

-- The publisher's handler ----------------------------------------------------------------------------------------------

test("observeReceipt does no I/O and never yields inside the publisher's handler", function()
	local f = Fakes.runtime()
	assert(f.client:start({ environment = "production" }))
	-- A publisher handler: grant, observe, decide. Called outside any scheduled coroutine, so a yield would error.
	local granted = {}
	local function processReceipt(receiptInfo)
		granted[receiptInfo.PurchaseId] = true -- the publisher's own grant
		f.client:observeReceipt(receiptInfo)
		return "PurchaseGranted"
	end
	eq(processReceipt(Fakes.receipt()), "PurchaseGranted")
	eq(#f.http.requests, 0, "no request before the handler returned")
	eq(f.dataStores.calls, 0, "no DataStore call before the handler returned")
	f.scheduler.run()
	eq(#Fakes.requestsTo(f.http, Wire.RECEIPTS_PATH), 1)
end)

test("an R3FTO failure never changes the publisher's decision; bad input never throws", function()
	local f = Fakes.runtime({ server = failing(500), secretMissing = true })
	f.dataStores.failAlways = true
	assert(f.client:start({ environment = "production" }))
	local function processReceipt(receiptInfo)
		f.client:observeReceipt(receiptInfo)
		return "PurchaseGranted"
	end
	eq(processReceipt(Fakes.receipt()), "PurchaseGranted")
	for _, junk in { nil, 5, "x", {}, { PurchaseId = {} }, Fakes.receipt({ PlayerId = math.huge }) } do
		local answer = f.client:observeReceipt(junk)
		eq(answer.accepted, false)
	end
	f.scheduler.run()
	eq(#f.http.requests, 0, "no token: nothing is sent")
end)

test("receipts observed before start keep their own first observation time", function()
	local f = Fakes.runtime()
	local early = f.client:observeReceipt(Fakes.receipt())
	eq(early.queuedUntilStart, true)
	f.scheduler.run(50)
	assert(f.client:start({ environment = "production" }))
	f.scheduler.run()
	local sent = Fakes.requestsTo(f.http, Wire.RECEIPTS_PATH)
	eq(#sent, 1)
	eq(sent[1].body.first_observed_at, "2025-11-11T10:30:45.123Z", "time of the observation, not of start")
end)

-- Environments, simulation, referral -----------------------------------------------------------------------------------

test("Test and Production use separate DataStore scopes and declare their environment", function()
	local prod = Fakes.runtime()
	assert(prod.client:start({ environment = "Production" }))
	local answer = prod.client:observeReceipt(Fakes.receipt())
	prod.scheduler.run()
	eq(Fakes.requestsTo(prod.http, Wire.RECEIPTS_PATH)[1].body.environment, "production")
	assert(prod.dataStores.stores[Wire.DATASTORE_NAME .. "/production"][answer.purchaseId])

	local test = Fakes.runtime()
	assert(test.client:start({ environment = "test" }))
	test.client:observeReceipt(Fakes.receipt())
	test.scheduler.run()
	eq(Fakes.requestsTo(test.http, Wire.RECEIPTS_PATH)[1].body.environment, "test")
	eq(test.dataStores.stores[Wire.DATASTORE_NAME .. "/production"], nil, "Test never writes the Production scope")
end)

test("simulated receipts exist only in the R3FTO Test environment and are marked", function()
	local prod = Fakes.runtime()
	assert(prod.client:start({ environment = "production" }))
	eq(prod.client:simulateTestReceipt({ userId = 1, productId = 2, currencySpent = 3 }).accepted, false)

	local test = Fakes.runtime()
	assert(test.client:start({ environment = "test" }))
	local answer = test.client:simulateTestReceipt({ userId = 1, productId = 2, currencySpent = 3 })
	eq(answer.accepted, true)
	eq(string.sub(answer.purchaseId, 1, #Wire.SIMULATED_PREFIX), Wire.SIMULATED_PREFIX)
	test.scheduler.run()
	local body = Fakes.requestsTo(test.http, Wire.RECEIPTS_PATH)[1].body
	eq(body.simulated, true)
	eq(test.dataStores.stores[Wire.DATASTORE_NAME .. "/test"][answer.purchaseId].simulated, true)

	-- The same simulationId again is a repeated callback of the same simulated receipt.
	local first = test.client:simulateTestReceipt({ userId = 1, productId = 2, currencySpent = 3, simulationId = "demo-1" })
	local again = test.client:simulateTestReceipt({ userId = 1, productId = 2, currencySpent = 3, simulationId = "demo-1" })
	eq(first.purchaseId, "r3fto-sim-demo-1")
	eq(again.duplicate, true)
	eq(again.firstObservedAtUtc, first.firstObservedAtUtc)
	eq(test.client:simulateTestReceipt({ userId = 1, productId = 2, currencySpent = 3, simulationId = "bad id" }).accepted, false)
end)

test("start refuses a bad configuration and reports setup problems without failing", function()
	local f = Fakes.runtime({ isServer = false })
	eq((f.client:start({ environment = "production" })), false, "client side")
	local g = Fakes.runtime()
	eq((g.client:start({ environment = "staging" })), false, "unknown environment")
	eq((g.client:start({ environment = "test", apiBaseUrl = "http://r3f.to" })), false, "not https")
	local h = Fakes.runtime({ secretMissing = true, httpEnabled = false, universeId = 0 })
	eq((h.client:start({ environment = "test" })), true)
	eq(#h.client:getDiagnostics().problems, 3)
end)

test("a referral token is reported once per join with the server-seen UserId", function()
	local f = Fakes.runtime()
	assert(f.client:start({ environment = "production" }))
	local token = "rt_abcdefghijklmnopqrstuvwxyz"
	local first = f.join(1234567, token)
	f.leave(first)
	f.scheduler.run(10)
	f.join(1234567, token) -- same player, same value, another join on this server: reported again
	f.join(7654321, nil) -- no launch data
	f.join(5555555, '{"publisher":"data"}') -- the publisher's own launch data
	f.scheduler.run()
	local sent = Fakes.requestsTo(f.http, Wire.REFERRALS_PATH)
	eq(#sent, 2)
	eq(sent[1].body.roblox_user_id, "1234567")
	eq(sent[1].body.launch_reference, token)
	eq(sent[1].body.environment, "production")
	eq(sent[1].headers.Authorization, "Bearer <secret>")
	eq(sent[2].body.launch_reference, token)
	assert(sent[2].body.observed_at ~= sent[1].body.observed_at, "each join has its own observation time")
end)

test("diagnostics never contain a PlayerId or the token", function()
	local f = Fakes.runtime()
	assert(f.client:start({ environment = "production" }))
	f.client:observeReceipt(Fakes.receipt())
	f.scheduler.run()
	for _, line in f.logs do
		assert(not string.find(line.message, "1234567", 1, true), "PlayerId in a log line")
		assert(not string.find(line.message, "secret", 1, true), "secret in a log line")
	end
	local diagnostics = f.client:getDiagnostics()
	eq(diagnostics.receipts.delivered, 1)
end)

-- Server signal ------------------------------------------------------------------------------------------------------

local Client = Fakes.Client
local HOUR = Client.HEARTBEAT_INTERVAL

local function signals(f)
	return Fakes.requestsTo(f.http, Wire.HEARTBEATS_PATH)
end

local function kinds(requests)
	local list = {}
	for _, request in requests do
		table.insert(list, request.body.kind)
	end
	return table.concat(list, ",")
end

local function count(logs, level, text)
	local found = 0
	for _, line in logs do
		if line.level == level and string.find(line.message, text, 1, true) then
			found += 1
		end
	end
	return found
end

-- Every string anywhere in a value, so a test can look for a value no matter where it is.
local function strings(value, into)
	into = into or {}
	if type(value) == "table" then
		for key, item in value do
			strings(key, into)
			strings(item, into)
		end
	elseif value ~= nil then
		table.insert(into, tostring(value))
	end
	return into
end

test("heartbeatBody carries integration data only", function()
	local body = Wire.heartbeatBody("alive", "2025-11-11T10:30:45.123Z", { memory_only = 1, stored_awaiting_delivery = 2, not_durable = 3 }, {
		environment = "test", universeId = "111", placeId = "222", serverJobId = "job-1", sdkVersion = "0.2.1",
	}, "job-1")
	local names = {}
	for name in body do
		table.insert(names, name)
	end
	table.sort(names)
	eq(table.concat(names, ","), "environment,kind,place_id,receipts,sdk_version,sent_at,server_job_id,universe_id")
	eq(body.kind, "alive")
	eq(body.sent_at, "2025-11-11T10:30:45.123Z")
	eq(body.receipts.memory_only, 1)
	eq(body.receipts.stored_awaiting_delivery, 2)
	eq(body.receipts.not_durable, 3)
	eq(Wire.HEARTBEATS_PATH, "/v1/roblox-sdk/heartbeats")
end)

test("started is sent once after start and alive exactly every hour after it", function()
	local f = Fakes.runtime()
	f.scheduler.run(10)
	eq(#signals(f), 0, "nothing before start")
	assert(f.client:start({ environment = "production" }))
	f.scheduler.run(10 + 3 * HOUR + 1)
	local sent = signals(f)
	eq(kinds(sent), "started,alive,alive,alive")
	eq(times(sent), table.concat({ 10, 10 + HOUR, 10 + 2 * HOUR, 10 + 3 * HOUR }, ","), "hourly from start, no drift")
	local first = sent[1].body
	eq(first.environment, "production")
	eq(first.universe_id, "111")
	eq(first.place_id, "222")
	eq(first.server_job_id, "job-1")
	eq(first.sdk_version, "0.1.0-test")
	eq(first.sent_at, Wire.isoUtcFromMillis(Fakes.BASE_MILLIS + 10 * 1000), "sent_at from the Unix clock")
	eq(sent[2].body.sent_at, Wire.isoUtcFromMillis(Fakes.BASE_MILLIS + (10 + HOUR) * 1000))
	eq(sent[1].headers.Authorization, "Bearer <secret>", "the same token as the receipts")
	local diagnostics = f.client:getDiagnostics()
	eq(diagnostics.heartbeat.lastKind, "alive")
	eq(diagnostics.heartbeat.lastSentAtUtc, sent[4].body.sent_at)
	eq(diagnostics.heartbeat.lastResult, "recorded")
end)

test("a failed signal is not retried and the next one follows on schedule", function()
	local f = Fakes.runtime({
		server = function(url)
			if string.sub(url, -#Wire.HEARTBEATS_PATH) == Wire.HEARTBEATS_PATH then
				return { status = 503 }
			end
			return { status = 200, body = { outcome = "recorded" } }
		end,
	})
	assert(f.client:start({ environment = "production" }))
	f.scheduler.run(2 * HOUR + 1)
	eq(times(signals(f)), table.concat({ 0, HOUR, 2 * HOUR }, ","), "one attempt per signal")
	eq(f.client:getDiagnostics().heartbeat.lastResult, "transport_failed")
	eq(count(f.logs, "warn", "server signal"), 0, "a failed signal is an info line")
	eq(count(f.logs, "info", "server signal alive failed"), 2)
end)

test("a refused signal warns once per server", function()
	local f = Fakes.runtime({ server = failing(401) })
	assert(f.client:start({ environment = "production" }))
	f.scheduler.run(2 * HOUR + 1)
	eq(#signals(f), 3, "still one signal per hour")
	eq(count(f.logs, "warn", "R3FTO refused the server signal (HTTP 401 X)"), 1)
	eq(f.client:getDiagnostics().heartbeat.lastResult, "rejected")
end)

test("signals carry this server's receipt counts by durability and no PlayerId", function()
	local longId = function(n)
		return "long-purchase-id-that-no-datastore-key-can-hold-000000000" .. n -- over 50 characters: no DataStore copy
	end
	local f = Fakes.runtime({
		server = function(url, body)
			if string.sub(url, -#Wire.RECEIPTS_PATH) ~= Wire.RECEIPTS_PATH then
				return { status = 200, body = { outcome = "recorded" } }
			end
			local id = body.receipt.purchase_id
			if id == "a1b2c3d4-0000-4000-8000-000000000001" then
				return { status = 401, body = { error = { code = "X" } } } -- refused: the DataStore copy remains
			elseif id == "a1b2c3d4-0000-4000-8000-000000000002" then
				return { status = 200, body = { outcome = "recorded" } } -- delivered: not counted
			end
			return { status = 500 } -- the long ids: no copy and no delivery
		end,
	})
	assert(f.client:start({ environment = "production" }))
	f.client:observeReceipt(Fakes.receipt())
	f.client:observeReceipt(Fakes.receipt({ PurchaseId = "a1b2c3d4-0000-4000-8000-000000000002" }))
	f.client:observeReceipt(Fakes.receipt({ PurchaseId = longId(3) }))
	f.scheduler.run(HOUR - 100)
	f.client:observeReceipt(Fakes.receipt({ PurchaseId = longId(4) })) -- still has attempts left at the hour
	f.scheduler.run(HOUR + 1)
	local alive = signals(f)[2]
	eq(alive.body.kind, "alive")
	eq(alive.body.receipts.memory_only, 1, "attempts remain")
	eq(alive.body.receipts.stored_awaiting_delivery, 1, "copy kept, delivery refused")
	eq(alive.body.receipts.not_durable, 1, "every attempt ended without a copy")
	for _, request in signals(f) do
		eq(request.body.player_id, nil, "no player_id member")
		for _, text in strings(request.body) do
			assert(not string.find(text, "1234567", 1, true), "a PlayerId in a signal")
		end
	end
end)

test("a signal is never an Engine job and never counts as a receipt or a referral", function()
	local f = Fakes.runtime()
	assert(f.client:start({ environment = "production" }))
	f.scheduler.run(2 * HOUR + 1)
	eq(#signals(f), 3)
	eq(next(f.client._engine:jobs()), nil, "no Engine job")
	local diagnostics = f.client:getDiagnostics()
	eq(diagnostics.referralObservations, 0)
	eq(diagnostics.receipts.delivered + diagnostics.receipts.memory_only + diagnostics.receipts.not_durable + diagnostics.receipts.stored_awaiting_delivery, 0)
end)

test("the receipt handler never waits for a signal", function()
	local f = Fakes.runtime()
	f.http.latency = 20
	assert(f.client:start({ environment = "production" }))
	f.scheduler.run(1)
	eq(#signals(f), 1, "started is in flight")
	eq(f.client:getDiagnostics().heartbeat.lastResult, "sending")
	-- A publisher handler called outside any scheduled coroutine: a yield here would error.
	local function processReceipt(receiptInfo)
		f.client:observeReceipt(receiptInfo)
		return "PurchaseGranted"
	end
	eq(processReceipt(Fakes.receipt()), "PurchaseGranted")
	f.scheduler.run(2)
	local delivery = Fakes.requestsTo(f.http, Wire.RECEIPTS_PATH)
	eq(#delivery, 1)
	eq(delivery[1].at, 1, "the receipt went out while the signal was still waiting")
	eq(f.client:getDiagnostics().heartbeat.lastResult, "sending")
end)

test("closing is sent on close and signals stop after it", function()
	local f = Fakes.runtime()
	assert(f.client:start({ environment = "production" }))
	f.scheduler.run(100)
	local waited = f.close()
	assert(waited < Client.CLOSING_WAIT_LIMIT, "a fast closing signal ends the wait at once")
	eq(kinds(signals(f)), "started,closing")
	eq(signals(f)[2].at, 100)
	f.scheduler.run(5 * HOUR)
	eq(kinds(signals(f)), "started,closing", "no alive after close")
	f.close()
	eq(#signals(f), 2, "closing is sent once")
end)

test("shutdown waits for the closing signal at most the wait limit, well under 30 seconds", function()
	local f = Fakes.runtime()
	assert(f.client:start({ environment = "production" }))
	f.scheduler.run(100)
	f.http.latency = 60 -- R3FTO does not answer in time
	local waited = f.close()
	assert(Client.CLOSING_WAIT_LIMIT <= 10, "the limit stays well under Roblox's 30 seconds")
	eq(waited, Client.CLOSING_WAIT_LIMIT)
	eq(kinds(signals(f)), "started,closing", "one attempt, not retried")
	eq(f.client:getDiagnostics().heartbeat.lastResult, "sending")
end)

test("a closing signal with no answer is not retried and no receipt work is added", function()
	local f = Fakes.runtime({ server = failing(500) })
	assert(f.client:start({ environment = "production" }))
	f.client:observeReceipt(Fakes.receipt())
	f.scheduler.run(30)
	f.close()
	f.scheduler.run()
	eq(kinds(signals(f)), "started,closing")
	eq(times(Fakes.requestsTo(f.http, Wire.RECEIPTS_PATH)), "0,60,180,300", "the receipt keeps its own schedule")
end)

test("Studio (empty JobId) signals with one studio-<GUID> id per session; receipts are unchanged", function()
	local f = Fakes.runtime({ jobId = "" })
	assert(f.client:start({ environment = "test" }))
	f.client:observeReceipt(Fakes.receipt())
	f.scheduler.run(HOUR + 1)
	local sent = signals(f)
	eq(#sent, 2)
	eq(sent[1].body.server_job_id, "studio-00000000-0000-0000-0000-000000000001")
	eq(sent[2].body.server_job_id, sent[1].body.server_job_id, "the same id for the whole session")
	eq(Fakes.requestsTo(f.http, Wire.RECEIPTS_PATH)[1].body.server_job_id, "", "the receipt wire is unchanged")
end)

test("signal logs never contain the token, a PlayerId or the server job id", function()
	local f = Fakes.runtime({ server = failing(503) })
	assert(f.client:start({ environment = "production" }))
	f.client:observeReceipt(Fakes.receipt())
	f.scheduler.run(HOUR + 1)
	f.close()
	for _, line in f.logs do
		assert(not string.find(line.message, "job-1", 1, true), "a job id in a log line")
		assert(not string.find(line.message, "<secret>", 1, true), "the token in a log line")
		assert(not string.find(line.message, "1234567", 1, true), "a PlayerId in a log line")
	end
end)

-- The SDK token secret ------------------------------------------------------------------------------------------------

local Adapters = Fakes.Adapters
local SECRET = Client.DEFAULT_TOKEN_SECRET
local NOT_CONFIGURED_WARNING = "server signals are not sent: the SDK token secret is not available (see the warning at start). Receipts keep only their DataStore copy until the secret is added"

test("secretAuthorization answers the header value, or Roblox's own error without a script position, capped", function()
	local http = Fakes.httpService(Fakes.scheduler(), Fakes.okServer())
	local value, why = Adapters.secretAuthorization(http, SECRET)
	eq(value, nil, "missing secret")
	eq(why, "Can't find secret with given key", "Roblox's message as raised")

	http.secretError = "Workspace.Script:12: Can't find secret with given key"
	eq(select(2, Adapters.secretAuthorization(http, SECRET)), "Can't find secret with given key", "position stripped")

	http.secretError = "HTTP 403: Forbidden"
	eq(select(2, Adapters.secretAuthorization(http, SECRET)), "HTTP 403: Forbidden", "not a script position: kept")

	http.secretError = string.rep("x", 300)
	eq(select(2, Adapters.secretAuthorization(http, SECRET)), string.rep("x", Adapters.MAX_SECRET_ERROR), "capped")
	eq(Adapters.MAX_SECRET_ERROR, 200)

	http.secretError = "ServerScriptService.R3FTOStart:7: " .. string.rep("y", 250)
	eq(select(2, Adapters.secretAuthorization(http, SECRET)), string.rep("y", 200), "stripped, then capped")

	http.secrets[SECRET] = "tok-7Qx"
	local found, none = Adapters.secretAuthorization(http, SECRET)
	eq(found, "Bearer tok-7Qx", "the header value")
	eq(none, nil, "no reason on success")
end)

test("a missing secret puts Roblox's own message into the start problem", function()
	local f = Fakes.runtime({ secretMissing = true, secretError = "Workspace.Script:12: Can't find secret with given key" })
	eq((f.client:start({ environment = "test" })), true, "start still succeeds")
	local expected = "the secret R3FTO_SDK_TOKEN is not available (Roblox: Can't find secret with given key). Add it in Creator Hub Secrets, or as a Studio Local Secret for local tests; direct delivery to R3FTO fails until then"
	local problems = f.client:getDiagnostics().problems
	eq(#problems, 1)
	eq(problems[1], expected)
	eq(count(f.logs, "warn", expected), 1, "printed once at start")
end)

test("httpPoster without the secret answers not_configured, not retryable, and sends nothing", function()
	local http = Fakes.httpService(Fakes.scheduler(), Fakes.okServer())
	local post = Adapters.httpPoster(http, "https://r3f.to", nil, Wire)
	local outcome = post(Wire.RECEIPTS_PATH, { any = "body" })
	eq(outcome.ok, false)
	eq(outcome.kind, "not_configured")
	eq(outcome.retryable, false)
	eq(outcome.detail, "the SDK token secret is not available")
	eq(#http.requests, 0, "nothing left the server")
end)

test("without the secret a receipt's delivery ends rejected (not_configured) and its DataStore copy is unaffected", function()
	local f = Fakes.runtime({ secretMissing = true })
	assert(f.client:start({ environment = "production" }))
	local answer = f.client:observeReceipt(Fakes.receipt())
	eq(answer.accepted, true)
	f.scheduler.run()
	local status = assert(f.client:getReceiptStatus(answer.purchaseId))
	eq(status.channels.delivery.state, "rejected")
	eq(status.channels.delivery.attempts, 1, "not retried")
	eq(status.channels.delivery.lastError, "not_configured")
	eq(status.channels.storage.state, "succeeded")
	eq(status.channels.storage.attempts, 1)
	eq(status.durability, "stored_awaiting_delivery")
	assert(f.dataStores.stores[Wire.DATASTORE_NAME .. "/production"][answer.purchaseId], "the DataStore copy exists")
	eq(#f.http.requests, 0, "nothing was sent")
end)

test("without the secret the server signal warns once with its own text and never blames R3FTO", function()
	local f = Fakes.runtime({ secretMissing = true })
	assert(f.client:start({ environment = "production" }))
	f.scheduler.run(2 * HOUR + 1)
	eq(#signals(f), 0, "no signal left the server")
	eq(count(f.logs, "warn", NOT_CONFIGURED_WARNING), 1, "warned once")
	eq(count(f.logs, "warn", "R3FTO refused"), 0, "no refusal warning")
	eq(count(f.logs, "info", "R3FTO refused"), 0, "no refusal line")
	eq(count(f.logs, "info", "server signal alive failed (not_configured"), 2, "later signals are info lines")
	eq(f.client:getDiagnostics().heartbeat.lastResult, "not_configured")
end)

test("the secret's value never reaches the logs, the problems or the diagnostics", function()
	local sentinel = "tok-7Qx"
	for _, server in { Fakes.okServer(), failing(401), failing(503) } do
		local f = Fakes.runtime({ server = server, secretValue = sentinel, httpEnabled = false, universeId = 0 })
		assert(f.client:start({ environment = "test" }))
		local answer = f.client:observeReceipt(Fakes.receipt())
		f.join(1234567, "rt_abcdefghijklmnopqrstuvwxyz")
		f.scheduler.run(HOUR + 1)
		f.close()
		eq(Fakes.requestsTo(f.http, Wire.RECEIPTS_PATH)[1].headers.Authorization, "Bearer " .. sentinel, "the secret was used")
		for _, line in f.logs do
			assert(not string.find(line.message, sentinel, 1, true), "the secret in a log line")
		end
		local diagnostics = f.client:getDiagnostics()
		eq(#diagnostics.problems, 2, "the setup problems are listed")
		for _, text in strings(diagnostics) do
			assert(not string.find(text, sentinel, 1, true), "the secret in the diagnostics")
		end
		for _, text in strings(f.client:getReceiptStatus(answer.purchaseId)) do
			assert(not string.find(text, sentinel, 1, true), "the secret in the receipt status")
		end
	end
end)

-- Player arrivals (creator link values) ----------------------------------------------------------------------------

local KAEL = "r3f_KAEL"
local NOVA = "r3f_NOVA"

-- An R3FTO that answers every arrival with `answer(launch_reference)` ({ status, body }) and every other request with
-- `recorded`.
local function arrivalServer(answer)
	return function(url, body)
		if string.sub(url, -#Wire.REFERRALS_PATH) == Wire.REFERRALS_PATH then
			return answer(body.launch_reference)
		end
		return { status = 200, body = { outcome = "recorded", receipt_id = "r-1", matches_first_record = true } }
	end
end

local function launchReferences(requests)
	local list = {}
	for _, request in requests do
		table.insert(list, request.body.launch_reference)
	end
	return table.concat(list, ",")
end

test("arrivals A, then B, then A again on one server are three reports", function()
	local f = Fakes.runtime()
	assert(f.client:start({ environment = "production" }))
	local first = f.join(1234567, "r3f_kael") -- sent in upper case
	f.scheduler.run(10)
	f.leave(first)
	local second = f.join(1234567, NOVA)
	f.scheduler.run(20)
	f.leave(second)
	f.join(1234567, KAEL)
	f.scheduler.run(30)
	local sent = Fakes.requestsTo(f.http, Wire.REFERRALS_PATH)
	eq(launchReferences(sent), "r3f_KAEL,r3f_NOVA,r3f_KAEL", "one report per join, in order")
	eq(times(sent), "0,10,20")
	eq(sent[1].body.observed_at, Wire.isoUtcFromMillis(Fakes.BASE_MILLIS), "the join time")
	eq(sent[3].body.observed_at, Wire.isoUtcFromMillis(Fakes.BASE_MILLIS + 20 * 1000))
	eq(f.client:getDiagnostics().referralObservations, 3)
end)

test("a rejoin with the same value is a new report", function()
	local f = Fakes.runtime()
	assert(f.client:start({ environment = "test" }))
	local first = f.join(1234567, "r3f_TSTA")
	f.scheduler.run(5)
	f.leave(first)
	f.scheduler.run(65)
	f.join(1234567, "r3f_TSTA")
	f.scheduler.run(70)
	local sent = Fakes.requestsTo(f.http, Wire.REFERRALS_PATH)
	eq(#sent, 2, "the rejoin is reported")
	eq(sent[2].body.launch_reference, "r3f_TSTA")
	eq(sent[2].body.environment, "test")
	eq(times(sent), "0,65")
end)

test("one join seen by PlayerAdded and by the GetPlayers loop is one report", function()
	local f = Fakes.runtime()
	assert(f.client:start({ environment = "production" }))
	local join = f.join(1234567, KAEL)
	f.join(1234567, KAEL, join) -- the same join observed again (the overlap at start)
	f.scheduler.run(10)
	f.join(1234567, KAEL, join) -- and again later, while the player is still in the server
	f.scheduler.run(20)
	eq(#Fakes.requestsTo(f.http, Wire.REFERRALS_PATH), 1)
	eq(f.client:getDiagnostics().referralObservations, 1)
	-- After the player leaves, the next join of the same player is a new report.
	f.leave(join)
	f.join(1234567, KAEL)
	f.scheduler.run(30)
	eq(#Fakes.requestsTo(f.http, Wire.REFERRALS_PATH), 2)
end)

test("an arrival is retried at 0, 60, 180, 300, 600, 900, 1800 and 3600 seconds; a receipt keeps four attempts", function()
	local f = Fakes.runtime({ server = failing(503) })
	assert(f.client:start({ environment = "production" }))
	f.join(1234567, KAEL)
	f.client:observeReceipt(Fakes.receipt())
	f.scheduler.run(HOUR + 600)
	local arrivals = Fakes.requestsTo(f.http, Wire.REFERRALS_PATH)
	eq(times(arrivals), "0,60,180,300,600,900,1800,3600", "eight attempts within an hour")
	eq(times(Fakes.requestsTo(f.http, Wire.RECEIPTS_PATH)), "0,60,180,300", "receipts keep their schedule")
	for _, request in arrivals do
		eq(request.body.observed_at, arrivals[1].body.observed_at, "every attempt repeats the same body")
		eq(request.body.launch_reference, KAEL)
	end
	local job = assert(f.client._engine:get("referral:1"))
	eq(job.byName.delivery.state, "failed")
	eq(job.byName.delivery.attempts, 8)
	eq(f.client:getDiagnostics().referralOutcomes.failed, 1)
end)

test("Retry-After skips slots in the arrival schedule and never adds one", function()
	local f = Fakes.runtime({ server = arrivalServer(function()
		return { status = 429, headers = { ["Retry-After"] = "700" }, body = { error = { code = "X", message = "x" } } }
	end) })
	assert(f.client:start({ environment = "production" }))
	f.join(1234567, KAEL)
	f.scheduler.run(HOUR + 600)
	eq(times(Fakes.requestsTo(f.http, Wire.REFERRALS_PATH)), "0,900,1800,3600", "the 60, 180, 300 and 600 s slots are skipped")
	local delivery = assert(f.client._engine:get("referral:1")).byName.delivery
	eq(delivery.skippedSlots, 4)
	eq(delivery.attempts, 4)
	eq(delivery.state, "failed")
	eq(delivery.lastError, "throttled")
end)

test("an arrival that R3FTO answers stops; a refused one is not retried", function()
	local calls = 0
	local f = Fakes.runtime({ server = arrivalServer(function(reference)
		if reference == NOVA then
			return { status = 400, body = { error = { code = "VALIDATION_ERROR", message = "x" } } }
		end
		calls += 1
		if calls < 3 then
			return { status = 500 }
		end
		return { status = 200, body = { outcome = "recorded" } }
	end) })
	assert(f.client:start({ environment = "production" }))
	f.join(1234567, KAEL)
	f.join(7654321, NOVA)
	f.scheduler.run(HOUR + 600)
	local sent = Fakes.requestsTo(f.http, Wire.REFERRALS_PATH)
	local kael, nova = {}, {}
	for _, request in sent do
		table.insert(if request.body.launch_reference == KAEL then kael else nova, request)
	end
	eq(times(kael), "0,60,180", "stopped after the answer")
	eq(times(nova), "0", "a refused report is not retried")
	local outcomes = f.client:getDiagnostics().referralOutcomes
	eq(outcomes.recorded, 1)
	eq(outcomes.failed, 1, "rejected counts as failed")
end)

test("an unrecognized value warns once per server, then logs info lines", function()
	local f = Fakes.runtime({ server = arrivalServer(function()
		return { status = 200, body = { outcome = "unrecognized_reference" } }
	end) })
	assert(f.client:start({ environment = "test" }))
	f.join(1234567, KAEL)
	f.join(7654321, NOVA)
	f.join(5555555, "r3f_TSTB")
	f.scheduler.run(10)
	eq(count(f.logs, "warn", "[R3FTO] " .. Client.UNRECOGNIZED_WARNING), 1, "one warning")
	eq(
		Client.UNRECOGNIZED_WARNING,
		"a creator link value was not recognized. Test mode accepts only the Test keys TSTA, TSTB and TSTC; Production accepts real creator keys."
	)
	eq(count(f.logs, "info", "a creator link value was not recognized"), 2, "later ones are info lines")
	eq(#Fakes.requestsTo(f.http, Wire.REFERRALS_PATH), 3, "an answer is not retried")
	eq(f.client:getDiagnostics().referralOutcomes.unrecognized_reference, 3)
end)

test("diagnostics count arrival outcomes and contain no key and no UserId", function()
	local f = Fakes.runtime({ server = arrivalServer(function(reference)
		if reference == "r3f_KAEL" then
			return { status = 200, body = { outcome = "recorded" } }
		elseif reference == "r3f_NOVA" then
			return { status = 200, body = { outcome = "already_recorded" } }
		elseif reference == "r3f_GONE" then
			return { status = 200, body = { outcome = "unrecognized_reference" } }
		elseif reference == "r3f_DOWN" then
			return { status = 503 }
		end
		return { status = 403, body = { error = { code = "ENVIRONMENT_MISMATCH", message = "x" } } }
	end) })
	assert(f.client:start({ environment = "production" }))
	f.join(1111111, "r3f_KAEL")
	f.join(2222222, "r3f_NOVA")
	f.join(3333333, "r3f_GONE")
	f.join(4444444, "r3f_DOWN")
	f.join(5555555, "r3f_SHUT")
	f.join(6666666, nil) -- no value: not an arrival
	f.scheduler.run(100)
	local early = f.client:getDiagnostics()
	eq(early.referralOutcomes.failed, 1, "the refused one; the one still retrying is in none")
	f.scheduler.run(HOUR + 600)
	local diagnostics = f.client:getDiagnostics()
	eq(diagnostics.referralObservations, 5)
	eq(diagnostics.referralOutcomes.recorded, 1)
	eq(diagnostics.referralOutcomes.already_recorded, 1)
	eq(diagnostics.referralOutcomes.unrecognized_reference, 1)
	eq(diagnostics.referralOutcomes.failed, 2)
	for _, text in strings(diagnostics) do
		for _, secret in { "KAEL", "NOVA", "GONE", "DOWN", "SHUT", "1111111", "2222222", "3333333", "4444444", "5555555" } do
			assert(not string.find(text, secret, 1, true), "a key or a UserId in the diagnostics")
		end
	end
	for _, line in f.logs do
		for _, secret in { "KAEL", "NOVA", "GONE", "DOWN", "SHUT", "1111111", "5555555" } do
			assert(not string.find(line.message, secret, 1, true), "a key or a UserId in a log line")
		end
	end
end)

-- Key panel -------------------------------------------------------------------------------------------------------------

local Look = Fakes.Look

local function selections(f)
	return Fakes.requestsTo(f.http, Wire.SELECTIONS_PATH)
end

-- An R3FTO that answers every key panel request with `answer(creator_key)` ({ status, headers?, body? }) and every other
-- request like Fakes.okServer.
local function selectionServer(answer)
	local others = Fakes.okServer()
	return function(url, body, headers, time)
		if string.sub(url, -#Wire.SELECTIONS_PATH) == Wire.SELECTIONS_PATH then
			return answer(body.creator_key)
		end
		return others(url, body, headers, time)
	end
end

-- A started SDK over the fakes.
local function started(options)
	local f = Fakes.runtime(options)
	assert(f.client:start({ environment = "production" }))
	return f
end

-- A player in the server with the key panel open.
local function panelFor(f, userId)
	local player = f.player(userId)
	local ok, reason = f.client:openKeyPanel(player)
	assert(ok, reason)
	return player
end

local function warnings(logs)
	local found = 0
	for _, line in logs do
		if line.level == "warn" then
			found += 1
		end
	end
	return found
end

test("a panel key is 4 to 16 letters A-Z after trimming and upper-casing; anything else never reaches R3FTO", function()
	eq(Wire.panelKey("kael"), "KAEL", "lower case")
	eq(Wire.panelKey("  Kael "), "KAEL", "spaces around it")
	eq(Wire.panelKey(string.rep("K", 16)), string.rep("K", 16), "16 letters")
	eq(Wire.panelKey("KAE"), nil, "3 letters")
	eq(Wire.panelKey(string.rep("K", 17)), nil, "17 letters")
	eq(Wire.panelKey("KA3L"), nil, "a digit")
	eq(Wire.panelKey("KA EL"), nil, "a space inside")
	eq(Wire.panelKey("KA-EL"), nil, "a hyphen")
	eq(Wire.panelKey("KÄEL"), nil, "a non-ASCII letter")
	eq(Wire.panelKey(string.rep(" ", 61) .. "KAEL"), nil, "more than 64 bytes")
	eq(Wire.panelKey(1234), nil, "a number")
	eq(Wire.panelKey(nil), nil, "nothing")

	local f = started()
	local player = panelFor(f, 1234567)
	for _, key in { "KAE", "KA3L", string.rep("K", 17), "", 42, { "KAEL" }, string.rep("A", 65), false } do
		eq(f.panelRequest(player, "use", key), "unknown_key", "a key the panel itself never sends")
	end
	eq(f.panelRequest(player, "use"), "unknown_key", "no key")
	eq(#selections(f), 0, "nothing reached R3FTO")
	eq(f.panelRequest(player, "use", " kael "), "accepted")
	eq(selections(f)[1].body.creator_key, "KAEL", "sent in upper case")
end)

test("a key panel request carries the server-seen UserId and the key, the action set and no time", function()
	local f = started()
	local player = panelFor(f, 1234567)
	eq(f.panelRequest(player, "use", "KAEL"), "accepted")
	local sent = selections(f)
	eq(#sent, 1)
	local body = sent[1].body
	local names = {}
	for name in body do
		table.insert(names, name)
	end
	table.sort(names)
	eq(table.concat(names, ","), "action,creator_key,environment,place_id,roblox_user_id,sdk_version,server_job_id,universe_id")
	eq(body.action, "set")
	eq(body.roblox_user_id, "1234567", "the UserId the server sees")
	eq(body.creator_key, "KAEL")
	eq(body.environment, "production")
	eq(body.universe_id, "111")
	eq(body.place_id, "222")
	eq(body.server_job_id, "job-1")
	eq(body.sdk_version, "0.1.0-test")
	eq(sent[1].headers.Authorization, "Bearer <secret>", "the same token as every route")
end)

test("an action other than use, another player's device or a player who left sends nothing", function()
	local f = started()
	local player = panelFor(f, 1234567)
	for _, action in { "clear", "remove", "set", "USE", 5, false, {} } do
		eq(f.panelRequest(player, action, "KAEL"), "failed", "action " .. tostring(action))
	end
	eq(f.panelRequest(player, nil, "KAEL"), "failed", "no action")
	local other = f.player(7654321)
	eq(f.panelRequest(player, "use", "KAEL", other), "failed", "another player's device")
	player.Parent = nil
	eq(f.panelRequest(player, "use", "KAEL"), "failed", "the player left")
	eq(#selections(f), 0, "nothing reached R3FTO")
end)

test("a key panel request is one attempt, never an Engine job, never a receipt or an arrival", function()
	local f = started({ server = selectionServer(function()
		return { status = 503 }
	end) })
	local player = panelFor(f, 1234567)
	eq(f.panelRequest(player, "use", "KAEL"), "failed")
	f.scheduler.run(2 * HOUR)
	eq(#selections(f), 1, "never retried")
	eq(next(f.client._engine:jobs()), nil, "no Engine job")
	local diagnostics = f.client:getDiagnostics()
	eq(diagnostics.referralObservations, 0)
	eq(diagnostics.receipts.delivered + diagnostics.receipts.memory_only + diagnostics.receipts.not_durable + diagnostics.receipts.stored_awaiting_delivery, 0)
end)

test("one key panel request at a time per player, released only when the call returns", function()
	local f = started()
	f.http.latency = 20
	local answers = {}
	local first = panelFor(f, 1234567)
	f.scheduler.spawn(function()
		answers.first = f.panelRequest(first, "use", "KAEL")
	end)
	f.scheduler.run(1)
	eq(#selections(f), 1, "the first request is in flight")
	eq(answers.first, nil)

	eq(f.panelRequest(first, "use", "NOVA"), "busy", "a second press")
	assert(f.client:openKeyPanel(first))
	eq(f.panelRequest(first, "use", "NOVA"), "busy", "a reopened panel")
	local rejoined = panelFor(f, 1234567)
	eq(f.panelRequest(rejoined, "use", "NOVA"), "busy", "the same player rejoined this server")
	eq(#selections(f), 1, "busy sends nothing")

	local other = panelFor(f, 7654321)
	f.scheduler.spawn(function()
		answers.other = f.panelRequest(other, "use", "NOVA")
	end)
	f.scheduler.run(2)
	eq(#selections(f), 2, "another player is not held up")

	f.scheduler.run(19)
	eq(f.panelRequest(first, "use", "NOVA"), "busy", "no timer releases it")
	f.scheduler.run(21)
	eq(answers.first, "accepted")
	eq(answers.other, "accepted")
	f.scheduler.spawn(function()
		answers.again = f.panelRequest(first, "use", "NOVA")
	end)
	f.scheduler.run(45)
	eq(answers.again, "accepted", "released when the call returned")
	eq(#selections(f), 3)
	eq(f.client:getDiagnostics().keyPanelOutcomes.busy, 4)
	eq(count(f.logs, "info", "key panel: accepted"), 3, "one line per answer from R3FTO")
	eq(count(f.logs, "info", "key panel: try again later"), 0, "busy prints nothing")
end)

test("at most 60 key panel requests a minute per server; beyond it throttled, and receipts still go out", function()
	local f = started()
	local answers = {}
	for i = 1, Client.KEY_PANEL_PER_MINUTE + 1 do
		table.insert(answers, f.panelRequest(panelFor(f, 1000000 + i), "use", "KAEL"))
	end
	eq(Client.KEY_PANEL_PER_MINUTE, 60)
	eq(answers[60], "accepted")
	eq(answers[61], "throttled")
	eq(#selections(f), 60, "the 61st was not sent")
	f.client:observeReceipt(Fakes.receipt())
	f.scheduler.run(1)
	eq(#Fakes.requestsTo(f.http, Wire.RECEIPTS_PATH), 1, "the receipt still went out")
	f.scheduler.run(59)
	eq(f.panelRequest(panelFor(f, 2000001), "use", "KAEL"), "throttled", "still the same minute")
	f.scheduler.run(60)
	eq(f.panelRequest(panelFor(f, 2000002), "use", "KAEL"), "accepted", "a minute later")
	eq(#selections(f), 61)
	eq(f.client:getDiagnostics().keyPanelOutcomes.throttled, 2)
end)

test("a 200 accepted is ok for the key panel while a receipt still classifies it ambiguous", function()
	eq(Wire.classifyHttp(200, {}, { outcome = "accepted" }).kind, "ambiguous", "the default answers")
	eq(Wire.classifyHttp(200, {}, { outcome = "unknown_key" }).kind, "ambiguous")
	eq(Wire.classifyHttp(200, {}, { outcome = "unavailable" }).kind, "ambiguous")
	local panel = Wire.classifyHttp(200, {}, { outcome = "accepted" }, Wire.SELECTION_OUTCOMES)
	eq(panel.ok, true)
	eq(panel.facts.outcome, "accepted")
	eq(Wire.classifyHttp(200, {}, { outcome = "unknown_key" }, Wire.SELECTION_OUTCOMES).ok, true)
	eq(Wire.classifyHttp(200, {}, { outcome = "unavailable" }, Wire.SELECTION_OUTCOMES).ok, true)
	eq(Wire.classifyHttp(200, {}, { outcome = "recorded" }, Wire.SELECTION_OUTCOMES).kind, "ambiguous", "a receipt answer")
	eq(Wire.classifyHttp(200, {}, { outcome = "cleared" }, Wire.SELECTION_OUTCOMES).kind, "ambiguous", "no removal answer")
	eq(Wire.classifyHttp(200, {}, { outcome = "recorded" }).ok, true, "the default answers are unchanged")

	local f = started({ server = function()
		return { status = 200, body = { outcome = "accepted" } }
	end })
	local player = panelFor(f, 1234567)
	eq(f.panelRequest(player, "use", "KAEL"), "accepted")
	local answer = f.client:observeReceipt(Fakes.receipt())
	f.scheduler.run()
	local status = assert(f.client:getReceiptStatus(answer.purchaseId))
	eq(status.channels.delivery.lastError, "ambiguous", "the receipt was not taken as delivered")
	eq(#Fakes.requestsTo(f.http, Wire.RECEIPTS_PATH), 4, "and kept its retries")
end)

test("the key panel answers: R3FTO's three answers as they are, everything else failed", function()
	local cases = {
		{ { status = 200, body = { outcome = "accepted" } }, "accepted" },
		{ { status = 200, body = { outcome = "unknown_key" } }, "unknown_key" },
		{ { status = 200, body = { outcome = "unavailable" } }, "unavailable" },
		{ { status = 200, body = { outcome = "recorded" } }, "failed" },
		{ { status = 200, body = { outcome = "cleared" } }, "failed" },
		{ { status = 200 }, "failed" },
		{ { status = 400, body = { error = { code = "VALIDATION_ERROR", message = "x" } } }, "failed" },
		{ { status = 401, body = { error = { code = "AUTHENTICATION_REQUIRED", message = "x" } } }, "failed" },
		{ { status = 403, body = { error = { code = "ENVIRONMENT_MISMATCH", message = "x" } } }, "failed" },
		{ { status = 429, headers = { ["Retry-After"] = "30" }, body = { error = { code = "RATE_LIMITED", message = "x" } } }, "failed" },
		{ { status = 503, body = { error = { code = "SERVICE_UNAVAILABLE", message = "x" } } }, "failed" },
	}
	for index, case in cases do
		local f = started({ server = selectionServer(function()
			return case[1]
		end) })
		eq(f.panelRequest(panelFor(f, 1234567), "use", "KAEL"), case[2], "case " .. index)
		eq(#selections(f), 1, "one attempt, case " .. index)
	end

	local silent = started({ server = selectionServer(function()
		error("request timed out")
	end) })
	eq(silent.panelRequest(panelFor(silent, 1234567), "use", "KAEL"), "failed", "no answer")
	eq(#selections(silent), 1, "not retried")

	local unconfigured = Fakes.runtime({ secretMissing = true })
	assert(unconfigured.client:start({ environment = "production" }))
	eq(unconfigured.panelRequest(panelFor(unconfigured, 1234567), "use", "KAEL"), "failed", "no token secret")
	eq(#selections(unconfigured), 0, "nothing sent without the secret")
end)

test("openKeyPanel refusals; without the KeyPanelGui folder the SDK still runs its receipts", function()
	local f = Fakes.runtime()
	local player = f.player(1234567)
	local ok, reason = f.client:openKeyPanel(player)
	eq(ok, false)
	eq(reason, Client.KEY_PANEL_NOT_STARTED, "before start")
	assert(f.client:start({ environment = "production" }))
	for _, value in { 1234567, "player", { UserId = 1 }, false } do
		local opened, why = f.client:openKeyPanel(value)
		eq(opened, false)
		eq(why, Client.KEY_PANEL_NOT_A_PLAYER, "not a player: " .. tostring(value))
	end
	eq(select(2, f.client:openKeyPanel(nil)), Client.KEY_PANEL_NOT_A_PLAYER, "nil")
	local left = f.player(7654321)
	left.Parent = nil
	eq(select(2, f.client:openKeyPanel(left)), Client.KEY_PANEL_NOT_A_PLAYER, "a player who left")
	eq(f.panelOpens(), 0, "nothing opened")
	eq(f.client:openKeyPanel(player), true)
	eq(f.client:openKeyPanel(player), true, "a second call replaces the panel")
	eq(f.panelOpens(), 2)

	local bare = Fakes.runtime({ keyPanelFolder = false })
	assert(bare.client:start({ environment = "production" }))
	local opened, why = bare.client:openKeyPanel(bare.player(1234567))
	eq(opened, false)
	eq(why, Client.KEY_PANEL_FOLDER_MISSING)
	local answer = bare.client:observeReceipt(Fakes.receipt())
	bare.scheduler.run()
	eq(assert(bare.client:getReceiptStatus(answer.purchaseId)).durability, "delivered", "receipts run without the folder")

	local partial = Fakes.runtime({ keyPanelParts = false })
	assert(partial.client:start({ environment = "production" }))
	eq(select(2, partial.client:openKeyPanel(partial.player(1234567))), Client.KEY_PANEL_FOLDER_MISSING, "a folder without Look or Panel")

	local older = Fakes.runtime()
	older.runtime.keyPanelOpener = nil
	assert(older.client:start({ environment = "production" }))
	eq(select(2, older.client:openKeyPanel(older.player(1234567))), Client.KEY_PANEL_FOLDER_MISSING, "no opener at all")
end)

test("a refused key panel request and a missing secret each warn once per server", function()
	local f = started({ server = selectionServer(function()
		return { status = 403, body = { error = { code = "ENVIRONMENT_MISMATCH", message = "x" } } }
	end) })
	f.scheduler.run(1)
	local player = panelFor(f, 1234567)
	local before = warnings(f.logs)
	for _ = 1, 3 do
		eq(f.panelRequest(player, "use", "KAEL"), "failed")
	end
	eq(warnings(f.logs) - before, 1, "one warning for three refusals")
	eq(f.client:getDiagnostics().keyPanelOutcomes.failed, 3)

	local g = Fakes.runtime({ secretMissing = true })
	assert(g.client:start({ environment = "production" }))
	g.scheduler.run(1)
	local other = panelFor(g, 1234567)
	local start = warnings(g.logs)
	for _ = 1, 3 do
		eq(g.panelRequest(other, "use", "KAEL"), "failed")
	end
	eq(warnings(g.logs) - start, 1, "one warning without the secret")
	eq(#selections(g), 0)
end)

test("key panel diagnostics count the answers; no key and no UserId in the diagnostics or the logs", function()
	local f = started({ server = selectionServer(function(key)
		if key == "KAEL" then
			return { status = 200, body = { outcome = "accepted" } }
		elseif key == "NOVA" then
			return { status = 200, body = { outcome = "unknown_key" } }
		elseif key == "GONE" then
			return { status = 200, body = { outcome = "unavailable" } }
		end
		return { status = 503 }
	end) })
	eq(f.panelRequest(panelFor(f, 1111111), "use", "KAEL"), "accepted")
	eq(f.panelRequest(panelFor(f, 2222222), "use", "NOVA"), "unknown_key")
	eq(f.panelRequest(panelFor(f, 3333333), "use", "GONE"), "unavailable")
	eq(f.panelRequest(panelFor(f, 4444444), "use", "DOWN"), "failed")
	eq(f.panelRequest(panelFor(f, 5555555), "use", "SHUTX1"), "unknown_key")
	local diagnostics = f.client:getDiagnostics()
	local outcomes = diagnostics.keyPanelOutcomes
	eq(outcomes.accepted, 1)
	eq(outcomes.unknown_key, 2)
	eq(outcomes.unavailable, 1)
	eq(outcomes.failed, 1)
	eq(outcomes.busy, 0)
	eq(outcomes.throttled, 0)
	eq(outcomes.cleared, nil, "no removal answer")
	eq(count(f.logs, "info", "key panel:"), 4, "only the four answers from R3FTO print a line")
	eq(count(f.logs, "info", "key panel: unknown key"), 1, "the key refused on this server prints nothing")
	for _, text in strings(diagnostics) do
		for _, secret in { "KAEL", "NOVA", "GONE", "DOWN", "SHUTX1", "1111111", "2222222", "3333333", "4444444", "5555555" } do
			assert(not string.find(text, secret, 1, true), "a key or a UserId in the diagnostics")
		end
	end
	for _, line in f.logs do
		for _, secret in { "KAEL", "NOVA", "GONE", "DOWN", "SHUTX1", "1111111", "2222222", "3333333", "4444444", "5555555", "<secret>" } do
			assert(not string.find(line.message, secret, 1, true), "a key, a UserId or the token in a log line")
		end
	end

	local quiet = Fakes.runtime()
	assert(quiet.client:start({ environment = "production", quiet = true }))
	local lines = #quiet.logs
	eq(quiet.panelRequest(panelFor(quiet, 1234567), "use", "KAEL"), "accepted")
	eq(#quiet.logs, lines, "quiet hides the answer lines")
end)

test("a closing SDK answers failed and sends nothing", function()
	local f = started()
	local player = panelFor(f, 1234567)
	f.close()
	eq(f.panelRequest(player, "use", "KAEL"), "failed")
	eq(#selections(f), 0)
	eq(count(f.logs, "info", "key panel:"), 0, "a local answer prints nothing")
	eq(f.client:getDiagnostics().keyPanelOutcomes.failed, 1, "but it is counted")
end)

test("the panel keeps only the letters A-Z and maps every answer token to its state", function()
	eq(Look.normalize("kael"), "KAEL")
	eq(Look.normalize("k a-e_l1"), "KAEL", "only letters")
	eq(Look.normalize(string.rep("ab", 10)), string.rep("AB", 8), "at most 16")
	eq(Look.normalize("KÄEL"), "KEL", "a non-ASCII letter is dropped")
	eq(Look.normalize(nil), "")
	eq(Look.isKey("KAE"), false)
	eq(Look.isKey("KAEL"), true)
	eq(Look.isKey(string.rep("K", 16)), true)
	eq(Look.isKey(string.rep("K", 17)), false)
	eq(Look.isKey("kael"), false, "the box holds upper case only")
	eq(Look.isKey(""), false)

	local expected = {
		checking = "checking",
		accepted = "accepted",
		unknown_key = "notFound",
		unavailable = "notReady",
		busy = "tryLater",
		throttled = "tryLater",
		failed = "tryLater",
		timeout = "tryLater",
	}
	for token, state in expected do
		eq(Look.stateFor(token), state, token)
	end
	eq(Look.stateFor("cleared"), "tryLater", "there is no removed state")
	eq(Look.stateFor("Your key was removed by the server"), "tryLater", "text from elsewhere is never shown")
	eq(Look.stateFor(nil), "tryLater")
	eq(Look.stateFor({ outcome = "accepted" }), "tryLater")
	eq(Look.STATES.removed, nil)
	eq(Look.STATES.cleared, nil)

	local names = {}
	for name, state in Look.STATES do
		table.insert(names, name)
		assert(Look.COLOURS[state.colour] ~= nil, name .. " uses a design colour")
		eq(state.clearBox, name == "accepted", name .. " empties the box only when accepted")
	end
	table.sort(names)
	eq(table.concat(names, ","), "accepted,checking,notFound,notReady,ready,tryLater")
	eq(Look.TIMEOUT, 15)
	assert(#Look.LONGEST_STATUS > 0)
end)

-- Runner ---------------------------------------------------------------------------------------------------------------

local passed, failed = 0, 0
for _, case in tests do
	local ok, err = pcall(case.fn)
	if ok then
		passed += 1
		print("ok   " .. case.name)
	else
		failed += 1
		print("FAIL " .. case.name .. "\n     " .. tostring(err))
	end
end
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	error("tests failed")
end
