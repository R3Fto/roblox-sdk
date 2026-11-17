--!strict
-- R3FTO Roblox SDK: the key panel's fixed look (pure Luau, no Roblox service).
--
-- The panel's words, the R3FTO design colours and sizes, the key filter and the answer-to-state map. The Panel
-- LocalScript draws the panel from this module only. The words and the look are fixed: a game cannot change them, and
-- the panel never shows text it receives from R3FTO or the game server, only these words and the player's own typing.

local Look = {}

-- The panel's words.
Look.WORDS = table.freeze({
	eyebrow = "R3FTO Key",
	help = "Type the R3FTO Key a creator gave you.",
	placeholder = "Use 4 to 16 letters A–Z",
	apply = "Apply",
	close = "Close",
	checking = "Checking",
	accepted = "Key accepted.",
	notFound = "R3FTO Key not found.",
	notReady = "R3FTO Keys are not available in this game right now.",
	tryLater = "Try again in a moment.",
})

-- The eyebrow is shown in upper case, as every R3FTO eyebrow.
Look.EYEBROW = string.upper(Look.WORDS.eyebrow)

-- The compact Close button shows this sign; the button is named with the Close word.
Look.CLOSE_SIGN = "×"

-- The R3FTO design colours (dark theme), copied once.
Look.COLOURS = table.freeze({
	["ink"] = "#0d0507",
	["canvas"] = "#170a0e",
	["surface-elevated"] = "#32161d",
	["border"] = "#4a222c",
	["text-primary"] = "#fff4f7",
	["text-secondary"] = "#cdbcc1",
	["text-muted"] = "#9e8b91",
	["crimson-action"] = "#d6284d",
	["on-crimson-action"] = "#ffffff",
	["neon-crimson"] = "#ff335c",
	["success-green"] = "#62d26f",
	["warning-amber"] = "#f3b340",
	["danger-critical"] = "#ff335c",
})

-- Sizes in pixels, from the design tokens: the panel is at most 400 wide and 16 from each screen edge, 16 below the
-- top of the safe area (so a phone keyboard does not cover the box), padded 24 (16 on a screen narrower than 480).
Look.SIZES = table.freeze({
	maxWidth = 400,
	screenMargin = 16,
	top = 16,
	padding = 24,
	paddingNarrow = 16,
	narrowBelow = 480,
	gap = 16,
	controlHeight = 48,
	closeSize = 36,
	inputPaddingX = 16,
	radiusPanel = 8,
	radiusControl = 6,
	stroke = 1,
})

-- The scrim behind the panel (ink, half transparent) and an inert button (the same size, faded).
Look.SCRIM_TRANSPARENCY = 0.5
Look.INERT_TRANSPARENCY = 0.55

-- Text styles: size, line height in pixels and weight ("Regular" or "Bold", a Roblox FontWeight name). Roboto.
Look.TYPE = table.freeze({
	eyebrow = table.freeze({ size = 12, lineHeight = 16, weight = "Bold" }),
	help = table.freeze({ size = 14, lineHeight = 20, weight = "Regular" }),
	key = table.freeze({ size = 20, lineHeight = 28, weight = "Bold" }),
	placeholder = table.freeze({ size = 14, lineHeight = 20, weight = "Regular" }),
	status = table.freeze({ size = 12, lineHeight = 16, weight = "Regular" }),
	button = table.freeze({ size = 14, lineHeight = 20, weight = "Bold" }),
	close = table.freeze({ size = 18, lineHeight = 18, weight = "Regular" }),
})

-- The panel's states: the status line's words and colour, and whether the box is emptied.
export type State = { text: string, colour: string, clearBox: boolean }

Look.STATES = table.freeze({
	ready = table.freeze({ text = "", colour = "text-secondary", clearBox = false }),
	checking = table.freeze({ text = Look.WORDS.checking, colour = "text-secondary", clearBox = false }),
	accepted = table.freeze({ text = Look.WORDS.accepted, colour = "success-green", clearBox = true }),
	notFound = table.freeze({ text = Look.WORDS.notFound, colour = "danger-critical", clearBox = false }),
	notReady = table.freeze({ text = Look.WORDS.notReady, colour = "warning-amber", clearBox = false }),
	tryLater = table.freeze({ text = Look.WORDS.tryLater, colour = "warning-amber", clearBox = false }),
})

-- The status line always keeps room for two lines, and for the longest status if that needs more, so no state moves
-- anything. Two invisible sizing texts hold that room.
Look.TWO_LINES = "X\nX"
Look.LONGEST_STATUS = (function(): string
	local longest = ""
	for _, state in Look.STATES do
		if #state.text > #longest then
			longest = state.text
		end
	end
	return longest
end)()

-- Seconds the panel waits for an answer before it shows the try-later state. A real answer that arrives later is
-- still shown.
Look.TIMEOUT = 15

-- The key bounds: 4 to 16 letters A-Z.
Look.MIN_KEY = 4
Look.MAX_KEY = 16

-- The box keeps only the letters A-Z, in upper case, at most MAX_KEY of them.
function Look.normalize(text: any): string
	if type(text) ~= "string" then
		return ""
	end
	local letters = string.gsub(string.upper(text), "[^A-Z]", "")
	return string.sub(letters, 1, Look.MAX_KEY)
end

-- True when the box holds a key that can be applied.
function Look.isKey(text: any): boolean
	return type(text) == "string"
		and #text >= Look.MIN_KEY
		and #text <= Look.MAX_KEY
		and string.find(text, "^[A-Z]+$") ~= nil
end

-- The state for an answer token. "timeout" is the panel's own: no answer within TIMEOUT seconds. Any token the panel
-- does not know shows the try-later state.
local STATE_FOR: { [string]: string } = {
	checking = "checking",
	accepted = "accepted",
	unknown_key = "notFound",
	unavailable = "notReady",
	busy = "tryLater",
	throttled = "tryLater",
	failed = "tryLater",
	timeout = "tryLater",
}

function Look.stateFor(outcome: any): string
	if type(outcome) == "string" and STATE_FOR[outcome] ~= nil then
		return STATE_FOR[outcome]
	end
	return "tryLater"
end

return table.freeze(Look)
