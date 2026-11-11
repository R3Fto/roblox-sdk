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

-- The DataStore copy of a receipt (report K-44/K-45).
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

-- A POST to R3FTO with the bearer token. `authorization` is a Roblox Secret (HttpService:GetSecret(...):AddPrefix(
-- "Bearer ")): the plaintext is never readable by any script, and Roblox only lets it travel in a header or the URL.
function Adapters.httpPoster(httpService: any, baseUrl: string, authorization: any, Wire: any)
	return function(path: string, body: any): AttemptResult
		if authorization == nil then
			return { ok = false, kind = "rejected", retryable = false, detail = "the R3FTO SDK token secret is not available" }
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
		return Wire.classifyHttp(response.StatusCode, response.Headers, decoded)
	end
end

return table.freeze(Adapters)
