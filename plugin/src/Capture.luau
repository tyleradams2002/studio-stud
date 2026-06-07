--!strict
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

local Types = require("./Types")
local Config = require("./Config")
local AllowList = require("./AllowList")
local Hash = require("./Hash")

type InstanceEntry = Types.InstanceEntry
type PropertyMap = Types.PropertyMap
type AttributeMap = Types.AttributeMap
type Tags = Types.Tags
type ClassPropSet = Types.ClassPropSet
type SourceEncoding = Types.SourceEncoding

local CLASS_PROPERTIES = Config.CLASS_PROPERTIES
local ROOT_SERVICE_ORDER = Config.ROOT_SERVICE_ORDER
local ROOT_SERVICE_INDEX = Config.ROOT_SERVICE_INDEX
local DESCENDANT_ROOT_SERVICES = Config.DESCENDANT_ROOT_SERVICES
local SERVICE_NAME = Config.SERVICE_NAME
local PLUGIN_VERSION = Config.PLUGIN_VERSION
local BASELINE_YIELD_EVERY = Config.BASELINE_YIELD_EVERY

-- == Supporting types ==

-- A per-property read error, collected when a property pcall throws (the per-prop
-- fallback path) or attribute read fails. Carried on the baseline entry as
-- propertyErrors; not part of the wire fingerprint.
export type PropertyError = {
	property: string,
	error: string,
}

-- One captured root service to walk (the result of getRootEntries). includeDescendants
-- gates whether the subtree is descended (DESCENDANT_ROOT_SERVICES) or captured as a
-- single leaf root.
export type RootEntry = {
	name: string,
	instance: Instance,
	includeDescendants: boolean,
}

-- The baseline snapshot envelope (the /tick/bulk baseline body). Field set and
-- nesting are the wire — ported verbatim from buildSnapshot.
export type Snapshot = {
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

export type SnapshotOptions = {
	reason: string?,
	requestId: any?,
}

-- E2: a per-flush sibling memo. Caller (Live.collectOpsFromDirty) creates one per
-- pass and threads it through buildUpsertedEntry so each parent's children are
-- scanned once, not once per dirty child. Keyed by the parent Instance.
export type SiblingMemo = {
	[Instance]: {
		counts: { [string]: number },
		children: { Instance },
	},
}

-- == Public interface ==

export type CaptureModule = {
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
	curatedSet: (inst: Instance) -> ClassPropSet,

	-- Property reads. readProperties is optimistic batch-pcall with per-property
	-- fallback (readPropsFrom) + Model bounding-box/pivot. Both return (props, errors).
	readPropsFrom: (inst: any, names: { string }) -> (PropertyMap, { PropertyError }),
	readProperties: (inst: Instance) -> (PropertyMap, { PropertyError }),

	-- base64 codec (the source non-UTF-8 path). Ported verbatim (the daemon decodes
	-- the same alphabet/padding).
	base64encode: (raw: string) -> string,
	base64decode: (encoded: string) -> string,

	-- LuaSourceContainer source: (text, encoding) as utf8, or (base64, "base64") when
	-- not valid UTF-8; (nil, nil) for non-script instances or a read failure.
	readSource: (inst: Instance) -> (string?, SourceEncoding?),
	-- All attributes (no whitelist), serialized; second return is errors.
	readAttributes: (inst: Instance) -> (AttributeMap, { PropertyError }),
	-- CollectionService tags in capture order ({} on failure).
	readTags: (inst: Instance) -> Tags,

	-- The yielding baseline walk. getRootEntries -> ordered captured services;
	-- collectBaseInstances -> (structural entries, rootNames) + populated id/path
	-- maps; buildSnapshot -> the full snapshot envelope (props/attrs/tags/source
	-- filled in a second yielding pass).
	getRootEntries: () -> { RootEntry },
	collectBaseInstances: () -> ({ any }, { string }),
	buildSnapshot: (options: SnapshotOptions?) -> Snapshot,

	-- The live per-instance entry builder. Returns (entry, oldPath): entry with fp
	-- set via Hash, oldPath = the path the instance had in pathByRef before this
	-- build (nil if new), so the caller can XOR the old fingerprint out of the right
	-- service. Returns (nil, nil) when the instance has no id, no parent, isn't found
	-- among its siblings, or its parent's GetChildren throws (mirrors the monolith's
	-- early-outs). `memo` (optional, E2) collapses per-parent sibling scans within a
	-- single flush.
	buildUpsertedEntry: (inst: Instance, memo: SiblingMemo?) -> (InstanceEntry?, string?),
}

-- Forward declaration of the module table so methods reach one another and the
-- per-walk maps through it (serializeValue -> Capture.instanceIdByRef;
-- collectBaseInstances -> Capture.shouldYield; buildSnapshot -> Capture.readProperties)
-- WITHOUT a forward-referenced upvalue. Capture.* is a real table field by the time
-- any method runs.
local Capture: CaptureModule

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
local function curatedSet(inst: Instance): ClassPropSet
	local fromAllow = AllowList.setFor(inst.ClassName)
	if fromAllow then
		return fromAllow
	end
	local set: ClassPropSet = {}
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
local function readPropsFrom(inst: any, names: { string }): (PropertyMap, { PropertyError })
	local properties: PropertyMap = {}
	local errors: { PropertyError } = {}
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
local function readProperties(inst: Instance): (PropertyMap, { PropertyError })
	local anyInst = inst :: any
	local names = getPropertyNames(inst)
	local properties: PropertyMap = {}
	local errors: { PropertyError } = {}
	local batchOk, batchProps = pcall(function()
		local props: PropertyMap = {}
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
local function readSource(inst: Instance): (string?, SourceEncoding?)
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
local function readAttributes(inst: Instance): (AttributeMap, { PropertyError })
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
local function readTags(inst: Instance): Tags
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
local function getRootEntries(): { RootEntry }
	local roots: { RootEntry } = {}
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
local function buildSnapshot(options: SnapshotOptions?): Snapshot
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
	memo: SiblingMemo?
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
local function buildUpsertedEntry(inst: Instance, memo: SiblingMemo?): (InstanceEntry?, string?)
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
	local entry: InstanceEntry = {
		id = id,
		parentId = parentId,
		path = path,
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
		entry.sourceEncoding = (if srcEnc then srcEnc else "utf8") :: SourceEncoding
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
