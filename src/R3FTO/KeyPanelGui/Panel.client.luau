--!nonstrict
-- R3FTO Roblox SDK: the key panel on the player's device (a LocalScript).
--
-- It runs only after the game server opened the panel for this player (R3FTO.openKeyPanel): the server copies this
-- script, the Look module and a "Request" remote into a ScreenGui in this player's PlayerGui. Under ServerScriptService
-- it never runs.
--
-- What it does, and what it never does:
-- * It draws the panel from Look only: fixed words, the R3FTO colours and sizes. It never shows text it receives; an
--   answer is a token that selects fixed Look words.
-- * The box keeps only the letters A-Z, in upper case, at most 16. Apply (or Enter, or the on-screen keyboard's return)
--   sends the key once through the remote. Nothing is sent by itself, and nothing removes a key: another key replaces it.
-- * Close, Escape and the gamepad B button close the panel. Closing removes this copy only.
-- * Text follows the player's text size setting (no scaled text); the status line keeps the same room in every state,
--   so nothing moves.

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local Look = require(script.Parent:WaitForChild("Look"))

local gui = script.Parent
local request = gui:WaitForChild("Request")
local sizes = Look.SIZES

local closed = false
local actionName = string.format("R3FTOKeyPanelClose%d", math.floor(os.clock() * 1000000))

local function colour(token: string): Color3
	return Color3.fromHex(Look.COLOURS[token])
end

local roboto = Font.fromEnum(Enum.Font.Roboto).Family

local function style(object: any, name: string)
	local textStyle = Look.TYPE[name]
	object.FontFace = Font.new(roboto, Enum.FontWeight[textStyle.weight])
	object.TextSize = textStyle.size
	object.LineHeight = textStyle.lineHeight / textStyle.size
	object.AutoLocalize = false
end

local function corner(parent: Instance, radius: number)
	local ui = Instance.new("UICorner")
	ui.CornerRadius = UDim.new(0, radius)
	ui.Parent = parent
end

-- A 1 px border around the object (never around its text).
local function stroke(parent: Instance, token: string): UIStroke
	local ui = Instance.new("UIStroke")
	ui.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ui.Thickness = sizes.stroke
	ui.Color = colour(token)
	ui.Parent = parent
	return ui
end

-- The gamepad-selected look of a control: a 1 px neon-crimson border at the control's radius, no glow. It replaces
-- Roblox's default selection image.
local function selectedLook(control: GuiObject, radius: number)
	local ring = Instance.new("Frame")
	ring.Name = "Selected"
	ring.Size = UDim2.fromScale(1, 1)
	ring.BackgroundTransparency = 1
	ring.BorderSizePixel = 0
	corner(ring, radius)
	stroke(ring, "neon-crimson")
	control.SelectionImageObject = ring
end

local function label(name: string, parent: Instance, order: number): TextLabel
	local text = Instance.new("TextLabel")
	text.Name = name
	text.BackgroundTransparency = 1
	text.BorderSizePixel = 0
	text.LayoutOrder = order
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextYAlignment = Enum.TextYAlignment.Top
	text.TextWrapped = true
	text.Parent = parent
	return text
end

-- The scrim: half-transparent ink over the screen. It takes the clicks behind the panel and frees the mouse in games
-- that lock it; it does nothing itself.
gui.AutoLocalize = false
local scrim = Instance.new("TextButton")
scrim.Name = "Scrim"
scrim.Size = UDim2.fromScale(1, 1)
scrim.BackgroundColor3 = colour("ink")
scrim.BackgroundTransparency = Look.SCRIM_TRANSPARENCY
scrim.BorderSizePixel = 0
scrim.AutoButtonColor = false
scrim.Modal = true
scrim.Selectable = false
scrim.Text = ""
scrim.AutoLocalize = false
scrim.ZIndex = 1
scrim.Parent = gui

-- The panel: top centre, at most 400 wide and 16 from each screen edge, as tall as its content.
local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0.5, 0)
panel.Position = UDim2.new(0.5, 0, 0, sizes.top)
panel.Size = UDim2.new(1, -2 * sizes.screenMargin, 0, 0)
panel.AutomaticSize = Enum.AutomaticSize.Y
panel.BackgroundColor3 = colour("surface-elevated")
panel.BorderSizePixel = 0
panel.Active = true
panel.ZIndex = 2
-- Gamepad selection stays inside the panel while it is open.
panel.SelectionGroup = true
panel.SelectionBehaviorUp = Enum.SelectionBehavior.Stop
panel.SelectionBehaviorDown = Enum.SelectionBehavior.Stop
panel.SelectionBehaviorLeft = Enum.SelectionBehavior.Stop
panel.SelectionBehaviorRight = Enum.SelectionBehavior.Stop
panel.Parent = gui
corner(panel, sizes.radiusPanel)
stroke(panel, "border")

local widthLimit = Instance.new("UISizeConstraint")
widthLimit.MaxSize = Vector2.new(sizes.maxWidth, math.huge)
widthLimit.Parent = panel

local padding = Instance.new("UIPadding")
padding.Parent = panel

local function fitPadding()
	local narrow = gui.AbsoluteSize.X > 0 and gui.AbsoluteSize.X < sizes.narrowBelow
	local inset = UDim.new(0, if narrow then sizes.paddingNarrow else sizes.padding)
	padding.PaddingTop = inset
	padding.PaddingBottom = inset
	padding.PaddingLeft = inset
	padding.PaddingRight = inset
end
fitPadding()
gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitPadding)

local stack = Instance.new("UIListLayout")
stack.FillDirection = Enum.FillDirection.Vertical
stack.SortOrder = Enum.SortOrder.LayoutOrder
stack.Padding = UDim.new(0, sizes.gap)
stack.Parent = panel

-- 1. The eyebrow and the compact Close button.
local top = Instance.new("Frame")
top.Name = "Top"
top.BackgroundTransparency = 1
top.BorderSizePixel = 0
top.LayoutOrder = 1
top.Size = UDim2.new(1, 0, 0, sizes.closeSize)
top.Parent = panel

local eyebrow = label("Eyebrow", top, 0)
eyebrow.Size = UDim2.new(1, -(sizes.closeSize + sizes.gap), 1, 0)
eyebrow.TextYAlignment = Enum.TextYAlignment.Center
eyebrow.TextWrapped = false
eyebrow.TextColor3 = colour("text-secondary")
style(eyebrow, "eyebrow")
eyebrow.Text = Look.EYEBROW

local closeButton = Instance.new("TextButton")
closeButton.Name = Look.WORDS.close
closeButton.AnchorPoint = Vector2.new(1, 0)
closeButton.Position = UDim2.fromScale(1, 0)
closeButton.Size = UDim2.fromOffset(sizes.closeSize, sizes.closeSize)
closeButton.BackgroundTransparency = 1
closeButton.BorderSizePixel = 0
closeButton.AutoButtonColor = false
closeButton.TextColor3 = colour("text-secondary")
style(closeButton, "close")
closeButton.Text = Look.CLOSE_SIGN
closeButton.Parent = top
corner(closeButton, sizes.radiusPanel)
stroke(closeButton, "border")
selectedLook(closeButton, sizes.radiusPanel)

-- 2. The help line.
local help = label("Help", panel, 2)
help.Size = UDim2.fromScale(1, 0)
help.AutomaticSize = Enum.AutomaticSize.Y
help.TextColor3 = colour("text-secondary")
style(help, "help")
help.Text = Look.WORDS.help

-- 3. The key box.
local box = Instance.new("TextBox")
box.Name = "Key"
box.LayoutOrder = 3
box.Size = UDim2.new(1, 0, 0, sizes.controlHeight)
box.BackgroundColor3 = colour("canvas")
box.BorderSizePixel = 0
box.ClearTextOnFocus = false
box.MultiLine = false
box.TextWrapped = false
box.TextXAlignment = Enum.TextXAlignment.Left
box.TextColor3 = colour("text-primary")
box.PlaceholderColor3 = colour("text-muted")
box.PlaceholderText = Look.WORDS.placeholder
box.Text = ""
box.Selectable = true
box.Parent = panel
corner(box, sizes.radiusControl)
local boxStroke = stroke(box, "border")
selectedLook(box, sizes.radiusControl)
local boxPadding = Instance.new("UIPadding")
boxPadding.PaddingLeft = UDim.new(0, sizes.inputPaddingX)
boxPadding.PaddingRight = UDim.new(0, sizes.inputPaddingX)
boxPadding.Parent = box

-- The placeholder uses the body style and a typed key the key style; the box keeps its height either way.
local function fitBoxStyle()
	style(box, if box.Text == "" then "placeholder" else "key")
end
fitBoxStyle()

-- 4. The status line. The holder is as tall as the larger of two lines and the longest status at the player's text
-- size; the two sizing texts are invisible, so every state keeps the same room.
local statusHolder = Instance.new("Frame")
statusHolder.Name = "StatusRoom"
statusHolder.BackgroundTransparency = 1
statusHolder.BorderSizePixel = 0
statusHolder.LayoutOrder = 4
statusHolder.Size = UDim2.fromScale(1, 0)
statusHolder.AutomaticSize = Enum.AutomaticSize.Y
statusHolder.Parent = panel

local function sizer(name: string): TextLabel
	local text = label(name, statusHolder, 0)
	text.Size = UDim2.fromScale(1, 0)
	text.AutomaticSize = Enum.AutomaticSize.Y
	text.TextTransparency = 1
	style(text, "status")
	return text
end
sizer("TwoLines").Text = Look.TWO_LINES
sizer("Longest").Text = Look.LONGEST_STATUS

local status = label("Status", statusHolder, 0)
status.Size = UDim2.fromScale(1, 0)
status.AutomaticSize = Enum.AutomaticSize.Y
style(status, "status")

-- 5. The Apply button, full width.
local applyButton = Instance.new("TextButton")
applyButton.Name = Look.WORDS.apply
applyButton.LayoutOrder = 5
applyButton.Size = UDim2.new(1, 0, 0, sizes.controlHeight)
applyButton.BackgroundColor3 = colour("crimson-action")
applyButton.BorderSizePixel = 0
applyButton.AutoButtonColor = false
applyButton.TextColor3 = colour("on-crimson-action")
style(applyButton, "button")
applyButton.Text = Look.WORDS.apply
applyButton.Selectable = true
applyButton.Parent = panel
corner(applyButton, sizes.radiusPanel)
selectedLook(applyButton, sizes.radiusPanel)

-- Gamepad order: Close, the box, Apply.
closeButton.NextSelectionDown = box
box.NextSelectionUp = closeButton
box.NextSelectionDown = applyButton
applyButton.NextSelectionUp = box

-- State ---------------------------------------------------------------------------------------------------------------

local latest = 0 -- the number of the latest request
local running = false -- the latest request is waiting for its answer and has not timed out

-- `stateName` is always a Look state (Look.stateFor answers only those).
local function show(stateName: string)
	status.Text = Look.STATES[stateName].text
	status.TextColor3 = colour(Look.STATES[stateName].colour)
end

local function canApply(): boolean
	return not closed and not running and Look.isKey(box.Text)
end

-- Apply is inert (the same size, faded) unless the box holds 4 to 16 letters and no request is running.
local function refresh()
	local faded = if canApply() then 0 else Look.INERT_TRANSPARENCY
	applyButton.BackgroundTransparency = faded
	applyButton.TextTransparency = faded
end

local sentKeys: { [number]: string } = {} -- the key each request sent, by request number, until it is answered

local function answered(id: number, outcome: any)
	local sentKey = sentKeys[id]
	sentKeys[id] = nil
	if closed then
		return
	end
	if id == latest then
		running = false
	elseif running then
		-- A newer request is waiting; its answer decides what the panel shows.
		return
	end
	local stateName = Look.stateFor(outcome)
	show(stateName)
	-- The box is emptied only while it still holds the key this request sent: a key typed since then stays.
	if Look.STATES[stateName].clearBox and box.Text == sentKey then
		box.Text = ""
	end
	refresh()
end

local function apply()
	if not canApply() then
		return
	end
	local key = box.Text
	latest += 1
	local id = latest
	sentKeys[id] = key
	running = true
	show("checking")
	refresh()
	task.delay(Look.TIMEOUT, function()
		if not closed and id == latest and running then
			-- No answer yet: the panel shows try-later. The real answer is still shown when it arrives.
			running = false
			show(Look.stateFor("timeout"))
			refresh()
		end
	end)
	task.spawn(function()
		local ok, outcome = pcall(function()
			return request:InvokeServer("use", key)
		end)
		answered(id, if ok then outcome else "failed")
	end)
end

-- Closing -------------------------------------------------------------------------------------------------------------

local previousSelection = GuiService.SelectedObject

local function release()
	if closed then
		return
	end
	closed = true
	ContextActionService:UnbindAction(actionName)
	local selected = GuiService.SelectedObject
	if selected == nil or selected:IsDescendantOf(gui) then
		if previousSelection ~= nil and previousSelection:IsDescendantOf(game) and not previousSelection:IsDescendantOf(gui) then
			GuiService.SelectedObject = previousSelection
		else
			GuiService.SelectedObject = nil
		end
	end
end

local function close()
	release()
	gui:Destroy()
end

-- The server replaces the panel when the game opens it again: this copy then cleans up after itself.
gui.Destroying:Connect(release)

-- Input -----------------------------------------------------------------------------------------------------------------

-- Every change is filtered through Look.normalize; the filtered text then arrives here again as a change.
box:GetPropertyChangedSignal("Text"):Connect(function()
	if Look.normalize(box.Text) ~= box.Text then
		box.Text = Look.normalize(box.Text)
		box.CursorPosition = #box.Text + 1
		return
	end
	fitBoxStyle()
	refresh()
end)

box.Focused:Connect(function()
	boxStroke.Color = colour("neon-crimson")
end)

box.FocusLost:Connect(function(enterPressed: boolean)
	boxStroke.Color = colour("border")
	if enterPressed then
		apply()
	end
end)

box.ReturnPressedFromOnScreenKeyboard:Connect(apply)
applyButton.Activated:Connect(apply)
closeButton.Activated:Connect(close)

ContextActionService:BindActionAtPriority(actionName, function(_, inputState: Enum.UserInputState)
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	close()
	return Enum.ContextActionResult.Sink
end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Escape, Enum.KeyCode.ButtonB)

show("ready")
refresh()

-- On a gamepad, selection starts on the box.
local lastInput = UserInputService:GetLastInputType()
if UserInputService.GamepadEnabled and string.find(lastInput.Name, "^Gamepad") ~= nil then
	GuiService.SelectedObject = box
end
