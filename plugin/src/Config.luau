--!strict
-- Config — the single source of truth for every compile-time constant in the
-- plugin. Version/protocol numbers, the captured-service ordering, the static
-- CLASS_PROPERTIES curation fallback, tick thresholds/intervals, and icon ids
-- all live here so no other module re-declares them. Ported verbatim from the
-- monolith's Config section (StudioStud.plugin.lua:49-504) plus the constants
-- that section's consumers later read (TICK_INLINE_THRESHOLD, BASELINE_YIELD_EVERY,
-- the bulk-chunk default, the startup-connect delay).
--
-- Constants ONLY: stateful/runtime helpers from the old Config block
-- (`updateInstallHint`, `checkRemoteUpdate`) are NOT constants — they carry
-- per-ping mutable state and belong with their daemon/UI consumers, not here.
-- The one pure helper kept is `normalizePluginAssetId`, used solely to resolve
-- the icon-id constant `resolvedLogoAssetId` at load time.

-- == Public interface ==

export type ConfigModule = {
	-- Version / protocol handshake.
	PLUGIN_VERSION: string,
	PROTOCOL_VERSION: number,
	MIN_DAEMON_PROTOCOL_VERSION: number,

	-- Identity / defaults.
	SERVICE_NAME: string,
	DEFAULT_DAEMON_URL: string,
	WELCOME_VERSION: string,

	-- Persisted-setting key names (single source of truth — Settings/Transport/
	-- init read these, never literal strings).
	SETTINGS: {
		daemonUrl: string,
		welcomeVersion: string,
		liveCaptureEnabled: string,
		debounceMs: string,
		debugLogging: string,
		settingsRev: string,
		panelEnabled: string,
		writeToken: string,
	},

	-- Debounce / tick-interval bounds (the interval is debounceMs/1000).
	DEBOUNCE_MS_MIN: number,
	DEBOUNCE_MS_MAX: number,
	DEBOUNCE_MS_DEFAULT: number,

	-- Captured-service ordering: ordered list, name→index map, and the subset
	-- whose descendants are walked.
	ROOT_SERVICE_ORDER: { string },
	ROOT_SERVICE_INDEX: { [string]: number },
	DESCENDANT_ROOT_SERVICES: { [string]: boolean },

	-- Static property-curation fallback (used when /allowlist is unavailable).
	CLASS_PROPERTIES: { [string]: { string } },

	-- Tick thresholds / intervals.
	TICK_INLINE_THRESHOLD: number, -- bytes; over this, ops spill to /tick/bulk
	BASELINE_YIELD_EVERY: number, -- instances per cooperative yield in the walk
	DEFAULT_BULK_CHUNK_BYTES: number, -- fallback when daemon omits maxChunkBytes
	STARTUP_CONNECT_DELAY: number, -- seconds before the auto-connect attempt

	-- Toolbar / logo icon ids.
	DEFAULT_TOOLBAR_ICON: string,
	PLUGIN_LOGO_ASSET_ID: string, -- raw, may be "" or numeric; resolved below
	resolvedLogoAssetId: string, -- "" or a valid rbxassetid://… string

	-- Pure helper retained to resolve the icon-id constant. Normalizes a raw
	-- asset id: trims, accepts a bare numeric id (→ rbxassetid://N) or an
	-- existing rbxassetid:///rbxasset:// url; returns "" for anything else.
	normalizePluginAssetId: (raw: string) -> string,
}

-- == Version / protocol ==

local PLUGIN_VERSION = "0.4.29"
local PROTOCOL_VERSION = 2
-- Minimum daemon protocol this plugin can talk to. Half of the mutual version
-- handshake: the daemon advertises minPluginProtocolVersion, the plugin enforces
-- MIN_DAEMON_PROTOCOL_VERSION, so each side can tell the user which one is behind.
local MIN_DAEMON_PROTOCOL_VERSION = 2

-- == Identity / defaults ==

local SERVICE_NAME = "studio-stud"
local DEFAULT_DAEMON_URL = "http://127.0.0.1:31878"
local WELCOME_VERSION = "2026-06-01-stage1-v1"

-- == Persisted-setting keys ==

local SETTINGS = {
	daemonUrl = "StudioStudDaemonUrl",
	welcomeVersion = "StudioStudWelcomeVersion",
	liveCaptureEnabled = "StudioStudLiveCaptureEnabled",
	debounceMs = "StudioStudDebounceMs",
	debugLogging = "StudioStudDebugLogging",
	settingsRev = "StudioStudSettingsRev",
	panelEnabled = "StudioStudPanelEnabled",
	writeToken = "StudioStudWriteToken",
}

-- == Debounce bounds ==

local DEBOUNCE_MS_MIN = 100
local DEBOUNCE_MS_MAX = 1000
local DEBOUNCE_MS_DEFAULT = 500

-- == Tick thresholds / intervals ==

-- Inline ops budget: a tick whose serialized ops exceed this spills to a chunked
-- /tick/bulk upload instead of riding inline (monolith :2365).
local TICK_INLINE_THRESHOLD = 256 * 1024
-- Cooperative-yield cadence for the baseline tree walk (monolith :1621).
local BASELINE_YIELD_EVERY = 500
-- Fallback chunk size when the daemon's bulk/start omits maxChunkBytes (:2912).
local DEFAULT_BULK_CHUNK_BYTES = 900000
-- Delay before the startup auto-connect attempt (monolith :3281).
local STARTUP_CONNECT_DELAY = 1.5

-- == Icon ids ==

local PLUGIN_LOGO_ASSET_ID = ""
local DEFAULT_TOOLBAR_ICON = "rbxassetid://14978048121"

-- Normalize a raw asset id to a usable image string, or "" if unusable.
-- Trims surrounding whitespace; a bare numeric id becomes rbxassetid://N; an
-- existing rbxassetid:// or rbxasset:// url passes through; anything else → "".
local function normalizePluginAssetId(raw: string): string
	raw = string.gsub(raw, "^%s+", "")
	raw = string.gsub(raw, "%s+$", "")
	if raw == "" then
		return ""
	end
	local numeric = string.match(raw, "^(%d+)$")
	if numeric then
		return "rbxassetid://" .. numeric
	end
	if string.find(raw, "^rbxassetid://", 1, true) or string.find(raw, "^rbxasset://", 1, true) then
		return raw
	end
	return ""
end

local resolvedLogoAssetId = normalizePluginAssetId(PLUGIN_LOGO_ASSET_ID)

-- == Captured-service ordering ==

-- The deterministic order captured root services are walked/emitted in. The
-- index map below pins each service's wire ordinal; DESCENDANT_ROOT_SERVICES is
-- the subset whose subtrees are descended (others are captured as leaf roots).
local ROOT_SERVICE_ORDER: { string } = {
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

local ROOT_SERVICE_INDEX: { [string]: number } = {}
for index, serviceName in ROOT_SERVICE_ORDER do
	ROOT_SERVICE_INDEX[serviceName] = index
end

local DESCENDANT_ROOT_SERVICES: { [string]: boolean } = {
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

-- == Static property curation (allow-list fallback) ==

local CLASS_PROPERTIES: { [string]: { string } } = {
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

-- == Module table ==

local Config: ConfigModule = {
	PLUGIN_VERSION = PLUGIN_VERSION,
	PROTOCOL_VERSION = PROTOCOL_VERSION,
	MIN_DAEMON_PROTOCOL_VERSION = MIN_DAEMON_PROTOCOL_VERSION,

	SERVICE_NAME = SERVICE_NAME,
	DEFAULT_DAEMON_URL = DEFAULT_DAEMON_URL,
	WELCOME_VERSION = WELCOME_VERSION,

	SETTINGS = SETTINGS,

	DEBOUNCE_MS_MIN = DEBOUNCE_MS_MIN,
	DEBOUNCE_MS_MAX = DEBOUNCE_MS_MAX,
	DEBOUNCE_MS_DEFAULT = DEBOUNCE_MS_DEFAULT,

	ROOT_SERVICE_ORDER = ROOT_SERVICE_ORDER,
	ROOT_SERVICE_INDEX = ROOT_SERVICE_INDEX,
	DESCENDANT_ROOT_SERVICES = DESCENDANT_ROOT_SERVICES,

	CLASS_PROPERTIES = CLASS_PROPERTIES,

	TICK_INLINE_THRESHOLD = TICK_INLINE_THRESHOLD,
	BASELINE_YIELD_EVERY = BASELINE_YIELD_EVERY,
	DEFAULT_BULK_CHUNK_BYTES = DEFAULT_BULK_CHUNK_BYTES,
	STARTUP_CONNECT_DELAY = STARTUP_CONNECT_DELAY,

	DEFAULT_TOOLBAR_ICON = DEFAULT_TOOLBAR_ICON,
	PLUGIN_LOGO_ASSET_ID = PLUGIN_LOGO_ASSET_ID,
	resolvedLogoAssetId = resolvedLogoAssetId,

	normalizePluginAssetId = normalizePluginAssetId,
}

return Config
