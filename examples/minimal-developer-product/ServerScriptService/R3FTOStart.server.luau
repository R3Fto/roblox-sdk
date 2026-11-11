-- Script · ServerScriptService/R3FTOStart
-- Starts the R3FTO SDK once, on the server. Replace nothing here except ENVIRONMENT when you go live.
--
-- Before you press Play:
--   * Experience Settings > Security: turn on "Allow HTTP Requests" and "Enable Studio Access to API Services".
--   * Experience Settings > Security > Local Secrets (Studio) or Creator Hub > your experience > Secrets (live servers):
--     add the secret R3FTO_SDK_TOKEN with the SDK token R3FTO gave you, domain r3f.to. Never paste the token here.

local ServerScriptService = game:GetService("ServerScriptService")

local R3FTO = require(ServerScriptService:WaitForChild("R3FTO"))

local ENVIRONMENT = "test" -- "test" while you integrate; "production" only with your Production token

local ok, reason = R3FTO.start({
	environment = ENVIRONMENT,
	tokenSecretName = "R3FTO_SDK_TOKEN",
})
if not ok then
	warn("[Example] R3FTO did not start: " .. tostring(reason))
end
