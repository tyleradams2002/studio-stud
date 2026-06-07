type ConfigModule__DARKLUA_TYPE_a = {
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

type PanelEnabledMap__DARKLUA_TYPE_b = { [string]: any }

type SettingsModule__DARKLUA_TYPE_c = {
	-- Typed scalar accessors. Each get is pcall + typeof guarded; on any failure,
	-- wrong stored type, or (for string) an empty value, the default is returned.
	getString: (key: string, defaultValue: string) -> string,
	setString: (key: string, value: string) -> (),
	getBool: (key: string, defaultValue: boolean) -> boolean,
	setBool: (key: string, value: boolean) -> (),
	getNumber: (key: string, defaultValue: number) -> number,
	setNumber: (key: string, value: number) -> (),

	-- Debounce (= tick interval ms). get clamps+rounds into [MIN,MAX]; both the
	-- get result and the value written by set are clamped identically. E5-cached.
	getDebounceMs: () -> number,
	setDebounceMs: (value: number) -> (),

	-- The daemon write token. E5-cached read over getString(SETTINGS.writeToken).
	-- The cache is the same slot setString invalidates, so a freshly-fetched token
	-- (Transport.fetchWriteToken calls setString) is visible on the next read.
	getWriteToken: () -> string,

	-- Panel enabled-state, persisted as one JSON-encoded map string.
	getPanelEnabledMap: () -> PanelEnabledMap__DARKLUA_TYPE_b,
	setPanelEnabledMap: (map: PanelEnabledMap__DARKLUA_TYPE_b) -> (),
	getPanelEnabled: (panelId: string, defaultEnabled: boolean) -> boolean,
	setPanelEnabled: (panelId: string, enabled: boolean) -> (),
	clearPanelEnabled: (panelId: string) -> (),

	-- Debug logging gate: warn(...) iff the debugLogging setting is true.
	debugLog: (...any) -> (),

	-- One-time defaults migration: brings a pre-revision install onto the current
	-- default debounce + debug-off the user expects. Idempotent (guarded by settingsRev).
	applyDefaultsMigration: () -> (),
}

type PanelDescriptor__DARKLUA_TYPE_d = {
	id: string,
	title: string,
	defaultEnabled: boolean?,
	build: (frame: Frame, ctx: any) -> PanelHandle__DARKLUA_TYPE_e?,
}

type PanelHandle__DARKLUA_TYPE_e = {
	frame: Frame?,
	destroy: (() -> ())?,
	onShow: (() -> ())?,
	onHide: (() -> ())?,
	[string]: any,
}

type PanelListItem__DARKLUA_TYPE_f = {
	id: string,
	title: string,
	defaultEnabled: boolean?,
	enabled: boolean,
	descriptor: PanelDescriptor__DARKLUA_TYPE_d,
}

type RegistryModule__DARKLUA_TYPE_g = {
	-- Mutable state (held on the table, not a closure — see header).
	descriptors: { PanelDescriptor__DARKLUA_TYPE_d },
	handles: { [string]: PanelHandle__DARKLUA_TYPE_e },
	selectedId: string?,
	panelHost: Instance?,
	getCtx: (() -> any)?,
	onChange: (() -> ())?,

	-- Wire the host: where panels are parented, how to build a panel ctx, and the
	-- callback fired whenever the tab set/selection changes (the view re-renders).
	setHost: (panelHost: Instance, getCtx: () -> any, onChange: () -> ()) -> (),

	-- Add a descriptor (validated). Returns (true) on success, or (false, reason)
	-- for an invalid descriptor or a duplicate id. Fires onChange on success.
	register: (descriptor: PanelDescriptor__DARKLUA_TYPE_d) -> (boolean, string?),

	-- Remove a descriptor by id: destroy its handle, drop its enabled setting,
	-- clear selection if it was selected, fire onChange. Returns whether removed.
	unregister: (id: string) -> boolean,

	-- Snapshot every descriptor as a PanelListItem (with resolved enabled state).
	list: () -> { PanelListItem__DARKLUA_TYPE_f },

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
	getHandle: (id: string) -> PanelHandle__DARKLUA_TYPE_e?,

	-- The first enabled tab id in registration order (nil if none enabled).
	firstEnabledId: () -> string?,

	-- The number of registered descriptors.
	countIds: () -> number,

	-- Every registered id, sorted (stable snapshot for tests/diffs).
	snapshotIds: () -> { string },
}

type CaptureHandler__DARKLUA_TYPE_h = () -> { [string]: any }

type SelfTestFn__DARKLUA_TYPE_i = () -> boolean

type StudioStudGlobal__DARKLUA_TYPE_j = {
	RunSelfTest: SelfTestFn__DARKLUA_TYPE_i?,
	__studioStudOwner: {}?, -- ownership token (our private table identity)
	[string]: any,
}

type GlobalApiModule__DARKLUA_TYPE_k = {
	-- Internal live handlers, held on the table so the panel can wire them and the
	-- SelfTest can read them WITHOUT exposing them on `_G` (S2). nil until wired;
	-- reset to nil by installNoOps. These are the single source of truth for the
	-- current capture handlers — the panel reads `GlobalApi.statusFn`/`.syncFn`
	-- rather than reaching back into `_G`.
	statusFn: CaptureHandler__DARKLUA_TYPE_h?,
	syncFn: CaptureHandler__DARKLUA_TYPE_h?,

	-- Build the "panel disabled" stand-in handler (faithful to the monolith's
	-- makeDisabledFn): warns once per call and returns `{ ok = false, error = ... }`.
	-- Retained so the panel/SelfTest can present a uniform disabled result; NOT
	-- published to `_G`.
	makeDisabledFn: () -> CaptureHandler__DARKLUA_TYPE_h,

	-- Clear the internal live handlers (the disabled state). Faithful to the
	-- monolith's installNoOps EXCEPT it no longer writes `Sync`/`Capture`/`Status`
	-- onto `_G` (S2) — there is nothing to publish, so it just drops the internal
	-- references. Safe to call when no global is installed.
	installNoOps: () -> (),

	-- Wire the live capture handlers internally. Faithful to the monolith's
	-- wireCapture EXCEPT it stores them on `GlobalApi` instead of publishing
	-- `Sync`/`Capture`/`Status` onto `_G` (S2).
	wireCapture: (statusFn: CaptureHandler__DARKLUA_TYPE_h, syncFn: CaptureHandler__DARKLUA_TYPE_h) -> (),

	-- Install the minimal global surface: create/reuse `_G.StudioStud`, stamp our
	-- ownership token, and publish `RunSelfTest`. Idempotent. Mirrors the bootstrap
	-- lines `_G.StudioStud = _G.StudioStud or {}` + `_G.StudioStud.RunSelfTest = ...`.
	install: (runSelfTest: SelfTestFn__DARKLUA_TYPE_i) -> (),

	-- True iff `_G.StudioStud` exists AND carries our ownership token (i.e. we still
	-- own the slot; nobody overwrote it). The trust-boundary read for the global.
	owns: () -> boolean,

	-- Reclaim on unload: nil `_G.StudioStud` ONLY if we still own it (token match),
	-- so a later plugin that replaced the slot is never clobbered. Faithful to the
	-- monolith's `if RunSelfTest == SelfTest.run then _G.StudioStud = nil`.
	reclaim: () -> (),
}

type Hex64__DARKLUA_TYPE_l = string

type Bytes__DARKLUA_TYPE_m = { number }

type SessionMode__DARKLUA_TYPE_n = "edit" | "play"

type SourceEncoding__DARKLUA_TYPE_o = "utf8" | "base64"

type PropertyMap__DARKLUA_TYPE_p = { [string]: any }

type AttributeMap__DARKLUA_TYPE_q = { [string]: any }

type Tags__DARKLUA_TYPE_r = { string }

type InstanceEntry__DARKLUA_TYPE_s = {
	id: string,
	parentId: string?, -- nil at a captured root
	path: string,
	displayPath: string, -- inst:GetFullName(); rides the wire (consumed by daemon for display_path/search_text), NOT in the drift hash
	name: string,
	className: string,
	depth: number,
	siblingIndex: number,
	childCount: number,
	duplicateSiblingName: boolean,
	properties: PropertyMap__DARKLUA_TYPE_p,
	attributes: AttributeMap__DARKLUA_TYPE_q,
	tags: Tags__DARKLUA_TYPE_r,
	fp: Hex64__DARKLUA_TYPE_l,
	source: string?, -- LuaSourceContainer text; absent for non-script instances
	sourceEncoding: SourceEncoding__DARKLUA_TYPE_o?, -- present iff `source` is present
}

type Ops__DARKLUA_TYPE_t = {
	upserted: { InstanceEntry__DARKLUA_TYPE_s },
	removed: { string }, -- removed instance ids
}

type TickPacket__DARKLUA_TYPE_u = {
	placeId: string,
	sessionMode: SessionMode__DARKLUA_TYPE_n,
	baseRevision: number,
	serviceFingerprints: { [string]: Hex64__DARKLUA_TYPE_l }, -- per captured root service
	ops: Ops__DARKLUA_TYPE_t,
	bulkRef: string?, -- set instead of fresh ops when payload spilled to chunks
}

type ApplyScript__DARKLUA_TYPE_v = {
	studioPath: string,
	newSource: string,
	expectedPriorHash: string,
}

type TickResponse__DARKLUA_TYPE_w = {
	ok: boolean,
	revision: number?,
	instanceCount: number?,
	driftServices: { string }?, -- services whose fingerprint disagreed (usually nil/[])
	request: any?, -- AI-queued job, e.g. { reason = "rebaseline" }
	applyScripts: { ApplyScript__DARKLUA_TYPE_v }?, -- downstream write channel (reserved)
	error: string?, -- set on a non-ok response (e.g. "no_baseline")
}

type ClassPropSet__DARKLUA_TYPE_x = { [string]: boolean }

type AllowList__DARKLUA_TYPE_y = {
	version: any,
	sets: { [string]: ClassPropSet__DARKLUA_TYPE_x }, -- [className] = { [propName] = readOnly }
	lists: { [string]: { string } }, -- [className] = { propName, ... }
}

type LiveState__DARKLUA_TYPE_z = {
	liveRunning: boolean,
	currentRevision: number,
	liveInstanceCount: number,
	networkErrorCount: number,
	dirtyStamp: number, -- monotonic edit counter
	dirtyUpsert: { [Instance]: boolean },
	dirtyRemoved: { [string]: boolean }, -- [id] = true
	upsertStamp: { [Instance]: number }, -- stamp at last mark
	removedStamp: { [string]: number }, -- [id] = stamp at last mark
	instFp: { [string]: Hex64__DARKLUA_TYPE_l }, -- [id] = current entry fingerprint
	serviceFpBytes: { [string]: Bytes__DARKLUA_TYPE_m }, -- [service] = 32-byte XOR accumulator
}

type SessionMode__DARKLUA_TYPE_A = SessionMode__DARKLUA_TYPE_n
type Signals__DARKLUA_TYPE_B = {
	isEdit: boolean,
	isRunning: boolean,
}

type SessionModule__DARKLUA_TYPE_C = {
	-- The pure truth table. The ONLY mode that ships traffic is edit, defined as
	-- "Studio is in edit AND the game is not running". Every other combination is
	-- a play/run DataModel and gates to "play" (a pure keepalive). Faithful port
	-- of `(sig.isEdit and not sig.isRunning) and "edit" or "play"`, written as an
	-- explicit if/else (the old `a and b or c` form was only safe because "edit"
	-- is truthy; the if/else removes that footgun without changing the result).
	decide: (isEdit: boolean, isRunning: boolean) -> SessionMode__DARKLUA_TYPE_A,

	-- Signal accessor: the single point that reads live RunService state. Impure
	-- by design; everything downstream consumes the typed table or `decide`.
	signals: () -> Signals__DARKLUA_TYPE_B,

	-- Current mode = decide(signals()). Convenience composition of the two above.
	mode: () -> SessionMode__DARKLUA_TYPE_A,

	-- True iff the current mode is "edit". The gate every traffic path checks.
	isEdit: () -> boolean,
}

type TickResponse__DARKLUA_TYPE_D = TickResponse__DARKLUA_TYPE_w
type ApplyScript__DARKLUA_TYPE_E = ApplyScript__DARKLUA_TYPE_v
-- == Internal HTTP request/response shapes ==

-- The request table we hand to HttpService:RequestAsync. The engine's typed
-- HttpRequestOptions requires a non-optional Compress field; the monolith never
-- set it (it defaults to None on the engine). We build a plain typed table and
-- cast at the single RequestAsync boundary so the rest of the module stays
-- strict without scattering `any`.
type RequestTable__DARKLUA_TYPE_F = {
	Url: string,
	Method: string,
	Headers: { [string]: string },
	Timeout: number,
	Body: string?,
}

-- Structural mirror of the engine's HttpResponseData (a non-exported local type
-- in globalTypes.d.luau, so we cannot name it). Pinned here for the RequestAsync
-- result and the shared decoder.
type HttpResponse__DARKLUA_TYPE_G = {
	Success: boolean,
	StatusCode: number,
	StatusMessage: string,
	Headers: { [string]: string },
	Body: string?,
}
type ResponseTable__DARKLUA_TYPE_H = {
	error: string?,
	statusCode: number?,
	body: string?,
	blockedReason: string?,
	token: string?,
	[string]: any,
}
type TransportModule__DARKLUA_TYPE_I = {
	-- Daemon-URL plumbing (verbatim port).
	parseDaemonUrl: (url: string?) -> (string, string),
	buildDaemonUrl: (host: string?, port: string?) -> string,
	currentUrl: () -> string,

	-- S1 loopback guard. `isLoopbackHost` is the pure predicate; the *Loopback
	-- helpers operate on the configured daemon URL. `assertCaptureAllowed` is the
	-- gate the capture/source-upload paths call before any data leaves the box:
	-- returns (true) when loopback, else (false, reason) — never sends.
	isLoopbackHost: (host: string?) -> boolean,
	currentUrlIsLoopback: () -> boolean,
	assertCaptureAllowed: () -> (boolean, string?),

	-- JSON safety net (PORTED VERBATIM — proven).
	sanitizeJsonValue: (value: any, path: string, report: { string }, seen: { [any]: boolean }?) -> any,
	safeEncode: (value: any, label: string?) -> (boolean, string),

	-- Request primitives. Each returns (ok, ResponseTable): decoded body on
	-- success, a `{ error = ... }` shape on failure.
	requestJson: (method: string, path: string, body: any?, timeoutSeconds: number?) -> (boolean, ResponseTable__DARKLUA_TYPE_H),
	requestJsonAuthed: (method: string, path: string, body: any?, timeoutSeconds: number?) -> (boolean, ResponseTable__DARKLUA_TYPE_H),
	requestBody: (path: string, body: string) -> (boolean, ResponseTable__DARKLUA_TYPE_H),

	-- Write-token plumbing. buildAuthedHeaders is exposed for the SelfTest; the
	-- E5 token cache itself lives in Settings.
	buildAuthedHeaders: (token: string) -> { [string]: string },
	fetchWriteToken: () -> string,

	-- Trust boundary: coerce a decoded tick body into the typed TickResponse the
	-- live engine consumes. Harden-once for the daemon wire.
	hardenTickResponse: (decoded: any) -> TickResponse__DARKLUA_TYPE_D,

	-- SelfTest seam: the last request table built by requestJsonAuthed, so the
	-- gate can assert the write-token header was attached.
	_selfTestLastRequest: RequestTable__DARKLUA_TYPE_F?,
}

type ClassPropSet__DARKLUA_TYPE_J = ClassPropSet__DARKLUA_TYPE_x type ParsedAllowList__DARKLUA_TYPE_K = AllowList__DARKLUA_TYPE_y type AllowListModule__DARKLUA_TYPE_L = {
	-- Loaded-from-daemon flag. When false, namesFor/setFor return nil and capture
	-- uses the static Config.CLASS_PROPERTIES fallback.
	loaded: boolean,
	-- Daemon-supplied, opaque version tag (any: the daemon may use a string, a
	-- number, or omit it). Stored as-is for diagnostics/logging.
	version: any,
	-- [className] = { [propName] = readOnly } — O(1) membership, the in-handler
	-- curated filter.
	sets: { [string]: ClassPropSet__DARKLUA_TYPE_J },
	-- [className] = { propName, ... } — ordered, the order capture reads in.
	lists: { [string]: { string } },

	-- PURE: decode a /allowlist response into per-class sets + ordered lists.
	-- Returns nil on bad input (non-table, or no `classes` table). Malformed
	-- per-class / per-entry pieces are dropped, not rejected.
	parse: (decoded: any) -> ParsedAllowList__DARKLUA_TYPE_K?,

	-- Fetch from the daemon and cache. Returns true on success; on failure logs
	-- (debug) and leaves the static fallback in place (returns false). Never throws.
	fetch: () -> boolean,

	-- Ordered property names for an EXACT class (nil if not loaded / class unknown).
	namesFor: (className: string) -> { string }?,
	-- Membership set { propName = readOnly } for an EXACT class (nil if not loaded /
	-- class unknown).
	setFor: (className: string) -> ClassPropSet__DARKLUA_TYPE_J?,
}

type Hex64__DARKLUA_TYPE_M = Hex64__DARKLUA_TYPE_l type Bytes__DARKLUA_TYPE_N = Bytes__DARKLUA_TYPE_m type InstanceEntry__DARKLUA_TYPE_O = InstanceEntry__DARKLUA_TYPE_s type HashModule__DARKLUA_TYPE_P = {
	-- The drift fingerprint of an instance entry: a 64-char lowercase-hex string
	-- (4 lanes × 16 hex). VERBATIM 4-lane FNV-32 over the canonical pipe string
	-- (source EXCLUDED). Byte-identical to the monolith's Live.hashInstance.
	hashInstance: (entry: InstanceEntry__DARKLUA_TYPE_O) -> Hex64__DARKLUA_TYPE_M,

	-- The service (root) name of a path: the leading segment before the first "/"
	-- (the whole path when there is no "/"). Empty string for a nil/"" path. Used
	-- to bucket fingerprints into per-service XOR accumulators.
	serviceOf: (path: string?) -> string,

	-- A fresh 32-zero byte array (one service's empty XOR accumulator).
	fpZero: () -> Bytes__DARKLUA_TYPE_N,
	-- Unpack a 64-hex fingerprint into its 32 bytes (0..255). Out-of-range / bad
	-- hex pairs become 0 (tonumber fallback), matching the monolith.
	fpHexToBytes: (hex: string) -> Bytes__DARKLUA_TYPE_N,
	-- Pack a 32-byte array back into 64 lowercase hex (nil bytes → "00").
	fpBytesToHex: (bytes: Bytes__DARKLUA_TYPE_N) -> Hex64__DARKLUA_TYPE_M,
	-- In-place XOR of `source` into `target` over 32 bytes (the accumulator op).
	-- nil entries on either side are treated as 0. Mutates and returns `target`.
	fpXor: (target: Bytes__DARKLUA_TYPE_N, source: Bytes__DARKLUA_TYPE_N) -> Bytes__DARKLUA_TYPE_N,
}

type Hex64__DARKLUA_TYPE_Q = Hex64__DARKLUA_TYPE_l type Bytes__DARKLUA_TYPE_R = Bytes__DARKLUA_TYPE_m type FpEntry__DARKLUA_TYPE_S = {
	fp: Hex64__DARKLUA_TYPE_Q?,
	path: string,
	-- The remaining InstanceEntry fields are read ONLY when fp is nil (Hash widens to
	-- any internally and applies the same `x or default` fallbacks the monolith used),
	-- so they are optional here.
	className: string?,
	name: string?,
	parentId: string?,
	depth: number?,
	siblingIndex: number?,
	childCount: number?,
	duplicateSiblingName: boolean?,
	properties: { [string]: any }?,
	attributes: { [string]: any }?,
	tags: { string }?,
}
type FingerprintsModule__DARKLUA_TYPE_T = {
	-- [id] = the instance's current 64-hex fingerprint (the value last XOR'd into a
	-- service accumulator for that id). Read by the Live engine for removal bookkeeping;
	-- mutated only through applyFpUpsert / applyFpRemove / reset.
	instFp: { [string]: Hex64__DARKLUA_TYPE_Q },
	-- [service] = the 32-byte XOR accumulator of every live instance's fingerprint in
	-- that service. serviceFingerprintsWire emits these as 64-hex on each tick.
	serviceFpBytes: { [string]: Bytes__DARKLUA_TYPE_R },

	-- The 64-hex fingerprint of one service: 64 zeros when the service has no
	-- accumulator yet, else its bytes packed to hex. (Monolith Live.serviceFpHex.)
	serviceFpHex: (self: FingerprintsModule__DARKLUA_TYPE_T, service: string) -> Hex64__DARKLUA_TYPE_Q,

	-- The serviceFingerprints wire map: { [service] = 64-hex } over every service that
	-- has an accumulator. This is the TickPacket.serviceFingerprints field.
	-- (Monolith Live.serviceFingerprintsWire.)
	serviceFingerprintsWire: (self: FingerprintsModule__DARKLUA_TYPE_T) -> { [string]: Hex64__DARKLUA_TYPE_Q },

	-- Add / update / REPARENT one instance's fingerprint. newFp = entry.fp or
	-- Hash.hashInstance(entry); MUTATES entry.fp to that value (the monolith did, and
	-- callers rely on the entry carrying its fp onto the wire). XORs the previously
	-- stored fingerprint (if any) out of serviceOf(oldPath or entry.path), XORs newFp
	-- into serviceOf(entry.path), and records instFp[id] = newFp. Pass oldPath when the
	-- instance moved services (reparent) so the old fingerprint leaves the OLD service.
	-- (Monolith Live.applyFpUpsert(id, entry, oldPath).)
	applyFpUpsert: (self: FingerprintsModule__DARKLUA_TYPE_T, id: string, entry: FpEntry__DARKLUA_TYPE_S, oldPath: string?) -> (),

	-- Remove one instance's fingerprint: XOR its stored fingerprint out of
	-- serviceOf(path) and clear instFp[id]. No-op on the accumulator if the id was
	-- never recorded. (Monolith Live.applyFpRemove(id, path).)
	applyFpRemove: (self: FingerprintsModule__DARKLUA_TYPE_T, id: string, path: string?) -> (),

	-- Drop ALL fingerprint state (instFp + serviceFpBytes) — used on full rebaseline /
	-- drift recovery / teardown so the next baseline rebuilds accumulators from scratch.
	-- (Monolith Live.resetFingerprints.)
	reset: (self: FingerprintsModule__DARKLUA_TYPE_T) -> (),
}

type ThemeModule__DARKLUA_TYPE_U = {
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

type MsSlider__DARKLUA_TYPE_V = {
	setValue: (ms: number) -> (),
	getValue: () -> number,
	disconnect: () -> (),
}

type StatusCard__DARKLUA_TYPE_W = {
	frame: Frame,
	setState: (state: string, message: string) -> (),
	setStats: (text: string?) -> (),
}

type UiModule__DARKLUA_TYPE_X = {
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
	) -> MsSlider__DARKLUA_TYPE_V,
	makeStatusCard: (parent: Instance, y: number) -> StatusCard__DARKLUA_TYPE_W,
	makeVectorLogo: (parent: Instance, size: number) -> Frame,
	makeBrandBadge: (parent: Instance) -> Frame,
}

type StatusCard__DARKLUA_TYPE_Y = StatusCard__DARKLUA_TYPE_W
type ShellContext__DARKLUA_TYPE_Z = {
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

type ShellModule__DARKLUA_TYPE__ = {
	-- Mutable view state (held on the table, not a closure — see header).
	widget: DockWidgetPluginGui,
	toolbarButton: PluginToolbarButton,
	mainFrame: Frame?,
	contentFrame: Frame?,
	panelHost: Frame?,
	tabStrip: Frame?,
	settingsFrame: Frame?,
	statusCard: StatusCard__DARKLUA_TYPE_Y?,
	connected: boolean,
	autoConnectGeneration: number,

	-- Build the panel context every panel's build receives.
	makeCtx: () -> ShellContext__DARKLUA_TYPE_Z,

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

type SelfTestModule__DARKLUA_TYPE_0 = {
	-- One assertion: print PASS, or record `name` in `failures` and warn FAIL.
	-- Faithful to the monolith's SelfTest.assert(name, condition, failures).
	assert: (name: string, condition: any, failures: { string }) -> (),

	-- Run the whole suite in the live edit DataModel. Returns true iff every check
	-- passed (the bare boolean the monolith returned and GlobalApi.RunSelfTest
	-- publishes). Restores all settings/registry it touched before returning.
	run: () -> boolean,
}

type InstanceEntry__DARKLUA_TYPE_1 = InstanceEntry__DARKLUA_TYPE_s
type PropertyMap__DARKLUA_TYPE_2 = PropertyMap__DARKLUA_TYPE_p
type AttributeMap__DARKLUA_TYPE_3 = AttributeMap__DARKLUA_TYPE_q
type Tags__DARKLUA_TYPE_4 = Tags__DARKLUA_TYPE_r
type ClassPropSet__DARKLUA_TYPE_5 = ClassPropSet__DARKLUA_TYPE_x
type SourceEncoding__DARKLUA_TYPE_6 = SourceEncoding__DARKLUA_TYPE_o
type PropertyError__DARKLUA_TYPE_7 = {
	property: string,
	error: string,
}

type RootEntry__DARKLUA_TYPE_8 = {
	name: string,
	instance: Instance,
	includeDescendants: boolean,
}

type Snapshot__DARKLUA_TYPE_9 = {
	formatVersion: number,
	snapshotKind: string,
	serviceName: string,
	pluginVersion: string,
	place: {
		placeKey: string,
		name: string,
		placeId: number,
		gameId: number,
	},
	sync: {
		reason: string,
		requestId: any,
		startedAtUtc: string,
		finishedAtUtc: string,
		consistency: string,
		rootNames: { string },
	},
	instances: { any },
}

type SnapshotOptions__DARKLUA_TYPE_aa = {
	reason: string?,
	requestId: any?,
}

type SiblingMemo__DARKLUA_TYPE_ab = {
	[Instance]: {
		counts: { [string]: number },
		children: { Instance },
	},
}

type CaptureModule__DARKLUA_TYPE_ac = {
	-- Per-walk identity maps. Rebuilt by collectBaseInstances; read by serializeValue
	-- (InstanceRef) and buildUpsertedEntry. Exposed so the Live engine can resolve an
	-- instance's id/path (e.g. for removal bookkeeping) against the same maps capture
	-- populated.
	instanceIdByRef: { [Instance]: string },
	pathByRef: { [Instance]: string },

	-- Cooperative-yield predicate: true when processedCount is a positive multiple of
	-- yieldEvery (and yieldEvery > 0). The walk task.wait()s on a true result.
	shouldYield: (processedCount: number, yieldEvery: number) -> boolean,

	-- Datatype serializers. serializeValue is the typeof-dispatch entry point;
	-- the three named helpers are reused by the Model bounding-box/pivot extras.
	serializeVector3: (value: Vector3) -> any,
	serializeCFrame: (value: CFrame) -> any,
	serializeColor3: (value: Color3) -> any,
	serializeValue: (value: any) -> any,

	-- Curation. getPropertyNames returns the ordered name list (AllowList per exact
	-- class, else static IsA-accumulation). curatedSet is the membership set for the
	-- class (AllowList set, else built from the names with readOnly=false).
	getPropertyNames: (inst: Instance) -> { string },
	curatedSet: (inst: Instance) -> ClassPropSet__DARKLUA_TYPE_5,

	-- Property reads. readProperties is optimistic batch-pcall with per-property
	-- fallback (readPropsFrom) + Model bounding-box/pivot. Both return (props, errors).
	readPropsFrom: (inst: any, names: { string }) -> (PropertyMap__DARKLUA_TYPE_2, { PropertyError__DARKLUA_TYPE_7 }),
	readProperties: (inst: Instance) -> (PropertyMap__DARKLUA_TYPE_2, { PropertyError__DARKLUA_TYPE_7 }),

	-- base64 codec (the source non-UTF-8 path). Ported verbatim (the daemon decodes
	-- the same alphabet/padding).
	base64encode: (raw: string) -> string,
	base64decode: (encoded: string) -> string,

	-- LuaSourceContainer source: (text, encoding) as utf8, or (base64, "base64") when
	-- not valid UTF-8; (nil, nil) for non-script instances or a read failure.
	readSource: (inst: Instance) -> (string?, SourceEncoding__DARKLUA_TYPE_6?),
	-- All attributes (no whitelist), serialized; second return is errors.
	readAttributes: (inst: Instance) -> (AttributeMap__DARKLUA_TYPE_3, { PropertyError__DARKLUA_TYPE_7 }),
	-- CollectionService tags in capture order ({} on failure).
	readTags: (inst: Instance) -> Tags__DARKLUA_TYPE_4,

	-- The yielding baseline walk. getRootEntries -> ordered captured services;
	-- collectBaseInstances -> (structural entries, rootNames) + populated id/path
	-- maps; buildSnapshot -> the full snapshot envelope (props/attrs/tags/source
	-- filled in a second yielding pass).
	getRootEntries: () -> { RootEntry__DARKLUA_TYPE_8 },
	collectBaseInstances: () -> ({ any }, { string }),
	buildSnapshot: (options: SnapshotOptions__DARKLUA_TYPE_aa?) -> Snapshot__DARKLUA_TYPE_9,

	-- The live per-instance entry builder. Returns (entry, oldPath): entry with fp
	-- set via Hash, oldPath = the path the instance had in pathByRef before this
	-- build (nil if new), so the caller can XOR the old fingerprint out of the right
	-- service. Returns (nil, nil) when the instance has no id, no parent, isn't found
	-- among its siblings, or its parent's GetChildren throws (mirrors the monolith's
	-- early-outs). `memo` (optional, E2) collapses per-parent sibling scans within a
	-- single flush.
	buildUpsertedEntry: (inst: Instance, memo: SiblingMemo__DARKLUA_TYPE_ab?) -> (InstanceEntry__DARKLUA_TYPE_1?, string?),
}

	-- Build the depth-sorted upsert work list (parents first).
	type WorkItem__DARKLUA_TYPE_aj = { inst: Instance, depth: number }

type InstanceEntry__DARKLUA_TYPE_ad = InstanceEntry__DARKLUA_TYPE_s type Ops__DARKLUA_TYPE_ae = Ops__DARKLUA_TYPE_t
type SessionMode__DARKLUA_TYPE_af = SessionMode__DARKLUA_TYPE_n
type Hex64__DARKLUA_TYPE_ag = Hex64__DARKLUA_TYPE_l
type LiveHost__DARKLUA_TYPE_ah = {
	transport: {
		requestJson: (method: string, path: string, body: any?, timeoutSeconds: number?) -> (boolean, any),
		requestBody: (path: string, body: string) -> (boolean, any),
	},
	setStatus: (kind: string, message: string) -> (),
	setStats: (text: string) -> (),
	setConnected: (connected: boolean) -> (),
	isConnected: () -> boolean,
	setBaseline: (hasBaseline: boolean) -> (),
	reconnect: () -> (),
	isRunning: () -> boolean,
}

type LiveModule__DARKLUA_TYPE_ai = {
	-- Live engine state (Types.LiveState fields are mirrored here; the accumulator
	-- halves instFp/serviceFpBytes live on Fingerprints, reached via the FP methods).
	liveRunning: boolean,
	currentRevision: number,
	liveInstanceCount: number,
	networkErrorCount: number,
	syncInFlight: boolean,
	verifyNeeded: boolean,
	dirtyStamp: number,
	dirtyUpsert: { [Instance]: boolean },
	dirtyRemoved: { [string]: boolean },
	upsertStamp: { [Instance]: number },
	removedStamp: { [string]: number },
	parentByInst: { [Instance]: Instance? },
	instConns: { [Instance]: { RBXScriptConnection } },
	rootConns: { RBXScriptConnection },
	globalConns: { RBXScriptConnection },
	propGaps: { [string]: boolean },
	pendingBulkRef: string?,
	baselineInProgress: boolean,
	recoveryServices: { string }?,
	tickGeneration: number,
	historyDirty: boolean,

	-- The host seam; a no-op stub until attach() injects the real orchestrator.
	host: LiveHost__DARKLUA_TYPE_ah,
	attach: (self: LiveModule__DARKLUA_TYPE_ai, host: LiveHost__DARKLUA_TYPE_ah) -> (),

	-- Dirty marking (lazy; handlers set dirty only, values read at tick time).
	markDirtyUpsert: (self: LiveModule__DARKLUA_TYPE_ai, inst: Instance) -> (),
	markDirtyRemoved: (self: LiveModule__DARKLUA_TYPE_ai, id: string) -> (),
	markSubtreeUpsert: (self: LiveModule__DARKLUA_TYPE_ai, root: Instance) -> (),
	markSiblingsDirty: (self: LiveModule__DARKLUA_TYPE_ai, parent: Instance?, name: string) -> (),

	-- Property classification (pure; O(1) lookup).
	classifyChangedProp: (self: LiveModule__DARKLUA_TYPE_ai, prop: string, curatedSet: { [string]: boolean }) -> string,
	recordPropGap: (self: LiveModule__DARKLUA_TYPE_ai, className: string?, prop: any) -> (),
	onNameChanged: (self: LiveModule__DARKLUA_TYPE_ai, inst: Instance) -> (),

	-- Per-instance signal wiring.
	registerInstance: (self: LiveModule__DARKLUA_TYPE_ai, inst: Instance) -> (),
	unregisterInstance: (self: LiveModule__DARKLUA_TYPE_ai, inst: Instance) -> (),
	unregisterSubtree: (self: LiveModule__DARKLUA_TYPE_ai, root: Instance) -> (),
	onDescendantAdded: (self: LiveModule__DARKLUA_TYPE_ai, child: Instance) -> (),
	onDescendantRemoving: (self: LiveModule__DARKLUA_TYPE_ai, child: Instance) -> (),

	-- Op collection + stamp clearing (the no-data-loss path).
	collectOpsFromDirty: (self: LiveModule__DARKLUA_TYPE_ai) -> (
		{ InstanceEntry__DARKLUA_TYPE_ad },
		{ string },
		{ [Instance]: number },
		{ [string]: number }
	),
	clearSentDirty: (
		self: LiveModule__DARKLUA_TYPE_ai,
		sentUpsertStamps: { [Instance]: number },
		sentRemovedStamps: { [string]: number }
	) -> (),

	-- Tick body + payload sizing.
	tickQuerySuffix: (self: LiveModule__DARKLUA_TYPE_ai) -> string,
	buildTickBody: (
		self: LiveModule__DARKLUA_TYPE_ai,
		placeId: any,
		sessionMode: SessionMode__DARKLUA_TYPE_af,
		baseRevision: number,
		serviceFingerprints: { [string]: Hex64__DARKLUA_TYPE_ag },
		ops: Ops__DARKLUA_TYPE_ae,
		bulkRef: string?
	) -> any,

	-- Baseline + bulk upload.
	initFingerprintsFromWalk: (self: LiveModule__DARKLUA_TYPE_ai) -> (),
	buildBaselineSnapshot: (self: LiveModule__DARKLUA_TYPE_ai, reason: string?) -> any,
	uploadTickBulk: (self: LiveModule__DARKLUA_TYPE_ai, jsonText: string, reason: string?) -> (boolean, any),
	triggerFullBaseline: (self: LiveModule__DARKLUA_TYPE_ai, reason: string?) -> boolean,
	triggerDriftRecovery: (self: LiveModule__DARKLUA_TYPE_ai, driftServices: { string }?) -> boolean,
	triggerRebaseline: (self: LiveModule__DARKLUA_TYPE_ai, reason: string?) -> (),

	-- The tick + loop.
	runTick: (self: LiveModule__DARKLUA_TYPE_ai, sessionMode: SessionMode__DARKLUA_TYPE_af?) -> (),
	startTickLoop: (
		self: LiveModule__DARKLUA_TYPE_ai,
		pausedBaselineRef: { revision: number, instanceCount: number }?,
		onReturnToEditFn: (() -> ())?
	) -> (),

	-- Connect / teardown / session transitions.
	connectLiveMode: (self: LiveModule__DARKLUA_TYPE_ai) -> boolean,
	setupAfterBaseline: (self: LiveModule__DARKLUA_TYPE_ai, materialized: any?) -> (),
	teardown: (self: LiveModule__DARKLUA_TYPE_ai) -> (),
}

type ShellContext__DARKLUA_TYPE_ak = ShellContext__DARKLUA_TYPE_Z
type LiveHost__DARKLUA_TYPE_al = LiveHost__DARKLUA_TYPE_ah
type LiveModule__DARKLUA_TYPE_am = LiveModule__DARKLUA_TYPE_ai
type CaptureModule__DARKLUA_TYPE_an = CaptureModule__DARKLUA_TYPE_ac
type SyncResult__DARKLUA_TYPE_ao = {
	ok: boolean,
	error: string?,
	status: string?,
	daemon: any?,
	placeId: any?,
	placeName: string?,
	[string]: any,
}

type PanelHandle__DARKLUA_TYPE_ap = {
	frame: Frame,
	sync: (options: any?) -> SyncResult__DARKLUA_TYPE_ao,
	status: () -> SyncResult__DARKLUA_TYPE_ao,
	probe: () -> boolean,
	setAutoPolling: (enabled: boolean) -> (),
	isRunning: () -> boolean,
	pollGeneration: number,
	onConnectRequested: () -> SyncResult__DARKLUA_TYPE_ao,
	destroy: () -> (),
	live: LiveModule__DARKLUA_TYPE_am,
	capture: CaptureModule__DARKLUA_TYPE_an,
	[string]: any,
}

type CapturePanelModule__DARKLUA_TYPE_aq = {
	build: (parent: Frame, ctx: ShellContext__DARKLUA_TYPE_ak) -> PanelHandle__DARKLUA_TYPE_ap,
	descriptor: {
		id: string,
		title: string,
		defaultEnabled: boolean,
		build: (parent: Frame, ctx: ShellContext__DARKLUA_TYPE_ak) -> PanelHandle__DARKLUA_TYPE_ap,
	},
}

-- == Per-build state record (the C1-C3-safe shape) ==

-- Everything the monolith held as forward-declared build-closure locals lives here
-- as fields; methods reach siblings through `panel.*` (call-time field reads), never
-- a read-before-local. One record per build() so each panel instance is isolated.
type PanelState__DARKLUA_TYPE_ar = {
	ctx: ShellContext__DARKLUA_TYPE_ak,
	parent: Frame,
	resultLabel: TextLabel,
	errorLabel: TextLabel,
	syncing: boolean,
	running: boolean,
	autoPolling: boolean,
	pollGeneration: number,
	sessionHasBaseline: boolean,
	pausedBaseline: { revision: number, instanceCount: number },

	formatError: (self: PanelState__DARKLUA_TYPE_ar, prefix: string, result: any) -> string,
	probe: (self: PanelState__DARKLUA_TYPE_ar) -> boolean,
	statusFn: (self: PanelState__DARKLUA_TYPE_ar, options: { silent: boolean }?) -> SyncResult__DARKLUA_TYPE_ao,
	syncFn: (self: PanelState__DARKLUA_TYPE_ar, options: any?) -> SyncResult__DARKLUA_TYPE_ao,
	startupConnectAndCapture: (self: PanelState__DARKLUA_TYPE_ar) -> SyncResult__DARKLUA_TYPE_ao,
	onReturnToEdit: (self: PanelState__DARKLUA_TYPE_ar) -> (),
}
local __DARKLUA_BUNDLE_MODULES={cache={}::any}do do local function __modImpl()
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

local Config: ConfigModule__DARKLUA_TYPE_a = {
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
end function __DARKLUA_BUNDLE_MODULES.a():typeof(__modImpl())local v=__DARKLUA_BUNDLE_MODULES.cache.a if not v then v={c=__modImpl()}__DARKLUA_BUNDLE_MODULES.cache.a=v end return v.c end end do local function __modImpl()--!strict
-- Settings — typed wrappers over plugin:GetSetting/SetSetting, ported faithfully
-- from the monolith's Settings block (StudioStud.plugin.lua:903-1005).
--
-- Two trust boundaries are hardened here, ONCE:
--   1. plugin:GetSetting returns `any` (persisted JSON the user/Studio can corrupt).
--      Every read is pcall-guarded AND type-checked, falling back to the caller's
--      default — so the rest of the plugin only ever sees the requested scalar type.
--   2. plugin:SetSetting can throw (e.g. unserializable value); writes are
--      pcall-swallowed exactly as the monolith did (best-effort persistence).
--
-- E5 (cache-at-event): `getDebounceMs` and the write token are read on hot paths
-- (the tick interval, every authed request). Both are memoized and the cache slot
-- is invalidated at the single write boundary (`setString`/`setNumber`) when the
-- matching key is written — so a value read once is O(1) thereafter, and a change
-- is reflected immediately without a stale window. The setting KEYS are the single
-- source of truth (Config.SETTINGS); the cache keys off those same constants.
--
-- panelEnabled is JSON-encoded into one string setting (a map), matching the
-- monolith — HttpService does the encode/decode, hardened with pcall + type check.

-- NB: this module imports no shared aliases from ./Types — every value it
-- persists is a scalar or a JSON map it declares locally (PanelEnabledMap). It
-- depends only on Config for the setting-key/threshold single source of truth, so
-- requiring ./Types would be a dead dependency. (Per luau-craft: import what you
-- use; the wire types live with the modules that emit the wire.)

local Config = __DARKLUA_BUNDLE_MODULES.a()

local SETTINGS = Config.SETTINGS
local DEBOUNCE_MS_MIN = Config.DEBOUNCE_MS_MIN
local DEBOUNCE_MS_MAX = Config.DEBOUNCE_MS_MAX
local DEBOUNCE_MS_DEFAULT = Config.DEBOUNCE_MS_DEFAULT

-- == Engine handles ==

-- `plugin` and `game` are Studio/plugin globals typed via globalTypes.d.luau under
-- the analyzer. Capture `plugin` into a local once (single trust point for the
-- settings store); HttpService is resolved lazily-and-cached on first JSON use
-- (cache-at-event) so the scalar accessors never touch it.











































local pluginHandle: Plugin = plugin

local httpService: HttpService? = nil
local function getHttpService(): HttpService
	local cached = httpService
	if cached then
		return cached
	end
	local resolved = game:GetService("HttpService") :: HttpService
	httpService = resolved
	return resolved
end

-- == E5 cache (cache-at-event) ==

-- Memoized hot-path reads. `nil` means "not yet computed"; the next get populates
-- it, and setString/setNumber clear the matching slot when their key is written.
-- Single source of truth: keyed off Config.SETTINGS, not literal strings.
local cachedDebounceMs: number? = nil
local cachedWriteToken: string? = nil

-- == Scalar accessors (trust boundary: GetSetting returns `any`) ==

local function getString(key: string, defaultValue: string): string
	local ok, value = pcall(function()
		return pluginHandle:GetSetting(key)
	end)
	if ok and typeof(value) == "string" and value ~= "" then
		return value
	end
	return defaultValue
end

local function setString(key: string, value: string): ()
	-- Invalidate the matching E5 slot BEFORE the write so a concurrent reader can
	-- never observe a stale cache paired with the new stored value.
	if key == SETTINGS.writeToken then
		cachedWriteToken = nil
	end
	pcall(function()
		pluginHandle:SetSetting(key, value)
	end)
end

local function getBool(key: string, defaultValue: boolean): boolean
	local ok, value = pcall(function()
		return pluginHandle:GetSetting(key)
	end)
	if ok and typeof(value) == "boolean" then
		return value
	end
	return defaultValue
end

local function setBool(key: string, value: boolean): ()
	pcall(function()
		pluginHandle:SetSetting(key, value)
	end)
end

local function getNumber(key: string, defaultValue: number): number
	local ok, value = pcall(function()
		return pluginHandle:GetSetting(key)
	end)
	if ok and typeof(value) == "number" then
		return value
	end
	return defaultValue
end

local function setNumber(key: string, value: number): ()
	if key == SETTINGS.debounceMs then
		cachedDebounceMs = nil
	end
	pcall(function()
		pluginHandle:SetSetting(key, value)
	end)
end

-- == Debounce (E5-cached) ==

-- Clamp+round a raw ms value into [MIN,MAX]. Single recipe shared by get and set
-- so the value read back always equals the value written (the SelfTest round-trip
-- invariant). `math.floor(value + 0.5)` is the monolith's round-half-up.
local function clampDebounceMs(value: number): number
	return math.clamp(math.floor(value + 0.5), DEBOUNCE_MS_MIN, DEBOUNCE_MS_MAX)
end

local function getDebounceMs(): number
	local cached = cachedDebounceMs
	if cached then
		return cached
	end
	local computed = clampDebounceMs(getNumber(SETTINGS.debounceMs, DEBOUNCE_MS_DEFAULT))
	cachedDebounceMs = computed
	return computed
end

local function setDebounceMs(value: number): ()
	-- setNumber clears the cache slot; recompute lazily on the next get.
	setNumber(SETTINGS.debounceMs, clampDebounceMs(value))
end

-- == Write token (E5-cached) ==

local function getWriteToken(): string
	local cached = cachedWriteToken
	if cached then
		return cached
	end
	local token = getString(SETTINGS.writeToken, "")
	cachedWriteToken = token
	return token
end

-- == Panel enabled map (JSON-encoded single setting) ==

local function getPanelEnabledMap(): PanelEnabledMap__DARKLUA_TYPE_b
	local raw = getString(SETTINGS.panelEnabled, "{}")
	local ok, decoded = pcall(function()
		return getHttpService():JSONDecode(raw)
	end)
	if ok and type(decoded) == "table" then
		return decoded
	end
	return {}
end

local function setPanelEnabledMap(map: PanelEnabledMap__DARKLUA_TYPE_b): ()
	-- Faithful to the monolith: encode unguarded by pcall (a panel map is always
	-- a plain {string:boolean} table, so JSONEncode cannot fail here), then route
	-- through setString. setString itself swallows SetSetting errors.
	setString(SETTINGS.panelEnabled, getHttpService():JSONEncode(map))
end

local function getPanelEnabled(panelId: string, defaultEnabled: boolean): boolean
	local map = getPanelEnabledMap()
	local value = map[panelId]
	-- Membership-first semantics (matches the monolith): absent key -> default
	-- (default true unless explicitly false); present key -> strict `== true`.
	if value == nil then
		return defaultEnabled ~= false
	end
	return value == true
end

local function setPanelEnabled(panelId: string, enabled: boolean): ()
	local map = getPanelEnabledMap()
	map[panelId] = enabled
	setPanelEnabledMap(map)
end

local function clearPanelEnabled(panelId: string): ()
	local map = getPanelEnabledMap()
	map[panelId] = nil
	setPanelEnabledMap(map)
end

-- == Debug logging gate ==

local function debugLog(...: any): ()
	if getBool(SETTINGS.debugLogging, false) then
		warn("[StudioStud]", ...)
	end
end

-- == One-time defaults migration ==

-- Persisted settings survive plugin upgrades (they're keyed in Studio's plugin settings),
-- so a pre-0.4.26 install still shows the old 300ms debounce and debug-on after updating.
-- Run ONCE per revision to bring those onto the defaults the user now expects; afterwards
-- the user's own changes persist normally. Guarded by `settingsRev` so it never re-clobbers.
local SETTINGS_REV = "0.4.26"
local function applyDefaultsMigration(): ()
	if getString(SETTINGS.settingsRev, "") == SETTINGS_REV then
		return
	end
	setDebounceMs(DEBOUNCE_MS_DEFAULT)
	setBool(SETTINGS.debugLogging, false)
	setString(SETTINGS.settingsRev, SETTINGS_REV)
end

-- == Module table ==

local Settings: SettingsModule__DARKLUA_TYPE_c = {
	getString = getString,
	setString = setString,
	getBool = getBool,
	setBool = setBool,
	getNumber = getNumber,
	setNumber = setNumber,

	getDebounceMs = getDebounceMs,
	setDebounceMs = setDebounceMs,
	getWriteToken = getWriteToken,

	getPanelEnabledMap = getPanelEnabledMap,
	setPanelEnabledMap = setPanelEnabledMap,
	getPanelEnabled = getPanelEnabled,
	setPanelEnabled = setPanelEnabled,
	clearPanelEnabled = clearPanelEnabled,

	debugLog = debugLog,

	applyDefaultsMigration = applyDefaultsMigration,
}

return Settings
end function __DARKLUA_BUNDLE_MODULES.b():typeof(__modImpl())local v=__DARKLUA_BUNDLE_MODULES.cache.b if not v then v={c=__modImpl()}__DARKLUA_BUNDLE_MODULES.cache.b=v end return v.c end end do local function __modImpl()--!strict
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


local Settings = __DARKLUA_BUNDLE_MODULES.b()

-- == Module table ==

-- Single table; methods reach siblings via `Registry.*` (call-time field reads),
-- never via a forward-referenced local. State initialised to the monolith's
-- defaults: empty ordered descriptor list, empty handle map, nothing selected,
-- host unwired until setHost.
































































































local Registry = {} :: RegistryModule__DARKLUA_TYPE_g
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

function Registry.register(descriptor: PanelDescriptor__DARKLUA_TYPE_d): (boolean, string?)
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

function Registry.list(): { PanelListItem__DARKLUA_TYPE_f }
	local items: { PanelListItem__DARKLUA_TYPE_f } = {}
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

	local targetDescriptor: PanelDescriptor__DARKLUA_TYPE_d? = nil
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
	local handle: PanelHandle__DARKLUA_TYPE_e
	local existing = Registry.handles[id]
	if existing then
		handle = existing
	else
		local frame = Instance.new("Frame")
		frame.Name = "Panel_" .. id
		frame.BackgroundTransparency = 1
		frame.Size = UDim2.fromScale(1, 1)
		frame.Parent = panelHost
		local built: PanelHandle__DARKLUA_TYPE_e = targetDescriptor.build(frame, getCtx()) or { frame = frame }
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

function Registry.getHandle(id: string): PanelHandle__DARKLUA_TYPE_e?
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
end function __DARKLUA_BUNDLE_MODULES.c():typeof(__modImpl())local v=__DARKLUA_BUNDLE_MODULES.cache.c if not v then v={c=__modImpl()}__DARKLUA_BUNDLE_MODULES.cache.c=v end return v.c end end do local function __modImpl()
-- == Module table ==

-- Single table; methods reach siblings/state via `GlobalApi.*` (call-time field
-- reads), never via a forward-referenced local. Internal handlers start nil
-- (disabled), matching the monolith pre-wire state.












































































































local GlobalApi = {} :: GlobalApiModule__DARKLUA_TYPE_k
GlobalApi.statusFn = nil
GlobalApi.syncFn = nil

-- Our private ownership token: a fresh table whose identity is unique to this
-- module instance. Stamped into `_G.StudioStud.__studioStudOwner` on install and
-- compared on owns()/reclaim(). Using a table identity (not a string/function)
-- means no other plugin can forge or accidentally collide with it.
local OWNER_TOKEN: {} = {}

-- `_G` is the untyped shared plugin global. Read it through one typed accessor so
-- the rest of the module annotates against StudioStudGlobal instead of `any`. This
-- is the trust boundary: `_G.StudioStud` is whatever some other plugin may have
-- left there, so it is `any` here and only trusted after the token check in owns().
local function globalSlot(): StudioStudGlobal__DARKLUA_TYPE_j?
	-- luau-lsp does not model `_G` as a typed table; treat the lookup as `any` once,
	-- here, rather than disabling checks (M1).
	-- selene: allow(global_usage)
	local slot = (_G :: any).StudioStud
	if type(slot) == "table" then
		return slot :: StudioStudGlobal__DARKLUA_TYPE_j
	end
	return nil
end

-- The write side of the same trust boundary: assign `_G.StudioStud` through one
-- typed accessor (a clean, non-`;`-prefixed statement) so install/reclaim never
-- inline a `_G` write and the `global_usage` suppression lives in exactly one place.
local function setGlobalSlot(value: StudioStudGlobal__DARKLUA_TYPE_j?): ()
	-- selene: allow(global_usage)
	local globals = _G :: any
	globals.StudioStud = value
end

function GlobalApi.makeDisabledFn(): CaptureHandler__DARKLUA_TYPE_h
	return function(): { [string]: any }
		warn("[Studio Stud] Capture/Query panel is disabled")
		return { ok = false, error = "panel disabled" }
	end
end

function GlobalApi.installNoOps(): ()
	-- S2: nothing is published to `_G`, so disabling is purely dropping the internal
	-- references. (The monolith set `_G.StudioStud.{Status,Sync,Capture}` to the
	-- disabled fn; those keys no longer exist on the global.)
	GlobalApi.statusFn = nil
	GlobalApi.syncFn = nil
end

function GlobalApi.wireCapture(statusFn: CaptureHandler__DARKLUA_TYPE_h, syncFn: CaptureHandler__DARKLUA_TYPE_h): ()
	-- S2: store internally instead of publishing onto `_G`. The monolith mapped both
	-- `Sync` and `Capture` to syncFn; here a single internal `syncFn` is the source
	-- of truth and any caller (panel/SelfTest) reads it off `GlobalApi.syncFn`.
	GlobalApi.statusFn = statusFn
	GlobalApi.syncFn = syncFn
end

function GlobalApi.install(runSelfTest: SelfTestFn__DARKLUA_TYPE_i): ()
	-- Faithful to `_G.StudioStud = _G.StudioStud or {}`: reuse an existing table if a
	-- prior load (or another plugin) left one, otherwise create ours. Then stamp the
	-- ownership token and publish the single allowed entry point (S2). `slot` is a
	-- non-optional local so the analyzer can prove the field writes below are safe
	-- (no giant closure, no nilable narrowing dance).
	local slot: StudioStudGlobal__DARKLUA_TYPE_j = globalSlot() or {} :: StudioStudGlobal__DARKLUA_TYPE_j
	setGlobalSlot(slot)
	slot.__studioStudOwner = OWNER_TOKEN
	slot.RunSelfTest = runSelfTest
end

function GlobalApi.owns(): boolean
	local slot = globalSlot()
	return slot ~= nil and slot.__studioStudOwner == OWNER_TOKEN
end

function GlobalApi.reclaim(): ()
	-- Only nil the slot when WE still own it (token match), faithful to the
	-- monolith's `RunSelfTest == SelfTest.run` ownership identity guard — a later
	-- plugin that overwrote `_G.StudioStud` keeps its slot.
	if GlobalApi.owns() then
		setGlobalSlot(nil)
	end
end

return GlobalApi
end function __DARKLUA_BUNDLE_MODULES.d():typeof(__modImpl())local v=__DARKLUA_BUNDLE_MODULES.cache.d if not v then v={c=__modImpl()}__DARKLUA_BUNDLE_MODULES.cache.d=v end return v.c end end do local function __modImpl()
-- This module is types-only; nothing to instantiate. The empty table keeps it a
-- valid ModuleScript whose exported types are imported via `require`.














































































































































return {}
end function __DARKLUA_BUNDLE_MODULES.e():typeof(__modImpl())local v=__DARKLUA_BUNDLE_MODULES.cache.e if not v then v={c=__modImpl()}__DARKLUA_BUNDLE_MODULES.cache.e=v end return v.c end end do local function __modImpl()--!strict
-- Session — edit-vs-play mode detection. Ported faithfully from the monolith's
-- Session block (StudioStud.plugin.lua:25-48).
--
-- Studio Stud must talk to the daemon ONLY during a genuine edit session. Code
-- running in a play/run DataModel (Play Solo / F8 Run, or a stray copy embedded
-- in the place) reports IsRunning()=true / IsEdit()=false and is gated to "play".
-- The real plugin runs in the edit DataModel; during an F5 playtest (a separate
-- DataModel) it stays "edit" and never sees the running game, so there is nothing
-- to capture there.
--
-- `decide` is a PURE function (no DataModel reads) so its truth table stays
-- unit-testable headless. The only impure surface is `signals()`, the single
-- read point for the live RunService state.


local Types = __DARKLUA_BUNDLE_MODULES.e()

-- == Engine handle ==

-- `game` is a plugin/Studio global typed via globalTypes.d.luau under the
-- analyzer. Resolution is LAZY (and cached) rather than at module load so the
-- pure `decide` half can be required headlessly (lune has no `game`) for the
-- truth-table test. The first impure call (`signals`) narrows GetService's
-- Instance result to RunService exactly once — the single trust point for the
-- engine handle; every later call reuses the cached handle (cache-at-event).
































local runService: RunService? = nil
local function getRunService(): RunService
	local cached = runService
	if cached then
		return cached
	end
	local resolved = game:GetService("RunService") :: RunService
	runService = resolved
	return resolved
end

-- == Implementation ==

local function decide(isEdit: boolean, isRunning: boolean): SessionMode__DARKLUA_TYPE_A
	if isEdit and not isRunning then
		return "edit"
	end
	return "play"
end

local function signals(): Signals__DARKLUA_TYPE_B
	local rs = getRunService()
	return {
		isEdit = rs:IsEdit(),
		isRunning = rs:IsRunning(),
	}
end

local function mode(): SessionMode__DARKLUA_TYPE_A
	local sig = signals()
	return decide(sig.isEdit, sig.isRunning)
end

local function isEdit(): boolean
	return mode() == "edit"
end

-- == Module table ==

local Session: SessionModule__DARKLUA_TYPE_C = {
	decide = decide,
	signals = signals,
	mode = mode,
	isEdit = isEdit,
}

return Session
end function __DARKLUA_BUNDLE_MODULES.f():typeof(__modImpl())local v=__DARKLUA_BUNDLE_MODULES.cache.f if not v then v={c=__modImpl()}__DARKLUA_BUNDLE_MODULES.cache.f=v end return v.c end end do local function __modImpl()--!strict
-- Transport — all HTTP to the daemon, plus the JSON-safety net, ported faithfully
-- from the monolith's Transport block (StudioStud.plugin.lua:1006-1254).
--
-- Responsibilities (one each):
--   * daemon-URL parse/build/current  (parseDaemonUrl/buildDaemonUrl/currentUrl)
--   * JSON safety net  (sanitizeJsonValue/safeEncode) — PORTED VERBATIM, proven:
--       a capture can never hard-fail HttpService:JSONEncode.
--   * request primitives  (requestJson, requestJsonAuthed with write-token header,
--       requestBody for pre-encoded bulk chunks)
--   * write-token fetch/cache  (fetchWriteToken; the E5 cache lives in Settings)
--   * S1 loopback guard  — a capture/source upload only ever talks to a loopback
--       daemon (127.0.0.1 / localhost / ::1 / 127/8). Refuse anything else BEFORE
--       any data leaves the machine.
--
-- TRUST BOUNDARY (harden once, here): every daemon response is decoded `any`. The
-- request helpers return (ok, table) where the table is the decoded body on
-- success or a `{ error = ... }` shape on failure; `hardenTickResponse` coerces a
-- decoded body into the typed TickResponse the live engine consumes, so nothing
-- downstream re-validates the wire. The daemon is not trusted to send well-typed
-- JSON.
--
-- luau-craft notes:
--   * Settings owns the write-token cache (E5); Transport reads via getWriteToken
--     and writes via setString (which invalidates that slot) — single source of
--     truth, no second cache here.
--   * `_selfTestLastRequest` is the one observable seam the SelfTest reads to
--     assert the write-token header was attached; it is part of the typed
--     interface, not a stray global.


local Types = __DARKLUA_BUNDLE_MODULES.e()
local Config = __DARKLUA_BUNDLE_MODULES.a()
local Settings = __DARKLUA_BUNDLE_MODULES.b()




local SETTINGS = Config.SETTINGS
local DEFAULT_DAEMON_URL = Config.DEFAULT_DAEMON_URL

-- == Engine handles ==

-- HttpService is the only engine global Transport touches. Resolve-and-cache on
-- first use (cache-at-event) so module load order never matters.














































































local httpService: HttpService? = nil
local function getHttpService(): HttpService
	local cached = httpService
	if cached then
		return cached
	end
	local resolved = game:GetService("HttpService") :: HttpService
	httpService = resolved
	return resolved
end

-- Forward declaration of the module table so methods can reference one another
-- through it (e.g. requestJson -> safeEncode) WITHOUT forward-referencing a
-- not-yet-assigned local — the C1/C2/C3 bug class this rewrite exists to kill.
-- Every cross-call goes through `Transport.*`, which is a real table field by the
-- time any of these functions run.
local Transport: TransportModule__DARKLUA_TYPE_I

-- == Daemon URL (verbatim port) ==

local function parseDaemonUrl(url: string?): (string, string)
	if typeof(url) ~= "string" or url == "" then
		return "127.0.0.1", "31878"
	end
	local matchedHost: string?, matchedPort: string? = url:match("^https?://([^:/]+):?(%d*)/?$")
	if not matchedHost then
		matchedHost, matchedPort = url:match("^([^:/]+):?(%d*)$")
	end
	if not matchedHost or matchedHost == "" then
		return "127.0.0.1", "31878"
	end
	local port: string = matchedPort or ""
	if port == "" then
		port = "31878"
	end
	return matchedHost, port
end

local function buildDaemonUrl(host: string?, port: string?): string
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

local function currentUrl(): string
	return Settings.getString(SETTINGS.daemonUrl, DEFAULT_DAEMON_URL)
end

-- == S1 loopback guard ==

-- Pure predicate: is `host` a loopback address the daemon may run on? Accepts the
-- canonical forms and the whole 127/8 range (and the bracketed IPv6 form Studio
-- could hand back from a URL). Comparison is case-insensitive for "localhost".
-- Anything else — a LAN IP, a public host, an empty/garbage host — is rejected,
-- so capture/source never leaves this machine.
local function isLoopbackHost(host: string?): boolean
	if typeof(host) ~= "string" or host == "" then
		return false
	end
	local lowered = string.lower(host)
	-- Strip an IPv6 bracket form, e.g. "[::1]" -> "::1".
	if string.sub(lowered, 1, 1) == "[" and string.sub(lowered, -1) == "]" then
		lowered = string.sub(lowered, 2, -2)
	end
	if lowered == "localhost" or lowered == "::1" or lowered == "0:0:0:0:0:0:0:1" then
		return true
	end
	-- IPv4 loopback is the entire 127.0.0.0/8 block.
	local a, b, c, d = string.match(lowered, "^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if a then
		local octets = { tonumber(a), tonumber(b), tonumber(c), tonumber(d) }
		if octets[1] ~= 127 then
			return false
		end
		for _, octet in octets do
			if octet == nil or octet < 0 or octet > 255 then
				return false
			end
		end
		return true
	end
	return false
end

local function currentUrlIsLoopback(): boolean
	local host = parseDaemonUrl(currentUrl())
	return isLoopbackHost(host)
end

-- The gate every capture / source-upload path calls before sending. Returns
-- (true) when the configured daemon is loopback, else (false, humanReason) and
-- sends nothing — the S1 contract.
local function assertCaptureAllowed(): (boolean, string?)
	if currentUrlIsLoopback() then
		return true
	end
	local host = parseDaemonUrl(currentUrl())
	return false,
		("refusing capture: daemon host %q is not loopback (127.0.0.1/localhost/::1 only)"):format(host)
end

-- == JSON safety net (PORTED VERBATIM) ==

-- Make a value JSON-safe IN PLACE so HttpService:JSONEncode can never hard-fail a
-- capture:
--   * non-finite numbers (NaN / ±inf) -> 0   (corrupted physics can yield these in CFrame fields)
--   * invalid-UTF-8 strings            -> valid prefix + U+FFFD  (script Source, captured in 0.4.17+)
--   * cyclic tables                    -> dropped
--   * userdata / function / thread     -> {type="Unsupported"}   (defensive; serializeValue normally
--                                                                  converts these already)
-- Appends a human-readable description of every offender to `report` so the cause is logged.
local function sanitizeJsonValue(value: any, path: string, report: { string }, seen: { [any]: boolean }?): any
	local t = type(value)
	if t == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			report[#report + 1] = path .. "=" .. tostring(value)
			return 0
		end
		return value
	elseif t == "string" then
		local len, firstBad = utf8.len(value)
		if len == nil then
			report[#report + 1] = path .. " (invalid utf-8, " .. #value .. "B)"
			return string.sub(value, 1, ((firstBad :: number?) or 1) - 1) .. utf8.char(0xFFFD)
		end
		return value
	elseif t == "table" then
		seen = seen or {}
		local seenSet = seen :: { [any]: boolean }
		if seenSet[value] then
			report[#report + 1] = path .. " (cyclic)"
			return nil
		end
		seenSet[value] = true
		for key, item in pairs(value) do
			value[key] = sanitizeJsonValue(item, path .. "." .. tostring(key), report, seenSet)
		end
		seenSet[value] = nil
		return value
	elseif t == "boolean" or t == "nil" then
		return value
	end
	report[#report + 1] = path .. " (type=" .. typeof(value) .. ")"
	return { type = "Unsupported", reason = typeof(value) }
end

-- Encode, but never crash the capture on a stray non-encodable value: on failure,
-- sanitize in place (logging exactly which fields were wrong) and retry. Zero
-- overhead on clean payloads. Returns (ok, jsonTextOrError) just like a guarded
-- pcall(JSONEncode).
local function safeEncode(value: any, label: string?): (boolean, string)
	local http = getHttpService()
	local okEnc, encoded = pcall(function(): string
		return http:JSONEncode(value)
	end)
	if okEnc then
		return true, encoded
	end
	local report: { string } = {}
	sanitizeJsonValue(value, label or "root", report, nil)
	warn(
		("[StudioStud] safeEncode: %s had %d non-JSON value(s), sanitized: %s"):format(
			tostring(label),
			#report,
			table.concat(report, ", ")
		)
	)
	return pcall(function(): string
		return http:JSONEncode(value)
	end)
end

-- == Request primitives ==

-- Shared response decoder: turn an HttpResponseData into (ok, ResponseTable),
-- exactly as the monolith's three near-identical inline blocks did. Single recipe
-- (DRY) — on a non-Success response, surface the daemon's JSON error body with
-- its statusCode attached; on a JSON parse failure, surface a synthetic error.
local function decodeResponse(response: HttpResponse__DARKLUA_TYPE_G): (boolean, ResponseTable__DARKLUA_TYPE_H)
	local http = getHttpService()
	local body = response.Body or ""
	if not response.Success then
		local decodedOk, decoded = pcall(function(): any
			return http:JSONDecode(body)
		end)
		if decodedOk and type(decoded) == "table" then
			local errTable = decoded :: ResponseTable__DARKLUA_TYPE_H
			errTable.statusCode = response.StatusCode
			return false, errTable
		end
		return false, { error = response.StatusMessage, statusCode = response.StatusCode, body = response.Body }
	end
	local decodedOk, decoded = pcall(function(): any
		return http:JSONDecode(body)
	end)
	if not decodedOk then
		return false, { error = "Bad daemon JSON: " .. tostring(decoded) }
	end
	return true, decoded :: ResponseTable__DARKLUA_TYPE_H
end

-- Send a fully-built request table, hardening the RequestAsync call itself.
local function sendRequestTable(request: RequestTable__DARKLUA_TYPE_F): (boolean, ResponseTable__DARKLUA_TYPE_H)
	local http = getHttpService()
	local ok, response = pcall(function(): HttpResponse__DARKLUA_TYPE_G
		-- HttpRequestOptions requires a Compress field the monolith never set;
		-- cast at this single boundary (the engine defaults Compress to None).
		return http:RequestAsync(request :: any) :: HttpResponse__DARKLUA_TYPE_G
	end)
	if not ok then
		return false, { error = tostring(response) }
	end
	return decodeResponse(response :: HttpResponse__DARKLUA_TYPE_G)
end

local function requestJson(method: string, path: string, body: any?, timeoutSeconds: number?): (boolean, ResponseTable__DARKLUA_TYPE_H)
	local request: RequestTable__DARKLUA_TYPE_F = {
		Url = currentUrl() .. path,
		Method = method,
		Headers = { ["Content-Type"] = "application/json" },
		Timeout = timeoutSeconds or 30,
	}
	if body ~= nil then
		local encOk, encoded = safeEncode(body, path)
		if not encOk then
			warn("[StudioStud] JSONEncode failed for", path, ":", encoded)
			return false, { error = "JSONEncode: " .. tostring(encoded) }
		end
		request.Body = encoded
	end
	return sendRequestTable(request)
end

local function buildAuthedHeaders(token: string): { [string]: string }
	return {
		["Content-Type"] = "application/json",
		["X-StudioStud-Token"] = token,
	}
end

local function fetchWriteToken(): string
	local ok, result = requestJson("GET", "/studio-stud/write/token", nil)
	if ok and type(result) == "table" and type(result.token) == "string" and result.token ~= "" then
		-- setString invalidates the Settings E5 token slot, so getWriteToken sees
		-- this immediately on the next read (single source of truth for the cache).
		Settings.setString(SETTINGS.writeToken, result.token)
		return result.token
	end
	return ""
end

local function requestJsonAuthed(
	method: string,
	path: string,
	body: any?,
	timeoutSeconds: number?
): (boolean, ResponseTable__DARKLUA_TYPE_H)
	local function sendRequest(token: string): (boolean, ResponseTable__DARKLUA_TYPE_H)
		local request: RequestTable__DARKLUA_TYPE_F = {
			Url = currentUrl() .. path,
			Method = method,
			Headers = buildAuthedHeaders(token),
			Timeout = timeoutSeconds or 30,
		}
		Transport._selfTestLastRequest = request
		if body ~= nil then
			local encOk, encoded = safeEncode(body, path)
			if not encOk then
				warn("[StudioStud] JSONEncode failed for", path, ":", encoded)
				return false, { error = "JSONEncode: " .. tostring(encoded) }
			end
			request.Body = encoded
		end
		return sendRequestTable(request)
	end

	-- Read the cached token (Settings E5); fetch on a miss.
	local token = Settings.getWriteToken()
	if token == "" then
		token = fetchWriteToken()
	end
	if token == "" then
		return false, { error = "write token unavailable", blockedReason = "tokenInvalid" }
	end

	local ok, result = sendRequest(token)
	-- One refresh-and-retry on a 401 (the token rotated under us).
	if not ok and result.statusCode == 401 then
		token = fetchWriteToken()
		if token ~= "" then
			ok, result = sendRequest(token)
		end
	end
	return ok, result
end

-- Pre-encoded body path (the daemon's chunked /tick/bulk upload sends raw JSON
-- chunk strings, already encoded by the caller). 60s timeout, no Content-Type
-- token — verbatim port of the monolith's requestBody.
local function requestBody(path: string, body: string): (boolean, ResponseTable__DARKLUA_TYPE_H)
	local request: RequestTable__DARKLUA_TYPE_F = {
		Url = currentUrl() .. path,
		Method = "POST",
		Headers = { ["Content-Type"] = "application/json" },
		Body = body,
		Timeout = 60,
	}
	return sendRequestTable(request)
end

-- == Trust boundary: harden the tick response (harden once) ==

-- Coerce a decoded `any` daemon body into a typed TickResponse. Each field is
-- type-checked and defaulted; a non-table or absent `ok` collapses to
-- `{ ok = false }`. Downstream (the live engine) trusts the result and never
-- re-validates the wire.
local function hardenTickResponse(decoded: any): TickResponse__DARKLUA_TYPE_D
	if type(decoded) ~= "table" then
		return { ok = false }
	end
	local raw = decoded :: { [string]: any }

	local driftServices: { string }? = nil
	if type(raw.driftServices) == "table" then
		local cleaned: { string } = {}
		for _, name in ipairs(raw.driftServices) do
			if type(name) == "string" then
				cleaned[#cleaned + 1] = name
			end
		end
		driftServices = cleaned
	end

	local applyScripts: { ApplyScript__DARKLUA_TYPE_E }? = nil
	if type(raw.applyScripts) == "table" then
		local cleaned: { ApplyScript__DARKLUA_TYPE_E } = {}
		for _, entry in ipairs(raw.applyScripts) do
			if type(entry) == "table" then
				local e = entry :: { [string]: any }
				if
					type(e.studioPath) == "string"
					and type(e.newSource) == "string"
					and type(e.expectedPriorHash) == "string"
				then
					cleaned[#cleaned + 1] = {
						studioPath = e.studioPath,
						newSource = e.newSource,
						expectedPriorHash = e.expectedPriorHash,
					}
				end
			end
		end
		applyScripts = cleaned
	end

	local revision: number? = nil
	if type(raw.revision) == "number" then
		revision = raw.revision
	end
	local instanceCount: number? = nil
	if type(raw.instanceCount) == "number" then
		instanceCount = raw.instanceCount
	end
	local errorText: string? = nil
	if type(raw.error) == "string" then
		errorText = raw.error
	end

	return {
		ok = raw.ok == true,
		revision = revision,
		instanceCount = instanceCount,
		driftServices = driftServices,
		request = raw.request,
		applyScripts = applyScripts,
		error = errorText,
	}
end

-- == Module table ==

Transport = {
	parseDaemonUrl = parseDaemonUrl,
	buildDaemonUrl = buildDaemonUrl,
	currentUrl = currentUrl,

	isLoopbackHost = isLoopbackHost,
	currentUrlIsLoopback = currentUrlIsLoopback,
	assertCaptureAllowed = assertCaptureAllowed,

	sanitizeJsonValue = sanitizeJsonValue,
	safeEncode = safeEncode,

	requestJson = requestJson,
	requestJsonAuthed = requestJsonAuthed,
	requestBody = requestBody,

	buildAuthedHeaders = buildAuthedHeaders,
	fetchWriteToken = fetchWriteToken,

	hardenTickResponse = hardenTickResponse,

	_selfTestLastRequest = nil,
}

return Transport
end function __DARKLUA_BUNDLE_MODULES.g():typeof(__modImpl())local v=__DARKLUA_BUNDLE_MODULES.cache.g if not v then v={c=__modImpl()}__DARKLUA_BUNDLE_MODULES.cache.g=v end return v.c end end do local function __modImpl()--!strict
-- AllowList — property-curation source of truth, ported faithfully from the
-- monolith's AllowList block (StudioStud.plugin.lua:1256-1323).
--
-- The daemon serves /studio-stud/allowlist: per exact ClassName, the ordered set
-- of properties capture should read (including inherited props) and whether each
-- is read-only. When that fetch succeeds, it overrides the static curation; when
-- it fails (daemon down, bad JSON, malformed body) the plugin keeps the static
-- Config.CLASS_PROPERTIES fallback and capture proceeds — a fetch failure is
-- NEVER fatal. This module owns the loaded-vs-fallback decision; capture's
-- getPropertyNames/curatedSet ask namesFor/setFor and fall back themselves when
-- those return nil.
--
-- Responsibilities (one each):
--   * parse(decoded) — PURE: a decoded /allowlist body -> { version, sets, lists }
--       or nil on bad input. The headless-testable surface (AllowList.spec).
--   * fetch() — GET /allowlist via Transport, parse, and on success swap in the
--       parsed sets/lists/version + mark loaded. On any failure: log (debug) and
--       leave the static fallback in place, returning false.
--   * namesFor(className) / setFor(className) — the per-class lookups capture
--       consumes. Both return nil unless loaded AND the exact class is present, so
--       an unknown class (even when loaded) falls through to the static list in
--       capture. This nil-on-unknown contract is load-bearing — reproduced exactly.
--
-- State model: this module carries mutable state (loaded/version/sets/lists). It
-- lives as fields on the module table (`AllowList.*`), and every method reaches
-- the state through that table — never through a forward-referenced upvalue. This
-- is the structural defense against the C1-C3 forward-reference bug class: the
-- table is a real value before any method runs, so there is no "before-local"
-- window to read a nil through.
--
-- TRUST BOUNDARY (harden once): the decoded /allowlist body is untrusted `any`.
-- parse is the single place it is validated; it walks every class/entry with
-- type guards and silently drops anything malformed, so namesFor/setFor only ever
-- hand capture well-formed ordered lists and boolean membership sets.

-- NB: this module does NOT require ./Config. The static CLASS_PROPERTIES fallback
-- is owned by Config and consumed by Capture (getPropertyNames/curatedSet) when
-- namesFor/setFor return nil — AllowList itself never reads it, so requiring
-- Config here would be a dead dependency (luau-craft: import what you use).

local Types = __DARKLUA_BUNDLE_MODULES.e()
local Settings = __DARKLUA_BUNDLE_MODULES.b()
local Transport = __DARKLUA_BUNDLE_MODULES.g()

-- Forward declaration of the module table so methods reference one another and
-- the mutable state through it (e.g. fetch -> parse, fetch -> AllowList.sets)
-- WITHOUT forward-referencing a not-yet-assigned local. Every cross-reference
-- goes through `AllowList.*`, which is a real table field by the time any method
-- runs — the C1/C2/C3 bug class this rewrite exists to kill.


































local AllowList: AllowListModule__DARKLUA_TYPE_L

-- == parse (PURE — the headless-testable surface) ==

-- Turn a decoded /allowlist body into { version, sets, lists }, or nil on bad
-- input. Verbatim port: a non-table body, or one whose `classes` is not a table,
-- yields nil (caller keeps the static fallback). Each class's `props` must be a
-- table; each entry must be a table with a string `name`. readOnly defaults to
-- false unless the entry says exactly `true` (`entry.readOnly == true`), matching
-- the monolith. Anything malformed is skipped, never fatal.
local function parse(decoded: any): ParsedAllowList__DARKLUA_TYPE_K?
	if type(decoded) ~= "table" or type(decoded.classes) ~= "table" then
		return nil
	end
	local raw = decoded :: { classes: { [string]: any }, version: any }
	local sets: { [string]: ClassPropSet__DARKLUA_TYPE_J } = {}
	local lists: { [string]: { string } } = {}
	for className, props in raw.classes do
		if type(props) == "table" then
			local set: ClassPropSet__DARKLUA_TYPE_J = {}
			local list: { string } = {}
			for _, entry in ipairs(props :: { any }) do
				if type(entry) == "table" and type(entry.name) == "string" then
					local name: string = entry.name
					set[name] = entry.readOnly == true
					list[#list + 1] = name
				end
			end
			sets[className] = set
			lists[className] = list
		end
	end
	return { version = raw.version, sets = sets, lists = lists }
end

-- == fetch ==

-- GET /allowlist via Transport, parse, and on success swap in the parsed state.
-- On any failure (request not ok, or parse nil) log via Settings.debugLog and
-- return false, leaving loaded/sets/lists/version untouched so the static
-- fallback stays in force. Verbatim behavior of the monolith's AllowList.fetch.
local function fetch(): boolean
	local ok, decoded = Transport.requestJson("GET", "/studio-stud/allowlist", nil, 15)
	if not ok then
		Settings.debugLog("allowlist: fetch failed (static fallback):", decoded and decoded.error)
		return false
	end
	local parsed = AllowList.parse(decoded)
	if not parsed then
		Settings.debugLog("allowlist: bad response (static fallback)")
		return false
	end
	AllowList.sets = parsed.sets
	AllowList.lists = parsed.lists
	AllowList.version = parsed.version
	AllowList.loaded = true
	local count = 0
	for _ in parsed.sets do
		count += 1
	end
	Settings.debugLog("allowlist: loaded version", tostring(parsed.version), "classes", count)
	return true
end

-- == per-class lookups ==

-- Ordered property names for an exact class. nil unless loaded AND the class is
-- present in the loaded lists — an unknown class returns nil even when loaded, so
-- capture falls through to the static CLASS_PROPERTIES. (Indexing a missing class
-- yields nil; the explicit `loaded` gate matches the monolith's early-out.)
local function namesFor(className: string): { string }?
	if AllowList.loaded then
		return AllowList.lists[className]
	end
	return nil
end

-- Membership set { propName = readOnly } for an exact class. Same nil-on-unknown
-- contract as namesFor.
local function setFor(className: string): ClassPropSet__DARKLUA_TYPE_J?
	if AllowList.loaded then
		return AllowList.sets[className]
	end
	return nil
end

-- == Module table ==

-- Initial state mirrors the monolith: not loaded, no version, empty sets/lists.
-- While unloaded, namesFor/setFor return nil and capture uses the static
-- Config.CLASS_PROPERTIES fallback (owned by Config, applied in Capture).
AllowList = {
	loaded = false,
	version = nil,
	sets = {},
	lists = {},

	parse = parse,
	fetch = fetch,
	namesFor = namesFor,
	setFor = setFor,
}

return AllowList
end function __DARKLUA_BUNDLE_MODULES.h():typeof(__modImpl())local v=__DARKLUA_BUNDLE_MODULES.cache.h if not v then v={c=__modImpl()}__DARKLUA_BUNDLE_MODULES.cache.h=v end return v.c end end do local function __modImpl()--!strict
-- Hash — the fingerprint recipe, ported VERBATIM from the monolith's Live
-- fingerprint block (StudioStud.plugin.lua:2189-2302). This is FP-1, the
-- plugin-authoritative drift hash: the daemon stores and XORs whatever value the
-- plugin emits, so the hash bytes MUST be byte-identical to the old plugin or
-- every tick reports phantom drift. NOTHING here may be "improved" — the canonical
-- string, the lane offsets, the FNV multiply/mod, and the hex layout are the wire.
--
-- This module is the SINGLE SOURCE OF TRUTH for the one fingerprint recipe used by
-- both the per-op entry hash (Fingerprints.applyFpUpsert) and the per-service XOR
-- accumulator (Fingerprints byte ops). It owns:
--   * hashInstance(entry) -> Hex64 — the 4-lane FNV-32 → 64-hex canonical hash.
--   * serviceOf(path) -> string — the leading path segment (service name).
--   * the byte helpers fpZero / fpHexToBytes / fpBytesToHex / fpXor used by the
--     XOR accumulators. (Named fpZero/fpXor here, matching the contract; the
--     monolith's locals were fpZeroBytes/fpXorBytes.)
--
-- M3 (by design): `source` is EXCLUDED from the canonical string. A script's text
-- edit changes `source` but NOT its fingerprint, so source-only edits do not show
-- as structural drift; the source rides the entry (Types.InstanceEntry.source) but
-- is never hashed. The canonical field order is, verbatim:
--   className | name | parentId | path | depth | siblingIndex | childCount |
--   duplicateSiblingName(0/1) | properties | attributes | tags
-- with map keys sorted and tags joined by ",".
--
-- PURE: no DataModel reads, no module state, no upvalue forward references. Every
-- function is a plain local assigned into the module table before return, so there
-- is no before-local window (the C1-C3 bug class this rewrite exists to kill).


local Types = __DARKLUA_BUNDLE_MODULES.e()

-- == FNV constants (the wire — do not touch) ==

-- Four lane offsets (monolith :2189). Lane i hashes the canonical string with
-- offset[i] for the low word and a derived offset for the high word.





























local FNV32_OFFSETS = { 0x811C9DC5, 0x050C5D1F, 0x9E3779B9, 0x7F4A7C15 }
-- The 32-bit FNV prime (monolith :2190).
local FNV32_PRIME = 16777619
-- 2^32, the FNV-32 modulus. Named so the hot multiply reads as a masking step.
local FNV32_MOD = 4294967296
-- High-word offset perturbation: lane offset XOR this constant (monolith :2267).
local HI_OFFSET_XOR = 0xA5A5A5A5

-- == Canonical-string serialization (verbatim) ==

-- Sorted string keys of a table. Every key is tostring'd first so mixed key types
-- order deterministically, then table.sort'd (monolith :2192). Returns a fresh
-- ordered array — the canonical map serialization iterates this, never raw pairs,
-- so the byte order is stable across runs.
local function fpSortedKeys(tbl: { [any]: any }): { string }
	local keys: { string } = {}
	for key in pairs(tbl) do
		keys[#keys + 1] = tostring(key)
	end
	table.sort(keys)
	return keys
end

-- Forward declaration so fpSerializeScalar can recurse into nested tables without
-- referencing a not-yet-assigned local (it calls itself; declaring the type up
-- front keeps the recursion strict-typed and avoids a before-local read).
local fpSerializeScalar: (value: any) -> string

-- Serialize one scalar value to its canonical token (monolith :2201). typeof-based
-- so it matches the engine's runtime type of captured property values:
--   string  -> "s:" .. value
--   number  -> "n:" .. tostring(value)
--   boolean -> "b:1" / "b:0"
--   nil     -> "z"
--   table   -> array form "[a,b,...]" when #value > 0, else map form "{k=v;...}"
--   else    -> "u:" .. tostring(value)  (userdata/datatypes etc.)
-- Recurses for nested tables (arrays and maps) exactly as the monolith did.
function fpSerializeScalar(value: any): string
	local kind = typeof(value)
	if kind == "string" then
		return "s:" .. value
	elseif kind == "number" then
		return "n:" .. tostring(value)
	elseif kind == "boolean" then
		-- Real if/else over the boolean — not the and/or trap (luau-craft).
		if value then
			return "b:1"
		else
			return "b:0"
		end
	elseif kind == "nil" then
		return "z"
	elseif kind == "table" then
		local tbl = value :: { [any]: any }
		if #tbl > 0 then
			local parts: { string } = {}
			for _, item in ipairs(tbl) do
				parts[#parts + 1] = fpSerializeScalar(item)
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local parts: { string } = {}
		for _, key in ipairs(fpSortedKeys(tbl)) do
			parts[#parts + 1] = key .. "=" .. fpSerializeScalar(tbl[key])
		end
		return "{" .. table.concat(parts, ";") .. "}"
	end
	return "u:" .. tostring(value)
end

-- Serialize a property/attribute map to "key=scalar;key=scalar;..." with keys
-- sorted (monolith :2228). A nil map serializes as the empty string.
local function fpSerializeMap(map: { [string]: any }?): string
	local source: { [any]: any } = map or {}
	local parts: { string } = {}
	for _, key in ipairs(fpSortedKeys(source)) do
		parts[#parts + 1] = key .. "=" .. fpSerializeScalar(source[key])
	end
	return table.concat(parts, ";")
end

-- == FNV-32 core (verbatim) ==

-- One lane of FNV-32 over a string from a given offset (monolith :2236).
-- h := offset; for each byte: h = ((h XOR byte) * PRIME) mod 2^32. Hot path:
-- one xor + one multiply + one mod per character, no allocation.
local function fnv32(str: string, offset: number): number
	local h = offset
	for i = 1, #str do
		h = bit32.bxor(h, string.byte(str, i))
		h = (h * FNV32_PRIME) % FNV32_MOD
	end
	return h
end

-- == hashInstance (the FP-1 recipe — byte-identical to the monolith) ==

-- Build the canonical pipe string and hash it across 4 lanes into 64 hex chars.
-- VERBATIM port of Live.hashInstance (monolith :2245). Field order and defaults
-- are the wire: each missing field falls back exactly as the old code did
-- (className/name/parentId/path -> "", depth/siblingIndex/childCount -> 0,
-- duplicateSiblingName -> "1"/"0"). `source` is NOT included (M3). For each lane,
-- the low word hashes the canonical string from the lane offset and the high word
-- hashes canonical .. "#" .. lane from (offset XOR 0xA5A5A5A5); the lane emits
-- "%08x%08x" (lo then hi), and the four lanes concatenate to 64 hex.
local function hashInstance(entry: InstanceEntry__DARKLUA_TYPE_O): Hex64__DARKLUA_TYPE_M
	-- entry is typed, but the monolith hashed `entry.x or default` on raw capture
	-- output; widen to `any` for the exact tostring/or fallbacks so the bytes match
	-- even if a field arrives nil off an untrusted/partial entry.
	local e = entry :: any
	local parts: { string } = {
		tostring(e.className or ""),
		tostring(e.name or ""),
		tostring(e.parentId or ""),
		tostring(e.path or ""),
		tostring(e.depth or 0),
		tostring(e.siblingIndex or 0),
		tostring(e.childCount or 0),
		(if e.duplicateSiblingName then "1" else "0"),
		fpSerializeMap(e.properties),
		fpSerializeMap(e.attributes),
	}
	local tagParts: { string } = {}
	for _, tag in ipairs(e.tags or {}) do
		tagParts[#tagParts + 1] = tostring(tag)
	end
	parts[#parts + 1] = table.concat(tagParts, ",")

	local canonical = table.concat(parts, "|")
	local hexParts: { string } = {}
	for lane = 1, 4 do
		local lo = fnv32(canonical, FNV32_OFFSETS[lane])
		local hi = fnv32(canonical .. "#" .. tostring(lane), bit32.bxor(FNV32_OFFSETS[lane], HI_OFFSET_XOR))
		hexParts[#hexParts + 1] = string.format("%08x%08x", lo, hi)
	end
	return table.concat(hexParts)
end

-- == serviceOf ==

-- Leading path segment before the first "/", or the whole path when there is no
-- "/". A nil path is treated as "" (monolith :2300): match returns nil, so we
-- fall back to "" — preserving the old `... or (path or "")` chain.
local function serviceOf(path: string?): string
	local p = path or ""
	return string.match(p, "^([^/]+)") or p
end

-- == Byte helpers (32-byte XOR accumulator primitives) ==

-- A fresh 32-zero byte array (monolith fpZeroBytes :2273).
local function fpZero(): Bytes__DARKLUA_TYPE_N
	return table.create(32, 0)
end

-- Unpack 64 hex chars into 32 bytes. Each byte is the value of a 2-char hex pair;
-- a bad/short pair yields 0 via the tonumber fallback (monolith fpHexToBytes :2278).
local function fpHexToBytes(hex: string): Bytes__DARKLUA_TYPE_N
	local bytes: Bytes__DARKLUA_TYPE_N = table.create(32, 0)
	for i = 1, 32 do
		bytes[i] = tonumber(string.sub(hex, (i - 1) * 2 + 1, (i - 1) * 2 + 2), 16) or 0
	end
	return bytes
end

-- Pack 32 bytes into 64 lowercase hex (nil entries → "00"; monolith fpBytesToHex
-- :2286).
local function fpBytesToHex(bytes: Bytes__DARKLUA_TYPE_N): Hex64__DARKLUA_TYPE_M
	local parts: { string } = table.create(32, "")
	for i = 1, 32 do
		parts[i] = string.format("%02x", bytes[i] or 0)
	end
	return table.concat(parts)
end

-- In-place 32-byte XOR of `source` into `target` (monolith fpXorBytes :2294).
-- nil entries on either side count as 0. Returns target for call-site convenience
-- (the monolith mutated in place; returning it changes nothing for in-place uses).
local function fpXor(target: Bytes__DARKLUA_TYPE_N, source: Bytes__DARKLUA_TYPE_N): Bytes__DARKLUA_TYPE_N
	for i = 1, 32 do
		target[i] = bit32.bxor(target[i] or 0, source[i] or 0)
	end
	return target
end

-- == Module table ==

-- Assembled as a real value before return; every cross-reference above is a plain
-- local, so there is no forward-reference-before-local read anywhere in the module.
local Hash: HashModule__DARKLUA_TYPE_P = {
	hashInstance = hashInstance,
	serviceOf = serviceOf,
	fpZero = fpZero,
	fpHexToBytes = fpHexToBytes,
	fpBytesToHex = fpBytesToHex,
	fpXor = fpXor,
}

return Hash
end function __DARKLUA_BUNDLE_MODULES.i():typeof(__modImpl())local v=__DARKLUA_BUNDLE_MODULES.cache.i if not v then v={c=__modImpl()}__DARKLUA_BUNDLE_MODULES.cache.i=v end return v.c end end do local function __modImpl()--!strict
-- Fingerprints — the live per-service XOR accumulators, ported faithfully from the
-- monolith's Live fingerprint block (StudioStud.plugin.lua: instFp/serviceFpBytes
-- :2183-2184, serviceFpHex :2304, serviceFingerprintsWire :2312, applyFpUpsert
-- :2320, applyFpRemove :2337, resetFingerprints :2348). This is the FP-1 live half:
-- the daemon stores and XORs whatever per-service fingerprint the plugin emits, so
-- the accumulator math (and the recipe behind it) MUST be byte-identical to the old
-- plugin or every tick reports phantom drift.
--
-- The recipe itself (the 4-lane FNV → 64-hex hash and the 32-byte XOR primitives)
-- lives in Hash — the single source of truth. This module owns ONLY the per-service
-- accumulation: which fingerprint belongs to which service, and the add / remove /
-- REPARENT inverse (XOR the old fingerprint out of the old service, XOR the new
-- fingerprint into the new service). It never re-derives the hash math.
--
-- The accumulator is XOR-based, so it is order-independent and self-inverse:
--   * add A, add B            -> serviceFp == hash(A) XOR hash(B)
--   * remove A                -> serviceFp == hash(B)        (A XOR'd back out)
--   * re-add A                -> serviceFp == hash(A) XOR hash(B)  (restored)
-- A reparent is just remove-from-old + add-to-new in one call: applyFpUpsert with a
-- distinct oldPath XORs the stored fingerprint out of serviceOf(oldPath) and the new
-- fingerprint into serviceOf(entry.path).
--
-- STATE: instFp ([id] = current 64-hex fingerprint) and serviceFpBytes ([service] =
-- 32-byte XOR accumulator) are module fields on the Fingerprints table — every method
-- reaches them through `Fingerprints.*`, never a forward-referenced upvalue, so there
-- is no before-local window (the C1-C3 bug class this rewrite exists to kill). The
-- monolith held the same two tables on its giant Live closure; here they are explicit
-- typed fields the Live engine can also read (Types.LiveState pins their shape).
--
-- M3 (by design): a fingerprint never includes `source` (Hash excludes it), so a
-- script-only edit does not change the per-service accumulator — no phantom drift.


local Types = __DARKLUA_BUNDLE_MODULES.e()
local Hash = __DARKLUA_BUNDLE_MODULES.i()

-- Forward declaration of the module table so methods reach the shared state through
-- it (Fingerprints.instFp / Fingerprints.serviceFpBytes) WITHOUT a forward-referenced
-- upvalue. Fingerprints.* is a real table field by the time any method runs.



































































local Fingerprints: FingerprintsModule__DARKLUA_TYPE_T

-- == serviceFpHex ==

-- 64-hex of a service's accumulator, or 64 zeros when none exists yet. VERBATIM
-- port of Live.serviceFpHex (monolith :2304): the bytes-missing branch returns
-- string.rep("0", 64), NOT fpZero packed (same value, but the monolith short-circuited
-- before allocating a byte array — preserved here).
local function serviceFpHex(self: FingerprintsModule__DARKLUA_TYPE_T, service: string): Hex64__DARKLUA_TYPE_Q
	local bytes = self.serviceFpBytes[service]
	if not bytes then
		return string.rep("0", 64)
	end
	return Hash.fpBytesToHex(bytes)
end

-- == serviceFingerprintsWire ==

-- The per-service wire map { [service] = 64-hex } over every service with an
-- accumulator. VERBATIM port of Live.serviceFingerprintsWire (monolith :2312):
-- iterate serviceFpBytes keys, emit serviceFpHex for each. Only services that have
-- ever held a fingerprint appear (a service that was added then fully removed stays
-- in the map with a 64-zero value — exactly as the monolith left it, because
-- applyFpRemove never deletes the serviceFpBytes entry).
local function serviceFingerprintsWire(self: FingerprintsModule__DARKLUA_TYPE_T): { [string]: Hex64__DARKLUA_TYPE_Q }
	local out: { [string]: Hex64__DARKLUA_TYPE_Q } = {}
	for service in pairs(self.serviceFpBytes) do
		out[service] = self:serviceFpHex(service)
	end
	return out
end

-- == applyFpUpsert (add / update / reparent) ==

-- VERBATIM port of Live.applyFpUpsert (monolith :2320). Order matters and is
-- preserved exactly:
--   1. newFp = entry.fp or Hash.hashInstance(entry); write it back onto entry.fp.
--   2. newService = serviceOf(entry.path).
--   3. If an old fingerprint exists for this id, XOR it OUT of serviceOf(oldPath or
--      entry.path) — the reparent inverse. (oldPath defaults to entry.path, so a
--      same-service update XORs the old value out of the same service it goes back in.)
--   4. XOR newFp INTO newService.
--   5. instFp[id] = newFp.
-- A fresh service accumulator is fpZero() (lazily created), matching the monolith's
-- `Live.serviceFpBytes[...] or fpZeroBytes()`.
local function applyFpUpsert(self: FingerprintsModule__DARKLUA_TYPE_T, id: string, entry: FpEntry__DARKLUA_TYPE_S, oldPath: string?): ()
	-- Real if/else over the optional fp (luau-craft: no `a or b` where b can throw /
	-- allocate unconditionally — though here both are values, the monolith's `or` is
	-- a cheap fallback so we keep the same single-evaluation semantics).
	local newFp: Hex64__DARKLUA_TYPE_Q
	if entry.fp then
		newFp = entry.fp
	else
		newFp = Hash.hashInstance(entry :: any)
	end
	entry.fp = newFp

	local newService = Hash.serviceOf(entry.path)
	local oldFp = self.instFp[id]
	if oldFp then
		local oldService = Hash.serviceOf(oldPath or entry.path)
		local svcBytes = self.serviceFpBytes[oldService]
		if not svcBytes then
			svcBytes = Hash.fpZero()
		end
		Hash.fpXor(svcBytes, Hash.fpHexToBytes(oldFp))
		self.serviceFpBytes[oldService] = svcBytes
	end

	local newBytes = self.serviceFpBytes[newService]
	if not newBytes then
		newBytes = Hash.fpZero()
	end
	Hash.fpXor(newBytes, Hash.fpHexToBytes(newFp))
	self.serviceFpBytes[newService] = newBytes

	self.instFp[id] = newFp
end

-- == applyFpRemove ==

-- VERBATIM port of Live.applyFpRemove (monolith :2337). XOR the stored fingerprint
-- out of serviceOf(path) and clear instFp[id]. If the id has no stored fingerprint,
-- only the (no-op) clear runs — the accumulator is untouched. The serviceFpBytes
-- entry is NOT deleted even when it returns to all-zero (monolith parity: the empty
-- service lingers in serviceFingerprintsWire as 64 zeros).
local function applyFpRemove(self: FingerprintsModule__DARKLUA_TYPE_T, id: string, path: string?): ()
	local oldFp = self.instFp[id]
	if oldFp then
		local service = Hash.serviceOf(path or "")
		local svcBytes = self.serviceFpBytes[service]
		if not svcBytes then
			svcBytes = Hash.fpZero()
		end
		Hash.fpXor(svcBytes, Hash.fpHexToBytes(oldFp))
		self.serviceFpBytes[service] = svcBytes
	end
	self.instFp[id] = nil
end

-- == reset ==

-- Drop all fingerprint state by replacing both tables with fresh empties. VERBATIM
-- port of Live.resetFingerprints (monolith :2348): new tables, not table.clear, so
-- any reference held to the OLD tables (e.g. a wire map already emitted) is unaffected.
local function reset(self: FingerprintsModule__DARKLUA_TYPE_T): ()
	self.instFp = {}
	self.serviceFpBytes = {}
end

-- == Module table ==

-- Assembled as a real value before return; the state tables start empty and every
-- method above reaches them via `self`, so there is no forward-reference-before-local
-- read anywhere in the module.
Fingerprints = {
	instFp = {},
	serviceFpBytes = {},
	serviceFpHex = serviceFpHex,
	serviceFingerprintsWire = serviceFingerprintsWire,
	applyFpUpsert = applyFpUpsert,
	applyFpRemove = applyFpRemove,
	reset = reset,
}

return Fingerprints
end function __DARKLUA_BUNDLE_MODULES.j():typeof(__modImpl())local v=__DARKLUA_BUNDLE_MODULES.cache.j if not v then v={c=__modImpl()}__DARKLUA_BUNDLE_MODULES.cache.j=v end return v.c end end do local function __modImpl()
-- == Module table ==








































local Theme: ThemeModule__DARKLUA_TYPE_U = table.freeze({
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
end function __DARKLUA_BUNDLE_MODULES.k():typeof(__modImpl())local v=__DARKLUA_BUNDLE_MODULES.cache.k if not v then v={c=__modImpl()}__DARKLUA_BUNDLE_MODULES.cache.k=v end return v.c end end do local function __modImpl()--!strict
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


local Theme = __DARKLUA_BUNDLE_MODULES.k()
local Config = __DARKLUA_BUNDLE_MODULES.a()

-- `game` is a Studio/plugin global the analyzer types via globalTypes.d.luau.
-- UserInputService drives slider dragging; resolved once at module load (it is a
-- process-wide singleton, so there is no per-event GetService on the hot drag path
-- — cache-at-event) and shared by every slider built thereafter.
local UserInputService = game:GetService("UserInputService") :: UserInputService

-- The resolved logo asset id ("" or a valid rbxassetid://… string), from Config —
-- the single source of truth for the icon constant. makeBrandBadge prefers the
-- image when present, else falls back to the drawn vector logo.
local resolvedLogoAssetId = Config.resolvedLogoAssetId

-- == Module table ==

-- All factories are fields on this one table; no forward-referenced upvalue is
-- ever read before it is assigned (the C1-C3 bug class). Where one factory calls
-- another (e.g. makePrimaryButton -> makeCorner), it goes through `Ui.*`, which is
-- a field read resolved at call time, never a use-before-local.












































local Ui = {} :: UiModule__DARKLUA_TYPE_X

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
): MsSlider__DARKLUA_TYPE_V
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

function Ui.makeStatusCard(parent: Instance, y: number): StatusCard__DARKLUA_TYPE_W
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
end function __DARKLUA_BUNDLE_MODULES.l():typeof(__modImpl())local v=__DARKLUA_BUNDLE_MODULES.cache.l if not v then v={c=__modImpl()}__DARKLUA_BUNDLE_MODULES.cache.l=v end return v.c end end do local function __modImpl()--!strict
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


local Theme = __DARKLUA_BUNDLE_MODULES.k()
local Ui = __DARKLUA_BUNDLE_MODULES.l()
local Config = __DARKLUA_BUNDLE_MODULES.a()
local Registry = __DARKLUA_BUNDLE_MODULES.c()
local Settings = __DARKLUA_BUNDLE_MODULES.b()
local Transport = __DARKLUA_BUNDLE_MODULES.g()



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

-- == Module table ==

-- Single table; methods reach siblings via `Shell.*` (call-time field reads),
-- never via a forward-referenced local. State initialised to the monolith's
-- defaults. `widget`/`toolbarButton` are assigned immediately below (the
-- bootstrap-at-load the monolith ran inline) so the typed fields are never nil
-- after this module returns.




























































local Shell = {} :: ShellModule__DARKLUA_TYPE__
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

function Shell.makeCtx(): ShellContext__DARKLUA_TYPE_Z
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

	-- With a single enabled panel the tab selector is pointless chrome; hide the strip so
	-- the panel body owns the surface. Only show tabs when there's a real choice (>1).
	local enabledCount = 0
	for _, item in ipairs(Registry.list()) do
		if item.enabled then
			enabledCount += 1
		end
	end
	tabStrip.Visible = enabledCount > 1
	if enabledCount <= 1 then
		return
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

	-- Live capture is mandatory (always on) — no user toggle. The label + note remain as
	-- an explanation of the automatic behavior.
	Ui.makeSectionLabel(scroll, "Live capture", y)
	y += 18
	local liveNote = Ui.makeLabel(
		scroll,
		"Auto-starts on plugin load. Signals stream changes to the daemon each tick and self-heal on drift. Reconnects automatically if the daemon restarts.",
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

local WAITING_FOR_SERVE_MSG = "Waiting for studio-stud serve…"

function Shell.onWidgetEnabled(): ()
	Shell.autoConnectGeneration += 1
	local myGeneration = Shell.autoConnectGeneration

	local function resolveConnectHandle(): any?
		local selectedId = Registry.selected()
		local handle = if selectedId then Registry.getHandle(selectedId) else nil
		if not handle then
			local firstId = Registry.firstEnabledId()
			if firstId then
				Registry.select(firstId)
				handle = Registry.getHandle(firstId)
			end
		end
		if handle and handle.probe and handle.onConnectRequested then
			return handle
		end
		return nil
	end

	task.spawn(function()
		local waitingShown = false
		local handle = resolveConnectHandle()
		if handle and handle.setAutoPolling then
			handle.setAutoPolling(true)
		end

		while Shell.autoConnectGeneration == myGeneration and Shell.widget.Enabled do
			if Shell.connected then
				waitingShown = false
				task.wait(1)
				continue
			end

			handle = resolveConnectHandle()
			if not handle then
				task.wait(1)
				continue
			end

			if not waitingShown then
				local card = Shell.statusCard
				if card then
					card.setState("waiting", WAITING_FOR_SERVE_MSG)
				end
				waitingShown = true
			end

			if handle.probe() then
				handle.onConnectRequested()
			end
			task.wait(1)
		end

		if handle and handle.setAutoPolling then
			handle.setAutoPolling(false)
		end
	end)
end

return Shell
end function __DARKLUA_BUNDLE_MODULES.m():typeof(__modImpl())local v=__DARKLUA_BUNDLE_MODULES.cache.m if not v then v={c=__modImpl()}__DARKLUA_BUNDLE_MODULES.cache.m=v end return v.c end end do local function __modImpl()--!strict
-- SelfTest — the in-engine acceptance harness, ported faithfully from the
-- monolith's SelfTest block (StudioStud.plugin.lua:3918-4571) and re-pointed at
-- the modular API. Every assertion the monolith ran is preserved (Workstream E,
-- Phase 3/4/5C, JSON-safety, edit-gate, allow-list parse), PLUS the new
-- regressions this rewrite exists to lock in: C1 (markDirtyUpsert sets
-- dirtyUpsert[inst] WITHOUT recursion), C2 (a simulated connect passes a NON-NIL
-- onReturnToEdit to startTickLoop), C3 (Sync() before live mode does not nil-call),
-- and a Hash wire-parity assertion (the new Hash.hashInstance must agree with the
-- monolith's recipe oracle, byte-for-byte).
--
-- WHY THIS RUNS IN-ENGINE ONLY: it drives the real Registry/Shell/Live engine over
-- a live DataModel (Instance.new, game:GetService, GetDebugId, signal wiring). It is
-- NOT a pure module, so — like the monolith's SelfTest.run — it is exercised through
-- `_G.StudioStud.RunSelfTest()` inside Studio, never headless under lune. (The pure
-- modules it leans on — Hash / Fingerprints / Capture / Live byte sizing — have their
-- own headless lune specs under __tests__/; this harness is the integration layer.)
--
-- API RE-POINTING (the monolith's flat `live.*` surface, now modular):
--   live.hashInstance               -> Hash.hashInstance
--   live.resetFingerprints          -> Fingerprints:reset()
--   live.applyFpUpsert/applyFpRemove -> Fingerprints:applyFpUpsert / :applyFpRemove
--   live.serviceFpHex               -> Fingerprints:serviceFpHex
--   live.serviceFingerprintsWire    -> Fingerprints:serviceFingerprintsWire()
--   live.buildTickBody              -> Live:buildTickBody (a `:` method)
--   live.buildBaselineSnapshot      -> Live:buildBaselineSnapshot (`:` method)
--   live.classifyChangedProp        -> Live:classifyChangedProp (`:` method)
--   live.recordPropGap              -> Live:recordPropGap (`:` method)
--   live.registerInstance/...       -> Live:registerInstance / :unregisterInstance
--   live.setupAfterBaseline         -> Live:setupAfterBaseline (`:` method)
--   live.teardown                   -> Live:teardown (`:` method)
--   live.collectOpsFromEntries(...) -> Live:collectOpsFromDirty() over real dirty
--                                      instances (the byte-incremental cap is now
--                                      internal to collectOpsFromDirty — driven here
--                                      with a fat + small instance, the E1 forward-
--                                      progress path).
-- DEVIATIONS from the monolith assertion set (functions that no longer exist as a
-- standalone surface; the BEHAVIOR they tested is preserved and re-asserted through
-- the surviving API):
--   * `live.classifyPayload(n)` is gone — payload inline/bulk is no longer a named
--     predicate; the wire boundary is Config.TICK_INLINE_THRESHOLD. The two
--     classify assertions are re-expressed as the same threshold comparison.
--   * `live.scheduleDriftRecovery(svc, up, rm)` is gone — drift recovery is now
--     Live:triggerDriftRecovery, which is guarded (no-op off-live) and never touches
--     the dirty sets. The "drift recovery preserves dirty" intent is re-asserted by
--     marking dirty, invoking the guarded recovery, and confirming the dirty sets
--     survive.
--
-- Structure note (the bug class this rewrite kills): SelfTest holds no
-- forward-referenced upvalues. `assert`/`run` are fields on the module table reached
-- through `SelfTest.*` (call-time field reads), and every collaborator is a required
-- module table. There is no before-local window anywhere here.


local Config = __DARKLUA_BUNDLE_MODULES.a()
local Session = __DARKLUA_BUNDLE_MODULES.f()
local Settings = __DARKLUA_BUNDLE_MODULES.b()
local Transport = __DARKLUA_BUNDLE_MODULES.g()
local AllowList = __DARKLUA_BUNDLE_MODULES.h()
local Hash = __DARKLUA_BUNDLE_MODULES.i()
local Fingerprints = __DARKLUA_BUNDLE_MODULES.j()
local Registry = __DARKLUA_BUNDLE_MODULES.c()
local GlobalApi = __DARKLUA_BUNDLE_MODULES.d()
local Theme = __DARKLUA_BUNDLE_MODULES.k()
local Shell = __DARKLUA_BUNDLE_MODULES.m()

local SETTINGS = Config.SETTINGS
local DEFAULT_DAEMON_URL = Config.DEFAULT_DAEMON_URL
local TICK_INLINE_THRESHOLD = Config.TICK_INLINE_THRESHOLD

-- == Monolith fingerprint oracle (the Hash wire-parity guard) ==

-- The 0.4.21 fingerprint recipe, copied VERBATIM from StudioStud.plugin.lua:2189-2302
-- as an independent oracle. The new Hash.hashInstance MUST agree with this
-- byte-for-byte or the unchanged daemon sees phantom drift on every tick. This is the
-- in-engine twin of Hash.spec's headless oracle — kept here so the Studio gate proves
-- parity in the real runtime too.
local ORACLE_OFFSETS = { 0x811C9DC5, 0x050C5D1F, 0x9E3779B9, 0x7F4A7C15 }
local ORACLE_PRIME = 16777619

local function oracleSortedKeys(tbl: { [any]: any }): { string }
	local keys: { string } = {}
	for key in pairs(tbl) do
		keys[#keys + 1] = tostring(key)
	end
	table.sort(keys)
	return keys
end

local oracleSerializeScalar: (value: any) -> string
function oracleSerializeScalar(value: any): string
	local kind = typeof(value)
	if kind == "string" then
		return "s:" .. value
	elseif kind == "number" then
		return "n:" .. tostring(value)
	elseif kind == "boolean" then
		if value then
			return "b:1"
		else
			return "b:0"
		end
	elseif kind == "nil" then
		return "z"
	elseif kind == "table" then
		local tbl = value :: { [any]: any }
		if #tbl > 0 then
			local parts: { string } = {}
			for _, item in ipairs(tbl) do
				parts[#parts + 1] = oracleSerializeScalar(item)
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local parts: { string } = {}
		for _, key in ipairs(oracleSortedKeys(tbl)) do
			parts[#parts + 1] = key .. "=" .. oracleSerializeScalar(tbl[key])
		end
		return "{" .. table.concat(parts, ";") .. "}"
	end
	return "u:" .. tostring(value)
end

local function oracleSerializeMap(map: { [string]: any }?): string
	local source: { [any]: any } = map or {}
	local parts: { string } = {}
	for _, key in ipairs(oracleSortedKeys(source)) do
		parts[#parts + 1] = key .. "=" .. oracleSerializeScalar(source[key])
	end
	return table.concat(parts, ";")
end

local function oracleFnv32(str: string, offset: number): number
	local h = offset
	for i = 1, #str do
		h = bit32.bxor(h, string.byte(str, i))
		h = (h * ORACLE_PRIME) % 4294967296
	end
	return h
end

local function oracleHashInstance(entry: { [string]: any }): string
	local parts: { string } = {
		tostring(entry.className or ""),
		tostring(entry.name or ""),
		tostring(entry.parentId or ""),
		tostring(entry.path or ""),
		tostring(entry.depth or 0),
		tostring(entry.siblingIndex or 0),
		tostring(entry.childCount or 0),
		(if entry.duplicateSiblingName then "1" else "0"),
		oracleSerializeMap(entry.properties),
		oracleSerializeMap(entry.attributes),
	}
	local tagParts: { string } = {}
	for _, tag in ipairs(entry.tags or {}) do
		tagParts[#tagParts + 1] = tostring(tag)
	end
	parts[#parts + 1] = table.concat(tagParts, ",")
	local canonical = table.concat(parts, "|")
	local hexParts: { string } = {}
	for lane = 1, 4 do
		local lo = oracleFnv32(canonical, ORACLE_OFFSETS[lane])
		local hi = oracleFnv32(canonical .. "#" .. tostring(lane), bit32.bxor(ORACLE_OFFSETS[lane], 0xA5A5A5A5))
		hexParts[#hexParts + 1] = string.format("%08x%08x", lo, hi)
	end
	return table.concat(hexParts)
end

-- Single module table; methods reach one another via `SelfTest.*` (call-time field
-- reads), never a forward-referenced upvalue.













local SelfTest = {} :: SelfTestModule__DARKLUA_TYPE_0

-- == assert ==

function SelfTest.assert(name: string, condition: any, failures: { string }): ()
	if condition then
		print("[Studio Stud SelfTest] PASS:", name)
	else
		failures[#failures + 1] = name
		warn("[Studio Stud SelfTest] FAIL:", name)
	end
end

-- == run ==

function SelfTest.run(): boolean
	local failures: { string } = {}
	local preIds = Registry.snapshotIds()
	local origLive = Settings.getBool(SETTINGS.liveCaptureEnabled, true)
	local origDebounce = Settings.getNumber(SETTINGS.debounceMs, 300)
	local origUrl = Settings.getString(SETTINGS.daemonUrl, DEFAULT_DAEMON_URL)

	-- HttpService for the JSON-safety raw-encode checks (resolved once, cache-at-event).
	local httpService = game:GetService("HttpService")

	-- A dummy panel descriptor factory (verbatim port of makeDummy, monolith :3938):
	-- a registerable panel whose handle exposes show/hide/destroy counters.
	local function makeDummy(id: string, title: string): PanelDescriptor__DARKLUA_TYPE_d		
local showCount = 0
		local hideCount = 0
		local destroyCount = 0
		local descriptor: PanelDescriptor__DARKLUA_TYPE_d= {
			id = id,
			title = title,
			defaultEnabled = true,
			build = function(parent: Frame, _ctx: any): PanelHandle__DARKLUA_TYPE_e				
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
					showCount = function(): number
						return showCount
					end,
					hideCount = function(): number
						return hideCount
					end,
					destroyCount = function(): number
						return destroyCount
					end,
				}
			end,
		}
		return descriptor
	end

	local dummyA = makeDummy("__selftest_a", "SelfTest A")
	local dummyB = makeDummy("__selftest_b", "SelfTest B")

	local okA = Registry.register(dummyA)
	SelfTest.assert("register dummy A", okA, failures)
	local okDup = Registry.register(dummyA)
	SelfTest.assert("reject duplicate id", not okDup, failures)
	local okB = Registry.register(dummyB)
	SelfTest.assert("register dummy B", okB, failures)

	local idsAfterRegister = Registry.snapshotIds()
	local indexA: number?, indexB: number? = nil, nil
	for index, id in ipairs(idsAfterRegister) do
		if id == "__selftest_a" then
			indexA = index
		elseif id == "__selftest_b" then
			indexB = index
		end
	end
	SelfTest.assert("registration order", indexA ~= nil and indexB ~= nil and indexA < indexB, failures)

	Registry.select("__selftest_a")
	Registry.select("__selftest_b")
	local handleA = Registry.getHandle("__selftest_a")
	local handleB = Registry.getHandle("__selftest_b")
	SelfTest.assert(
		"select lifecycle onShow/onHide",
		handleA ~= nil and handleB ~= nil and handleA.hideCount() >= 1 and handleB.showCount() >= 1,
		failures
	)

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
	local oldRunning = (oldRunningFn ~= nil and oldRunningFn()) or false

	Registry.unregister("__selftest_a")
	Registry.unregister("__selftest_b")
	SelfTest.assert(
		"unregister removes dummy ids",
		Registry.snapshotIds()[1] == "capture" and #Registry.snapshotIds() == 1,
		failures
	)

	Registry.teardownAll()
	SelfTest.assert(
		"teardown stops capture loop",
		captureHandleBefore ~= nil and not captureHandleBefore.isRunning(),
		failures
	)
	-- S2: `_G.StudioStud` no longer publishes `Sync`; the disabled-handler is held
	-- internally on GlobalApi (the panel destroy ran installNoOps on teardown). The
	-- monolith asserted `_G.StudioStud.Sync()` returned the disabled shape; the faithful
	-- equivalent under S2 is GlobalApi.syncFn being cleared (the disabled state).
	SelfTest.assert("_G no-op while torn down (S2: syncFn cleared)", GlobalApi.syncFn == nil, failures)
	local disabledFn = GlobalApi.makeDisabledFn()
	local disabledResult = disabledFn()
	SelfTest.assert(
		"disabled handler shape",
		disabledResult.ok == false and disabledResult.error == "panel disabled",
		failures
	)

	Shell.build()
	local captureHandleAfter = Registry.getHandle("capture")
	SelfTest.assert("re-init capture handle", captureHandleAfter ~= nil, failures)
	-- S2: identity is now GlobalApi.syncFn == handle.sync (the panel wires its sync entry
	-- into GlobalApi on build), replacing the monolith's `_G.StudioStud.Sync == handle.sync`.
	SelfTest.assert(
		"_G re-wire identity (S2: GlobalApi.syncFn == handle.sync)",
		captureHandleAfter ~= nil and GlobalApi.syncFn == captureHandleAfter.sync,
		failures
	)
	SelfTest.assert(
		"single poll loop after re-init",
		captureHandleAfter ~= nil
			and captureHandleAfter.isRunning()
			and (not oldRunning or (captureHandleBefore ~= nil and not captureHandleBefore.isRunning())),
		failures
	)

	local tabCount = 0
	local tabStrip0 = Shell.tabStrip
	if tabStrip0 then
		for _, child in ipairs(tabStrip0:GetChildren()) do
			if child:IsA("TextButton") then
				tabCount += 1
			end
		end
	end
	Shell.build()
	local tabCountAgain = 0
	local tabStrip1 = Shell.tabStrip
	if tabStrip1 then
		for _, child in ipairs(tabStrip1:GetChildren()) do
			if child:IsA("TextButton") then
				tabCountAgain += 1
			end
		end
	end
	-- A single enabled panel hides the tab strip (0 tab buttons); a rebuild stays
	-- idempotent — same count, no stacked/duplicate tabs.
	SelfTest.assert(
		"single-panel build hides tab strip (idempotent)",
		tabCountAgain == 0 and tabCountAgain == tabCount,
		failures
	)
	SelfTest.assert(
		"no ghost selftest tabs",
		not string.find(table.concat(Registry.snapshotIds(), ","), "__selftest"),
		failures
	)

	-- == Live machinery self-tests (Workstream E) ==
	do
		-- GetDebugId stability across reparent.
		local testFolder = Instance.new("Folder")
		testFolder.Name = "StudioStudSelfTestLive"
		testFolder.Parent = game:GetService("ReplicatedStorage")
		local okBefore, idBeforeRaw = pcall(function(): string
			return testFolder:GetDebugId(0)
		end)
		local idBefore = if okBefore then idBeforeRaw else ""
		testFolder.Parent = game:GetService("ServerStorage")
		local okAfter, idAfterRaw = pcall(function(): string
			return testFolder:GetDebugId(0)
		end)
		local idAfter = if okAfter then idAfterRaw else ""
		SelfTest.assert("GetDebugId stable across reparent", idBefore ~= "" and idBefore == idAfter, failures)
		testFolder:Destroy()
	end

	-- The capture/live exports off the rebuilt panel handle.
	local captureHandleLive = Registry.getHandle("capture")
	local live = captureHandleLive and captureHandleLive.live
	local capture = captureHandleLive and captureHandleLive.capture

	-- == Phase 3: getPropertyNames + curatedSet routing ==
	do
		if capture then
			local part = Instance.new("Part")
			-- not loaded -> static fallback includes CFrame (BasePart).
			AllowList.loaded = false
			local fallbackNames = capture.getPropertyNames(part)
			local hasCFrame = false
			for _, n in ipairs(fallbackNames) do
				if n == "CFrame" then
					hasCFrame = true
				end
			end
			SelfTest.assert("getPropertyNames fallback includes CFrame", hasCFrame, failures)
			-- loaded -> uses the allow-list.
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
			-- restore.
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
				__index = function(_, key: any): any
					if key == "BadProp" then
						error("read failed")
					end
					if key == "GoodProp" then
						return 1
					end
					if key == "GoodProp2" then
						return 1
					end
					return nil
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
			local srcUtf8, encUtf8 = capture.readSource(mod)
			SelfTest.assert("readSource ModuleScript utf8", srcUtf8 == "return 42" and encUtf8 == "utf8", failures)
			local part = Instance.new("Part")
			local srcNil, encNil = capture.readSource(part)
			SelfTest.assert("readSource non-script nil", srcNil == nil and encNil == nil, failures)
			local binary = string.char(0xFF, 0x00, 0xAB)
			local encB64 = capture.base64encode(binary)
			local roundTrip = capture.base64decode(encB64)
			SelfTest.assert("base64 round-trip", roundTrip == binary, failures)
			SelfTest.assert("base64 alphabet valid", string.match(encB64, "^[A-Za-z0-9+/=]+$") ~= nil, failures)
			mod:Destroy()
			part:Destroy()
		else
			print("[Studio Stud SelfTest] SKIP: capture handle not available (phase 4)")
		end
	end

	-- == Hash wire-parity (NEW regression): Hash.hashInstance must equal the
	-- monolith recipe oracle byte-for-byte, in the live runtime. A drift here means
	-- the unchanged daemon would report phantom drift on every tick. ==
	do
		local sample: { [string]: any } = {
			id = "hp1",
			className = "Part",
			name = "P",
			parentId = "ws",
			path = "Workspace/P[1]",
			depth = 1,
			siblingIndex = 1,
			childCount = 0,
			duplicateSiblingName = true,
			properties = {
				Transparency = 0.5,
				Anchored = true,
				CanCollide = false,
				Size = { type = "Vector3", x = 1, y = 2, z = 3 },
				CFrame = { 0, 5, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1 },
			},
			attributes = { foo = "bar", count = 7 },
			tags = { "tagA", "tagB" },
		}
		SelfTest.assert(
			"Hash parity: full entry matches monolith oracle",
			Hash.hashInstance(sample :: any) == oracleHashInstance(sample),
			failures
		)
		-- source is EXCLUDED (M3): an entry differing only by source hashes equal.
		local withSource: { [string]: any } = table.clone(sample)
		withSource.source = "print('x')"
		withSource.sourceEncoding = "utf8"
		SelfTest.assert(
			"Hash parity: source excluded from hash (M3)",
			Hash.hashInstance(withSource :: any) == Hash.hashInstance(sample :: any),
			failures
		)
		-- sparse defaults reproduce the monolith `or` fallbacks.
		local sparse: { [string]: any } = { id = "sp" }
		SelfTest.assert(
			"Hash parity: sparse defaults match oracle",
			Hash.hashInstance(sparse :: any) == oracleHashInstance(sparse),
			failures
		)
	end

	-- == Phase 5C: hashInstance + incremental serviceFp ==
	if live then
		do
			local realLive = live :: typeof(live)
			local sample: { [string]: any } = {
				id = "a1",
				className = "Part",
				name = "P",
				parentId = "ws",
				path = "Workspace/P[1]",
				depth = 1,
				siblingIndex = 1,
				childCount = 0,
				duplicateSiblingName = false,
				properties = { Transparency = 0.5, Size = { type = "Vector3", x = 1, y = 2, z = 3 } },
				attributes = { foo = "bar" },
				tags = { "tagA", "tagB" },
			}
			local h1 = Hash.hashInstance(sample :: any)
			local h2 = Hash.hashInstance(sample :: any)
			SelfTest.assert("hashInstance stable", h1 == h2, failures)
			SelfTest.assert("hashInstance 64 hex", #h1 == 64 and string.match(h1, "^[0-9a-f]+$") ~= nil, failures)

			local snap = realLive:buildBaselineSnapshot("selftest")
			SelfTest.assert("baseline snapshot has instances", #snap.instances > 0, failures)
			local reordered: { [string]: any } = {
				id = "a1",
				className = "Part",
				name = "P",
				parentId = "ws",
				path = "Workspace/P[1]",
				depth = 1,
				siblingIndex = 1,
				childCount = 0,
				duplicateSiblingName = false,
				properties = { Size = { type = "Vector3", x = 1, y = 2, z = 3 }, Transparency = 0.5 },
				attributes = { foo = "bar" },
				tags = { "tagA", "tagB" },
			}
			SelfTest.assert("hashInstance property order invariant", Hash.hashInstance(reordered :: any) == h1, failures)
			sample.properties.Transparency = 0.6
			SelfTest.assert("hashInstance property change", Hash.hashInstance(sample :: any) ~= h1, failures)

			Fingerprints:reset()
			local entryA: { [string]: any } = {
				id = "a",
				className = "Part",
				name = "A",
				parentId = "ws",
				path = "Workspace/A[1]",
				depth = 1,
				siblingIndex = 1,
				childCount = 0,
				duplicateSiblingName = false,
				properties = {},
				attributes = {},
				tags = {},
			}
			local entryB: { [string]: any } = {
				id = "b",
				className = "Part",
				name = "B",
				parentId = "ws",
				path = "Workspace/B[1]",
				depth = 1,
				siblingIndex = 2,
				childCount = 0,
				duplicateSiblingName = false,
				properties = {},
				attributes = {},
				tags = {},
			}
			Fingerprints:applyFpUpsert("a", entryA :: any, nil)
			Fingerprints:applyFpUpsert("b", entryB :: any, nil)
			local fpB = Hash.hashInstance(entryB :: any)
			local wsXor = Fingerprints:serviceFpHex("Workspace")
			Fingerprints:applyFpRemove("a", entryA.path)
			SelfTest.assert("serviceFp remove A leaves B", Fingerprints:serviceFpHex("Workspace") == fpB, failures)
			Fingerprints:applyFpUpsert("a", entryA :: any, nil)
			SelfTest.assert("serviceFp re-add A restores XOR", Fingerprints:serviceFpHex("Workspace") == wsXor, failures)

			local body = realLive:buildTickBody("123", "edit", 2, { Workspace = string.rep("a", 64) }, {
				upserted = { { id = "x" } :: any },
				removed = { "y" },
			}, nil)
			SelfTest.assert(
				"buildTickBody shape",
				body.placeId == "123"
					and body.sessionMode == "edit"
					and body.baseRevision == 2
					and body.ops.upserted[1].id == "x"
					and body.bulkRef == nil,
				failures
			)
			-- DEVIATION: live.classifyPayload is gone; the inline/bulk boundary is now
			-- Config.TICK_INLINE_THRESHOLD (the byte size collectOpsFromDirty caps on).
			-- Re-assert the same two classification facts against that threshold.
			SelfTest.assert("payload inline below threshold", 1024 <= TICK_INLINE_THRESHOLD, failures)
			SelfTest.assert("payload bulk above threshold", 300000 > TICK_INLINE_THRESHOLD, failures)

			Fingerprints:reset()
			Fingerprints:applyFpUpsert("ws", {
				path = "Workspace",
				fp = Hash.hashInstance({
					id = "ws",
					path = "Workspace",
					name = "Workspace",
					className = "Workspace",
					depth = 0,
					siblingIndex = 0,
					childCount = 0,
					duplicateSiblingName = false,
					properties = {},
					attributes = {},
					tags = {},
				} :: any),
			}, nil)
			local fpPreOp = Fingerprints:serviceFingerprintsWire()
			Fingerprints:applyFpUpsert("p1", {
				path = "Workspace/Part[1]",
				fp = Hash.hashInstance({
					id = "p1",
					path = "Workspace/Part[1]",
					name = "Part",
					className = "Part",
					depth = 1,
					siblingIndex = 1,
					childCount = 0,
					duplicateSiblingName = false,
					properties = {},
					attributes = {},
					tags = {},
				} :: any),
			}, nil)
			local fpPostOp = Fingerprints:serviceFingerprintsWire()
			SelfTest.assert("edit tick fingerprints are post-ops", fpPreOp.Workspace ~= fpPostOp.Workspace, failures)

			-- DEVIATION: live.scheduleDriftRecovery(svc, up, rm) is gone. Drift recovery
			-- is now Live:triggerDriftRecovery — guarded (no-op off-live) and it NEVER
			-- touches the dirty sets. Re-assert the "preserves dirty" intent: mark dirty,
			-- invoke the guarded recovery (off-live -> returns false, no-op), confirm the
			-- dirty sets survive untouched.
			local ws = game:GetService("Workspace")
			realLive.dirtyUpsert[ws] = true
			realLive.dirtyRemoved.z = true
			local recoveryStarted = realLive:triggerDriftRecovery({ "Workspace" })
			SelfTest.assert("drift recovery is a no-op while off-live", recoveryStarted == false, failures)
			SelfTest.assert(
				"drift recovery preserves dirty",
				realLive.dirtyUpsert[ws] == true and realLive.dirtyRemoved.z == true,
				failures
			)
			realLive.dirtyUpsert = {}
			realLive.dirtyRemoved = {}

			-- E1 forward-progress + cap: drive the real collectOpsFromDirty with a fat
			-- (over-threshold) and a small instance among the dirty set. The fat one is
			-- depth-sorted equal, so ordering is by the pairs() walk; we assert the cap
			-- ships at most one when the fat entry would overflow, and that a SOLO fat
			-- entry still ships (forward-progress). This is the modular equivalent of the
			-- monolith's collectOpsFromEntries cap tests.
			do
				local capFolder = Instance.new("Folder")
				capFolder.Name = "StudioStudSelfTestCap"
				capFolder.Parent = game:GetService("ReplicatedStorage")

				local fatPart = Instance.new("Part")
				fatPart.Name = "Fat"
				fatPart.Parent = capFolder
				-- An attribute large enough to push the entry over TICK_INLINE_THRESHOLD.
				fatPart:SetAttribute("pad", string.rep("x", TICK_INLINE_THRESHOLD + 4096))

				local smallPart = Instance.new("Part")
				smallPart.Name = "Small"
				smallPart.Parent = capFolder

				-- Register both in the live identity maps so buildUpsertedEntry resolves them.
				local fatId = fatPart:GetDebugId(0)
				local smallId = smallPart:GetDebugId(0)
				local capId = capFolder:GetDebugId(0)
				capture.instanceIdByRef[capFolder] = capId
				capture.pathByRef[capFolder] = "ReplicatedStorage/StudioStudSelfTestCap[1]"
				capture.instanceIdByRef[fatPart] = fatId
				capture.pathByRef[fatPart] = ""
				capture.instanceIdByRef[smallPart] = smallId
				capture.pathByRef[smallPart] = ""

				-- SOLO fat: forward-progress ships it even though it exceeds the threshold.
				Fingerprints:reset()
				realLive.dirtyUpsert = {}
				realLive.dirtyRemoved = {}
				realLive.upsertStamp = {}
				realLive.removedStamp = {}
				realLive:markDirtyUpsert(fatPart)
				local soloUpserted = realLive:collectOpsFromDirty()
				SelfTest.assert(
					"solo fat op collects one entry (forward-progress)",
					#soloUpserted == 1 and soloUpserted[1].id == fatId,
					failures
				)

				-- small + fat: the cap breaks after the first committed op, so the batch
				-- never ships BOTH inline (the fat overflow is deferred to the next tick).
				Fingerprints:reset()
				realLive.dirtyUpsert = {}
				realLive.dirtyRemoved = {}
				realLive.upsertStamp = {}
				realLive.removedStamp = {}
				realLive:markDirtyUpsert(smallPart)
				realLive:markDirtyUpsert(fatPart)
				local cappedUpserted = realLive:collectOpsFromDirty()
				SelfTest.assert(
					"fat batch caps (does not ship both inline)",
					#cappedUpserted < 2,
					failures
				)

				-- Clean the live maps + DataModel.
				capture.instanceIdByRef[capFolder] = nil
				capture.pathByRef[capFolder] = nil
				capture.instanceIdByRef[fatPart] = nil
				capture.pathByRef[fatPart] = nil
				capture.instanceIdByRef[smallPart] = nil
				capture.pathByRef[smallPart] = nil
				realLive.dirtyUpsert = {}
				realLive.dirtyRemoved = {}
				realLive.upsertStamp = {}
				realLive.removedStamp = {}
				Fingerprints:reset()
				capFolder:Destroy()
			end
		end
	end

	-- == JSON safety: a snapshot must always encode, even with NaN/inf or invalid-UTF-8 (0.4.18) ==
	do
		local report: { string } = {}
		local dirty: { [string]: any } = {
			nan = 0 / 0,
			posInf = math.huge,
			negInf = -math.huge,
			ok = 1.5,
			badStr = "abc" .. string.char(0xFF, 0xFE) .. "z",
			goodStr = "héllo",
			nested = { x = 0 / 0, y = 2 },
		}
		local rawOk = pcall(function()
			return httpService:JSONEncode(dirty)
		end)
		SelfTest.assert("dirty snapshot fails raw JSONEncode", not rawOk, failures)
		Transport.sanitizeJsonValue(dirty, "root", report, nil)
		local postOk = pcall(function()
			return httpService:JSONEncode(dirty)
		end)
		SelfTest.assert("sanitized snapshot encodes", postOk, failures)
		SelfTest.assert("sanitize reported offenders", #report >= 4, failures)
		SelfTest.assert("sanitize replaced NaN with 0", dirty.nan == 0, failures)
		SelfTest.assert("sanitize kept finite number", dirty.ok == 1.5, failures)
		SelfTest.assert("sanitize kept valid multibyte string", dirty.goodStr == "héllo", failures)
	end

	if live then
		local realLive = live :: typeof(live)
		realLive:teardown()
		SelfTest.assert("live.teardown clears liveRunning", not realLive.liveRunning, failures)
		SelfTest.assert("live.teardown clears instConns", next(realLive.instConns) == nil, failures)
		SelfTest.assert("live.teardown clears rootConns", #realLive.rootConns == 0, failures)
		SelfTest.assert("live.teardown clears globalConns", #realLive.globalConns == 0, failures)
		SelfTest.assert("live.teardown resets revision", realLive.currentRevision == 0, failures)
		SelfTest.assert("live.teardown resets liveInstanceCount", realLive.liveInstanceCount == 0, failures)
		SelfTest.assert("live.teardown clears dirtyUpsert", next(realLive.dirtyUpsert) == nil, failures)
		SelfTest.assert("live.teardown clears dirtyRemoved", next(realLive.dirtyRemoved) == nil, failures)
		SelfTest.assert("live.teardown resets verifyNeeded", realLive.verifyNeeded == false, failures)

		-- Settings gate: liveCaptureEnabled = false → setupAfterBaseline is a no-op.
		Settings.setBool(SETTINGS.liveCaptureEnabled, false)
		realLive:setupAfterBaseline({ revision = 5, instances = 100 })
		SelfTest.assert("live gated by liveCaptureEnabled=false", not realLive.liveRunning, failures)
		Settings.setBool(SETTINGS.liveCaptureEnabled, true)

		-- Dirty-set precedence: removed wins over upserted for same id.
		local dummyInst = Instance.new("Folder")
		dummyInst.Parent = game:GetService("ReplicatedStorage")
		local dummyId = dummyInst:GetDebugId(0)
		realLive.dirtyUpsert[dummyInst] = true
		realLive.dirtyRemoved[dummyId] = true
		-- collectOpsFromDirty skips this inst because its id is in dirtyRemoved.
		local skipped = realLive.dirtyRemoved[dummyId] == true
		SelfTest.assert("removed wins over upserted in dirty sets", skipped, failures)
		realLive.dirtyUpsert = {}
		realLive.dirtyRemoved = {}
		dummyInst:Destroy()

		-- == C1 regression: markDirtyUpsert sets dirtyUpsert[inst] WITHOUT recursion ==
		-- The monolith's buggy markDirtyUpsert called itself (infinite recursion). The
		-- cure: it ONLY sets dirtyUpsert[inst]=true + stamps. Assert the post-condition
		-- (the inst is dirty and stamped) AND that the call returns normally (a recursive
		-- version would stack-overflow before reaching the assert).
		do
			realLive.dirtyUpsert = {}
			realLive.upsertStamp = {}
			realLive.dirtyStamp = 0
			local c1Inst = Instance.new("Folder")
			c1Inst.Parent = game:GetService("ReplicatedStorage")
			realLive:markDirtyUpsert(c1Inst)
			SelfTest.assert(
				"C1: markDirtyUpsert sets dirtyUpsert[inst] (no recursion)",
				realLive.dirtyUpsert[c1Inst] == true,
				failures
			)
			SelfTest.assert(
				"C1: markDirtyUpsert stamps the inst once",
				realLive.dirtyStamp == 1 and realLive.upsertStamp[c1Inst] == 1,
				failures
			)
			realLive.dirtyUpsert = {}
			realLive.upsertStamp = {}
			c1Inst:Destroy()
		end

		-- == C2 regression: a simulated connect passes a NON-NIL onReturnToEdit to
		-- startTickLoop ==
		-- The monolith captured a not-yet-assigned `onReturnToEdit` upvalue into
		-- startTickLoop (nil at capture time -> the play->edit resume silently died).
		-- Simulate the connect seam: build a real callback and hand it to startTickLoop,
		-- asserting the engine accepts a non-nil onReturnToEdit (and that the call itself
		-- returns normally — a nil-call would have thrown). Tear down immediately so the
		-- spawned loop exits on its next generation guard.
		do
			Settings.setBool(SETTINGS.liveCaptureEnabled, true)
			realLive.liveRunning = true -- arm the loop guard so startTickLoop spawns
			local returnSeen = false
			local onReturnToEdit = function()
				returnSeen = true
			end
			local okStart = pcall(function()
				realLive:startTickLoop({ revision = 0, instanceCount = 0 }, onReturnToEdit)
			end)
			SelfTest.assert("C2: startTickLoop accepts a non-nil onReturnToEdit", okStart, failures)
			SelfTest.assert("C2: onReturnToEdit is a function (non-nil)", type(onReturnToEdit) == "function", failures)
			-- `returnSeen` exists only so the closure is genuinely capturable (no dead
			-- upvalue); the loop fires it only on a play->edit transition, not here.
			SelfTest.assert("C2: onReturnToEdit closure is live", returnSeen == false, failures)
			realLive:teardown() -- bump generation so the spawned loop exits
		end

		-- == C3 regression: Sync() before live mode does not nil-call ==
		-- The monolith's Sync() before live nil-called a not-yet-assigned upvalue. Here
		-- the engine's host starts as a NO-OP stub (Live.host = NOOP_HOST) until attach,
		-- so a pre-live engine call routes through the stub and is a safe no-op. After
		-- teardown the engine is off-live; drive a host-touching engine path
		-- (triggerRebaseline goes straight through host.* ) and assert it does not throw.
		do
			realLive.liveRunning = false
			local okPreLive = pcall(function()
				realLive:triggerRebaseline("c3-pre-live")
			end)
			SelfTest.assert("C3: pre-live engine call is a safe no-op (no nil-call)", okPreLive, failures)
			-- And the panel handle's sync entry (the real Sync()) returns a result table
			-- rather than throwing, even with no daemon (off-live, edit session).
			if captureHandleLive then
				local okSync, syncResult = pcall(function(): any
					return captureHandleLive.sync()
				end)
				SelfTest.assert(
					"C3: Sync() before live returns a result (no nil-call)",
					okSync and type(syncResult) == "table",
					failures
				)
			end
		end

		-- == Phase 3: detection collapse ==
		do
			local curated = { Transparency = false }
			SelfTest.assert("classify Name -> name", realLive:classifyChangedProp("Name", curated) == "name", failures)
			SelfTest.assert("classify Source -> dirty", realLive:classifyChangedProp("Source", curated) == "dirty", failures)
			SelfTest.assert(
				"classify curated -> dirty",
				realLive:classifyChangedProp("Transparency", curated) == "dirty",
				failures
			)
			SelfTest.assert(
				"classify uncurated -> gap",
				realLive:classifyChangedProp("Archivable", curated) == "gap",
				failures
			)

			-- gap-probe dedup.
			realLive.propGaps = {}
			realLive:recordPropGap("Part", "Foo")
			realLive:recordPropGap("Part", "Foo")
			local gapCount = 0
			for _ in pairs(realLive.propGaps) do
				gapCount += 1
			end
			SelfTest.assert("recordPropGap dedups", gapCount == 1, failures)

			-- connection-count collapse: a Part should register ~3 connections, not ~20.
			AllowList.loaded = true
			AllowList.lists = { Part = { "Transparency", "Size" } }
			AllowList.sets = { Part = { Transparency = false, Size = false } }
			local part = Instance.new("Part")
			realLive:registerInstance(part)
			local partConns = realLive.instConns[part]
			SelfTest.assert("registerInstance collapses Part to <=4 conns", partConns ~= nil and #partConns <= 4, failures)
			realLive:unregisterInstance(part)
			part:Destroy()

			-- ValueBase registers explicit signals (Ancestry + Attribute + Name + Value).
			local iv = Instance.new("IntValue")
			realLive:registerInstance(iv)
			local ivConns = realLive.instConns[iv]
			SelfTest.assert("ValueBase registers >=3 conns", ivConns ~= nil and #ivConns >= 3, failures)
			realLive:unregisterInstance(iv)
			iv:Destroy()

			AllowList.loaded = false
			AllowList.lists = {}
			AllowList.sets = {}
		end
	else
		-- Live handle not available: skip but don't fail.
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
		SelfTest.assert("decide edit when isEdit & !isRunning", Session.decide(true, false) == "edit", failures)
		SelfTest.assert("decide play when isRunning", Session.decide(false, true) == "play", failures)
		SelfTest.assert("decide play when !isEdit", Session.decide(false, false) == "play", failures)
		SelfTest.assert("decide play when isEdit & isRunning", Session.decide(true, true) == "play", failures)
		-- SelfTest runs in a genuine edit session, so the LIVE decision must be edit:
		SelfTest.assert("Session.mode() == 'edit' while editing", Session.mode() == "edit", failures)
	end

	Settings.setBool(SETTINGS.liveCaptureEnabled, origLive)
	Settings.setNumber(SETTINGS.debounceMs, origDebounce)
	Settings.setString(SETTINGS.daemonUrl, origUrl)
	SelfTest.assert(
		"registry ids restored",
		Registry.snapshotIds()[1] == preIds[1] and #Registry.snapshotIds() == #preIds,
		failures
	)

	if #failures == 0 then
		print("[Studio Stud SelfTest] PASS — all checks passed")
		return true
	end
	warn("[Studio Stud SelfTest] FAIL — " .. tostring(#failures) .. " check(s) failed")
	return false
end

return SelfTest
end function __DARKLUA_BUNDLE_MODULES.n():typeof(__modImpl())local v=__DARKLUA_BUNDLE_MODULES.cache.n if not v then v={c=__modImpl()}__DARKLUA_BUNDLE_MODULES.cache.n=v end return v.c end end do local function __modImpl()--!strict
-- Capture — DataModel → wire serialization, ported faithfully from the monolith's
-- Capture.* block (StudioStud.plugin.lua:1623-2063) plus buildUpsertedEntry
-- (:2736-2808). This is the read half of the protocol: it turns live Studio
-- instances into the InstanceEntry wire shape the daemon stores. It must reproduce
-- the EXACT serialization the daemon (and the Hash recipe) already expect — the
-- field set, the datatype tagging, the {type="Unsupported"} default, the
-- base64-for-non-UTF-8 source rule, the Model bounding-box/pivot extras, and the
-- baseline walk's path/sibling/duplicate numbering are all the wire. None of it may
-- be "improved" or every captured tree would mismatch the old plugin.
--
-- Responsibilities (one each):
--   * serializeValue  — typeof-dispatch over every captured datatype, recursing
--       into tables, with the {type="Unsupported", reason=...} default. Reads the
--       per-walk instanceIdByRef/pathByRef maps for InstanceRef resolution.
--   * the yielding baseline walk  — collectBaseInstances/getRootEntries/buildSnapshot,
--       cooperatively yielding every Config.BASELINE_YIELD_EVERY instances
--       (shouldYield) so a large tree never stalls the Studio frame.
--   * readProperties  — optimistic batch-pcall over the curated name list, falling
--       back to a per-property pcall (readPropsFrom) so one throwing property never
--       drops the rest; plus the Model bounding-box/pivot extras.
--   * readSource  — LuaSourceContainer.Source as utf8, or base64 when the text is
--       not valid UTF-8 (sets sourceEncoding); readAttributes (all, no whitelist)
--       and readTags.
--   * getPropertyNames/curatedSet  — AllowList (per exact ClassName) first, else
--       the static Config.CLASS_PROPERTIES IsA-accumulation fallback. AllowList is
--       the single source of truth for curation; Config is only the fallback.
--   * buildUpsertedEntry  — the live per-instance entry builder: depth from path
--       slash count, sibling index/duplicate from the parent's children, fp via
--       Hash.hashInstance. Returns (entry, oldPath) so the caller (Live) can apply
--       the per-service fingerprint XOR with the correct old path. E2: an optional
--       per-flush sibling memo collapses the O(siblings) re-scan per dirty entry to
--       once per parent within a single collectOpsFromDirty pass.
--
-- STATE: instanceIdByRef/pathByRef are per-walk maps (Instance -> id / path),
-- rebuilt each collectBaseInstances and read by serializeValue (InstanceRef) and
-- buildUpsertedEntry. They live as module fields on the Capture table — every
-- method reaches them through `Capture.*`, never a forward-referenced upvalue, so
-- there is no before-local window (the C1-C3 bug class this rewrite exists to kill).
--
-- DECOUPLING: the monolith's buildUpsertedEntry also XOR'd the entry into the live
-- per-service accumulator (Live.applyFpUpsert). That belongs to the Fingerprints/
-- Live module (P4), not Capture — Capture only computes the entry and its fp and
-- hands back (entry, oldPath); the caller applies the accumulator op with the
-- returned oldPath. This keeps Capture free of any Live dependency while preserving
-- the exact (entry, oldPath) contract and the proven hash/path semantics.
--
-- M3 (by design): `source` rides the entry but is EXCLUDED from the drift hash —
-- Hash.hashInstance never reads it. buildUpsertedEntry sets fp via Hash AFTER the
-- structural fields, so a source-only edit does not change fp.


local Types = __DARKLUA_BUNDLE_MODULES.e()
local Config = __DARKLUA_BUNDLE_MODULES.a()
local AllowList = __DARKLUA_BUNDLE_MODULES.h()
local Hash = __DARKLUA_BUNDLE_MODULES.i()








local CLASS_PROPERTIES = Config.CLASS_PROPERTIES
local ROOT_SERVICE_ORDER = Config.ROOT_SERVICE_ORDER
local ROOT_SERVICE_INDEX = Config.ROOT_SERVICE_INDEX
local DESCENDANT_ROOT_SERVICES = Config.DESCENDANT_ROOT_SERVICES
local SERVICE_NAME = Config.SERVICE_NAME
local PLUGIN_VERSION = Config.PLUGIN_VERSION
local BASELINE_YIELD_EVERY = Config.BASELINE_YIELD_EVERY

-- Forward declaration of the module table so methods reach one another and the
-- per-walk maps through it (serializeValue -> Capture.instanceIdByRef;
-- collectBaseInstances -> Capture.shouldYield; buildSnapshot -> Capture.readProperties)
-- WITHOUT a forward-referenced upvalue. Capture.* is a real table field by the time
-- any method runs.

























































































































local Capture: CaptureModule__DARKLUA_TYPE_ac

-- == shouldYield ==

-- True when processedCount is a positive multiple of yieldEvery (yieldEvery > 0).
-- Verbatim: `yieldEvery > 0 and processedCount > 0 and (processedCount % yieldEvery) == 0`.
local function shouldYield(processedCount: number, yieldEvery: number): boolean
	return yieldEvery > 0 and processedCount > 0 and (processedCount % yieldEvery) == 0
end

-- == Datatype serializers ==

local function serializeVector3(value: Vector3): any
	return { type = "Vector3", x = value.X, y = value.Y, z = value.Z }
end

local function serializeCFrame(value: CFrame): any
	local components = { value:GetComponents() }
	return {
		type = "CFrame",
		position = serializeVector3(value.Position),
		matrix = components,
	}
end

local function serializeColor3(value: Color3): any
	return { type = "Color3", r = value.R, g = value.G, b = value.B }
end

-- Serialize one captured value to its wire form. typeof-dispatch matching the
-- engine's runtime type, recursing into tables (attributes/nested datatype maps).
-- Anything not handled falls to { type = "Unsupported", reason = typeof }. VERBATIM
-- port of Capture.serializeValue (monolith :1648). InstanceRef resolves id/path from
-- the per-walk maps (path falls back to GetFullName when the ref is outside the walk).
local function serializeValue(value: any): any
	local valueType = typeof(value)
	if valueType == "nil" or valueType == "boolean" or valueType == "number" or valueType == "string" then
		return value
	elseif valueType == "Vector3" then
		return serializeVector3(value)
	elseif valueType == "Vector2" then
		return { type = "Vector2", x = value.X, y = value.Y }
	elseif valueType == "CFrame" then
		return serializeCFrame(value)
	elseif valueType == "Color3" then
		return serializeColor3(value)
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
			table.insert(keypoints, { time = keypoint.Time, value = serializeColor3(keypoint.Value) })
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
			id = Capture.instanceIdByRef[value],
			path = Capture.pathByRef[value] or value:GetFullName(),
		}
	elseif valueType == "table" then
		local out: { [string]: any } = {}
		for key, item in pairs(value) do
			out[tostring(key)] = serializeValue(item)
		end
		return out
	end
	return { type = "Unsupported", reason = valueType }
end

-- == Curation (AllowList first, static fallback) ==

-- Ordered property names for an instance. Prefer the daemon AllowList (per exact
-- ClassName, includes inherited props); else accumulate the static CLASS_PROPERTIES
-- by IsA, BasePart first (so its props lead the list exactly as the monolith did).
-- VERBATIM port of Capture.getPropertyNames (monolith :1722).
local function getPropertyNames(inst: Instance): { string }
	local fromAllow = AllowList.namesFor(inst.ClassName)
	if fromAllow then
		return fromAllow
	end
	local names: { string } = {}
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

-- Membership set for the instance's class: AllowList set when loaded, else built
-- from getPropertyNames with readOnly=false (the monolith's `set[name] = false`).
-- VERBATIM port of Capture.curatedSet (monolith :1746).
local function curatedSet(inst: Instance): ClassPropSet__DARKLUA_TYPE_5
	local fromAllow = AllowList.setFor(inst.ClassName)
	if fromAllow then
		return fromAllow
	end
	local set: ClassPropSet__DARKLUA_TYPE_5 = {}
	for _, name in ipairs(getPropertyNames(inst)) do
		set[name] = false
	end
	return set
end

-- == Property reads ==

-- Per-property fallback: read each name through its own pcall so one throwing
-- property doesn't abort the rest; collect failures as errors. `inst` is `any` to
-- match the monolith's index-by-string (`fakeInst[propName]`) over a real Instance.
-- VERBATIM port of Capture.readPropsFrom (monolith :1758).
local function readPropsFrom(inst: any, names: { string }): (PropertyMap__DARKLUA_TYPE_2, { PropertyError__DARKLUA_TYPE_7 })
	local properties: PropertyMap__DARKLUA_TYPE_2 = {}
	local errors: { PropertyError__DARKLUA_TYPE_7 } = {}
	for _, propName in ipairs(names) do
		local ok, value = pcall(function()
			return inst[propName]
		end)
		if ok then
			properties[propName] = serializeValue(value)
		else
			table.insert(errors, { property = propName, error = tostring(value) })
		end
	end
	return properties, errors
end

-- Read an instance's curated properties. Optimistic: one batch pcall reads the whole
-- name list at once (the common case — no property throws); on any throw, fall back
-- to the per-property readPropsFrom so a single bad property never loses the rest.
-- Then the Model bounding-box/pivot extras (each pcall-guarded). VERBATIM port of
-- Capture.readProperties (monolith :1774).
local function readProperties(inst: Instance): (PropertyMap__DARKLUA_TYPE_2, { PropertyError__DARKLUA_TYPE_7 })
	local anyInst = inst :: any
	local names = getPropertyNames(inst)
	local properties: PropertyMap__DARKLUA_TYPE_2 = {}
	local errors: { PropertyError__DARKLUA_TYPE_7 } = {}
	local batchOk, batchProps = pcall(function()
		local props: PropertyMap__DARKLUA_TYPE_2 = {}
		for _, propName in ipairs(names) do
			props[propName] = serializeValue(anyInst[propName])
		end
		return props
	end)
	if batchOk then
		properties = batchProps
	else
		properties = {}
		properties, errors = readPropsFrom(inst, names)
	end

	if inst:IsA("Model") then
		local model = inst :: Model
		local ok, cframe, size = pcall(function()
			return model:GetBoundingBox()
		end)
		if ok then
			properties.BoundingBoxCFrame = serializeCFrame(cframe)
			properties.BoundingBoxSize = serializeVector3(size)
		end
		local pivotOk, pivot = pcall(function()
			return model:GetPivot()
		end)
		if pivotOk then
			properties.Pivot = serializeCFrame(pivot)
		end
	end
	return properties, errors
end

-- == base64 (source non-UTF-8 path) ==

local B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- Encode a raw byte string to base64. VERBATIM port (monolith :1812): the daemon
-- decodes the same standard alphabet + `=` padding, so this must not change.
local function base64encode(raw: string): string
	local out: { string } = {}
	local i = 1
	while i <= #raw do
		local b1 = string.byte(raw, i)
		local b2 = string.byte(raw, i + 1)
		local b3 = string.byte(raw, i + 2)
		local n = (b1 or 0) * 65536 + ((b2 or 0) * 256) + (b3 or 0)
		local c1 = math.floor(n / 262144) % 64 + 1
		local c2 = math.floor(n / 4096) % 64 + 1
		local c3 = math.floor(n / 64) % 64 + 1
		local c4 = n % 64 + 1
		table.insert(out, string.sub(B64_ALPHABET, c1, c1))
		table.insert(out, string.sub(B64_ALPHABET, c2, c2))
		if b2 then
			table.insert(out, string.sub(B64_ALPHABET, c3, c3))
		else
			table.insert(out, "=")
		end
		if b3 then
			table.insert(out, string.sub(B64_ALPHABET, c4, c4))
		else
			table.insert(out, "=")
		end
		i += 3
	end
	return table.concat(out)
end

-- Decode base64 back to raw bytes (round-trip helper / SelfTest). VERBATIM port
-- (monolith :1841): strips non-alphabet chars, stops on a short final group.
local function base64decode(encoded: string): string
	local map: { [string]: number } = {}
	for idx = 1, #B64_ALPHABET do
		map[string.sub(B64_ALPHABET, idx, idx)] = idx - 1
	end
	local cleaned = string.gsub(encoded or "", "[^A-Za-z0-9+/=]", "")
	local out: { string } = {}
	local i = 1
	while i <= #cleaned do
		local c1 = string.sub(cleaned, i, i)
		local c2 = string.sub(cleaned, i + 1, i + 1)
		local c3 = string.sub(cleaned, i + 2, i + 2)
		local c4 = string.sub(cleaned, i + 3, i + 3)
		if c1 == "" or c2 == "" then
			break
		end
		local n = map[c1] * 262144 + map[c2] * 4096
		if c3 ~= "=" and c3 ~= "" then
			n += map[c3] * 64
		end
		if c4 ~= "=" and c4 ~= "" then
			n += map[c4]
		end
		table.insert(out, string.char(math.floor(n / 65536) % 256))
		if c3 ~= "=" and c3 ~= "" then
			table.insert(out, string.char(math.floor(n / 256) % 256))
		end
		if c4 ~= "=" and c4 ~= "" then
			table.insert(out, string.char(n % 256))
		end
		i += 4
	end
	return table.concat(out)
end

-- == source / attributes / tags ==

-- LuaSourceContainer source: utf8 inline when valid UTF-8, else base64 (with the
-- "base64" encoding tag). (nil, nil) for non-script instances or a read failure.
-- VERBATIM port of Capture.readSource (monolith :1876).
local function readSource(inst: Instance): (string?, SourceEncoding__DARKLUA_TYPE_6?)
	if not inst:IsA("LuaSourceContainer") then
		return nil, nil
	end
	-- `.Source` is declared on the concrete script subclasses, not the abstract
	-- LuaSourceContainer base, so the defs don't expose it here. The monolith read
	-- it via a dynamic, pcall-guarded index; mirror that with an `any` cast (the
	-- pcall already hardens the read, and the IsA gate guarantees the field exists).
	local container = inst :: any
	local ok, src = pcall(function()
		return container.Source
	end)
	if ok and typeof(src) == "string" then
		if utf8.len(src) ~= nil then
			return src, "utf8"
		end
		return base64encode(src), "base64"
	end
	return nil, nil
end

-- All attributes (no whitelist), serialized through serializeValue. On a GetAttributes
-- failure returns ({}, one error). VERBATIM port of Capture.readAttributes (:1892).
local function readAttributes(inst: Instance): (AttributeMap__DARKLUA_TYPE_3, { PropertyError__DARKLUA_TYPE_7 })
	local ok, attrs = pcall(function()
		return inst:GetAttributes()
	end)
	if not ok then
		return {}, { { property = "Attributes", error = tostring(attrs) } }
	end
	return serializeValue(attrs), {}
end

-- CollectionService tags in capture order; {} on failure or non-table result.
-- VERBATIM port of Capture.readTags (monolith :1902).
local function readTags(inst: Instance): Tags__DARKLUA_TYPE_4
	local ok, tags = pcall(function()
		return inst:GetTags()
	end)
	if ok and typeof(tags) == "table" then
		return tags
	end
	return {}
end

-- == Root services / baseline walk ==

-- The ordered, de-duplicated set of captured root services. GetService is pcall'd
-- (some services don't exist in every place); each kept once; then sorted by
-- ROOT_SERVICE_INDEX (className then name), name, then className — the exact
-- tie-break chain of the monolith. VERBATIM port of Capture.getRootEntries (:1912).
local function getRootEntries(): { RootEntry__DARKLUA_TYPE_8 }
	local roots: { RootEntry__DARKLUA_TYPE_8 } = {}
	local seen: { [Instance]: boolean } = {}
	for _, serviceName in ipairs(ROOT_SERVICE_ORDER) do
		local ok, service = pcall(function()
			return game:GetService(serviceName :: any)
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

-- Walk every captured root, building the STRUCTURAL entries (id/path/parent/depth/
-- siblingIndex/childCount/duplicateSiblingName) and populating the per-walk
-- instanceIdByRef/pathByRef maps. Properties/attributes/tags/source are filled in a
-- SECOND pass (buildSnapshot) so the id/path maps are complete before any InstanceRef
-- is serialized. Yields every BASELINE_YIELD_EVERY instances. VERBATIM port of
-- Capture.collectBaseInstances (monolith :1948).
local function collectBaseInstances(): ({ any }, { string })
	local instances: { any } = {}
	local rootNames: { string } = {}
	local instanceIdByRef: { [Instance]: string } = {}
	local pathByRef: { [Instance]: string } = {}
	Capture.instanceIdByRef = instanceIdByRef
	Capture.pathByRef = pathByRef
	local processedCount = 0

	local function walk(
		inst: Instance,
		parentId: string?,
		parentPath: string,
		depth: number,
		siblingIndex: number,
		duplicate: boolean,
		includeDescendants: boolean
	)
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
			parentPath = if parentPath ~= "" then parentPath else nil,
			depth = depth,
			siblingIndex = siblingIndex,
			childCount = if includeDescendants then #children else 0,
			duplicateSiblingName = duplicate,
		}
		table.insert(instances, entry)
		processedCount += 1
		if shouldYield(processedCount, BASELINE_YIELD_EVERY) then
			task.wait()
		end

		if not includeDescendants then
			return
		end

		local siblingCounts: { [string]: number } = {}
		for _, child in ipairs(children) do
			siblingCounts[child.Name] = (siblingCounts[child.Name] or 0) + 1
		end
		local seen: { [string]: number } = {}
		for _, child in ipairs(children) do
			seen[child.Name] = (seen[child.Name] or 0) + 1
			walk(child, id, path, depth + 1, seen[child.Name], siblingCounts[child.Name] > 1, true)
		end
	end

	for _, root in ipairs(getRootEntries()) do
		table.insert(rootNames, root.name)
		walk(root.instance, nil, "", 0, 1, false, root.includeDescendants)
	end
	return instances, rootNames
end

-- Build the full baseline snapshot envelope. First the structural walk
-- (collectBaseInstances), then a SECOND yielding pass over the populated id map that
-- fills each entry's attributes/properties/source/tags/propertyErrors (now that all
-- ids/paths exist for InstanceRef resolution). VERBATIM port of Capture.buildSnapshot
-- (monolith :2009).
local function buildSnapshot(options: SnapshotOptions__DARKLUA_TYPE_aa?): Snapshot__DARKLUA_TYPE_9
	local startedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
	local instances, rootNames = collectBaseInstances()
	local idToEntry: { [string]: any } = {}
	for _, entry in ipairs(instances) do
		idToEntry[entry.id] = entry
	end

	local processedCount = 0
	for inst, id in pairs(Capture.instanceIdByRef) do
		local entry = idToEntry[id]
		if entry then
			local attributes, attrErrors = readAttributes(inst)
			local properties, propErrors = readProperties(inst)
			entry.attributes = attributes
			entry.tags = readTags(inst)
			entry.properties = properties
			entry.propertyErrors = propErrors
			local src, srcEnc = readSource(inst)
			if src ~= nil then
				entry.source = src
				entry.sourceEncoding = srcEnc or "utf8"
			end
			for _, attrError in ipairs(attrErrors) do
				table.insert(entry.propertyErrors, attrError)
			end
			processedCount += 1
			if shouldYield(processedCount, BASELINE_YIELD_EVERY) then
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
			placeKey = tostring(if game.PlaceId ~= 0 then ("Place" .. tostring(game.PlaceId)) else game.Name),
			name = game.Name,
			placeId = game.PlaceId,
			gameId = game.GameId,
		},
		sync = {
			reason = if options and options.reason then options.reason else "manual",
			requestId = if options then options.requestId else nil,
			startedAtUtc = startedAt,
			finishedAtUtc = os.date("!%Y-%m-%dT%H:%M:%SZ"),
			consistency = "single-pass",
			rootNames = rootNames,
		},
		instances = instances,
	}
end

-- == buildUpsertedEntry (live per-instance entry) ==

-- E2 helper: resolve a parent's (children, siblingCounts) once. With a memo, the
-- first dirty child of a parent populates the slot and later siblings reuse it
-- (collapsing the O(siblings) scan to once per parent per flush). Without a memo
-- (baseline/one-off), it computes fresh exactly as the monolith did. Returns nil
-- when parent:GetChildren() throws (the caller early-outs, mirroring the monolith).
local function resolveSiblings(
	parent: Instance,
	memo: SiblingMemo__DARKLUA_TYPE_ab?
): ({ Instance }?, { [string]: number }?)
	if memo then
		local cached = memo[parent]
		if cached then
			return cached.children, cached.counts
		end
	end
	local ok, children = pcall(function()
		return parent:GetChildren()
	end)
	if not ok then
		return nil, nil
	end
	local counts: { [string]: number } = {}
	for _, sib in ipairs(children) do
		counts[sib.Name] = (counts[sib.Name] or 0) + 1
	end
	if memo then
		memo[parent] = { children = children, counts = counts }
	end
	return children, counts
end

-- Build the wire entry for one live instance. Reproduces buildUpsertedEntry
-- (monolith :2736) exactly: depth = slash count of the new path, siblingIndex from
-- the parent's children scan, duplicateSiblingName from the same scan, childCount
-- from the instance's own children, fp via Hash.hashInstance over the structural
-- fields (source set but EXCLUDED from the hash, M3). Sets pathByRef[inst] to the
-- new path and returns (entry, oldPath) — oldPath being the path BEFORE this build —
-- so the caller can XOR the old fingerprint out of the correct old service.
--
-- Returns (nil, nil) on any of the monolith's early-outs: no id in the walk map, no
-- parent, parent GetChildren throws, or the instance not found among its siblings
-- (siblingIndex stays 0 — likely mid-destroy).
local function buildUpsertedEntry(inst: Instance, memo: SiblingMemo__DARKLUA_TYPE_ab?): (InstanceEntry__DARKLUA_TYPE_1?, string?)
	local id = Capture.instanceIdByRef[inst]
	if not id then
		return nil, nil
	end
	local parent = inst.Parent
	if not parent then
		return nil, nil
	end
	local parentId = Capture.instanceIdByRef[parent]
	local parentPath = Capture.pathByRef[parent] or ""
	local children, siblingCounts = resolveSiblings(parent, memo)
	if not children or not siblingCounts then
		return nil, nil
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
		return nil, nil -- not found in parent (likely destroying)
	end
	local segment = inst.Name .. "[" .. siblingIndex .. "]"
	local path = if parentPath == "" then segment else (parentPath .. "/" .. segment)
	local oldPath = Capture.pathByRef[inst]
	Capture.pathByRef[inst] = path
	local _, slashCount = string.gsub(path, "/", "")
	local ownOk, ownChildren = pcall(function()
		return inst:GetChildren()
	end)
	local childCount = if ownOk then #ownChildren else 0
	local properties = readProperties(inst)
	local attributes = readAttributes(inst)
	local tags = readTags(inst)
	local src, srcEnc = readSource(inst)
	local entry: InstanceEntry__DARKLUA_TYPE_1 = {
		id = id,
		parentId = parentId,
		path = path,
		displayPath = inst:GetFullName(),
		name = inst.Name,
		className = inst.ClassName,
		depth = slashCount,
		siblingIndex = siblingIndex,
		childCount = childCount,
		duplicateSiblingName = duplicate,
		properties = properties,
		attributes = attributes,
		tags = tags,
		fp = "",
	}
	if src ~= nil then
		entry.source = src
		-- srcEnc is SourceEncoding? and is non-nil exactly when src is (readSource
		-- returns them paired); default to "utf8" like the monolith. The cast pins the
		-- literal union the analyzer would otherwise widen to `string` through the
		-- narrowing branch.
		entry.sourceEncoding = (if srcEnc then srcEnc else "utf8") :: SourceEncoding__DARKLUA_TYPE_6
	end
	entry.fp = Hash.hashInstance(entry)
	return entry, oldPath
end

-- == Module table ==

-- Assembled as a real value before return; every cross-reference above goes through
-- Capture.* (a real table field by the time any method runs), so there is no
-- forward-reference-before-local read anywhere in the module.
Capture = {
	instanceIdByRef = {},
	pathByRef = {},

	shouldYield = shouldYield,

	serializeVector3 = serializeVector3,
	serializeCFrame = serializeCFrame,
	serializeColor3 = serializeColor3,
	serializeValue = serializeValue,

	getPropertyNames = getPropertyNames,
	curatedSet = curatedSet,

	readPropsFrom = readPropsFrom,
	readProperties = readProperties,

	base64encode = base64encode,
	base64decode = base64decode,

	readSource = readSource,
	readAttributes = readAttributes,
	readTags = readTags,

	getRootEntries = getRootEntries,
	collectBaseInstances = collectBaseInstances,
	buildSnapshot = buildSnapshot,

	buildUpsertedEntry = buildUpsertedEntry,
}

return Capture
end function __DARKLUA_BUNDLE_MODULES.o():typeof(__modImpl())local v=__DARKLUA_BUNDLE_MODULES.cache.o if not v then v={c=__modImpl()}__DARKLUA_BUNDLE_MODULES.cache.o=v end return v.c end end do local function __modImpl()--!strict
-- Live — the live capture engine, ported faithfully from the monolith's Live.*
-- block (StudioStud.plugin.lua:2168-3346), MINUS the Hash / Capture / Fingerprints
-- code already extracted into their own modules. This is the heart of protocol v2:
-- a single fixed-interval tick loop that ships dirty deltas (ops.upserted/removed)
-- to /studio-stud/tick, spills oversized payloads to /tick/bulk, recovers from
-- drift with a full rebaseline, and gates all traffic to genuine edit sessions.
--
-- ARCHITECTURE (the C1-C3 cure): the monolith held Live as a giant table inside an
-- 1,800-line build closure, alongside the UI, the orchestrator, and forward-declared
-- locals (`syncFn`, `startupConnectAndCapture`, `pausedBaseline`, `onReturnToEdit`,
-- `responseNeedsRebaseline`) that were referenced before assignment — the exact
-- before-local window that produced C1 (markDirtyUpsert self-call), C2 (a nil
-- onReturnToEdit captured into startTickLoop), and C3 (Sync() before live nil-calls).
-- Here Live is an explicit module table with typed fields and methods; every method
-- reaches state and siblings through `self`/module references, never a forward upvalue.
-- The orchestrator/UI seam the monolith reached through closure upvalues (`ctx`,
-- `running`, `sessionHasBaseline`, `startupConnectAndCapture`)
-- is now an INJECTED, typed `LiveHost` the bootstrap hands in via `Live.attach(host)`;
-- the engine calls back through it instead of capturing a closure. Until attached,
-- the host is a no-op stub, so a pre-live call (the C3 path) is a safe no-op, not a
-- nil-call.
--
-- SHARED IDENTITY MAPS: the monolith's `instanceIdByRef`/`pathByRef` (Instance -> id
-- / path) were build-closure locals shared by Capture and Live. In the modular split
-- Capture OWNS them (Capture.instanceIdByRef / Capture.pathByRef, rebuilt each walk);
-- Live reads/writes the SAME tables through Capture.* so id/path resolution stays
-- consistent across both — single source of truth, no parallel map.
--
-- FINGERPRINTS: the per-service XOR accumulator (instFp / serviceFpBytes /
-- applyFpUpsert / applyFpRemove / reset / serviceFingerprintsWire) lives in the
-- Fingerprints module; Live drives it. The hash recipe itself is Hash (the single
-- source of truth). serviceFingerprints are computed AFTER collectOpsFromDirty (the
-- Phase-5 post-ops fix): the accumulator is mutated as each op is built, so the wire
-- map must be snapshotted after the op loop, never before.
--
-- NON-NEGOTIABLE behaviors preserved verbatim (regression if changed):
--   * dirty sets + monotonic stamps; clearSentDirty stamp-based no-data-loss.
--   * registerInstance: ONE inst.Changed connection + classifyChangedProp (~= nil
--     membership; Name->name, Source->dirty); ValueBase explicit Name+Value;
--     AncestryChanged / AttributeChanged; root DescendantAdded / DescendantRemoving.
--   * markDirtyUpsert sets dirtyUpsert[inst]=true (NO recursion — the C1 cure).
--   * collectOpsFromDirty: depth-sorted, capped at TICK_INLINE_THRESHOLD with
--     forward-progress (a solo over-threshold op still ships); E1 incremental byte
--     sizing (encode each entry once, running sum, no per-op trial copy).
--   * runTick: serviceFingerprints AFTER collectOpsFromDirty; bulkRef commit;
--     drift -> triggerFullBaseline; no_baseline -> baseline; 4-error teardown.
--   * startTickLoop: ONE fixed-interval loop; play=keepalive + teardown; play->edit
--     resume via onReturnToEdit; generation-guarded.
--   * triggerFullBaseline: yielding fp loop in buildBaselineSnapshot (the Q1 fix).
--   * historyDirty -> rebaseline; teardown resets all; connect/baseline full bulk.


local Types = __DARKLUA_BUNDLE_MODULES.e()
local Config = __DARKLUA_BUNDLE_MODULES.a()
local Session = __DARKLUA_BUNDLE_MODULES.f()
local Settings = __DARKLUA_BUNDLE_MODULES.b()
local Transport = __DARKLUA_BUNDLE_MODULES.g()
local Capture = __DARKLUA_BUNDLE_MODULES.o()
local Fingerprints = __DARKLUA_BUNDLE_MODULES.j()
local Hash = __DARKLUA_BUNDLE_MODULES.i()






local PLUGIN_VERSION = Config.PLUGIN_VERSION
local PROTOCOL_VERSION = Config.PROTOCOL_VERSION
local TICK_INLINE_THRESHOLD = Config.TICK_INLINE_THRESHOLD
local BASELINE_YIELD_EVERY = Config.BASELINE_YIELD_EVERY
local DEFAULT_BULK_CHUNK_BYTES = Config.DEFAULT_BULK_CHUNK_BYTES
local SETTINGS = Config.SETTINGS

-- == Engine handles ==

-- HttpService (for UrlEncode) and `game` are Studio globals typed via
-- globalTypes.d.luau. Resolve-and-cache HttpService on first use (cache-at-event);
-- `game` is a global the analyzer already types.
local httpService: HttpService? = nil
local function getHttpService(): HttpService
	local cached = httpService
	if cached then
		return cached
	end
	local resolved = game:GetService("HttpService") :: HttpService
	httpService = resolved
	return resolved
end

-- Forward declaration of the module table so methods reach state and one another
-- through it (Live.markDirtyUpsert, Live.host, ...) WITHOUT a forward-referenced
-- upvalue. Live.* is a real table field by the time any method runs.





























































































































local Live: LiveModule__DARKLUA_TYPE_ai

-- == No-op host stub (the C3 cure) ==

-- Before attach(), every host call is a safe no-op. The monolith's Sync()-before-live
-- nil-called a not-yet-assigned upvalue; here a pre-live call routes through this stub
-- and does nothing. requestJson/requestBody return a failure shape so any stray pre-
-- attach network call fails gracefully instead of throwing.
local NOOP_HOST: LiveHost__DARKLUA_TYPE_ah = {
	transport = {
		requestJson = function(_method: string, _path: string, _body: any?, _timeout: number?): (boolean, any)
			return false, { error = "live host not attached" }
		end,
		requestBody = function(_path: string, _body: string): (boolean, any)
			return false, { error = "live host not attached" }
		end,
	},
	setStatus = function(_kind: string, _message: string) end,
	setStats = function(_text: string) end,
	setConnected = function(_connected: boolean) end,
	isConnected = function(): boolean
		return false
	end,
	setBaseline = function(_hasBaseline: boolean) end,
	reconnect = function() end,
	isRunning = function(): boolean
		return true
	end,
}

local function attach(self: LiveModule__DARKLUA_TYPE_ai, host: LiveHost__DARKLUA_TYPE_ah): ()
	self.host = host
end

-- == debugLog passthrough ==

-- The monolith logged through a closure `debugLog`; Settings.debugLog is the same
-- gate (warns iff the debugLogging setting is true). Single source of truth.
local debugLog = Settings.debugLog

-- == Dirty marking (lazy; handlers set dirty only) ==

-- VERBATIM port of Live.markDirtyUpsert (monolith :2353). Sets dirtyUpsert[inst]=true
-- and stamps it — NO recursion, NO read (the C1 cure: the buggy version called itself).
local function markDirtyUpsert(self: LiveModule__DARKLUA_TYPE_ai, inst: Instance): ()
	self.dirtyUpsert[inst] = true
	self.dirtyStamp += 1
	self.upsertStamp[inst] = self.dirtyStamp
end

-- VERBATIM port of Live.markDirtyRemoved (monolith :2359).
local function markDirtyRemoved(self: LiveModule__DARKLUA_TYPE_ai, id: string): ()
	self.dirtyRemoved[id] = true
	self.dirtyStamp += 1
	self.removedStamp[id] = self.dirtyStamp
end

-- BFS dirty-mark: root + all captured descendants (path cascade on rename/reparent).
-- VERBATIM port of Live.markSubtreeUpsert (monolith :2486). Only instances present in
-- the walk map are marked; GetChildren is pcall-guarded so a destroying node is skipped.
local function markSubtreeUpsert(self: LiveModule__DARKLUA_TYPE_ai, root: Instance): ()
	local idByRef = Capture.instanceIdByRef
	local queue: { Instance } = { root }
	local qi = 1
	while qi <= #queue do
		local inst = queue[qi]
		qi += 1
		if idByRef[inst] then
			self:markDirtyUpsert(inst)
		end
		local ok, children = pcall(function()
			return inst:GetChildren()
		end)
		if ok then
			for _, child in ipairs(children) do
				queue[#queue + 1] = child
			end
		end
	end
end

-- Dirty parent + all same-name siblings under parent (siblingIndex/duplicate changed).
-- VERBATIM port of Live.markSiblingsDirty (monolith :2507).
local function markSiblingsDirty(self: LiveModule__DARKLUA_TYPE_ai, parent: Instance?, name: string): ()
	if not parent then
		return
	end
	local realParent = parent :: Instance
	local idByRef = Capture.instanceIdByRef
	if idByRef[realParent] then
		self:markDirtyUpsert(realParent)
	end
	local ok, children = pcall(function()
		return realParent:GetChildren()
	end)
	if not ok then
		return
	end
	for _, sib in ipairs(children) do
		if sib.Name == name and idByRef[sib] then
			self:markDirtyUpsert(sib)
		end
	end
end

-- == Property classification (pure; O(1)) ==

-- VERBATIM port of Live.classifyChangedProp (monolith :2531). curatedSet maps
-- propName -> readOnly(boolean); a WRITABLE curated prop is `false`, so membership
-- MUST be tested with `~= nil`, not truthiness (the Phase-3 fix — else writable props
-- are missed). Source is PluginSecurity-only (excluded from the allow-list) — special-
-- cased to "dirty" so live source edits ship. Returns "name" | "dirty" | "gap".
local function classifyChangedProp(_self: LiveModule__DARKLUA_TYPE_ai, prop: string, curatedSet: { [string]: boolean }): string
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

-- Uncurated properties that fired, deduped, for later reporting (Phase 5). VERBATIM
-- port of Live.recordPropGap (monolith :2545).
local function recordPropGap(self: LiveModule__DARKLUA_TYPE_ai, className: string?, prop: any): ()
	local key = (className or "?") .. "/" .. tostring(prop)
	if not self.propGaps[key] then
		self.propGaps[key] = true
		debugLog("allowlist gap:", key)
	end
end

-- Shared name-change cascade (was the body of the old Name signal). VERBATIM port of
-- Live.onNameChanged (monolith :2554): dirty the subtree (path cascade), then dirty
-- same-name siblings under both the old and new parent for siblingIndex/duplicate.
local function onNameChanged(self: LiveModule__DARKLUA_TYPE_ai, inst: Instance): ()
	local pathByRef = Capture.pathByRef
	local oldPath = pathByRef[inst] or ""
	local oldName = oldPath:match("([^%[/]+)%[%d+%]$") or inst.Name
	self:markSubtreeUpsert(inst)
	local parent = self.parentByInst[inst] or inst.Parent
	self:markSiblingsDirty(parent, oldName)
	self:markSiblingsDirty(parent, inst.Name)
end

-- == Per-instance signal wiring ==

-- Connect per-instance signals for one instance. VERBATIM port of Live.registerInstance
-- (monolith :2564): AncestryChanged (intra-root reparent), AttributeChanged, then
-- EITHER ValueBase explicit Name+Value signals (ValueBase fires .Changed with the
-- VALUE, not a prop name) OR ONE inst.Changed connection routed through
-- classifyChangedProp. Every Connect is pcall-guarded (some signals throw on exotic
-- instances) and only kept on success.
local function registerInstance(self: LiveModule__DARKLUA_TYPE_ai, inst: Instance): ()
	if self.instConns[inst] then
		return
	end
	local idByRef = Capture.instanceIdByRef
	local conns: { RBXScriptConnection } = {}

	-- AncestryChanged: intra-root reparent (fires on the moved node AND each dragged
	-- descendant). Mark the inst dirty; if it is the changed child whose parent moved,
	-- dirty same-name siblings under old and new parent and update parentByInst.
	local okA, cA = pcall(function()
		return inst.AncestryChanged:Connect(function(changedChild: Instance, newParent: Instance?)
			if idByRef[inst] then
				self:markDirtyUpsert(inst)
			end
			if changedChild == inst then
				local oldParent = self.parentByInst[inst]
				if oldParent ~= newParent then
					self:markSiblingsDirty(oldParent, inst.Name)
					self:markSiblingsDirty(newParent, inst.Name)
				end
				self.parentByInst[inst] = newParent
			end
		end)
	end)
	if okA then
		conns[#conns + 1] = cA
	end

	-- AttributeChanged.
	local okAt, cAt = pcall(function()
		return inst.AttributeChanged:Connect(function()
			if idByRef[inst] then
				self:markDirtyUpsert(inst)
			end
		end)
	end)
	if okAt then
		conns[#conns + 1] = cAt
	end

	if inst:IsA("ValueBase") then
		-- ValueBase fires .Changed with the VALUE, not the property name → explicit
		-- per-property signals for Name and Value. The defs only declare `Value` on the
		-- concrete ValueBase subclasses (IntValue/StringValue/…), not the abstract
		-- ValueBase the IsA narrowed to, so GetPropertyChangedSignal("Value") would
		-- otherwise flag an unknown key. The IsA gate guarantees the property exists and
		-- the pcall already hardens the call; index the signal off an `any` handle
		-- (mirrors Capture's dynamic `.Source` read on LuaSourceContainer).
		local valueInst = inst :: any
		local okN, cN = pcall(function()
			return inst:GetPropertyChangedSignal("Name"):Connect(function()
				self:onNameChanged(inst)
			end)
		end)
		if okN then
			conns[#conns + 1] = cN
		end
		local okV, cV = pcall(function()
			return valueInst:GetPropertyChangedSignal("Value"):Connect(function()
				if idByRef[inst] then
					self:markDirtyUpsert(inst)
				end
			end)
		end)
		if okV then
			conns[#conns + 1] = cV
		end
	else
		-- ONE Changed connection replaces ~N per-property signals + the Name signal.
		-- curatedSet is cached at registration time (cache-at-event) so the hot signal
		-- handler does only an O(1) table lookup via classifyChangedProp.
		local curated = Capture.curatedSet(inst)
		local okC, cC = pcall(function()
			return inst.Changed:Connect(function(prop: string)
				local kind = self:classifyChangedProp(prop, curated)
				if kind == "name" then
					self:onNameChanged(inst)
				elseif kind == "dirty" then
					if idByRef[inst] then
						self:markDirtyUpsert(inst)
					end
				else
					self:recordPropGap(inst.ClassName, prop)
				end
			end)
		end)
		if okC then
			conns[#conns + 1] = cC
		end
	end

	self.instConns[inst] = conns
end

-- Disconnect all per-instance signals for one instance (table not mutated during
-- iteration). VERBATIM port of Live.unregisterInstance (monolith :2648).
local function unregisterInstance(self: LiveModule__DARKLUA_TYPE_ai, inst: Instance): ()
	local conns = self.instConns[inst]
	if conns then
		for _, conn in ipairs(conns) do
			pcall(function()
				conn:Disconnect()
			end)
		end
		self.instConns[inst] = nil
	end
	self.parentByInst[inst] = nil
end

-- Unregister an inst + its entire subtree: queue ids in dirtyRemoved, XOR their
-- fingerprints out, disconnect, clear maps. VERBATIM port of Live.unregisterSubtree
-- (monolith :2662). Disconnects inline (NOT via unregisterInstance) to avoid mutating
-- instConns during the outer BFS.
local function unregisterSubtree(self: LiveModule__DARKLUA_TYPE_ai, root: Instance): ()
	local idByRef = Capture.instanceIdByRef
	local pathByRef = Capture.pathByRef
	local queue: { Instance } = { root }
	local qi = 1
	while qi <= #queue do
		local inst = queue[qi]
		qi += 1
		local id = idByRef[inst]
		if id then
			self:markDirtyRemoved(id)
			Fingerprints:applyFpRemove(id, pathByRef[inst])
		end
		local conns = self.instConns[inst]
		if conns then
			for _, conn in ipairs(conns) do
				pcall(function()
					conn:Disconnect()
				end)
			end
			self.instConns[inst] = nil
		end
		self.parentByInst[inst] = nil
		idByRef[inst] = nil
		pathByRef[inst] = nil
		local ok, children = pcall(function()
			return inst:GetChildren()
		end)
		if ok then
			for _, child in ipairs(children) do
				queue[#queue + 1] = child
			end
		end
	end
end

-- Root DescendantAdded handler. VERBATIM port of Live.onDescendantAdded (monolith
-- :2697): off-live, warn and bail; else assign a debug id (best-effort), record the
-- parent, register signals, mark dirty, and dirty same-name siblings.
local function onDescendantAdded(self: LiveModule__DARKLUA_TYPE_ai, child: Instance): ()
	if not self.liveRunning then
		warn("[StudioStud] +added (live off — click Capture/Query first):", child:GetFullName())
		return
	end
	local idByRef = Capture.instanceIdByRef
	local pathByRef = Capture.pathByRef
	if not idByRef[child] then
		local ok, id = pcall(function()
			return child:GetDebugId(0)
		end)
		local resolved: string? = nil
		if ok and id ~= "" then
			resolved = id
		end
		if resolved then
			idByRef[child] = resolved
			pathByRef[child] = ""
			debugLog("+added:", child:GetFullName(), resolved)
		else
			debugLog("+added (no debugId):", child:GetFullName())
		end
	end
	self.parentByInst[child] = child.Parent
	self:registerInstance(child)
	if idByRef[child] then
		self:markDirtyUpsert(child)
	end
	self:markSiblingsDirty(child.Parent, child.Name)
end

-- Root DescendantRemoving handler. VERBATIM port of Live.onDescendantRemoving
-- (monolith :2720): off-live, warn and bail; else unregister the subtree, ensure the
-- removed node loses any pending upsert (removed wins), and dirty siblings.
local function onDescendantRemoving(self: LiveModule__DARKLUA_TYPE_ai, child: Instance): ()
	if not self.liveRunning then
		warn("[StudioStud] -removing (live off, skipped):", child:GetFullName())
		return
	end
	local id = Capture.instanceIdByRef[child]
	debugLog("-removing:", child:GetFullName(), "id=", tostring(id))
	local parent = self.parentByInst[child] or child.Parent
	self:unregisterSubtree(child)
	-- removed wins: clear from upsert.
	self.dirtyUpsert[child] = nil
	self:markSiblingsDirty(parent, child.Name)
	debugLog("-removing queued in dirtyRemoved:", next(self.dirtyRemoved) ~= nil)
end

-- == Op collection (E1 incremental sizing + cap + forward-progress) ==

-- E1: encode each entry ONCE and keep a running byte sum, instead of the monolith's
-- per-op O(K^2) trial-copy + full re-encode. The monolith's cap logic was: build a
-- trialUpserted = current ++ entry, re-encode the WHOLE body, and break if it exceeded
-- the threshold AND at least one op was already committed (forward-progress: a solo
-- over-threshold op still ships). We reproduce the SAME decision with the same wire
-- semantics — the deciding quantity is the byte length of the encoded tick body — but
-- compute it incrementally.
--
-- Byte accounting: the wire body is buildTickBody(...) JSON-encoded. Its size is the
-- fixed envelope (placeId/sessionMode/baseRevision/serviceFingerprints/bulkRef + the
-- ops wrapper) plus the JSON of each entry plus inter-entry commas. The monolith's
-- threshold test compared the FULL encoded body to TICK_INLINE_THRESHOLD; we keep that
-- exact comparison by measuring the full body once with zero ops (the envelope) and
-- adding each entry's own encoded length + the comma that joins it. This yields a byte
-- count that tracks the real encoded size, and the break condition (over threshold AND
-- committedCount > 0) is identical to the monolith's shouldBreakOpsCap.

-- Encoded byte length of one entry, via safeEncode (the same encoder the wire uses).
-- A non-encodable entry returns math.huge so it is treated as oversized (forward-
-- progress still ships it solo, exactly as a huge tickPayloadByteLen would have).
local function entryByteLen(entry: InstanceEntry__DARKLUA_TYPE_ad): number
	local ok, encoded = Transport.safeEncode(entry, "tick-entry")
	if ok then
		return #encoded
	end
	return math.huge
end

-- The fixed tick-body envelope size (zero ops): everything except the upserted/removed
-- arrays' contents. Measured once per flush, matching the monolith's full-body probe
-- but without re-encoding per op.
local function envelopeByteLen(self: LiveModule__DARKLUA_TYPE_ai, removed: { string }): number
	local body = self:buildTickBody(
		game.PlaceId,
		"edit",
		self.currentRevision,
		Fingerprints:serviceFingerprintsWire(),
		{ upserted = {}, removed = removed },
		nil
	)
	local ok, encoded = Transport.safeEncode(body, "tick-probe")
	if ok then
		return #encoded
	end
	return math.huge
end

-- VERBATIM behavior port of Live.collectOpsFromDirty (monolith :2810). Builds the
-- removed list from dirtyRemoved, then the upsert list from dirtyUpsert (skipping ids
-- already removed), depth-sorts ascending (parents before children — path/parent
-- ordering), and builds each entry, XOR-ing its fingerprint into the accumulator. The
-- E1 incremental cap (committedBytes + this entry's bytes > threshold AND at least one
-- committed) breaks with forward-progress, rolling the just-applied fingerprint back
-- (and restoring the previous fp) exactly as the monolith did. Returns the ops plus
-- the per-op stamps so clearSentDirty can do its no-data-loss clear.
local function collectOpsFromDirty(self: LiveModule__DARKLUA_TYPE_ai): (
	{ InstanceEntry__DARKLUA_TYPE_ad },
	{ string },
	{ [Instance]: number },
	{ [string]: number }
)
	local idByRef = Capture.instanceIdByRef
	local sentUpsertStamps: { [Instance]: number } = {}
	local sentRemovedStamps: { [string]: number } = {}
	local removed: { string } = {}
	for id in pairs(self.dirtyRemoved) do
		removed[#removed + 1] = id
		sentRemovedStamps[id] = self.removedStamp[id]
	end
	


local upsertList: { WorkItem__DARKLUA_TYPE_aj } = {}
	for inst in pairs(self.dirtyUpsert) do
		local id = idByRef[inst]
		if id and not self.dirtyRemoved[id] then
			local depth = 0
			local p = inst.Parent
			while p and p ~= game do
				depth += 1
				p = p.Parent
			end
			upsertList[#upsertList + 1] = { inst = inst, depth = depth }
		end
	end
	table.sort(upsertList, function(a: WorkItem__DARKLUA_TYPE_aj, b: WorkItem__DARKLUA_TYPE_aj): boolean
		return a.depth < b.depth
	end)

	-- E1: measure the envelope once, then add each entry's encoded length + comma.
	local committedBytes = envelopeByteLen(self, removed)
	local upserted: { InstanceEntry__DARKLUA_TYPE_ad } = {}

	for _, item in ipairs(upsertList) do
		local inst = item.inst
		if inst.Parent ~= nil then
			local entry, oldPath = Capture.buildUpsertedEntry(inst)
			if entry then
				local realEntry = entry :: InstanceEntry__DARKLUA_TYPE_ad
				local prevFp = Fingerprints.instFp[realEntry.id]
				Fingerprints:applyFpUpsert(realEntry.id, realEntry, oldPath)

				-- Incremental size: this entry's own JSON + the comma that joins it to
				-- the array (1 byte; absorbs the array-bracket fixed cost into the
				-- envelope's empty `[]`, which the comma replacement covers). The break
				-- test mirrors shouldBreakOpsCap: over threshold AND already committed.
				local addedBytes = entryByteLen(realEntry) + 1
				local trialBytes = committedBytes + addedBytes
				if trialBytes > TICK_INLINE_THRESHOLD and #upserted > 0 then
					-- Roll back the fingerprint op for the entry we are NOT shipping,
					-- restoring the previous fp if there was one (verbatim monolith).
					Fingerprints:applyFpRemove(realEntry.id, realEntry.path)
					if prevFp then
						Fingerprints:applyFpUpsert(
							realEntry.id,
							{ fp = prevFp, path = oldPath or realEntry.path },
							oldPath
						)
					end
					break
				end
				committedBytes = trialBytes
				upserted[#upserted + 1] = realEntry
				sentUpsertStamps[inst] = self.upsertStamp[inst]
			else
				-- buildUpsertedEntry early-out (no parent / not found / mid-destroy):
				-- treat as removed if we still have an id.
				local id = idByRef[inst]
				if id then
					removed[#removed + 1] = id
					sentRemovedStamps[id] = self.removedStamp[id]
				end
			end
		else
			local id = idByRef[inst]
			if id then
				removed[#removed + 1] = id
				sentRemovedStamps[id] = self.removedStamp[id]
			end
		end
	end

	return upserted, removed, sentUpsertStamps, sentRemovedStamps
end

-- Stamp-based clear (the no-data-loss invariant). VERBATIM port of Live.clearSentDirty
-- (monolith :2878): only clear a dirty entry if its CURRENT stamp equals the stamp at
-- send time — an edit that re-marked it mid-tick bumped the stamp, so it stays dirty
-- and is re-sent next tick.
local function clearSentDirty(
	self: LiveModule__DARKLUA_TYPE_ai,
	sentUpsertStamps: { [Instance]: number },
	sentRemovedStamps: { [string]: number }
): ()
	for inst, stamp in pairs(sentUpsertStamps) do
		if self.upsertStamp[inst] == stamp then
			self.dirtyUpsert[inst] = nil
			self.upsertStamp[inst] = nil
		end
	end
	for id, stamp in pairs(sentRemovedStamps) do
		if self.removedStamp[id] == stamp then
			self.dirtyRemoved[id] = nil
			self.removedStamp[id] = nil
		end
	end
end

-- == Tick body + query ==

-- VERBATIM port of Live.tickQuerySuffix (monolith :2372): placeId, URL-encoded.
local function tickQuerySuffix(_self: LiveModule__DARKLUA_TYPE_ai): string
	return "placeId=" .. getHttpService():UrlEncode(tostring(game.PlaceId))
end

-- VERBATIM port of Live.buildTickBody (monolith :2376). The protocol-v2 tick body.
-- placeId is stringified (the daemon expects a string placeId on the wire).
local function buildTickBody(
	_self: LiveModule__DARKLUA_TYPE_ai,
	placeId: any,
	sessionMode: SessionMode__DARKLUA_TYPE_af,
	baseRevision: number,
	serviceFingerprints: { [string]: Hex64__DARKLUA_TYPE_ag },
	ops: Ops__DARKLUA_TYPE_ae,
	bulkRef: string?
): any
	return {
		placeId = tostring(placeId),
		sessionMode = sessionMode,
		baseRevision = baseRevision,
		serviceFingerprints = serviceFingerprints,
		ops = ops,
		bulkRef = bulkRef,
	}
end

-- == Baseline + bulk upload ==

-- Rebuild the per-service accumulators from the current walk maps WITHOUT producing a
-- snapshot. VERBATIM port of Live.initFingerprintsFromWalk (monolith :2955): reset,
-- then buildUpsertedEntry each live instance (which sets pathByRef + fp), XOR-ing into
-- the accumulator via the FP module, yielding every BASELINE_YIELD_EVERY.
local function initFingerprintsFromWalk(_self: LiveModule__DARKLUA_TYPE_ai): ()
	Fingerprints:reset()
	local processed = 0
	for inst in pairs(Capture.instanceIdByRef) do
		if inst.Parent ~= nil then
			local entry, oldPath = Capture.buildUpsertedEntry(inst)
			if entry then
				local realEntry = entry :: InstanceEntry__DARKLUA_TYPE_ad
				Fingerprints:applyFpUpsert(realEntry.id, realEntry, oldPath)
			end
			processed += 1
			if Capture.shouldYield(processed, BASELINE_YIELD_EVERY) then
				task.wait()
			end
		end
	end
end

-- Build a full baseline snapshot AND rebuild the accumulators from it. VERBATIM port
-- of Live.buildBaselineSnapshot (monolith :2969): reset, build the snapshot, then a
-- YIELDING loop (the Q1 fix — never stall the frame) that hashes each entry and XORs
-- it into the accumulator.
local function buildBaselineSnapshot(_self: LiveModule__DARKLUA_TYPE_ai, reason: string?): any
	Fingerprints:reset()
	local snapshot = Capture.buildSnapshot({ reason = reason or "tick-baseline" })
	local processed = 0
	for _, entry in ipairs(snapshot.instances) do
		entry.fp = Hash.hashInstance(entry)
		Fingerprints:applyFpUpsert(entry.id, entry, nil)
		processed += 1
		if Capture.shouldYield(processed, BASELINE_YIELD_EVERY) then
			task.wait()
		end
	end
	return snapshot
end

-- Upload a pre-encoded baseline JSON via the chunked /tick/bulk channel. VERBATIM
-- port of Live.uploadTickBulk (monolith :2893): start -> chunk(s) -> complete, sending
-- the whole body in one chunk when it fits, else splitting by maxChunkBytes. Returns
-- (true, {syncId=...}) on success so the caller stages pendingBulkRef.
local function uploadTickBulk(self: LiveModule__DARKLUA_TYPE_ai, jsonText: string, reason: string?): (boolean, any)
	local query = self:tickQuerySuffix()
	local http = getHttpService()
	local placeKey: string
	if game.PlaceId ~= 0 then
		placeKey = "Place" .. tostring(game.PlaceId)
	else
		placeKey = game.Name
	end
	local okStart, startResult = self.host.transport.requestJson(
		"POST",
		"/studio-stud/tick/bulk/start?" .. query,
		{
			pluginVersion = PLUGIN_VERSION,
			protocolVersion = PROTOCOL_VERSION,
			place = {
				placeId = game.PlaceId,
				placeKey = placeKey,
				name = game.Name,
			},
		}
	)
	if not okStart or not startResult or not startResult.syncId then
		return false, startResult
	end
	local syncId = startResult.syncId
	local maxChunk = tonumber(startResult.maxChunkBytes) or DEFAULT_BULK_CHUNK_BYTES
	if #jsonText <= maxChunk then
		local okBody = self.host.transport.requestBody(
			"/studio-stud/tick/bulk/chunk?" .. query .. "&syncId=" .. http:UrlEncode(syncId) .. "&index=0",
			jsonText
		)
		if not okBody then
			return false, { error = "bulk chunk failed" }
		end
	else
		local chunkCount = math.ceil(#jsonText / maxChunk)
		for index = 1, chunkCount do
			local startByte = ((index - 1) * maxChunk) + 1
			local chunk = string.sub(jsonText, startByte, startByte + maxChunk - 1)
			local okChunk = self.host.transport.requestBody(
				("/studio-stud/tick/bulk/chunk?%s&syncId=%s&index=%d"):format(
					query,
					http:UrlEncode(syncId),
					index - 1
				),
				chunk
			)
			if not okChunk then
				return false, { error = "bulk chunk failed", index = index }
			end
		end
	end
	local expectedChunks: number? = nil
	if #jsonText > maxChunk then
		expectedChunks = math.ceil(#jsonText / maxChunk)
	end
	local okComplete, completeResult = self.host.transport.requestJson(
		"POST",
		"/studio-stud/tick/bulk/complete?" .. query,
		{ syncId = syncId, expectedChunks = expectedChunks }
	)
	if not okComplete or not completeResult or completeResult.ok ~= true then
		return false, completeResult
	end
	debugLog("tick bulk staged:", reason or "bulk", syncId)
	return true, { syncId = syncId }
end

-- Trigger a full rebaseline spilled to /tick/bulk, committed on the next tick via
-- pendingBulkRef. VERBATIM port of Live.triggerFullBaseline (monolith :2991): guard
-- against re-entry (baselineInProgress / pendingBulkRef / not live / not edit), then
-- spawn the build+encode+upload off the caller's frame. Returns whether it started.
local function triggerFullBaseline(self: LiveModule__DARKLUA_TYPE_ai, reason: string?): boolean
	if self.baselineInProgress or self.pendingBulkRef or not self.liveRunning then
		return false
	end
	if not Session.isEdit() then
		return false
	end
	self.baselineInProgress = true
	task.spawn(function()
		local snapshot = self:buildBaselineSnapshot(reason or "tick-baseline")
		local okEnc, jsonText = Transport.safeEncode(snapshot, "tick-baseline")
		if not okEnc then
			warn("[StudioStud] baseline encode failed:", tostring(jsonText))
			self.baselineInProgress = false
			return
		end
		local okBulk, bulkResult = self:uploadTickBulk(jsonText, reason or "tick-baseline")
		if okBulk and bulkResult and bulkResult.syncId then
			self.pendingBulkRef = bulkResult.syncId
			debugLog("baseline bulk staged, awaiting tick commit")
		else
			warn("[StudioStud] baseline bulk upload failed")
		end
		self.baselineInProgress = false
	end)
	return true
end

-- VERBATIM port of Live.triggerDriftRecovery (monolith :2984): same guards, then a
-- full rebaseline (delta-only recovery — no partial materialize).
local function triggerDriftRecovery(self: LiveModule__DARKLUA_TYPE_ai, _driftServices: { string }?): boolean
	if self.baselineInProgress or self.pendingBulkRef or not self.liveRunning then
		return false
	end
	return self:triggerFullBaseline("drift-recovery")
end

-- VERBATIM port of Live.triggerRebaseline (monolith :2464): deferred teardown +
-- disconnect + full reconnect through the host (the orchestrator owns the handshake).
local function triggerRebaseline(self: LiveModule__DARKLUA_TYPE_ai, reason: string?): ()
	task.defer(function()
		if self.liveRunning then
			self:teardown()
		end
		self.host.setConnected(false)
		self.host.setBaseline(false)
		self.host.setStatus("syncing", "Re-baselining...")
		warn("[StudioStud] re-baseline:", reason or "live-rebaseline")
		self.host.reconnect()
	end)
end

-- == The tick ==

-- VERBATIM port of Live.runTick (monolith :3019). Single tick: gate on live/in-flight;
-- on an edit tick with a pending history change, schedule a rebaseline; collect ops
-- (edit-only, and only when not committing a bulkRef); snapshot serviceFingerprints
-- AFTER op collection (the post-ops fix); POST; on ok, advance revision/count, commit
-- bulkRef, clear sent dirty (stamp-based), and handle drift/no_baseline; on repeated
-- failure (>=4) tear down and surface the offline status.
local function runTick(self: LiveModule__DARKLUA_TYPE_ai, sessionMode: SessionMode__DARKLUA_TYPE_af?): ()
	if not self.liveRunning or self.syncInFlight or self.baselineInProgress then
		return
	end
	if sessionMode == "edit" and self.historyDirty then
		self.historyDirty = false
		self:triggerFullBaseline("history-change")
	end
	self.syncInFlight = true

	local mode: SessionMode__DARKLUA_TYPE_af
	if sessionMode then
		mode = sessionMode
	elseif Session.isEdit() then
		mode = "edit"
	else
		mode = "play"
	end

	local bulkRef = self.pendingBulkRef
	local upserted: { InstanceEntry__DARKLUA_TYPE_ad } = {}
	local removed: { string } = {}
	local sentUpsertStamps: { [Instance]: number } = {}
	local sentRemovedStamps: { [string]: number } = {}
	if mode == "edit" and not bulkRef then
		upserted, removed, sentUpsertStamps, sentRemovedStamps = self:collectOpsFromDirty()
	end

	-- Post-ops: snapshot fingerprints AFTER collectOpsFromDirty has XOR'd this tick's
	-- entries into the accumulators (the Phase-5 ordering fix).
	local serviceFingerprints = Fingerprints:serviceFingerprintsWire()
	local ops: Ops__DARKLUA_TYPE_ae = { upserted = upserted, removed = removed }
	local body = self:buildTickBody(game.PlaceId, mode, self.currentRevision, serviceFingerprints, ops, bulkRef)

	local okEnc, encoded = Transport.safeEncode(body, "tick")
	if not okEnc then
		warn("[StudioStud] tick encode failed:", tostring(encoded))
		self.syncInFlight = false
		return
	end

	local tickPath = "/studio-stud/tick?" .. self:tickQuerySuffix()
	local ok, result = self.host.transport.requestJson("POST", tickPath, body)
	if ok and result and result.ok then
		self.currentRevision = result.revision or self.currentRevision
		self.liveInstanceCount = result.instanceCount or self.liveInstanceCount
		self.networkErrorCount = 0
		if bulkRef then
			self.pendingBulkRef = nil
		end
		if mode == "edit" then
			self:clearSentDirty(sentUpsertStamps, sentRemovedStamps)
		end
		local drift = result.driftServices
		if type(drift) == "table" and #drift > 0 then
			debugLog("tick drift services:", table.concat(drift, ", "))
			self.recoveryServices = drift
			self:triggerDriftRecovery(drift)
		end
		if result.request then
			debugLog("tick request from daemon:", result.request)
		end
		self.host.setStatus("connected", "Live — tick sync active")
	elseif ok and result and result.error == "revision_mismatch" then
		warn("[StudioStud] tick revision_mismatch: server=", result.revision, "local=", self.currentRevision)
		if result.revision then
			self.currentRevision = result.revision
		end
	elseif ok and result and result.error == "no_baseline" then
		debugLog("tick no_baseline — scheduling full baseline")
		self:triggerFullBaseline("tick-no-baseline")
	elseif not ok or (result and result.ok == false) then
		self.networkErrorCount += 1
		local errText: any
		if result then
			errText = result.error or "no response"
		else
			errText = "no response"
		end
		warn("[StudioStud] tick error:", errText)
		if self.networkErrorCount >= 4 and not self.pendingBulkRef and not self.baselineInProgress then
			self:teardown()
			self.host.setConnected(false)
			self.host.setBaseline(false)
			self.host.setStatus("error", "Daemon offline — reconnecting automatically")
			self.host.setStats("")
		end
	end
	self.syncInFlight = false
end

-- == The fixed-interval tick loop ==

-- VERBATIM port of Live.startTickLoop (monolith :3172). ONE generation-guarded loop
-- (replacing the old 3): wait the debounce interval, re-check liveness/generation/
-- running, detect edit<->play transitions (entering play: stash revision/count, tear
-- down, idle status; returning to edit: defer onReturnToEditFn — the C2 path, now a
-- real injected function), keepalive-tick during play, and run an edit tick otherwise
-- with a pending-count stat line.
local function startTickLoop(
	self: LiveModule__DARKLUA_TYPE_ai,
	pausedBaselineRef: { revision: number, instanceCount: number }?,
	onReturnToEditFn: (() -> ())?
): ()
	self.tickGeneration += 1
	local myTickGen = self.tickGeneration
	local lastSessionMode = Session.mode()
	task.spawn(function()
		while self.liveRunning and self.tickGeneration == myTickGen and self.host.isRunning() do
			local intervalSeconds = Settings.getDebounceMs() / 1000
			task.wait(intervalSeconds)
			if not self.liveRunning or self.tickGeneration ~= myTickGen or not self.host.isRunning() then
				break
			end
			local mode = Session.mode()
			if mode ~= lastSessionMode then
				lastSessionMode = mode
				if mode == "play" then
					if pausedBaselineRef then
						pausedBaselineRef.revision = self.currentRevision
						pausedBaselineRef.instanceCount = self.liveInstanceCount
					end
					self:teardown()
					self.host.setStatus("idle", "Paused — Studio in play session")
					self.host.setStats("")
					debugLog("session: entered play — live paused")
				else
					debugLog("session: returned to edit — scheduling catch-up")
					if onReturnToEditFn then
						task.defer(onReturnToEditFn)
					end
				end
			end
			if mode ~= "edit" or not self.liveRunning then
				if mode == "play" then
					local okTick, errTick = pcall(function()
						self:runTick("play")
					end)
					if not okTick then
						warn("[StudioStud] play keepalive error:", errTick)
					end
				end
				continue
			end
			local pending = 0
			for _ in pairs(self.dirtyUpsert) do
				pending += 1
			end
			for _ in pairs(self.dirtyRemoved) do
				pending += 1
			end
			local statsText = ("rev %d · %d instances"):format(self.currentRevision, self.liveInstanceCount)
			if pending > 0 then
				statsText = statsText .. (" · %d pending"):format(pending)
			end
			self.host.setStats(statsText)
			local okTick, errTick = pcall(function()
				self:runTick("edit")
			end)
			if not okTick then
				warn("[StudioStud] runTick error:", errTick)
			end
		end
	end)
end

-- == Connect / teardown / session transitions ==

-- Bring up live mode: reset, rebuild the walk maps + accumulators, wire per-instance
-- and root signals, and connect Selection/ChangeHistory globals. VERBATIM port of
-- Live.connectLiveMode (monolith :3099). Returns false (without arming) when live
-- capture is disabled in settings.
local function connectLiveMode(self: LiveModule__DARKLUA_TYPE_ai): boolean
	if not Settings.getBool(SETTINGS.liveCaptureEnabled, true) then
		return false
	end
	self:teardown()
	self.liveRunning = true
	self.currentRevision = 0
	self.liveInstanceCount = 0
	self.pendingBulkRef = nil
	-- Capture owns the identity maps; collectBaseInstances rebuilds them fresh.
	Capture.collectBaseInstances()
	self:initFingerprintsFromWalk()
	for inst in pairs(Capture.instanceIdByRef) do
		self.parentByInst[inst] = inst.Parent
		self:registerInstance(inst)
	end
	for _, root in ipairs(Capture.getRootEntries()) do
		if root.includeDescendants then
			local rootInst = root.instance
			self.rootConns[#self.rootConns + 1] = rootInst.DescendantAdded:Connect(function(child: Instance)
				self:onDescendantAdded(child)
			end)
			self.rootConns[#self.rootConns + 1] = rootInst.DescendantRemoving:Connect(function(child: Instance)
				self:onDescendantRemoving(child)
			end)
		end
	end
	local selOk, selConn = pcall(function()
		local Selection = game:GetService("Selection")
		return Selection.SelectionChanged:Connect(function()
			local okSel, selected = pcall(function()
				return Selection:Get()
			end)
			if okSel then
				for _, inst in ipairs(selected) do
					if Capture.instanceIdByRef[inst] then
						self:markDirtyUpsert(inst)
					end
				end
			end
		end)
	end)
	if selOk then
		self.globalConns[#self.globalConns + 1] = selConn
	end
	local changeHistory = game:GetService("ChangeHistoryService")
	local undoOk, undoConn = pcall(function()
		return changeHistory.OnUndo:Connect(function()
			self.historyDirty = true
		end)
	end)
	if undoOk then
		self.globalConns[#self.globalConns + 1] = undoConn
	end
	local redoOk, redoConn = pcall(function()
		return changeHistory.OnRedo:Connect(function()
			self.historyDirty = true
		end)
	end)
	if redoOk then
		self.globalConns[#self.globalConns + 1] = redoConn
	end
	self.host.setStatus("connected", "Live — tick sync active")
	self.host.setStats(("rev %d · %d instances"):format(self.currentRevision, self.liveInstanceCount))
	return true
end

-- VERBATIM port of Live.setupAfterBaseline (monolith :3272): arm live mode and seed
-- revision/count from the materialized baseline result.
local function setupAfterBaseline(self: LiveModule__DARKLUA_TYPE_ai, materialized: any?): ()
	if self:connectLiveMode() then
		self.currentRevision = (materialized and materialized.revision) or 0
		self.liveInstanceCount = (materialized and (materialized.instances or materialized.totalItems)) or 0
	end
end

-- Tear down all live state and disconnect everything. VERBATIM port of Live.teardown
-- (monolith :3235): disconnect root/global/per-instance connections, clear every
-- dirty/stamp/parent map, reset fingerprints, bump the tick generation so any running
-- loop exits on its next guard check.
local function teardown(self: LiveModule__DARKLUA_TYPE_ai): ()
	self.liveRunning = false
	for _, conn in ipairs(self.rootConns) do
		pcall(function()
			conn:Disconnect()
		end)
	end
	self.rootConns = {}
	for _, conn in ipairs(self.globalConns) do
		pcall(function()
			conn:Disconnect()
		end)
	end
	self.globalConns = {}
	for _, conns in pairs(self.instConns) do
		for _, conn in ipairs(conns) do
			pcall(function()
				conn:Disconnect()
			end)
		end
	end
	self.instConns = {}
	self.dirtyUpsert = {}
	self.networkErrorCount = 0
	self.dirtyRemoved = {}
	self.parentByInst = {}
	self.currentRevision = 0
	self.liveInstanceCount = 0
	self.verifyNeeded = false
	Fingerprints:reset()
	self.pendingBulkRef = nil
	self.upsertStamp = {}
	self.removedStamp = {}
	self.tickGeneration += 1
end

-- == Module table ==

-- Assembled as a real value before return; the state tables start empty and every
-- method reaches state/siblings through `self`/module refs, so there is no
-- forward-reference-before-local read anywhere. The host starts as the no-op stub so a
-- pre-attach call is a safe no-op (the C3 cure).
Live = {
	liveRunning = false,
	currentRevision = 0,
	liveInstanceCount = 0,
	networkErrorCount = 0,
	syncInFlight = false,
	verifyNeeded = false,
	dirtyStamp = 0,
	dirtyUpsert = {},
	dirtyRemoved = {},
	upsertStamp = {},
	removedStamp = {},
	parentByInst = {},
	instConns = {},
	rootConns = {},
	globalConns = {},
	propGaps = {},
	pendingBulkRef = nil,
	baselineInProgress = false,
	recoveryServices = nil,
	tickGeneration = 0,
	historyDirty = false,

	host = NOOP_HOST,
	attach = attach,

	markDirtyUpsert = markDirtyUpsert,
	markDirtyRemoved = markDirtyRemoved,
	markSubtreeUpsert = markSubtreeUpsert,
	markSiblingsDirty = markSiblingsDirty,

	classifyChangedProp = classifyChangedProp,
	recordPropGap = recordPropGap,
	onNameChanged = onNameChanged,

	registerInstance = registerInstance,
	unregisterInstance = unregisterInstance,
	unregisterSubtree = unregisterSubtree,
	onDescendantAdded = onDescendantAdded,
	onDescendantRemoving = onDescendantRemoving,

	collectOpsFromDirty = collectOpsFromDirty,
	clearSentDirty = clearSentDirty,

	tickQuerySuffix = tickQuerySuffix,
	buildTickBody = buildTickBody,

	initFingerprintsFromWalk = initFingerprintsFromWalk,
	buildBaselineSnapshot = buildBaselineSnapshot,
	uploadTickBulk = uploadTickBulk,
	triggerFullBaseline = triggerFullBaseline,
	triggerDriftRecovery = triggerDriftRecovery,
	triggerRebaseline = triggerRebaseline,

	runTick = runTick,
	startTickLoop = startTickLoop,

	connectLiveMode = connectLiveMode,
	setupAfterBaseline = setupAfterBaseline,
	teardown = teardown,
}

return Live
end function __DARKLUA_BUNDLE_MODULES.p():typeof(__modImpl())local v=__DARKLUA_BUNDLE_MODULES.cache.p if not v then v={c=__modImpl()}__DARKLUA_BUNDLE_MODULES.cache.p=v end return v.c end end do local function __modImpl()--!strict
-- CapturePanel — the Capture/Query panel VIEW, ported faithfully from the
-- monolith's CapturePanel block (StudioStud.plugin.lua:1564-3346) MINUS the live
-- engine and the capture serializer, which now live in their own modules (Live /
-- Capture / Fingerprints / Hash). What remains here is exactly what the rewrite
-- assigns to this module: the panel chrome (result/error labels), the daemon
-- ping/handshake (statusFn), the connect+baseline orchestration (syncFn /
-- startupConnectAndCapture), the play->edit resume (onReturnToEdit — the C2 path),
-- and the LiveHost the engine calls back through.
--
-- VIEW-ONLY, ENGINE LIVES IN Live: this module owns no dirty sets, no tick loop,
-- no fingerprints — it BUILDS the ctx the engine needs (setStatus/setStats/
-- transport/isRunning/...) via Live's typed `LiveHost` seam and attaches it with
-- `Live:attach(host)`, then drives the engine through its public methods
-- (connectLiveMode / startTickLoop / triggerFullBaseline / teardown). The monolith
-- reached the engine through closure upvalues; here the seam is the injected,
-- typed host (Live.LiveHost) — the structural cure for the C1-C3 forward-reference
-- bug class.
--
-- Structure note (the bug class this rewrite kills): the monolith held statusFn /
-- syncFn / startupConnectAndCapture / onReturnToEdit / responseNeedsRebaseline as
-- forward-declared build-closure LOCALS referenced before assignment — the exact
-- before-local window that produced C2 (a nil onReturnToEdit captured into
-- startTickLoop) and C3 (Sync() before live nil-calls). Here they are fields on a
-- per-build `panel` state table; every cross-call goes through `panel.*` (a field
-- read resolved at call time), so nothing is read before its field is assigned.
-- `panel` is fully assembled before any handler can fire.
--
-- GlobalApi wiring is PER-BUILD / PER-DESTROY, faithful to the monolith
-- (StudioStud.plugin.lua:3314 wired inside every CapturePanel.build, :3322
-- unwired inside destroy). `build` calls `GlobalApi.wireCapture(status, sync)`
-- so `GlobalApi.statusFn`/`.syncFn` always track the currently-live panel, and
-- `destroy` calls `GlobalApi.installNoOps()` so the handlers revert to the disabled
-- state whenever the panel is torn down (tab toggle off, `Registry.teardownAll`,
-- `Shell.build`). The S2 change is preserved: GlobalApi stores these INTERNALLY and
-- never publishes raw `Sync`/`Capture`/`Status` onto `_G`. The panel itself never
-- touches `_G`. (An earlier rewrite wired once at bootstrap; that left the handlers
-- pointing at a destroyed panel after any rebuild and broke the ported
-- '_G no-op while torn down' / '_G re-wire identity' SelfTest assertions.)


local Theme = __DARKLUA_BUNDLE_MODULES.k()
local Ui = __DARKLUA_BUNDLE_MODULES.l()
local Shell = __DARKLUA_BUNDLE_MODULES.m()
local Config = __DARKLUA_BUNDLE_MODULES.a()
local Session = __DARKLUA_BUNDLE_MODULES.f()
local AllowList = __DARKLUA_BUNDLE_MODULES.h()
local Live = __DARKLUA_BUNDLE_MODULES.p()
local Capture = __DARKLUA_BUNDLE_MODULES.o()
local GlobalApi = __DARKLUA_BUNDLE_MODULES.d()






local PLUGIN_VERSION = Config.PLUGIN_VERSION
local PROTOCOL_VERSION = Config.PROTOCOL_VERSION
local MIN_DAEMON_PROTOCOL_VERSION = Config.MIN_DAEMON_PROTOCOL_VERSION

-- `game` is a Studio/plugin global the analyzer types via globalTypes.d.luau; read
-- directly where the monolith read it (PlaceId / Name in the connect result).

-- == Update-nudge helpers (ported verbatim from the monolith Config block) ==

-- These are NOT compile-time constants — `updateInstallHint` is channel-aware and
-- `checkRemoteUpdate` carries per-ping mutable state — so Config (constants-only)
-- intentionally omits them; they belong with their UI consumer (this panel). Ported
-- verbatim from StudioStud.plugin.lua:61-140.

-- Channel-aware install one-liner for the "update available" nudge. The daemon ping
-- reports the machine's channel; dev points at its own bootstrap so following the
-- hint never silently switches the user onto release.
local function updateInstallHint(channel: any): string
	local script = "install.ps1"
	if channel == "dev" then
		script = "install-dev.ps1"
	end
	return ("irm https://tyleradams2002.github.io/studio-stud/%s | iex"):format(script)
end

-- Update nudge from /studio-stud/ping (channel-aware). Best-effort; never throws.
-- State bundled in one table (matches the monolith's module-scope-low rationale).
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
	local notes: { string } = {}
	if
		type(pingResult.latestPluginVersion) == "string"
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










































































local CapturePanel = {} :: CapturePanelModule__DARKLUA_TYPE_aq

-- == build ==

function CapturePanel.build(parent: Frame, ctx: ShellContext__DARKLUA_TYPE_ak): PanelHandle__DARKLUA_TYPE_ap
	local debugLog = ctx.settings.debugLog

	local resultLabel = Ui.makeLabel(parent, "Latest capture: none", Theme.PAD, 72, Theme.muted)
	resultLabel.TextSize = 12

	local errorLabel = Ui.makeLabel(parent, "", Theme.PAD + 80, 80, Theme.warn)
	errorLabel.TextSize = 12

	-- The state record; fields assigned below before any handler can fire.
	local panel: PanelState__DARKLUA_TYPE_ar = {
		ctx = ctx,
		parent = parent,
		resultLabel = resultLabel,
		errorLabel = errorLabel,
		syncing = false,
		running = true,
		autoPolling = false,
		pollGeneration = 0,
		sessionHasBaseline = false,
		pausedBaseline = { revision = 0, instanceCount = 0 },
	} :: PanelState__DARKLUA_TYPE_ar

	-- VERBATIM port of CapturePanel.build's formatError (monolith :1594).
	function panel.formatError(_self: PanelState__DARKLUA_TYPE_ar, prefix: string, result: any): string
		local message = prefix .. ": " .. tostring(result and result.error or "unknown error")
		if result and result.statusCode then
			message = message .. " (HTTP " .. tostring(result.statusCode) .. ")"
		end
		if result and result.body and result.body ~= "" then
			message = message .. "\n" .. tostring(result.body)
		end
		return message
	end

	-- Lightweight reachability check: ping only, no status or error-label mutation.
	function panel.probe(self: PanelState__DARKLUA_TYPE_ar): boolean
		local ok, result = self.ctx.transport.requestJson("GET", "/studio-stud/ping", nil)
		return ok and type(result) == "table" and result.ok == true
	end

	-- VERBATIM port of statusFn (monolith :2077): ping the daemon, run the mutual
	-- protocol handshake, set the connection LED/status, and (on success) prime the
	-- write token. Returns the loose result shape the monolith returned.
	function panel.statusFn(self: PanelState__DARKLUA_TYPE_ar, options: { silent: boolean }?): SyncResult__DARKLUA_TYPE_ao
		self.ctx.setStatus("syncing", "Checking daemon...")
		local ok, result = self.ctx.transport.requestJson("GET", "/studio-stud/ping", nil)
		if ok and result.ok then
			local daemonProtocol = tonumber(result.protocolVersion) or 0
			local daemonMinPlugin = tonumber(result.minPluginProtocolVersion) or daemonProtocol
			-- Mutual handshake: name whichever side is behind.
			if daemonProtocol < MIN_DAEMON_PROTOCOL_VERSION then
				self.ctx.setConnected(false)
				self.ctx.setStatus("error", "Daemon outdated — update it")
				self.errorLabel.Text = ("Daemon protocol %d < plugin requires %d. Update: %s"):format(
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
				self.ctx.setConnected(false)
				self.ctx.setStatus("error", "Plugin outdated — reinstall plugin")
				self.errorLabel.Text = ("Plugin protocol %d < daemon requires %d. Reinstall from .studio-stud-tool/plugin/StudioStud.plugin.lua"):format(
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
			self.ctx.setConnected(true)
			local updateNote = checkRemoteUpdate(result)
			if updateNote ~= "" then
				self.ctx.setStatus(
					"connected",
					("Daemon %s — %s"):format(tostring(result.version or "unknown"), updateNote)
				)
				self.errorLabel.Text = updateNote .. "  (run: " .. updateInstallHint(result.channel) .. ")"
			else
				self.ctx.setStatus(
					"connected",
					("Daemon %s — listening for captures"):format(tostring(result.version or "unknown"))
				)
				self.errorLabel.Text = ""
			end
			self.ctx.transport.fetchWriteToken()
			return { ok = true, daemon = result, placeId = game.PlaceId, placeName = game.Name }
		end
		self.ctx.setConnected(false)
		local silent = self.autoPolling or (options and options.silent == true)
		if silent then
			self.errorLabel.Text = ""
			return { ok = false, error = result.error, placeId = game.PlaceId, placeName = game.Name }
		end
		self.ctx.setStatus("idle", "Run studio-stud serve, then Connect")
		self.errorLabel.Text = self:formatError("Connect failed", result)
		return { ok = false, error = result.error, placeId = game.PlaceId, placeName = game.Name }
	end

	-- VERBATIM port of syncFn (monolith :2065): gate to edit sessions; if live is
	-- already running, schedule a tick baseline; else run the full connect+capture.
	function panel.syncFn(self: PanelState__DARKLUA_TYPE_ar, options: any?): SyncResult__DARKLUA_TYPE_ao
		if not Session.isEdit() then
			return { ok = false, error = "studio_in_play_session" }
		end
		if Live.liveRunning then
			Live:triggerFullBaseline(options and options.reason or "manual")
			self.ctx.setStatus("syncing", "Scheduling tick baseline...")
			return { ok = true, status = "baseline_scheduled" }
		end
		return self:startupConnectAndCapture()
	end

	-- VERBATIM port of startupConnectAndCapture (monolith :2138). Ping daemon; on the
	-- first success this session, load the allow-list once, bring up live mode, and
	-- start the single tick loop — handing it this panel's pausedBaseline ref and a
	-- NON-NIL onReturnToEdit (the C2 cure: the monolith captured a not-yet-assigned
	-- upvalue here). The onReturnToEdit closure routes back through `panel:onReturnToEdit()`.
	function panel.startupConnectAndCapture(self: PanelState__DARKLUA_TYPE_ar): SyncResult__DARKLUA_TYPE_ao
		-- Edit-session gate: do not connect/capture while Studio is in a play session.
		if not Session.isEdit() then
			return { ok = false, error = "studio_in_play_session" }
		end
		if self.syncing then
			return { ok = false, error = "Sync already running." }
		end
		local ping = self:statusFn()
		-- statusFn always returns a (non-nil) SyncResult, so the monolith's
		-- `not (ping and ping.ok)` reduces to `not ping.ok` here (same behaviour,
		-- and keeps the return typed SyncResult rather than SyncResult?).
		if not ping.ok then
			return ping
		end
		if not AllowList.loaded then -- load once per connect (best-effort; static fallback on failure)
			AllowList.fetch()
		end
		if self.sessionHasBaseline and Live.liveRunning then
			return ping
		end
		debugLog("startup: daemon reachable — starting tick live mode")
		if Live:connectLiveMode() then
			Live:startTickLoop(self.pausedBaseline, function()
				self:onReturnToEdit()
			end)
			self.ctx.setConnected(true)
			self.sessionHasBaseline = true
			self.resultLabel.Text = "Connected — first tick will baseline via /tick"
			return { ok = true, daemon = ping.daemon }
		end
		return { ok = false, error = "live_connect_failed" }
	end

	-- VERBATIM port of onReturnToEdit (monolith :3280): the play->edit catch-up. After
	-- a short settle, if still in edit, re-arm live mode from the stashed pausedBaseline
	-- and restart the tick loop (re-passing self:onReturnToEdit so the loop stays armed
	-- across further transitions); else trigger a full rebaseline via the host.
	function panel.onReturnToEdit(self: PanelState__DARKLUA_TYPE_ar): ()
		task.wait(1.5)
		if not Session.isEdit() then
			return
		end
		if Live:connectLiveMode() then
			Live.currentRevision = self.pausedBaseline.revision or 0
			Live.liveInstanceCount = self.pausedBaseline.instanceCount or 0
			Live:startTickLoop(self.pausedBaseline, function()
				self:onReturnToEdit()
			end)
			self.ctx.setConnected(true)
			self.sessionHasBaseline = true
			self.ctx.setStatus("connected", "Live resumed — tick sync active")
			debugLog("session: resumed live after play (rev ", Live.currentRevision, ")")
		else
			Live:triggerRebaseline("return-to-edit")
		end
	end

	-- == Attach the engine host (the injected seam) ==

	-- Build the LiveHost the engine calls back through. transport/setStatus/setStats/
	-- isConnected/setConnected come straight from ctx (the monolith's closure upvalues,
	-- now typed). setBaseline persists this panel's sessionHasBaseline; reconnect is the
	-- full connect handshake (the monolith's startupConnectAndCapture, used by
	-- triggerRebaseline); isRunning is the panel-alive flag the tick loop checks.
	local host: LiveHost__DARKLUA_TYPE_al = {
		transport = {
			requestJson = ctx.transport.requestJson,
			requestBody = ctx.transport.requestBody,
		},
		setStatus = ctx.setStatus,
		setStats = function(text: string)
			ctx.setStats(text)
		end,
		setConnected = ctx.setConnected,
		isConnected = ctx.isConnected,
		setBaseline = function(hasBaseline: boolean)
			panel.sessionHasBaseline = hasBaseline
		end,
		reconnect = function()
			panel:startupConnectAndCapture()
		end,
		isRunning = function(): boolean
			return panel.running
		end,
	}
	Live:attach(host)

	panel.pollGeneration += 1
	local myGeneration = panel.pollGeneration

	-- The handle's `sync`/`status` entry points, named so the SAME closures are both
	-- returned on the handle AND wired into GlobalApi below — preserving the monolith's
	-- `_G.StudioStud.Sync == handle.sync` identity (now `GlobalApi.syncFn == handle.sync`
	-- under S2). They close over `panel` and route through its methods.
	local syncEntry = function(options: any?): SyncResult__DARKLUA_TYPE_ao
		return panel:syncFn(options)
	end
	local statusEntry = function(): SyncResult__DARKLUA_TYPE_ao
		return panel:statusFn()
	end
	local probeEntry = function(): boolean
		return panel:probe()
	end
	local setAutoPollingEntry = function(enabled: boolean)
		panel.autoPolling = enabled
	end

	-- Per-build wire (monolith :3314): GlobalApi now tracks THIS live panel's handlers
	-- internally (S2 — never published to `_G`).
	GlobalApi.wireCapture(statusEntry, syncEntry)

	-- VERBATIM port of the panel's destroy (monolith :3316): stop the loop, tear down
	-- the engine, and revert GlobalApi to the disabled state (monolith :3322) so a
	-- torn-down panel never leaves stale handlers wired.
	local function destroy(): ()
		panel.running = false
		Live:teardown()
		GlobalApi.installNoOps()
	end

	-- VERBATIM port of the panel handle (monolith :3325). `onConnectRequested` closes
	-- over `panel`; `sync`/`status` reuse the wired entry closures.
	return {
		frame = parent,
		sync = syncEntry,
		status = statusEntry,
		probe = probeEntry,
		setAutoPolling = setAutoPollingEntry,
		isRunning = function(): boolean
			return panel.running
		end,
		pollGeneration = myGeneration,
		onConnectRequested = function(): SyncResult__DARKLUA_TYPE_ao
			return panel:startupConnectAndCapture()
		end,
		destroy = destroy,
		live = Live, -- exposed for self-tests and _G.StudioStud.Live
		capture = Capture, -- Phase 3: exposed for self-tests (SelfTest reaches Capture only via this field)
	}
end

-- == Descriptor ==

-- VERBATIM port of CapturePanel.descriptor (monolith :3340): the tab the bootstrap
-- registers with Registry.
CapturePanel.descriptor = {
	id = "capture",
	title = "Live Sync",
	defaultEnabled = true,
	build = CapturePanel.build,
}

return CapturePanel
end function __DARKLUA_BUNDLE_MODULES.q():typeof(__modImpl())local v=__DARKLUA_BUNDLE_MODULES.cache.q if not v then v={c=__modImpl()}__DARKLUA_BUNDLE_MODULES.cache.q=v end return v.c end end end--!strict
-- init — the plugin bootstrap and darklua bundle root. Ported faithfully from the
-- monolith's top guard (StudioStud.plugin.lua:1-24) and its Bootstrap block
-- (:4572-4613). This is the ONE file darklua resolves `require`s from to produce
-- the single distributable `dist/StudioStud.plugin.lua`; every other module is
-- reached through it (directly or transitively).
--
-- WHAT THIS OWNS (the contract item "Session/misc: plugin-vs-game-script guard;
-- toolbar/widget bootstrap with auto-connect"):
--   1. The plugin-only guard (:12): refuse to do anything unless the `plugin`
--      global exists, so an embedded copy pasted into a place never runs inside a
--      live game DataModel and captures the running game.
--   2. Install the minimal `_G.StudioStud` surface (S2: only RunSelfTest + token)
--      via GlobalApi. The per-panel capture handlers are wired INSIDE the panel
--      lifecycle (CapturePanel.build wires, destroy unwires) — faithful to the
--      monolith — not here, so they always track the currently-live panel across
--      rebuilds/teardown rather than going stale at a destroyed panel.
--   3. Register the CapturePanel descriptor, build the widget chrome (Shell), and
--      auto-connect on widget-enable.
--   4. The toolbar-button toggle, the Unloading reclaim, and the once-per-version
--      welcome print.
--
-- Structure note (the bug class this rewrite kills): this is a flat, linear
-- bootstrap. There are no forward-referenced locals — every collaborator is a
-- required module table (Shell/Registry/GlobalApi/...) whose methods are field
-- reads resolved at call time, and the only closures (the toolbar click handler,
-- the deferred enable, the welcome) capture already-required module tables, never a
-- not-yet-assigned local. The C1-C3 forward-reference window does not exist here.
--
-- Trust boundary: the `plugin` global is the single Studio handle this file reads;
-- it is typed via globalTypes.d.luau under the analyzer and captured once. `_G`
-- hardening lives in GlobalApi (ownership token); panel/Studio errors are swallowed
-- where the monolith swallowed them (the welcome pcall).

-- == Plugin-only guard (verbatim port of :12) ==

-- This file MUST run as a Studio plugin (loaded from the Plugins folder), where the
-- `plugin` global exists. If a copy of this source is ever embedded in a place
-- (e.g. pasted into Workspace as a Script and saved), it would otherwise run inside
-- the running game's Server/Client DataModels during a playtest and capture the
-- live game. When `plugin` is nil we are NOT a plugin — bail out before requiring
-- (and thus loading/bootstrapping) any subsystem.
--
-- `plugin` is the plugin-context global typed by globalTypes.d.luau. The analyzer
-- types it non-optional, but at the bundle root it genuinely may be nil (the
-- embedded-script case the guard exists for), so it is read through an `any` shim
-- here — the single place this file treats a Studio global as untrusted — rather
-- than disabling checks for the whole module.

local pluginGlobal: Plugin? = (plugin :: any) :: Plugin?
if not pluginGlobal then
	warn(
		"[StudioStud] This is a Studio plugin, not a game script. Install it via the Roblox "
			.. "Plugins folder and remove any embedded copy (e.g. Workspace.Script) from the place."
	)
	-- Bail out without bootstrapping. Returning an empty typed module keeps the
	-- bundle root a valid `--!strict` ModuleScript in the embedded-script case while
	-- doing nothing (the monolith bare-`return`ed here).
	return {}
end

-- Past the guard `pluginGlobal` is non-nil; narrow it into a non-optional handle so
-- the field accesses below (CreateToolbar via Shell, Unloading, GetSetting) type
-- cleanly without per-call narrowing.
local pluginHandle: Plugin = pluginGlobal

local Config = __DARKLUA_BUNDLE_MODULES.a()
local Settings = __DARKLUA_BUNDLE_MODULES.b()
local Registry = __DARKLUA_BUNDLE_MODULES.c()
local GlobalApi = __DARKLUA_BUNDLE_MODULES.d()
local SelfTest = __DARKLUA_BUNDLE_MODULES.n()
local Shell = __DARKLUA_BUNDLE_MODULES.m()
local CapturePanel = __DARKLUA_BUNDLE_MODULES.q()

local PLUGIN_VERSION = Config.PLUGIN_VERSION
local WELCOME_VERSION = Config.WELCOME_VERSION
local SETTINGS = Config.SETTINGS

-- == RunSelfTest binding ==

-- The monolith published `_G.StudioStud.RunSelfTest = SelfTest.run`; `SelfTest.run`
-- returns a bare boolean (`true` on pass, `false` on fail).
local runSelfTest = SelfTest.run

-- == Public interface ==

-- The bootstrap exports the small surface that drives load: `start` performs the
-- full bootstrap (install the global, register panel, build chrome — the panel wires
-- its own capture handlers as it builds — arm the toolbar/unload hooks, schedule
-- auto-connect, show the welcome). Exported
-- (rather than run at module load) so the darklua bundle root can call it once and
-- so the in-engine SelfTest can assert the wiring is idempotent. `runSelfTest` and
-- the captured `plugin` handle are exposed for the same test surface.
export type InitModule = {
	start: () -> (),
	runSelfTest: () -> boolean,
	plugin: Plugin,
}

-- == Bootstrap helpers ==

-- Once-per-version welcome (verbatim port of showWelcomeOnce, :4600). Best-effort:
-- the GetSetting read and the SetSetting write are each pcall-guarded exactly as the
-- monolith did, so a corrupt/unwritable setting never blocks load. Reads/writes go
-- through the captured `pluginHandle` (not Settings) to mirror the monolith's raw
-- GetSetting/SetSetting calls and their exact welcome semantics.
local function showWelcomeOnce(): ()
	local ok, value = pcall(function()
		return pluginHandle:GetSetting(SETTINGS.welcomeVersion)
	end)
	if ok and value == WELCOME_VERSION then
		return
	end
	print(
		"[Studio Stud] Loaded v"
			.. PLUGIN_VERSION
			.. ". Run `studio-stud serve`, then open this panel — it connects and captures automatically."
	)
	pcall(function()
		pluginHandle:SetSetting(SETTINGS.welcomeVersion, WELCOME_VERSION)
	end)
end

-- == start ==

local started = false

local function start(): ()
	-- Idempotent: a second call (e.g. a SelfTest re-bootstrap probe) is a no-op so we
	-- never double-register the descriptor or stack duplicate toolbar/unload hooks.
	if started then
		return
	end
	started = true

	-- One-time: bring a pre-revision install onto the current default debounce (500ms) and
	-- debug-off BEFORE the settings overlay reads them, so the UI shows the expected state.
	-- Idempotent (guarded by settingsRev), so this is a no-op on every subsequent load.
	Settings.applyDefaultsMigration()

	-- Install the minimal global surface BEFORE building the panel, mirroring the
	-- monolith's `_G.StudioStud = _G.StudioStud or {}` + `RunSelfTest` running ahead of
	-- the panel. (S2: only RunSelfTest + the ownership token are published; the panel's
	-- capture handlers are wired internally on GlobalApi during its own build, not here.)
	GlobalApi.install(runSelfTest)

	-- Register the one panel descriptor, then build the widget chrome. Shell.build
	-- wires the Registry host and selects the first enabled tab, which lazily builds
	-- the CapturePanel — and CapturePanel.build itself wires its capture handlers into
	-- GlobalApi (S2, internal-only) as part of that build, so no bootstrap-level wire
	-- is needed and the handlers always track the live panel across rebuilds/teardown.
	Registry.register(CapturePanel.descriptor)
	Shell.build()

	-- Auto-connect on enable (verbatim port of the deferred Shell.onWidgetEnabled at
	-- :4581): defer so the widget finishes laying out before the connect handshake.
	task.defer(function()
		Shell.onWidgetEnabled()
	end)

	-- Toolbar toggle (verbatim port of :4585): flip the widget, sync the button's
	-- active state, and kick the connect handshake when it becomes visible.
	Shell.toolbarButton.Click:Connect(function()
		Shell.widget.Enabled = not Shell.widget.Enabled
		Shell.toolbarButton:SetActive(Shell.widget.Enabled)
		if Shell.widget.Enabled then
			Shell.onWidgetEnabled()
		end
	end)

	-- Unload reclaim (verbatim port of :4593): tear down every built panel and, only
	-- if we still own `_G.StudioStud` (GlobalApi's ownership token — the monolith's
	-- `RunSelfTest == SelfTest.run` identity guard, generalized), nil the slot so a
	-- later-loaded plugin that replaced it is never clobbered.
	pluginHandle.Unloading:Connect(function()
		Registry.teardownAll()
		GlobalApi.reclaim()
	end)

	showWelcomeOnce()
end

-- == Module table ==

local Init: InitModule = {
	start = start,
	runSelfTest = runSelfTest,
	plugin = pluginHandle,
}

-- Run the bootstrap now: as the darklua bundle root this module is required exactly
-- once at plugin load, and `start` is idempotent, so calling it here reproduces the
-- monolith's run-at-load behavior while keeping the logic exported for tests.
start()

return Init
