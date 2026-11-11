-- ModuleScript · ServerScriptService/ExampleGrants
-- THE EXAMPLE GAME'S OWN product delivery. This is not R3FTO code and R3FTO never calls it.
--
-- It follows Roblox's recommended pattern: grant the product and remember the PurchaseId in the same durable write,
-- return PurchaseGranted only after that write succeeded, and NotProcessedYet otherwise (Roblox asks again later).
-- Your game already has its own version of this. Keep yours.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")

local ExampleGrants = {}

ExampleGrants.COINS_PER_PURCHASE = 100

local purchases = DataStoreService:GetDataStore("ExampleGame_PlayerCoins")

local function coinsValue(player: Player): IntValue?
	local stats = player:FindFirstChild("leaderstats")
	return if stats then stats:FindFirstChild("Coins") :: IntValue? else nil
end

function ExampleGrants.setUpPlayer(player: Player)
	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"
	local coins = Instance.new("IntValue")
	coins.Name = "Coins"
	coins.Parent = stats
	stats.Parent = player

	local ok, saved = pcall(function()
		return purchases:GetAsync(tostring(player.UserId))
	end)
	if ok and type(saved) == "table" and type(saved.coins) == "number" then
		coins.Value = saved.coins
	end
end

-- Grants the coins once per PurchaseId. Returns the Roblox decision.
function ExampleGrants.grant(receiptInfo): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
	if player == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet -- Roblox asks again when the player is back
	end

	local newTotal = nil
	local ok = pcall(function()
		purchases:UpdateAsync(tostring(receiptInfo.PlayerId), function(saved)
			saved = if type(saved) == "table" then saved else { coins = 0, processed = {} }
			saved.processed = saved.processed or {}
			if saved.processed[receiptInfo.PurchaseId] then
				newTotal = saved.coins
				return nil -- already granted: keep the data as it is
			end
			saved.processed[receiptInfo.PurchaseId] = true
			saved.coins += ExampleGrants.COINS_PER_PURCHASE
			newTotal = saved.coins
			return saved
		end)
	end)
	if not ok then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local coins = coinsValue(player)
	if coins and newTotal then
		coins.Value = newTotal
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

return ExampleGrants
