--!nonstrict
-- R3FTO Roblox SDK: the adapters over real Roblox services (server only).
--
-- Each adapter is small and replaceable: init.luau builds them from the real services, the tests use fakes with the same
-- shape. Nothing here prints a secret, a request body or a PlayerId.

-- `Wire` is passed in (not required here) so the plain-Luau tests can run these adapters over fake services.

local Adapters = {}

export type AttemptResult = {
	ok: boolean,
	record: any?,
	kind: string?,
	retryable: boolean?,
	retryAfter: number?,
	detail: string?,
	facts: { [string]: any }?,
}

-- The DataStore copy of a receipt: a durable record of it on Roblox's side that keeps the first observation time.
--
-- UpdateAsync with a transform that ONLY looks at the current value: when a schema-1 record for this PurchaseId already
-- exists (written by this server earlier, or by another server that saw the same receipt) the transform returns nil,
-- which cancels the write and keeps the existing record and its firstObservedAtUtc. Otherwise it returns the new
-- record, tagged with the buyer's UserId so Roblox's data-deletion tooling can find it. No network call and no other
-- side effect happens inside the transform (it may run more than once and must not yield).
function Adapters.dataStoreChannel(dataStoreService: any, environment: string, Wire: any)
	local store = nil
	local function storeFor()
		if store == nil then
			store = dataStoreService:GetDataStore(Wire.DATASTORE_NAME, environment)
		end
		return store
	end

	return function(record: any): AttemptResult
		local key = record.purchaseId
		if #key > Wire.MAX_DATASTORE_KEY then
			return { ok = false, kind = "rejected", retryable = false, detail = "PurchaseId is longer than a DataStore key" }
		end

		-- Respect the server's DataStore budget instead of queueing past it (Roblox throttle queues are 30 deep).
		local budgetOk, budget = pcall(function()
			return dataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync)
		end)
		if budgetOk and type(budget) == "number" and budget < 1 then
			return { ok = false, kind = "throttled", retryable = true, detail = "DataStore budget exhausted" }
		end

		local existing: any = nil
		local userId = tonumber(record.playerId)
		local ok, err = pcall(function()
			storeFor():UpdateAsync(key, function(current: any)
				if Wire.isRecord(current, key) then
					existing = current
					return nil
				end
				existing = nil
				return record, if userId then { userId } else nil
			end)
		end)
		if not ok then
			-- Includes an ambiguous failure after a write that did land: the next attempt sees that record and adopts it.
			return { ok = false, kind = "storage_failed", retryable = true, detail = tostring(err) }
		end

		if existing ~= nil then
			return { ok = true, record = existing, facts = { adoptedExistingRecord = true, existingDiffers = not Wire.samePurchase(existing, record) } }
		end
		return { ok = true, facts = { adoptedExistingRecord = false } }
	end
end

-- The longest part of Roblox's own error text kept when a secret cannot be read.
Adapters.MAX_SECRET_ERROR = 200

-- The bearer authorization header value from a Roblox Secret: HttpService:GetSecret(secretName):AddPrefix("Bearer ").
-- Answers (value, nil), or (nil, Roblox's own error text) when the secret cannot be read. The text is Roblox's lookup
-- error (for example "Can't find secret with given key") without a leading script position, at most MAX_SECRET_ERROR
-- characters long. It never holds the secret: a script cannot read a Secret's content.
function Adapters.secretAuthorization(httpService: any, secretName: string): (any?, string?)
	local ok, value = pcall(function()
		return httpService:GetSecret(secretName):AddPrefix("Bearer ")
	end)
	if ok then
		return value, nil
	end
	local message = string.gsub(tostring(value), "^[^:]+:%d+:%s*", "", 1)
	if #message > Adapters.MAX_SECRET_ERROR then
		message = string.sub(message, 1, Adapters.MAX_SECRET_ERROR)
	end
	return nil, message
end

-- A POST to R3FTO with the bearer token. `authorization` is a Roblox Secret (HttpService:GetSecret(...):AddPrefix(
-- "Bearer ")): the plaintext is never readable by any script, and Roblox only lets it travel in a header or the URL.
-- Without it nothing is sent: the request never leaves the server, so the answer is "not_configured", not a refusal.
-- `outcomes` is the set of answers this one request knows (Wire.classifyHttp); without it, the shared default set.
function Adapters.httpPoster(httpService: any, baseUrl: string, authorization: any, Wire: any)
	return function(path: string, body: any, outcomes: { [string]: boolean }?): AttemptResult
		if authorization == nil then
			return { ok = false, kind = "not_configured", retryable = false, detail = "the SDK token secret is not available" }
		end

		local encodedOk, encoded = pcall(function()
			return httpService:JSONEncode(body)
		end)
		if not encodedOk then
			return { ok = false, kind = "rejected", retryable = false, detail = "the request could not be encoded" }
		end

		local sent, response = pcall(function()
			return httpService:RequestAsync({
				Url = baseUrl .. path,
				Method = "POST",
				Headers = {
					["Content-Type"] = "application/json",
					["Authorization"] = authorization,
				},
				Body = encoded,
			})
		end)
		if not sent or type(response) ~= "table" then
			-- A timeout or a broken connection: R3FTO may or may not have committed it. The same identity is retried.
			return { ok = false, kind = "ambiguous", retryable = true, detail = "the request did not complete" }
		end

		local decoded = nil
		if type(response.Body) == "string" and #response.Body > 0 then
			local decodedOk, value = pcall(function()
				return httpService:JSONDecode(response.Body)
			end)
			if decodedOk then
				decoded = value
			end
		end
		return Wire.classifyHttp(response.StatusCode, response.Headers, decoded, outcomes)
	end
end

-- The name of the key panel's ScreenGui in a player's PlayerGui, and of its remote.
Adapters.KEY_PANEL_NAME = "R3FTOKeyPanel"
Adapters.KEY_PANEL_REQUEST = "Request"

-- The optional key panel, opened for one player at a time. `template` is the KeyPanelGui folder (the Look ModuleScript
-- and the Panel LocalScript); under ServerScriptService neither ever runs or reaches a device. `open(player)`:
-- * refuses unless the player is in this server and has a PlayerGui: (false, "player");
-- * refuses when the folder lacks Look or Panel: (false, "folder");
-- * destroys that player's open panel, so a second call replaces it;
-- * builds a new ScreenGui for that player alone (Roblox automatic translation off, so the fixed English words show
--   exactly) with a RemoteFunction "Request" whose server handler calls `onRequest(player, invoker, action, key)` inside
--   pcall and returns only an answer token, never text;
-- * clones Look and Panel into it and parents it to the player's PlayerGui last. Only then does Roblox copy it to that
--   player's device, where Panel draws the panel.
-- The server never calls the player's device (no InvokeClient): only the device asks, and the server answers.
function Adapters.keyPanelOpener(players: any, template: any, onRequest: (any, any, any, any) -> string)
	return function(player: any): (boolean, string?)
		if player == nil or player.Parent ~= players then
			return false, "player"
		end
		local playerGui = player:FindFirstChildOfClass("PlayerGui")
		if playerGui == nil then
			return false, "player"
		end
		local look = template:FindFirstChild("Look")
		local panel = template:FindFirstChild("Panel")
		if look == nil or panel == nil then
			return false, "folder"
		end

		local open = playerGui:FindFirstChild(Adapters.KEY_PANEL_NAME)
		while open ~= nil do
			open:Destroy()
			open = playerGui:FindFirstChild(Adapters.KEY_PANEL_NAME)
		end

		local gui = Instance.new("ScreenGui")
		gui.Name = Adapters.KEY_PANEL_NAME
		gui.ResetOnSpawn = false
		gui.DisplayOrder = 1000
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.AutoLocalize = false

		local request = Instance.new("RemoteFunction")
		request.Name = Adapters.KEY_PANEL_REQUEST
		request.OnServerInvoke = function(invoker: any, action: any, key: any): string
			local ok, answer = pcall(onRequest, player, invoker, action, key)
			if ok and type(answer) == "string" then
				return answer
			end
			return "failed"
		end
		request.Parent = gui

		look:Clone().Parent = gui
		panel:Clone().Parent = gui
		gui.Parent = playerGui
		return true, nil
	end
end

return table.freeze(Adapters)
