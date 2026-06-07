--!strict
-- Theme — the plugin's visual constants. Ported verbatim from the monolith's
-- Theme block (StudioStud.plugin.lua:507-524): the same RGB palette, the same
-- four font families/weights, and the same PAD spacing unit. No logic; every UI
-- module imports these so the palette lives in exactly one place (single source
-- of truth) and no view re-declares a colour or font.
--
-- Pure constants only, but NOT lune-testable: every value is a Roblox datatype
-- (Color3 / Font / number), so this module is exercised only in-engine via the
-- UI and SelfTest, never headless.

-- == Public interface ==

-- The exported theme. Frozen at construction (read-only) so a view can never
-- mutate a shared colour; consumers read fields, never assign them.
export type ThemeModule = {
	-- Palette (Color3, identical RGB to the monolith).
	panel: Color3,
	surface: Color3,
	surfaceBorder: Color3,
	copper: Color3,
	copperDim: Color3,
	teal: Color3,
	tealDim: Color3,
	muted: Color3,
	body: Color3,
	warn: Color3,
	badge: Color3,

	-- Fonts (family + weight, identical to the monolith).
	CODE_FONT: Font,
	UI_FONT: Font,
	UI_FONT_BOLD: Font,
	TITLE_FONT: Font,

	-- Base padding/spacing unit in pixels.
	PAD: number,
}

-- == Module table ==

local Theme: ThemeModule = table.freeze({
	-- Palette.
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

	-- Fonts.
	CODE_FONT = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Regular),
	UI_FONT = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Regular),
	UI_FONT_BOLD = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold),
	TITLE_FONT = Font.new("rbxasset://fonts/families/Merriweather.json", Enum.FontWeight.Bold),

	-- Spacing.
	PAD = 14,
})

return Theme
