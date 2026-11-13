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

test("LaunchData carries an R3FTO reference only when it is exactly a referral token", function()
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

test("a creator-link reference is reported once per player with the server-seen UserId", function()
	local f = Fakes.runtime()
	assert(f.client:start({ environment = "production" }))
	local token = "rt_abcdefghijklmnopqrstuvwxyz"
	f.join(1234567, token)
	f.join(1234567, token) -- same player, same reference (another join on this server)
	f.join(7654321, nil) -- no launch data
	f.join(5555555, '{"publisher":"data"}') -- the publisher's own launch data
	f.scheduler.run()
	local sent = Fakes.requestsTo(f.http, Wire.REFERRALS_PATH)
	eq(#sent, 1)
	eq(sent[1].body.roblox_user_id, "1234567")
	eq(sent[1].body.launch_reference, token)
	eq(sent[1].body.environment, "production")
	eq(sent[1].headers.Authorization, "Bearer <secret>")
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
