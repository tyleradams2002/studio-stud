-- Studio Stud
--
-- Studio plugin source. Publish this as a reusable team plugin after local
-- testing. The plugin is read-only: it exports live Studio DataModel metadata
-- to a local daemon for AI review.

-- Plugin-only guard. This file MUST run as a Studio plugin (loaded from the Plugins
-- folder), where the `plugin` global exists. If a copy of this source is ever embedded
-- in a place (e.g. pasted into Workspace as a Script and saved), it would otherwise run
-- inside the running game's Server/Client DataModels during a playtest and capture the
-- live game. When `plugin` is nil we are NOT a plugin — bail out immediately.
if not plugin then
	warn(
		"[StudioStud] This is a Studio plugin, not a game script. Install it via the Roblox "
			.. "Plugins folder and remove any embedded copy (e.g. Workspace.Script) from the place."
	)
	return
end

local HttpService = game:GetService("HttpService")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

-- == Session mode (edit vs play) ==
-- Studio Stud must talk to the daemon ONLY during a genuine edit session. Code running in a
-- play/run DataModel (Play Solo / F8 Run, or a stray copy embedded in the place) reports
-- IsRunning()=true / IsEdit()=false and is gated to "play". The real plugin runs in the edit
-- DataModel; during an F5 playtest (a separate DataModel) it stays "edit" and never sees the
-- running game, so there is nothing to capture there.
-- decide() is a PURE function so its truth table stays unit-testable in SelfTest.
local Session = {}
function Session.signals()
	return {
		isEdit = RunService:IsEdit(),
		isRunning = RunService:IsRunning(),
	}
end
function Session.decide(sig)
	return (sig.isEdit and not sig.isRunning) and "edit" or "play"
end
function Session.mode()
	return Session.decide(Session.signals())
end
function Session.isEdit()
	return Session.mode() == "edit"
end

-- == Config ==

local PLUGIN_VERSION = "0.4.17"
local PLUGIN_LOGO_ASSET_ID = ""
local PROTOCOL_VERSION = 1
-- Minimum daemon protocol this plugin can talk to. Half of the mutual version
-- handshake: the daemon advertises minPluginProtocolVersion, the plugin enforces
-- MIN_DAEMON_PROTOCOL_VERSION, so each side can tell the user which one is behind.
local MIN_DAEMON_PROTOCOL_VERSION = 1
-- Channel-aware install one-liner for the "update available" nudge. The daemon ping reports the
-- machine's channel; dev/beta point at their own bootstrap so following the hint never silently
-- switches the user onto release.
local function updateInstallHint(channel: any): string
	local script = "install.ps1"
	if channel == "dev" then
		script = "install-dev.ps1"
	end
	return ("irm https://tyleradams2002.github.io/studio-stud/%s | iex"):format(script)
end
local DEFAULT_TOOLBAR_ICON = "rbxassetid://14978048121"
local SERVICE_NAME = "studio-stud"
local DEFAULT_DAEMON_URL = "http://127.0.0.1:31878"
local WELCOME_VERSION = "2026-06-01-stage1-v1"

local SETTINGS = {
	daemonUrl = "StudioStudDaemonUrl",
	welcomeVersion = "StudioStudWelcomeVersion",
	liveCaptureEnabled = "StudioStudLiveCaptureEnabled",
	debounceMs = "StudioStudDebounceMs",
	debugLogging = "StudioStudDebugLogging",
	panelEnabled = "StudioStudPanelEnabled",
	writeToken = "StudioStudWriteToken",
}

local DEBOUNCE_MS_MIN = 100
local DEBOUNCE_MS_MAX = 1000
local DEBOUNCE_MS_DEFAULT = 300

local function normalizePluginAssetId(raw: string): string
	raw = string.gsub(raw or "", "^%s+", "")
	raw = string.gsub(raw, "%s+$", "")
	if raw == "" then
		return ""
	end
	local numeric = raw:match("^(%d+)$")
	if numeric then
		return "rbxassetid://" .. numeric
	end
	if string.find(raw, "^rbxassetid://", 1, true) or string.find(raw, "^rbxasset://", 1, true) then
		return raw
	end
	return ""
end

local resolvedLogoAssetId = normalizePluginAssetId(PLUGIN_LOGO_ASSET_ID)

-- Update nudge comes from daemon /studio-stud/ping (channel-aware). Best-effort; never throws.
-- State is bundled in one table to keep module-scope locals low (Luau 200-register limit).
local updateCheck = { at = 0, note = "", done = false }
local function checkRemoteUpdate(pingResult: any): string
	local now = os.time()
	if updateCheck.done and (now - updateCheck.at) < 86400 then
		return updateCheck.note
	end
	updateCheck.done = true
	updateCheck.at = now
	updateCheck.note = ""

	if type(pingResult) ~= "table" then
		return updateCheck.note
	end
	if pingResult.onFallback == true then
		return updateCheck.note
	end
	if pingResult.updateAvailable ~= true then
		return updateCheck.note
	end
	local notes = {}
	if type(pingResult.latestPluginVersion) == "string"
		and pingResult.latestPluginVersion ~= ""
		and pingResult.latestPluginVersion ~= PLUGIN_VERSION
	then
		notes[#notes + 1] = ("plugin %s"):format(pingResult.latestPluginVersion)
	end
	if type(pingResult.latestDaemonVersion) == "string" and pingResult.latestDaemonVersion ~= "" then
		notes[#notes + 1] = ("daemon %s"):format(pingResult.latestDaemonVersion)
	end
	if #notes > 0 then
		updateCheck.note = "Update available: " .. table.concat(notes, ", ")
	end
	return updateCheck.note
end

local ROOT_SERVICE_ORDER = {
	"Workspace",
	"ServerStorage",
	"Lighting",
	"SoundService",
	"ReplicatedStorage",
	"ReplicatedFirst",
	"ServerScriptService",
	"StarterGui",
	"StarterPlayer",
	"StarterPack",
	"AssetService",
	"AvatarSettings",
	"Chat",
	"CollectionService",
	"ConfigureServerService",
	"ContextActionService",
	"CookiesService",
	"CSGDictionaryService",
	"Debris",
	"GamePassService",
	"GuidRegistryService",
	"HttpService",
	"InsertService",
	"LocalizationService",
	"LodDataService",
	"LuaWebService",
	"MaterialService",
	"NonReplicatedCSGDictionaryService",
	"Packages",
	"PermissionsService",
	"PhysicsService",
	"PlayerEmulatorService",
	"Players",
	"ProximityPromptService",
	"ScriptService",
	"Selection",
	"SerializationService",
	"ServiceVisibilityService",
	"StudioData",
	"Teams",
	"TeleportService",
	"TestService",
	"TextChatService",
	"TimerService",
	"TouchInputService",
	"TweenService",
	"UGCAvatarService",
	"VideoCaptureService",
	"VideoService",
	"VoiceChatService",
	"VRService",
}

local ROOT_SERVICE_INDEX = {}
for index, serviceName in ipairs(ROOT_SERVICE_ORDER) do
	ROOT_SERVICE_INDEX[serviceName] = index
end

local DESCENDANT_ROOT_SERVICES = {
	Workspace = true,
	ServerStorage = true,
	Lighting = true,
	SoundService = true,
	ReplicatedStorage = true,
	ReplicatedFirst = true,
	ServerScriptService = true,
	StarterGui = true,
	StarterPlayer = true,
	StarterPack = true,
	AvatarSettings = true,
	Chat = true,
	MaterialService = true,
	TextChatService = true,
}

local CLASS_PROPERTIES = {
	BasePart = {
		"CFrame",
		"Size",
		"Color",
		"Material",
		"MaterialVariant",
		"Anchored",
		"CanCollide",
		"CanTouch",
		"CanQuery",
		"CollisionGroup",
		"Transparency",
		"Reflectance",
		"CastShadow",
		"Massless",
	},
	MeshPart = {
		"MeshId",
		"TextureID",
		"RenderFidelity",
		"CollisionFidelity",
	},
	UnionOperation = {
		"RenderFidelity",
		"CollisionFidelity",
	},
	Model = {
		"PrimaryPart",
		"ModelStreamingMode",
		"LevelOfDetail",
	},
	Attachment = {
		"CFrame",
		"Position",
		"Orientation",
		"Axis",
		"SecondaryAxis",
	},
	ProximityPrompt = {
		"ActionText",
		"ObjectText",
		"Enabled",
		"HoldDuration",
		"MaxActivationDistance",
		"RequiresLineOfSight",
		"KeyboardKeyCode",
		"GamepadKeyCode",
		"Style",
	},
	Beam = {
		"Attachment0",
		"Attachment1",
		"Enabled",
		"Texture",
		"Color",
		"Transparency",
		"Width0",
		"Width1",
		"LightEmission",
		"LightInfluence",
		"Brightness",
	},
	Trail = {
		"Attachment0",
		"Attachment1",
		"Enabled",
		"Texture",
		"Color",
		"Transparency",
		"Lifetime",
		"LightEmission",
	},
	ParticleEmitter = {
		"Enabled",
		"Texture",
		"Color",
		"Transparency",
		"Size",
		"Rate",
		"Lifetime",
		"LightEmission",
		"LightInfluence",
		"Speed",
	},
	PointLight = {
		"Enabled",
		"Brightness",
		"Range",
		"Shadows",
		"Color",
	},
	SpotLight = {
		"Enabled",
		"Brightness",
		"Range",
		"Angle",
		"Shadows",
		"Color",
	},
	SurfaceLight = {
		"Enabled",
		"Brightness",
		"Range",
		"Angle",
		"Shadows",
		"Color",
	},
	Sound = {
		"SoundId",
		"Volume",
		"Looped",
		"RollOffMode",
		"RollOffMaxDistance",
		"RollOffMinDistance",
		"EmitterSize",
	},
	Decal = { "Texture", "Transparency", "Color3" },
	Texture = { "Texture", "Transparency", "Color3", "OffsetStudsU", "OffsetStudsV", "StudsPerTileU", "StudsPerTileV" },
	SurfaceAppearance = { "ColorMap", "MetalnessMap", "NormalMap", "RoughnessMap", "AlphaMode" },
	SpecialMesh = { "MeshId", "TextureId", "MeshType", "Scale", "Offset", "VertexColor" },
	Script = { "Enabled", "Disabled", "LinkedSource" },
	LocalScript = { "Enabled", "Disabled", "LinkedSource" },
	ModuleScript = { "LinkedSource" },
	-- Joints
	Motor6D = { "C0", "C1", "Part0", "Part1", "MaxVelocity", "CurrentAngle" },
	Motor = { "C0", "C1", "Part0", "Part1", "MaxVelocity", "CurrentAngle" },
	Weld = { "C0", "C1", "Part0", "Part1" },
	WeldConstraint = { "Part0", "Part1", "Enabled" },
	RigidConstraint = { "Attachment0", "Attachment1", "Enabled" },
	-- Physics constraints
	HingeConstraint = {
		"Attachment0", "Attachment1", "Enabled",
		"LimitsEnabled", "UpperAngle", "LowerAngle",
		"ActuatorType", "AngularVelocity", "MotorMaxAcceleration", "MotorMaxTorque",
		"Restitution", "Stiffness", "Damping",
	},
	BallSocketConstraint = {
		"Attachment0", "Attachment1", "Enabled",
		"LimitsEnabled", "UpperAngle",
		"TwistLimitsEnabled", "TwistUpperAngle", "TwistLowerAngle",
		"Restitution",
	},
	RodConstraint = {
		"Attachment0", "Attachment1", "Enabled",
		"Length", "Thickness", "LimitsEnabled", "UpperAngle", "LowerAngle",
	},
	RopeConstraint = {
		"Attachment0", "Attachment1", "Enabled",
		"Length", "Thickness", "Restitution",
	},
	SpringConstraint = {
		"Attachment0", "Attachment1", "Enabled",
		"Coils", "Stiffness", "Damping", "FreeLength",
		"LimitsEnabled", "MaxLength", "MinLength",
	},
	AlignPosition = {
		"Attachment0", "Attachment1", "Enabled",
		"MaxForce", "MaxVelocity", "Responsiveness", "RigidityEnabled", "Mode",
	},
	AlignOrientation = {
		"Attachment0", "Attachment1", "Enabled",
		"MaxAngularVelocity", "MaxTorque", "Responsiveness", "RigidityEnabled", "Mode",
	},
	AngularVelocity = { "Attachment", "Enabled", "MaxTorque", "RelativeTo", "AngularVelocity" },
	LinearVelocity = { "Attachment", "Enabled", "MaxForce", "RelativeTo", "VectorVelocity" },
	VectorForce = { "Attachment", "Enabled", "Force", "RelativeTo" },
	Torque = { "Attachment", "Enabled", "Torque", "RelativeTo" },
	-- Humanoid / character
	Humanoid = {
		"WalkSpeed", "JumpPower", "MaxHealth", "Health",
		"RigType", "AutoJumpEnabled", "AutoRotate",
		"DisplayDistanceType", "HealthDisplayType",
		"NameDisplayDistance", "HealthDisplayDistance",
		"HipHeight", "BreakJointsOnDeath", "RequiresNeck",
	},
	-- Animation
	Animation = { "AnimationId" },
	-- Value instances
	StringValue = { "Value" },
	IntValue = { "Value" },
	NumberValue = { "Value" },
	BoolValue = { "Value" },
	ObjectValue = { "Value" },
	Vector3Value = { "Value" },
	CFrameValue = { "Value" },
	Color3Value = { "Value" },
	IntConstrainedValue = { "Value", "MinValue", "MaxValue" },
	DoubleConstrainedValue = { "Value", "MinValue", "MaxValue" },
	-- Interactive
	ClickDetector = { "MaxActivationDistance", "CursorIcon" },
	Tool = { "CanBeDropped", "Enabled", "ManualActivationOnly", "RequiresHandle", "TextureId", "ToolTip", "Grip" },
	Seat = { "Disabled" },
	VehicleSeat = { "Disabled", "Steer", "Throttle", "MaxSpeed", "Torque", "TurnSpeed", "HeadsUpDisplay" },
	-- Camera
	Camera = { "CFrame", "FieldOfView", "Focus", "HeadLocked" },
	-- Base GUI object — applies to all GuiObject subclasses via IsA
	GuiObject = {
		"Visible", "Size", "Position", "AnchorPoint",
		"BackgroundColor3", "BackgroundTransparency",
		"BorderColor3", "BorderSizePixel", "BorderMode",
		"ZIndex", "LayoutOrder", "ClipsDescendants",
		"Rotation", "AutomaticSize", "Active", "Selectable", "SizeConstraint",
	},
	-- GUI layers (not GuiObject subclasses — need explicit entries)
	ScreenGui = { "Enabled", "ResetOnSpawn", "ZIndexBehavior", "IgnoreGuiInset", "DisplayOrder", "OnTopOfCoreBlur" },
	BillboardGui = {
		"Enabled", "Size", "StudsOffset", "StudsOffsetWorldSpace",
		"AlwaysOnTop", "MaxDistance", "LightInfluence", "Brightness", "Active", "Adornee",
	},
	SurfaceGui = {
		"Enabled", "Face", "LightInfluence", "MaxDistance", "PixelsPerStud",
		"AlwaysOnTop", "CanvasSize", "Active", "Adornee", "ZIndexBehavior",
	},
	-- Text GUI
	TextLabel = {
		"Text", "TextColor3", "TextScaled", "TextSize", "TextTransparency",
		"TextWrapped", "TextXAlignment", "TextYAlignment",
		"FontFace", "RichText", "LineHeight", "TextStrokeColor3", "TextStrokeTransparency",
	},
	TextButton = {
		"Text", "TextColor3", "TextScaled", "TextSize", "TextTransparency",
		"TextWrapped", "TextXAlignment", "TextYAlignment",
		"FontFace", "RichText", "AutoButtonColor", "LineHeight",
	},
	TextBox = {
		"Text", "TextColor3", "TextScaled", "TextSize", "TextTransparency",
		"TextWrapped", "TextXAlignment", "TextYAlignment",
		"FontFace", "PlaceholderColor3", "PlaceholderText", "ClearTextOnFocus", "MultiLine",
	},
	-- Image GUI
	ImageLabel = {
		"Image", "ImageColor3", "ImageTransparency", "ScaleType",
		"SliceScale", "SliceCenter", "TileSize", "ImageRectOffset", "ImageRectSize",
	},
	ImageButton = {
		"Image", "ImageColor3", "ImageTransparency", "ScaleType",
		"HoverImage", "PressedImage", "AutoButtonColor",
	},
	-- Scroll
	ScrollingFrame = {
		"ScrollBarThickness", "ScrollingEnabled", "ScrollingDirection",
		"CanvasPosition", "CanvasSize",
		"ScrollBarImageColor3", "ScrollBarImageTransparency",
		"AutomaticCanvasSize", "ElasticBehavior",
	},
	-- UI layout
	UIListLayout = { "SortOrder", "FillDirection", "WrapsItems", "HorizontalAlignment", "VerticalAlignment", "Padding" },
	UIGridLayout = {
		"SortOrder", "FillDirection", "HorizontalAlignment", "VerticalAlignment",
		"CellPadding", "CellSize", "FillDirectionMaxCells", "StartCorner",
	},
	UITableLayout = {
		"SortOrder", "FillDirection", "FillEmptySpaceColumns", "FillEmptySpaceRows",
		"HorizontalAlignment", "VerticalAlignment", "MajorAxis", "Padding",
	},
	UIPadding = { "PaddingBottom", "PaddingLeft", "PaddingRight", "PaddingTop" },
	UICorner = { "CornerRadius" },
	UIStroke = { "Color", "Thickness", "Transparency", "ApplyStrokeMode", "LineJoinMode", "Enabled" },
	UIScale = { "Scale" },
	UIAspectRatioConstraint = { "AspectRatio", "AspectType", "DominantAxis" },
	UISizeConstraint = { "MaxSize", "MinSize" },
	UITextSizeConstraint = { "MaxTextSize", "MinTextSize" },
	UIFlexItem = { "FlexMode", "GrowRatio", "ShrinkRatio" },
	-- Lighting / atmosphere / post-processing
	Lighting = {
		"Ambient", "Brightness", "ColorShift_Bottom", "ColorShift_Top",
		"EnvironmentDiffuseScale", "EnvironmentSpecularScale", "ExposureCompensation",
		"FogColor", "FogEnd", "FogStart", "GeographicLatitude",
		"OutdoorAmbient", "ShadowSoftness", "Technology", "ClockTime",
	},
	Atmosphere = { "Density", "Offset", "Color", "Decay", "Glare", "Haze" },
	Sky = {
		"SkyboxBk", "SkyboxDn", "SkyboxFt", "SkyboxLf", "SkyboxRt", "SkyboxUp",
		"SunAngularSize", "MoonAngularSize", "MoonTextureId", "StarCount", "CelestialBodiesShown",
	},
	BloomEffect = { "Enabled", "Intensity", "Size", "Threshold" },
	BlurEffect = { "Enabled", "Size" },
	ColorCorrectionEffect = { "Enabled", "Brightness", "Contrast", "Saturation", "TintColor" },
	DepthOfFieldEffect = { "Enabled", "FarIntensity", "FocusDistance", "InFocusRadius", "NearIntensity" },
	SunRaysEffect = { "Enabled", "Intensity", "Spread" },
	-- Sound
	SoundGroup = { "Volume" },
	-- Workspace
	Workspace = { "Gravity", "GlobalWind" },
}

-- == Theme ==

local Theme = {
	panel = Color3.fromRGB(10, 20, 30),
	surface = Color3.fromRGB(18, 34, 48),
	surfaceBorder = Color3.fromRGB(42, 72, 92),
	copper = Color3.fromRGB(196, 142, 72),
	copperDim = Color3.fromRGB(140, 100, 52),
	teal = Color3.fromRGB(72, 168, 152),
	tealDim = Color3.fromRGB(48, 110, 100),
	muted = Color3.fromRGB(118, 142, 158),
	body = Color3.fromRGB(224, 236, 244),
	warn = Color3.fromRGB(232, 178, 108),
	badge = Color3.fromRGB(32, 88, 108),
	CODE_FONT = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Regular),
	UI_FONT = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Regular),
	UI_FONT_BOLD = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold),
	TITLE_FONT = Font.new("rbxasset://fonts/families/Merriweather.json", Enum.FontWeight.Bold),
	PAD = 14,
}

-- == Ui ==

local Ui = {}

function Ui.makeCorner(parent, radius)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or 8)
	corner.Parent = parent
	return corner
end

function Ui.makeStroke(parent, color, thickness)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness or 1
	stroke.Parent = parent
	return stroke
end

function Ui.makeLabel(parent, text, y, height, textColor)
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

function Ui.makeSectionLabel(parent, text, y)
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

function Ui.makePrimaryButton(parent, text)
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

function Ui.makeSecondaryButton(parent, text)
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

-- Horizontal ms slider (integer steps). Calls onChanged(ms) when the value settles/changes.
function Ui.makeMsSlider(parent, y, minMs, maxMs, initialMs, onChanged)
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

	local function alphaForMs(ms)
		return (ms - minMs) / (maxMs - minMs)
	end

	local function msFromAlpha(alpha)
		return math.clamp(minMs + math.clamp(alpha, 0, 1) * (maxMs - minMs), minMs, maxMs)
	end

	local function applyMs(ms, persist)
		currentMs = math.clamp(math.floor(ms + 0.5), minMs, maxMs)
		local alpha = alphaForMs(currentMs)
		fill.Size = UDim2.new(alpha, 0, 1, 0)
		knob.Position = UDim2.new(alpha, 0, 0.5, 0)
		valueLabel.Text = tostring(currentMs) .. " ms"
		if persist and onChanged then
			onChanged(currentMs)
		end
	end

	local function updateFromScreenX(screenX)
		local trackX = track.AbsolutePosition.X
		local trackWidth = track.AbsoluteSize.X
		if trackWidth <= 0 then
			return
		end
		applyMs(msFromAlpha((screenX - trackX) / trackWidth), true)
	end

	local function beginDrag(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			updateFromScreenX(input.Position.X)
		end
	end

	track.InputBegan:Connect(beginDrag)
	knob.InputBegan:Connect(beginDrag)

	UserInputService.InputChanged:Connect(function(input)
		if not dragging then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			updateFromScreenX(input.Position.X)
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)

	applyMs(currentMs, false)

	return {
		setValue = function(ms)
			applyMs(ms, false)
		end,
		getValue = function()
			return currentMs
		end,
	}
end

function Ui.makeStatusCard(parent, y)
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

	local function setState(state, message)
		statusLabel.Text = message
		if state == "connected" then
			dot.BackgroundColor3 = Theme.teal
			stripe.BackgroundColor3 = Theme.teal
			statusLabel.TextColor3 = Theme.body
		elseif state == "syncing" then
			dot.BackgroundColor3 = Theme.copper
			stripe.BackgroundColor3 = Theme.copper
			statusLabel.TextColor3 = Theme.body
		elseif state == "error" then
			dot.BackgroundColor3 = Theme.warn
			stripe.BackgroundColor3 = Theme.warn
			statusLabel.TextColor3 = Theme.warn
		else
			dot.BackgroundColor3 = Theme.muted
			stripe.BackgroundColor3 = Theme.tealDim
			statusLabel.TextColor3 = Theme.muted
		end
	end

	local function setStats(text)
		statsLabel.Text = text or ""
	end

	return { frame = card, setState = setState, setStats = setStats }
end

function Ui.makeVectorLogo(parent, size)
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

function Ui.makeBrandBadge(parent)
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

-- == Settings ==

local Settings = {}

function Settings.getString(key, defaultValue)
	local ok, value = pcall(function()
		return plugin:GetSetting(key)
	end)
	if ok and typeof(value) == "string" and value ~= "" then
		return value
	end
	return defaultValue
end

function Settings.setString(key, value)
	pcall(function()
		plugin:SetSetting(key, value)
	end)
end

function Settings.getBool(key, defaultValue)
	local ok, value = pcall(function()
		return plugin:GetSetting(key)
	end)
	if ok and typeof(value) == "boolean" then
		return value
	end
	return defaultValue
end

function Settings.setBool(key, value)
	pcall(function()
		plugin:SetSetting(key, value)
	end)
end

function Settings.getNumber(key, defaultValue)
	local ok, value = pcall(function()
		return plugin:GetSetting(key)
	end)
	if ok and typeof(value) == "number" then
		return value
	end
	return defaultValue
end

function Settings.setNumber(key, value)
	pcall(function()
		plugin:SetSetting(key, value)
	end)
end

function Settings.getDebounceMs()
	local value = Settings.getNumber(SETTINGS.debounceMs, DEBOUNCE_MS_DEFAULT)
	return math.clamp(math.floor(value + 0.5), DEBOUNCE_MS_MIN, DEBOUNCE_MS_MAX)
end

function Settings.setDebounceMs(value)
	Settings.setNumber(SETTINGS.debounceMs, math.clamp(math.floor(value + 0.5), DEBOUNCE_MS_MIN, DEBOUNCE_MS_MAX))
end

function Settings.getPanelEnabledMap()
	local raw = Settings.getString(SETTINGS.panelEnabled, "{}")
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if ok and type(decoded) == "table" then
		return decoded
	end
	return {}
end

function Settings.setPanelEnabledMap(map)
	Settings.setString(SETTINGS.panelEnabled, HttpService:JSONEncode(map))
end

function Settings.getPanelEnabled(panelId, defaultEnabled)
	local map = Settings.getPanelEnabledMap()
	local value = map[panelId]
	if value == nil then
		return defaultEnabled ~= false
	end
	return value == true
end

function Settings.setPanelEnabled(panelId, enabled)
	local map = Settings.getPanelEnabledMap()
	map[panelId] = enabled
	Settings.setPanelEnabledMap(map)
end

function Settings.clearPanelEnabled(panelId)
	local map = Settings.getPanelEnabledMap()
	map[panelId] = nil
	Settings.setPanelEnabledMap(map)
end

local function debugLog(...)
	if Settings.getBool(SETTINGS.debugLogging, false) then
		warn("[StudioStud]", ...)
	end
end

-- == Transport ==

local Transport = {}

function Transport.parseDaemonUrl(url)
	if typeof(url) ~= "string" or url == "" then
		return "127.0.0.1", "31878"
	end
	local host, port = url:match("^https?://([^:/]+):?(%d*)/?$")
	if not host then
		host, port = url:match("^([^:/]+):?(%d*)$")
	end
	if not host or host == "" then
		return "127.0.0.1", "31878"
	end
	if not port or port == "" then
		port = "31878"
	end
	return host, port
end

function Transport.buildDaemonUrl(host, port)
	local trimmedHost = string.gsub(host or "", "%s+", "")
	local trimmedPort = string.gsub(port or "", "%s+", "")
	if trimmedHost == "" then
		trimmedHost = "127.0.0.1"
	end
	if trimmedPort == "" then
		trimmedPort = "31878"
	end
	return ("http://%s:%s"):format(trimmedHost, trimmedPort)
end

function Transport.currentUrl()
	return Settings.getString(SETTINGS.daemonUrl, DEFAULT_DAEMON_URL)
end

function Transport.requestJson(method, path, body, timeoutSeconds)
	local url = Transport.currentUrl() .. path
	local request = {
		Url = url,
		Method = method,
		Headers = { ["Content-Type"] = "application/json" },
		Timeout = timeoutSeconds or 30,
	}
	if body ~= nil then
		local encOk, encoded = pcall(HttpService.JSONEncode, HttpService, body)
		if not encOk then
			warn("[StudioStud] JSONEncode failed for", path, ":", encoded)
			return false, { error = "JSONEncode: " .. tostring(encoded) }
		end
		request.Body = encoded
	end
	local ok, response = pcall(function()
		return HttpService:RequestAsync(request)
	end)
	if not ok then
		return false, { error = tostring(response) }
	end
	if not response.Success then
		local decodedOk, decoded = pcall(function()
			return HttpService:JSONDecode(response.Body)
		end)
		if decodedOk and type(decoded) == "table" then
			decoded.statusCode = response.StatusCode
			return false, decoded
		end
		return false, { error = response.StatusMessage, statusCode = response.StatusCode, body = response.Body }
	end
	local decodedOk, decoded = pcall(function()
		return HttpService:JSONDecode(response.Body)
	end)
	if not decodedOk then
		return false, { error = "Bad daemon JSON: " .. tostring(decoded) }
	end
	return true, decoded
end

function Transport.buildAuthedHeaders(token)
	return {
		["Content-Type"] = "application/json",
		["X-StudioStud-Token"] = token,
	}
end

function Transport.fetchWriteToken()
	local ok, result = Transport.requestJson("GET", "/studio-stud/write/token", nil)
	if ok and type(result) == "table" and type(result.token) == "string" and result.token ~= "" then
		Settings.setString(SETTINGS.writeToken, result.token)
		return result.token
	end
	return ""
end

function Transport.requestJsonAuthed(method, path, body, timeoutSeconds)
	local function sendRequest(token)
		local url = Transport.currentUrl() .. path
		local request = {
			Url = url,
			Method = method,
			Headers = Transport.buildAuthedHeaders(token),
			Timeout = timeoutSeconds or 30,
		}
		Transport._selfTestLastRequest = request
		if body ~= nil then
			local encOk, encoded = pcall(HttpService.JSONEncode, HttpService, body)
			if not encOk then
				warn("[StudioStud] JSONEncode failed for", path, ":", encoded)
				return false, { error = "JSONEncode: " .. tostring(encoded) }
			end
			request.Body = encoded
		end
		local ok, response = pcall(function()
			return HttpService:RequestAsync(request)
		end)
		if not ok then
			return false, { error = tostring(response) }
		end
		if not response.Success then
			local decodedOk, decoded = pcall(function()
				return HttpService:JSONDecode(response.Body)
			end)
			if decodedOk and type(decoded) == "table" then
				decoded.statusCode = response.StatusCode
				return false, decoded
			end
			return false, { error = response.StatusMessage, statusCode = response.StatusCode, body = response.Body }
		end
		local decodedOk, decoded = pcall(function()
			return HttpService:JSONDecode(response.Body)
		end)
		if not decodedOk then
			return false, { error = "Bad daemon JSON: " .. tostring(decoded) }
		end
		return true, decoded
	end

	local token = Settings.getString(SETTINGS.writeToken, "")
	if token == "" then
		token = Transport.fetchWriteToken()
	end
	if token == "" then
		return false, { error = "write token unavailable", blockedReason = "tokenInvalid" }
	end

	local ok, result = sendRequest(token)
	if not ok and result.statusCode == 401 then
		token = Transport.fetchWriteToken()
		if token ~= "" then
			ok, result = sendRequest(token)
		end
	end
	return ok, result
end

function Transport.requestBody(path, body)
	local request = {
		Url = Transport.currentUrl() .. path,
		Method = "POST",
		Headers = { ["Content-Type"] = "application/json" },
		Body = body,
		Timeout = 60,
	}
	local ok, response = pcall(function()
		return HttpService:RequestAsync(request)
	end)
	if not ok then
		return false, { error = tostring(response) }
	end
	if not response.Success then
		local decodedOk, decoded = pcall(function()
			return HttpService:JSONDecode(response.Body)
		end)
		if decodedOk and type(decoded) == "table" then
			decoded.statusCode = response.StatusCode
			return false, decoded
		end
		return false, { error = response.StatusMessage, statusCode = response.StatusCode, body = response.Body }
	end
	local decodedOk, decoded = pcall(function()
		return HttpService:JSONDecode(response.Body)
	end)
	if not decodedOk then
		return false, { error = "Bad daemon JSON: " .. tostring(decoded) }
	end
	return true, decoded
end

-- == Property allow-list (fetched from daemon /allowlist; static CLASS_PROPERTIES is the fallback) ==
local AllowList = {}
AllowList.loaded = false
AllowList.version = nil
AllowList.sets = {} -- [className] = { [propName] = readOnly(boolean) }   (O(1) membership)
AllowList.lists = {} -- [className] = { propName, ... }                    (ordered, for capture)

-- Pure: turn a decoded /allowlist response into per-class sets + ordered lists. Returns nil on bad input.
function AllowList.parse(decoded)
	if type(decoded) ~= "table" or type(decoded.classes) ~= "table" then
		return nil
	end
	local sets, lists = {}, {}
	for className, props in pairs(decoded.classes) do
		if type(props) == "table" then
			local set, list = {}, {}
			for _, entry in ipairs(props) do
				if type(entry) == "table" and type(entry.name) == "string" then
					set[entry.name] = entry.readOnly == true
					table.insert(list, entry.name)
				end
			end
			sets[className] = set
			lists[className] = list
		end
	end
	return { version = decoded.version, sets = sets, lists = lists }
end

-- Fetch from the daemon and cache. Returns true on success; leaves the static fallback in place on failure.
function AllowList.fetch()
	local ok, decoded = Transport.requestJson("GET", "/studio-stud/allowlist", nil, 15)
	if not ok then
		debugLog("allowlist: fetch failed (static fallback):", decoded and decoded.error)
		return false
	end
	local parsed = AllowList.parse(decoded)
	if not parsed then
		debugLog("allowlist: bad response (static fallback)")
		return false
	end
	AllowList.sets = parsed.sets
	AllowList.lists = parsed.lists
	AllowList.version = parsed.version
	AllowList.loaded = true
	local count = 0
	for _ in pairs(parsed.sets) do
		count += 1
	end
	debugLog("allowlist: loaded version", tostring(parsed.version), "classes", count)
	return true
end

-- Ordered property names for an exact class (nil if not loaded / class unknown).
function AllowList.namesFor(className)
	if AllowList.loaded then
		return AllowList.lists[className]
	end
	return nil
end

-- Membership set {propName = readOnly} for an exact class (nil if not loaded / class unknown).
function AllowList.setFor(className)
	if AllowList.loaded then
		return AllowList.sets[className]
	end
	return nil
end

-- == Global API (_G.StudioStud wiring) ==

local GlobalApi = {}

function GlobalApi.makeDisabledFn()
	return function()
		warn("[Studio Stud] Capture/Query panel is disabled")
		return { ok = false, error = "panel disabled" }
	end
end

function GlobalApi.installNoOps()
	if not _G.StudioStud then
		return
	end
	local disabled = GlobalApi.makeDisabledFn()
	_G.StudioStud.Status = disabled
	_G.StudioStud.Sync = disabled
	_G.StudioStud.Capture = disabled
end

function GlobalApi.wireCapture(statusFn, syncFn)
	if not _G.StudioStud then
		return
	end
	_G.StudioStud.Status = statusFn
	_G.StudioStud.Sync = syncFn
	_G.StudioStud.Capture = syncFn
end

-- == Registry ==

local Registry = {
	descriptors = {},
	handles = {},
	selectedId = nil,
	panelHost = nil,
	getCtx = nil,
	onChange = nil,
}

function Registry.setHost(panelHost, getCtx, onChange)
	Registry.panelHost = panelHost
	Registry.getCtx = getCtx
	Registry.onChange = onChange
end

function Registry.register(descriptor)
	if type(descriptor) ~= "table" or type(descriptor.id) ~= "string" or descriptor.id == "" then
		return false, "invalid descriptor"
	end
	if type(descriptor.title) ~= "string" or type(descriptor.build) ~= "function" then
		return false, "invalid descriptor"
	end
	for _, existing in ipairs(Registry.descriptors) do
		if existing.id == descriptor.id then
			return false, "duplicate id"
		end
	end
	table.insert(Registry.descriptors, descriptor)
	if Registry.onChange then
		Registry.onChange()
	end
	return true
end

function Registry.unregister(id)
	for index, descriptor in ipairs(Registry.descriptors) do
		if descriptor.id == id then
			local handle = Registry.handles[id]
			if handle and handle.destroy then
				handle.destroy()
			elseif handle and handle.frame then
				handle.frame:Destroy()
			end
			Registry.handles[id] = nil
			if Registry.selectedId == id then
				Registry.selectedId = nil
			end
			table.remove(Registry.descriptors, index)
			Settings.clearPanelEnabled(id)
			if Registry.onChange then
				Registry.onChange()
			end
			return true
		end
	end
	return false
end

function Registry.list()
	local items = {}
	for _, descriptor in ipairs(Registry.descriptors) do
		table.insert(items, {
			id = descriptor.id,
			title = descriptor.title,
			defaultEnabled = descriptor.defaultEnabled,
			enabled = Settings.getPanelEnabled(descriptor.id, descriptor.defaultEnabled),
			descriptor = descriptor,
		})
	end
	return items
end

function Registry.setEnabled(id, enabled)
	local found = false
	for _, descriptor in ipairs(Registry.descriptors) do
		if descriptor.id == id then
			found = true
			break
		end
	end
	if not found then
		return false
	end
	Settings.setPanelEnabled(id, enabled)
	if not enabled then
		local handle = Registry.handles[id]
		if handle then
			if handle.destroy then
				handle.destroy()
			elseif handle.frame then
				handle.frame:Destroy()
			end
			Registry.handles[id] = nil
		end
		if Registry.selectedId == id then
			Registry.selectedId = nil
			for _, item in ipairs(Registry.list()) do
				if item.enabled then
					Registry.select(item.id)
					break
				end
			end
		end
	end
	if Registry.onChange then
		Registry.onChange()
	end
	return true
end

function Registry.selected()
	return Registry.selectedId
end

function Registry.teardownAll()
	for id, handle in pairs(Registry.handles) do
		if handle.destroy then
			handle.destroy()
		elseif handle.frame then
			handle.frame:Destroy()
		end
		Registry.handles[id] = nil
	end
	Registry.selectedId = nil
end

function Registry.select(id)
	if not Registry.panelHost or not Registry.getCtx then
		return false
	end
	local targetDescriptor = nil
	local targetEnabled = false
	for _, descriptor in ipairs(Registry.descriptors) do
		if descriptor.id == id then
			targetDescriptor = descriptor
			targetEnabled = Settings.getPanelEnabled(id, descriptor.defaultEnabled)
			break
		end
	end
	if not targetDescriptor or not targetEnabled then
		return false
	end

	if Registry.selectedId and Registry.selectedId ~= id then
		local current = Registry.handles[Registry.selectedId]
		if current then
			if current.onHide then
				current.onHide()
			end
			if current.frame then
				current.frame.Visible = false
			end
		end
	end

	local handle = Registry.handles[id]
	if not handle then
		local frame = Instance.new("Frame")
		frame.Name = "Panel_" .. id
		frame.BackgroundTransparency = 1
		frame.Size = UDim2.fromScale(1, 1)
		frame.Parent = Registry.panelHost
		handle = targetDescriptor.build(frame, Registry.getCtx()) or { frame = frame }
		if not handle.frame then
			handle.frame = frame
		end
		Registry.handles[id] = handle
	end

	if handle.onShow then
		handle.onShow()
	end
	if handle.frame then
		handle.frame.Visible = true
	end
	Registry.selectedId = id
	if Registry.onChange then
		Registry.onChange()
	end
	return true
end

function Registry.getHandle(id)
	return Registry.handles[id]
end

function Registry.firstEnabledId()
	for _, item in ipairs(Registry.list()) do
		if item.enabled then
			return item.id
		end
	end
	return nil
end

function Registry.countIds()
	return #Registry.descriptors
end

function Registry.snapshotIds()
	local ids = {}
	for _, item in ipairs(Registry.list()) do
		table.insert(ids, item.id)
	end
	table.sort(ids)
	return ids
end

-- == CapturePanel ==

local CapturePanel = {}

function CapturePanel.build(parent, ctx)
	local syncing = false
	local running = true
	local pollGeneration = 0
	local sessionHasBaseline = false
	local syncFn
	local responseNeedsRebaseline
	local statusFn
	local Live -- populated after syncFn/statusFn; captured as upvalue by both

	local resultLabel = Ui.makeLabel(parent, "Latest capture: none", Theme.PAD, 72, Theme.muted)
	resultLabel.TextSize = 12

	local errorLabel = Ui.makeLabel(parent, "", Theme.PAD + 80, 80, Theme.warn)
	errorLabel.TextSize = 12

	local connectButton = Ui.makePrimaryButton(parent, "Connect")
	connectButton.Position = UDim2.fromOffset(Theme.PAD, Theme.PAD + 168)
	connectButton.Size = UDim2.new(1, -Theme.PAD * 2, 0, 36)

	local function formatError(prefix, result)
		local message = prefix .. ": " .. tostring(result and result.error or "unknown error")
		if result and result.statusCode then
			message = message .. " (HTTP " .. tostring(result.statusCode) .. ")"
		end
		if result and result.body and result.body ~= "" then
			message = message .. "\n" .. tostring(result.body)
		end
		return message
	end

	local function setConnectButtonState()
		if syncing then
			connectButton.Text = "Capturing..."
			connectButton.BackgroundColor3 = Theme.teal
			connectButton.AutoButtonColor = false
		elseif ctx.isConnected() then
			connectButton.Text = "Capture / Query"
			connectButton.BackgroundColor3 = Theme.copper
			connectButton.AutoButtonColor = true
		else
			connectButton.Text = "Connect"
			connectButton.BackgroundColor3 = Theme.copper
			connectButton.AutoButtonColor = true
		end
	end

	local BASELINE_YIELD_EVERY = 500

	local Capture = {}
	local instanceIdByRef = {}
	local pathByRef = {}

	function Capture.shouldYield(processedCount, yieldEvery)
		return yieldEvery > 0 and processedCount > 0 and (processedCount % yieldEvery) == 0
	end

	function Capture.serializeVector3(value)
		return { type = "Vector3", x = value.X, y = value.Y, z = value.Z }
	end

	function Capture.serializeCFrame(value)
		local components = { value:GetComponents() }
		return {
			type = "CFrame",
			position = Capture.serializeVector3(value.Position),
			matrix = components,
		}
	end

	function Capture.serializeColor3(value)
		return { type = "Color3", r = value.R, g = value.G, b = value.B }
	end

	function Capture.serializeValue(value)
		local valueType = typeof(value)
		if valueType == "nil" or valueType == "boolean" or valueType == "number" or valueType == "string" then
			return value
		elseif valueType == "Vector3" then
			return Capture.serializeVector3(value)
		elseif valueType == "Vector2" then
			return { type = "Vector2", x = value.X, y = value.Y }
		elseif valueType == "CFrame" then
			return Capture.serializeCFrame(value)
		elseif valueType == "Color3" then
			return Capture.serializeColor3(value)
		elseif valueType == "UDim" then
			return { type = "UDim", scale = value.Scale, offset = value.Offset }
		elseif valueType == "UDim2" then
			return {
				type = "UDim2",
				x = { scale = value.X.Scale, offset = value.X.Offset },
				y = { scale = value.Y.Scale, offset = value.Y.Offset },
			}
		elseif valueType == "EnumItem" then
			return { type = "EnumItem", enumType = tostring(value.EnumType), name = value.Name }
		elseif valueType == "NumberRange" then
			return { type = "NumberRange", min = value.Min, max = value.Max }
		elseif valueType == "NumberSequence" then
			local keypoints = {}
			for _, keypoint in ipairs(value.Keypoints) do
				table.insert(keypoints, { time = keypoint.Time, value = keypoint.Value, envelope = keypoint.Envelope })
			end
			return { type = "NumberSequence", keypoints = keypoints }
		elseif valueType == "ColorSequence" then
			local keypoints = {}
			for _, keypoint in ipairs(value.Keypoints) do
				table.insert(keypoints, { time = keypoint.Time, value = Capture.serializeColor3(keypoint.Value) })
			end
			return { type = "ColorSequence", keypoints = keypoints }
		elseif valueType == "PhysicalProperties" then
			return {
				type = "PhysicalProperties",
				density = value.Density,
				friction = value.Friction,
				elasticity = value.Elasticity,
				frictionWeight = value.FrictionWeight,
				elasticityWeight = value.ElasticityWeight,
			}
		elseif valueType == "Font" then
			return {
				type = "Font",
				family = value.Family,
				weight = value.Weight.Name,
				style = value.Style.Name,
			}
		elseif valueType == "Rect" then
			return {
				type = "Rect",
				min = { type = "Vector2", x = value.Min.X, y = value.Min.Y },
				max = { type = "Vector2", x = value.Max.X, y = value.Max.Y },
			}
		elseif valueType == "Instance" then
			return {
				type = "InstanceRef",
				id = instanceIdByRef[value],
				path = pathByRef[value] or value:GetFullName(),
			}
		elseif valueType == "table" then
			local out = {}
			for key, item in pairs(value) do
				out[tostring(key)] = Capture.serializeValue(item)
			end
			return out
		end
		return { type = "Unsupported", reason = valueType }
	end

	function Capture.getPropertyNames(inst)
		-- Phase 3: prefer the daemon allow-list (per exact ClassName, includes inherited props).
		local fromAllow = AllowList.namesFor(inst.ClassName)
		if fromAllow then
			return fromAllow
		end
		-- Fallback: static CLASS_PROPERTIES (IsA-based accumulation).
		local names = {}
		if inst:IsA("BasePart") then
			for _, name in ipairs(CLASS_PROPERTIES.BasePart) do
				table.insert(names, name)
			end
		end
		for className, props in pairs(CLASS_PROPERTIES) do
			if className ~= "BasePart" and inst:IsA(className) then
				for _, name in ipairs(props) do
					table.insert(names, name)
				end
			end
		end
		return names
	end

	-- Membership set for the inst's class (allow-list when loaded, else built from the static names).
	function Capture.curatedSet(inst)
		local fromAllow = AllowList.setFor(inst.ClassName)
		if fromAllow then
			return fromAllow
		end
		local set = {}
		for _, name in ipairs(Capture.getPropertyNames(inst)) do
			set[name] = false
		end
		return set
	end

	function Capture.readPropsFrom(fakeInst, names)
		local properties = {}
		local errors = {}
		for _, propName in ipairs(names) do
			local ok, value = pcall(function()
				return fakeInst[propName]
			end)
			if ok then
				properties[propName] = Capture.serializeValue(value)
			else
				table.insert(errors, { property = propName, error = tostring(value) })
			end
		end
		return properties, errors
	end

	function Capture.readProperties(inst)
		local names = Capture.getPropertyNames(inst)
		local properties = {}
		local errors = {}
		local batchOk, batchProps = pcall(function()
			local props = {}
			for _, propName in ipairs(names) do
				props[propName] = Capture.serializeValue(inst[propName])
			end
			return props
		end)
		if batchOk then
			properties = batchProps
		else
			properties = {}
			properties, errors = Capture.readPropsFrom(inst, names)
		end

		if inst:IsA("Model") then
			local ok, cframe, size = pcall(function()
				return inst:GetBoundingBox()
			end)
			if ok then
				properties.BoundingBoxCFrame = Capture.serializeCFrame(cframe)
				properties.BoundingBoxSize = Capture.serializeVector3(size)
			end
			local pivotOk, pivot = pcall(function()
				return inst:GetPivot()
			end)
			if pivotOk then
				properties.Pivot = Capture.serializeCFrame(pivot)
			end
		end
		return properties, errors
	end

	function Capture.readSource(inst)
		if not inst:IsA("LuaSourceContainer") then
			return nil
		end
		local ok, src = pcall(function()
			return inst.Source
		end)
		if ok and typeof(src) == "string" then
			return src
		end
		return nil
	end

	function Capture.readAttributes(inst)
		local ok, attrs = pcall(function()
			return inst:GetAttributes()
		end)
		if not ok then
			return {}, { { property = "Attributes", error = tostring(attrs) } }
		end
		return Capture.serializeValue(attrs), {}
	end

	function Capture.readTags(inst)
		local ok, tags = pcall(function()
			return inst:GetTags()
		end)
		if ok and typeof(tags) == "table" then
			return tags
		end
		return {}
	end

	function Capture.getRootEntries()
		local roots = {}
		local seen = {}
		for _, serviceName in ipairs(ROOT_SERVICE_ORDER) do
			local ok, service = pcall(function()
				return game:GetService(serviceName)
			end)
			if ok and service and not seen[service] then
				seen[service] = true
				table.insert(roots, {
					name = service.Name,
					instance = service,
					includeDescendants = DESCENDANT_ROOT_SERVICES[serviceName]
						or DESCENDANT_ROOT_SERVICES[service.Name]
						or false,
				})
			end
		end
		table.sort(roots, function(left, right)
			local leftIndex = ROOT_SERVICE_INDEX[left.instance.ClassName]
				or ROOT_SERVICE_INDEX[left.name]
				or math.huge
			local rightIndex = ROOT_SERVICE_INDEX[right.instance.ClassName]
				or ROOT_SERVICE_INDEX[right.name]
				or math.huge
			if leftIndex ~= rightIndex then
				return leftIndex < rightIndex
			end
			if left.name ~= right.name then
				return left.name < right.name
			end
			return left.instance.ClassName < right.instance.ClassName
		end)
		return roots
	end

	function Capture.collectBaseInstances()
		local instances = {}
		local rootNames = {}
		instanceIdByRef = {}
		pathByRef = {}
		local processedCount = 0

		local function walk(inst, parentId, parentPath, depth, siblingIndex, duplicate, includeDescendants)
			local id = inst:GetDebugId(0)
			local segment = ("%s[%d]"):format(inst.Name, siblingIndex)
			local path
			if parentPath == "" then
				path = segment
			else
				path = parentPath .. "/" .. segment
			end
			instanceIdByRef[inst] = id
			pathByRef[inst] = path

			local children = inst:GetChildren()
			local entry = {
				id = id,
				path = path,
				displayPath = inst:GetFullName(),
				name = inst.Name,
				className = inst.ClassName,
				parentId = parentId,
				parentPath = parentPath ~= "" and parentPath or nil,
				depth = depth,
				siblingIndex = siblingIndex,
				childCount = if includeDescendants then #children else 0,
				duplicateSiblingName = duplicate,
			}
			table.insert(instances, entry)
			processedCount += 1
			if Capture.shouldYield(processedCount, BASELINE_YIELD_EVERY) then
				task.wait()
			end

			if not includeDescendants then
				return
			end

			local siblingCounts = {}
			for _, child in ipairs(children) do
				siblingCounts[child.Name] = (siblingCounts[child.Name] or 0) + 1
			end
			local seen = {}
			for _, child in ipairs(children) do
				seen[child.Name] = (seen[child.Name] or 0) + 1
				walk(child, id, path, depth + 1, seen[child.Name], siblingCounts[child.Name] > 1, true)
			end
		end

		for _, root in ipairs(Capture.getRootEntries()) do
			table.insert(rootNames, root.name)
			walk(root.instance, nil, "", 0, 1, false, root.includeDescendants)
		end
		return instances, rootNames
	end

	function Capture.buildSnapshot(options)
		local startedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
		local instances, rootNames = Capture.collectBaseInstances()
		local idToEntry = {}
		for _, entry in ipairs(instances) do
			idToEntry[entry.id] = entry
		end

		local processedCount = 0
		for inst, id in pairs(instanceIdByRef) do
			local entry = idToEntry[id]
			if entry then
				local attributes, attrErrors = Capture.readAttributes(inst)
				local properties, propErrors = Capture.readProperties(inst)
				entry.attributes = attributes
				entry.tags = Capture.readTags(inst)
				entry.properties = properties
				entry.propertyErrors = propErrors
				local src = Capture.readSource(inst)
				if src ~= nil then
					entry.source = src
				end
				for _, attrError in ipairs(attrErrors) do
					table.insert(entry.propertyErrors, attrError)
				end
				processedCount += 1
				if Capture.shouldYield(processedCount, BASELINE_YIELD_EVERY) then
					task.wait()
				end
			end
		end

		return {
			formatVersion = 1,
			snapshotKind = "studio-stud-live-snapshot",
			serviceName = SERVICE_NAME,
			pluginVersion = PLUGIN_VERSION,
			place = {
				placeKey = tostring(game.PlaceId ~= 0 and ("Place" .. tostring(game.PlaceId)) or game.Name),
				name = game.Name,
				placeId = game.PlaceId,
				gameId = game.GameId,
			},
			sync = {
				reason = options and options.reason or "manual",
				requestId = options and options.requestId or nil,
				startedAtUtc = startedAt,
				finishedAtUtc = os.date("!%Y-%m-%dT%H:%M:%SZ"),
				consistency = "single-pass",
				rootNames = rootNames,
			},
			instances = instances,
		}
	end

	local function waitForCaptureFinalize(captureSyncId, timeoutSeconds)
		local deadline = os.clock() + (timeoutSeconds or 120)
		while os.clock() < deadline do
			local okStatus, statusResult = ctx.transport.requestJson(
				"GET",
				"/studio-stud/capture/status?syncId=" .. HttpService:UrlEncode(captureSyncId),
				nil
			)
			if okStatus and statusResult then
				local status = statusResult.status
				if status == "done" or status == "completed" then
					return true, statusResult
				end
				if status == "error" or statusResult.ok == false then
					return false, statusResult
				end
			end
			task.wait(0.5)
		end
		return false, { ok = false, error = "Capture finalize timed out" }
	end

	syncFn = function(options)
		-- Edit-session gate: never build a snapshot or touch the daemon during a play session.
		if not Session.isEdit() then
			debugLog("capture skipped — Studio in play session (mode=", Session.mode(), ")")
			return { ok = false, error = "studio_in_play_session" }
		end
		if syncing then
			return { ok = false, error = "Sync already running." }
		end
		syncing = true
		setConnectButtonState()
		ctx.setStatus("syncing", "Capturing place data...")
		errorLabel.Text = ""

		local snapshot = Capture.buildSnapshot(options)
		local jsonText = HttpService:JSONEncode(snapshot)
		local okStart, startResult = ctx.transport.requestJson("POST", "/studio-stud/capture/start", {
			pluginVersion = PLUGIN_VERSION,
			protocolVersion = PROTOCOL_VERSION,
			place = snapshot.place,
		})
		if not okStart then
			syncing = false
			setConnectButtonState()
			errorLabel.Text = formatError("Start failed", startResult)
			ctx.setStatus("error", "Capture failed")
			ctx.setConnected(false)
			return startResult
		end
		local syncId = startResult.syncId
		local maxChunk = tonumber(startResult.maxChunkBytes) or 1000000

		if #jsonText <= maxChunk then
			local okBody, bodyResult = ctx.transport.requestBody(
				"/studio-stud/capture/body?syncId=" .. HttpService:UrlEncode(syncId),
				jsonText
			)
			if not okBody then
				syncing = false
				setConnectButtonState()
				errorLabel.Text = formatError("Upload failed", bodyResult)
				ctx.setStatus("error", "Capture failed")
				ctx.setConnected(false)
				return bodyResult
			end
		else
			local chunkCount = math.ceil(#jsonText / maxChunk)
			for index = 1, chunkCount do
				local startByte = ((index - 1) * maxChunk) + 1
				local chunk = string.sub(jsonText, startByte, startByte + maxChunk - 1)
				local okChunk, chunkResult = ctx.transport.requestBody(
					("/studio-stud/capture/chunk?syncId=%s&index=%d"):format(HttpService:UrlEncode(syncId), index - 1),
					chunk
				)
				if not okChunk then
					syncing = false
					setConnectButtonState()
					errorLabel.Text = formatError("Chunk failed", chunkResult)
					ctx.setStatus("error", "Capture failed")
					ctx.setConnected(false)
					return chunkResult
				end
			end
		end

		local expectedChunks = nil
		if #jsonText > maxChunk then
			expectedChunks = math.ceil(#jsonText / maxChunk)
		end
		local okComplete, completeResult = ctx.transport.requestJson("POST", "/studio-stud/capture/complete", {
			syncId = syncId,
			expectedChunks = expectedChunks,
		}, 60)
		if okComplete and completeResult and completeResult.status == "finalizing" then
			ctx.setStatus("syncing", "Finalizing capture on daemon...")
			local finalizeSyncId = completeResult.syncId or syncId
			okComplete, completeResult = waitForCaptureFinalize(finalizeSyncId, 120)
		end
		syncing = false
		setConnectButtonState()
		if okComplete and completeResult and responseNeedsRebaseline(completeResult) then
			Live.triggerRebaseline("capture-unknown-sync")
			return completeResult
		end
		if okComplete and completeResult.ok then
			ctx.setConnected(true)
			local materialized = completeResult.result or completeResult
			local placeKey = tostring(materialized.placeKey or snapshot.place.placeKey)
			local placeId = tostring(materialized.placeId or snapshot.place.placeId)
			sessionHasBaseline = true
			resultLabel.Text = ("Latest capture: OK\nPlace: %s\nInstances: %s\nCLI:\nstudio-stud analyze %s --report context"):format(
				placeKey,
				tostring(materialized.instances or materialized.totalItems),
				placeId
			)
			if Live then
				Live.setupAfterBaseline(materialized)
				debugLog("live mode started, revision=", Live.currentRevision, "instances=", Live.liveInstanceCount)
				ctx.setStatus("connected", "Live — delta streaming active")
			else
				ctx.setStatus("connected", "Capture complete")
			end
			return completeResult
		end
		errorLabel.Text = formatError("Complete failed", completeResult)
		ctx.setStatus("error", "Capture failed")
		ctx.setConnected(false)
		return completeResult
	end

	statusFn = function()
		ctx.setStatus("syncing", "Checking daemon...")
		local ok, result = ctx.transport.requestJson("GET", "/studio-stud/ping", nil)
		if ok and result.ok then
			local daemonProtocol = tonumber(result.protocolVersion) or 0
			local daemonMinPlugin = tonumber(result.minPluginProtocolVersion) or daemonProtocol
			-- Mutual handshake: name whichever side is behind.
			if daemonProtocol < MIN_DAEMON_PROTOCOL_VERSION then
				ctx.setConnected(false)
				setConnectButtonState()
				ctx.setStatus("error", "Daemon outdated — update it")
				errorLabel.Text = ("Daemon protocol %d < plugin requires %d. Update: %s"):format(
					daemonProtocol,
					MIN_DAEMON_PROTOCOL_VERSION,
					updateInstallHint(result.channel)
				)
				return {
					ok = false,
					error = "daemon outdated",
					daemon = result,
					placeId = game.PlaceId,
					placeName = game.Name,
				}
			end
			if PROTOCOL_VERSION < daemonMinPlugin then
				ctx.setConnected(false)
				setConnectButtonState()
				ctx.setStatus("error", "Plugin outdated — reinstall plugin")
				errorLabel.Text = ("Plugin protocol %d < daemon requires %d. Reinstall from .studio-stud-tool/plugin/StudioStud.plugin.lua"):format(
					PROTOCOL_VERSION,
					daemonMinPlugin
				)
				return {
					ok = false,
					error = "plugin outdated",
					daemon = result,
					placeId = game.PlaceId,
					placeName = game.Name,
				}
			end
			ctx.setConnected(true)
			setConnectButtonState()
			local updateNote = checkRemoteUpdate(result)
			if updateNote ~= "" then
				ctx.setStatus("connected", ("Daemon %s — %s"):format(tostring(result.version or "unknown"), updateNote))
				errorLabel.Text = updateNote .. "  (run: " .. updateInstallHint(result.channel) .. ")"
			else
				ctx.setStatus("connected", ("Daemon %s — listening for captures"):format(tostring(result.version or "unknown")))
				errorLabel.Text = ""
			end
			Transport.fetchWriteToken()
			return { ok = true, daemon = result, placeId = game.PlaceId, placeName = game.Name }
		end
		ctx.setConnected(false)
		setConnectButtonState()
		ctx.setStatus("idle", "Run studio-stud serve, then Connect")
		errorLabel.Text = formatError("Connect failed", result)
		return { ok = false, error = result.error, placeId = game.PlaceId, placeName = game.Name }
	end

	-- Ping daemon; on first success this session, run baseline capture + live mode.
	local function startupConnectAndCapture()
		-- Edit-session gate: do not connect/capture while Studio is in a play session.
		if not Session.isEdit() then
			return { ok = false, error = "studio_in_play_session" }
		end
		if syncing then
			return { ok = false, error = "Sync already running." }
		end
		local ping = statusFn()
		if not (ping and ping.ok) then
			return ping
		end
		if not AllowList.loaded then -- Phase 3: load once per connect (best-effort; static fallback on failure)
			AllowList.fetch()
		end
		if sessionHasBaseline or (Live and Live.liveRunning) then
			return ping
		end
		debugLog("startup: daemon reachable — running initial capture")
		return syncFn({ reason = "startup" })
	end

	-- == Live capture engine ==

	Live = {}
	Live.liveRunning = false
	Live.currentRevision = 0
	Live.dirtyUpsert = {} -- [Instance] = true
	Live.dirtyRemoved = {} -- [id: string] = true
	Live.instConns = {} -- [Instance] = {RBXScriptConnection...}
	Live.rootConns = {} -- RBXScriptConnection[] for root DescendantAdded/Removing
	Live.globalConns = {} -- RBXScriptConnection[] for Selection, ChangeHistory
	Live.parentByInst = {} -- [Instance] = Instance|nil (last known parent)
	Live.verifyNeeded = false
	Live.liveInstanceCount = 0
	Live.syncInFlight = false
	Live.networkErrorCount = 0

	responseNeedsRebaseline = function(result)
		if type(result) ~= "table" then
			return false
		end
		if result.needsRebaseline == true then
			return true
		end
		return result.error == "unknownSyncId"
	end

	function Live.triggerRebaseline(reason)
		local delays = { 5, 15, 45 }
		task.defer(function()
			if Live.liveRunning then
				Live.teardown()
			end
			ctx.setConnected(false)
			sessionHasBaseline = false
			setConnectButtonState()
			ctx.setStatus("syncing", "Re-baselining after daemon restart...")
			local attempt = 0
			local function tryRebaseline()
				attempt += 1
				warn("[StudioStud] re-baseline attempt", attempt, "reason:", reason or "live-rebaseline")
				local res = syncFn({ reason = reason or "live-rebaseline" })
				if res and res.ok then
					return
				end
				if attempt < #delays then
					warn("[StudioStud] re-baseline failed, retrying in", delays[attempt], "s")
					task.delay(delays[attempt], function()
						tryRebaseline()
					end)
				else
					warn("[StudioStud] re-baseline failed after", attempt, "attempts — click Capture/Query to reconnect")
					ctx.setStatus("error", "Live lost — click Capture/Query to reconnect")
				end
			end
			tryRebaseline()
		end)
	end

	local function liveDebugId(inst)
		local ok, id = pcall(function()
			return inst:GetDebugId(0)
		end)
		return ok and id ~= "" and id or nil
	end

	-- BFS dirty-mark: root + all captured descendants (path cascade on rename/reparent)
	function Live.markSubtreeUpsert(root)
		local queue = { root }
		local qi = 1
		while qi <= #queue do
			local inst = queue[qi]
			qi += 1
			if instanceIdByRef[inst] then
				Live.dirtyUpsert[inst] = true
			end
			local ok, children = pcall(function()
				return inst:GetChildren()
			end)
			if ok then
				for _, child in ipairs(children) do
					table.insert(queue, child)
				end
			end
		end
	end

	-- Dirty parent + all same-name siblings under parent (siblingIndex/duplicate changed)
	function Live.markSiblingsDirty(parent, name)
		if not parent then
			return
		end
		if instanceIdByRef[parent] then
			Live.dirtyUpsert[parent] = true
		end
		local ok, children = pcall(function()
			return parent:GetChildren()
		end)
		if not ok then
			return
		end
		for _, sib in ipairs(children) do
			if sib.Name == name and instanceIdByRef[sib] then
				Live.dirtyUpsert[sib] = true
			end
		end
	end

	-- Pure: classify a Changed property for an instance. Returns "name" | "dirty" | "gap".
	-- NOTE: curatedSet maps propName -> readOnly(boolean); a writable curated prop is `false`,
	-- so membership MUST be tested with `~= nil`, not truthiness (else writable props are missed).
	-- Source is PluginSecurity-only (excluded from allow-list) — special-cased here so live edits ship.
	function Live.classifyChangedProp(prop, curatedSet)
		if prop == "Name" then
			return "name"
		elseif prop == "Source" then
			return "dirty"
		elseif curatedSet[prop] ~= nil then
			return "dirty"
		else
			return "gap"
		end
	end

	-- Uncurated properties that fired, deduped, for later reporting to the daemon (Phase 5).
	Live.propGaps = {} -- [className.."/"..prop] = true
	function Live.recordPropGap(className, prop)
		local key = (className or "?") .. "/" .. tostring(prop)
		if not Live.propGaps[key] then
			Live.propGaps[key] = true
			debugLog("allowlist gap:", key)
		end
	end

	-- Shared name-change cascade (was the body of the old Name signal).
	function Live.onNameChanged(inst)
		local oldPath = pathByRef[inst] or ""
		local oldName = oldPath:match("([^%[/]+)%[%d+%]$") or inst.Name
		Live.markSubtreeUpsert(inst)
		local parent = Live.parentByInst[inst] or inst.Parent
		Live.markSiblingsDirty(parent, oldName)
		Live.markSiblingsDirty(parent, inst.Name)
	end

	-- Connect per-instance signals for one instance
	function Live.registerInstance(inst)
		if Live.instConns[inst] then
			return
		end
		local conns = {}

		-- AncestryChanged: intra-root reparent (fires on moved node AND each dragged descendant)
		local okA, cA = pcall(function()
			return inst.AncestryChanged:Connect(function(changedChild, newParent)
				if instanceIdByRef[inst] then
					Live.dirtyUpsert[inst] = true
				end
				if changedChild == inst then
					local oldParent = Live.parentByInst[inst]
					if oldParent ~= newParent then
						Live.markSiblingsDirty(oldParent, inst.Name)
						Live.markSiblingsDirty(newParent, inst.Name)
					end
					Live.parentByInst[inst] = newParent
				end
			end)
		end)
		if okA then
			table.insert(conns, cA)
		end

		-- AttributeChanged
		local okAt, cAt = pcall(function()
			return inst.AttributeChanged:Connect(function()
				if instanceIdByRef[inst] then
					Live.dirtyUpsert[inst] = true
				end
			end)
		end)
		if okAt then
			table.insert(conns, cAt)
		end

		if inst:IsA("ValueBase") then
			-- ValueBase fires .Changed with the VALUE, not the property name → use explicit signals.
			local okN, cN = pcall(function()
				return inst:GetPropertyChangedSignal("Name"):Connect(function()
					Live.onNameChanged(inst)
				end)
			end)
			if okN then
				table.insert(conns, cN)
			end
			local okV, cV = pcall(function()
				return inst:GetPropertyChangedSignal("Value"):Connect(function()
					if instanceIdByRef[inst] then
						Live.dirtyUpsert[inst] = true
					end
				end)
			end)
			if okV then
				table.insert(conns, cV)
			end
		else
			-- One Changed connection replaces ~N per-property signals + the Name signal.
			local curated = Capture.curatedSet(inst)
			local okC, cC = pcall(function()
				return inst.Changed:Connect(function(prop)
					local kind = Live.classifyChangedProp(prop, curated)
					if kind == "name" then
						Live.onNameChanged(inst)
					elseif kind == "dirty" then
						if instanceIdByRef[inst] then
							Live.dirtyUpsert[inst] = true
						end
					else
						Live.recordPropGap(inst.ClassName, prop)
					end
				end)
			end)
			if okC then
				table.insert(conns, cC)
			end
		end

		Live.instConns[inst] = conns
	end

	-- Disconnect all per-instance signals (without modifying the table during iteration)
	function Live.unregisterInstance(inst)
		local conns = Live.instConns[inst]
		if conns then
			for _, conn in ipairs(conns) do
				pcall(function()
					conn:Disconnect()
				end)
			end
			Live.instConns[inst] = nil
		end
		Live.parentByInst[inst] = nil
	end

	-- Unregister an inst + its entire subtree: add ids to dirtyRemoved, disconnect, clear maps
	function Live.unregisterSubtree(root)
		local queue = { root }
		local qi = 1
		while qi <= #queue do
			local inst = queue[qi]
			qi += 1
			local id = instanceIdByRef[inst]
			if id then
				Live.dirtyRemoved[id] = true
			end
			-- Disconnect without going through unregisterInstance (avoids table mutation during outer iteration)
			local conns = Live.instConns[inst]
			if conns then
				for _, conn in ipairs(conns) do
					pcall(function()
						conn:Disconnect()
					end)
				end
				Live.instConns[inst] = nil
			end
			Live.parentByInst[inst] = nil
			instanceIdByRef[inst] = nil
			pathByRef[inst] = nil
			local ok, children = pcall(function()
				return inst:GetChildren()
			end)
			if ok then
				for _, child in ipairs(children) do
					table.insert(queue, child)
				end
			end
		end
	end

	function Live.onDescendantAdded(child)
		if not Live.liveRunning then
			warn("[StudioStud] +added (live off — click Capture/Query first):", child:GetFullName())
			return
		end
		if not instanceIdByRef[child] then
			local id = liveDebugId(child)
			if id then
				instanceIdByRef[child] = id
				pathByRef[child] = ""
				debugLog("+added:", child:GetFullName(), id)
			else
				debugLog("+added (no debugId):", child:GetFullName())
			end
		end
		Live.parentByInst[child] = child.Parent
		Live.registerInstance(child)
		if instanceIdByRef[child] then
			Live.dirtyUpsert[child] = true
		end
		Live.markSiblingsDirty(child.Parent, child.Name)
	end

	function Live.onDescendantRemoving(child)
		if not Live.liveRunning then
			warn("[StudioStud] -removing (live off, skipped):", child:GetFullName())
			return
		end
		local id = instanceIdByRef[child]
		debugLog("-removing:", child:GetFullName(), "id=", tostring(id))
		local parent = Live.parentByInst[child] or child.Parent
		Live.unregisterSubtree(child)
		-- removed wins: clear from upsert
		Live.dirtyUpsert[child] = nil
		Live.markSiblingsDirty(parent, child.Name)
		debugLog("-removing queued in dirtyRemoved:", next(Live.dirtyRemoved) ~= nil)
	end

	-- Build one full upserted entry for inst by reading the live tree
	local function buildUpsertedEntry(inst)
		local id = instanceIdByRef[inst]
		if not id then
			return nil
		end
		local parent = inst.Parent
		if not parent then
			return nil
		end
		local parentId = instanceIdByRef[parent]
		local parentPath = pathByRef[parent] or ""
		local ok, children = pcall(function()
			return parent:GetChildren()
		end)
		if not ok then
			return nil
		end
		local siblingCounts = {}
		for _, sib in ipairs(children) do
			siblingCounts[sib.Name] = (siblingCounts[sib.Name] or 0) + 1
		end
		local duplicate = (siblingCounts[inst.Name] or 1) > 1
		local siblingIndex = 0
		for _, sib in ipairs(children) do
			if sib.Name == inst.Name then
				siblingIndex += 1
				if sib == inst then
					break
				end
			end
		end
		if siblingIndex == 0 then
			return nil -- not found in parent (likely destroying)
		end
		local segment = inst.Name .. "[" .. siblingIndex .. "]"
		local path = parentPath == "" and segment or (parentPath .. "/" .. segment)
		pathByRef[inst] = path
		local _, slashCount = string.gsub(path, "/", "")
		local ownOk, ownChildren = pcall(function()
			return inst:GetChildren()
		end)
		local childCount = ownOk and #ownChildren or 0
		local properties, _ = Capture.readProperties(inst)
		local attributes, _ = Capture.readAttributes(inst)
		local tags = Capture.readTags(inst)
		local displayPath = inst:GetFullName()
		-- Phase 4: any dirty script re-ships full Source (per-property granularity is Phase 5).
		local src = Capture.readSource(inst)
		local entry = {
			id = id,
			parentId = parentId,
			path = path,
			displayPath = displayPath,
			name = inst.Name,
			className = inst.ClassName,
			depth = slashCount,
			siblingIndex = siblingIndex,
			childCount = childCount,
			duplicateSiblingName = duplicate,
			properties = properties,
			attributes = attributes,
			tags = tags,
		}
		if src ~= nil then
			entry.source = src
		end
		return entry
	end

	-- Flush dirty sets → POST /live/delta
	function Live.flushDirty()
		if not Live.liveRunning then
			warn("[StudioStud] flushDirty skipped — live mode is off (click Capture/Query)")
			return
		end
		-- Edit-session gate: never push deltas while Studio is in a play session.
		if not Session.isEdit() then
			return
		end
		if Live.syncInFlight then
			return
		end
		if not next(Live.dirtyUpsert) and not next(Live.dirtyRemoved) then
			return
		end

		Live.syncInFlight = true
		local function finish()
			Live.syncInFlight = false
		end

		local removed = {}
		for id, _ in pairs(Live.dirtyRemoved) do
			table.insert(removed, id)
		end

		-- Sort dirty-upserted by ancestor depth so parents are processed before children
		-- (ensures pathByRef[parent] is updated before child uses it)
		local upsertList = {}
		for inst, _ in pairs(Live.dirtyUpsert) do
			local id = instanceIdByRef[inst]
			if id and not Live.dirtyRemoved[id] then
				local depth = 0
				local p = inst.Parent
				while p and p ~= game do
					depth += 1
					p = p.Parent
				end
				table.insert(upsertList, { inst = inst, depth = depth })
			end
		end
		table.sort(upsertList, function(a, b)
			return a.depth < b.depth
		end)

		local upserted = {}
		for _, item in ipairs(upsertList) do
			local inst = item.inst
			if inst.Parent ~= nil then
				local entry = buildUpsertedEntry(inst)
				if entry then
					table.insert(upserted, entry)
				else
					local id = instanceIdByRef[inst]
					if id then
						table.insert(removed, id)
					end
				end
			else
				-- Dead instance — treat as removed
				local id = instanceIdByRef[inst]
				if id then
					table.insert(removed, id)
				end
			end
		end

		if #upserted == 0 and #removed == 0 then
			Live.dirtyUpsert = {}
			Live.dirtyRemoved = {}
			finish()
			return
		end

		local body = {
			placeId = tostring(game.PlaceId),
			baseRevision = Live.currentRevision,
			ops = {
				upserted = upserted,
				removed = removed,
			},
		}
		debugLog("delta POST: upserted=", #upserted, "removed=", #removed, "baseRev=", Live.currentRevision)
		local ok, result = ctx.transport.requestJson("POST", "/studio-stud/live/delta", body)
		if ok and result and result.ok then
			debugLog("delta OK: rev=", result.revision, "count=", result.instanceCount)
			Live.currentRevision = result.revision or Live.currentRevision
			Live.liveInstanceCount = result.instanceCount or Live.liveInstanceCount
			Live.networkErrorCount = 0
			Live.dirtyUpsert = {}
			Live.dirtyRemoved = {}
			ctx.setStatus("connected", "Live — delta streaming active")
			ctx.setStats(("rev %d · %d instances"):format(Live.currentRevision, Live.liveInstanceCount))
		elseif ok and result and result.error == "revision_mismatch" then
			-- Resync revision from daemon and retry — do NOT discard pending ops
			warn(
				"[StudioStud] delta MISMATCH: serverRev=",
				result.revision,
				"localRev=",
				Live.currentRevision,
				"— resyncing, will retry"
			)
			if result.revision then
				Live.currentRevision = result.revision
			end
			finish()
			task.defer(function()
				if Live.liveRunning then
					Live.flushDirty()
				end
			end)
			return
		elseif ok and result and result.error == "no_baseline" then
			warn("[StudioStud] delta no_baseline — triggering re-baseline")
			Live.dirtyUpsert = {}
			Live.dirtyRemoved = {}
			task.defer(function()
				if Live.liveRunning then
					Live.teardown()
					-- Retry re-baseline up to 3 times with exponential backoff (5s, 15s, 45s)
					local delays = { 5, 15, 45 }
					local attempt = 0
					local function tryRebaseline()
						attempt += 1
						warn("[StudioStud] re-baseline attempt", attempt)
						local res = syncFn({ reason = "live-rebaseline" })
						if res and res.ok then
							return -- success, setupAfterBaseline already called inside syncFn
						end
						if attempt < #delays then
							warn("[StudioStud] re-baseline failed, retrying in", delays[attempt], "s")
							task.delay(delays[attempt], function()
								if not Live.liveRunning then
									tryRebaseline()
								end
							end)
						else
							warn("[StudioStud] re-baseline failed after", attempt, "attempts — click Capture/Query to reconnect")
							ctx.setStatus("error", "Live lost — click Capture/Query to reconnect")
						end
					end
					tryRebaseline()
				end
			end)
		elseif ok and result and result.ok == false then
			warn("[StudioStud] delta rejected:", result.error or "unknown", result)
			Live.verifyNeeded = true
		elseif result and result.statusCode == 404 then
			-- Daemon does not support /live/* — fall back to poll-only
			Live.teardown()
		elseif not ok then
			Live.networkErrorCount = Live.networkErrorCount + 1
			warn("[StudioStud] delta network error (x" .. Live.networkErrorCount .. "):", result and result.error or "no response")
			Live.verifyNeeded = true
			if Live.networkErrorCount >= 4 then
				task.defer(function()
					if Live.liveRunning then
						warn("[StudioStud] daemon unreachable — pausing live, will reconnect automatically")
						Live.teardown()
						ctx.setConnected(false)
						sessionHasBaseline = false
						setConnectButtonState()
						ctx.setStatus("error", "Daemon offline — reconnecting automatically")
						ctx.setStats("")
					end
				end)
			end
		end
		finish()
		-- On network error: keep dirty sets; retry next debounce cycle
	end

	-- Send a full verify snapshot → /live/verify/*
	function Live.sendVerify()
		if not Live.liveRunning then
			return
		end
		-- Edit-session gate: never build/send the verify snapshot during a play session.
		if not Session.isEdit() then
			return
		end
		if Live.syncInFlight then
			return
		end
		Live.syncInFlight = true
		local function finish()
			Live.syncInFlight = false
		end

		debugLog("verify: building snapshot...")
		local snapshot = Capture.buildSnapshot({ reason = "live-verify" })
		local jsonText = HttpService:JSONEncode(snapshot)
		local maxChunk = 900000
		local okStart, startResult = ctx.transport.requestJson("POST", "/studio-stud/live/verify/start", {
			pluginVersion = PLUGIN_VERSION,
			protocolVersion = PROTOCOL_VERSION,
		})
		if not okStart then
			warn("[StudioStud] verify: start failed:", startResult and startResult.error or "no response")
			Live.verifyNeeded = true -- retry on next cycle
			finish()
			return
		end
		local syncId = startResult.syncId
		if #jsonText <= maxChunk then
			local okBody = ctx.transport.requestBody(
				"/studio-stud/live/verify/body?syncId=" .. HttpService:UrlEncode(syncId),
				jsonText
			)
			if not okBody then
				warn("[StudioStud] verify: body upload failed")
				Live.verifyNeeded = true
				finish()
				return
			end
		else
			local chunkCount = math.ceil(#jsonText / maxChunk)
			for i = 1, chunkCount do
				local startByte = ((i - 1) * maxChunk) + 1
				local chunk = string.sub(jsonText, startByte, startByte + maxChunk - 1)
				local okChunk = ctx.transport.requestBody(
					("/studio-stud/live/verify/chunk?syncId=%s&index=%d"):format(
						HttpService:UrlEncode(syncId),
						i - 1
					),
					chunk
				)
				if not okChunk then
					warn("[StudioStud] verify: chunk", i, "upload failed")
					Live.verifyNeeded = true
					finish()
					return
				end
			end
		end
		local expectedChunks = nil
		if #jsonText > maxChunk then
			expectedChunks = math.ceil(#jsonText / maxChunk)
		end
		local okComplete, completeResult = ctx.transport.requestJson("POST", "/studio-stud/live/verify/complete", {
			syncId = syncId,
			placeId = tostring(game.PlaceId),
			expectedChunks = expectedChunks,
		}, 120)
		if okComplete and completeResult and completeResult.ok then
			local drift = completeResult.drift and #completeResult.drift or 0
			if drift > 0 then
				debugLog("verify: corrected", completeResult.corrected, "drifted instances, new rev=", completeResult.revision)
			else
				debugLog("verify: no drift, rev=", completeResult.revision)
			end
			if completeResult.revision then
				Live.currentRevision = completeResult.revision
			end
			Live.networkErrorCount = 0
			-- Full snapshot replaced daemon state — local dirty tracking is stale
			Live.dirtyUpsert = {}
			Live.dirtyRemoved = {}
			ctx.setStatus("connected", "Live — delta streaming active")
			ctx.setStats(("rev %d · %d instances"):format(Live.currentRevision, Live.liveInstanceCount))
		else
			local errText = completeResult and completeResult.error or "no response"
			warn("[StudioStud] verify: complete failed:", errText)
			if responseNeedsRebaseline(completeResult) then
				Live.triggerRebaseline("verify-unknown-sync")
			else
				Live.verifyNeeded = true
			end
			finish()
			return
		end
		Live.verifyNeeded = false
		finish()
	end

	function Live.startDebounceLoop()
		task.spawn(function()
			while Live.liveRunning do
				local debounceSeconds = Settings.getDebounceMs() / 1000
				task.wait(debounceSeconds)
				if not Live.liveRunning then
					break
				end
				if Live.syncInFlight then
					continue
				end
				if next(Live.dirtyUpsert) or next(Live.dirtyRemoved) then
					local ok, err = pcall(Live.flushDirty)
					if not ok then
						warn("[StudioStud] flushDirty error:", err)
					end
				end
			end
		end)
	end

	function Live.startVerifyLoop()
		local checkSeconds = 45
		local hardVerifySeconds = 180 -- full verify every 3 minutes regardless
		local elapsed = 0
		task.spawn(function()
			while Live.liveRunning do
				task.wait(checkSeconds)
				if not Live.liveRunning then
					break
				end
				elapsed += checkSeconds
				-- Update stats line every heartbeat
				do
					local pending = 0
					for _ in pairs(Live.dirtyUpsert) do pending += 1 end
					for _ in pairs(Live.dirtyRemoved) do pending += 1 end
					local statsText = ("rev %d · %d instances"):format(Live.currentRevision, Live.liveInstanceCount)
					if pending > 0 then
						statsText = statsText .. (" · %d pending"):format(pending)
					end
					ctx.setStats(statsText)
				end

				local shouldVerify = Live.verifyNeeded or elapsed >= hardVerifySeconds
				if not shouldVerify then
					-- Quick instance-count check via fingerprint endpoint
					if Live.syncInFlight then
						continue
					end
					local ok, result = ctx.transport.requestJson(
						"GET",
						"/studio-stud/live/fingerprint?placeId=" .. HttpService:UrlEncode(tostring(game.PlaceId)),
						nil
					)
					if ok and result and result.ok then
						local daemonCount = result.instanceCount
						if daemonCount and daemonCount ~= Live.liveInstanceCount then
							shouldVerify = true
						end
					end
				end
				if next(Live.dirtyUpsert) or next(Live.dirtyRemoved) then
					-- Try flushing deltas before falling back to a full verify
					if not Live.syncInFlight then
						Live.flushDirty()
					end
					if next(Live.dirtyUpsert) or next(Live.dirtyRemoved) then
						shouldVerify = true
					end
				end
				if shouldVerify and not Live.syncInFlight then
					debugLog("verify: triggered (verifyNeeded=", Live.verifyNeeded, "elapsed=", elapsed, "s)")
					Live.sendVerify()
					elapsed = 0
				end
			end
		end)
	end

	function Live.teardown()
		Live.liveRunning = false
		for _, conn in ipairs(Live.rootConns) do
			pcall(function()
				conn:Disconnect()
			end)
		end
		Live.rootConns = {}
		for _, conn in ipairs(Live.globalConns) do
			pcall(function()
				conn:Disconnect()
			end)
		end
		Live.globalConns = {}
		-- Disconnect all per-instance connections by replacing the table
		for _, conns in pairs(Live.instConns) do
			for _, conn in ipairs(conns) do
				pcall(function()
					conn:Disconnect()
				end)
			end
		end
		Live.instConns = {}
		Live.dirtyUpsert = {}
		Live.networkErrorCount = 0
		Live.dirtyRemoved = {}
		Live.parentByInst = {}
		Live.currentRevision = 0
		Live.liveInstanceCount = 0
		Live.verifyNeeded = false
	end

	-- Activate live mode after a successful baseline capture
	function Live.setupAfterBaseline(materialized)
		if not Settings.getBool(SETTINGS.liveCaptureEnabled, true) then
			return
		end
		Live.teardown()
		Live.liveRunning = true
		Live.currentRevision = (materialized and materialized.revision) or 0
		Live.liveInstanceCount = (materialized and (materialized.instances or materialized.totalItems)) or 0

		-- Register all instances from the just-completed baseline walk
		for inst, _ in pairs(instanceIdByRef) do
			Live.parentByInst[inst] = inst.Parent
			Live.registerInstance(inst)
		end

		-- Connect DescendantAdded/Removing on each captured root service
		for _, root in ipairs(Capture.getRootEntries()) do
			if root.includeDescendants then
				local rootInst = root.instance
				table.insert(
					Live.rootConns,
					rootInst.DescendantAdded:Connect(function(child)
						Live.onDescendantAdded(child)
					end)
				)
				table.insert(
					Live.rootConns,
					rootInst.DescendantRemoving:Connect(function(child)
						Live.onDescendantRemoving(child)
					end)
				)
			end
		end

		-- Selection changes → dirty selected instances (selection metadata in future)
		local selOk, selConn = pcall(function()
			local Selection = game:GetService("Selection")
			return Selection.SelectionChanged:Connect(function()
				local ok, selected = pcall(function()
					return Selection:Get()
				end)
				if ok then
					for _, inst in ipairs(selected) do
						if instanceIdByRef[inst] then
							Live.dirtyUpsert[inst] = true
						end
					end
				end
			end)
		end)
		if selOk then
			table.insert(Live.globalConns, selConn)
		end

		-- ChangeHistoryService: undo/redo → trigger a full verify on next cycle
		local undoOk, undoConn = pcall(function()
			return ChangeHistoryService.OnUndo:Connect(function()
				Live.verifyNeeded = true
			end)
		end)
		if undoOk then
			table.insert(Live.globalConns, undoConn)
		end
		local redoOk, redoConn = pcall(function()
			return ChangeHistoryService.OnRedo:Connect(function()
				Live.verifyNeeded = true
			end)
		end)
		if redoOk then
			table.insert(Live.globalConns, redoConn)
		end

		ctx.setStatus("connected", "Live — delta streaming active")
		ctx.setStats(("rev %d · %d instances"):format(Live.currentRevision, Live.liveInstanceCount))
		Live.startDebounceLoop()
		Live.startVerifyLoop()
	end

	local connectConnection = connectButton.MouseButton1Click:Connect(function()
		if ctx.isConnected() then
			syncFn({ reason = "manual" })
		else
			startupConnectAndCapture()
		end
	end)

	-- Smart catch-up when returning from a play session to edit. Cheap fingerprint
	-- short-circuit when the daemon still holds our pre-play baseline (the common case,
	-- since Stop restores the edit tree); otherwise a full re-baseline.
	local pausedBaseline = nil
	local function onReturnToEdit()
		task.wait(1.5) -- let the edit DataModel settle after Stop
		if not Session.isEdit() then
			return -- bounced back into a play session; the poll loop will re-handle
		end
		local baseline = pausedBaseline
		pausedBaseline = nil
		local resumed = false
		if baseline then
			local ok, result = ctx.transport.requestJson(
				"GET",
				"/studio-stud/live/fingerprint?placeId=" .. HttpService:UrlEncode(tostring(game.PlaceId)),
				nil
			)
			if
				ok
				and result
				and result.ok
				and result.revision == baseline.revision
				and result.instanceCount == baseline.instanceCount
			then
				-- Daemon still holds our baseline → re-arm live without a full re-walk.
				-- Defer one verify to reconcile any F8 run-persisted edit-tree drift.
				Live.setupAfterBaseline({ revision = result.revision, instances = result.instanceCount })
				Live.verifyNeeded = true
				ctx.setConnected(true)
				sessionHasBaseline = true
				setConnectButtonState()
				ctx.setStatus(
					"connected",
					("Live resumed — rev %d · %d instances · ready"):format(
						tonumber(result.revision) or 0,
						tonumber(result.instanceCount) or 0
					)
				)
				ctx.setStats(
					("rev %d · %d instances"):format(
						tonumber(result.revision) or 0,
						tonumber(result.instanceCount) or 0
					)
				)
				debugLog("session: resumed live via fingerprint short-circuit (rev ", result.revision, ")")
				resumed = true
			end
		end
		if not resumed then
			debugLog("session: return-to-edit needs full re-baseline")
			Live.triggerRebaseline("return-to-edit")
		end
	end

	pollGeneration += 1
	local myGeneration = pollGeneration
	local lastSessionMode = Session.mode()
	task.spawn(function()
		while running do
			task.wait(3)
			if not running then
				break
			end

			-- Edit/play session state machine: detect transitions each tick.
			local mode = Session.mode()
			if mode ~= lastSessionMode then
				lastSessionMode = mode
				if mode == "play" then
					-- edit → play: snapshot the baseline, drop live connections so no dirty
					-- accumulates, and pause all daemon comms (heartbeat continues below).
					pausedBaseline = {
						revision = (Live and Live.currentRevision) or 0,
						instanceCount = (Live and Live.liveInstanceCount) or 0,
					}
					if Live and Live.liveRunning then
						Live.teardown()
					end
					ctx.setStatus("idle", "Paused — Studio in play session")
					ctx.setStats("")
					debugLog("session: entered play — live paused, baseline rev ", pausedBaseline.revision)
				else
					-- play → edit: smart catch-up (debounced) then resume.
					debugLog("session: returned to edit — scheduling catch-up")
					task.defer(onReturnToEdit)
				end
			end

			-- Heartbeat every tick so the daemon learns our session mode (carried as a
			-- query param). This is the only daemon traffic during a play session.
			local ok, result = ctx.transport.requestJson(
				"GET",
				"/studio-stud/capture/request?sessionMode=" .. HttpService:UrlEncode(mode),
				nil
			)

			-- During a play session: heartbeat only — no captures, no reconnects.
			if mode ~= "edit" then
				continue
			end

			if ok then
				-- Daemon reachable
				if result and result.request and not syncing then
					syncFn(result.request.options or { reason = result.request.reason or "daemon-request" })
				end
				-- Auto-reconnect: if live went down (daemon restart or network hiccup), re-baseline
				if not (Live and Live.liveRunning) and not syncing and not ctx.isConnected() then
					debugLog("poll: daemon is back — reconnecting")
					ctx.setConnected(true)
					sessionHasBaseline = false
					setConnectButtonState()
					ctx.setStatus("syncing", "Daemon back — reconnecting...")
					task.defer(startupConnectAndCapture)
				end
			else
				-- Daemon unreachable — update UI if live was running
				if Live and Live.liveRunning then
					warn("[StudioStud] poll: daemon unreachable — pausing live")
					Live.teardown()
					ctx.setConnected(false)
					sessionHasBaseline = false
					setConnectButtonState()
					ctx.setStatus("error", "Daemon offline — reconnecting automatically")
					ctx.setStats("")
				elseif ctx.isConnected() then
					ctx.setConnected(false)
					setConnectButtonState()
					ctx.setStatus("error", "Daemon offline — reconnecting automatically")
					ctx.setStats("")
				end
			end
		end
	end)

	GlobalApi.wireCapture(statusFn, syncFn)

	local function destroy()
		running = false
		if Live then
			Live.teardown()
		end
		connectConnection:Disconnect()
		GlobalApi.installNoOps()
	end

	return {
		frame = parent,
		sync = syncFn,
		status = statusFn,
		isRunning = function()
			return running
		end,
		pollGeneration = myGeneration,
		onConnectRequested = startupConnectAndCapture,
		destroy = destroy,
		live = Live, -- exposed for self-tests and _G.StudioStud.Live
		capture = Capture, -- Phase 3: exposed for self-tests
	}
end

CapturePanel.descriptor = {
	id = "capture",
	title = "Capture / Query",
	defaultEnabled = true,
	build = CapturePanel.build,
}

-- == Shell ==

local Shell = {
	widget = nil,
	toolbarButton = nil,
	mainFrame = nil,
	contentFrame = nil,
	panelHost = nil,
	tabStrip = nil,
	settingsFrame = nil,
	statusCard = nil,
	connected = false,
}

local widgetInfo = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 380, 260, 340, 220)
Shell.widget = plugin:CreateDockWidgetPluginGui("StudioStud", widgetInfo)
Shell.widget.Title = "Studio Stud"

local toolbar = plugin:CreateToolbar("Studio Stud")
local toolbarIcon = if resolvedLogoAssetId ~= "" then resolvedLogoAssetId else DEFAULT_TOOLBAR_ICON
local toolbarOk, toolbarResult = pcall(function()
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

function Shell.makeCtx()
	return {
		theme = Theme,
		ui = Ui,
		transport = Transport,
		settings = Settings,
		plugin = plugin,
		widget = Shell.widget,
		setStatus = function(state, message)
			if Shell.statusCard then
				Shell.statusCard.setState(state, message)
			end
		end,
		setStats = function(text)
			if Shell.statusCard then
				Shell.statusCard.setStats(text)
			end
		end,
		isConnected = function()
			return Shell.connected
		end,
		setConnected = function(value)
			Shell.connected = value
		end,
	}
end

function Shell.renderTabStrip()
	if not Shell.tabStrip then
		return
	end
	for _, child in ipairs(Shell.tabStrip:GetChildren()) do
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
		tab.Size = UDim2.fromOffset(math.max(96, #item.title * 7 + 24), 28)
		tab.Position = UDim2.fromOffset(x, 2)
		tab.Parent = Shell.tabStrip
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
		x += math.max(96, #item.title * 7 + 24) + 6
	end
end

function Shell.openSettings()
	if Shell.settingsFrame then
		local placeLabel = Shell.settingsFrame:FindFirstChild("PlaceLabel", true)
		if placeLabel and placeLabel:IsA("TextLabel") then
			placeLabel.Text = ("Studio: %s  |  PlaceId: %s"):format(game.Name, tostring(game.PlaceId))
		end
		Shell.settingsFrame.Visible = true
	end
	if Shell.contentFrame then
		Shell.contentFrame.Visible = false
	end
end

function Shell.closeSettings()
	if Shell.settingsFrame then
		Shell.settingsFrame.Visible = false
	end
	if Shell.contentFrame then
		Shell.contentFrame.Visible = true
	end
end

function Shell.buildSettingsOverlay(parent)
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
	local liveButton = Ui.makeSecondaryButton(scroll, liveEnabled and "Live capture: ON" or "Live capture: OFF")
	liveButton.Position = UDim2.fromOffset(Theme.PAD, y)
	liveButton.Size = UDim2.new(1, -Theme.PAD * 2, 0, 32)
	liveButton.MouseButton1Click:Connect(function()
		liveEnabled = not liveEnabled
		Settings.setBool(SETTINGS.liveCaptureEnabled, liveEnabled)
		liveButton.Text = liveEnabled and "Live capture: ON" or "Live capture: OFF"
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
	Ui.makeMsSlider(scroll, y, DEBOUNCE_MS_MIN, DEBOUNCE_MS_MAX, Settings.getDebounceMs(), function(ms)
		Settings.setDebounceMs(ms)
	end)
	y += 64

	Ui.makeSectionLabel(scroll, "Debug logging", y)
	y += 18
	local debugEnabled = Settings.getBool(SETTINGS.debugLogging, false)
	local debugButton = Ui.makeSecondaryButton(scroll, debugEnabled and "Debug logs: ON" or "Debug logs: OFF")
	debugButton.Position = UDim2.fromOffset(Theme.PAD, y)
	debugButton.Size = UDim2.new(1, -Theme.PAD * 2, 0, 32)
	debugButton.MouseButton1Click:Connect(function()
		debugEnabled = not debugEnabled
		Settings.setBool(SETTINGS.debugLogging, debugEnabled)
		debugButton.Text = debugEnabled and "Debug logs: ON" or "Debug logs: OFF"
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
			nameLabel.Size = UDim2.new(0.65, 0, 1, 0)
			nameLabel.FontFace = Theme.UI_FONT
			nameLabel.TextColor3 = Theme.body
			nameLabel.TextSize = 13
			nameLabel.TextXAlignment = Enum.TextXAlignment.Left
			nameLabel.Text = tostring(id)
			nameLabel.Parent = row
			local toggle = Ui.makeSecondaryButton(row, enabled and "Enabled" or "Disabled")
			toggle.Size = UDim2.new(0.32, 0, 1, 0)
			toggle.Position = UDim2.new(0.68, 0, 0, 0)
			toggle.MouseButton1Click:Connect(function()
				local path = enabled and "/studio-stud/addons/disable" or "/studio-stud/addons/enable"
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
			nameLabel.Size = UDim2.new(0.65, 0, 1, 0)
			nameLabel.FontFace = Theme.UI_FONT
			nameLabel.TextColor3 = Theme.body
			nameLabel.TextSize = 13
			nameLabel.TextXAlignment = Enum.TextXAlignment.Left
			nameLabel.Text = item.title
			nameLabel.Parent = row

			local panelId = item.id
			local toggle = Ui.makeSecondaryButton(row, item.enabled and "Enabled" or "Disabled")
			toggle.Size = UDim2.new(0.32, 0, 1, 0)
			toggle.Position = UDim2.new(0.68, 0, 0, 0)
			toggle.MouseButton1Click:Connect(function()
				local newValue = not Settings.getPanelEnabled(panelId, item.defaultEnabled)
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

function Shell.build()
	Shell.widget:ClearAllChildren()
	Registry.teardownAll()
	Shell.connected = false

	Shell.mainFrame = Instance.new("Frame")
	Shell.mainFrame.BackgroundColor3 = Theme.panel
	Shell.mainFrame.BorderSizePixel = 0
	Shell.mainFrame.Size = UDim2.fromScale(1, 1)
	Shell.mainFrame.Parent = Shell.widget

	local topRule = Instance.new("Frame")
	topRule.BackgroundColor3 = Theme.copperDim
	topRule.BorderSizePixel = 0
	topRule.Size = UDim2.new(1, 0, 0, 2)
	topRule.Parent = Shell.mainFrame

	Shell.contentFrame = Instance.new("Frame")
	Shell.contentFrame.BackgroundTransparency = 1
	Shell.contentFrame.Position = UDim2.fromOffset(0, 2)
	Shell.contentFrame.Size = UDim2.new(1, 0, 1, -2)
	Shell.contentFrame.Parent = Shell.mainFrame

	local header = Instance.new("Frame")
	header.BackgroundTransparency = 1
	header.Position = UDim2.fromOffset(Theme.PAD, Theme.PAD)
	header.Size = UDim2.new(1, -Theme.PAD * 2, 0, 52)
	header.Parent = Shell.contentFrame

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
	settingsButton.Position = UDim2.new(1, 0, 0, 0)
	settingsButton.Size = UDim2.fromOffset(72, 32)
	settingsButton.MouseButton1Click:Connect(function()
		Shell.openSettings()
	end)

	local STATUS_CARD_H = 54
	Shell.statusCard = Ui.makeStatusCard(Shell.contentFrame, Theme.PAD + 52 + 8)
	Shell.statusCard.setState("idle", "Waiting for daemon")

	Shell.tabStrip = Instance.new("Frame")
	Shell.tabStrip.Name = "TabStrip"
	Shell.tabStrip.BackgroundTransparency = 1
	Shell.tabStrip.Position = UDim2.fromOffset(Theme.PAD, Theme.PAD + 52 + 8 + STATUS_CARD_H + 8)
	Shell.tabStrip.Size = UDim2.new(1, -Theme.PAD * 2, 0, 32)
	Shell.tabStrip.Parent = Shell.contentFrame

	local panelTop = Theme.PAD + 52 + 8 + STATUS_CARD_H + 8 + 32 + 8
	Shell.panelHost = Instance.new("Frame")
	Shell.panelHost.Name = "PanelHost"
	Shell.panelHost.BackgroundTransparency = 1
	Shell.panelHost.Position = UDim2.fromOffset(0, panelTop)
	Shell.panelHost.Size = UDim2.new(1, 0, 1, -panelTop)
	Shell.panelHost.Parent = Shell.contentFrame

	Registry.setHost(Shell.panelHost, Shell.makeCtx, Shell.renderTabStrip)
	Shell.buildSettingsOverlay(Shell.mainFrame)

	local firstId = Registry.firstEnabledId()
	if firstId then
		Registry.select(firstId)
	end
	Shell.renderTabStrip()
end

function Shell.onWidgetEnabled()
	local selectedId = Registry.selected()
	if selectedId then
		local handle = Registry.getHandle(selectedId)
		if handle and handle.onConnectRequested then
			handle.onConnectRequested()
		end
	else
		local firstId = Registry.firstEnabledId()
		if firstId then
			Registry.select(firstId)
			local handle = Registry.getHandle(firstId)
			if handle and handle.onConnectRequested then
				handle.onConnectRequested()
			end
		end
	end
end

-- == SelfTest ==

local SelfTest = {}

function SelfTest.assert(name, condition, failures)
	if condition then
		print("[Studio Stud SelfTest] PASS:", name)
	else
		table.insert(failures, name)
		warn("[Studio Stud SelfTest] FAIL:", name)
	end
end

function SelfTest.run()
	local failures = {}
	local preIds = Registry.snapshotIds()
	local origLive = Settings.getBool(SETTINGS.liveCaptureEnabled, true)
	local origDebounce = Settings.getNumber(SETTINGS.debounceMs, 300)
	local origUrl = Settings.getString(SETTINGS.daemonUrl, DEFAULT_DAEMON_URL)

	local function makeDummy(id, title)
		local showCount = 0
		local hideCount = 0
		local destroyCount = 0
		local descriptor = {
			id = id,
			title = title,
			defaultEnabled = true,
			build = function(parent, _ctx)
				local label = Instance.new("TextLabel")
				label.BackgroundTransparency = 1
				label.Size = UDim2.fromScale(1, 1)
				label.FontFace = Theme.UI_FONT
				label.TextColor3 = Theme.body
				label.Text = title
				label.Parent = parent
				return {
					frame = parent,
					onShow = function()
						showCount += 1
					end,
					onHide = function()
						hideCount += 1
					end,
					destroy = function()
						destroyCount += 1
						parent:Destroy()
					end,
					showCount = function()
						return showCount
					end,
					hideCount = function()
						return hideCount
					end,
					destroyCount = function()
						return destroyCount
					end,
				}
			end,
		}
		return descriptor
	end

	local dummyA = makeDummy("__selftest_a", "SelfTest A")
	local dummyB = makeDummy("__selftest_b", "SelfTest B")

	local okA, errA = Registry.register(dummyA)
	SelfTest.assert("register dummy A", okA, failures)
	local okDup = Registry.register(dummyA)
	SelfTest.assert("reject duplicate id", not okDup, failures)
	local okB = Registry.register(dummyB)
	SelfTest.assert("register dummy B", okB, failures)

	local idsAfterRegister = Registry.snapshotIds()
	local indexA, indexB = nil, nil
	for index, id in ipairs(idsAfterRegister) do
		if id == "__selftest_a" then
			indexA = index
		elseif id == "__selftest_b" then
			indexB = index
		end
	end
	SelfTest.assert("registration order", indexA and indexB and indexA < indexB, failures)

	Registry.select("__selftest_a")
	Registry.select("__selftest_b")
	local handleA = Registry.getHandle("__selftest_a")
	local handleB = Registry.getHandle("__selftest_b")
	SelfTest.assert("select lifecycle onShow/onHide", handleA and handleB and handleA.hideCount() >= 1 and handleB.showCount() >= 1, failures)

	local visibleCount = 0
	for _, handle in pairs(Registry.handles) do
		if handle.frame and handle.frame.Visible then
			visibleCount += 1
		end
	end
	SelfTest.assert("one visible panel frame", visibleCount == 1, failures)

	Registry.setEnabled("__selftest_a", false)
	SelfTest.assert("disable persists", Settings.getPanelEnabled("__selftest_a", true) == false, failures)
	local enabledAfterDisable = false
	for _, item in ipairs(Registry.list()) do
		if item.id == "__selftest_a" and item.enabled then
			enabledAfterDisable = true
		end
	end
	SelfTest.assert("disabled panel excluded from enabled set", not enabledAfterDisable, failures)
	Registry.setEnabled("__selftest_a", true)

	Settings.setBool(SETTINGS.liveCaptureEnabled, false)
	Settings.setDebounceMs(450)
	Settings.setString(SETTINGS.daemonUrl, "http://127.0.0.1:31999")
	SelfTest.assert("settings round-trip bool", Settings.getBool(SETTINGS.liveCaptureEnabled, true) == false, failures)
	SelfTest.assert("settings round-trip number", Settings.getDebounceMs() == 450, failures)
	SelfTest.assert(
		"settings round-trip string",
		Settings.getString(SETTINGS.daemonUrl, DEFAULT_DAEMON_URL) == "http://127.0.0.1:31999",
		failures
	)

	Settings.setString(SETTINGS.writeToken, "selftest-write-token")
	SelfTest.assert(
		"write token settings round-trip",
		Settings.getString(SETTINGS.writeToken, "") == "selftest-write-token",
		failures
	)
	local authedHeaders = Transport.buildAuthedHeaders(Settings.getString(SETTINGS.writeToken, ""))
	SelfTest.assert(
		"requestJsonAuthed attaches write token header",
		authedHeaders["X-StudioStud-Token"] == "selftest-write-token",
		failures
	)
	Settings.setString(SETTINGS.writeToken, "")

	local captureHandleBefore = Registry.getHandle("capture")
	local oldRunningFn = captureHandleBefore and captureHandleBefore.isRunning
	local oldRunning = oldRunningFn and oldRunningFn() or false

	Registry.unregister("__selftest_a")
	Registry.unregister("__selftest_b")
	SelfTest.assert("unregister removes dummy ids", Registry.snapshotIds()[1] == "capture" and #Registry.snapshotIds() == 1, failures)

	Registry.teardownAll()
	SelfTest.assert("teardown stops capture loop", captureHandleBefore and not captureHandleBefore.isRunning(), failures)
	local disabledResult = _G.StudioStud and _G.StudioStud.Sync()
	SelfTest.assert(
		"_G no-op while torn down",
		disabledResult and disabledResult.ok == false and disabledResult.error == "panel disabled",
		failures
	)

	Shell.build()
	local captureHandleAfter = Registry.getHandle("capture")
	SelfTest.assert("re-init capture handle", captureHandleAfter ~= nil, failures)
	SelfTest.assert(
		"_G re-wire identity",
		_G.StudioStud and _G.StudioStud.Sync == captureHandleAfter.sync,
		failures
	)
	SelfTest.assert(
		"single poll loop after re-init",
		captureHandleAfter.isRunning() and (not oldRunning or not captureHandleBefore.isRunning()),
		failures
	)

	local tabCount = 0
	if Shell.tabStrip then
		for _, child in ipairs(Shell.tabStrip:GetChildren()) do
			if child:IsA("TextButton") then
				tabCount += 1
			end
		end
	end
	Shell.build()
	local tabCountAgain = 0
	if Shell.tabStrip then
		for _, child in ipairs(Shell.tabStrip:GetChildren()) do
			if child:IsA("TextButton") then
				tabCountAgain += 1
			end
		end
	end
	SelfTest.assert("idempotent Shell.build tab count", tabCountAgain == 1, failures)
	SelfTest.assert("no ghost selftest tabs", not string.find(table.concat(Registry.snapshotIds(), ","), "__selftest"), failures)

	-- == Live machinery self-tests (Workstream E) ==
	do
		-- GetDebugId stability across reparent
		local testFolder = Instance.new("Folder")
		testFolder.Name = "StudioStudSelfTestLive"
		testFolder.Parent = game:GetService("ReplicatedStorage")
		local idBefore = pcall(function() return testFolder:GetDebugId(0) end) and testFolder:GetDebugId(0) or ""
		testFolder.Parent = game:GetService("ServerStorage")
		local idAfter = pcall(function() return testFolder:GetDebugId(0) end) and testFolder:GetDebugId(0) or ""
		SelfTest.assert("GetDebugId stable across reparent", idBefore ~= "" and idBefore == idAfter, failures)
		testFolder:Destroy()
	end

	-- Live sub-table state after teardown
	local captureHandleLive = Registry.getHandle("capture")
	local live = captureHandleLive and captureHandleLive.live

	-- == Phase 3: getPropertyNames + curatedSet routing ==
	do
		local captureExports = Registry.getHandle("capture")
		local capture = captureExports and captureExports.capture
		if capture then
			local part = Instance.new("Part")
			-- not loaded -> static fallback includes CFrame (BasePart)
			AllowList.loaded = false
			local fallbackNames = capture.getPropertyNames(part)
			local hasCFrame = false
			for _, n in ipairs(fallbackNames) do
				if n == "CFrame" then
					hasCFrame = true
				end
			end
			SelfTest.assert("getPropertyNames fallback includes CFrame", hasCFrame, failures)
			-- loaded -> uses the allow-list
			AllowList.loaded = true
			AllowList.lists = { Part = { "Transparency" } }
			AllowList.sets = { Part = { Transparency = false } }
			local allowNames = capture.getPropertyNames(part)
			SelfTest.assert(
				"getPropertyNames uses allow-list when loaded",
				#allowNames == 1 and allowNames[1] == "Transparency",
				failures
			)
			SelfTest.assert("curatedSet membership from allow-list", capture.curatedSet(part).Transparency == false, failures)
			-- restore
			AllowList.loaded = false
			AllowList.lists = {}
			AllowList.sets = {}
			part:Destroy()
		else
			print("[Studio Stud SelfTest] SKIP: capture handle not available")
		end
	end

	-- == Phase 4: baseline yield + readPropsFrom + readSource ==
	do
		local captureExports = Registry.getHandle("capture")
		local capture = captureExports and captureExports.capture
		if capture then
			SelfTest.assert("shouldYield(0,500)=false", not capture.shouldYield(0, 500), failures)
			SelfTest.assert("shouldYield(500,500)=true", capture.shouldYield(500, 500), failures)
			SelfTest.assert("shouldYield(750,500)=false", not capture.shouldYield(750, 500), failures)
			SelfTest.assert("shouldYield(1000,500)=true", capture.shouldYield(1000, 500), failures)
			SelfTest.assert("shouldYield(5,0)=false", not capture.shouldYield(5, 0), failures)

			local fakeOk = { Transparency = 0.5, Size = Vector3.new(1, 2, 3) }
			local propsOk, errsOk = capture.readPropsFrom(fakeOk, { "Transparency", "Size" })
			SelfTest.assert(
				"readPropsFrom success path",
				propsOk.Transparency == 0.5 and propsOk.Size ~= nil and #errsOk == 0,
				failures
			)

			local fakeThrow = setmetatable({}, {
				__index = function(_, key)
					if key == "BadProp" then
						error("read failed")
					end
					return 1
				end,
			})
			local propsFb, errsFb = capture.readPropsFrom(fakeThrow, { "GoodProp", "BadProp", "GoodProp2" })
			SelfTest.assert(
				"readPropsFrom fallback returns rest",
				propsFb.GoodProp == 1 and propsFb.GoodProp2 == 1 and #errsFb == 1,
				failures
			)

			local mod = Instance.new("ModuleScript")
			mod.Source = "return 42"
			SelfTest.assert("readSource ModuleScript", capture.readSource(mod) == "return 42", failures)
			local part = Instance.new("Part")
			SelfTest.assert("readSource non-script nil", capture.readSource(part) == nil, failures)
			mod:Destroy()
			part:Destroy()
		else
			print("[Studio Stud SelfTest] SKIP: capture handle not available (phase 4)")
		end
	end

	if live then
		live.teardown()
		SelfTest.assert("live.teardown clears liveRunning", not live.liveRunning, failures)
		SelfTest.assert("live.teardown clears instConns", next(live.instConns) == nil, failures)
		SelfTest.assert("live.teardown clears rootConns", #live.rootConns == 0, failures)
		SelfTest.assert("live.teardown clears globalConns", #live.globalConns == 0, failures)
		SelfTest.assert("live.teardown resets revision", live.currentRevision == 0, failures)
		SelfTest.assert("live.teardown resets liveInstanceCount", live.liveInstanceCount == 0, failures)
		SelfTest.assert("live.teardown clears dirtyUpsert", next(live.dirtyUpsert) == nil, failures)
		SelfTest.assert("live.teardown clears dirtyRemoved", next(live.dirtyRemoved) == nil, failures)
		SelfTest.assert("live.teardown resets verifyNeeded", live.verifyNeeded == false, failures)

		-- Settings gate: liveCaptureEnabled = false → setupAfterBaseline is a no-op
		Settings.setBool(SETTINGS.liveCaptureEnabled, false)
		live.setupAfterBaseline({ revision = 5, instances = 100 })
		SelfTest.assert("live gated by liveCaptureEnabled=false", not live.liveRunning, failures)
		Settings.setBool(SETTINGS.liveCaptureEnabled, true)

		-- Dirty-set precedence: removed wins over upserted for same id
		local dummyInst = Instance.new("Folder")
		dummyInst.Parent = game:GetService("ReplicatedStorage")
		local dummyId = dummyInst:GetDebugId(0)
		live.dirtyUpsert[dummyInst] = true
		live.dirtyRemoved[dummyId] = true
		-- buildUpsertedEntry should skip this inst because id is in dirtyRemoved
		local skipped = live.dirtyRemoved[dummyId] == true
		SelfTest.assert("removed wins over upserted in dirty sets", skipped, failures)
		live.dirtyUpsert = {}
		live.dirtyRemoved = {}
		dummyInst:Destroy()

		-- == Phase 3: detection collapse ==
		do
			local curated = { Transparency = false }
			SelfTest.assert("classify Name -> name", live.classifyChangedProp("Name", curated) == "name", failures)
			SelfTest.assert("classify Source -> dirty", live.classifyChangedProp("Source", curated) == "dirty", failures)
			SelfTest.assert("classify curated -> dirty", live.classifyChangedProp("Transparency", curated) == "dirty", failures)
			SelfTest.assert("classify uncurated -> gap", live.classifyChangedProp("Archivable", curated) == "gap", failures)

			-- gap-probe dedup
			live.propGaps = {}
			live.recordPropGap("Part", "Foo")
			live.recordPropGap("Part", "Foo")
			local gapCount = 0
			for _ in pairs(live.propGaps) do
				gapCount += 1
			end
			SelfTest.assert("recordPropGap dedups", gapCount == 1, failures)

			-- connection-count collapse: a Part should register ~3 connections, not ~20
			AllowList.loaded = true
			AllowList.lists = { Part = { "Transparency", "Size" } }
			AllowList.sets = { Part = { Transparency = false, Size = false } }
			local part = Instance.new("Part")
			live.registerInstance(part)
			local partConns = live.instConns[part]
			SelfTest.assert("registerInstance collapses Part to <=4 conns", partConns ~= nil and #partConns <= 4, failures)
			live.unregisterInstance(part)
			part:Destroy()

			-- ValueBase registers explicit signals (Ancestry + Attribute + Name + Value)
			local iv = Instance.new("IntValue")
			live.registerInstance(iv)
			local ivConns = live.instConns[iv]
			SelfTest.assert("ValueBase registers >=3 conns", ivConns ~= nil and #ivConns >= 3, failures)
			live.unregisterInstance(iv)
			iv:Destroy()

			AllowList.loaded = false
			AllowList.lists = {}
			AllowList.sets = {}
		end
	else
		-- Live handle not available: skip but don't fail
		print("[Studio Stud SelfTest] SKIP: live handle not available (live tests skipped)")
	end

	-- == Phase 3: allow-list parse (pure) ==
	do
		local parsed = AllowList.parse({
			version = "1.2.3.4",
			classes = {
				Part = {
					{ name = "Transparency", readOnly = false },
					{ name = "AbsoluteSize", readOnly = true },
				},
			},
		})
		SelfTest.assert("allowlist parse version", parsed ~= nil and parsed.version == "1.2.3.4", failures)
		SelfTest.assert("allowlist parse membership", parsed ~= nil and parsed.sets.Part.Transparency == false, failures)
		SelfTest.assert("allowlist parse readOnly flag", parsed ~= nil and parsed.sets.Part.AbsoluteSize == true, failures)
		SelfTest.assert("allowlist parse ordered list", parsed ~= nil and #parsed.lists.Part == 2, failures)
		SelfTest.assert("allowlist parse rejects bad input", AllowList.parse({}) == nil, failures)
	end

	-- == Edit-session gate self-tests ==
	-- SelfTest runs in a genuine edit session, so the primitive MUST resolve to edit.
	-- A failure here means the gate would wrongly suspend all capture during normal editing.
	do
		SelfTest.assert("Session.decide is a function", type(Session.decide) == "function", failures)
		SelfTest.assert("Session.signals is a function", type(Session.signals) == "function", failures)
		-- Pure decision truth table (independent of the live RunService):
		SelfTest.assert(
			"decide edit when isEdit & !isRunning",
			Session.decide({ isEdit = true, isRunning = false }) == "edit",
			failures
		)
		SelfTest.assert(
			"decide play when isRunning",
			Session.decide({ isEdit = false, isRunning = true }) == "play",
			failures
		)
		SelfTest.assert(
			"decide play when !isEdit",
			Session.decide({ isEdit = false, isRunning = false }) == "play",
			failures
		)
		SelfTest.assert(
			"decide play when isEdit & isRunning",
			Session.decide({ isEdit = true, isRunning = true }) == "play",
			failures
		)
		-- SelfTest runs in a genuine edit session, so the LIVE decision must be edit:
		SelfTest.assert("Session.mode() == 'edit' while editing", Session.mode() == "edit", failures)
	end

	Settings.setBool(SETTINGS.liveCaptureEnabled, origLive)
	Settings.setNumber(SETTINGS.debounceMs, origDebounce)
	Settings.setString(SETTINGS.daemonUrl, origUrl)
	SelfTest.assert("registry ids restored", Registry.snapshotIds()[1] == preIds[1] and #Registry.snapshotIds() == #preIds, failures)

	if #failures == 0 then
		print("[Studio Stud SelfTest] PASS — all checks passed")
		return true
	end
	warn("[Studio Stud SelfTest] FAIL — " .. tostring(#failures) .. " check(s) failed")
	return false
end

-- == Bootstrap ==

_G.StudioStud = _G.StudioStud or {}

Registry.register(CapturePanel.descriptor)
Shell.build()

_G.StudioStud.RunSelfTest = SelfTest.run

task.defer(function()
	Shell.onWidgetEnabled()
end)

Shell.toolbarButton.Click:Connect(function()
	Shell.widget.Enabled = not Shell.widget.Enabled
	Shell.toolbarButton:SetActive(Shell.widget.Enabled)
	if Shell.widget.Enabled then
		Shell.onWidgetEnabled()
	end
end)

plugin.Unloading:Connect(function()
	Registry.teardownAll()
	if _G.StudioStud and _G.StudioStud.RunSelfTest == SelfTest.run then
		_G.StudioStud = nil
	end
end)

local function showWelcomeOnce()
	local ok, value = pcall(function()
		return plugin:GetSetting(SETTINGS.welcomeVersion)
	end)
	if ok and value == WELCOME_VERSION then
		return
	end
	print("[Studio Stud] Loaded v" .. PLUGIN_VERSION .. ". Run `studio-stud serve`, then open this panel — it connects and captures automatically.")
	pcall(function()
		plugin:SetSetting(SETTINGS.welcomeVersion, WELCOME_VERSION)
	end)
end

showWelcomeOnce()
