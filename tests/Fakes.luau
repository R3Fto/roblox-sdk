-- Fakes for the plain-Luau tests: a virtual-time scheduler, a DataStoreService, an HttpService and a runtime builder.
-- The SDK's own Engine, Wire, Client and RobloxAdapters run unchanged on top of them. Nothing here proves real Roblox
-- behaviour; it proves the SDK's logic (schedule, identity, failure independence) deterministically.

local Engine = require("../src/R3FTO/Engine")
local Wire = require("../src/R3FTO/Wire")
local Client = require("../src/R3FTO/Client")
local Adapters = require("../src/R3FTO/RobloxAdapters")

local Fakes = {}

Fakes.BASE_MILLIS = 1762857045123 -- 2025-11-11T10:30:45.123Z at virtual time 0

-- Virtual time. spawn() queues a coroutine at the current time; sleep() (only inside a queued coroutine) parks it.
function Fakes.scheduler()
	local s = { t = 0, queue = {}, seq = 0, sleeps = {} }
	function s.now()
		return s.t
	end
	function s.spawn(fn)
		s.seq += 1
		table.insert(s.queue, { at = s.t, seq = s.seq, co = coroutine.create(fn) })
	end
	function s.sleep(seconds)
		table.insert(s.sleeps, seconds)
		coroutine.yield(s.t + seconds)
	end
	-- Runs until nothing is queued, or until virtual time would pass `untilTime`.
	function s.run(untilTime)
		while #s.queue > 0 do
			table.sort(s.queue, function(a, b)
				if a.at == b.at then
					return a.seq < b.seq
				end
				return a.at < b.at
			end)
			local item = s.queue[1]
			if untilTime ~= nil and item.at > untilTime then
				s.t = untilTime
				return
			end
			table.remove(s.queue, 1)
			if item.at > s.t then
				s.t = item.at
			end
			local ok, wake = coroutine.resume(item.co)
			if not ok then
				error("scheduled coroutine failed: " .. tostring(wake))
			end
			if coroutine.status(item.co) ~= "dead" then
				s.seq += 1
				table.insert(s.queue, { at = wake, seq = s.seq, co = item.co })
			end
		end
		if untilTime ~= nil and untilTime > s.t then
			s.t = untilTime
		end
	end
	return s
end

-- A DataStoreService with one in-memory map per (name, scope).
--   failures: number of UpdateAsync calls that error before touching data
--   writeThenFail: number of calls that write and THEN error (a lost answer)
--   latency: virtual seconds each call takes
function Fakes.dataStoreService(scheduler)
	local service = { stores = {}, calls = 0, callTimes = {}, failures = 0, failAlways = false, writeThenFail = 0, latency = 0, budget = nil, userIds = {} }
	function service:GetDataStore(name, scope)
		local id = name .. "/" .. scope
		local data = service.stores[id]
		if data == nil then
			data = {}
			service.stores[id] = data
		end
		local store = {}
		function store:UpdateAsync(key, transform)
			service.calls += 1
			table.insert(service.callTimes, scheduler.t)
			if service.latency > 0 then
				scheduler.sleep(service.latency)
			end
			if service.failAlways or service.failures > 0 then
				service.failures = math.max(0, service.failures - 1)
				error("502: DataStore request failed")
			end
			local value, userIds = transform(data[key])
			if value ~= nil then
				data[key] = table.clone(value)
				service.userIds[key] = userIds
			end
			if service.writeThenFail > 0 then
				service.writeThenFail -= 1
				error("request timed out")
			end
			return value
		end
		return store
	end
	function service:GetRequestBudgetForRequestType(_)
		return service.budget or 100
	end
	return service
end

-- An HttpService whose JSON is a registry of tables (the fake never needs real JSON text) and whose network is the
-- `server(url, body, headers, time)` function a test supplies. The server returns { status, headers?, body? } or
-- errors (a timeout).
function Fakes.httpService(scheduler, server)
	local service = { registry = {}, n = 0, requests = {} }
	local function encode(value)
		service.n += 1
		local key = "json#" .. service.n
		service.registry[key] = value
		return key
	end
	function service:JSONEncode(value)
		return encode(value)
	end
	function service:JSONDecode(text)
		local value = service.registry[text]
		if value == nil then
			error("not JSON")
		end
		return value
	end
	function service:RequestAsync(request)
		local body = service.registry[request.Body]
		table.insert(service.requests, { url = request.Url, body = body, headers = request.Headers, at = scheduler.t })
		local answer = server(request.Url, body, request.Headers, scheduler.t)
		local status = answer.status
		return {
			Success = status >= 200 and status < 300,
			StatusCode = status,
			StatusMessage = "",
			Headers = answer.headers or {},
			Body = if answer.body ~= nil then encode(answer.body) else "",
		}
	end
	return service
end

-- A server that answers every request with `recorded`.
function Fakes.okServer()
	return function(url)
		if string.find(url, "referral", 1, true) then
			return { status = 200, body = { outcome = "recorded" } }
		end
		return { status = 200, body = { outcome = "recorded", receipt_id = "r-1", matches_first_record = true } }
	end
end

-- A full runtime over the fakes. options: server, universeId, placeId, secretMissing, httpEnabled.
function Fakes.runtime(options)
	options = options or {}
	local scheduler = Fakes.scheduler()
	local dataStores = Fakes.dataStoreService(scheduler)
	local http = Fakes.httpService(scheduler, options.server or Fakes.okServer())
	local logs = {}
	local players = {}
	local closers = {}
	local ids = 0
	local runtime = {
		Engine = Engine,
		Wire = Wire,
		sdkVersion = "0.1.0-test",
		isServer = function()
			return options.isServer ~= false
		end,
		now = scheduler.now,
		unixMillis = function()
			return Fakes.BASE_MILLIS + scheduler.t * 1000
		end,
		sleep = scheduler.sleep,
		spawn = scheduler.spawn,
		log = function(level, message)
			table.insert(logs, { level = level, message = message })
		end,
		httpEnabled = function()
			return options.httpEnabled ~= false
		end,
		authorization = function(_)
			if options.secretMissing then
				return nil, "missing"
			end
			return "Bearer <secret>", nil
		end,
		poster = function(baseUrl, authorization)
			return Adapters.httpPoster(http, baseUrl, authorization, Wire)
		end,
		dataStoreChannel = function(environment)
			return Adapters.dataStoreChannel(dataStores, environment, Wire)
		end,
		universeId = function()
			return options.universeId or 111
		end,
		placeId = function()
			return options.placeId or 222
		end,
		jobId = function()
			return "job-1"
		end,
		generateId = function()
			ids += 1
			return string.format("00000000-0000-0000-0000-%012d", ids)
		end,
		eachPlayer = function(callback)
			table.insert(players, callback)
		end,
		onClose = function(callback)
			table.insert(closers, callback)
		end,
	}
	local client = Client.new(runtime)
	return {
		client = client,
		runtime = runtime,
		scheduler = scheduler,
		dataStores = dataStores,
		http = http,
		logs = logs,
		join = function(userId, launchData)
			for _, callback in players do
				callback(userId, launchData)
			end
		end,
		close = function()
			for _, callback in closers do
				callback()
			end
		end,
	}
end

function Fakes.receipt(overrides)
	local receipt = {
		PurchaseId = "a1b2c3d4-0000-4000-8000-000000000001",
		PlayerId = 1234567,
		ProductId = 98765,
		CurrencySpent = 200,
		CurrencyType = "Robux",
		PlaceIdWherePurchased = 222,
	}
	for key, value in overrides or {} do
		receipt[key] = value
	end
	return receipt
end

-- Requests to one path, in order.
function Fakes.requestsTo(http, path)
	local found = {}
	for _, request in http.requests do
		if string.sub(request.url, -#path) == path then
			table.insert(found, request)
		end
	end
	return found
end

Fakes.Engine = Engine
Fakes.Wire = Wire
return Fakes
