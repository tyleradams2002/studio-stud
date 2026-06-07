--!strict
-- Registry — the panel/tab registry, ported faithfully from the monolith's
-- Registry block (StudioStud.plugin.lua:1354-1563). It owns the ordered list of
-- tab descriptors, the lazily-built per-tab handles, the currently selected tab,
-- and the host wiring (where panels are parented, how to build a panel context,
-- and what to call when the tab set changes). The view (Shell) reads this state
-- to render the tab strip; the bootstrap registers descriptors and selects the
-- first enabled tab.
--
-- Structure note (the bug class this rewrite kills): every method is a field on
-- the single `Registry` module table and reaches sibling methods through
-- `Registry.*` — a field read resolved at call time — so there is no
-- forward-referenced upvalue read before its `local` is assigned (C1-C3). The
-- monolith already used a module-table shape here; this port keeps that shape and
-- only adds the explicit typed interface.
--
-- Dependency: Settings is the single source of truth for per-panel enabled state
-- (getPanelEnabled / setPanelEnabled / clearPanelEnabled) — Registry never keeps a
-- parallel enabled map. It otherwise traffics only in Roblox UI datatypes
-- (Instance/UDim2), none of which are part of the protocol-v2 wire contract, so it
-- imports no aliases from ./Types (luau-craft: import what you use).

local Settings = require("./Settings")

-- == Public interface ==

-- A panel/tab descriptor as registered by a panel module. `id` and `title` and
-- `build` are required (validated at register time, the trust boundary for
-- descriptors); `defaultEnabled` defaults to enabled when absent (see Settings
-- membership semantics). `build(frame, ctx)` constructs the panel into `frame` and
-- returns its handle (or nil, in which case Registry synthesizes `{ frame = frame }`).
export type PanelDescriptor = {
	id: string,
	title: string,
	defaultEnabled: boolean?,
	build: (frame: Frame, ctx: any) -> PanelHandle?,
}

-- A built panel's handle. Registry only ever touches the fields below, and only
-- after a `~= nil` check (faithful to the monolith's `if handle.destroy then …
-- elseif handle.frame then`). Panels attach arbitrary extra fields (the SelfTest
-- dummy adds showCount()/hideCount(); the capture panel adds its live exports), so
-- the handle is an open table keyed by string — Registry stays agnostic to those
-- extras and the owning view reads them off getHandle(id). `frame` is the panel's
-- root Instance (used for show/hide visibility and as the destroy fallback).
export type PanelHandle = {
	frame: Frame?,
	destroy: (() -> ())?,
	onShow: (() -> ())?,
	onHide: (() -> ())?,
	[string]: any,
}

-- One row of `list()`: the descriptor's identity plus its resolved enabled state
-- (read through Settings, honouring defaultEnabled) and the descriptor itself.
export type PanelListItem = {
	id: string,
	title: string,
	defaultEnabled: boolean?,
	enabled: boolean,
	descriptor: PanelDescriptor,
}

-- The exported registry. Each method mirrors one monolith Registry.* function with
-- the same signature and behaviour. State fields (descriptors/handles/selectedId/
-- host wiring) are part of the table so methods read them as `Registry.*`.
export type RegistryModule = {
	-- Mutable state (held on the table, not a closure — see header).
	descriptors: { PanelDescriptor },
	handles: { [string]: PanelHandle },
	selectedId: string?,
	panelHost: Instance?,
	getCtx: (() -> any)?,
	onChange: (() -> ())?,

	-- Wire the host: where panels are parented, how to build a panel ctx, and the
	-- callback fired whenever the tab set/selection changes (the view re-renders).
	setHost: (panelHost: Instance, getCtx: () -> any, onChange: () -> ()) -> (),

	-- Add a descriptor (validated). Returns (true) on success, or (false, reason)
	-- for an invalid descriptor or a duplicate id. Fires onChange on success.
	register: (descriptor: PanelDescriptor) -> (boolean, string?),

	-- Remove a descriptor by id: destroy its handle, drop its enabled setting,
	-- clear selection if it was selected, fire onChange. Returns whether removed.
	unregister: (id: string) -> boolean,

	-- Snapshot every descriptor as a PanelListItem (with resolved enabled state).
	list: () -> { PanelListItem },

	-- Persist a panel's enabled flag. Disabling destroys its handle and, if it was
	-- selected, advances selection to the first remaining enabled tab. Fires
	-- onChange. Returns false iff the id is unknown.
	setEnabled: (id: string, enabled: boolean) -> boolean,

	-- The currently selected tab id (or nil).
	selected: () -> string?,

	-- Destroy every built handle and clear selection (panel host stays wired).
	teardownAll: () -> (),

	-- Select (and lazily build) a tab: hide the previous tab, build-on-first-show,
	-- run onShow, make its frame visible, fire onChange. Returns false if the host
	-- isn't wired or the target is unknown/disabled.
	select: (id: string) -> boolean,

	-- The built handle for a tab id (nil if never selected/built), opaque to
	-- Registry — the owning view reads panel-specific exports off it.
	getHandle: (id: string) -> PanelHandle?,

	-- The first enabled tab id in registration order (nil if none enabled).
	firstEnabledId: () -> string?,

	-- The number of registered descriptors.
	countIds: () -> number,

	-- Every registered id, sorted (stable snapshot for tests/diffs).
	snapshotIds: () -> { string },
}

-- == Module table ==

-- Single table; methods reach siblings via `Registry.*` (call-time field reads),
-- never via a forward-referenced local. State initialised to the monolith's
-- defaults: empty ordered descriptor list, empty handle map, nothing selected,
-- host unwired until setHost.
local Registry = {} :: RegistryModule
Registry.descriptors = {}
Registry.handles = {}
Registry.selectedId = nil
Registry.panelHost = nil
Registry.getCtx = nil
Registry.onChange = nil

function Registry.setHost(panelHost: Instance, getCtx: () -> any, onChange: () -> ()): ()
	Registry.panelHost = panelHost
	Registry.getCtx = getCtx
	Registry.onChange = onChange
end

function Registry.register(descriptor: PanelDescriptor): (boolean, string?)
	-- Trust boundary for descriptors: validate the required fields exactly as the
	-- monolith did (a malformed descriptor never enters the list).
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
	local onChange = Registry.onChange
	if onChange then
		onChange()
	end
	return true
end

function Registry.unregister(id: string): boolean
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
			local onChange = Registry.onChange
			if onChange then
				onChange()
			end
			return true
		end
	end
	return false
end

function Registry.list(): { PanelListItem }
	local items: { PanelListItem } = {}
	for _, descriptor in ipairs(Registry.descriptors) do
		table.insert(items, {
			id = descriptor.id,
			title = descriptor.title,
			defaultEnabled = descriptor.defaultEnabled,
			enabled = Settings.getPanelEnabled(descriptor.id, descriptor.defaultEnabled ~= false),
			descriptor = descriptor,
		})
	end
	return items
end

function Registry.setEnabled(id: string, enabled: boolean): boolean
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
	local onChange = Registry.onChange
	if onChange then
		onChange()
	end
	return true
end

function Registry.selected(): string?
	return Registry.selectedId
end

function Registry.teardownAll(): ()
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

function Registry.select(id: string): boolean
	local panelHost = Registry.panelHost
	local getCtx = Registry.getCtx
	if not panelHost or not getCtx then
		return false
	end

	local targetDescriptor: PanelDescriptor? = nil
	local targetEnabled = false
	for _, descriptor in ipairs(Registry.descriptors) do
		if descriptor.id == id then
			targetDescriptor = descriptor
			targetEnabled = Settings.getPanelEnabled(id, descriptor.defaultEnabled ~= false)
			break
		end
	end
	if not targetDescriptor or not targetEnabled then
		return false
	end

	local selectedId = Registry.selectedId
	if selectedId and selectedId ~= id then
		local current = Registry.handles[selectedId]
		if current then
			if current.onHide then
				current.onHide()
			end
			if current.frame then
				current.frame.Visible = false
			end
		end
	end

	-- Lazily build the panel on first selection. `build` may return nil, in which
	-- case Registry synthesizes `{ frame = frame }` (matches the monolith). The
	-- `or` fallback makes `built` non-optional, so the analyzer can prove the
	-- field reads below are safe without a giant closure.
	local handle: PanelHandle
	local existing = Registry.handles[id]
	if existing then
		handle = existing
	else
		local frame = Instance.new("Frame")
		frame.Name = "Panel_" .. id
		frame.BackgroundTransparency = 1
		frame.Size = UDim2.fromScale(1, 1)
		frame.Parent = panelHost
		local built: PanelHandle = targetDescriptor.build(frame, getCtx()) or { frame = frame }
		if not built.frame then
			built.frame = frame
		end
		Registry.handles[id] = built
		handle = built
	end

	if handle.onShow then
		handle.onShow()
	end
	if handle.frame then
		handle.frame.Visible = true
	end
	Registry.selectedId = id
	local onChange = Registry.onChange
	if onChange then
		onChange()
	end
	return true
end

function Registry.getHandle(id: string): PanelHandle?
	return Registry.handles[id]
end

function Registry.firstEnabledId(): string?
	for _, item in ipairs(Registry.list()) do
		if item.enabled then
			return item.id
		end
	end
	return nil
end

function Registry.countIds(): number
	return #Registry.descriptors
end

function Registry.snapshotIds(): { string }
	local ids: { string } = {}
	for _, item in ipairs(Registry.list()) do
		table.insert(ids, item.id)
	end
	table.sort(ids)
	return ids
end

return Registry
