-- LocalScript · StarterPlayer/StarterPlayerScripts/BuyButton
-- A minimal purchase button. It holds no secret and no R3FTO code: purchases are reported only on the server.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

local DEVELOPER_PRODUCT_ID = 0 -- replace with your developer product id (Creator Hub > Monetization > Developer Products)

local player = Players.LocalPlayer
local gui = Instance.new("ScreenGui")
gui.Name = "ExampleShop"
gui.ResetOnSpawn = false

local button = Instance.new("TextButton")
button.Size = UDim2.fromOffset(220, 48)
button.Position = UDim2.new(0.5, -110, 1, -80)
button.Text = "Buy 100 coins"
button.Parent = gui

button.Activated:Connect(function()
	if DEVELOPER_PRODUCT_ID == 0 then
		warn("[Example] Set DEVELOPER_PRODUCT_ID in BuyButton first.")
		return
	end
	MarketplaceService:PromptProductPurchase(player, DEVELOPER_PRODUCT_ID)
end)

gui.Parent = player:WaitForChild("PlayerGui")
