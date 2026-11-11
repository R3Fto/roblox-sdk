--!nonstrict
-- R3FTO Roblox SDK (server only). This file is the "R3FTO" ModuleScript; Engine, Wire, Client, RobloxAdapters and
-- Version are its child ModuleScripts. See sdk/roblox/README.md for the Studio layout.
--
-- Public API:
--   R3FTO.start(config) -> (ok, reason?)
--   R3FTO.observeReceipt(receiptInfo) -> { accepted, purchaseId, firstObservedAtUtc, duplicate, reason? }
--   R3FTO.simulateTestReceipt({ userId, productId, currencySpent }) -> same shape (R3FTO Test environment only)
--   R3FTO.getReceiptStatus(purchaseId) -> snapshot | nil
--   R3FTO.getDiagnostics() -> table (no token, no PlayerId)
--   R3FTO.VERSION
--
-- The SDK never sets MarketplaceService.ProcessReceipt and never calls BindReceiptHandler: your handler stays the only
-- one, grants the product and returns the purchase decision. It observes receipts; it does not grant or verify them.

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Engine = require(script.Engine)
local Wire = require(script.Wire)
local Client = require(script.Client)
local Adapters = require(script.RobloxAdapters)
local Version = require(script.Version)

local runtime = {
	Engine = Engine,
	Wire = Wire,
	sdkVersion = Version,
	isServer = function()
		return RunService:IsServer()
	end,
	now = os.clock,
	unixMillis = function()
		return DateTime.now().UnixTimestampMillis
	end,
	sleep = function(seconds: number)
		task.wait(seconds)
	end,
	-- task.defer: the work starts after the caller's code has returned, so observeReceipt itself never does I/O.
	spawn = function(fn: () -> ())
		task.defer(fn)
	end,
	log = function(level: string, message: string)
		if level == "warn" then
			warn(message)
		else
			print(message)
		end
	end,
	httpEnabled = function()
		local ok, enabled = pcall(function()
			return HttpService.HttpEnabled
		end)
		return ok and enabled == true
	end,
	authorization = function(secretName: string)
		local ok, value = pcall(function()
			return HttpService:GetSecret(secretName):AddPrefix("Bearer ")
		end)
		if ok then
			return value, nil
		end
		return nil, "not found: add it in Creator Hub Secrets, or as a Studio Local Secret for local tests"
	end,
	poster = function(baseUrl: string, authorization: any)
		return Adapters.httpPoster(HttpService, baseUrl, authorization, Wire)
	end,
	dataStoreChannel = function(environment: string)
		return Adapters.dataStoreChannel(DataStoreService, environment, Wire)
	end,
	universeId = function()
		return game.GameId
	end,
	placeId = function()
		return game.PlaceId
	end,
	jobId = function()
		return game.JobId
	end,
	generateId = function()
		return HttpService:GenerateGUID(false)
	end,
	eachPlayer = function(callback: (number, any) -> ())
		local function observe(player: Player)
			local ok, joinData = pcall(function()
				return player:GetJoinData()
			end)
			callback(player.UserId, if ok and type(joinData) == "table" then joinData.LaunchData else nil)
		end
		Players.PlayerAdded:Connect(observe)
		for _, player in Players:GetPlayers() do
			task.defer(observe, player)
		end
	end,
	onClose = function(callback: () -> ())
		game:BindToClose(callback)
	end,
}

local client = Client.new(runtime :: any)

local R3FTO = {
	VERSION = Version,
}

function R3FTO.start(config: any): (boolean, string?)
	return client:start(config)
end

function R3FTO.observeReceipt(receiptInfo: any): { [string]: any }
	return client:observeReceipt(receiptInfo)
end

function R3FTO.simulateTestReceipt(options: any): { [string]: any }
	return client:simulateTestReceipt(options)
end

function R3FTO.getReceiptStatus(purchaseId: string): { [string]: any }?
	return client:getReceiptStatus(purchaseId)
end

function R3FTO.getDiagnostics(): { [string]: any }
	return client:getDiagnostics()
end

return table.freeze(R3FTO)
