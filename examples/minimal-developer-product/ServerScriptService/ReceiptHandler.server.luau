-- Script · ServerScriptService/ReceiptHandler
-- The example game's ONE receipt handler. R3FTO adds a single line to it and changes nothing else.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local R3FTO = require(ServerScriptService:WaitForChild("R3FTO"))
local ExampleGrants = require(ServerScriptService:WaitForChild("ExampleGrants"))

Players.PlayerAdded:Connect(ExampleGrants.setUpPlayer)
for _, player in Players:GetPlayers() do
	ExampleGrants.setUpPlayer(player)
end

MarketplaceService.ProcessReceipt = function(receiptInfo)
	-- R3FTO: report the receipt. Returns at once, never yields and never changes your decision below.
	pcall(R3FTO.observeReceipt, receiptInfo)

	-- Your own product delivery and your own decision, exactly as before.
	return ExampleGrants.grant(receiptInfo)
end
