--!strict
-- Ui — the plugin's UI primitive factory, ported faithfully from the monolith's
-- Ui block (StudioStud.plugin.lua:526-902). Every widget the panels build
-- (labels, buttons, the ms slider, the status card, the brand badge/logo) is
-- minted here so the construction recipe — sizes, fonts, colours, ZIndex,
-- corners/strokes — lives in exactly one place. Pure view construction: no daemon
-- traffic, no Live/Capture logic; the panels wire behaviour to the handles these
-- factories return.
--
-- Every colour/font/spacing value comes from ./Theme (single source of truth); no
-- factory re-declares a palette entry.
--
-- M4 FIX (the leak this module exists to close): makeMsSlider connects to
-- UserInputService.InputChanged / .InputEnded (process-wide signals, NOT scoped to
-- the slider's own Instances, so they outlive the Frame's destruction). The
-- monolith never disconnected them, so every rebuilt panel leaked two live
-- connections. Here the slider tracks both RBXScriptConnections and the returned
-- handle exposes `disconnect()`; the owning panel calls it on teardown. The
-- slider's own track/knob InputBegan connections die with the Instances (parented
-- under `row`) and need no explicit teardown — only the UIS subscriptions do.
--
-- NB: this module imports no shared aliases from ./Types — it traffics purely in
-- Roblox UI datatypes (Instances, Color3, UDim2), none of which are part of the
-- protocol-v2 wire contract. It depends only on ./Theme for the palette/fonts and
-- on ../Config for the resolved logo asset id. (luau-craft: import what you use.)

local Theme = require("./Theme")
local Config = require("../Config")

-- `game` is a Studio/plugin global the analyzer types via globalTypes.d.luau.
-- UserInputService drives slider dragging; resolved once at module load (it is a
-- process-wide singleton, so there is no per-event GetService on the hot drag path
-- — cache-at-event) and shared by every slider built thereafter.
local UserInputService = game:GetService("UserInputService") :: UserInputService

-- The resolved logo asset id ("" or a valid rbxassetid://… string), from Config —
-- the single source of truth for the icon constant. makeBrandBadge prefers the
-- image when present, else falls back to the drawn vector logo.
local resolvedLogoAssetId = Config.resolvedLogoAssetId

-- == Public interface ==

-- A live ms-slider handle. `setValue` re-positions the fill/knob and label without
-- firing onChanged (programmatic update); `getValue` reads the current integer ms;
-- `disconnect` tears down the two UserInputService subscriptions (M4) and must be
-- called by the owner when the slider's panel is destroyed.
export type MsSlider = {
	setValue: (ms: number) -> (),
	getValue: () -> number,
	disconnect: () -> (),
}

-- A status-card handle. `frame` is the card Instance (for parenting/layout);
-- `setState` recolours the dot/stripe and message for one of the four states
-- ("connected" | "syncing" | "error" | anything-else→idle); `setStats` writes the
-- secondary code-font line.
export type StatusCard = {
	frame: Frame,
	setState: (state: string, message: string) -> (),
	setStats: (text: string?) -> (),
}

-- The exported factory module. Each method mirrors one monolith Ui.* function,
-- same signature and same returned Instance/handle.
export type UiModule = {
	makeCorner: (parent: Instance, radius: number?) -> UICorner,
	makeStroke: (parent: Instance, color: Color3, thickness: number?) -> UIStroke,
	makeLabel: (parent: Instance, text: string, y: number, height: number?, textColor: Color3?) -> TextLabel,
	makeSectionLabel: (parent: Instance, text: string, y: number) -> TextLabel,
	makePrimaryButton: (parent: Instance, text: string) -> TextButton,
	makeSecondaryButton: (parent: Instance, text: string) -> TextButton,
	makeMsSlider: (
		parent: Instance,
		y: number,
		minMs: number,
		maxMs: number,
		initialMs: number,
		onChanged: ((ms: number) -> ())?
	) -> MsSlider,
	makeStatusCard: (parent: Instance, y: number) -> StatusCard,
	makeVectorLogo: (parent: Instance, size: number) -> Frame,
	makeBrandBadge: (parent: Instance) -> Frame,
}

-- == Module table ==

-- All factories are fields on this one table; no forward-referenced upvalue is
-- ever read before it is assigned (the C1-C3 bug class). Where one factory calls
-- another (e.g. makePrimaryButton -> makeCorner), it goes through `Ui.*`, which is
-- a field read resolved at call time, never a use-before-local.
local Ui = {} :: UiModule

function Ui.makeCorner(parent: Instance, radius: number?): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or 8)
	corner.Parent = parent
	return corner
end

function Ui.makeStroke(parent: Instance, color: Color3, thickness: number?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness or 1
	stroke.Parent = parent
	return stroke
end

function Ui.makeLabel(parent: Instance, text: string, y: number, height: number?, textColor: Color3?): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromOffset(Theme.PAD, y)
	label.Size = UDim2.new(1, -Theme.PAD * 2, 0, height or 24)
	label.FontFace = Theme.UI_FONT
	label.TextColor3 = textColor or Theme.body
	label.TextSize = 14
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.TextWrapped = true
	label.Text = text
	label.Parent = parent
	return label
end

function Ui.makeSectionLabel(parent: Instance, text: string, y: number): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromOffset(Theme.PAD, y)
	label.Size = UDim2.new(1, -Theme.PAD * 2, 0, 14)
	label.FontFace = Theme.UI_FONT_BOLD
	label.TextColor3 = Theme.muted
	label.TextSize = 11
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = string.upper(text)
	label.Parent = parent
	return label
end

function Ui.makePrimaryButton(parent: Instance, text: string): TextButton
	local button = Instance.new("TextButton")
	button.BackgroundColor3 = Theme.copper
	button.BorderSizePixel = 0
	button.FontFace = Theme.UI_FONT_BOLD
	button.TextColor3 = Theme.panel
	button.TextSize = 14
	button.Text = text
	button.Parent = parent
	Ui.makeCorner(button, 8)
	return button
end

function Ui.makeSecondaryButton(parent: Instance, text: string): TextButton
	local button = Instance.new("TextButton")
	button.BackgroundColor3 = Theme.surface
	button.BorderSizePixel = 0
	button.AutoButtonColor = true
	button.FontFace = Theme.UI_FONT
	button.TextColor3 = Theme.body
	button.TextSize = 14
	button.Text = text
	button.ZIndex = 2
	button.Parent = parent
	Ui.makeCorner(button, 8)
	Ui.makeStroke(button, Theme.surfaceBorder, 1)
	return button
end

-- Horizontal ms slider (integer steps). Calls onChanged(ms) when the value
-- settles/changes. M4: the two UserInputService subscriptions (drag-move /
-- drag-end) are captured into `connections` and torn down by the returned
-- handle's `disconnect()` — the only connections that outlive the slider's Frame.
function Ui.makeMsSlider(
	parent: Instance,
	y: number,
	minMs: number,
	maxMs: number,
	initialMs: number,
	onChanged: ((ms: number) -> ())?
): MsSlider
	local row = Instance.new("Frame")
	row.Name = "MsSlider"
	row.BackgroundTransparency = 1
	row.Position = UDim2.fromOffset(Theme.PAD, y)
	row.Size = UDim2.new(1, -Theme.PAD * 2, 0, 56)
	row.Parent = parent

	local valueLabel = Instance.new("TextLabel")
	valueLabel.BackgroundTransparency = 1
	valueLabel.Size = UDim2.new(1, 0, 0, 18)
	valueLabel.FontFace = Theme.UI_FONT_BOLD
	valueLabel.TextColor3 = Theme.body
	valueLabel.TextSize = 13
	valueLabel.TextXAlignment = Enum.TextXAlignment.Right
	valueLabel.Parent = row

	local track = Instance.new("TextButton")
	track.Name = "Track"
	track.AutoButtonColor = false
	track.Text = ""
	track.BackgroundColor3 = Theme.surface
	track.BorderSizePixel = 0
	track.Position = UDim2.fromOffset(0, 22)
	track.Size = UDim2.new(1, 0, 0, 24)
	track.ZIndex = 2
	track.Parent = row
	Ui.makeCorner(track, 6)
	Ui.makeStroke(track, Theme.surfaceBorder, 1)

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = Theme.copper
	fill.BorderSizePixel = 0
	fill.Size = UDim2.fromScale(0, 1)
	fill.ZIndex = 2
	fill.Parent = track
	Ui.makeCorner(fill, 6)

	local knob = Instance.new("TextButton")
	knob.Name = "Knob"
	knob.AutoButtonColor = false
	knob.Text = ""
	knob.BackgroundColor3 = Theme.body
	knob.BorderSizePixel = 0
	knob.Size = UDim2.fromOffset(16, 16)
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.ZIndex = 4
	knob.Parent = track
	Ui.makeCorner(knob, 8)
	Ui.makeStroke(knob, Theme.copperDim, 1)

	local minLabel = Instance.new("TextLabel")
	minLabel.BackgroundTransparency = 1
	minLabel.Position = UDim2.fromOffset(0, 48)
	minLabel.Size = UDim2.fromOffset(48, 14)
	minLabel.FontFace = Theme.UI_FONT
	minLabel.TextColor3 = Theme.muted
	minLabel.TextSize = 10
	minLabel.TextXAlignment = Enum.TextXAlignment.Left
	minLabel.Text = tostring(minMs) .. " ms"
	minLabel.Parent = row

	local maxLabel = Instance.new("TextLabel")
	maxLabel.BackgroundTransparency = 1
	maxLabel.AnchorPoint = Vector2.new(1, 0)
	maxLabel.Position = UDim2.new(1, 0, 0, 48)
	maxLabel.Size = UDim2.fromOffset(52, 14)
	maxLabel.FontFace = Theme.UI_FONT
	maxLabel.TextColor3 = Theme.muted
	maxLabel.TextSize = 10
	maxLabel.TextXAlignment = Enum.TextXAlignment.Right
	maxLabel.Text = tostring(maxMs) .. " ms"
	maxLabel.Parent = row

	local currentMs = math.clamp(math.floor(initialMs + 0.5), minMs, maxMs)
	local dragging = false

	local function alphaForMs(ms: number): number
		return (ms - minMs) / (maxMs - minMs)
	end

	local function msFromAlpha(alpha: number): number
		return math.clamp(minMs + math.clamp(alpha, 0, 1) * (maxMs - minMs), minMs, maxMs)
	end

	local function applyMs(ms: number, persist: boolean)
		currentMs = math.clamp(math.floor(ms + 0.5), minMs, maxMs)
		local alpha = alphaForMs(currentMs)
		fill.Size = UDim2.fromScale(alpha, 1)
		knob.Position = UDim2.fromScale(alpha, 0.5)
		valueLabel.Text = tostring(currentMs) .. " ms"
		if persist and onChanged then
			onChanged(currentMs)
		end
	end

	local function updateFromScreenX(screenX: number)
		local trackX = track.AbsolutePosition.X
		local trackWidth = track.AbsoluteSize.X
		if trackWidth <= 0 then
			return
		end
		applyMs(msFromAlpha((screenX - trackX) / trackWidth), true)
	end

	local function beginDrag(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			updateFromScreenX(input.Position.X)
		end
	end

	-- track/knob InputBegan connections are scoped to those Instances (parented
	-- under `row`); they die when the slider's Frame is destroyed, so they are NOT
	-- tracked for teardown — only the process-wide UIS subscriptions below are.
	track.InputBegan:Connect(beginDrag)
	knob.InputBegan:Connect(beginDrag)

	-- M4: the leaky pair. Track both so disconnect() can release them.
	local connections: { RBXScriptConnection } = {}

	connections[#connections + 1] = UserInputService.InputChanged:Connect(function(input: InputObject)
		if not dragging then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			updateFromScreenX(input.Position.X)
		end
	end)

	connections[#connections + 1] = UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)

	applyMs(currentMs, false)

	return {
		setValue = function(ms: number)
			applyMs(ms, false)
		end,
		getValue = function(): number
			return currentMs
		end,
		disconnect = function()
			for _, connection in connections do
				connection:Disconnect()
			end
			table.clear(connections)
		end,
	}
end

function Ui.makeStatusCard(parent: Instance, y: number): StatusCard
	local card = Instance.new("Frame")
	card.Name = "StatusCard"
	card.Position = UDim2.fromOffset(Theme.PAD, y)
	card.Size = UDim2.new(1, -Theme.PAD * 2, 0, 54)
	card.BackgroundColor3 = Theme.surface
	card.BorderSizePixel = 0
	card.Parent = parent
	Ui.makeCorner(card, 8)
	Ui.makeStroke(card, Theme.surfaceBorder, 1)

	local stripe = Instance.new("Frame")
	stripe.Name = "StatusStripe"
	stripe.BackgroundColor3 = Theme.tealDim
	stripe.BorderSizePixel = 0
	stripe.Size = UDim2.new(0, 4, 1, 0)
	stripe.Parent = card
	local stripeCorner = Instance.new("UICorner")
	stripeCorner.CornerRadius = UDim.new(0, 8)
	stripeCorner.Parent = stripe

	local dot = Instance.new("Frame")
	dot.Name = "StatusDot"
	dot.BackgroundColor3 = Theme.muted
	dot.BorderSizePixel = 0
	dot.Position = UDim2.fromOffset(14, 12)
	dot.Size = UDim2.fromOffset(10, 10)
	dot.Parent = card
	Ui.makeCorner(dot, 5)

	local statusLabel = Instance.new("TextLabel")
	statusLabel.BackgroundTransparency = 1
	statusLabel.Position = UDim2.fromOffset(30, 4)
	statusLabel.Size = UDim2.new(1, -38, 0, 22)
	statusLabel.FontFace = Theme.UI_FONT
	statusLabel.TextColor3 = Theme.body
	statusLabel.TextSize = 13
	statusLabel.TextXAlignment = Enum.TextXAlignment.Left
	statusLabel.TextWrapped = false
	statusLabel.TextTruncate = Enum.TextTruncate.AtEnd
	statusLabel.Text = "Waiting for daemon"
	statusLabel.Parent = card

	local statsLabel = Instance.new("TextLabel")
	statsLabel.BackgroundTransparency = 1
	statsLabel.Position = UDim2.fromOffset(30, 30)
	statsLabel.Size = UDim2.new(1, -38, 0, 18)
	statsLabel.FontFace = Theme.CODE_FONT
	statsLabel.TextColor3 = Theme.muted
	statsLabel.TextSize = 11
	statsLabel.TextXAlignment = Enum.TextXAlignment.Left
	statsLabel.TextTruncate = Enum.TextTruncate.AtEnd
	statsLabel.Text = ""
	statsLabel.Parent = card

	local function setState(state: string, message: string)
		statusLabel.Text = message
		if state == "connected" then
			dot.BackgroundColor3 = Theme.teal
			stripe.BackgroundColor3 = Theme.teal
			statusLabel.TextColor3 = Theme.body
		elseif state == "syncing" then
			dot.BackgroundColor3 = Theme.copper
			stripe.BackgroundColor3 = Theme.copper
			statusLabel.TextColor3 = Theme.body
		elseif state == "error" or state == "waiting" then
			dot.BackgroundColor3 = Theme.warn
			stripe.BackgroundColor3 = Theme.warn
			statusLabel.TextColor3 = Theme.warn
		else
			dot.BackgroundColor3 = Theme.muted
			stripe.BackgroundColor3 = Theme.tealDim
			statusLabel.TextColor3 = Theme.muted
		end
	end

	local function setStats(text: string?)
		statsLabel.Text = text or ""
	end

	return { frame = card, setState = setState, setStats = setStats }
end

function Ui.makeVectorLogo(parent: Instance, size: number): Frame
	local root = Instance.new("Frame")
	root.Name = "StudioStudLogo"
	root.BackgroundColor3 = Theme.badge
	root.BorderSizePixel = 0
	root.Size = UDim2.fromOffset(size, size)
	root.Parent = parent
	Ui.makeCorner(root, math.floor(size * 0.22))

	local ring = Instance.new("Frame")
	ring.BackgroundColor3 = Theme.tealDim
	ring.BorderSizePixel = 0
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.fromOffset(math.floor(size * 0.78), math.floor(size * 0.78))
	ring.Parent = root
	Ui.makeCorner(ring, 999)

	local ringInner = Instance.new("Frame")
	ringInner.BackgroundColor3 = Theme.badge
	ringInner.BorderSizePixel = 0
	ringInner.AnchorPoint = Vector2.new(0.5, 0.5)
	ringInner.Position = UDim2.fromScale(0.5, 0.5)
	ringInner.Size = UDim2.fromOffset(math.floor(size * 0.58), math.floor(size * 0.58))
	ringInner.Parent = ring
	Ui.makeCorner(ringInner, 999)

	local pin = Instance.new("Frame")
	pin.BackgroundColor3 = Theme.copper
	pin.BorderSizePixel = 0
	pin.AnchorPoint = Vector2.new(0.5, 0.5)
	pin.Position = UDim2.fromScale(0.5, 0.52)
	pin.Size = UDim2.fromOffset(math.max(3, math.floor(size * 0.12)), math.floor(size * 0.42))
	pin.Parent = root
	Ui.makeCorner(pin, 2)

	for index = 0, 2 do
		local tick = Instance.new("Frame")
		tick.BackgroundColor3 = Theme.copperDim
		tick.BorderSizePixel = 0
		tick.Position = UDim2.fromOffset(math.floor(size * 0.16), math.floor(size * 0.28 + index * size * 0.14))
		tick.Size = UDim2.fromOffset(math.floor(size * 0.18), math.max(2, math.floor(size * 0.06)))
		tick.Parent = root
		Ui.makeCorner(tick, 1)
	end

	return root
end

function Ui.makeBrandBadge(parent: Instance): Frame
	local badge = Instance.new("Frame")
	badge.Name = "BrandBadge"
	badge.BackgroundTransparency = 1
	badge.BorderSizePixel = 0
	badge.Size = UDim2.fromOffset(36, 36)
	badge.Parent = parent

	if resolvedLogoAssetId ~= "" then
		local image = Instance.new("ImageLabel")
		image.Name = "LogoImage"
		image.BackgroundTransparency = 1
		image.Size = UDim2.fromScale(1, 1)
		image.Image = resolvedLogoAssetId
		image.ScaleType = Enum.ScaleType.Fit
		image.Parent = badge
	else
		Ui.makeVectorLogo(badge, 36)
	end

	return badge
end

return Ui
