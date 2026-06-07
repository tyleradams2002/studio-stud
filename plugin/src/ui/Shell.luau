--!strict
--!nolint DeprecatedApi
-- DeprecatedApi is silenced FILE-WIDE for exactly one call: the verbatim
-- `plugin:CreateDockWidgetPluginGui` bootstrap (the monolith's proven API).
-- luau-lsp suggests the `...Async` variant, but switching it would be a behavior
-- deviation (a different, yielding API) — parity over the lint, per the rewrite's
-- "port proven behavior verbatim" rule. No other deprecated call exists here.
-- Shell — the tab-shell UI, ported faithfully from the monolith's Shell block
-- (StudioStud.plugin.lua:3347-3917). It owns the DockWidgetPluginGui + toolbar
-- bootstrap, the panel context factory (makeCtx) handed to every panel, the tab
-- strip renderer, the full Settings overlay (daemon endpoint, live capture,
-- debounce slider, debug toggle, addon list, panel toggles, setup help), the
-- main-frame build (header/status card/tab strip/panel host), and the
-- widget-enabled hook that kicks the selected panel's connect handshake.
--
-- This is a VIEW module: all daemon traffic goes through Transport (requestJson /
-- requestJsonAuthed), all persistence through Settings, all panel lifecycle
-- through Registry, all visual constants through Theme/Ui. The live capture
-- engine and capture logic live in Live/Capture; Shell only builds the chrome and
-- relays panel requests. (luau-craft: single responsibility — the shell is the
-- frame, not the engine.)
--
-- Structure note (the bug class this rewrite kills): every method is a field on
-- the single `Shell` module table and reaches sibling methods through `Shell.*` —
-- a field read resolved at call time — so there is no forward-referenced upvalue
-- read before its `local` is assigned (C1-C3). The monolith already used a
-- module-table shape here; this port keeps that shape and only adds the explicit
-- typed interface plus a typed `plugin`/`game` shim at the trust boundary.

local Theme = require("./Theme")
local Ui = require("./Ui")
local Config = require("../Config")
local Registry = require("../Registry")
local Settings = require("../Settings")
local Transport = require("../Transport")

type StatusCard = Ui.StatusCard

local SETTINGS = Config.SETTINGS
local DEBOUNCE_MS_MIN = Config.DEBOUNCE_MS_MIN
local DEBOUNCE_MS_MAX = Config.DEBOUNCE_MS_MAX
local PLUGIN_VERSION = Config.PLUGIN_VERSION
local DEFAULT_TOOLBAR_ICON = Config.DEFAULT_TOOLBAR_ICON
local resolvedLogoAssetId = Config.resolvedLogoAssetId

-- `plugin` and `game` are Studio/plugin globals the analyzer types via
-- globalTypes.d.luau. Capture `plugin` into a local once (the single trust point
-- for the widget/toolbar store), matching how Settings caches it. `game` is read
-- directly where the monolith read it (Studio name / PlaceId in the settings
-- overlay), already typed as DataModel by the analyzer.
local pluginHandle: Plugin = plugin

-- == Public interface ==

-- The panel context produced by makeCtx and handed to every panel's build. It is
-- the typed shape of the monolith's loose ctx table: the shared collaborators
-- (theme/ui/transport/settings/plugin/widget) plus the four shell callbacks a
-- panel uses to drive the status card and the connection LED. Registry's getCtx
-- is typed `any`, so this concrete type flows in cleanly while panels can read it
-- with whatever annotation they choose.
export type ShellContext = {
	theme: typeof(Theme),
	ui: typeof(Ui),
	transport: typeof(Transport),
	settings: typeof(Settings),
	plugin: Plugin,
	widget: DockWidgetPluginGui,
	setStatus: (state: string, message: string) -> (),
	setStats: (text: string?) -> (),
	isConnected: () -> boolean,
	setConnected: (value: boolean) -> (),
}

-- The exported shell. State fields (widget/toolbarButton/frames/statusCard/
-- connected) live on the table so methods read them as `Shell.*`. Methods mirror
-- the monolith Shell.* functions one-for-one with the same behaviour. `widget`,
-- `toolbarButton`, `build`, and `onWidgetEnabled` are the surface the bootstrap
-- wires; the rest are internal view helpers exposed for the SelfTest.
export type ShellModule = {
	-- Mutable view state (held on the table, not a closure — see header).
	widget: DockWidgetPluginGui,
	toolbarButton: PluginToolbarButton,
	mainFrame: Frame?,
	contentFrame: Frame?,
	panelHost: Frame?,
	tabStrip: Frame?,
	settingsFrame: Frame?,
	statusCard: StatusCard?,
	connected: boolean,
	autoConnectGeneration: number,

	-- Build the panel context every panel's build receives.
	makeCtx: () -> ShellContext,

	-- Re-render the tab strip from the Registry's enabled list + selection.
	renderTabStrip: () -> (),

	-- Show / hide the Settings overlay (hides / restores the content frame).
	openSettings: () -> (),
	closeSettings: () -> (),

	-- Build the Settings overlay into `parent` (the main frame).
	buildSettingsOverlay: (parent: Instance) -> (),

	-- Build the whole widget content (header, status card, tab strip, panel host,
	-- settings overlay), select the first enabled tab, render the strip.
	build: () -> (),

	-- Widget-enabled hook: ask the selected (or first enabled) panel to connect.
	onWidgetEnabled: () -> (),
}

-- == Module table ==

-- Single table; methods reach siblings via `Shell.*` (call-time field reads),
-- never via a forward-referenced local. State initialised to the monolith's
-- defaults. `widget`/`toolbarButton` are assigned immediately below (the
-- bootstrap-at-load the monolith ran inline) so the typed fields are never nil
-- after this module returns.
local Shell = {} :: ShellModule
Shell.mainFrame = nil
Shell.contentFrame = nil
Shell.panelHost = nil
Shell.tabStrip = nil
Shell.settingsFrame = nil
Shell.statusCard = nil
Shell.connected = false
Shell.autoConnectGeneration = 0

-- == Widget + toolbar bootstrap (verbatim port, runs at module load) ==

local widgetInfo = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 380, 260, 340, 220)
local widget = pluginHandle:CreateDockWidgetPluginGui("StudioStud", widgetInfo)
widget.Title = "Studio Stud"
Shell.widget = widget

local toolbar = pluginHandle:CreateToolbar("Studio Stud")
local toolbarIcon = if resolvedLogoAssetId ~= "" then resolvedLogoAssetId else DEFAULT_TOOLBAR_ICON
local toolbarOk, toolbarResult = pcall(function(): PluginToolbarButton
	return toolbar:CreateButton("Studio Stud", "Open Studio Stud", toolbarIcon)
end)
if toolbarOk then
	Shell.toolbarButton = toolbarResult
elseif resolvedLogoAssetId ~= "" then
	warn(
		"[Studio Stud] Toolbar icon failed to load. Upload studio-stud-logo.png as an Image (not Decal), then set PLUGIN_LOGO_ASSET_ID. Error:",
		toolbarResult
	)
	Shell.toolbarButton = toolbar:CreateButton("Studio Stud", "Open Studio Stud", DEFAULT_TOOLBAR_ICON)
else
	error("[Studio Stud] Failed to create toolbar button: " .. tostring(toolbarResult))
end
pcall(function()
	Shell.toolbarButton.ClickableWhenViewportHidden = true
end)

-- == Panel context factory ==

function Shell.makeCtx(): ShellContext
	return {
		theme = Theme,
		ui = Ui,
		transport = Transport,
		settings = Settings,
		plugin = pluginHandle,
		widget = Shell.widget,
		setStatus = function(state: string, message: string)
			local card = Shell.statusCard
			if card then
				card.setState(state, message)
			end
		end,
		setStats = function(text: string?)
			local card = Shell.statusCard
			if card then
				card.setStats(text)
			end
		end,
		isConnected = function(): boolean
			return Shell.connected
		end,
		setConnected = function(value: boolean)
			Shell.connected = value
		end,
	}
end

-- == Tab strip ==

function Shell.renderTabStrip(): ()
	local tabStrip = Shell.tabStrip
	if not tabStrip then
		return
	end
	for _, child in ipairs(tabStrip:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end

	local selectedId = Registry.selected()
	local x = 0
	for _, item in ipairs(Registry.list()) do
		if not item.enabled then
			continue
		end
		local tab = Instance.new("TextButton")
		tab.Name = "Tab_" .. item.id
		tab.AutoButtonColor = true
		tab.FontFace = Theme.UI_FONT_BOLD
		tab.TextSize = 12
		tab.Text = item.title
		local tabWidth = math.max(96, #item.title * 7 + 24)
		tab.Size = UDim2.fromOffset(tabWidth, 28)
		tab.Position = UDim2.fromOffset(x, 2)
		tab.Parent = tabStrip
		if item.id == selectedId then
			tab.BackgroundColor3 = Theme.copper
			tab.TextColor3 = Theme.panel
		else
			tab.BackgroundColor3 = Theme.surface
			tab.TextColor3 = Theme.body
			Ui.makeStroke(tab, Theme.surfaceBorder, 1)
		end
		Ui.makeCorner(tab, 6)
		local tabId = item.id
		tab.MouseButton1Click:Connect(function()
			Registry.select(tabId)
		end)
		x += tabWidth + 6
	end
end

-- == Settings overlay show/hide ==

function Shell.openSettings(): ()
	local settingsFrame = Shell.settingsFrame
	if settingsFrame then
		local placeLabel = settingsFrame:FindFirstChild("PlaceLabel", true)
		if placeLabel and placeLabel:IsA("TextLabel") then
			placeLabel.Text = ("Studio: %s  |  PlaceId: %s"):format(game.Name, tostring(game.PlaceId))
		end
		settingsFrame.Visible = true
	end
	local contentFrame = Shell.contentFrame
	if contentFrame then
		contentFrame.Visible = false
	end
end

function Shell.closeSettings(): ()
	local settingsFrame = Shell.settingsFrame
	if settingsFrame then
		settingsFrame.Visible = false
	end
	local contentFrame = Shell.contentFrame
	if contentFrame then
		contentFrame.Visible = true
	end
end

-- == Settings overlay build ==

function Shell.buildSettingsOverlay(parent: Instance): ()
	local frame = Instance.new("Frame")
	frame.Name = "SettingsOverlay"
	frame.BackgroundColor3 = Theme.panel
	frame.BorderSizePixel = 0
	frame.Size = UDim2.fromScale(1, 1)
	frame.Visible = false
	frame.Parent = parent
	Shell.settingsFrame = frame

	local headerH = 48

	local header = Instance.new("Frame")
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, headerH)
	header.Parent = frame

	local backButton = Ui.makeSecondaryButton(header, "Back")
	backButton.Position = UDim2.fromOffset(Theme.PAD, Theme.PAD)
	backButton.Size = UDim2.fromOffset(72, 32)
	backButton.MouseButton1Click:Connect(function()
		Shell.closeSettings()
	end)

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Position = UDim2.fromOffset(96, Theme.PAD + 4)
	title.Size = UDim2.new(1, -110, 0, 24)
	title.FontFace = Theme.TITLE_FONT
	title.TextColor3 = Theme.body
	title.TextSize = 18
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "Settings"
	title.Parent = header

	-- Scrollable content area below the header
	local scroll = Instance.new("ScrollingFrame")
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Position = UDim2.fromOffset(0, headerH)
	scroll.Size = UDim2.new(1, 0, 1, -headerH)
	scroll.ScrollBarThickness = 4
	scroll.ScrollBarImageColor3 = Theme.tealDim
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.CanvasSize = UDim2.fromOffset(0, 0)
	scroll.Parent = frame

	local y = Theme.PAD

	local placeLabel = Ui.makeLabel(scroll, "Studio: loading...", y, 40, Theme.muted)
	placeLabel.Name = "PlaceLabel"
	placeLabel.TextSize = 13
	y += 48

	Ui.makeSectionLabel(scroll, "Daemon endpoint", y)
	y += 18

	local field = Instance.new("Frame")
	field.Position = UDim2.fromOffset(Theme.PAD, y)
	field.Size = UDim2.new(1, -Theme.PAD * 2, 0, 58)
	field.BackgroundColor3 = Theme.surface
	field.BorderSizePixel = 0
	field.Parent = scroll
	Ui.makeCorner(field, 8)
	Ui.makeStroke(field, Theme.surfaceBorder, 1)

	local hostCaption = Instance.new("TextLabel")
	hostCaption.BackgroundTransparency = 1
	hostCaption.Position = UDim2.fromOffset(10, 6)
	hostCaption.Size = UDim2.new(0.55, -10, 0, 12)
	hostCaption.FontFace = Theme.UI_FONT
	hostCaption.TextColor3 = Theme.muted
	hostCaption.TextSize = 10
	hostCaption.TextXAlignment = Enum.TextXAlignment.Left
	hostCaption.Text = "HOST"
	hostCaption.Parent = field

	local host, port = Transport.parseDaemonUrl(Transport.currentUrl())
	local hostBox = Instance.new("TextBox")
	hostBox.BackgroundTransparency = 1
	hostBox.BorderSizePixel = 0
	hostBox.Position = UDim2.fromOffset(10, 20)
	hostBox.Size = UDim2.new(0.55, -14, 0, 28)
	hostBox.ClearTextOnFocus = false
	hostBox.FontFace = Theme.CODE_FONT
	hostBox.TextColor3 = Theme.body
	hostBox.TextSize = 14
	hostBox.TextXAlignment = Enum.TextXAlignment.Left
	hostBox.PlaceholderColor3 = Theme.muted
	hostBox.PlaceholderText = "127.0.0.1"
	hostBox.Text = host
	hostBox.Parent = field

	local portCaption = Instance.new("TextLabel")
	portCaption.BackgroundTransparency = 1
	portCaption.Position = UDim2.new(0.58, 0, 0, 6)
	portCaption.Size = UDim2.new(0.38, -8, 0, 12)
	portCaption.FontFace = Theme.UI_FONT
	portCaption.TextColor3 = Theme.muted
	portCaption.TextSize = 10
	portCaption.TextXAlignment = Enum.TextXAlignment.Left
	portCaption.Text = "PORT"
	portCaption.Parent = field

	local portBox = Instance.new("TextBox")
	portBox.BackgroundTransparency = 1
	portBox.BorderSizePixel = 0
	portBox.Position = UDim2.new(0.58, 0, 0, 20)
	portBox.Size = UDim2.new(0.38, -8, 0, 28)
	portBox.ClearTextOnFocus = false
	portBox.FontFace = Theme.CODE_FONT
	portBox.TextColor3 = Theme.body
	portBox.TextSize = 14
	portBox.TextXAlignment = Enum.TextXAlignment.Left
	portBox.PlaceholderColor3 = Theme.muted
	portBox.PlaceholderText = "31878"
	portBox.Text = port
	portBox.Parent = field

	local function persistEndpoint()
		local url = Transport.buildDaemonUrl(hostBox.Text, portBox.Text)
		Settings.setString(SETTINGS.daemonUrl, url)
	end
	hostBox.FocusLost:Connect(persistEndpoint)
	portBox.FocusLost:Connect(persistEndpoint)
	y += 66

	Ui.makeSectionLabel(scroll, "Live capture", y)
	y += 18
	local liveEnabled = Settings.getBool(SETTINGS.liveCaptureEnabled, true)
	local liveButton = Ui.makeSecondaryButton(scroll, if liveEnabled then "Live capture: ON" else "Live capture: OFF")
	liveButton.Position = UDim2.fromOffset(Theme.PAD, y)
	liveButton.Size = UDim2.new(1, -Theme.PAD * 2, 0, 32)
	liveButton.MouseButton1Click:Connect(function()
		liveEnabled = not liveEnabled
		Settings.setBool(SETTINGS.liveCaptureEnabled, liveEnabled)
		liveButton.Text = if liveEnabled then "Live capture: ON" else "Live capture: OFF"
	end)
	y += 40
	local liveNote = Ui.makeLabel(
		scroll,
		"Auto-starts on plugin load. Signals track changes; full verify every 3 min. Reconnects automatically if daemon restarts.",
		y,
		36,
		Theme.muted
	)
	liveNote.TextSize = 11
	y += 44

	Ui.makeSectionLabel(scroll, "Sync debounce", y)
	y += 18
	local debounceNote = Ui.makeLabel(
		scroll,
		"How often live changes flush to the daemon. Lower = fresher data, higher = lighter on Studio.",
		y,
		28,
		Theme.muted
	)
	debounceNote.TextSize = 11
	y += 32
	Ui.makeMsSlider(scroll, y, DEBOUNCE_MS_MIN, DEBOUNCE_MS_MAX, Settings.getDebounceMs(), function(ms: number)
		Settings.setDebounceMs(ms)
	end)
	y += 64

	Ui.makeSectionLabel(scroll, "Debug logging", y)
	y += 18
	local debugEnabled = Settings.getBool(SETTINGS.debugLogging, false)
	local debugButton = Ui.makeSecondaryButton(scroll, if debugEnabled then "Debug logs: ON" else "Debug logs: OFF")
	debugButton.Position = UDim2.fromOffset(Theme.PAD, y)
	debugButton.Size = UDim2.new(1, -Theme.PAD * 2, 0, 32)
	debugButton.MouseButton1Click:Connect(function()
		debugEnabled = not debugEnabled
		Settings.setBool(SETTINGS.debugLogging, debugEnabled)
		debugButton.Text = if debugEnabled then "Debug logs: ON" else "Debug logs: OFF"
	end)
	y += 48

	Ui.makeSectionLabel(scroll, "Addon plugins", y)
	y += 18
	local addonsNote = Ui.makeLabel(
		scroll,
		"Bundled addons install into your Roblox Plugins folder for this repo. Reload Studio if a panel does not appear.",
		y,
		36,
		Theme.muted
	)
	addonsNote.TextSize = 11
	y += 40
	local addonsList = Instance.new("Frame")
	addonsList.Name = "AddonsList"
	addonsList.BackgroundTransparency = 1
	addonsList.Position = UDim2.fromOffset(Theme.PAD, y)
	addonsList.Size = UDim2.new(1, -Theme.PAD * 2, 0, 28)
	addonsList.Parent = scroll

	local function renderAddons()
		for _, child in ipairs(addonsList:GetChildren()) do
			child:Destroy()
		end
		local placeId = 0
		pcall(function()
			placeId = game.PlaceId
		end)
		local okCtx, ctx = Transport.requestJson("GET", "/studio-stud/context?placeId=" .. tostring(placeId), nil)
		if okCtx and type(ctx) == "table" and ctx.status == "unbound" then
			local hint = Ui.makeLabel(addonsList, "Place not bound to a repo — open installer or bind in daemon.", 0, 40, Theme.muted)
			hint.TextSize = 11
			addonsList.Size = UDim2.new(1, -Theme.PAD * 2, 0, 44)
			return
		end
		local ok, result = Transport.requestJson("GET", "/studio-stud/addons?placeId=" .. tostring(placeId), nil)
		if not ok or type(result) ~= "table" or type(result.addons) ~= "table" then
			local err = Ui.makeLabel(addonsList, "Could not load addons (is `studio-stud serve` running?)", 0, 32, Theme.muted)
			err.TextSize = 11
			addonsList.Size = UDim2.new(1, -Theme.PAD * 2, 0, 36)
			return
		end
		local rowY = 0
		for _, addon in ipairs(result.addons) do
			local id = addon.id
			local enabled = addon.enabled == true
			local row = Instance.new("Frame")
			row.BackgroundTransparency = 1
			row.Size = UDim2.new(1, 0, 0, 28)
			row.Position = UDim2.fromOffset(0, rowY)
			row.Parent = addonsList
			local nameLabel = Instance.new("TextLabel")
			nameLabel.BackgroundTransparency = 1
			nameLabel.Size = UDim2.fromScale(0.65, 1)
			nameLabel.FontFace = Theme.UI_FONT
			nameLabel.TextColor3 = Theme.body
			nameLabel.TextSize = 13
			nameLabel.TextXAlignment = Enum.TextXAlignment.Left
			nameLabel.Text = tostring(id)
			nameLabel.Parent = row
			local toggle = Ui.makeSecondaryButton(row, if enabled then "Enabled" else "Disabled")
			toggle.Size = UDim2.fromScale(0.32, 1)
			toggle.Position = UDim2.fromScale(0.68, 0)
			toggle.MouseButton1Click:Connect(function()
				local path = if enabled then "/studio-stud/addons/disable" else "/studio-stud/addons/enable"
				local okW, res = Transport.requestJsonAuthed("POST", path, {
					id = id,
					placeId = placeId,
				})
				if not okW then
					warn("[StudioStud] addon toggle failed:", res)
				end
				renderAddons()
			end)
			toggle.Parent = row
			rowY += 32
		end
		addonsList.Size = UDim2.new(1, -Theme.PAD * 2, 0, math.max(rowY, 28))
	end
	renderAddons()
	y += 120

	Ui.makeSectionLabel(scroll, "Tabs", y)
	y += 18
	local tabsList = Instance.new("Frame")
	tabsList.Name = "TabsList"
	tabsList.BackgroundTransparency = 1
	tabsList.Position = UDim2.fromOffset(Theme.PAD, y)
	tabsList.Size = UDim2.new(1, -Theme.PAD * 2, 0, 28)
	tabsList.Parent = scroll

	local function renderPanelToggles()
		for _, child in ipairs(tabsList:GetChildren()) do
			child:Destroy()
		end
		local rowY = 0
		for _, item in ipairs(Registry.list()) do
			local row = Instance.new("Frame")
			row.BackgroundTransparency = 1
			row.Size = UDim2.new(1, 0, 0, 28)
			row.Position = UDim2.fromOffset(0, rowY)
			row.Parent = tabsList

			local nameLabel = Instance.new("TextLabel")
			nameLabel.BackgroundTransparency = 1
			nameLabel.Size = UDim2.fromScale(0.65, 1)
			nameLabel.FontFace = Theme.UI_FONT
			nameLabel.TextColor3 = Theme.body
			nameLabel.TextSize = 13
			nameLabel.TextXAlignment = Enum.TextXAlignment.Left
			nameLabel.Text = item.title
			nameLabel.Parent = row

			local panelId = item.id
			local toggle = Ui.makeSecondaryButton(row, if item.enabled then "Enabled" else "Disabled")
			toggle.Size = UDim2.fromScale(0.32, 1)
			toggle.Position = UDim2.fromScale(0.68, 0)
			toggle.MouseButton1Click:Connect(function()
				local newValue = not Settings.getPanelEnabled(panelId, item.defaultEnabled ~= false)
				Registry.setEnabled(panelId, newValue)
				renderPanelToggles()
			end)
			toggle.Parent = row
			rowY += 32
		end
		tabsList.Size = UDim2.new(1, -Theme.PAD * 2, 0, math.max(rowY, 28))
	end
	renderPanelToggles()
	y += 160

	Ui.makeLabel(
		scroll,
		"Setup:\n1. Run `studio-stud.exe serve` and leave it open.\n2. Enable Studio HTTP requests (Game Settings → Security).\n3. Approve localhost if Studio prompts.\n4. Plugin connects and captures automatically on open.",
		y,
		100,
		Theme.muted
	).TextSize = 12
end

-- == Main frame build ==

function Shell.build(): ()
	Shell.widget:ClearAllChildren()
	Registry.teardownAll()
	Shell.connected = false

	local mainFrame = Instance.new("Frame")
	mainFrame.BackgroundColor3 = Theme.panel
	mainFrame.BorderSizePixel = 0
	mainFrame.Size = UDim2.fromScale(1, 1)
	mainFrame.Parent = Shell.widget
	Shell.mainFrame = mainFrame

	local topRule = Instance.new("Frame")
	topRule.BackgroundColor3 = Theme.copperDim
	topRule.BorderSizePixel = 0
	topRule.Size = UDim2.new(1, 0, 0, 2)
	topRule.Parent = mainFrame

	local contentFrame = Instance.new("Frame")
	contentFrame.BackgroundTransparency = 1
	contentFrame.Position = UDim2.fromOffset(0, 2)
	contentFrame.Size = UDim2.new(1, 0, 1, -2)
	contentFrame.Parent = mainFrame
	Shell.contentFrame = contentFrame

	local header = Instance.new("Frame")
	header.BackgroundTransparency = 1
	header.Position = UDim2.fromOffset(Theme.PAD, Theme.PAD)
	header.Size = UDim2.new(1, -Theme.PAD * 2, 0, 52)
	header.Parent = contentFrame

	Ui.makeBrandBadge(header).Position = UDim2.fromOffset(0, 0)

	local titleBlock = Instance.new("Frame")
	titleBlock.BackgroundTransparency = 1
	titleBlock.Position = UDim2.fromOffset(46, 0)
	titleBlock.Size = UDim2.new(1, -120, 1, 0)
	titleBlock.Parent = header

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0, 24)
	title.FontFace = Theme.TITLE_FONT
	title.TextColor3 = Theme.copper
	title.TextSize = 20
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Text = "Studio Stud"
	title.Parent = titleBlock

	local subtitle = Instance.new("TextLabel")
	subtitle.BackgroundTransparency = 1
	subtitle.Position = UDim2.fromOffset(0, 24)
	subtitle.Size = UDim2.new(1, 0, 0, 16)
	subtitle.FontFace = Theme.UI_FONT
	subtitle.TextColor3 = Theme.muted
	subtitle.TextSize = 12
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.Text = "Live place inspector · v" .. PLUGIN_VERSION
	subtitle.Parent = titleBlock

	local versionLabel = Instance.new("TextLabel")
	versionLabel.BackgroundTransparency = 1
	versionLabel.AnchorPoint = Vector2.new(1, 0)
	versionLabel.Position = UDim2.new(1, 0, 0, 2)
	versionLabel.Size = UDim2.fromOffset(56, 18)
	versionLabel.FontFace = Theme.CODE_FONT
	versionLabel.TextColor3 = Theme.muted
	versionLabel.TextSize = 11
	versionLabel.TextXAlignment = Enum.TextXAlignment.Right
	versionLabel.Text = "v" .. PLUGIN_VERSION
	versionLabel.Parent = header

	local settingsButton = Ui.makeSecondaryButton(header, "Settings")
	settingsButton.AnchorPoint = Vector2.new(1, 0)
	settingsButton.Position = UDim2.fromScale(1, 0)
	settingsButton.Size = UDim2.fromOffset(72, 32)
	settingsButton.MouseButton1Click:Connect(function()
		Shell.openSettings()
	end)

	local STATUS_CARD_H = 54
	local statusCard = Ui.makeStatusCard(contentFrame, Theme.PAD + 52 + 8)
	statusCard.setState("idle", "Waiting for daemon")
	Shell.statusCard = statusCard

	local tabStrip = Instance.new("Frame")
	tabStrip.Name = "TabStrip"
	tabStrip.BackgroundTransparency = 1
	tabStrip.Position = UDim2.fromOffset(Theme.PAD, Theme.PAD + 52 + 8 + STATUS_CARD_H + 8)
	tabStrip.Size = UDim2.new(1, -Theme.PAD * 2, 0, 32)
	tabStrip.Parent = contentFrame
	Shell.tabStrip = tabStrip

	local panelTop = Theme.PAD + 52 + 8 + STATUS_CARD_H + 8 + 32 + 8
	local panelHost = Instance.new("Frame")
	panelHost.Name = "PanelHost"
	panelHost.BackgroundTransparency = 1
	panelHost.Position = UDim2.fromOffset(0, panelTop)
	panelHost.Size = UDim2.new(1, 0, 1, -panelTop)
	panelHost.Parent = contentFrame
	Shell.panelHost = panelHost

	Registry.setHost(panelHost, Shell.makeCtx, Shell.renderTabStrip)
	Shell.buildSettingsOverlay(mainFrame)

	local firstId = Registry.firstEnabledId()
	if firstId then
		Registry.select(firstId)
	end
	Shell.renderTabStrip()
end

-- == Widget-enabled hook ==

function Shell.onWidgetEnabled(): ()
	Shell.autoConnectGeneration += 1
	local myGeneration = Shell.autoConnectGeneration

	local function requestConnect(): any
		local selectedId = Registry.selected()
		if selectedId then
			local handle = Registry.getHandle(selectedId)
			if handle and handle.onConnectRequested then
				return handle.onConnectRequested()
			end
		else
			local firstId = Registry.firstEnabledId()
			if firstId then
				Registry.select(firstId)
				local handle = Registry.getHandle(firstId)
				if handle and handle.onConnectRequested then
					return handle.onConnectRequested()
				end
			end
		end
		return nil
	end

	local result = requestConnect()
	if result and result.ok then
		return
	end

	-- Daemon may start after the plugin; retry with backoff without blocking the frame.
	task.spawn(function()
		local delays = { 2, 2, 2, 2, 2 }
		for _, delay in delays do
			if Shell.autoConnectGeneration ~= myGeneration or not Shell.widget.Enabled then
				return
			end
			task.wait(delay)
			if Shell.autoConnectGeneration ~= myGeneration or not Shell.widget.Enabled then
				return
			end
			local retryResult = requestConnect()
			if retryResult and retryResult.ok then
				return
			end
		end
	end)
end

return Shell
