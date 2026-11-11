-- Script · ServerScriptService/R3FTOTestDemos (optional; delete it before you publish to Production)
-- Runs SIMULATED receipts against the R3FTO Test environment so you can see the SDK work without a real purchase.
-- Simulated receipts are marked simulated end to end; R3FTO refuses them in Production. They prove nothing about real
-- Roblox purchases.

local ServerScriptService = game:GetService("ServerScriptService")

local R3FTO = require(ServerScriptService:WaitForChild("R3FTO"))

local RUN_DEMOS = true
local DEMO_PRODUCT_ID = 1 -- any whole number for a simulation
local DEMO_USER_ID = 1 -- any whole number for a simulation

if not RUN_DEMOS then
	return
end

task.wait(2) -- let R3FTOStart run first
local diagnostics = R3FTO.getDiagnostics()
if diagnostics.environment ~= "test" then
	print("[Example] Test demos run only when R3FTOStart uses the test environment.")
	return
end

-- 1. One simulated receipt, observed twice: the second call joins the first one's work (a duplicate callback).
local first = R3FTO.simulateTestReceipt({
	userId = DEMO_USER_ID,
	productId = DEMO_PRODUCT_ID,
	currencySpent = 25,
	simulationId = "example-" .. string.sub(game.JobId, 1, 8),
})
local again = R3FTO.simulateTestReceipt({
	userId = DEMO_USER_ID,
	productId = DEMO_PRODUCT_ID,
	currencySpent = 25,
	simulationId = "example-" .. string.sub(game.JobId, 1, 8),
})
print("[Example] simulated receipt", first.purchaseId, "accepted:", first.accepted, "duplicate on second call:", again.duplicate)

-- 2. A few seconds later, show what happened to it.
task.wait(5)
local status = R3FTO.getReceiptStatus(first.purchaseId)
if status then
	print("[Example] durability:", status.durability)
	print("[Example] DataStore copy:", status.channels.storage.state, status.channels.storage.lastError or "")
	print("[Example] R3FTO delivery:", status.channels.delivery.state, status.channels.delivery.lastError or "")
end
print("[Example] diagnostics:", game:GetService("HttpService"):JSONEncode(R3FTO.getDiagnostics()))
