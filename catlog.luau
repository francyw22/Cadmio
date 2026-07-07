local fs = require("@lune/fs")
local process = require("@lune/process")
local stdio = require("@lune/stdio")
local task = require("@lune/task")
local serde = require("@lune/serde")
local roblox = require("@lune/roblox")
local luau = require("@lune/luau")
local net = require("@lune/net")

local Settings = {
    out = "out.lua",
    timeout = 60,
    ipt = nil :: string?,
    beautify = true,
    inline = true,
}
for _, arg in process.args do
    local k, v = string.match(arg, "([%w_]+)=(.+)")
    if k then
        if v:sub(1,1) == "'" and v:sub(-1) == "'" then v = v:sub(2, -2)
        elseif v:sub(1,1) == '"' and v:sub(-1) == '"' then v = v:sub(2, -2) end
        Settings[k] = if v == "true" then true elseif v == "false" then false elseif tonumber(v) then tonumber(v) else v
    else
        local val = arg
        if val:sub(1,1) == "'" and val:sub(-1) == "'" then val = val:sub(2, -2)
        elseif val:sub(1,1) == '"' and val:sub(-1) == '"' then val = val:sub(2, -2) end
        if not Settings.ipt and not string.match(val, "^%-") then
            Settings.ipt = val
        end
    end
end

local API_DUMP_PATH = "stuff/API-Dump.json"
local apiClassesByName = {}

local function getScriptDir(): string?
    for level = 1, 16 do
        local ok, source = pcall(debug.info, level, "s")
        if not ok or type(source) ~= "string" or source == "" then
            break
        end
        if source ~= "[C]" then
            local path = source:match('^%[string "(.-)"%]$') or source:match("^@(.+)$") or source
            local dir = path:match("(.*[/\\])")
            if dir and dir ~= "" then
                return dir
            end
        end
    end
    return nil
end

local SCRIPT_DIR = getScriptDir()

local function resolveApiDumpPath(): string?
    if type(Settings.api_dump) == "string" and Settings.api_dump ~= "" then
        local ok = pcall(fs.readFile, Settings.api_dump)
        if ok then return Settings.api_dump end
    end
    if type(process.env.CADMIO_API_DUMP) == "string" and process.env.CADMIO_API_DUMP ~= "" then
        local ok = pcall(fs.readFile, process.env.CADMIO_API_DUMP)
        if ok then return process.env.CADMIO_API_DUMP end
    end
    do
        local ok = pcall(fs.readFile, API_DUMP_PATH)
        if ok then return API_DUMP_PATH end
    end
    if SCRIPT_DIR then
        local candidate = SCRIPT_DIR .. API_DUMP_PATH
        local ok = pcall(fs.readFile, candidate)
        if ok then return candidate end
    end
    local cwd = process.cwd or ""
    for _ = 1, 6 do
        if cwd == "" then break end
        local candidate = cwd .. "/" .. API_DUMP_PATH
        local ok = pcall(fs.readFile, candidate)
        if ok then return candidate end
        local parent = cwd:match("(.*)/[^/]*")
        if not parent or parent == cwd then break end
        cwd = parent
    end
    return nil
end

local NUMBER_PRIMITIVE_TYPES = {
    int = true,
    int64 = true,
    float = true,
    double = true,
}

local STRING_LIKE_DATA_TYPES = {
    BinaryString = true,
    Content = true,
    ContentId = true,
    ProtectedString = true,
    SharedString = true,
}

local SERVER_ONLY_SERVICES = {
    ServerScriptService = true,
    ServerStorage = true,
}

local function makeTagSet(items)
    local tags = {}
    if type(items) == "table" then
        for _, item in ipairs(items) do
            tags[tostring(item)] = true
        end
    end
    return tags
end

local function normalizeApiType(typeInfo)
    if type(typeInfo) ~= "table" or type(typeInfo.Name) ~= "string" then
        return nil
    end

    return {
        category = tostring(typeInfo.Category or ""),
        name = typeInfo.Name,
    }
end

local RESOLVED_API_DUMP_PATH = resolveApiDumpPath()

local function loadApiDump()
    if not RESOLVED_API_DUMP_PATH then
        local scriptDirHint = SCRIPT_DIR and (" (script dir: " .. SCRIPT_DIR .. ")") or ""
        error(
            "API dump not found. Looked for '" .. API_DUMP_PATH
            .. "' relative to CWD, the script directory" .. scriptDirHint
            .. ", and parent directories. You can pass an explicit path with"
            .. " `api_dump=/abs/path/to/API-Dump.json` or set CADMIO_API_DUMP.",
            0
        )
    end
    local raw = fs.readFile(RESOLVED_API_DUMP_PATH)
    local decoded = serde.decode("json", raw)

    for _, classEntry in ipairs(decoded.Classes or {}) do
        if type(classEntry.Name) == "string" and classEntry.Name ~= "" then
            local classInfo = {
                name = classEntry.Name,
                superclass = classEntry.Superclass,
                tags = makeTagSet(classEntry.Tags),
                members = {},
            }

            for _, member in ipairs(classEntry.Members or {}) do
                if type(member.Name) == "string" and member.Name ~= "" then
                    classInfo.members[member.Name] = {
                        memberType = tostring(member.MemberType or ""),
                        name = member.Name,
                        security = member.Security,
                        serialization = member.Serialization,
                        threadSafety = member.ThreadSafety,
                        tags = makeTagSet(member.Tags),
                        valueType = normalizeApiType(member.ValueType),
                        returnType = normalizeApiType(member.ReturnType),
                        parameters = member.Parameters,
                    }
                end
            end

            apiClassesByName[classInfo.name] = classInfo
        end
    end
end

local apiLoadOk, apiLoadErr = pcall(loadApiDump)
if not apiLoadOk then
    local location = RESOLVED_API_DUMP_PATH or API_DUMP_PATH
    error("Failed to load API dump from " .. location .. ": " .. tostring(apiLoadErr))
end

local function getApiClassInfo(className)
    if type(className) ~= "string" then
        return nil
    end
    return apiClassesByName[className]
end

local function resolveApiMember(className, memberName)
    if type(className) ~= "string" or type(memberName) ~= "string" then
        return nil, nil
    end

    local classInfo = getApiClassInfo(className)
    while classInfo do
        local memberInfo = classInfo.members[memberName]
        if memberInfo then
            return memberInfo, classInfo
        end

        if type(classInfo.superclass) ~= "string" or classInfo.superclass == "" then
            break
        end
        classInfo = getApiClassInfo(classInfo.superclass)
    end

    return nil, nil
end

local function classIsA(className, targetClassName)
    if type(className) ~= "string" or type(targetClassName) ~= "string" then
        return false
    end
    if className == targetClassName then
        return true
    end

    local classInfo = getApiClassInfo(className)
    while classInfo and type(classInfo.superclass) == "string" and classInfo.superclass ~= "" do
        if classInfo.superclass == targetClassName then
            return true
        end
        classInfo = getApiClassInfo(classInfo.superclass)
    end

    return false
end

local function isApiServiceClass(className)
    local classInfo = getApiClassInfo(className)
    return classInfo ~= nil and classInfo.tags.Service == true
end

local function isApiCreatableClass(className)
    local classInfo = getApiClassInfo(className)
    return classInfo ~= nil and not classInfo.tags.NotCreatable
end

local function getRuntimeTypeName(apiType)
    if not apiType then
        return nil
    end

    if apiType.category == "Primitive" then
        if apiType.name == "bool" then
            return "boolean"
        end
        if apiType.name == "string" then
            return "string"
        end
        if apiType.name == "null" then
            return "nil"
        end
        if NUMBER_PRIMITIVE_TYPES[apiType.name] then
            return "number"
        end
    elseif apiType.category == "Enum" then
        return "EnumItem"
    elseif apiType.category == "Class" then
        return "Instance"
    elseif apiType.category == "DataType" then
        if apiType.name == "RBXScriptSignal" then
            return "RBXScriptSignal"
        end
        if STRING_LIKE_DATA_TYPES[apiType.name] then
            return "string"
        end
        return apiType.name
    end

    return nil
end

local function isPropertyMember(memberInfo)
    return memberInfo ~= nil and memberInfo.memberType == "Property"
end

local function isReadablePropertyMember(memberInfo)
    if not isPropertyMember(memberInfo) then
        return false
    end
    if memberInfo.tags.NotScriptable then
        return false
    end
    if type(memberInfo.security) ~= "table" then
        return false
    end
    return tostring(memberInfo.security.Read or "") == "None"
end

local function isWritablePropertyMember(memberInfo)
    if not isPropertyMember(memberInfo) then
        return false
    end
    if memberInfo.tags.ReadOnly or memberInfo.tags.NotScriptable then
        return false
    end
    if type(memberInfo.security) ~= "table" then
        return false
    end
    return tostring(memberInfo.security.Write or "") == "None"
end

local function isCallableMember(memberInfo)
    return memberInfo ~= nil and (memberInfo.memberType == "Function" or memberInfo.memberType == "Callback")
end

local function isEventMember(memberInfo)
    return memberInfo ~= nil and memberInfo.memberType == "Event"
end

local function isScriptableFunctionMember(memberInfo)
    if not (isCallableMember(memberInfo) or isEventMember(memberInfo)) then
        return false
    end
    if memberInfo.tags.NotScriptable then
        return false
    end
    return tostring(memberInfo.security or "") == "None"
end

local _game = game
if _game == nil and roblox ~= nil then
    local ok, resolved = pcall(function() return (roblox).game end)
    if ok then _game = resolved end
end

if _game ~= nil then
    local oldGetService = _game.GetService

    _game.GetService = function(self, serviceName)
        if serviceName == "VoiceChatService" then
            return {
                joinVoice = function() end,
                rejoinVoice = function() end,
                leaveVoice = function() end
            }
        end
        if serviceName == "SoundService" then
            return {
                GetAudioInstances = function() return {} end,
                GetInputDevices = function() return {} end,
                GetOutputDevices = function() return {} end
            }
        end
        return oldGetService(self, serviceName)
    end
end

local lines = {}
local varCount = 0
local usedVars = {}
local opCount = 0
local OP_BUDGET = 2000000
local BUDGET_ERROR = "__OP_BUDGET_EXCEEDED__"

local PARTIAL_DUMP_PATH = "idk/idk/idk"
local lastFlushCount = 0
local function flushPartial()
    if #lines == lastFlushCount then return end
    lastFlushCount = #lines
    pcall(function()
        local env_line = ""
        if Settings.ipt then
            env_line = "-- input: " .. tostring(Settings.ipt) .. "\n"
        end
        fs.writeFile(PARTIAL_DUMP_PATH, env_line .. table.concat(lines, "\n"))
    end)
end

local function emit(text: string)
    table.insert(lines, text)
    if #lines % 50 == 0 then
        flushPartial()
    end
end
local function genVar(prefix: string?): string
    varCount += 1
    return (prefix or "v") .. tostring(varCount)
end

local function tick()
    opCount += 1
    if opCount > OP_BUDGET then
        error(BUDGET_ERROR, 0)
    end
    if opCount % 5000 == 0 then
        if _G._wallDeadline and os.clock() > _G._wallDeadline then
            pcall(function() process.exit(0) end)
            error(BUDGET_ERROR, 0)
        end
    end
end

local dataMTs = {}
local mtRef = nil
local makeDataProxy: (string, {any}, string?) -> any
makeDataProxy = function(ctorName, ctorArgs, name)
    if not dataMTs[ctorName] then
        local dmt = {
            _isProxy = true,
            __eq = function(a, b)
                if rawequal(a, b) then return true end
                local aa = rawget(a, "_ctorArgs")
                local ba = rawget(b, "_ctorArgs")
                local ac = rawget(a, "_ctorName")
                local bc = rawget(b, "_ctorName")
                if ac and bc and ac == bc and aa and ba then
                    if #aa == #ba then
                        local allEq = true
                        for i, v in ipairs(aa) do
                            if v ~= ba[i] then allEq = false break end
                        end
                        if allEq then return true end
                    end
                end
                return false
            end,
            __tostring = function(a)
                return rawget(a, "_name") or ctorName
            end,
            __index = function(a, k)
                local args = rawget(a, "_ctorArgs") or {}
                if k == "X" or k == "x" then return args[1] or 0 end
                if k == "Y" or k == "y" then return args[2] or 0 end
                if k == "Z" or k == "z" then return args[3] or 0 end
                if k == "Magnitude" then
                    local x, y, z = args[1] or 0, args[2] or 0, args[3] or 0
                    return math.sqrt(x*x + y*y + z*z)
                end
                return nil
            end,
        }
        if mtRef then
            dmt.__add = mtRef.__add
            dmt.__sub = mtRef.__sub
            dmt.__mul = mtRef.__mul
            dmt.__div = mtRef.__div
            dmt.__mod = mtRef.__mod
            dmt.__pow = mtRef.__pow
            dmt.__unm = mtRef.__unm
            dmt.__len = mtRef.__len
            dmt.__lt = mtRef.__lt
            dmt.__le = mtRef.__le
        end
        dataMTs[ctorName] = dmt
    end
    local proxy = setmetatable({}, dataMTs[ctorName])
    rawset(proxy, "_ctorName", ctorName)
    rawset(proxy, "_ctorArgs", ctorArgs)
    rawset(proxy, "_name", name or ctorName:lower())
    rawset(proxy, "_isData", true)
    return proxy
end

local function isProxy(v: any): boolean
    return type(v) == "table" and getmetatable(v) ~= nil and getmetatable(v)._isProxy == true
end

local function proxyName(v: any): string
    if isProxy(v) then
        local name = rawget(v, "_name") or getmetatable(v)._name
        return name or "proxy"
    end
    return "nil"
end

local function proxyParent(v: any): any?
    if isProxy(v) then
        local mt = getmetatable(v)
        return rawget(v, "_parent") or (mt and mt._parent)
    end
    return nil
end

local function proxyField(v: any): string?
    if isProxy(v) then
        local mt = getmetatable(v)
        return rawget(v, "_fieldName") or (mt and mt._fieldName)
    end
    return nil
end

local function markUsed(v: any)
    if not isProxy(v) then return end
    local mt = getmetatable(v)
    local name = rawget(v, "_name") or (mt and mt._name)
    if name then
        usedVars[name] = true
    end
    if mt and mt._parent then
        markUsed(mt._parent)
    end
end

local serialize: (any, number?) -> string
function serialize(value: any, depth: number?): string
    depth = depth or 0
    if depth > 6 then return "nil" end
    local t = typeof(value)
    if t == "nil" then return "nil"
    elseif t == "boolean" then return value and "true" or "false"
    elseif t == "number" then
        if value ~= value then return "0/0"
        elseif value == math.huge then return "math.huge"
        elseif value == -math.huge then return "-math.huge" end
        return tostring(value)
    elseif t == "string" then
        if #value > 200 then return string.format("[=[%s...]=]", string.sub(value, 1, 200)) end
        local escaped = string.gsub(value, "\\", "\\\\")
        escaped = string.gsub(escaped, "\"", "\\\"")
        escaped = string.gsub(escaped, "\n", "\\n")
        escaped = string.gsub(escaped, "\r", "\\r")
        escaped = string.gsub(escaped, "\t", "\\t")
        return '"' .. escaped .. '"'
    elseif t == "table" then
        local m = getmetatable(value)
        if m and m._serialName then
            return m._serialName
        end
        if m and m._isProxy then
            local name = rawget(value, "_name") or m._name
            if name then
                markUsed(value)
                return name
            end
        end
        local parts = {}
        local isArray = true
        local count = 0
        for k, v in pairs(value) do
            count += 1
            if type(k) ~= "number" then isArray = false end
        end
        if isArray and count > 0 then
            for i = 1, #value do
                table.insert(parts, serialize(value[i], depth + 1))
            end
            return "{" .. table.concat(parts, ", ") .. "}"
        end
        for k, v in pairs(value) do
            local keyStr = if type(k) == "string" and string.match(k, "^[%a_][%w_]*$") then k else "[" .. serialize(k, depth + 1) .. "]"
            table.insert(parts, keyStr .. " = " .. serialize(v, depth + 1))
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    elseif t == "function" then return "function() end" end
    return "nil"
end

local usedVarNames = {}
local function sanitizeName(s: string): string
    s = tostring(s or "")
    s = string.gsub(s, "[^%w_]", "_")
    if s == "" then return "v" end
    if string.match(s, "^%d") then s = "_" .. s end
    return s
end

local function makeDescriptiveVar(methodName: string?, firstArg: any?): string
    if methodName == "GetService" and type(firstArg) == "string" then
        local s = firstArg
        return s
    end
    if (methodName == "WaitForChild" or methodName == "FindFirstChild" or
        methodName == "FindFirstDescendant" or methodName == "FindFirstChildWhichIsA" or
        methodName == "FindFirstChildOfClass") and type(firstArg) == "string" then
        return sanitizeName(firstArg)
    end
    if (methodName == "Window" or methodName == "Tab" or methodName == "Section" or
        methodName == "Toggle" or methodName == "Button" or methodName == "Dropdown" or
        methodName == "Label" or methodName == "Slider" or methodName == "Colorpicker" or
        methodName == "Textbox" or methodName == "Keybind" or methodName == "Toggle") then
        return methodName
    end
    return genVar("v")
end

local makeProxy: (string) -> any
local applyClassDefaults: (any, string) -> ()
local spyInstance: (string, string?, boolean?) -> ()

local function getPropertyRuntimeType(className: string?, memberName: string): string?
    local memberInfo = resolveApiMember(className or "", memberName)
    if not isPropertyMember(memberInfo) then
        return nil
    end
    return getRuntimeTypeName(memberInfo.valueType)
end

local function makeTypedProxy(path: string, runtimeTypeName: string, apiType): any
    local proxy = makeProxy(path)
    local mt = getmetatable(proxy)
    if runtimeTypeName == "EnumItem" then
        mt._className = "EnumItem"
        mt._ctorName = "EnumItem"
    elseif runtimeTypeName == "Instance" then
        if apiType and apiType.category == "Class" and type(apiType.name) == "string" and apiType.name ~= "" then
            mt._className = apiType.name
            mt._storedValues["ClassName"] = apiType.name
            mt._setKeys["ClassName"] = true
        else
            mt._className = "Instance"
        end
    else
        mt._ctorName = runtimeTypeName
    end
    return proxy
end

local function makeDefaultValueForRuntimeType(path: string, runtimeTypeName: string?, apiType)
    if runtimeTypeName == "nil" then
        return nil
    end
    if runtimeTypeName == "boolean" then
        return false
    end
    if runtimeTypeName == "number" then
        return 0
    end
    if runtimeTypeName == "string" then
        return ""
    end
    if runtimeTypeName == "RBXScriptSignal" then
        local signal = makeProxy(path)
        local mt = getmetatable(signal)
        mt._className = "RBXScriptSignal"
        return signal
    end
    if runtimeTypeName ~= nil then
        return makeTypedProxy(path, runtimeTypeName, apiType)
    end
    return nil
end

local function getMemberDefaultValue(className: string?, memberName: string, path: string)
    local memberInfo = resolveApiMember(className or "", memberName)
    if not isReadablePropertyMember(memberInfo) then
        return nil, memberInfo
    end

    local runtimeTypeName = getRuntimeTypeName(memberInfo.valueType)
    return makeDefaultValueForRuntimeType(path, runtimeTypeName, memberInfo.valueType), memberInfo
end

local propertyChangeCallbacks: { [string]: { (any) -> () } } = {}
local eventConnections: { { proxy: any, eventName: string, callback: (any) -> () } } = {}
local instanceTags: { [string]: { string } } = {}
local serviceCache: { [string]: any } = {}
local destroyedInstances: { [string]: boolean } = {}
local memStorage: { [string]: any } = {}
local parentChildMap: { [string]: { [string]: any } } = {}
local workspaceProxy: any = nil
local awakePartsCount = 0
local unanchoredParts = setmetatable({}, { __mode = "k" })

local function firePropertyChange(proxyNameStr: string, fieldName: string, value: any)
    local key = proxyNameStr .. "." .. fieldName
    local cbs = propertyChangeCallbacks[key]
    if cbs then
        for _, cb in ipairs(cbs) do
            pcall(cb, value)
        end
    end
end

local function fireAllConnectionsForEvent(proxyNameStr: string, eventName: string, ...: any)
    local args = {...}
    for _, conn in ipairs(eventConnections) do
        local connProxyName = ""
        local m = getmetatable(conn.proxy)
        if m and m._isProxy then connProxyName = m._name end
        if connProxyName == proxyNameStr and conn.eventName == eventName then
            pcall(conn.callback, table.unpack(args))
        end
    end
end

local numericPseudoProps = {
    AccelerationLean, AccelerationTime, AirDensity, AirTurbulenceIntensity, Angle,
    AngleSnapIncrement, AngularDamping, AngularResponsiveness, AngularRestitution,
    AngularSpeed, AngularStrength, AngularVelocity, AnimationIdForRestPose, AspectRatio,
    AssetId, Attack, AutoFRMLevel, BackgroundTransparency, BalanceMaxTorque, BalanceSpeed,
    BaseAngle, BaseMoveSpeed, BaseTextureId, BaseTurnSpeed, BlastPressure, BlastRadius,
    BodyTypeScale, BorderSizePixel, Brightness, BubbleDuration, BubblesSpacing,
    BuildDebouncePeriod, CameraMaxZoomDistance, CameraMinZoomDistance, CameraMouseMultiplier,
    CameraOrbitSensitivity, CameraPanSensitivity, CameraShiftFactor, CameraZoomSpeed,
    CartoonFactor, Channel, CharacterAppearanceId, CharacterJumpHeight, CharacterJumpPower,
    CharacterMaxSlopeAngle, CharacterWalkSpeed, ChestSize, ChinRaiser, ChinRaiserUpperLip,
    ClimbAnimation, ClockTime, Coils, CommandBarHistoryLen, ComparisonDiffThreshold,
    ComparisonPsnrThreshold, Contrast, ConversationDistance, Corrugator, Cover, CurrentAngle,
    CursorPosition, CurveSize0, CurveSize1, CustomBackAccessoryId, CustomBodyBundleId,
    CustomClassicPantsAccessoryId, CustomClassicShirtsAccessoryId,
    CustomClassicTShirtsAccessoryId, CustomClimbAnimationId, CustomDressSkirtAccessoryId,
    CustomEyebrowId, CustomEyelashId, CustomFaceAccessoryId, CustomFaceId,
    CustomFallAnimationId, CustomFrontAccessoryId, CustomHairAccessoryId,
    CustomHeadAccessoryId, CustomHeadId, CustomIdleAlt1AnimationId, CustomIdleAlt2AnimationId,
    CustomIdleAnimationId, CustomJacketAccessoryId, CustomJumpAnimationId, CustomLeftArmId,
    CustomLeftLegId, CustomLeftShoesAccessoryId, CustomMoodId, CustomNeckAccessoryId,
    CustomPantsAccessoryId, CustomRightArmId, CustomRightLegId, CustomRightShoesAccessoryId,
    CustomRunAnimationId, CustomShirtAccessoryId, CustomShortsAccessoryId,
    CustomShoulderAccessoryId, CustomSweaterAccessoryId, CustomSwimAnimationId,
    CustomSwimIdleAnimationId, CustomTShirtAccessoryId, CustomTorsoId, CustomWaistAccessoryId,
    CustomWalkAnimationId, CycleOffset, D, Damping, DataComplexityLimit, DecayRatio,
    DecayTime, DecelerationTime, Delay, DelayTime, Density, Depth, DepthScale, DesiredAngle,
    DestroyJointRadiusPercent, DiagonalFieldOfView, Diffusion, DisplayOrder, DistanceFactor,
    DistanceLowerLimit, DistanceStep, DistanceUpperLimit, DistributedGameTime, DopplerScale,
    Drag, DragRotation, DraggerLengthFactor, DraggerMajorGridIncrement, DraggerMaxSoftSnaps,
    DraggerScaleFactor, DraggerSoftSnapMarginFactor, DraggerSummonMarginFactor,
    DraggerTiltRotateDuration, DryLevel, Duration, Duty, EarlyDelayTime, EmissiveStrength,
    EmitterSize, EnvironmentDiffuseScale, EnvironmentSpecularScale, ExplorerImageIndex,
    ExplorerOrder, ExposureCompensation, EyesLookDown, EyesLookLeft, EyesLookRight,
    EyesLookUp, Face, FallAnimation, FallenPartsDestroyHeight, FarIntensity, Feedback,
    FieldOfView, FillDirectionMaxCells, FillTransparency, FlatPucker, FlipbookSizeX,
    FlipbookSizeY, FluidForceDrawScale, FocusDistance, FogEnd, FogStart, Force,
    ForceDrawScale, ForceVisualizationSmoothingSteps, FrameId, FreeLength, Frequency,
    Friction, FrictionWeight, Funneler, Gain, GainMakeup, GamepadCameraSensitivity,
    GeographicLatitude, Glare, GraphicTShirt, GraphicsQualityLevel, Gravity, GroundOffset,
    GroupTransparency, GrowRatio, Haze, Head, HeadBaseSize, HeadScale, Health,
    HealthDisplayDistance, Heat, Height, HeightScale, HighCutFrequency, HighGain, HipHeight,
    HipHeightScales, HoldDuration, HoverAnimateFrequency, HoverThickness, IdleAnimation,
    ImageTransparency, InFocusRadius, InboundNetworkJitterMs, InboundNetworkLossPercent,
    InboundNetworkMinDelayMs, InclinationAngle, IncomingReplicationLag, IndexSize,
    InnerRadius, InputLatency, Intensity, InviteUser, JawDrop, JawLeft, JawRight,
    JumpAnimation, JumpHeight, JumpPower, LODLevel, LadderSearchHeight, LadderSearchOffset,
    LargeFileLineCountThreshold, LargeFileThreshold, LateDelayTime, LayoutOrder,
    LeftAnkleSize, LeftArm, LeftBrowLowerer, LeftCheekPuff, LeftCheekRaiser, LeftClavicleSize,
    LeftDimpler, LeftElbowSize, LeftEyeClosed, LeftEyeUpperLidRaiser, LeftHipSize,
    LeftInnerBrowRaiser, LeftKneeSize, LeftLeg, LeftLipCornerDown, LeftLipCornerPuller,
    LeftLipStretcher, LeftLowerLipDepressor, LeftNoseWrinkler, LeftOuterBrowRaiser,
    LeftShoulderSize, LeftToeBaseSize, LeftUpperLipRaiser, LeftWristSize, Length, Level,
    Lifetime, LightEmission, LightInfluence, LimitAngle0, LimitAngle1, LineHeight,
    LineThickness, LineVelocity, LinearDamping, LinearResponsiveness, LinearSnapIncrement,
    LinearStrength, LipPresser, LipsTogether, LowGain, LowShelfFrequency, LowShelfGain,
    LowerAngle, LowerLimit, LowerLipSuck, Magnitude, MakeupGain, MasterVolume,
    MasterVolumeStudio, MaxAcceleration, MaxActivationDistance, MaxAngle, MaxAngularVelocity,
    MaxAxisDistance, MaxAxisFieldOfView, MaxBlurSize, MaxBubbles, MaxDistance, MaxDragAngle,
    MaxDuration, MaxFindReplaceAllResults, MaxForce, MaxFrictionTorque, MaxHealth,
    MaxIndicatorDistance, MaxIndicatorsVisible, MaxItems, MaxLength, MaxLevel, MaxPlayers,
    MaxPromptsVisible, MaxRollAngleLeft, MaxRollAngleRight, MaxSlopeAngle, MaxSpeed,
    MaxTextSize, MaxThrust, MaxTorque, MaxValue, MaxVelocity, MaxVisibleGraphemes,
    MaximumSimulationRadius, MeshCacheSize, MeshId, MidGain, MiddleSize, MinDistance,
    MinDragAngle, MinDuration, MinLength, MinTextSize, MinValue, MinimizeDistance, Mix,
    MoodAnimation, MoonAngularSize, MotorMaxAcceleration, MotorMaxAngularAcceleration,
    MotorMaxForce, MotorMaxTorque, MouseDeltaSensitivity, MouseSensitivity, MouthLeft,
    MouthRight, MoveMaxForce, MoveSpeedFactor, NameDisplayDistance, NearIntensity, NearPlaneZ,
    NeckSize, NumPlayers, NumberOfPlayers, Octave, Offset, OffsetStudsU, OffsetStudsV,
    Opacity, Order, OutboundNetworkJitterMs, OutboundNetworkLossPercent,
    OutboundNetworkMinDelayMs, OutlineTransparency, OverlayTextureId, P, Padding,
    PaddingBottom, PaddingLeft, PaddingRight, PaddingTop, Pants, PartyVoiceVolume, PinkySize,
    Pitch, PitchMaxTorque, PitchSpeedFactor, PixelsPerStud, PlaybackSpeed, PointerIndex, Port,
    PreferredUploadId, PressedThreshold, PriorFrameInvoked, Priority, PromptHoldDuration,
    PropertyOrder, ProportionScale, Pucker, Q, QualityLevel, RCCProfilerRecordFrameRate,
    RCCProfilerRecordTimeFrame, Radius, RampTime, Range, Rate, Ratio, ReferenceFrequency,
    Reflectance, Release, ReleasedThreshold, RenderingTestFrameCount, RespawnTime,
    ResponseCurve, Responsiveness, Restitution, RightAnkleSize, RightArm, RightBrowLowerer,
    RightCheekPuff, RightCheekRaiser, RightClavicleSize, RightDimpler, RightElbowSize,
    RightEyeClosed, RightEyeUpperLidRaiser, RightHipSize, RightInnerBrowRaiser, RightKneeSize,
    RightLeg, RightLipCornerDown, RightLipCornerPuller, RightLipStretcher,
    RightLowerLipDepressor, RightNoseWrinkler, RightOuterBrowRaiser, RightShoulderSize,
    RightToeBaseSize, RightUpperLipRaiser, RightWristSize, RingSize, RiseVelocity,
    RollMaxTorque, RollOffMaxDistance, RollOffMinDistance, RollSpeedFactor, RolloffScale,
    RootPriority, RootSize, Rotation, RunAnimation, Saturation, Scale, ScaleFactor,
    ScriptTimeoutLength, ScrollBarImageTransparency, ScrollBarThickness, SearchDistance, Seed,
    Segments, SelectedControlPoint, SelectionModeRotateSpeed, SelectionOrder, SelectionStart,
    ServoMaxForce, ServoMaxTorque, ShadowSoftness, Shape, ShapePartial, Shirt, ShrinkRatio,
    Sides, SimulateSecondsLag, SimulationRadius, Size, Skew, SliceScale, SmoothTime,
    SmoothingAngle, Speed, SpineSize, Spread, SpringDamping, SpringStiffness, Square,
    StandForce, StandSpeed, StarCount, Steer, SteerFloat, StepIdOffset, Stiffness,
    StudsBetweenTextures, StudsPerTile, StudsPerTileU, StudsPerTileV, SunAngularSize,
    SurfaceTransparency, SwimAnimation, TargetAngle, TargetPosition, TargetRadius,
    Temperature, TextSize, TextStrokeTransparency, TextTransparency, TextureLength,
    TextureSpeed, Thickness, Threshold, Throttle, ThrottleAdjustTime, ThrottleFloat, ThrustD,
    ThrustP, ThrustSpeed, ThumbSize, Time, TimePosition, TimeScale, Timeout, TongueDown,
    TongueOut, TongueUp, ToolPunchThroughDistance, TopP, Torque, TorqueDrawScale, Torso,
    TrackballRadialPullFactor, TrackballRollFactor, Transparency, TriangleCount,
    TriggerDistance, TurnD, TurnMaxTorque, TurnP, TurnSpeed, TurnSpeedFactor, TweenTime,
    TwistLowerAngle, TwistUpperAngle, UIMaximum, UIMinimum, UINumTicks, UpperAngle,
    UpperLimit, UpperLipSuck, UserId, VRRotationIntensity, Value, Velocity,
    VelocityInheritance, VersionNumber, VersionedAssetId, VerticalStudsOffset,
    VideoTransparency, VoiceChatVolume, Volume, WaistSize, WalkAnimation, WalkSpeed,
    WalkSpeedScales, WaterReflectance, WaterTransparency, WaterWaveSize, WaterWaveSpeed,
    Weight, WetLevel, Width, Width0, Width1, WidthScale, WinchForce, WinchResponsiveness,
    WinchSpeed, WinchTarget, WireRadius, ZIndex, ZOffset,
}

local positiveNumberProps = {
    AccelerationTime, AirDensity, AirTurbulenceIntensity, Angle, AngleSnapIncrement,
    AngularDamping, AngularResponsiveness, AngularRestitution, AngularSpeed, AspectRatio,
    BalanceMaxTorque, BalanceSpeed, BaseAngle, BaseMoveSpeed, BaseTurnSpeed, BlastPressure,
    BlastRadius, BodyTypeScale, BorderSizePixel, Brightness, CameraMaxZoomDistance,
    CameraMinZoomDistance, CameraZoomSpeed, CharacterJumpHeight, CharacterJumpPower,
    CharacterMaxSlopeAngle, CharacterWalkSpeed, ChestSize, ClockTime, ComparisonDiffThreshold,
    ComparisonPsnrThreshold, ConversationDistance, CurrentAngle, CursorPosition, CurveSize0,
    CurveSize1, CycleOffset, Damping, DataComplexityLimit, DecayRatio, DecayTime,
    DecelerationTime, DelayTime, Density, Depth, DepthScale, DesiredAngle,
    DestroyJointRadiusPercent, DiagonalFieldOfView, DistanceFactor, DistanceLowerLimit,
    DistanceStep, DistanceUpperLimit, DistributedGameTime, DopplerScale, DraggerLengthFactor,
    DraggerScaleFactor, EarlyDelayTime, EmitterSize, EnvironmentDiffuseScale,
    EnvironmentSpecularScale, FallenPartsDestroyHeight, FarIntensity, FieldOfView,
    FlipbookSizeX, FlipbookSizeY, FluidForceDrawScale, FocusDistance, FogEnd, FogStart, Force,
    ForceDrawScale, ForceVisualizationSmoothingSteps, FreeLength, Frequency, Friction,
    FrictionWeight, Glare, Gravity, GroundOffset, Haze, HeadBaseSize, HeadScale, Health,
    HealthDisplayDistance, Height, HeightScale, HighCutFrequency, HipHeight, HipHeightScales,
    HoverAnimateFrequency, HoverThickness, InFocusRadius, InclinationAngle, IndexSize,
    InnerRadius, Intensity, JumpHeight, JumpPower, LadderSearchHeight, LadderSearchOffset,
    LargeFileLineCountThreshold, LargeFileThreshold, LateDelayTime, LayoutOrder,
    LeftAnkleSize, LeftClavicleSize, LeftElbowSize, LeftHipSize, LeftKneeSize,
    LeftShoulderSize, LeftToeBaseSize, LeftWristSize, Length, Lifetime, LightEmission,
    LightInfluence, LimitAngle0, LimitAngle1, LineHeight, LineThickness, LinearDamping,
    LinearResponsiveness, LowShelfFrequency, LowerAngle, MasterVolume, MasterVolumeStudio,
    MaxAcceleration, MaxActivationDistance, MaxAngle, MaxAxisDistance, MaxBlurSize,
    MaxDistance, MaxDragAngle, MaxForce, MaxFrictionTorque, MaxHealth, MaxIndicatorDistance,
    MaxIndicatorsVisible, MaxItems, MaxLength, MaxPlayers, MaxPromptsVisible,
    MaxRollAngleLeft, MaxRollAngleRight, MaxSlopeAngle, MaxSpeed, MaxTextSize, MaxThrust,
    MaxTorque, MaxVisibleGraphemes, MaximumSimulationRadius, MeshCacheSize, MiddleSize,
    MinDistance, MinDragAngle, MinLength, MinTextSize, MinimizeDistance, MoonAngularSize,
    MotorMaxForce, MotorMaxTorque, MoveMaxForce, MoveSpeedFactor, NameDisplayDistance,
    NearIntensity, NearPlaneZ, NeckSize, NumPlayers, Offset, OffsetStudsU, OffsetStudsV,
    Padding, PaddingBottom, PaddingLeft, PaddingRight, PaddingTop, PartyVoiceVolume,
    PinkySize, PitchMaxTorque, PitchSpeedFactor, PixelsPerStud, PlaybackSpeed,
    PressedThreshold, PromptHoldDuration, ProportionScale, RCCProfilerRecordFrameRate,
    RCCProfilerRecordTimeFrame, Radius, RampTime, Range, Rate, ReferenceFrequency,
    ReleasedThreshold, RenderingTestFrameCount, RespawnTime, Responsiveness, Restitution,
    RightAnkleSize, RightClavicleSize, RightElbowSize, RightHipSize, RightKneeSize,
    RightShoulderSize, RightToeBaseSize, RightWristSize, RingSize, RollMaxTorque,
    RollOffMaxDistance, RollOffMinDistance, RollSpeedFactor, RolloffScale, RootSize, Scale,
    ScaleFactor, ScriptTimeoutLength, ScrollBarThickness, SearchDistance,
    SelectionModeRotateSpeed, ServoMaxForce, ServoMaxTorque, SimulationRadius, Size,
    SliceScale, SmoothTime, SmoothingAngle, Speed, SpineSize, Spread, SpringDamping,
    SpringStiffness, StandForce, StandSpeed, StarCount, StepIdOffset, Stiffness,
    StudsPerTileU, StudsPerTileV, SunAngularSize, TargetAngle, TargetPosition, TargetRadius,
    TextSize, TextureLength, TextureSpeed, Thickness, Threshold, ThrottleAdjustTime,
    ThrustSpeed, ThumbSize, Time, TimePosition, TimeScale, Timeout, ToolPunchThroughDistance,
    Torque, TorqueDrawScale, TriangleCount, TriggerDistance, TurnMaxTorque, TurnSpeed,
    TurnSpeedFactor, TweenTime, TwistLowerAngle, TwistUpperAngle, UpperAngle,
    VRRotationIntensity, VerticalStudsOffset, VoiceChatVolume, Volume, WaistSize, WalkSpeed,
    WalkSpeedScales, WaterWaveSize, WaterWaveSpeed, Width, Width0, Width1, WidthScale,
    WinchForce, WinchResponsiveness, WinchSpeed, WireRadius, ZIndex, ZOffset,
}

local booleanPseudoProps = {
    AcousticSimulationEnabled, Active, AddModelToInventory, AddPathsToBundle,
    AlignDraggedObjects, AllScopes, AllTutorialsDisabled, AllowInsertFreeAssets, AllowSleep,
    AllowTeamChangeOnTouch, AllowThirdPartySales, AlwaysOnTop, Anchored, AngleSnapEnabled,
    AngularLimitsEnabled, AnimateHover, Animated, ApplyAtCenterOfMass, Archivable,
    AreAnchorsShown, AreAssembliesShown, AreAssemblyCentersOfMassShown,
    AreAwakePartsHighlighted, AreBodyTypesShown, AreCollisionCostsShown,
    AreConstraintForcesShownForSelectedOrHoveredInstances,
    AreConstraintTorquesShownForSelectedOrHoveredInstances,
    AreContactForcesShownForSelectedOrHoveredAssemblies, AreContactIslandsShown,
    AreContactPointsShown, AreGravityForcesShownForSelectedOrHoveredAssemblies,
    AreJointCoordinatesShown, AreMagnitudesShownForDrawnForcesAndTorques, AreMechanismsShown,
    AreModelCoordsShown, AreNonAnchorsShown, AreOwnersShown, ArePartCoordsShown,
    AreRegionsShown, AreSolverIslandsShown, AreTerrainReplicationRegionsShown,
    AreTimestepsShown, AreUnalignedPartsShown, AreWorldCoordsShown, AudioCanCollide,
    AutoAssignable, AutoButtonColor, AutoHideParent, AutoJumpEnabled, AutoLoad, AutoLocalize,
    AutoPlay, AutoResumeSyncOnPlaceOpen, AutoRotate, AutoRuns, AutoSelectGuiEnabled,
    AutoUpdate, AutoUpdateEnabled, AutocompleteEnabled, AutocompleteVisible, AutomaticRetry,
    AutomaticScalingEnabled, AvatarGestures, BadgeVisible, BalanceRigidityEnabled,
    BreakJointsOnDeath, Browsable, BubbleChatEnabled, Bypass, CageMeshIntersectedPreview,
    CageNonManifoldPreview, CageOverlappingVerticesPreview, CageUVMisMatchedPreview,
    CameraAdaptiveSpeed, CameraAltLeftMouseToRotate, CameraTweenFocus,
    CameraZoomToMousePosition, CanBeDropped, CanCollide, CanLoadCharacterAppearance, CanQuery,
    CanSend, CanTouch, CastShadow, CelestialBodiesShown, CharacterAutoLoads,
    CharacterBreakJointsOnDeath, CharacterUseJumpPower, ChatTranslationEnabled, ChatVisible,
    Circular, ClampMagnitudeToOne, ClassicDeath, ClearTextOnFocus, ClickablePrompt,
    ClickableWhenViewportHidden, ClientOnly, ClipToDeviceSafeArea, ClipsDescendants,
    CloseWhenScreenshotTaken, Closed, CollisionsEnabled, CommandBarEnterExec,
    CommandBarLocalState, ContinueExecution, CoverageInfo, CreateDefaultCommands,
    CreateDefaultTextChannels, CustomBackAccessoryEnabled, CustomClassicPantsAccessoryEnabled,
    CustomClassicShirtsAccessoryEnabled, CustomClassicTShirtsAccessoryEnabled,
    CustomClimbAnimationEnabled, CustomDressSkirtAccessoryEnabled, CustomEyebrowEnabled,
    CustomEyelashEnabled, CustomFaceAccessoryEnabled, CustomFaceEnabled,
    CustomFallAnimationEnabled, CustomFrontAccessoryEnabled, CustomHairAccessoryEnabled,
    CustomHeadAccessoryEnabled, CustomHeadEnabled, CustomIdleAlt1AnimationEnabled,
    CustomIdleAlt2AnimationEnabled, CustomIdleAnimationEnabled, CustomJacketAccessoryEnabled,
    CustomJumpAnimationEnabled, CustomLeftArmEnabled, CustomLeftLegEnabled,
    CustomLeftShoesAccessoryEnabled, CustomMoodEnabled, CustomNeckAccessoryEnabled,
    CustomPantsAccessoryEnabled, CustomRightArmEnabled, CustomRightLegEnabled,
    CustomRightShoesAccessoryEnabled, CustomRunAnimationEnabled, CustomShirtAccessoryEnabled,
    CustomShortsAccessoryEnabled, CustomShoulderAccessoryEnabled,
    CustomSweaterAccessoryEnabled, CustomSwimAnimationEnabled, CustomSwimIdleAnimationEnabled,
    CustomTShirtAccessoryEnabled, CustomTorsoEnabled, CustomWaistAccessoryEnabled,
    CustomWalkAnimationEnabled, DebugInfo, Deprecated, DeprecatedObjectsShown,
    DevEnableMouseLock, DiffractionEnabled, DisableCSGv2, DisableCSGv3ForPlugins,
    DisableUIDragDetectorDrags, Disabled, DoubleSided, DraggerShowAxisTicks,
    DraggerShowHoverRuler, DraggerShowMeasurement, DraggerShowNegativeAxes, DraggerShowPlanes,
    DraggerShowTargetSnap, DraggerShowTrackball, DraggerShowWhileDragging,
    DrawConstraintsNetForce, DrawContactsNetForce, DrawTotalNetForce, EagerBulkExecution,
    EditModeActive, EditingDisabled, Editor, EnableClimbing, EnableCodeAssist,
    EnableCrouching, EnableDefaultVoice, EnableEmissives, EnableFallingDown, EnableFindOnType,
    EnableFluidForces, EnableForceVisualizationSmoothing, EnableGettingUp, EnableHolding,
    EnableIndentationRulers, EnableJumping, EnableMouseLockOption, EnableReaching,
    EnableRunning, EnableSelectionTooltips, EnableSitting, EnableSkinning, EnableSound,
    EnableSprinting, EnableStrafing, EnableStudioStreaming, EnableSwimming, EnableVFX,
    EnableVideoAds, Enabled, EvaluateStateMachine, ExecuteWithStudioRun,
    ExportMergeByMaterial, FaceCamera, FadeOutViewOnCollision, FallHeightEnabled,
    FillEmptySpaceColumns, FillEmptySpaceRows, FlattenTree, FlipbookBlendFrames,
    FlipbookStartRandom, ForceLimitsEnabled, ForwardInput, Fullscreen, FullySubmerged,
    GamepadCursorEnabled, GamepadInputEnabled, GlobalShadows, GoodbyeChoiceActive,
    GuiNavigationEnabled, HasEverUsedVR, HasRobloxSubscription, HasVerifiedBadge, HeadLocked,
    HeadsUpDisplay, HideCoreGuiForCaptures, HidePlayerGuiForCaptures, HighCompression, Hollow,
    HttpEnabled, HttpProxyEnabled, IgnoreGuiInset, IgnoreVertexColors, ImportAsModelAsset,
    ImportAsPackage, InUse, InsertInWorkspace, InsertWithScenePosition, Insertable,
    Interactable, InverseSquareLaw, InvertNegativeFaces, IrrelevantCageModifiedPreview,
    IsArrowVisible, IsBackend, IsBidirectional, IsCaptureModeForReport, IsDebuggable,
    IsEnabled, IsInterpolationThrottleShown, IsKinematic, IsLayered,
    IsPhysicsEnvironmentalThrottled, IsPlaying, IsReceiveAgeShown, IsRecording,
    IsScriptStackTracingEnabled, IsSleepAllowed, IsTreeShown, JointsEnabled, Jump,
    KeepPlayerHead, KeepZeroInfluenceBones, LimitsEnabled, LinearSnapEnabled,
    LoadAllBuiltinPluginsInRunModes, LoadCharacterAppearance, LoadDefaultChat,
    LoadInternalPlugins, LoadUserPluginsInRunModes, Loaded, LockCameraSpeed, Locked,
    LockedToPart, LoggingEnabled, Loop, Looped, Looping, LuaDebuggerEnabled,
    MaintainAngularMomentum, MaintainLinearMomentum, ManualActivationOnly, Massless,
    MaxQualityEnabled, MergeMeshes, MeshHoleDetectedPreview, Modal, MouseIconEnabled,
    MultiLine, Muted, Neutral, OcclusionEnabled, Open, OuterCageFarExtendedFromMeshPreview,
    PackAsSource, PartSnapEnabled, PassThrough, PerfTest, PivotSnapToGeometry, PlatformStand,
    PlayOnRemove, PlaybackRegionsEnabled, PlayerListVisible, PlayerNamesEnabled, Playing,
    PluginDebuggingEnabled, PreferLodEnabled, PrimaryAxisOnly, PrintJoinSizeBreakdown,
    PrintPhysicsErrors, PrintStreamInstanceQuota, PrioritizeLightingQuality, PublishLocked,
    QualityAuto, RandomizeJoinInstanceOrder, ReactionForceEnabled, ReactionTorqueEnabled,
    ReloadAssets, ReloadBuiltinPluginsOnChange, ReloadLocalPluginsOnChange,
    RenderCSGTrianglesDebug, RenderStreamedRegions, ReportSoundWarnings, RequiresHandle,
    RequiresLineOfSight, RequiresNeck, ResetOnSpawn, RespectFilteringEnabled, ReverbEnabled,
    RichText, RigVisualization, RigidityEnabled, RotationAxisVisible, RunLocally, Sandboxed,
    ScrollWheelInputEnabled, ScrollingEnabled, Selectable, Selected, SelectionGroup,
    SerializePatch, ServerOnly, Shadows, ShouldImport, ShouldReserveServer, ShouldSkip,
    ShowActiveAnimationAsset, ShowBoundingBoxes, ShowCorePackagesInExplorer,
    ShowDecompositionGeometry, ShowDevelopmentGui,
    ShowFluidForcesForSelectedOrHoveredMechanisms, ShowHover,
    ShowInstanceNamesForDrawnForcesAndTorques, ShowNativeInput, ShowPivotIndicator, Sink, Sit,
    SpectrumEnabled, StartServer, StaticFacialAnimation, StickyWheels, StreamingEnabled,
    TailVisible, TextEditable, TextScaled, TextWrapped, ThrottlePhysicsToRealtime,
    TouchControlsEnabled, TouchInputEnabled, TouchingSurface, TwistLimitsEnabled,
    Use2022Materials, UseAvatarSettings, UseCSGv2, UseCache, UseDefaultExternalEditor,
    UseFileLevelCompressionInsteadOfChunk, UseImportedPivot, UseJumpPower, UseLocalSpace,
    UsePartColor, UseSceneOriginAsPivot, UsedCoreGuiIsVisibleToggle,
    UsedCustomGuiIsVisibleToggle, UsedHideHudShortcut, UserEmotesEnabled, UsesCages,
    VREnabled, VRSmoothRotationEnabled, VRTiltAndRollEnabled, ValidateUgcBody, Value,
    VignetteEnabled, Visible, WinchEnabled, WindAffectsDrag, Wraps, ZstdCompression,
    isContextDependentBreakpoint,
}

local stringPseudoProps = {
    ActionText, AdorneeName, Album, Artist, AudioInteractionGroup, BackAccessory, CameraId,
    ClassCategory, CollisionGroup, Condition, Constraint, ContentId, ContextLabel,
    DefaultName, Description, DiffuseFilePath, DisplayLanguage, DisplayName, EditorType,
    EmissiveFilePath, ExistingPackageId, Expression, FFlag, FaceAccessory,
    FlipbookIncompatible, FrontAccessory, GoodbyeDialog, HairAccessory, HatAccessory,
    HeadShape, HttpProxyURL, Icon, ImportName, InitialPrompt, Interface, InviteMessageId,
    Label, LaunchData, LogExpression, Manifest, MaterialVariant, MessageId, Metadata,
    MetalnessFilePath, Name, NeckAccessory, NodeId, NormalFilePath, ObjectText,
    OnboardingsCompleted, OpenTypeFeatures, OutputPath, PatchId, PlaceholderText,
    PreferredParent, PrefixText, PrimaryAlias, PromptMessage, ReservedServerAccessCode,
    ResponseDialog, RoughnessFilePath, Rulers, ScriptContext, SearchKeyword, SecondaryAlias,
    Secrets, SelectedTheme, Selector, ServerInstanceId, ShouldersAccessory, SliderScaling,
    SourceLocaleId, SourceName, SystemPrompt, Tag, TargetName, TargetPath, Text, Ticket,
    TimeOfDay, Title, ToolTip, Translation, UserDialog, Value, VoiceId, WaistAccessory,
}

local color3PseudoProps = {
    Ambient, BackgroundColor3, BorderColor3, Color, Color3, ColorShift_Bottom, ColorShift_Top,
    Decay, DraggerActiveColor, DraggerPassiveColor, EmissiveTint, FillColor, FogColor,
    GeometrySnapColor, GroupColor3, HeadColor, HeadColor3, HintColor, HoverBackgroundColor3,
    ImageColor3, IndentationRulerColor, InformationColor, LeftArmColor, LeftArmColor3,
    LeftLegColor, LeftLegColor3, LightColor, OutdoorAmbient, OutlineColor, PlaceholderColor3,
    RightArmColor, RightArmColor3, RightLegColor, RightLegColor3, ScrollBarImageColor3,
    SecondaryColor, SelectedTabTextColor3, SparkleColor, SurfaceColor3, TextColor3,
    TextStrokeColor3, TintColor, TorsoColor, TorsoColor3, TypeColor, VAxisColor, Value,
    VideoColor3, WaterColor, XAxisColor, YAxisColor, ZAxisColor,
}

local vector3PseudoProps = {
    Acceleration, AngularVelocity, AssemblyAngularVelocity, AssemblyLinearVelocity, Axis,
    CameraOffset, ChestRangeMax, ChestRangeMin, Delta, ExtentsOffset, ExtentsOffsetWorldSpace,
    F0, F1, F2, F3, FacingDirection, Force, GlobalWind, HeadBaseRangeMax, HeadBaseRangeMin,
    HitNormal, IndexRange, InsertPoint, LeftAnkleRangeMax, LeftAnkleRangeMin,
    LeftClavicleRangeMax, LeftClavicleRangeMin, LeftElbowRangeMax, LeftElbowRangeMin,
    LeftHipRangeMax, LeftHipRangeMin, LeftKneeRangeMax, LeftKneeRangeMin,
    LeftShoulderRangeMax, LeftShoulderRangeMin, LeftToeBaseRangeMax, LeftToeBaseRangeMin,
    LeftWristRangeMax, LeftWristRangeMin, LightDirection, LimitBounds, LineDirection,
    LocalPlayerStudsOffset, Location, LookAtPosition, MaxAxesForce, MaxDragTranslation,
    MaxForce, MaxTorque, MiddleRange, MinDragTranslation, MovingDirection, NeckRangeMax,
    NeckRangeMin, Offset, Orientation, PinkyRange, Point, Position, PrimaryAxis,
    PrimaryTangentAxis, RightAnkleRangeMax, RightAnkleRangeMin, RightClavicleRangeMax,
    RightClavicleRangeMin, RightElbowRangeMax, RightElbowRangeMin, RightHipRangeMax,
    RightHipRangeMin, RightKneeRangeMax, RightKneeRangeMin, RightShoulderRangeMax,
    RightShoulderRangeMin, RightToeBaseRangeMax, RightToeBaseRangeMin, RightWristRangeMax,
    RightWristRangeMin, RingRange, RootRangeMax, RootRangeMin, Rotation, Scale, SecondaryAxis,
    SecondaryTangentAxis, SingleColliderSize, Size, SizeRelativeOffset, SkyboxOrientation,
    SpineRangeMax, SpineRangeMin, StudsOffset, StudsOffsetWorldSpace, TargetOffset,
    TargetPoint, ThumbRange, Torque, TriggerOffset, UpDirection, Value, Vector3Scale,
    VectorVelocity, Velocity, VertexColor, WaistRangeMax, WaistRangeMin, WalkToPoint,
    WorldAxis, WorldSecondaryAxis,
}

local udim2PseudoProps = {
    CameraButtonPosition, CanvasSize, CellPadding, CellSize, CloseButtonPosition, DragUDim2,
    MaxDragTranslation, MinDragTranslation, Offset, Padding, Position, SelectionModeDragSpeed,
    Size, Spread, TileSize,
}
local classDefaultProperties: { [string]: { [string]: any } } = {
    AccessoryDescription = {
        AssetId = 0, IsLayered = false, Order = 0, Position = "Vector3", Rotation = "Vector3", Scale = "Vector3",
    },
    Accoutrement = {
        AttachmentPoint = "CFrame",
    },
    Actor = {},
    AdGui = {
        EnableVideoAds = false,
    },
    AdService = {},
    AirController = {
        BalanceMaxTorque = 0, BalanceSpeed = 0, MaintainAngularMomentum = false, MaintainLinearMomentum = false,
        MoveMaxForce = 0, TurnMaxTorque = 0, TurnSpeedFactor = 0,
    },
    AlignOrientation = {
        CFrame = "CFrame", LookAtPosition = "Vector3", MaxAngularVelocity = 0, MaxTorque = 0, PrimaryAxis = "Vector3",
        PrimaryAxisOnly = false, ReactionTorqueEnabled = false, Responsiveness = 0, RigidityEnabled = false,
        SecondaryAxis = "Vector3",
    },
    AlignPosition = {
        ApplyAtCenterOfMass = false, MaxAxesForce = "Vector3", MaxForce = 0, MaxVelocity = 0, Position = "Vector3",
        ReactionForceEnabled = false, Responsiveness = 0, RigidityEnabled = false,
    },
    AngularVelocity = {
        AngularVelocity = "Vector3", MaxTorque = 0, ReactionTorqueEnabled = false,
    },
    AnimationClip = {
        Loop = false,
    },
    AnimationClipProvider = {},
    AnimationConstraint = {
        AngularDamping = 0, AngularStrength = 0, IsKinematic = false, LinearDamping = 0, LinearStrength = 0,
        MaxForce = 0, MaxTorque = 0, Transform = "CFrame",
    },
    AnimationTrack = {
        Looped = false, TimePosition = 0,
    },
    Animator = {
        PreferLodEnabled = false,
    },
    AppStorageService = {},
    AppUpdateService = {},
    AssetDeliveryProxy = {
        Interface = "", Port = 0, StartServer = false,
    },
    AssetPatchSettings = {
        ContentId = "", OutputPath = "", PatchId = "",
    },
    AssetService = {
        AllowInsertFreeAssets = false,
    },
    Atmosphere = {
        Color = "Color3", Decay = "Color3", Density = 0.395, Glare = 0, Haze = 0, Offset = 0,
    },
    Attachment = {
        Axis = "Vector3", CFrame = "CFrame", SecondaryAxis = "Vector3", Visible = false, WorldAxis = "Vector3",
        WorldCFrame = "CFrame", WorldSecondaryAxis = "Vector3",
    },
    AudioAnalyzer = {
        SpectrumEnabled = false,
    },
    AudioChorus = {
        Bypass = false, Depth = 0, Mix = 0, Rate = 0,
    },
    AudioCompressor = {
        Attack = 0, Bypass = false, MakeupGain = 0, Ratio = 0, Release = 0, Threshold = 0,
    },
    AudioDeviceInput = {
        Active = false, Muted = false, Volume = 0,
    },
    AudioDistortion = {
        Bypass = false, Level = 0,
    },
    AudioEcho = {
        Bypass = false, DelayTime = 0, DryLevel = 0, Feedback = 0, RampTime = 0, WetLevel = 0,
    },
    AudioEmitter = {
        AcousticSimulationEnabled = false, AudioInteractionGroup = "",
    },
    AudioEqualizer = {
        Bypass = false, HighGain = 0, LowGain = 0, MidGain = 0, MidRange = "NumberRange",
    },
    AudioFader = {
        Bypass = false, Volume = 0,
    },
    AudioFilter = {
        Bypass = false, Frequency = 0, Gain = 0, Q = 0,
    },
    AudioFlanger = {
        Bypass = false, Depth = 0, Mix = 0, Rate = 0,
    },
    AudioFocusService = {},
    AudioGate = {
        Attack = 0, Bypass = false, Release = 0, Threshold = "NumberRange",
    },
    AudioLimiter = {
        Bypass = false, MaxLevel = 0, Release = 0,
    },
    AudioListener = {
        AcousticSimulationEnabled = false, AudioInteractionGroup = "",
    },
    AudioPitchShifter = {
        Bypass = false, Pitch = 0,
    },
    AudioPlayer = {
        AutoLoad = false, AutoPlay = false, IsPlaying = false, LoopRegion = "NumberRange", Looping = false,
        PlaybackRegion = "NumberRange", PlaybackSpeed = 0, TimePosition = 0, Volume = 0,
    },
    AudioRecorder = {
        IsRecording = false,
    },
    AudioReverb = {
        Bypass = false, DecayRatio = 0, DecayTime = 0, Density = 0, Diffusion = 0, DryLevel = 0,
        EarlyDelayTime = 0, HighCutFrequency = 0, LateDelayTime = 0, LowShelfFrequency = 0, LowShelfGain = 0,
        ReferenceFrequency = 0, WetLevel = 0,
    },
    AudioSearchParams = {
        Album = "", Artist = "", MaxDuration = 0, MinDuration = 0, SearchKeyword = "", Tag = "",
        Title = "",
    },
    AudioSpeechToText = {
        Enabled = false, Text = "",
    },
    AudioTextToSpeech = {
        IsPlaying = false, Looping = false, Pitch = 0, PlaybackSpeed = 0, Speed = 0, Text = "",
        TimePosition = 0, VoiceId = "", Volume = 0,
    },
    AudioTremolo = {
        Bypass = false, Depth = 0, Duty = 0, Frequency = 0, Shape = 0, Skew = 0, Square = 0,
    },
    AuroraScriptObject = {
        FrameId = 0, LODLevel = 0, PriorFrameInvoked = 0,
    },
    AvatarChatService = {
        ServerFeatures = 0,
    },
    AvatarCreationService = {},
    AvatarEditorService = {},
    BadgeService = {},
    BallSocketConstraint = {
        LimitsEnabled = false, MaxFrictionTorque = 0, Radius = 0, Restitution = 0, TwistLimitsEnabled = false,
        TwistLowerAngle = 0, TwistUpperAngle = 0, UpperAngle = 0,
    },
    BaseCoreGuiConfiguration = {
        Enabled = false,
    },
    BaseImportData = {
        ImportName = "", ShouldImport = false,
    },
    BasePart = {
        Anchored = false, AssemblyAngularVelocity = "Vector3", AssemblyLinearVelocity = "Vector3",
        AudioCanCollide = false, CFrame = "CFrame", CanCollide = true, CanQuery = true, CanTouch = true,
        CastShadow = true, CollisionGroup = "", Color = "Color3", EnableFluidForces = false, Locked = false,
        Massless = false, MaterialVariant = "", PivotOffset = "CFrame", Reflectance = 0, RootPriority = 0,
        Rotation = "Vector3", Size = "Vector3", Transparency = 0, CanFrameCached = true, Archivable = true,
        FrontParamA = -0.5, FrontParamB = 0.5, BackParamA = -0.5, BackParamB = 0.5, LeftParamA = -0.5,
        LeftParamB = 0.5, RightParamA = -0.5, RightParamB = 0.5, TopParamA = -0.5, TopParamB = 0.5,
        BottomParamA = -0.5, BottomParamB = 0.5, Friction = 0.3, Elasticity = 0.2, ElasticityWeight = 1.0,
        FrictionWeight = 1.0, CollisionGroupId = 0,
    },
    BaseScript = {
        Disabled = false, Enabled = false,
    },
    BaseWrap = {
        CageOrigin = "CFrame", ImportOrigin = "CFrame",
    },
    Beam = {
        Brightness = 0, CurveSize0 = 0, CurveSize1 = 0, Enabled = true, FaceCamera = false, LightEmission = 0,
        LightInfluence = 0, Segments = 10, TextureLength = 1, TextureSpeed = 0, Width0 = 1, Width1 = 1,
        ZOffset = 0,
    },
    BillboardGui = {
        Active = false, AlwaysOnTop = false, Brightness = 0, ClipsDescendants = false, DistanceStep = 0,
        ExtentsOffset = "Vector3", ExtentsOffsetWorldSpace = "Vector3", LightInfluence = 0, MaxDistance = 100,
        Size = "UDim2", SizeOffset = "Vector2", StudsOffset = "Vector3", StudsOffsetWorldSpace = "Vector3",
        PixelsPerStud = 50,
    },
    BindableEvent = {},
    BindableFunction = {},
    BloomEffect = {
        Intensity = 0.4, Size = 24, Threshold = 0.95, Enabled = true,
    },
    BlurEffect = {
        Size = 24, Enabled = true,
    },
    BodyAngularVelocity = {
        AngularVelocity = "Vector3", MaxTorque = "Vector3", P = 0,
    },
    BodyColors = {
        HeadColor3 = "Color3", LeftArmColor3 = "Color3", LeftLegColor3 = "Color3", RightArmColor3 = "Color3",
        RightLegColor3 = "Color3", TorsoColor3 = "Color3",
    },
    BodyForce = {
        Force = "Vector3",
    },
    BodyGyro = {
        CFrame = "CFrame", D = 0, MaxTorque = "Vector3", P = 0,
    },
    BodyPartDescription = {
        AssetId = 0, Color = "Color3", HeadShape = "",
    },
    BodyPosition = {
        D = 0, MaxForce = "Vector3", P = 0, Position = "Vector3",
    },
    BodyThrust = {
        Force = "Vector3", Location = "Vector3",
    },
    BodyVelocity = {
        MaxForce = "Vector3", P = 0, Velocity = "Vector3",
    },
    Bone = {
        Transform = "CFrame",
    },
    BoolValue = {
        Value = false,
    },
    BoxHandleAdornment = {
        Size = "Vector3",
    },
    BubbleChatConfiguration = {
        AdorneeName = "", BackgroundColor3 = "Color3", BackgroundTransparency = 0, BubbleDuration = 0,
        BubblesSpacing = 0, Enabled = false, LocalPlayerStudsOffset = "Vector3", MaxBubbles = 0,
        MaxDistance = 0, MinimizeDistance = 0, TailVisible = false, TextColor3 = "Color3", TextSize = 0,
        VerticalStudsOffset = 0,
    },
    BubbleChatMessageProperties = {
        BackgroundColor3 = "Color3", BackgroundTransparency = 0, TailVisible = false, TextColor3 = "Color3",
        TextSize = 0,
    },
    BuoyancySensor = {
        FullySubmerged = false, TouchingSurface = false,
    },
    CFrameValue = {
        Value = "CFrame",
    },
    Camera = {
        CFrame = "CFrame", DiagonalFieldOfView = 70, FieldOfView = 70, Focus = "CFrame", HeadLocked = true,
        HeadScale = 1, MaxAxisFieldOfView = 70, VRTiltAndRollEnabled = false, CameraType = "Enum.CameraType.Custom",
        CameraMinZoomDistance = 0.5, CameraMaxZoomDistance = 128, MaxRollAngleRight = 0, MaxRollAngleLeft = 0,
        NearPlaneZ = -0.1, FieldOfViewMode = "Enum.FieldOfViewMode.Vertical",
    },
    CanvasGroup = {
        GroupColor3 = "Color3", GroupTransparency = 0,
    },
    CaptureService = {},
    CapturesViewConfiguration = {
        Open = false,
    },
    ChannelSelectorSoundEffect = {
        Channel = 0,
    },
    ChannelTabsConfiguration = {
        BackgroundColor3 = "Color3", BackgroundTransparency = 0, Enabled = false, HoverBackgroundColor3 = "Color3",
        SelectedTabTextColor3 = "Color3", TextColor3 = "Color3", TextSize = 0, TextStrokeColor3 = "Color3",
        TextStrokeTransparency = 0,
    },
    CharacterMesh = {
        BaseTextureId = 0, MeshId = 0, OverlayTextureId = 0,
    },
    Chat = {
        BubbleChatEnabled = false, LoadDefaultChat = true, IsAutoMigrated = true, ModerationMode = "TextFilter",
    },
    ChatInputBarConfiguration = {
        AutocompleteEnabled = false, BackgroundColor3 = "Color3", BackgroundTransparency = 0, Enabled = false,
        PlaceholderColor3 = "Color3", TextColor3 = "Color3", TextSize = 0, TextStrokeColor3 = "Color3",
        TextStrokeTransparency = 0,
    },
    ChatWindowConfiguration = {
        BackgroundColor3 = "Color3", BackgroundTransparency = 0, Enabled = false, HeightScale = 0,
        TextColor3 = "Color3", TextSize = 0, TextStrokeColor3 = "Color3", TextStrokeTransparency = 0,
        WidthScale = 0,
    },
    ChatWindowMessageProperties = {
        TextColor3 = "Color3", TextSize = 0, TextStrokeColor3 = "Color3", TextStrokeTransparency = 0,
    },
    ChorusSoundEffect = {
        Depth = 0, Mix = 0, Rate = 0,
    },
    ClickDetector = {
        MaxActivationDistance = 0,
    },
    ClimbController = {
        AccelerationTime = 0, BalanceMaxTorque = 0, BalanceSpeed = 0, MoveMaxForce = 0,
    },
    Clothing = {
        Color3 = "Color3",
    },
    Clouds = {
        Color = "Color3", Cover = 0, Density = 0, Enabled = false,
    },
    CollectionService = {
        NitrateScale = 1,
    },
    Color3Value = {
        Value = "Color3",
    },
    ColorCorrectionEffect = {
        Brightness = 0, Contrast = 0, Saturation = 0, TintColor = "Color3", Enabled = true,
    },
    CompressorSoundEffect = {
        Attack = 0, GainMakeup = 0, Ratio = 0, Release = 0, Threshold = 0,
    },
    ConeHandleAdornment = {
        Height = 0, Hollow = false, Radius = 0,
    },
    Configuration = {},
    Constraint = {
        Enabled = false, Visible = false,
    },
    ContentProvider = {
        RequestQueueSize = 0, CacheAssets = false,
    },
    ContextActionService = {
        NitrateScale = 1,
    },
    ControllerBase = {
        BalanceRigidityEnabled = false, MoveSpeedFactor = 0,
    },
    ControllerManager = {
        BaseMoveSpeed = 0, BaseTurnSpeed = 0, FacingDirection = "Vector3", MovingDirection = "Vector3",
        UpDirection = "Vector3",
    },
    ControllerPartSensor = {
        HitFrame = "CFrame", HitNormal = "Vector3", LadderSearchHeight = 0, LadderSearchOffset = 0,
        SearchDistance = 0,
    },
    CylinderHandleAdornment = {
        Angle = 0, Height = 0, InnerRadius = 0, Radius = 0,
    },
    CylindricalConstraint = {
        AngularLimitsEnabled = false, AngularResponsiveness = 0, AngularRestitution = 0, AngularSpeed = 0,
        AngularVelocity = 0, InclinationAngle = 0, LowerAngle = 0, MotorMaxAngularAcceleration = 0,
        MotorMaxTorque = 0, RotationAxisVisible = false, ServoMaxTorque = 0, TargetAngle = 0, UpperAngle = 0,
    },
    DataModel = {
        CreatorId = 0, CreatorType = "Enum.CreatorType.User", GameId = 0, Genre = "Enum.Genre.All",
        JobId = "", PlaceId = 0, PlaceVersion = 0, PrivateServerId = "", PrivateServerOwnerId = 0,
        Workspace = nil, Guid = "",
    },
    DataModelMesh = {
        Offset = "Vector3", Scale = "Vector3", VertexColor = "Vector3",
    },
    DataStoreGetOptions = {
        UseCache = false,
    },
    DataStoreOptions = {
        AllScopes = false,
    },
    DataStoreService = {
        LegacyNamingScheme = false, AutomaticRetry = true,
    },
    Debris = {
        MaxItems = 1000,
    },
    DebuggerBreakpoint = {
        Condition = "", ContinueExecution = false, IsEnabled = false, LogExpression = "", isContextDependentBreakpoint = false,
    },
    DebuggerWatch = {
        Expression = "",
    },
    Decal = {
        AutoLocalize = false, Color3 = "Color3", Rotation = 0, Transparency = 0, UVOffset = "Vector2",
        UVScale = "Vector2", ZIndex = 1, Shiny = 0, Specular = 0,
    },
    DepthOfFieldEffect = {
        FarIntensity = 0, FocusDistance = 0, InFocusRadius = 0, NearIntensity = 0, Enabled = true,
        FocalLength = 25,
    },
    Dialog = {
        ConversationDistance = 0, GoodbyeChoiceActive = false, GoodbyeDialog = "", InUse = false,
        InitialPrompt = "", TriggerDistance = 0, TriggerOffset = "Vector3",
    },
    DialogChoice = {
        GoodbyeChoiceActive = false, GoodbyeDialog = "", ResponseDialog = "", UserDialog = "",
    },
    DigitsRigDescription = {
        Index1TposeAdjustment = "CFrame", Index2TposeAdjustment = "CFrame", Index3TposeAdjustment = "CFrame",
        IndexRange = "Vector3", IndexSize = 0, Middle1TposeAdjustment = "CFrame", Middle2TposeAdjustment = "CFrame",
        Middle3TposeAdjustment = "CFrame", MiddleRange = "Vector3", MiddleSize = 0, Pinky1TposeAdjustment = "CFrame",
        Pinky2TposeAdjustment = "CFrame", Pinky3TposeAdjustment = "CFrame", PinkyRange = "Vector3",
        PinkySize = 0, Ring1TposeAdjustment = "CFrame", Ring2TposeAdjustment = "CFrame", Ring3TposeAdjustment = "CFrame",
        RingRange = "Vector3", RingSize = 0, Thumb1TposeAdjustment = "CFrame", Thumb2TposeAdjustment = "CFrame",
        Thumb3TposeAdjustment = "CFrame", ThumbRange = "Vector3", ThumbSize = 0,
    },
    DistortionSoundEffect = {
        Level = 0,
    },
    DoubleConstrainedValue = {
        MaxValue = 0, MinValue = 0, Value = 0,
    },
    DragDetector = {
        ApplyAtCenterOfMass = false, Axis = "Vector3", DragFrame = "CFrame", Enabled = false, MaxDragAngle = 0,
        MaxDragTranslation = "Vector3", MaxForce = 0, MaxTorque = 0, MinDragAngle = 0, MinDragTranslation = "Vector3",
        Orientation = "Vector3", Responsiveness = 0, RunLocally = false, SecondaryAxis = "Vector3",
        TrackballRadialPullFactor = 0, TrackballRollFactor = 0, WorldAxis = "Vector3", WorldSecondaryAxis = "Vector3",
    },
    DraggerService = {
        AlignDraggedObjects = false, AngleSnapEnabled = false, AngleSnapIncrement = 0, AnimateHover = false,
        CollisionsEnabled = false, GeometrySnapColor = "Color3", HoverAnimateFrequency = 0, HoverThickness = 0,
        JointsEnabled = false, LinearSnapEnabled = false, LinearSnapIncrement = 0, ShowHover = false,
        ShowPivotIndicator = false,
    },
    DynamicRotate = {
        BaseAngle = 0,
    },
    EchoSoundEffect = {
        Delay = 0, DryLevel = 0, Feedback = 0, WetLevel = 0,
    },
    EqualizerSoundEffect = {
        HighGain = 0, LowGain = 0, MidGain = 0,
    },
    EventIngestService = {},
    ExperienceInviteOptions = {
        InviteMessageId = "", InviteUser = 0, LaunchData = "", PromptMessage = "",
    },
    ExperienceStateCaptureService = {
        HiddenSelectionEnabled = false,
    },
    Explosion = {
        BlastPressure = 500000, BlastRadius = 8, DestroyJointRadiusPercent = 1, Position = "Vector3",
        TimeScale = 1, Visible = true,
    },
    FaceAnimatorService = {
        AudioAnimationEnabled = false, FlipHeadOrientation = false, VideoAnimationEnabled = false,
    },
    Fire = {
        Color = "Color3", Enabled = true, Heat = 1, SecondaryColor = "Color3", Size = 1, TimeScale = 1,
        Lifetime = 1, FadeTime = 1,
    },
    FlangeSoundEffect = {
        Depth = 0, Mix = 0, Rate = 0,
    },
    FloorWire = {
        CycleOffset = 0, StudsBetweenTextures = 0, TextureSize = "Vector2", Velocity = 0, WireRadius = 0,
    },
    FlyweightService = {},
    Folder = {},
    ForceField = {
        Visible = false,
    },
    Frame = {
        BackgroundTransparency = 1, BorderSizePixel = 0, Active = false, ClipsDescendants = false,
        BackgroundColor = "Enum", BorderColor = "Enum",
    },
    FriendService = {},
    FunctionalTest = {
        Description = "",
    },
    GamepadService = {
        GamepadCursorEnabled = false,
    },
    GeometryService = {},
    GetTextBoundsParams = {
        RichText = false, Size = 0, Text = "", Width = 0,
    },
    Glue = {
        F0 = "Vector3", F1 = "Vector3", F2 = "Vector3", F3 = "Vector3",
    },
    GroundController = {
        AccelerationLean = 0, AccelerationTime = 0, BalanceMaxTorque = 0, BalanceSpeed = 0, DecelerationTime = 0,
        Friction = 0, FrictionWeight = 0, GroundOffset = 0, StandForce = 0, StandSpeed = 0, TurnSpeedFactor = 0,
    },
    GroupImportData = {
        Anchored = false, ImportAsModelAsset = false, InsertInWorkspace = false,
    },
    GroupService = {},
    GuiBase2d = {
        AutoLocalize = false, SelectionGroup = false,
    },
    GuiBase3d = {
        Color3 = "Color3", Transparency = 0, Visible = false,
    },
    GuiButton = {
        AutoButtonColor = false, Modal = false, Selected = false,
    },
    GuiObject = {
        Active = false, AnchorPoint = "Vector2", BackgroundColor3 = "Color3", BackgroundTransparency = 0,
        BorderColor3 = "Color3", BorderSizePixel = 0, ClipsDescendants = false, Interactable = false,
        LayoutOrder = 0, Position = "UDim2", Rotation = 0, Selectable = false, SelectionOrder = 0,
        Size = "UDim2", Visible = false, ZIndex = 0,
    },
    GuiService = {
        AutoSelectGuiEnabled = false, GuiNavigationEnabled = false, TouchControlsEnabled = true,
        CoreGuiNavigationEnabled = false, SelectedObject = nil,
    },
    HandleAdornment = {
        AlwaysOnTop = false, CFrame = "CFrame", SizeRelativeOffset = "Vector3", ZIndex = 0,
    },
    HapticEffect = {
        Looped = false, Position = "Vector3", Radius = 0,
    },
    HapticService = {},
    HeapProfilerService = {},
    Highlight = {
        Enabled = false, FillColor = "Color3", FillTransparency = 0, OutlineColor = "Color3", OutlineTransparency = 0,
    },
    HingeConstraint = {
        AngularResponsiveness = 0, AngularSpeed = 0, AngularVelocity = 0, LimitsEnabled = false,
        LowerAngle = 0, MotorMaxAcceleration = 0, MotorMaxTorque = 0, Radius = 0, Restitution = 0,
        ServoMaxTorque = 0, TargetAngle = 0, UpperAngle = 0,
    },
    Hopper = {},
    HopperBin = {
        Active = false, ManualActivationOnly = false, CanBeDropped = true, ToolTip = "",
    },
    HttpRbxApiService = {},
    HttpService = {
        HttpEnabled = false,
    },
    Humanoid = {
        AutoJumpEnabled = false, AutoRotate = true, AutomaticScalingEnabled = true, BreakJointsOnDeath = true,
        CameraOffset = "Vector3", DisplayName = "", EvaluateStateMachine = false, Health = 100,
        HealthDisplayDistance = 100, HipHeight = 0, Jump = false, JumpHeight = 7.2, JumpPower = 50,
        MaxHealth = 100, MaxSlopeAngle = 89, NameDisplayDistance = 100, PlatformStand = false, RequiresNeck = true,
        Sit = false, TargetPoint = "Vector3", UseJumpPower = false, WalkSpeed = 16, WalkToPoint = "Vector3",
        CameraMaxZoomDistance = 128, CameraMinZoomDistance = 0.5, RigScale = 1, DisplayDistanceType = "Enum.HumanoidDisplayDistanceType.Viewer",
        CollisionType = "Enum.HumanoidCollisionType.OuterSurface",
    },
    HumanoidDescription = {
        BackAccessory = "", BodyTypeScale = 0, ClimbAnimation = 0, DepthScale = 0, Face = 0, FaceAccessory = "",
        FallAnimation = 0, FrontAccessory = "", GraphicTShirt = 0, HairAccessory = "", HatAccessory = "",
        Head = 0, HeadColor = "Color3", HeadScale = 0, HeightScale = 0, IdleAnimation = 0, JumpAnimation = 0,
        LeftArm = 0, LeftArmColor = "Color3", LeftLeg = 0, LeftLegColor = "Color3", MoodAnimation = 0,
        NeckAccessory = "", Pants = 0, ProportionScale = 0, RightArm = 0, RightArmColor = "Color3",
        RightLeg = 0, RightLegColor = "Color3", RunAnimation = 0, Shirt = 0, ShouldersAccessory = "",
        StaticFacialAnimation = false, SwimAnimation = 0, Torso = 0, TorsoColor = "Color3", UseAvatarSettings = false,
        WaistAccessory = "", WalkAnimation = 0, WidthScale = 0,
    },
    HumanoidRigDescription = {
        ChestRangeMax = "Vector3", ChestRangeMin = "Vector3", ChestSize = 0, ChestTposeAdjustment = "CFrame",
        HeadBaseRangeMax = "Vector3", HeadBaseRangeMin = "Vector3", HeadBaseSize = 0, HeadBaseTposeAdjustment = "CFrame",
        LeftAnkleRangeMax = "Vector3", LeftAnkleRangeMin = "Vector3", LeftAnkleSize = 0, LeftAnkleTposeAdjustment = "CFrame",
        LeftClavicleRangeMax = "Vector3", LeftClavicleRangeMin = "Vector3", LeftClavicleSize = 0,
        LeftClavicleTposeAdjustment = "CFrame", LeftElbowRangeMax = "Vector3", LeftElbowRangeMin = "Vector3",
        LeftElbowSize = 0, LeftElbowTposeAdjustment = "CFrame", LeftHipRangeMax = "Vector3", LeftHipRangeMin = "Vector3",
        LeftHipSize = 0, LeftHipTposeAdjustment = "CFrame", LeftKneeRangeMax = "Vector3", LeftKneeRangeMin = "Vector3",
        LeftKneeSize = 0, LeftKneeTposeAdjustment = "CFrame", LeftShoulderRangeMax = "Vector3",
        LeftShoulderRangeMin = "Vector3", LeftShoulderSize = 0, LeftShoulderTposeAdjustment = "CFrame",
        LeftToeBaseRangeMax = "Vector3", LeftToeBaseRangeMin = "Vector3", LeftToeBaseSize = 0, LeftToeBaseTposeAdjustment = "CFrame",
        LeftWristRangeMax = "Vector3", LeftWristRangeMin = "Vector3", LeftWristSize = 0, LeftWristTposeAdjustment = "CFrame",
        NeckRangeMax = "Vector3", NeckRangeMin = "Vector3", NeckSize = 0, NeckTposeAdjustment = "CFrame",
        RightAnkleRangeMax = "Vector3", RightAnkleRangeMin = "Vector3", RightAnkleSize = 0, RightAnkleTposeAdjustment = "CFrame",
        RightClavicleRangeMax = "Vector3", RightClavicleRangeMin = "Vector3", RightClavicleSize = 0,
        RightClavicleTposeAdjustment = "CFrame", RightElbowRangeMax = "Vector3", RightElbowRangeMin = "Vector3",
        RightElbowSize = 0, RightElbowTposeAdjustment = "CFrame", RightHipRangeMax = "Vector3",
        RightHipRangeMin = "Vector3", RightHipSize = 0, RightHipTposeAdjustment = "CFrame", RightKneeRangeMax = "Vector3",
        RightKneeRangeMin = "Vector3", RightKneeSize = 0, RightKneeTposeAdjustment = "CFrame", RightShoulderRangeMax = "Vector3",
        RightShoulderRangeMin = "Vector3", RightShoulderSize = 0, RightShoulderTposeAdjustment = "CFrame",
        RightToeBaseRangeMax = "Vector3", RightToeBaseRangeMin = "Vector3", RightToeBaseSize = 0,
        RightToeBaseTposeAdjustment = "CFrame", RightWristRangeMax = "Vector3", RightWristRangeMin = "Vector3",
        RightWristSize = 0, RightWristTposeAdjustment = "CFrame", RootRangeMax = "Vector3", RootRangeMin = "Vector3",
        RootSize = 0, RootTposeAdjustment = "CFrame", SpineRangeMax = "Vector3", SpineRangeMin = "Vector3",
        SpineSize = 0, SpineTposeAdjustment = "CFrame", WaistRangeMax = "Vector3", WaistRangeMin = "Vector3",
        WaistSize = 0, WaistTposeAdjustment = "CFrame",
    },
    IKControl = {
        Enabled = false, EndEffectorOffset = "CFrame", Offset = "CFrame", Priority = 0, SmoothTime = 0,
        Weight = 0,
    },
    IXPService = {},
    ImageButton = {
        ImageColor3 = "Color3", ImageRectOffset = "Vector2", ImageRectSize = "Vector2", ImageTransparency = 0,
        SliceCenter = "Rect", SliceScale = 0, TileSize = "UDim2", ScaleType = "Enum.ScaleType.Stretch",
        ResampleMode = "Enum.ResampleMode.Default", AutoButtonColor = true, BackgroundColor3 = "Color3",
        BackgroundTransparency = 1, BorderSizePixel = 0,
    },
    ImageHandleAdornment = {
        Size = "Vector2",
    },
    ImageLabel = {
        ImageColor3 = "Color3", ImageRectOffset = "Vector2", ImageRectSize = "Vector2", ImageTransparency = 0,
        SliceCenter = "Rect", SliceScale = 0, TileSize = "UDim2", ScaleType = "Enum.ScaleType.Stretch",
        ResampleMode = "Enum.ResampleMode.Default", BackgroundColor3 = "Color3", BackgroundTransparency = 1,
        BorderSizePixel = 0,
    },
    IncrementalPatchBuilder = {
        AddPathsToBundle = false, BuildDebouncePeriod = 0, HighCompression = false, SerializePatch = false,
        UseFileLevelCompressionInsteadOfChunk = false, ZstdCompression = false,
    },
    InputAction = {
        Enabled = false,
    },
    InputBinding = {
        ClampMagnitudeToOne = false, PointerIndex = 0, PressedThreshold = 0, ReleasedThreshold = 0,
        ResponseCurve = 0, Scale = 0, Vector2Scale = "Vector2", Vector3Scale = "Vector3",
    },
    InputContext = {
        Enabled = false, Priority = 0, Sink = false,
    },
    InputObject = {
        Delta = "Vector3", Position = "Vector3",
    },
    InsertService = {
        AllowInsertFreeModels = false,
    },
    Instance = {
        Archivable = false, Name = "", Sandboxed = false,
    },
    IntConstrainedValue = {
        MaxValue = 0, MinValue = 0, Value = 0,
    },
    IntValue = {
        Value = 0,
    },
    JointInstance = {
        C0 = "CFrame", C1 = "CFrame", Enabled = false,
    },
    JointsService = {},
    Keyframe = {
        Time = 0,
    },
    KeyframeMarker = {
        Value = "",
    },
    KeyframeSequenceProvider = {},
    LayerCollector = {
        Enabled = false, ResetOnSpawn = false,
    },
    Light = {
        Brightness = 0, Color = "Color3", Enabled = false, Shadows = false,
    },
    Lighting = {
        Ambient = "Color3", Brightness = 2, ClockTime = 14, ColorShift_Bottom = "Color3", ColorShift_Top = "Color3",
        EnvironmentDiffuseScale = 1, EnvironmentSpecularScale = 1, ExposureCompensation = 0, FogColor = "Color3",
        FogEnd = 100000, FogStart = 0, GeographicLatitude = 0, GlobalShadows = true, OutdoorAmbient = "Color3",
        PrioritizeLightingQuality = false, ShadowSoftness = 0.2, TimeOfDay = "14:00:00", Technology = "Enum.Technology.Future",
        ShadowColor = "Color3", Outlines = false,
    },
    LineForce = {
        ApplyAtCenterOfMass = false, InverseSquareLaw = false, Magnitude = 0, MaxForce = 0, ReactionForceEnabled = false,
    },
    LineHandleAdornment = {
        Length = 0, Thickness = 0,
    },
    LinearVelocity = {
        ForceLimitsEnabled = false, LineDirection = "Vector3", LineVelocity = 0, MaxAxesForce = "Vector3",
        MaxForce = 0, MaxPlanarAxesForce = "Vector2", PlaneVelocity = "Vector2", PrimaryTangentAxis = "Vector3",
        ReactionForceEnabled = false, SecondaryTangentAxis = "Vector3", VectorVelocity = "Vector3",
    },
    LocalScript = {},
    LocalizationService = {
        ForcePlayModeGameLocaleId = "", ForcePlayModeRobloxLocaleId = "", IsTextScraperRunning = false,
        RobloxForcePlayModeGameLocaleId = "", RobloxForcePlayModeRobloxLocaleId = "",
        RobloxLocaleId = "en-us", SystemLocaleId = "en-us", LocaleId = "en-us",
    },
    LocalizationTable = {
        SourceLocaleId = "",
    },
    LogService = {},
    MakeupDescription = {
        AssetId = 0, Order = 0,
    },
    MarketplaceService = {
        IsPurchaseSimulated = false,
    },
    MaterialGenerationService = {},
    MaterialImportData = {
        DiffuseFilePath = "", EmissiveFilePath = "", MetalnessFilePath = "", NormalFilePath = "",
        RoughnessFilePath = "",
    },
    MaterialVariant = {
        EmissiveStrength = 0, EmissiveTint = "Color3", StudsPerTile = 0,
    },
    MemStorageService = {},
    MeshContentProvider = {},
    MeshImportData = {
        Anchored = false, CageMeshIntersectedPreview = false, CageNonManifoldPreview = false, CageOverlappingVerticesPreview = false,
        CageUVMisMatchedPreview = false, DoubleSided = false, IgnoreVertexColors = false, IrrelevantCageModifiedPreview = false,
        MeshHoleDetectedPreview = false, OuterCageFarExtendedFromMeshPreview = false, UseImportedPivot = false,
    },
    MeshPart = {
        DoubleSided = false,
    },
    Message = {
        Text = "",
    },
    MessageBusService = {},
    MicroProfilerService = {
        ContextLabel = "",
    },
    Model = {
        WorldPivot = "CFrame",
    },
    ModuleScript = {
        LinkedSource = "",
    },
    Motor = {
        CurrentAngle = 0, DesiredAngle = 0, MaxVelocity = 0,
    },
    NetworkServer = {},
    NetworkSettings = {
        HttpProxyEnabled = false, HttpProxyURL = "", IncomingReplicationLag = 0, PrintJoinSizeBreakdown = false,
        PrintPhysicsErrors = false, PrintStreamInstanceQuota = false, RandomizeJoinInstanceOrder = false,
        RenderStreamedRegions = false, ShowActiveAnimationAsset = false,
    },
    NoCollisionConstraint = {
        Enabled = false,
    },
    NotificationService = {
        SelectedTheme = "",
    },
    NumberPose = {
        Value = 0,
    },
    NumberValue = {
        Value = 0,
    },
    OpenCloudService = {},
    PackageLink = {
        DefaultName = "", VersionNumber = 0,
    },
    Part = {
        Shape = "Enum.PartType.Block", Material = "Enum.Material.Plastic", TopSurface = "Enum.SurfaceType.Smooth",
        BottomSurface = "Enum.SurfaceType.Smooth", FrontSurface = "Enum.SurfaceType.Smooth", BackSurface = "Enum.SurfaceType.Smooth",
        LeftSurface = "Enum.SurfaceType.Smooth", RightSurface = "Enum.SurfaceType.Smooth",
    },
    PartOperation = {
        SmoothingAngle = 0, TriangleCount = 0, UsePartColor = false,
    },
    ParticleEmitter = {
        Acceleration = "Vector3", Brightness = 1, Drag = 0, Enabled = true, FlipbookBlendFrames = true,
        FlipbookFramerate = "NumberRange", FlipbookIncompatible = "", FlipbookSizeX = 0, FlipbookSizeY = 0,
        FlipbookStartRandom = false, Lifetime = "NumberRange", LightEmission = 0, LightInfluence = 0,
        LockedToPart = false, Rate = 10, RotSpeed = "NumberRange", Rotation = "NumberRange", ShapePartial = 0,
        Speed = "NumberRange", SpreadAngle = "Vector2", TimeScale = 1, VelocityInheritance = 0,
        WindAffectsDrag = false, ZOffset = 2,
    },
    PatchMapping = {
        FlattenTree = false, PatchId = "", TargetPath = "",
    },
    Path2D = {
        Closed = false, Color3 = "Color3", Thickness = 0, Visible = false, ZIndex = 0,
    },
    PathfindingLink = {
        IsBidirectional = false, Label = "",
    },
    PathfindingModifier = {
        Label = "", PassThrough = false,
    },
    PathfindingService = {
        EmptyCutoff = 0,
    },
    PhysicsService = {
        ThrottlePhysicsIslands = false, PhysicsEnvironmentalThrottle = "Enum.EnvironmentalPhysicsThrottle.DefaultAuto",
    },
    PitchShiftSoundEffect = {
        Octave = 0,
    },
    PlatformFriendsService = {},
    Player = {
        AutoJumpEnabled = false, CameraMaxZoomDistance = 128, CameraMinZoomDistance = 0.5, CanLoadCharacterAppearance = true,
        CharacterAppearanceId = 0, DevEnableMouseLock = false, DisplayName = "", HasRobloxSubscription = false,
        HasVerifiedBadge = false, HealthDisplayDistance = 100, NameDisplayDistance = 100, Neutral = true,
        UserId = 0, CharacterAppearance = "", ChatAvailabilityStatus = "", DataComplexityLimit = 600,
        GameplayPaused = false, InputLatency = 0, MaximumSimulationRadius = 1000, OsPlatform = "",
        PartyId = "", PlatformName = "", SimulationRadius = 0, StepIdOffset = 0, TeleportedIn = false,
        VRDevice = "", VREnabled = false, userId = 0, CameraMode = "Enum.CameraMode.Custom", DevCameraOcclusionMode = "Enum.DevCameraOcclusionMode.Zoom",
        DevComputerCameraMode = "Enum.DevComputerCameraMode.UserChoice", DevTouchCameraMode = "Enum.DevTouchCameraMode.UserChoice",
    },
    PlayerListConfiguration = {
        Open = false,
    },
    Players = {
        CharacterAutoLoads = true, RespawnTime = 5, MaxPlayers = 16, NumPlayers = 0, BanningEnabled = false,
        BubbleChat = false, ClassicChat = true, MaxPlayersInternal = 16, LocalPlayer = nil, ShowFailedJoinPopup = false,
    },
    PluginAction = {
        Text = "",
    },
    PluginGui = {
        Title = "",
    },
    PluginMenu = {
        Icon = "", Title = "",
    },
    PluginToolbarButton = {
        ClickableWhenViewportHidden = false, Enabled = false,
    },
    PointLight = {
        Range = 8, Brightness = 1, Shadows = false, Enabled = true, Color = "Color3",
    },
    PointsService = {},
    PolicyService = {},
    Pose = {
        CFrame = "CFrame",
    },
    PoseBase = {
        Weight = 0,
    },
    PostEffect = {
        Enabled = false,
    },
    ProceduralModel = {
        Size = "Vector3",
    },
    ProximityPrompt = {
        ActionText = "", AutoLocalize = true, ClickablePrompt = true, Enabled = true, HoldDuration = 0,
        MaxActivationDistance = 10, MaxIndicatorDistance = 12, ObjectText = "", RequiresLineOfSight = true,
        UIOffset = "Vector2", MaxDistance = 10, Style = "Enum.ProximityPromptStyle.Default",
    },
    ProximityPromptService = {
        Enabled = true, MaxIndicatorsVisible = 4, MaxPromptsVisible = 4, PromptButtonHolder = nil,
    },
    PyramidHandleAdornment = {
        Height = 0, Sides = 0, Size = 0,
    },
    RbxAnalyticsService = {},
    ReflectionMetadataClass = {
        ExplorerImageIndex = 0, ExplorerOrder = 0, Insertable = false, PreferredParent = "",
    },
    ReflectionMetadataItem = {
        Browsable = false, ClassCategory = "", ClientOnly = false, Constraint = "", Deprecated = false,
        EditingDisabled = false, EditorType = "", FFlag = "", IsBackend = false, PropertyOrder = 0,
        ScriptContext = "", ServerOnly = false, SliderScaling = "", UIMaximum = 0, UIMinimum = 0,
        UINumTicks = 0,
    },
    RemoteEvent = {},
    RemoteFunction = {},
    RenderingTest = {
        CFrame = "CFrame", ComparisonDiffThreshold = 0, ComparisonPsnrThreshold = 0, Description = "",
        FieldOfView = 0, PerfTest = false, QualityAuto = false, QualityLevel = 0, RenderingTestFrameCount = 0,
        ShouldSkip = false, Ticket = "", Timeout = 0,
    },
    ReplicatedFirst = {},
    ReplicatedStorage = {},
    ReverbSoundEffect = {
        DecayTime = 0, Density = 0, Diffusion = 0, DryLevel = 0, WetLevel = 0,
    },
    RobloxReplicatedStorage = {},
    RocketPropulsion = {
        CartoonFactor = 0, MaxSpeed = 0, MaxThrust = 0, MaxTorque = "Vector3", TargetOffset = "Vector3",
        TargetRadius = 0, ThrustD = 0, ThrustP = 0, TurnD = 0, TurnP = 0,
    },
    RodConstraint = {
        Length = 0, LimitAngle0 = 0, LimitAngle1 = 0, LimitsEnabled = false, Thickness = 0,
    },
    RootImportData = {
        AddModelToInventory = false, Anchored = false, AnimationIdForRestPose = 0, ExistingPackageId = "",
        ImportAsModelAsset = false, ImportAsPackage = false, InsertInWorkspace = false, InsertWithScenePosition = false,
        InvertNegativeFaces = false, KeepZeroInfluenceBones = false, MergeMeshes = false, PreferredUploadId = 0,
        RigVisualization = false, ScaleFactor = 0, UseSceneOriginAsPivot = false, UsesCages = false,
        ValidateUgcBody = false, VersionedAssetId = 0,
    },
    RopeConstraint = {
        Length = 0, Restitution = 0, Thickness = 0, WinchEnabled = false, WinchForce = 0, WinchResponsiveness = 0,
        WinchSpeed = 0, WinchTarget = 0,
    },
    RunService = {
        ClientGitHash = "", FrameNumber = 0, RunState = "Enum.RunState.Running",
    },
    SafetyService = {
        IsCaptureModeForReport = false,
    },
    ScreenGui = {
        ClipToDeviceSafeArea = false, DisplayOrder = 0, IgnoreGuiInset = false,
    },
    ScreenshotHud = {
        CameraButtonPosition = "UDim2", CloseButtonPosition = "UDim2", CloseWhenScreenshotTaken = false,
        HideCoreGuiForCaptures = false, HidePlayerGuiForCaptures = false, Visible = false,
    },
    Script = {
        Source = "",
    },
    ScriptContext = {
        ScriptsDisabled = false,
    },
    ScriptProfilerService = {},
    ScrollingFrame = {
        CanvasPosition = "Vector2", CanvasSize = "UDim2", ScrollBarImageColor3 = "Color3", ScrollBarImageTransparency = 0,
        ScrollBarThickness = 8, ScrollingEnabled = true, ElasticBehavior = "Enum.ElasticBehavior.Always",
        AutomaticCanvasSize = "Enum.AutomaticSize.None",
    },
    Seat = {
        Disabled = false, Occupant = nil, IsSit = true,
    },
    SelectionBox = {
        LineThickness = 0.05, SurfaceColor3 = "Color3", SurfaceTransparency = 0, Transparency = 0,
        Adornee = nil, Color3 = "Color3",
    },
    SelectionPointLasso = {
        Point = "Vector3",
    },
    SelectionSphere = {
        SurfaceColor3 = "Color3", SurfaceTransparency = 0,
    },
    SelfViewConfiguration = {
        Open = false,
    },
    SessionService = {},
    ShirtGraphic = {
        Color3 = "Color3",
    },
    SkateboardPlatform = {
        Steer = 0, StickyWheels = false, Throttle = 0,
    },
    Sky = {
        CelestialBodiesShown = true, MoonAngularSize = 11, SkyboxOrientation = "Vector3", StarCount = 3000,
        SunAngularSize = 11, SunEnabled = true, MoonEnabled = true, SunTextureId = "rbxassetid://1683788242",
        MoonTextureId = "rbxasset://sky/moon.jpg", SkyboxBk = "rbxasset://textures/sky/sky512_bk.tex",
        SkyboxDn = "rbxasset://textures/sky/sky512_dn.tex", SkyboxFt = "rbxasset://textures/sky/sky512_ft.tex",
        SkyboxLf = "rbxasset://textures/sky/sky512_lf.tex", SkyboxRt = "rbxasset://textures/sky/sky512_rt.tex",
        SkyboxUp = "rbxasset://textures/sky/sky512_up.tex",
    },
    SlidingBallConstraint = {
        LimitsEnabled = false, LinearResponsiveness = 0, LowerLimit = 0, MotorMaxAcceleration = 0,
        MotorMaxForce = 0, Restitution = 0, ServoMaxForce = 0, Size = 0, Speed = 0, TargetPosition = 0,
        UpperLimit = 0, Velocity = 0,
    },
    Smoke = {
        Color = "Color3", Enabled = true, Opacity = 0.5, RiseVelocity = 1, Size = 1, TimeScale = 1,
        Lifetime = 1,
    },
    SocialService = {},
    Sound = {
        AcousticSimulationEnabled = false, LoopRegion = "NumberRange", Looped = false, PlayOnRemove = false,
        PlaybackRegion = "NumberRange", PlaybackRegionsEnabled = false, PlaybackSpeed = 1, Playing = false,
        RollOffMaxDistance = 10000, RollOffMinDistance = 10, TimePosition = 0, Volume = 0.5, Pitch = 1,
        RollOffMode = "Enum.RollOffMode.Inverse", EmitterSize = 0, RollOffGain = 1, MaxDistance = 10000,
        MinDistance = 10,
    },
    SoundEffect = {
        Enabled = false, Priority = 0,
    },
    SoundGroup = {
        Volume = 0,
    },
    SoundService = {
        AcousticSimulationEnabled = false, DiffractionEnabled = false, DistanceFactor = 3.32, DopplerScale = 1,
        ListenerCFrame = "CFrame", OcclusionEnabled = false, RespectFilteringEnabled = true, ReverbEnabled = false,
        RolloffScale = 1, IsNewExpForAudioApiByDefault = "Enum.RolloutState.Rollout", AmbientReverb = "Enum.ReverbType.NoReverb",
        AudioApiByDefault = "Enum.RolloutState.Rollout",
    },
    Sparkles = {
        Enabled = true, SparkleColor = "Color3", TimeScale = 1, Lifetime = 1, SparkleCount = 24,
    },
    SpawnLocation = {
        AllowTeamChangeOnTouch = false, Duration = 0, Enabled = false, Neutral = false,
    },
    SpecialMesh = {
        Scale = "Vector3", Offset = "Vector3", MeshType = "Enum.MeshType.Brick", VertexColor = "Color3",
        TextureID = "",
    },
    SphereHandleAdornment = {
        Radius = 0,
    },
    SpotLight = {
        Angle = 90, Range = 8, Brightness = 1, Shadows = false, Enabled = true, Face = "Enum.NormalId.Front",
    },
    SpringConstraint = {
        Coils = 0, Damping = 0, FreeLength = 0, LimitsEnabled = false, MaxForce = 0, MaxLength = 0,
        MinLength = 0, Radius = 0, Stiffness = 0, Thickness = 0,
    },
    StarterGui = {
        ShowDevelopmentGui = true, ProcessUserInput = false, ResetPlayerGuiOnSpawn = true, ScreenOrientation = "Enum.ScreenOrientation.Landscape",
        VRLaserPointerMode = "Enum.VRLaserPointerMode.Disabled",
    },
    StarterPlayer = {
        AutoJumpEnabled = false, CameraMaxZoomDistance = 128, CameraMinZoomDistance = 0.5, CharacterBreakJointsOnDeath = true,
        CharacterJumpHeight = 7.2, CharacterJumpPower = 50, CharacterMaxSlopeAngle = 89, CharacterUseJumpPower = false,
        CharacterWalkSpeed = 16, ClassicDeath = true, EnableMouseLockOption = true, HealthDisplayDistance = 100,
        LoadCharacterAppearance = true, NameDisplayDistance = 100, UserEmotesEnabled = true, AllowCustomAnimations = true,
        CreateDefaultPlayerModule = true, PlayerModuleStatus = 0,
    },
    Stats = {
        ProfilingWindow = "Enum.StatsProfilingWindow.TenSeconds",
    },
    StringValue = {
        Value = "",
    },
    StudioAttachment = {
        AutoHideParent = false, IsArrowVisible = false, Offset = "Vector2", SourceAnchorPoint = "Vector2",
        TargetAnchorPoint = "Vector2",
    },
    StudioService = {
        UseLocalSpace = false, AlignDraggedObjects = false, Secrets = "", HighlightColor = "Color3",
    },
    StyleDerive = {
        Priority = 0,
    },
    StyleRule = {
        Priority = 0, Selector = "",
    },
    SunRaysEffect = {
        Intensity = 0.25, Spread = 1, Enabled = true,
    },
    SurfaceAppearance = {
        Color = "Color3", EmissiveStrength = 0, EmissiveTint = "Color3",
    },
    SurfaceGui = {
        AlwaysOnTop = false, Brightness = 0, CanvasSize = "Vector2", ClipsDescendants = false, LightInfluence = 0,
        MaxDistance = 0, PixelsPerStud = 50, ToolPunchThroughDistance = 0, ZOffset = 0,
    },
    SurfaceGuiBase = {
        Active = false,
    },
    SurfaceLight = {
        Angle = 90, Range = 8, Brightness = 1, Shadows = false, Enabled = true, Face = "Enum.NormalId.Front",
    },
    SurfaceSelection = {
        LineThickness = 0.05, Transparency = 0, Adornee = nil, Face = "Enum.NormalId.Top",
    },
    SwimController = {
        AccelerationTime = 0, PitchMaxTorque = 0, PitchSpeedFactor = 0, RollMaxTorque = 0, RollSpeedFactor = 0,
    },
    SyncScriptBuilder = {
        CoverageInfo = false, DebugInfo = false, PackAsSource = false,
    },
    Team = {
        AutoAssignable = false,
    },
    Teams = {},
    TelemetryService = {},
    TeleportOptions = {
        ReservedServerAccessCode = "", ServerInstanceId = "", ShouldReserveServer = false,
    },
    TeleportService = {
        CustomizedTeleportUI = false,
    },
    Terrain = {
        WaterColor = "Color3", WaterReflectance = 0, WaterTransparency = 0, WaterWaveSize = 0, WaterWaveSpeed = 0,
        DecorationGridSize = 1024, GrassLength = "Enum.GrassSoleLength", SmoothVoxelsUpgraded = false,
        Decoration = false,
    },
    TerrainDetail = {
        EmissiveStrength = 0, EmissiveTint = "Color3", StudsPerTile = 0,
    },
    TestService = {
        AutoRuns = false, Description = "", ExecuteWithStudioRun = false, IsPhysicsEnvironmentalThrottled = false,
        IsSleepAllowed = false, NumberOfPlayers = 0, SimulateSecondsLag = 0, ThrottlePhysicsToRealtime = false,
        Timeout = 0,
    },
    TextBox = {
        ClearTextOnFocus = true, CursorPosition = -1, LineHeight = 0, MaxVisibleGraphemes = 0, MultiLine = false,
        OpenTypeFeatures = "", PlaceholderColor3 = "Color3", PlaceholderText = "", RichText = false,
        SelectionStart = -1, ShowNativeInput = true, Text = "", TextColor3 = "Color3", TextEditable = true,
        TextScaled = false, TextSize = 14, TextStrokeColor3 = "Color3", TextStrokeTransparency = 0,
        TextTransparency = 0, TextWrapped = false, BackgroundTransparency = 1, BorderSizePixel = 0,
        TextXAlignment = "Enum.TextXAlignment.Left", TextYAlignment = "Enum.TextYAlignment.Center",
        Font = "Enum.Font.SourceSans",
    },
    TextButton = {
        LineHeight = 0, MaxVisibleGraphemes = 0, OpenTypeFeatures = "", RichText = false, Text = "",
        TextColor3 = "Color3", TextScaled = false, TextSize = 14, TextStrokeColor3 = "Color3", TextStrokeTransparency = 0,
        TextTransparency = 0, TextWrapped = false, AutoButtonColor = true, Modal = false, BackgroundTransparency = 1,
        BorderSizePixel = 0, Font = "Enum.Font.SourceSans",
    },
    TextChatCommand = {
        AutocompleteVisible = false, Enabled = false, PrimaryAlias = "", SecondaryAlias = "",
    },
    TextChatMessage = {
        MessageId = "", Metadata = "", PrefixText = "", Text = "", Timestamp = "DateTime", Translation = "",
    },
    TextChatMessageProperties = {
        PrefixText = "", Text = "", Translation = "",
    },
    TextChatService = {
        ChatTranslationEnabled = false, CreateDefaultCommands = true, CreateDefaultTextChannels = true,
        ChatTranslationFTUXShown = false, ChatTranslationToggleEnabled = false, HasSeenDeprecationDialog = false,
        IsLegacyChatDisabled = false,
    },
    TextGenerator = {
        Seed = 0, SystemPrompt = "", Temperature = 0, TopP = 0,
    },
    TextLabel = {
        LineHeight = 0, MaxVisibleGraphemes = 0, OpenTypeFeatures = "", RichText = false, Text = "",
        TextColor3 = "Color3", TextScaled = false, TextSize = 14, TextStrokeColor3 = "Color3", TextStrokeTransparency = 0,
        TextTransparency = 0, TextWrapped = false, BackgroundTransparency = 1, BorderSizePixel = 0,
        TextXAlignment = "Enum.TextXAlignment.Left", TextYAlignment = "Enum.TextYAlignment.Center",
        Font = "Enum.Font.SourceSans",
    },
    TextSource = {
        CanSend = false,
    },
    Texture = {
        OffsetStudsU = 0, OffsetStudsV = 0, StudsPerTileU = 1, StudsPerTileV = 1, Transparency = 0,
        Color3 = "Color3",
    },
    TextureGenerationService = {},
    Tool = {
        CanBeDropped = true, Enabled = false, Grip = "CFrame", ManualActivationOnly = false, RequiresHandle = true,
        ToolTip = "",
    },
    Torque = {
        Torque = "Vector3",
    },
    TorsionSpringConstraint = {
        Coils = 0, Damping = 0, LimitsEnabled = false, MaxAngle = 0, MaxTorque = 0, Radius = 0,
        Restitution = 0, Stiffness = 0,
    },
    Trail = {
        Brightness = 1, Enabled = true, FaceCamera = false, Lifetime = 1, LightEmission = 0, LightInfluence = 0,
        MaxLength = 0, MinLength = 0.1, TextureLength = 1, TextureMode = "Enum.TextureMode.Stretch",
    },
    TremoloSoundEffect = {
        Depth = 0, Duty = 0, Frequency = 0,
    },
    TweenService = {},
    UGCValidationService = {},
    UIAspectRatioConstraint = {
        AspectRatio = 0,
    },
    UICorner = {
        BottomLeftRadius = "UDim", BottomRightRadius = "UDim", CornerRadius = "UDim", TopLeftRadius = "UDim",
        TopRightRadius = "UDim",
    },
    UIDragDetector = {
        DragAxis = "Vector2", DragRotation = 0, DragUDim2 = "UDim2", Enabled = false, MaxDragAngle = 0,
        MaxDragTranslation = "UDim2", MinDragAngle = 0, MinDragTranslation = "UDim2", SelectionModeDragSpeed = "UDim2",
        SelectionModeRotateSpeed = 0,
    },
    UIFlexItem = {
        GrowRatio = 0, ShrinkRatio = 0,
    },
    UIGradient = {
        Enabled = false, Offset = "Vector2", Rotation = 0, Scale = 0,
    },
    UIGridLayout = {
        CellPadding = "UDim2", CellSize = "UDim2", FillDirectionMaxCells = 0,
    },
    UIListLayout = {
        Padding = "UDim", Wraps = false,
    },
    UIPadding = {
        PaddingBottom = "UDim", PaddingLeft = "UDim", PaddingRight = "UDim", PaddingTop = "UDim",
    },
    UIPageLayout = {
        Animated = false, Circular = false, GamepadInputEnabled = false, Padding = "UDim", ScrollWheelInputEnabled = false,
        TouchInputEnabled = false, TweenTime = 0,
    },
    UIScale = {
        Scale = 0,
    },
    UIShadow = {
        BlurRadius = "UDim", Color = "Color3", Enabled = false, Offset = "UDim2", Spread = "UDim2",
        Transparency = 0, ZIndex = 0,
    },
    UISizeConstraint = {
        MaxSize = "Vector2", MinSize = "Vector2",
    },
    UIStroke = {
        BorderOffset = "UDim", Color = "Color3", Enabled = false, Thickness = 0, Transparency = 0,
        ZIndex = 0,
    },
    UITableLayout = {
        FillEmptySpaceColumns = false, FillEmptySpaceRows = false, Padding = "UDim2",
    },
    UITextSizeConstraint = {
        MaxTextSize = 0, MinTextSize = 0,
    },
    UniversalConstraint = {
        LimitsEnabled = false, MaxAngle = 0, Radius = 0, Restitution = 0,
    },
    UserGameSettings = {
        GamepadCameraSensitivity = 0, MouseSensitivity = 0, RCCProfilerRecordFrameRate = 0, RCCProfilerRecordTimeFrame = 0,
        VRSmoothRotationEnabled = false, VignetteEnabled = false,
    },
    UserInputService = {
        MouseDeltaSensitivity = 1, MouseIconEnabled = true, LegacyInputEventsEnabled = true, ModalEnabled = false,
        AccelerometerEnabled = false, GamepadEnabled = true, GyroscopeEnabled = false, KeyboardEnabled = true,
        TouchEnabled = false, VREnabled = false, MouseBehavior = "Enum.MouseBehavior.Default", MouseIcon = "rbxasset://textures/ArrowCursor.png",
    },
    UserService = {},
    VRService = {
        AvatarGestures = false, FadeOutViewOnCollision = true, QuestASWState = false, QuestDisplayRefreshRate = 0,
        AutomaticThermalStatus = "Enum.RolloutState.Rollout",
    },
    Vector3Value = {
        Value = "Vector3",
    },
    VectorForce = {
        ApplyAtCenterOfMass = false, Force = "Vector3",
    },
    VehicleSeat = {
        Disabled = false, HeadsUpDisplay = false, MaxSpeed = 0, Steer = 0, SteerFloat = 0, Throttle = 0,
        ThrottleFloat = 0, Torque = 0, TurnSpeed = 0, IsSit = true,
    },
    VelocityMotor = {
        CurrentAngle = 0, DesiredAngle = 0, MaxVelocity = 0,
    },
    VideoCaptureService = {
        Active = false, CameraID = "",
    },
    VideoDeviceInput = {
        Active = false, CameraId = "",
    },
    VideoDisplay = {
        TileSize = "UDim2", VideoColor3 = "Color3", VideoRectOffset = "Vector2", VideoRectSize = "Vector2",
        VideoTransparency = 0,
    },
    VideoFrame = {
        Looped = false, Playing = false, RollOffMaxDistance = 0, RollOffMinDistance = 0, TimePosition = 0,
        Volume = 0,
    },
    VideoPlayer = {
        Looping = false, PlaybackSpeed = 0, TimePosition = 0, Volume = 0,
    },
    ViewportFrame = {
        Ambient = "Color3", ImageColor3 = "Color3", ImageTransparency = 0, LightColor = "Color3",
        LightDirection = "Vector3",
    },
    VoiceChatService = {
        EnableDefaultVoice = true, UseNewAudioApi = "Enum.RolloutState.Rollout", UseNewControlPaths = false,
        UseNewJoinFlow = "Enum.RolloutState.Rollout", UseStreamSwitching = "Enum.RolloutState.Rollout",
        VoiceChatEnabledForPlaceOnRcc = false, VoiceChatEnabledForUniverseOnRcc = false,
    },
    WeldConstraint = {
        Enabled = false,
    },
    Wire = {
        SourceName = "", TargetName = "",
    },
    WireframeHandleAdornment = {
        Scale = "Vector3", Thickness = 0,
    },
    Workspace = {
        AirDensity = 0, AirTurbulenceIntensity = 0, AllowThirdPartySales = false,
        FallHeightEnabled = false, FallenPartsDestroyHeight = -500, GlobalWind = "Vector3", Gravity = 196.2,
        InsertPoint = "Vector3", StreamingEnabled = false, FilteringEnabled = true, StreamingMinRadius = 0,
        StreamingTargetRadius = 0, TouchesUseCollisionGroups = false,
    },
    WorldModel = {},
    WrapLayer = {
        BindOffset = "CFrame", Enabled = false, Order = 0, ReferenceOrigin = "CFrame",
    },
    WrapTextureTransfer = {
        UVMaxBound = "Vector2", UVMinBound = "Vector2",
    },
}


makeProxy = function(name: string): any
    local children = {}
    local storedValues = {}
    local setKeys = {}
    local mt = {
        _name = name,
        _isProxy = true,
        _parent = nil,
        _fieldName = nil,
        _descriptive = false,
        _storedValues = storedValues,
        _setKeys = setKeys,
    }
    mtRef = mt
    mt.__index = function(t, k)
        tick()
        local ks = tostring(k)
        if ks == "DistributedGameTime" and not setKeys[ks] then
            return os.clock()
        end
        if ks == "Parent" and not setKeys[ks] then
            return nil
        end
        if mt._className == "EnumItem" and ks == "EnumType" then
            local val = mt._storedValues and mt._storedValues["EnumType"]
            if type(val) == "string" then
                local cached = _G._enumCache and _G._enumCache[val]
                if cached then
                    mt._storedValues["EnumType"] = cached
                    return cached
                end
            end
            return val
        end
        if setKeys[ks] then
            return storedValues[ks]
        end
        if ks == "Parent" and destroyedInstances[name] then
            return nil
        end
        if mt._className == "DataModel" and isApiServiceClass(ks) then
            if not serviceCache[ks] then
                if SERVER_ONLY_SERVICES[ks] then
                    error(ks .. " is not a valid member of DataModel \"DataModel\"", 2)
                end
                local svc = spyInstance(ks, ks:lower(), true)
                serviceCache[ks] = svc
                if ks == "Workspace" and workspaceProxy then
                    serviceCache[ks] = workspaceProxy
                end
            end
            return serviceCache[ks]
        end
        if mt._className == "Players" and ks == "LocalPlayer" then
            if not children[ks] then
                local player = spyInstance("Player", "LocalPlayer", true)
                local pmt = getmetatable(player)
                pmt._storedValues["UserId"] = 0
                pmt._setKeys["UserId"] = true
                pmt._storedValues["Character"] = nil
                pmt._setKeys["Character"] = true
                pmt._storedValues["AccountAge"] = 0
                pmt._setKeys["AccountAge"] = true
                pmt._storedValues["DisplayName"] = "Player"
                pmt._setKeys["DisplayName"] = true
                children[ks] = player
            end
            return children[ks]
        end
        if mt._className == "Workspace" and ks == "CurrentCamera" then
            if not children[ks] then
                local cam = spyInstance("Camera", "CurrentCamera", true)
                children[ks] = cam
            end
            return children[ks]
        end
        if ks == "MembershipType" and mt._className == "Player" and not setKeys[ks] then
            local cached = _G._enumCache and _G._enumCache["MembershipType.None"]
            if cached then return cached end
        end
        if ks == "ClassName" and mt._className then
            return mt._className
        end
        if ks == "DistributedGameTime" then
            return os.time()
        end
        if ks == "Workspace.CurrentCamera" or (mt._className == "Workspace" and ks == "CurrentCamera") then
            if not children[ks] then
                local cam = spyInstance("Camera", "CurrentCamera", true)
                children[ks] = cam
            end
            return children[ks]
        end
        if mt._className == "EnumItem" and (ks == "Value" or ks == "Name" or ks == "EnumType") then
            if ks == "Value" then
                if mt._storedValues and mt._storedValues["Value"] ~= nil then
                    return mt._storedValues["Value"]
                end
                local ENUM_VALUES = {
                    ["Enum.Material.Plastic"] = 256,
                    ["Enum.Material.Plastic.Value"] = 256,
                }
                local fullName = mt._name or ""
                if mt._storedValues and mt._storedValues["EnumType"] and mt._storedValues["Name"] then
                    fullName = "Enum." .. mt._storedValues["EnumType"] .. "." .. mt._storedValues["Name"]
                end
                return ENUM_VALUES[fullName] or 256
            end
            if ks == "Name" then
                if mt._storedValues and mt._storedValues["Name"] then
                    return mt._storedValues["Name"]
                end
                return mt._name or ""
            end
            if ks == "EnumType" then
                if mt._storedValues and mt._storedValues["EnumType"] then
                    local val = mt._storedValues["EnumType"]
                    if type(val) == "string" then
                        local cached = _G._enumCache and _G._enumCache[val]
                        if cached then
                            mt._storedValues["EnumType"] = cached
                            return cached
                        else
                            return val
                        end
                    end
                    return val
                end
                return nil
            end
        end
        if ks == "Changed" or ks == "changed" or ks == "Heartbeat" or ks == "RenderStepped" or ks == "Stepped" or ks == "ChildAdded" or ks == "ChildRemoved" or ks == "DescendantAdded" or ks == "DescendantRemoving" or ks == "AncestryChanged" or ks == "Destroying" then
            if not children[ks] then
                local child = makeProxy(name .. "." .. ks)
                local cmt = getmetatable(child)
                cmt._parent = t
                cmt._fieldName = ks
                cmt._signalForEvent = { proxy = t, eventName = ks }
                children[ks] = child
            end
            return children[ks]
        end
        local KNOWN_METHODS = {
            SetItem = true, GetItem = true, IsVibrationSupported = true,
            GetCorescriptLocalizations = true, IsAvailable = true, HasAchieved = true,
            GetRealPhysicsFPS = true, GetPhysicsFPS = true,
            SetMetadata = true, GetMetadata = true,
            AddVertex = true, GetVertices = true, GetPosition = true,
            CreateEditableMesh = true,
            Disconnect = true, Connect = true, Once = true,
            PromptPremiumPurchase = true, PromptPurchase = true,
            GetProductInfo = true, GetDeveloperProductsAsync = true,
            GetTranslatorForLocaleAsync = true, GetTableEntries = true,
            RemoveItem = true,
        }
        if KNOWN_METHODS[ks] then
            if not children[ks] then
                local child = makeProxy(name .. "." .. ks)
                local cmt = getmetatable(child)
                cmt._parent = t
                cmt._fieldName = ks
                cmt._isMethod = true
                children[ks] = child
            end
            return children[ks]
        end
        local memberInfo = resolveApiMember(mt._className or "", ks)
        if isScriptableFunctionMember(memberInfo) then
            if not children[ks] then
                local child = makeProxy(name .. "." .. ks)
                local cmt = getmetatable(child)
                cmt._parent = t
                cmt._fieldName = ks
                cmt._memberType = memberInfo.memberType
                children[ks] = child
            end
            return children[ks]
        end
        if isEventMember(memberInfo) then
            if not children[ks] then
                local child = makeProxy(name .. "." .. ks)
                local cmt = getmetatable(child)
                cmt._parent = t
                cmt._fieldName = ks
                cmt._memberType = memberInfo.memberType
                cmt._signalForEvent = { proxy = t, eventName = ks }
                children[ks] = child
            end
            return children[ks]
        end
        if mt._ctorArgs and (ks == "X" or ks == "Y" or ks == "Z" or ks == "W") and mt._ctorName ~= "UDim2" and mt._ctorName ~= "UDim" then
            local idx = ({ X = 1, Y = 2, Z = 3, W = 4 })[ks]
            local val = mt._ctorArgs[idx]
            if type(val) == "number" then return val end
        end
        if mt._ctorArgs and (ks == "R" or ks == "G" or ks == "B") and mt._ctorName == "Color3" then
            local idx = ({ R = 1, G = 2, B = 3 })[ks]
            local val = mt._ctorArgs[idx]
            if type(val) == "number" then return val end
        end
        if mt._ctorName == "Vector3" and ks == "Magnitude" then
            local x = mt._ctorArgs[1] or 0
            local y = mt._ctorArgs[2] or 0
            local z = mt._ctorArgs[3] or 0
            return math.sqrt(x*x + y*y + z*z)
        end
        if mt._ctorName == "Vector2" and ks == "Magnitude" then
            local x = mt._ctorArgs[1] or 0
            local y = mt._ctorArgs[2] or 0
            return math.sqrt(x*x + y*y)
        end
        if mt._ctorName == "Vector2" and (ks == "X" or ks == "Y") then
            local idx = ({ X = 1, Y = 2 })[ks]
            local args = mt._ctorArgs or {}
            local val = args[idx]
            if type(val) == "number" then return val end
            return 0
        end
        if mt._ctorName == "Vector3" and (ks == "X" or ks == "Y" or ks == "Z") then
            local idx = ({ X = 1, Y = 2, Z = 3 })[ks]
            local args = mt._ctorArgs or {}
            local val = args[idx]
            if type(val) == "number" then return val end
            return 0
        end
        if mt._ctorName == "Vector3" and (ks == "Unit" or ks == "LookVector" or ks == "RightVector" or ks == "UpVector") then
            local v = makeProxy(name .. "." .. ks)
            local vmt = getmetatable(v)
            vmt._ctorName = "Vector3"
            vmt._ctorArgs = mt._ctorArgs or { 1, 0, 0 }
            return v
        end
        if mt._ctorName == "Vector2" and ks == "Unit" then
            local v = makeProxy(name .. "." .. ks)
            local vmt = getmetatable(v)
            vmt._ctorName = "Vector2"
            vmt._ctorArgs = mt._ctorArgs or { 1, 0 }
            return v
        end
        if mt._ctorName == "UDim2" and (ks == "X" or ks == "Y") then
            local idx = ({ X = 1, Y = 2 })[ks]
            local args = mt._ctorArgs or {0, 0, 0, 0}
            local scale = args[idx*2-1] or 0
            local offset = args[idx*2] or 0
            local u = makeProxy(name .. "." .. ks)
            local umt = getmetatable(u)
            umt._ctorName = "UDim"
            umt._ctorArgs = { scale, offset }
            return u
        end
        if mt._ctorName == "UDim" and (ks == "Scale" or ks == "Offset") then
            local idx = ({ Scale = 1, Offset = 2 })[ks]
            local args = mt._ctorArgs or {0, 0}
            local val = args[idx]
            if type(val) == "number" then return val end
            return 0
        end
        if mt._ctorName == "NumberRange" and (ks == "Min" or ks == "Max") then
            local idx = ({ Min = 1, Max = 2 })[ks]
            local val = mt._ctorArgs[idx]
            if type(val) == "number" then return val end
            if #mt._ctorArgs == 1 then return mt._ctorArgs[1] end
            return 0
        end
        if (mt._ctorName == "Axes" or mt._ctorName == "Faces") and
           (ks == "X" or ks == "Y" or ks == "Z" or ks == "Top" or ks == "Bottom" or
            ks == "Left" or ks == "Right" or ks == "Front" or ks == "Back") then
            if mt._ctorArgs then
                for _, arg in ipairs(mt._ctorArgs) do
                    if isProxy(arg) then
                        local am = getmetatable(arg)
                        if am and am._name and am._name:find(ks) then return true end
                    end
                end
            end
            return false
        end
        if mt._ctorName == "Ray" and (ks == "Origin" or ks == "Direction") then
            local idx = ({ Origin = 1, Direction = 2 })[ks]
            return mt._ctorArgs[idx] or makeProxy(name .. "." .. ks)
        end
        if mt._ctorName == "Rect" and (ks == "Min" or ks == "Max") then
            local idx = ({ Min = 1, Max = 2 })[ks]
            return mt._ctorArgs[idx] or makeProxy(name .. "." .. ks)
        end
        if mt._ctorName == "Region3" and ks == "Size" then
            return makeProxy(name .. ".Size")
        end
        if mt._ctorName == "PathWaypoint" and (ks == "Position" or ks == "Action") then
            local idx = ({ Position = 1, Action = 2 })[ks]
            return mt._ctorArgs[idx] or makeProxy(name .. "." .. ks)
        end
        if mt._ctorName == "TweenInfo" and (ks == "Time" or ks == "EasingStyle" or ks == "EasingDirection" or ks == "RepeatCount" or ks == "Reverses" or ks == "DelayTime") then
            local defaults = { Time = 1, EasingStyle = "Quad", EasingDirection = "In", RepeatCount = 0, Reverses = false, DelayTime = 0 }
            local val = mt._ctorArgs[({Time=1,EasingStyle=2,EasingDirection=3,RepeatCount=4,Reverses=5,DelayTime=6})[ks]]
            if val ~= nil then return val end
            return defaults[ks]
        end
        if mt._ctorName == "PhysicalProperties" and (ks == "Friction" or ks == "Elasticity" or ks == "ElasticityWeight" or ks == "FrictionWeight" or ks == "Density") then
            local idx = ({ Friction = 1, Elasticity = 2, ElasticityWeight = 3, FrictionWeight = 4, Density = 5 })[ks]
            local val = mt._ctorArgs and mt._ctorArgs[idx]
            if type(val) == "number" then return val end
            return 0
        end
        if mt._ctorName == "Region3" and ks == "Size" then
            local v = makeProxy(name .. ".Size")
            local vmt = getmetatable(v)
            vmt._ctorName = "Vector3"
            vmt._ctorArgs = { 0, 0, 0 }
            return v
        end
        if mt._ctorName == "Region3int16" and (ks == "Min" or ks == "Max") then
            local idx = ({ Min = 1, Max = 2 })[ks]
            local v = makeProxy(name .. "." .. ks)
            local vmt = getmetatable(v)
            vmt._ctorName = "Vector3int16"
            vmt._ctorArgs = mt._ctorArgs and { mt._ctorArgs[idx*3-2] or 0, mt._ctorArgs[idx*3-1] or 0, mt._ctorArgs[idx*3] or 0 } or { 0, 0, 0 }
            return v
        end
        if (mt._ctorName == "Vector2int16" or mt._ctorName == "Vector3int16") and (ks == "X" or ks == "Y" or ks == "Z") then
            local idx = ({ X = 1, Y = 2, Z = 3 })[ks]
            local val = mt._ctorArgs and mt._ctorArgs[idx]
            if type(val) == "number" then return math.floor(val) end
            return 0
        end
        if mt._ctorName == "FloatCurveKey" and ks == "Time" then
            local val = mt._ctorArgs[1]
            if type(val) == "number" then return val end
        end
        if mt._ctorName == "RotationCurveKey" and ks == "Time" then
            local val = mt._ctorArgs[1]
            if type(val) == "number" then return val end
        end
        if mt._ctorName == "ValueCurveKey" and ks == "Time" then
            local val = mt._ctorArgs[1]
            if type(val) == "number" then return val end
        end
        if numericPseudoProps[ks] then
            return 0
        end

        local memberDefaultValue = nil
        memberDefaultValue, memberInfo = getMemberDefaultValue(mt._className or "", ks, name .. "." .. ks)
        if memberDefaultValue ~= nil then
            if isProxy(memberDefaultValue) then
                local cmt = getmetatable(memberDefaultValue)
                cmt._parent = t
                cmt._fieldName = ks
            end
            children[ks] = memberDefaultValue
            return memberDefaultValue
        end
        if memberInfo ~= nil then
            return nil
        end

        local cls = mt._className or ""
        local clsInfo = getApiClassInfo(cls)
        local chain = {}
        local cur = clsInfo
        while cur do
            table.insert(chain, cur.name)
            if type(cur.superclass) ~= "string" or cur.superclass == "" then break end
            cur = getApiClassInfo(cur.superclass)
        end
        for i = 1, #chain do
            local defaults = classDefaultProperties[chain[i]]
            if defaults and defaults[ks] ~= nil then
                local dv = defaults[ks]
                if dv == "Color3" then
                    local c = makeProxy(name .. "." .. ks)
                    local cmt = getmetatable(c)
                    cmt._ctorName = "Color3"
                    cmt._ctorArgs = { 0.631373, 0.647059, 0.631373 }
                    storedValues[ks] = c
                    setKeys[ks] = true
                    return c
                elseif dv == "Vector3" then
                    local v = makeProxy(name .. "." .. ks)
                    local vmt = getmetatable(v)
                    vmt._ctorName = "Vector3"
                    vmt._ctorArgs = { 0, 0, 0 }
                    storedValues[ks] = v
                    setKeys[ks] = true
                    return v
                elseif dv == "Vector2" then
                    local v = makeProxy(name .. "." .. ks)
                    local vmt = getmetatable(v)
                    vmt._ctorName = "Vector2"
                    vmt._ctorArgs = { 0, 0 }
                    storedValues[ks] = v
                    setKeys[ks] = true
                    return v
                elseif dv == "UDim2" then
                    local u = makeProxy(name .. "." .. ks)
                    local umt = getmetatable(u)
                    umt._ctorName = "UDim2"
                    umt._ctorArgs = { 0, 0, 0, 0 }
                    storedValues[ks] = u
                    setKeys[ks] = true
                    return u
                elseif dv == "CFrame" then
                    local cf = makeProxy(name .. "." .. ks)
                    local cfmt = getmetatable(cf)
                    cfmt._ctorName = "CFrame"
                    cfmt._ctorArgs = { 0, 0, 0 }
                    storedValues[ks] = cf
                    setKeys[ks] = true
                    return cf
                elseif dv == "NumberRange" then
                    local nr = makeProxy(name .. "." .. ks)
                    local nrmt = getmetatable(nr)
                    nrmt._ctorName = "NumberRange"
                    nrmt._ctorArgs = { 0, 0 }
                    storedValues[ks] = nr
                    setKeys[ks] = true
                    return nr
                elseif type(dv) == "string" and dv:match("^Enum%.") then
                    local enumItem = makeProxy(name .. "." .. ks)
                    local eimt = getmetatable(enumItem)
                    eimt._className = "EnumItem"
                    eimt._ctorName = "EnumItem"
                    eimt._storedValues["Name"] = dv:sub(dv:find("%.[^%.]*$") + 1, -1)
                    eimt._storedValues["Value"] = 0
                    eimt._storedValues["EnumType"] = dv:match("^Enum%.([%w_]+)%.")
                    storedValues[ks] = enumItem
                    setKeys[ks] = true
                    return enumItem
                else
                    storedValues[ks] = dv
                    setKeys[ks] = true
                    return dv
                end
            end
        end

        if booleanPseudoProps[ks] then
            return false
        end
        if stringPseudoProps[ks] then
            return ""
        end
        if color3PseudoProps[ks] then
            local c = makeProxy(name .. "." .. ks)
            local cmt = getmetatable(c)
            cmt._ctorName = "Color3"
            cmt._ctorArgs = { 0.631373, 0.647059, 0.631373 }
            storedValues[ks] = c
            setKeys[ks] = true
            return c
        end
        if vector3PseudoProps[ks] then
            local v = makeProxy(name .. "." .. ks)
            local vmt = getmetatable(v)
            vmt._ctorName = "Vector3"
            vmt._ctorArgs = { 0, 0, 0 }
            storedValues[ks] = v
            setKeys[ks] = true
            return v
        end
        if udim2PseudoProps[ks] then
            local u = makeProxy(name .. "." .. ks)
            local umt = getmetatable(u)
            umt._ctorName = "UDim2"
            umt._ctorArgs = { 0, 0, 0, 0 }
            storedValues[ks] = u
            setKeys[ks] = true
            return u
        end

        if not children[ks] then
            local cls = mt._className or ""
            local knownMember = resolveApiMember(cls, ks)
            if cls ~= "" and not knownMember and not string.find(ks, "^_") and not ks:match("^ThemeTag$") and not ks:match("^LibraryGradient$") then
                local lowerKs = ks:lower()
                local isLowerKnown = false
                for _, m in ipairs({"name", "parent", "classname"}) do
                    if lowerKs == m then isLowerKnown = true break end
                end
                if not isLowerKnown then
                    if not string.match(ks, "^[%u][%w]*$") and not string.match(ks, "^[%a][%w_]*$") then
                    else
                        error(ks .. " is not a valid member of " .. (cls or "Instance") .. " \"" .. (mt._name or "") .. "\"", 2)
                    end
                end
            end
            local child = makeProxy(name .. "." .. ks)
            local cmt = getmetatable(child)
            cmt._parent = t
            cmt._fieldName = ks
            children[ks] = child
        end
        return children[ks]
    end
    mt.__newindex = function(t, k, v)
        tick()
        local ks = tostring(k)
        local cls = mt._className or ""
        local memberInfo = resolveApiMember(cls, ks)
        if memberInfo and not isWritablePropertyMember(memberInfo) then
            error("attempt to set a read-only property '" .. ks .. "'", 2)
        end
        if positiveNumberProps[ks] and type(v) == "number" and v < 0 then
            v = 0
        end
        storedValues[ks] = v
        setKeys[ks] = true
        if ks == "Name" and type(v) == "string" then
            mt._name = v
        end
        if ks == "Parent" and v ~= nil and not isProxy(v) then
            error("attempt to set Parent to a non-Instance value", 2)
        end
        if ks == "Parent" and isProxy(v) then
            local parentName = getmetatable(v)._name
            local childName = name
            local childDisplayName = storedValues["Name"] or childName
            if not parentChildMap[parentName] then parentChildMap[parentName] = {} end
            parentChildMap[parentName][childDisplayName] = t
            parentChildMap[parentName][childName] = t
            if storedValues["Anchored"] == false then
                if not unanchoredParts[t] then
                    unanchoredParts[t] = true
                    awakePartsCount += 1
                end
            end
        end
        if ks == "Parent" and v == nil then
            if unanchoredParts[t] then
                unanchoredParts[t] = nil
                if awakePartsCount > 0 then
                    awakePartsCount -= 1
                end
            end
        end
        if ks == "AssemblyLinearVelocity" and isProxy(v) then
            local velMt = getmetatable(v)
            if velMt and velMt._ctorArgs then
                local vx = velMt._ctorArgs[1] or 0
                storedValues["Position"] = makeProxy(name .. ".Position")
                local posMt = getmetatable(storedValues["Position"])
                posMt._ctorArgs = { 0, -500, 0 }
                posMt._ctorName = "Vector3"
                storedValues["Parent"] = nil
            end
        end
        if ks == "Anchored" then
            local cls = mt._className or ""
            local isPartLike = (cls == "Part" or cls == "BasePart" or cls == "TrussPart" or cls == "WedgePart" or cls == "CornerWedgePart" or cls == "MeshPart" or cls == "UnionOperation" or cls == "NegateOperation" or cls == "Seat" or cls == "VehicleSeat")
            if isPartLike and storedValues["Parent"] ~= nil then
                if v == false then
                    if not unanchoredParts[t] then
                        unanchoredParts[t] = true
                        awakePartsCount += 1
                    end
                else
                    if unanchoredParts[t] then
                        unanchoredParts[t] = nil
                        if awakePartsCount > 0 then
                            awakePartsCount -= 1
                        end
                    end
                end
            end
        end
        if isProxy(v) then
            markUsed(v)
            emit(string.format('%s.%s = %s', name, ks, proxyName(v)))
        elseif type(v) == "function" then
            emit(string.format('%s.%s = function() end', name, ks))
        else
            emit(string.format('%s.%s = %s', name, ks, serialize(v)))
        end
        firePropertyChange(name, ks, v)
    end
    mt.__call = function(t, ...)
        tick()
        local args = {...}
        local n = select("#", ...)
        local parts = {}
        local callExpr
        local startIdx = 1

        local cmt = getmetatable(t)
        local parent = cmt._parent
        local fieldName = cmt._fieldName

        local STATEMENT_METHODS = {
            Connect = true, connect = true, Once = true, Disconnect = true,
            Wait = true, wait = true, Destroy = true, Remove = true,
            ClearAllChildren = true, DisconnectAll = true,
            Init = true, Notify = true,
            FireServer = true, FireClient = true, FireAllClients = true,
            InvokeServer = true, InvokeClient = true,
            Set = true, set = true, Add = true, Remove = true,
            CaptureController = true, ClickButton1 = true, ClickButton2 = true,
            GetChildren = true, GetDescendants = true,
            SetItem = true, GetItem = true,
            IsVibrationSupported = true, GetCorescriptLocalizations = true,
            IsAvailable = true, HasAchieved = true,
            GetRealPhysicsFPS = true, GetPhysicsFPS = true,
            GetAsync = true, PostAsync = true, RequestAsync = true,
            HttpGet = true, HttpPost = true, HttpRequest = true,
            JSONEncode = true, JSONDecode = true,
            SetCore = true, GetCore = true,
            FindFirstChild = true, WaitForChild = true,
            FindFirstDescendant = true, FindFirstAncestor = true,
            IsA = true, Clone = true,
            SetMetadata = true, GetMetadata = true,
        }

        local isMethod = false
        if parent and n >= 1 and rawequal(args[1], parent) then
            callExpr = proxyName(parent) .. ":" .. fieldName
            markUsed(parent)
            startIdx = 2
            isMethod = true
        elseif parent and STATEMENT_METHODS[fieldName] then
            callExpr = proxyName(parent) .. ":" .. fieldName
            markUsed(parent)
            isMethod = true
        else
            if not parent and not fieldName then
                error("attempt to call a Instance value", 2)
            end
            callExpr = name
        end

        if _G._yieldTick and (fieldName == "Wait" or fieldName == "wait") then
            _G._yieldTick()
        end

        for i = startIdx, n do
            table.insert(parts, serialize(args[i]))
        end

        local firstArg = args[startIdx]
        local baseName = makeDescriptiveVar(fieldName, firstArg)
        local retName = baseName
        if usedVarNames[retName] then
            local i = 2
            while usedVarNames[baseName .. tostring(i)] do
                i += 1
            end
            retName = baseName .. tostring(i)
        end
        usedVarNames[retName] = true

        local isStatementCall = isMethod and STATEMENT_METHODS[fieldName] ~= nil

        if isMethod and fieldName == "GetService" and parent and type(firstArg) == "string" then
            local parentName = proxyName(parent)
            local serviceName = firstArg
            if serviceName == "Workspace" or serviceName == "workspace" then
                emit(string.format('local %s = %s:GetService(%s)', serviceName, parentName, serialize(firstArg)))
                if workspaceProxy then
                    serviceCache["Workspace"] = workspaceProxy
                    return workspaceProxy
                end
            end
            if serviceName == "DebuggerManager" then
                emit(string.format('local %s = %s:GetService(%s)', serviceName, parentName, serialize(firstArg)))
                error("GetService: DebuggerManager not available", 0)
            end
            if SERVER_ONLY_SERVICES[serviceName] then
                emit(string.format('local %s = %s:GetService(%s)', serviceName, parentName, serialize(firstArg)))
                error("GetService: " .. serviceName .. " is not a valid service", 0)
            end
            if not isApiServiceClass(serviceName) then
                emit(string.format('local %s = %s:GetService(%s)', serviceName, parentName, serialize(firstArg)))
                error("GetService: " .. serviceName .. " is not a valid service", 0)
            end
            if serviceCache[serviceName] then
                emit(string.format('local %s = %s:GetService(%s)', serviceName, parentName, serialize(firstArg)))
                return serviceCache[serviceName]
            end
            local serviceProxy = makeProxy(serviceName)
            local serviceMt = getmetatable(serviceProxy)
            serviceMt._className = serviceName
            serviceMt._storedValues["ClassName"] = serviceName
            serviceMt._setKeys["ClassName"] = true
            if serviceName == "Chat" then
                local ugcParent = spyInstance("DataModel", "ugc", true)
                local ugcMt = getmetatable(ugcParent)
                ugcMt._storedValues["Name"] = "Ugc"
                ugcMt._setKeys["Name"] = true
                serviceMt._storedValues["Parent"] = ugcParent
                serviceMt._setKeys["Parent"] = true
            elseif serviceName == "NetworkClient" then
                local cr = spyInstance("ClientReplicator", "ClientReplicator", true)
                if not parentChildMap[serviceName] then parentChildMap[serviceName] = {} end
                parentChildMap[serviceName]["ClientReplicator"] = cr
            end
            serviceCache[serviceName] = serviceProxy
            emit(string.format('local %s = %s:GetService(%s)', serviceName, parentName, serialize(firstArg)))
            return serviceProxy
        end

        if isMethod and fieldName == "GetPropertyChangedSignal" and parent and type(firstArg) == "string" then
            local parentName = proxyName(parent)
            local parentMt = getmetatable(parent)
            local cls = parentMt and parentMt._className or ""
            local memberInfo = resolveApiMember(cls, firstArg)
            if not isPropertyMember(memberInfo) and cls ~= "" and cls ~= nil then
                emit(string.format('local %s = %s:GetPropertyChangedSignal(%s)', retName, parentName, serialize(firstArg)))
                error(firstArg .. " is not a valid member of " .. cls .. " \"" .. parentName .. "\"", 0)
            end
            local signalProxy = makeProxy(retName)
            local signalMt = getmetatable(signalProxy)
            signalMt._signalForProperty = { proxy = parent, propName = firstArg }
            emit(string.format('local %s = %s:GetPropertyChangedSignal(%s)', retName, parentName, serialize(firstArg)))
            return signalProxy
        end

        if isMethod and (fieldName == "Connect" or fieldName == "connect") and parent then
            local callback = firstArg
            if type(callback) == "function" then
                local parentMt = getmetatable(parent)
                if parentMt and parentMt._signalForProperty then
                    local sigInfo = parentMt._signalForProperty
                    local proxyNameStr = proxyName(sigInfo.proxy)
                    local propName = sigInfo.propName
                    local key = proxyNameStr .. "." .. propName
                    if not propertyChangeCallbacks[key] then
                        propertyChangeCallbacks[key] = {}
                    end
                    table.insert(propertyChangeCallbacks[key], callback)
                end
                local parentNameStr = ""
                local pm = getmetatable(parent)
                if pm and pm._isProxy then parentNameStr = pm._name end
                local eventName = ""
                if pm and pm._signalForEvent then eventName = pm._signalForEvent.eventName or "" end
                if eventName ~= "" then
                    table.insert(eventConnections, {
                        proxy = pm._signalForEvent.proxy,
                        eventName = eventName,
                        callback = callback,
                    })
                    if eventName == "Heartbeat" or eventName == "Stepped" or eventName == "RenderStepped" then
                        local baseTime = os.clock()
                        for i = 1, 10 do
                            pcall(callback, 0.015, baseTime + i * 0.015)
                        end
                    else
                        pcall(callback, makeProxy("eventArgs"))
                    end
                end
            end
            local connProxy = makeProxy(retName)
            local connMt = getmetatable(connProxy)
            connMt._className = "RBXScriptConnection"
            connMt._storedValues["Connected"] = true
            connMt._setKeys["Connected"] = true
            connMt._storedValues["ClassName"] = "RBXScriptConnection"
            connMt._setKeys["ClassName"] = true
            emit(string.format('local %s = %s(%s)', retName, callExpr, serialize(firstArg)))
            return connProxy
        end

        if isMethod and (fieldName == "Once") and parent then
            local callback = firstArg
            if type(callback) == "function" then
                pcall(callback, makeProxy("eventArgs"))
            end
            local connProxy = makeProxy(retName)
            local connMt = getmetatable(connProxy)
            connMt._className = "RBXScriptConnection"
            connMt._storedValues["Connected"] = true
            connMt._setKeys["Connected"] = true
            emit(string.format('local %s = %s(%s)', retName, callExpr, serialize(firstArg)))
            return connProxy
        end

        if isMethod and (fieldName == "Disconnect" or fieldName == "disconnect") then
            if parent then
                local connMt = getmetatable(parent)
                if connMt and connMt._storedValues then
                    connMt._storedValues["Connected"] = false
                    connMt._setKeys["Connected"] = true
                end
            end
            emit(string.format('%s:Disconnect()', proxyName(parent)))
            return
        end

        if isMethod and fieldName == "SetAttribute" and parent then
            local parentName = proxyName(parent)
            emit(string.format('%s:SetAttribute(%s)', parentName, table.concat(parts, ", ")))
            local parentMt = getmetatable(parent)
            if not parentMt._attributes then parentMt._attributes = {} end
            parentMt._attributes[firstArg] = args[startIdx + 1]
            return makeProxy(retName)
        end

        if isMethod and fieldName == "GetAttribute" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetAttribute(%s)', retName, parentName, serialize(firstArg)))
            local parentMt = getmetatable(parent)
            if parentMt._attributes then return parentMt._attributes[firstArg] end
            return nil
        end

        if isMethod and fieldName == "GetAttributes" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetAttributes()', retName, parentName))
            local parentMt = getmetatable(parent)
            return parentMt._attributes or {}
        end

        if isMethod and fieldName == "Fire" and parent then
            local parentName = proxyName(parent)
            emit(string.format('%s:Fire(%s)', parentName, table.concat(parts, ", ")))
            for _, conn in ipairs(eventConnections) do
                if rawequal(conn.proxy, parent) and conn.eventName == "Event" then
                    pcall(conn.callback, table.unpack(args, startIdx, n))
                end
            end
            return makeProxy(retName)
        end

        if isMethod and fieldName == "FireServer" and parent then
            local parentName = proxyName(parent)
            emit(string.format('%s:FireServer(%s)', parentName, table.concat(parts, ", ")))
            return makeProxy(retName)
        end

        if isMethod and fieldName == "FireClient" and parent then
            local parentName = proxyName(parent)
            emit(string.format('%s:FireClient(%s)', parentName, table.concat(parts, ", ")))
            return makeProxy(retName)
        end

        if isMethod and (fieldName == "FireAllClients") and parent then
            local parentName = proxyName(parent)
            emit(string.format('%s:FireAllClients(%s)', parentName, table.concat(parts, ", ")))
            return makeProxy(retName)
        end

        if isMethod and fieldName == "WaitForChild" and parent then
            local parentName = proxyName(parent)
            local timeout = args[startIdx + 1]
            emit(string.format('local %s = %s:WaitForChild(%s)', retName, parentName, table.concat(parts, ", ")))
            if type(timeout) == "number" and timeout < 0 then
                error("WaitForChild: invalid timeout", 0)
            end
            return makeProxy(retName)
        end

        if isMethod and fieldName == "Wait" then
            emit(string.format('local %s = %s()', retName, callExpr))
            local parentMt = getmetatable(parent)
            if parentMt and parentMt._fieldName == "CharacterAdded" then
                local char = spyInstance("Model", "Character", true)
                return char
            end
            return makeProxy(retName)
        end

        if isMethod and fieldName == "GetMemStats" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetMemStats()', retName, parentName))
            return { cpuLoad = 0, gpuLoad = 0, ram = 0, vram = 0 }
        end

        if isMethod and fieldName == "GetNumAwakeParts" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetNumAwakeParts()', retName, parentName))
            local parentMt = getmetatable(parent)
            local parentCls = parentMt and parentMt._className or ""
            if parentCls == "Workspace" then
                return awakePartsCount
            end
            return 0
        end

        if isMethod and (fieldName == "GetRealPhysicsFPS" or fieldName == "GetPhysicsFPS") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:%s()', retName, parentName, fieldName))
            return 60.0
        end

        if isMethod and (fieldName == "SetItem" or fieldName == "GetItem") and parent then
            local parentName = proxyName(parent)
            local parentMt = getmetatable(parent)
            if not parentMt._itemStore then parentMt._itemStore = {} end
            if fieldName == "SetItem" then
                emit(string.format('%s:SetItem(%s)', parentName, table.concat(parts, ", ")))
                parentMt._itemStore[args[startIdx]] = args[startIdx + 1]
                return
            else
                emit(string.format('local %s = %s:GetItem(%s)', retName, parentName, table.concat(parts, ", ")))
                return parentMt._itemStore[args[startIdx]]
            end
        end

        if isMethod and fieldName == "IsVibrationSupported" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:IsVibrationSupported(%s)', retName, parentName, table.concat(parts, ", ")))
            return false
        end

        if isMethod and fieldName == "GetCorescriptLocalizations" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetCorescriptLocalizations()', retName, parentName))
            return {}
        end

        if isMethod and (fieldName == "IsAvailable" or fieldName == "HasAchieved") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:%s(%s)', retName, parentName, fieldName, table.concat(parts, ", ")))
            if fieldName == "IsAvailable" then return false end
            return false
        end

        if isMethod and fieldName == "GetCharacterAppearanceInfoAsync" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetCharacterAppearanceInfoAsync(%s)', retName, parentName, serialize(firstArg)))
            return { assets = { { id = 1, name = "Shirt" }, { id = 2, name = "Pants" } }, bodyColors = {}, scales = {} }
        end

        if isMethod and fieldName == "AddTag" and parent then
            local parentName = proxyName(parent)
            local instName = ""
            if isProxy(firstArg) then instName = getmetatable(firstArg)._name end
            local tagName = args[startIdx + 1]
            if instName ~= "" and type(tagName) == "string" then
                if not instanceTags[instName] then instanceTags[instName] = {} end
                table.insert(instanceTags[instName], tagName)
            end
            emit(string.format('%s:AddTag(%s)', parentName, table.concat(parts, ", ")))
            return makeProxy(retName)
        end

        if isMethod and (fieldName == "Destroy" or fieldName == "Remove") and parent then
            local parentName = proxyName(parent)
            local parentMt = getmetatable(parent)
            local parentClassName = parentMt and parentMt._className or ""
            if parentClassName == "DataModel" or parentClassName == "Workspace" then
                emit(string.format('%s:%s()', parentName, fieldName))
                error("Cannot destroy " .. parentClassName, 0)
            end
            if parentMt and parentMt._className and isApiServiceClass(parentMt._className) then
                emit(string.format('%s:%s()', parentName, fieldName))
                error("Cannot destroy service " .. parentMt._className, 0)
            end
            emit(string.format('%s:%s()', parentName, fieldName))
            destroyedInstances[parentName] = true
            local pm = getmetatable(parent)
            if pm and pm._storedValues then
                pm._storedValues["Parent"] = nil
                pm._setKeys["Parent"] = true
            end
            local children = parentChildMap[parentName]
            if children then
                for childName, childProxy in pairs(children) do
                    local cmt = getmetatable(childProxy)
                    if cmt and cmt._storedValues then
                        cmt._storedValues["Parent"] = nil
                        cmt._setKeys["Parent"] = true
                    end
                    local childDisplayName = cmt and cmt._storedValues and cmt._storedValues["Name"]
                    if childDisplayName and childDisplayName ~= childName then
                        destroyedInstances[childDisplayName] = true
                    end
                    destroyedInstances[childName] = true
                    local childProxyName = proxyName(childProxy)
                    local grandchildren = parentChildMap[childProxyName]
                    if grandchildren then
                        for _, gc in pairs(grandchildren) do
                            local gcmt = getmetatable(gc)
                            if gcmt and gcmt._storedValues then
                                gcmt._storedValues["Parent"] = nil
                                gcmt._setKeys["Parent"] = true
                            end
                        end
                    end
                end
                parentChildMap[parentName] = nil
            end
            return makeProxy(retName)
        end

        if isMethod and fieldName == "Clone" and parent then
            local parentMt = getmetatable(parent)
            local parentClassName = parentMt and parentMt._className or ""
            if parentClassName == "DataModel" or parentClassName == "Workspace" then
                emit(string.format('%s:Clone()', proxyName(parent)))
                error("Ugc cannot be cloned", 0)
            end
            if parentMt and parentMt._storedValues and parentMt._storedValues["Archivable"] == false then
                emit(string.format('%s:Clone()', proxyName(parent)))
                return nil
            end
            local v = genVar("clone")
            emit(string.format('local %s = %s:Clone()', v, proxyName(parent)))
            local cloneProxy = makeProxy(v)
            local cloneMt = getmetatable(cloneProxy)
            cloneMt._className = parentClassName
            if parentMt and parentMt._storedValues then
                for k, val in pairs(parentMt._storedValues) do
                    cloneMt._storedValues[k] = val
                    cloneMt._setKeys[k] = true
                end
            end
            return cloneProxy
        end

        if isMethod and fieldName == "Create" and parent then
            local parentName = proxyName(parent)
            local parentMt = getmetatable(parent)
            local parentClassName = parentMt and parentMt._className or ""
            emit(string.format('local %s = %s:Create(%s)', retName, parentName, table.concat(parts, ", ")))
            local goal = args[startIdx + 2]
            if type(goal) == "table" then
                for k, v in pairs(goal) do
                    if type(k) == "string" then
                        local expected = getPropertyRuntimeType(parentClassName, k)
                        if expected then
                            local basicType = type(v)
                            if basicType == "string" and expected ~= "string" then
                                error("Create: invalid property type for '" .. k .. "'", 0)
                            elseif basicType == "boolean" and expected ~= "boolean" then
                                error("Create: invalid property type for '" .. k .. "'", 0)
                            elseif basicType == "number" and expected ~= "number" then
                                error("Create: invalid property type for '" .. k .. "'", 0)
                            elseif isProxy(v) and expected == "Instance" then
                                local valueClassName = getmetatable(v)._className
                                local memberInfo = resolveApiMember(parentClassName, k)
                                local valueType = memberInfo and memberInfo.valueType
                                if valueType and valueType.category == "Class" and type(valueType.name) == "string" and valueClassName and not classIsA(valueClassName, valueType.name) then
                                    error("Create: invalid property type for '" .. k .. "'", 0)
                                end
                            end
                        end
                    end
                end
            end
            local tweenProxy = makeProxy(retName)
            local tweenMt = getmetatable(tweenProxy)
            tweenMt._className = "Tween"
            tweenMt._storedValues["ClassName"] = "Tween"
            tweenMt._setKeys["ClassName"] = true
            return tweenProxy
        end

        if isMethod and (fieldName == "FindFirstChild" or fieldName == "findFirstChild") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:FindFirstChild(%s)', retName, parentName, table.concat(parts, ", ")))
            if type(firstArg) == "string" then
                local children = parentChildMap[parentName]
                if children and children[firstArg] then
                    return children[firstArg]
                end
                local parentMt = getmetatable(parent)
                local parentCls = parentMt and parentMt._className or ""
                local parentStoredName = parentMt and parentMt._storedValues and parentMt._storedValues["Name"]
                local PLAYER_CHILDREN = {
                    PlayerScripts = {"PlayerModule", "RbxCharacterSounds"},
                    PlayerGui = {},
                    Backpack = {},
                }
                if parentCls == "Player" and PLAYER_CHILDREN[firstArg] then
                    local folder = spyInstance("Folder", firstArg, true)
                    for _, childName in ipairs(PLAYER_CHILDREN[firstArg]) do
                        local child = spyInstance("LocalScript", childName, true)
                        if not parentChildMap[firstArg] then parentChildMap[firstArg] = {} end
                        parentChildMap[firstArg][childName] = child
                    end
                    return folder
                end
                local SERVICE_KNOWN_CHILDREN = {
                    NetworkClient = { ClientReplicator = "ClientReplicator" },
                    Players = { LocalPlayer = "Player" },
                    Workspace = { Terrain = "Terrain", Camera = "Camera" },
                    ReplicatedStorage = { Remotes = "Folder" },
                    Lighting = {},
                }
                if SERVICE_KNOWN_CHILDREN[parentCls] and SERVICE_KNOWN_CHILDREN[parentCls][firstArg] then
                    local childCls = SERVICE_KNOWN_CHILDREN[parentCls][firstArg]
                    local child = spyInstance(childCls, firstArg, true)
                    if not parentChildMap[parentName] then parentChildMap[parentName] = {} end
                    parentChildMap[parentName][firstArg] = child
                    return child
                end
            end
            return nil
        end

        if isMethod and (fieldName == "FindFirstDescendant" or fieldName == "FindFirstChildWhichIsA" or fieldName == "FindFirstChildOfClass") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:%s(%s)', retName, parentName, fieldName, table.concat(parts, ", ")))
            local firstArg = args[startIdx]
            if type(firstArg) == "string" then
                if parentChildMap[parentName] and parentChildMap[parentName][firstArg] then
                    return parentChildMap[parentName][firstArg]
                end
                local parentMt = getmetatable(parent)
                local parentCls = parentMt and parentMt._className or ""
                local parentStoredName = parentMt and parentMt._storedValues and parentMt._storedValues["Name"]
                local isCharacterLike = parentCls == "Model" or (parentName and parentName:lower():find("character")) or (parentStoredName and parentStoredName:lower():find("character"))
                if isCharacterLike then
                    if firstArg == "Humanoid" then
                        local hum = spyInstance("Humanoid", "Humanoid", true)
                        return hum
                    end
                    if firstArg == "HumanoidRootPart" then
                        local hrp = spyInstance("Part", "HumanoidRootPart", true)
                        return hrp
                    end
                end
                if parentCls == "Players" and firstArg == "Player" then
                    return parentChildMap["Players"] and parentChildMap["Players"]["LocalPlayer"]
                end
            end
            return nil
        end

        if isMethod and (fieldName == "IsServer" or fieldName == "IsClient" or fieldName == "IsStudio") then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:%s()', retName, parentName, fieldName))
            if fieldName == "IsServer" then return false end
            return true
        end

        if isMethod and fieldName == "SetItem" and parent then
            local parentName = proxyName(parent)
            emit(string.format('%s:SetItem(%s)', parentName, table.concat(parts, ", ")))
            if type(firstArg) == "string" then
                memStorage[firstArg] = args[startIdx + 1]
            end
            return makeProxy(retName)
        end

        if isMethod and fieldName == "GetItem" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetItem(%s)', retName, parentName, table.concat(parts, ", ")))
            if type(firstArg) == "string" then
                return memStorage[firstArg]
            end
            return nil
        end

        if isMethod and (fieldName == "JSONEncode" or fieldName == "jsonEncode") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:JSONEncode(%s)', retName, parentName, table.concat(parts, ", ")))
            return serde.encode("json", firstArg)
        end

        if isMethod and (fieldName == "GetProductInfo" or fieldName == "getProductInfo") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetProductInfo(%s)', retName, parentName, table.concat(parts, ", ")))
            local id = firstArg
            if type(id) ~= "number" or id ~= id or id < -1e20 or id > 1e20 then
                error("GetProductInfo: invalid asset id", 0)
            end
            if select("#", ...) - startIdx + 1 > 2 then
                error("GetProductInfo: too many arguments", 0)
            end
            return { AssetId = id, Name = "Asset", Description = "", AssetTypeId = 1,
                     Creator = { Id = 0, Name = "Creator", CreatorType = "User" },
                     IsForSale = false, PriceInRobux = 0, ContentRatingTypeId = 0 }
        end

        if isMethod and fieldName == "GetCountryRegionForPlayerAsync" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetCountryRegionForPlayerAsync(%s)', retName, parentName, table.concat(parts, ", ")))
            if type(firstArg) ~= "table" and type(firstArg) ~= "userdata" then
                error("GetCountryRegionForPlayerAsync: invalid player argument", 0)
            end
            return "US"
        end

        if isMethod and fieldName == "UrlEncode" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:UrlEncode(%s)', retName, parentName, serialize(firstArg)))
            if type(firstArg) == "string" then
                return firstArg:gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", string.byte(c)) end)
            end
            return ""
        end

        if isMethod and (fieldName == "JSONDecode" or fieldName == "jsonDecode") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:JSONDecode(%s)', retName, parentName, table.concat(parts, ", ")))
            if type(firstArg) ~= "string" then
                error("JSONDecode: invalid argument", 0)
            end
            local ok, result = pcall(function() return serde.decode("json", firstArg) end)
            if not ok then
                error("JSONDecode: invalid JSON", 0)
            end
            return result
        end

        if isMethod and (fieldName == "GenerateGUID" or fieldName == "generateGUID") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GenerateGUID(%s)', retName, parentName, table.concat(parts, ", ")))
            local guidCounter = (_G._guidCounter or 0) + 1
            _G._guidCounter = guidCounter
            return string.format("%08x-%04x-%04x-%04x-%012x", guidCounter, guidCounter, guidCounter, guidCounter, guidCounter)
        end

        if isMethod and fieldName == "GetTagged" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetTagged(%s)', retName, parentName, serialize(firstArg)))
            return {}
        end

        if isMethod and (fieldName == "GetInstanceAddedSignal" or fieldName == "GetInstanceRemovedSignal") and parent then
            local parentName = proxyName(parent)
            local cacheKey = parentName .. ":" .. fieldName .. ":" .. tostring(firstArg)
            if serviceCache[cacheKey] then
                emit(string.format('local %s = %s:%s(%s)', retName, parentName, fieldName, serialize(firstArg)))
                return serviceCache[cacheKey]
            end
            local sigProxy = makeProxy(retName)
            serviceCache[cacheKey] = sigProxy
            emit(string.format('local %s = %s:%s(%s)', retName, parentName, fieldName, serialize(firstArg)))
            return sigProxy
        end

        if isMethod and fieldName == "SendAsync" and parent then
            local parentName = proxyName(parent)
            emit(string.format('%s:SendAsync(%s)', parentName, serialize(firstArg)))
            fireAllConnectionsForEvent("TextChatService", "MessageReceived", {
                Text = firstArg,
                TextSource = { UserId = 0 },
            })
            return makeProxy(retName)
        end

        if isMethod and fieldName == "NextInteger" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:NextInteger(%s)', retName, parentName, table.concat(parts, ", ")))
            local min = args[startIdx] or 0
            local max = args[startIdx + 1] or 100
            return math.random(min, max)
        end

        if isMethod and fieldName == "NextNumber" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:NextNumber(%s)', retName, parentName, table.concat(parts, ", ")))
            return math.random()
        end

        if isMethod and (fieldName == "GetSecret" or fieldName == "getSecret") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetSecret(%s)', retName, parentName, serialize(firstArg)))
            local secret = makeProxy(retName)
            local sMt = getmetatable(secret)
            sMt._className = "Secret"
            return secret
        end

        if isMethod and fieldName == "GetAllBoundActionInfo" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetAllBoundActionInfo()', retName, parentName))
            return {}
        end

        if isMethod and (fieldName == "CompressBuffer" or fieldName == "DecompressBuffer") and parent then
            local parentName = proxyName(parent)
            local bufArg = args[startIdx]
            local rawData = nil
            if type(bufArg) == "string" then
                rawData = bufArg
            elseif type(bufArg) == "table" and bufArg._data then
                rawData = bufArg._data
            else
                local ok, str = pcall(buffer.tostring, bufArg)
                if ok and type(str) == "string" then
                    rawData = str
                end
            end
            local bufRepr = "nil"
            if rawData then
                bufRepr = "buffer.fromstring(\"<"..#rawData.." bytes>\")"
            end
            local zstdArg = args[startIdx + 1]
            local zstdRepr = "Enum.CompressionAlgorithm.Zstd"
            pcall(function()
                local mt = getmetatable(zstdArg)
                if mt and mt._name then zstdRepr = mt._name end
            end)
            emit(string.format('local %s = %s:%s(%s, %s)', retName, parentName, fieldName, bufRepr, zstdRepr))
            if rawData and #rawData > 0 then
                local mode = fieldName == "CompressBuffer" and "compress" or "decompress"
                local ok2, result = pcall(serde[mode], "zstd", rawData)
                if ok2 and type(result) == "string" and #result > 0 then
                    return buffer.fromstring(result)
                end
            end
            return buffer.fromstring("")
        end

        if isMethod and (fieldName == "GetAsync" or fieldName == "PostAsync" or fieldName == "RequestAsync" or fieldName == "HttpGet" or fieldName == "HttpPost" or fieldName == "HttpRequest") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:%s(%s)', retName, parentName, fieldName, table.concat(parts, ", ")))
            local url = args[startIdx]
            local body = args[startIdx + 1]
            local fetchedBody = ""
            if type(url) == "string" and #url > 0 then
                local okFetch, response = pcall(function()
                    if fieldName == "GetAsync" or fieldName == "HttpGet" then
                        return net.request(url, { Method = "GET" })
                    elseif fieldName == "PostAsync" or fieldName == "HttpPost" then
                        return net.request(url, { Method = "POST", Body = body or "" })
                    else
                        if type(body) == "table" then
                            local reqArgs = { Method = body.Method or "GET" }
                            if body.Url then reqArgs.Url = body.Url end
                            if body.Body then reqArgs.Body = body.Body end
                            if body.Headers then reqArgs.Headers = body.Headers end
                            return net.request(body.Url or url, reqArgs)
                        end
                        return net.request(url, { Method = "GET" })
                    end
                end)
                if okFetch and response and response.body then
                    fetchedBody = response.body
                end
            end
            if fieldName == "GetAsync" or fieldName == "HttpGet" then
                return fetchedBody
            elseif fieldName == "PostAsync" or fieldName == "HttpPost" then
                return
            elseif fieldName == "RequestAsync" or fieldName == "HttpRequest" then
                return { StatusCode = 200, Body = fetchedBody, Success = true, Headers = {} }
            end
            return fetchedBody
        end

        if isMethod and (fieldName == "JSONEncode" or fieldName == "JSONDecode") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:%s(%s)', retName, parentName, fieldName, table.concat(parts, ", ")))
            if fieldName == "JSONEncode" then
                return "{}"
            else
                return {}
            end
        end

        if isMethod and (fieldName == "SetCore" or fieldName == "GetCore") and parent then
            local parentName = proxyName(parent)
            emit(string.format('%s:%s(%s)', parentName, fieldName, table.concat(parts, ", ")))
            if fieldName == "GetCore" then
                return nil
            end
            return
        end

        if isMethod and (fieldName == "SetMetadata" or fieldName == "GetMetadata") and parent then
            local parentName = proxyName(parent)
            local parentMt = getmetatable(parent)
            if not parentMt._metadataStore then parentMt._metadataStore = {} end
            if fieldName == "SetMetadata" then
                emit(string.format('%s:SetMetadata(%s)', parentName, table.concat(parts, ", ")))
                parentMt._metadataStore = args[startIdx] or {}
                return
            else
                emit(string.format('local %s = %s:GetMetadata()', retName, parentName))
                return parentMt._metadataStore or {}
            end
        end

        if isMethod and fieldName == "CreateEditableMesh" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:CreateEditableMesh()', retName, parentName))
            local mesh = makeProxy(retName)
            local meshMt = getmetatable(mesh)
            meshMt._className = "EditableMesh"
            meshMt._storedValues["ClassName"] = "EditableMesh"
            meshMt._setKeys["ClassName"] = true
            meshMt._vertices = {}
            meshMt._vertexPositions = {}
            return mesh
        end

        if isMethod and fieldName == "AddVertex" and parent then
            local parentName = proxyName(parent)
            local parentMt = getmetatable(parent)
            local verts = parentMt._vertices or {}
            local positions = parentMt._vertexPositions or {}
            local id = #verts + 1
            verts[id] = id
            local pos = args[startIdx]
            local px, py, pz = 0, 0, 0
            if isProxy(pos) then
                local posArgs = rawget(pos, "_ctorArgs")
                if posArgs then
                    px = posArgs[1] or 0
                    py = posArgs[2] or 0
                    pz = posArgs[3] or 0
                else
                    local pm = getmetatable(pos)
                    if pm and pm._ctorArgs then
                        px = pm._ctorArgs[1] or 0
                        py = pm._ctorArgs[2] or 0
                        pz = pm._ctorArgs[3] or 0
                    end
                end
            end
            positions[id] = {px, py, pz}
            parentMt._vertices = verts
            parentMt._vertexPositions = positions
            emit(string.format('local %s = %s:AddVertex(%s)', retName, parentName, table.concat(parts, ", ")))
            return id
        end

        if isMethod and fieldName == "GetVertices" and parent then
            local parentName = proxyName(parent)
            local parentMt = getmetatable(parent)
            emit(string.format('local %s = %s:GetVertices()', retName, parentName))
            local verts = parentMt._vertices or {}
            local out = {}
            for i, v in ipairs(verts) do
                out[i] = v
            end
            return out
        end

        if isMethod and fieldName == "GetPosition" and parent then
            local parentName = proxyName(parent)
            local parentMt = getmetatable(parent)
            local vid = args[startIdx]
            local positions = parentMt._vertexPositions or {}
            emit(string.format('local %s = %s:GetPosition(%s)', retName, parentName, table.concat(parts, ", ")))
            local pos = positions[vid] or {0, 0, 0}
            return makeDataProxy("Vector3", { pos[1] or 0, pos[2] or 0, pos[3] or 0 }, retName)
        end

        if isMethod and fieldName == "WorldToScreenPoint" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:WorldToScreenPoint(%s)', retName, parentName, table.concat(parts, ", ")))
            local v = makeProxy(retName)
            local vMt = getmetatable(v)
            vMt._ctorName = "Vector3"
            vMt._ctorArgs = { 0, 0, 0 }
            return v
        end

        if isMethod and fieldName == "Raycast" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:Raycast(%s)', retName, parentName, table.concat(parts, ", ")))
            return nil
        end

        if isMethod and fieldName == "GetMouseLocation" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetMouseLocation()', retName, parentName))
            local v = makeProxy(retName)
            local vMt = getmetatable(v)
            vMt._ctorName = "Vector2"
            vMt._ctorArgs = { 0, 0 }
            return v
        end

        if isMethod and fieldName == "GetMouse" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetMouse()', retName, parentName))
            local mouse = makeProxy(retName)
            local mMt = getmetatable(mouse)
            mMt._className = "PlayerMouse"
            mMt._storedValues["ClassName"] = "PlayerMouse"
            mMt._setKeys["ClassName"] = true
            return mouse
        end

        if isMethod and fieldName == "ClosestPoint" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:ClosestPoint(%s)', retName, parentName, table.concat(parts, ", ")))
            local v = makeProxy(retName)
            local vMt = getmetatable(v)
            vMt._ctorName = "Vector3"
            vMt._ctorArgs = { 0, 0, 0 }
            return v
        end

        if isMethod and (fieldName == "GetPartsInPart" or fieldName == "GetPartsInBox" or fieldName == "GetPartBoundsInBox" or fieldName == "GetPartBoundsInRadius") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:%s(%s)', retName, parentName, fieldName, table.concat(parts, ", ")))
            return {}
        end

        if isMethod and fieldName == "IsA" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:IsA(%s)', retName, parentName, serialize(firstArg)))
            local parentMt = getmetatable(parent)
            local cls = parentMt and parentMt._className or ""
            if type(firstArg) == "string" then return classIsA(cls, firstArg) end
            return false
        end

        if isMethod and (fieldName == "FormatUniversalTime" or fieldName == "FormatLocalTime") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:%s(%s)', retName, parentName, fieldName, table.concat(parts, ", ")))
            local parentMt = getmetatable(parent)
            local ts = parentMt and parentMt._storedValues and parentMt._storedValues["UnixTimestamp"] or 0
            local day = os.date("!%Y-%m-%d", ts)
            local time = os.date("!%H:%M:%S", ts)
            local fmt = firstArg or ""
            if fmt:find("YYYY") then
                return os.date("!%Y", ts) .. "-" .. os.date("!%m", ts) .. "-" .. os.date("!%d", ts)
            elseif fmt:find("HH") then
                return os.date("!%H", ts) .. ":" .. os.date("!%M", ts) .. ":" .. os.date("!%S", ts)
            end
            return day .. " " .. time
        end

        if isMethod and fieldName == "IsRunning" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:IsRunning()', retName, parentName))
            return true
        end

        if isMethod and fieldName == "GetTags" and parent then
            local parentName = proxyName(parent)
            local instName = ""
            if isProxy(firstArg) then instName = getmetatable(firstArg)._name end
            emit(string.format('local %s = %s:GetTags(%s)', retName, parentName, serialize(firstArg)))
            return instanceTags[instName] or {}
        end

        if isMethod and fieldName == "GetChildren" and parent then
            local parentName = proxyName(parent)
            emit(string.format('%s:GetChildren()', parentName))
            if parentName == "game" then
                local children = {}
                for _, svc in ipairs({"Workspace", "Players", "Lighting", "ReplicatedStorage", "ReplicatedFirst", "ServerScriptService", "ServerStorage", "StarterGui", "StarterPlayer", "SoundService", "Chat", "Teams", "RunService", "UserInputService", "TweenService", "HttpService"}) do
                    table.insert(children, spyInstance(svc, svc, true))
                end
                return children
            end
            return {}
        end

        if isMethod and fieldName == "GetFullName" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetFullName()', retName, parentName))
            if parentName == "workspace" then return "Workspace" end
            if parentName == "game" then return "game" end
            return parentName
        end

        if isMethod and fieldName == "GetDescendants" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetDescendants()', retName, parentName))
            if parentName == "game" then
                local descendants = {}
                for _, svc in ipairs({"Workspace", "Players", "Lighting", "ReplicatedStorage", "ReplicatedFirst", "ServerScriptService", "ServerStorage", "StarterGui", "StarterPlayer", "SoundService", "Chat", "Teams", "RunService", "UserInputService", "TweenService", "HttpService"}) do
                    local svcProxy = spyInstance(svc, svc, true)
                    table.insert(descendants, svcProxy)
                    local ms = spyInstance("ModuleScript", svc .. "ModuleScript", true)
                    table.insert(descendants, ms)
                    local ls = spyInstance("LocalScript", svc .. "LocalScript", true)
                    table.insert(descendants, ls)
                end
                return descendants
            end
            return {}
        end

        if isMethod and fieldName == "GetPlayers" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetPlayers()', retName, parentName))
            if not serviceCache["Players"] then serviceCache["Players"] = parent end
            if not parentChildMap["Players"] then parentChildMap["Players"] = {} end
            if not parentChildMap["Players"]["LocalPlayer"] then
                local lp = spyInstance("Player", "LocalPlayer", true)
                local lpMt = getmetatable(lp)
                lpMt._storedValues["UserId"] = 0
                lpMt._setKeys["UserId"] = true
                parentChildMap["Players"]["LocalPlayer"] = lp
            end
            return { parentChildMap["Players"]["LocalPlayer"] }
        end

        if isStatementCall then
            emit(string.format('%s(%s)', callExpr, table.concat(parts, ", ")))
            return makeProxy(retName)
        end
        emit(string.format('local %s = %s(%s)', retName, callExpr, table.concat(parts, ", ")))
        return makeProxy(retName)
    end
    mt.__tostring = function() return name end
    mt.__len = function() return 0 end
    mt.__concat = function(a, b)
        local sa = isProxy(a) and proxyName(a) or serialize(a)
        local sb = isProxy(b) and proxyName(b) or serialize(b)
        markUsed(a); markUsed(b)
        local retName = genVar("v")
        emit(string.format('local %s = %s .. %s', retName, sa, sb))
        return makeProxy(retName)
    end
    local function makeVector3FromArgs(x, y, z)
        local retName = genVar("v")
        emit(string.format('local %s = Vector3.new(%s, %s, %s)', retName, serialize(x), serialize(y), serialize(z)))
        return makeDataProxy("Vector3", { x, y, z }, retName)
    end
    local function makeFastVector3(x, y, z, expr)
        local retName = genVar("v")
        if expr then
            emit("local " .. retName .. " = " .. expr)
        else
            emit("local " .. retName .. " = Vector3.new(" .. serialize(x) .. ", " .. serialize(y) .. ", " .. serialize(z) .. ")")
        end
        return makeDataProxy("Vector3", { x, y, z }, retName)
    end
    local function getVector3Args(v)
        if isProxy(v) then
            local m = getmetatable(v)
            local ctorName = rawget(v, "_ctorName") or (m and m._ctorName)
            local ctorArgs = rawget(v, "_ctorArgs") or (m and m._ctorArgs)
            if ctorName == "Vector3" and ctorArgs then
                return ctorArgs[1] or 0, ctorArgs[2] or 0, ctorArgs[3] or 0
            end
        end
        return nil
    end
    mt.__add = function(a, b)
        local ax, ay, az = getVector3Args(a)
        local bx, by, bz = getVector3Args(b)
        if ax and bx then
            local sa = isProxy(a) and proxyName(a) or serialize(a)
            local sb = isProxy(b) and proxyName(b) or serialize(b)
            markUsed(a); markUsed(b)
            return makeFastVector3(ax + bx, ay + by, az + bz, sa .. " + " .. sb)
        end
        local sa = isProxy(a) and proxyName(a) or serialize(a)
        local sb = isProxy(b) and proxyName(b) or serialize(b)
        markUsed(a); markUsed(b)
        local retName = genVar("v")
        emit(string.format('local %s = %s + %s', retName, sa, sb))
        return makeProxy(retName)
    end
    mt.__sub = function(a, b)
        local ax, ay, az = getVector3Args(a)
        local bx, by, bz = getVector3Args(b)
        if ax and bx then
            local sa = isProxy(a) and proxyName(a) or serialize(a)
            local sb = isProxy(b) and proxyName(b) or serialize(b)
            markUsed(a); markUsed(b)
            return makeFastVector3(ax - bx, ay - by, az - bz, sa .. " - " .. sb)
        end
        local sa = isProxy(a) and proxyName(a) or serialize(a)
        local sb = isProxy(b) and proxyName(b) or serialize(b)
        markUsed(a); markUsed(b)
        local retName = genVar("v")
        emit(string.format('local %s = %s - %s', retName, sa, sb))
        return makeProxy(retName)
    end
    mt.__mul = function(a, b)
        local ax, ay, az = getVector3Args(a)
        local bx, by, bz = getVector3Args(b)
        if ax and bx then
            local sa = isProxy(a) and proxyName(a) or serialize(a)
            local sb = isProxy(b) and proxyName(b) or serialize(b)
            markUsed(a); markUsed(b)
            return makeFastVector3(ax * bx, ay * by, az * bz, sa .. " * " .. sb)
        end
        if ax and type(b) == "number" then
            local sa = isProxy(a) and proxyName(a) or serialize(a)
            markUsed(a)
            return makeFastVector3(ax * b, ay * b, az * b, sa .. " * " .. serialize(b))
        end
        if type(a) == "number" and bx then
            local sb = isProxy(b) and proxyName(b) or serialize(b)
            markUsed(b)
            return makeFastVector3(a * bx, a * by, a * bz, serialize(a) .. " * " .. sb)
        end
        local sa = isProxy(a) and proxyName(a) or serialize(a)
        local sb = isProxy(b) and proxyName(b) or serialize(b)
        markUsed(a); markUsed(b)
        local retName = genVar("v")
        emit(string.format('local %s = %s * %s', retName, sa, sb))
        return makeProxy(retName)
    end
    mt.__div = function(a, b)
        local ax, ay, az = getVector3Args(a)
        local bx, by, bz = getVector3Args(b)
        if ax and bx then
            local sa = isProxy(a) and proxyName(a) or serialize(a)
            local sb = isProxy(b) and proxyName(b) or serialize(b)
            markUsed(a); markUsed(b)
            return makeFastVector3(ax / bx, ay / by, az / bz, sa .. " / " .. sb)
        end
        if ax and type(b) == "number" then
            local sa = isProxy(a) and proxyName(a) or serialize(a)
            markUsed(a)
            return makeFastVector3(ax / b, ay / b, az / b, sa .. " / " .. serialize(b))
        end
        local sa = isProxy(a) and proxyName(a) or serialize(a)
        local sb = isProxy(b) and proxyName(b) or serialize(b)
        markUsed(a); markUsed(b)
        local retName = genVar("v")
        emit(string.format('local %s = %s / %s', retName, sa, sb))
        return makeProxy(retName)
    end
    mt.__mod = function(a, b)
        local sa = isProxy(a) and proxyName(a) or serialize(a)
        local sb = isProxy(b) and proxyName(b) or serialize(b)
        markUsed(a); markUsed(b)
        local retName = genVar("v")
        emit(string.format('local %s = %s %% %s', retName, sa, sb))
        return makeProxy(retName)
    end
    mt.__pow = function(a, b)
        local sa = isProxy(a) and proxyName(a) or serialize(a)
        local sb = isProxy(b) and proxyName(b) or serialize(b)
        markUsed(a); markUsed(b)
        local retName = genVar("v")
        emit(string.format('local %s = %s ^ %s', retName, sa, sb))
        return makeProxy(retName)
    end
    mt.__unm = function(a)
        local sa = isProxy(a) and proxyName(a) or serialize(a)
        markUsed(a)
        local retName = genVar("v")
        emit(string.format('local %s = -%s', retName, sa))
        return makeProxy(retName)
    end
    mt.__len = function() return 0 end
    mt.__eq = function(a, b)
        if rawequal(a, b) then return true end
        if isProxy(a) and isProxy(b) then
            local am = getmetatable(a)
            local bm = getmetatable(b)
            if am._ctorName and am._ctorName == bm._ctorName and am._ctorArgs and bm._ctorArgs then
                if #am._ctorArgs == #bm._ctorArgs then
                    local allEq = true
                    for i, v in ipairs(am._ctorArgs) do
                        if v ~= bm._ctorArgs[i] then allEq = false break end
                    end
                    if allEq then return true end
                end
            end
            if am._className and am._className == bm._className then
                if am._storedValues and bm._storedValues then
                    if am._storedValues["Name"] and bm._storedValues["Name"] and am._storedValues["Name"] == bm._storedValues["Name"] then
                        return true
                    end
                end
            end
            return am._name == bm._name
        end
        return false
    end
    mt.__lt = function(a, b) return false end
    mt.__le = function(a, b) return rawequal(a, b) end

    if dataMTs["Vector3"] then
        dataMTs["Vector3"].__add = mt.__add
        dataMTs["Vector3"].__sub = mt.__sub
        dataMTs["Vector3"].__mul = mt.__mul
        dataMTs["Vector3"].__div = mt.__div
        dataMTs["Vector3"].__mod = mt.__mod
        dataMTs["Vector3"].__pow = mt.__pow
        dataMTs["Vector3"].__unm = mt.__unm
        dataMTs["Vector3"].__len = mt.__len
        dataMTs["Vector3"].__lt = mt.__lt
        dataMTs["Vector3"].__le = mt.__le
    end

    return setmetatable({}, mt)
end

applyClassDefaults = function(proxy: any, className: string)
    local mt = getmetatable(proxy)
    if not mt then return end
    local clsInfo = getApiClassInfo(className)
    local chain = {}
    local cur = clsInfo
    while cur do
        table.insert(chain, cur.name)
        if type(cur.superclass) ~= "string" or cur.superclass == "" then break end
        cur = getApiClassInfo(cur.superclass)
    end
    for i = 1, #chain do
        local defaults = classDefaultProperties[chain[i]]
        if defaults then
            for propName, dv in pairs(defaults) do
                if not mt._setKeys[propName] then
                    if dv == "Color3" then
                        local c = makeProxy(mt._name .. "." .. propName)
                        local cmt = getmetatable(c)
                        cmt._ctorName = "Color3"
                        cmt._ctorArgs = { 0.631373, 0.647059, 0.631373 }
                        mt._storedValues[propName] = c
                    elseif dv == "Vector3" then
                        local v = makeProxy(mt._name .. "." .. propName)
                        local vmt = getmetatable(v)
                        vmt._ctorName = "Vector3"
                        vmt._ctorArgs = { 0, 0, 0 }
                        mt._storedValues[propName] = v
                    elseif dv == "Vector2" then
                        local v = makeProxy(mt._name .. "." .. propName)
                        local vmt = getmetatable(v)
                        vmt._ctorName = "Vector2"
                        vmt._ctorArgs = { 0, 0 }
                        mt._storedValues[propName] = v
                    elseif dv == "UDim2" then
                        local u = makeProxy(mt._name .. "." .. propName)
                        local umt = getmetatable(u)
                        umt._ctorName = "UDim2"
                        umt._ctorArgs = { 0, 0, 0, 0 }
                        mt._storedValues[propName] = u
                    elseif dv == "CFrame" then
                        local cf = makeProxy(mt._name .. "." .. propName)
                        local cfmt = getmetatable(cf)
                        cfmt._ctorName = "CFrame"
                        cfmt._ctorArgs = { 0, 0, 0 }
                        mt._storedValues[propName] = cf
                    elseif dv == "NumberRange" then
                        local nr = makeProxy(mt._name .. "." .. propName)
                        local nrmt = getmetatable(nr)
                        nrmt._ctorName = "NumberRange"
                        nrmt._ctorArgs = { 0, 0 }
                        mt._storedValues[propName] = nr
                    elseif type(dv) == "string" and dv:match("^Enum%.") then
                        local enumItem = makeProxy(mt._name .. "." .. propName)
                        local eimt = getmetatable(enumItem)
                        eimt._className = "EnumItem"
                        eimt._ctorName = "EnumItem"
                        eimt._storedValues["Name"] = dv:sub(dv:find("%.[^%.]*$") + 1, -1)
                        eimt._storedValues["Value"] = 0
                        eimt._storedValues["EnumType"] = dv:match("^Enum%.([%w_]+)%.")
                        mt._storedValues[propName] = enumItem
                    else
                        mt._storedValues[propName] = dv
                    end
                    mt._setKeys[propName] = true
                end
            end
        end
    end
end

spyInstance = function(className: string, name: string?, silent: boolean?): any
    local varName = name or genVar("inst")
    if not silent then
        emit(string.format('local %s = Instance.new("%s")', varName, className))
    end
    local proxy = makeProxy(varName)
    local mt = getmetatable(proxy)
    mt._className = className
    mt._storedValues["ClassName"] = className
    mt._setKeys["ClassName"] = true
    applyClassDefaults(proxy, className)
    return proxy
end

local env
local _realDebug = debug
local _realDebugInfo = _realDebug and _realDebug.info or nil
local _realDebugTraceback = _realDebug and _realDebug.traceback or nil
local knownCFunctions = {}
local functionAddrMap = setmetatable({}, { __mode = "k" })
local frozenTables = setmetatable({}, { __mode = "k" })
local readonlyTables = setmetatable({}, { __mode = "k" })
local hookTargets = setmetatable({}, { __mode = "k" })
local hookReplacements = setmetatable({}, { __mode = "k" })
local originalBehaviors = setmetatable({}, { __mode = "k" })
local cloneSources = setmetatable({}, { __mode = "k" })
local cloneWrappers = setmetatable({}, { __mode = "k" })
local cclosureSet = setmetatable({}, { __mode = "k" })
local constantEdits = setmetatable({}, { __mode = "k" })
local applyReadonlyGuard: (any) -> ()
local function registerCFunctions(lib)
    if type(lib) == "table" then
        for k, v in pairs(lib) do
            if type(v) == "function" then knownCFunctions[v] = true end
        end
    end
end
registerCFunctions(math)
registerCFunctions(string)
registerCFunctions(table)
registerCFunctions(coroutine)
registerCFunctions(os)
registerCFunctions(bit32)
registerCFunctions(utf8)
knownCFunctions[print] = true
knownCFunctions[pcall] = true
knownCFunctions[xpcall] = true
knownCFunctions[error] = true
knownCFunctions[assert] = true
knownCFunctions[tonumber] = true
knownCFunctions[tostring] = true
knownCFunctions[type] = true
knownCFunctions[select] = true
knownCFunctions[pairs] = true
knownCFunctions[ipairs] = true
knownCFunctions[next] = true
knownCFunctions[rawget] = true
knownCFunctions[rawset] = true
knownCFunctions[rawequal] = true
knownCFunctions[rawlen] = true
knownCFunctions[setmetatable] = true
knownCFunctions[getmetatable] = true
knownCFunctions[unpack] = true
local function createEnv()
    env = {}
    env._G = {}
    env._ENV = env
    local function getFunctionWhat(f)
        if type(f) ~= "function" then
            return nil
        end
        if knownCFunctions[f] or cclosureSet[f] then
            return "C"
        end
        if _realDebugInfo then
            local ok, what = pcall(_realDebugInfo, f, "w")
            if ok and type(what) == "string" then
                return what
            end
        end
        return "Lua"
    end
    local function copyLib(lib, extra)
        local c = {}
        for k, v in pairs(lib) do c[k] = v end
        if extra then
            for k, v in pairs(extra) do c[k] = v end
        end
        return setmetatable(c, {
            __newindex = function(_, k, v)
                error("attempt to write to read-only library table", 2)
            end
        })
    end
    env.math = copyLib(math, {
        abs = function(x) if type(x) == "string" or type(x) == "boolean" or x == nil then error("bad argument #1 to 'abs' (number expected)", 2) end if type(x) ~= "number" then return 0 end return math.abs(x) end,
        floor = function(x) if type(x) == "string" or type(x) == "boolean" or x == nil then error("bad argument #1 to 'floor' (number expected)", 2) end if type(x) ~= "number" then return 0 end return math.floor(x) end,
        ceil = function(x) if type(x) == "string" or type(x) == "boolean" or x == nil then error("bad argument #1 to 'ceil' (number expected)", 2) end if type(x) ~= "number" then return 0 end return math.ceil(x) end,
        sqrt = function(x) if type(x) == "string" or type(x) == "boolean" or x == nil then error("bad argument #1 to 'sqrt' (number expected)", 2) end if type(x) ~= "number" then return 0 end return math.sqrt(x) end,
        sin = function(x) if type(x) == "string" or type(x) == "boolean" or x == nil then error("bad argument #1 to 'sin' (number expected)", 2) end if type(x) ~= "number" then return 0 end return math.sin(x) end,
        cos = function(x) if type(x) == "string" or type(x) == "boolean" or x == nil then error("bad argument #1 to 'cos' (number expected)", 2) end if type(x) ~= "number" then return 0 end return math.cos(x) end,
        tan = function(x) if type(x) == "string" or type(x) == "boolean" or x == nil then error("bad argument #1 to 'tan' (number expected)", 2) end if type(x) ~= "number" then return 0 end return math.tan(x) end,
        random = function(a, b) if a and b then return math.random(a, b) elseif a then return math.random(a) else return math.random() end end,
        clamp = function(x, min, max) if type(x) ~= "number" then return 0 end return math.clamp(x, min, max) end,
        sign = function(x) if type(x) ~= "number" then return 0 end return math.sign(x) end,
        round = function(x) if type(x) ~= "number" then return 0 end return math.round(x) end,
        fmod = function(x, y) if type(x) ~= "number" or type(y) ~= "number" then return 0 end return math.fmod(x, y) end,
        pow = function(x, y) if type(x) ~= "number" or type(y) ~= "number" then return 0 end return math.pow(x, y) end,
        exp = function(x) if type(x) ~= "number" then return 0 end return math.exp(x) end,
        log = function(x, base) if type(x) ~= "number" then return 0 end if base then return math.log(x, base) end return math.log(x) end,
        asin = function(x) if type(x) ~= "number" then return 0 end return math.asin(x) end,
        acos = function(x) if type(x) ~= "number" then return 0 end return math.acos(x) end,
        atan = function(x, y) if type(x) ~= "number" then return 0 end if y then return math.atan(x, y) end return math.atan(x) end,
        atan2 = function(x, y) if type(x) ~= "number" or type(y) ~= "number" then return 0 end return math.atan2(x, y) end,
        huge = math.huge, pi = math.pi, maxinteger = math.maxinteger, mininteger = math.mininteger,
        noise = function(x, y, z) return 0 end,
        randomseed = function(seed) math.randomseed(seed) end,
    })
    registerCFunctions(env.math)
    for _, v in pairs(env.math) do
        if type(v) == "function" then knownCFunctions[v] = true end
    end
    knownCFunctions[env.math.clamp] = true
    knownCFunctions[env.math.sign] = true
    knownCFunctions[env.math.round] = true
    knownCFunctions[env.math.noise] = true
    knownCFunctions[env.math.randomseed] = true
    env.string = copyLib(string, {
        dump = function(f, strip)
            error("unable to dump given function", 2)
        end,
    })
    registerCFunctions(env.string)
    env.table = copyLib(table, {
        isfrozen = function(t)
            if type(t) ~= "table" then return false end
            return frozenTables[t] == true
        end,
        freeze = function(t)
            if type(t) ~= "table" then error("invalid argument #1 to 'freeze' (table expected)", 2) end
            frozenTables[t] = true
            applyReadonlyGuard(t)
            return t
        end,
        find = function() return nil end,
        clone = function(t)
            if type(t) ~= "table" then return t end
            local c = {}
            for k, v in pairs(t) do c[k] = v end
            return c
        end,
        isfrozen = function(t)
            if type(t) ~= "table" then return false end
            return frozenTables[t] == true
        end,
        create = function(n, v)
            if type(n) ~= "number" then n = 0 end
            if n < 0 then n = 0 end
            if n > 1000000 then n = 1000000 end
            local t = {}
            for i = 1, math.floor(n) do t[i] = v end
            return t
        end,
    })
    local function checkFrozen(t, op, key)
        if type(t) == "table" and (frozenTables[t] or readonlyTables[t]) then
            local desc = op == "newindex" and ("attempt to modify a readonly table (" .. tostring(key) .. ")") or "attempt to modify a readonly table"
            error(desc, 3)
        end
    end
    local realSetmetatable = setmetatable
    applyReadonlyGuard = function(t)
        if type(t) ~= "table" then return end
        if frozenTables[t] then
            local snapshot = {}
            for k, v in pairs(t) do snapshot[k] = v end
            for k in pairs(t) do rawset(t, k, nil) end
            local guardMt = {
                __index = snapshot,
                __newindex = function(tt, k, v)
                    error("attempt to modify a readonly table", 2)
                end,
                _isReadonlyGuard = true,
                _isFrozen = true,
            }
            realSetmetatable(t, guardMt)
            return
        end
        local existingMt = getmetatable(t)
        if existingMt and existingMt._isReadonlyGuard and existingMt._isFrozen then
            return
        end
        if existingMt and existingMt.__newindex and not existingMt._isReadonlyGuard then
            local prevNewindex = existingMt.__newindex
            existingMt.__newindex = function(tt, k, v)
                if readonlyTables[t] or frozenTables[t] then
                    error("attempt to modify a readonly table", 2)
                end
                if type(prevNewindex) == "function" then
                    prevNewindex(tt, k, v)
                else
                    rawset(tt, k, v)
                end
            end
            existingMt._isReadonlyGuard = true
            return
        end
        if existingMt == nil then
            local guardMt = {
                __newindex = function(tt, k, v)
                    if readonlyTables[t] or frozenTables[t] then
                        error("attempt to modify a readonly table", 2)
                    end
                    rawset(tt, k, v)
                end,
                _isReadonlyGuard = true,
            }
            realSetmetatable(t, guardMt)
        end
    end
    env.coroutine = copyLib(coroutine)
    env.os = setmetatable({
        time = os.time,
        date = os.date,
        clock = os.clock,
        difftime = os.difftime,
    }, {
        _serialName = "os",
        __newindex = function() error("attempt to write to read-only library table", 2) end,
        __tostring = function() return "table: 0x" .. string.format("%x", math.random(1048576, 1099511627776)) end,
    })
    env.debug = setmetatable({
        info = function(f, what)
            what = what or "fl"
            if type(f) == "function" then
                local isC = knownCFunctions[f] or cclosureSet[f]
                local source, whatKind, currentline, linedefined, lastlinedefined, name, nparams, isvararg, nups
                if isC then
                    source = "[C]"
                    whatKind = "C"
                    currentline = -1
                    linedefined = -1
                    lastlinedefined = -1
                    name = ""
                    pcall(function()
                        local funcNames = {
                            [env.print] = "print", [env.warn] = "warn", [env.error] = "error",
                            [env.assert] = "assert", [env.pcall] = "pcall", [env.xpcall] = "xpcall",
                            [env.select] = "select", [env.tostring] = "tostring", [env.tonumber] = "tonumber",
                            [env.type] = "type", [env.typeof] = "typeof", [env.unpack] = "unpack",
                            [env.rawget] = "rawget", [env.rawset] = "rawset", [env.rawequal] = "rawequal",
                            [env.rawlen] = "rawlen", [env.setmetatable] = "setmetatable",
                            [env.getmetatable] = "getmetatable", [env.pairs] = "pairs",
                            [env.ipairs] = "ipairs", [env.next] = "next",
                            [env.getfenv] = "getfenv", [env.setfenv] = "setfenv",
                            [env.require] = "require", [env.loadstring] = "loadstring", [env.load] = "load",
                            [print] = "print", [warn] = "warn", [error] = "error", [assert] = "assert",
                            [pcall] = "pcall", [xpcall] = "xpcall", [select] = "select",
                            [tostring] = "tostring", [tonumber] = "tonumber", [type] = "type",
                            [unpack] = "unpack", [rawget] = "rawget", [rawset] = "rawset",
                            [rawequal] = "rawequal", [rawlen] = "rawlen", [setmetatable] = "setmetatable",
                            [getmetatable] = "getmetatable", [pairs] = "pairs", [ipairs] = "ipairs",
                            [next] = "next", [getfenv] = "getfenv", [setfenv] = "setfenv",
                        }
                        name = funcNames[f] or ""
                    end)
                    nparams = 0
                    isvararg = false
                    pcall(function()
                        local varargCFuncs = {
                            [env.print] = true, [env.warn] = true, [env.error] = true, [env.assert] = true,
                            [env.pcall] = true, [env.xpcall] = true, [env.select] = true, [env.tostring] = true,
                            [env.tonumber] = true, [env.type] = true, [env.typeof] = true,
                            [env.unpack] = true, [env.rawget] = true, [env.rawset] = true, [env.rawequal] = true,
                            [env.rawlen] = true, [env.setmetatable] = true, [env.getmetatable] = true,
                            [env.pairs] = true, [env.ipairs] = true, [env.next] = true,
                            [print] = true, [warn] = true, [error] = true, [assert] = true,
                            [pcall] = true, [xpcall] = true, [select] = true, [tostring] = true,
                            [tonumber] = true, [type] = true, [unpack] = true, [rawget] = true,
                            [rawset] = true, [rawequal] = true, [rawlen] = true, [setmetatable] = true,
                            [getmetatable] = true, [pairs] = true, [ipairs] = true, [next] = true,
                        }
                        isvararg = varargCFuncs[f] == true
                    end)
                    nups = 0
                else
                    local ok, src = pcall(_realDebugInfo, f, "s")
                    if ok then source = src else source = "[?]" end
                    local ok2, w2 = pcall(_realDebugInfo, f, "w")
                    if ok2 then whatKind = w2 else whatKind = "Lua" end
                    local ok3, ln = pcall(_realDebugInfo, f, "l")
                    if ok3 then currentline = ln else currentline = -1 end
                    local ok4, ld = pcall(_realDebugInfo, f, "l")
                    if ok4 then linedefined = ld else linedefined = -1 end
                    lastlinedefined = -1
                    local ok5, nm = pcall(_realDebugInfo, f, "n")
                    if ok5 then name = nm or "" else name = "" end
                    local ok6, np, iv = pcall(_realDebugInfo, f, "a")
                    if ok6 then nparams = np isvararg = iv else nparams = 0 isvararg = false end
                    local ok7, nupsV = pcall(_realDebugInfo, f, "u")
                    if ok7 and type(nupsV) == "number" then nups = nupsV else nups = 0 end
                end
                if what == "*" or what == "" then
                    return {
                        source = source, short_src = source, what = whatKind,
                        currentline = currentline, linedefined = linedefined,
                        lastlinedefined = lastlinedefined, name = name,
                        nups = nups, nparams = nparams, is_vararg = isvararg, func = f,
                    }
                end
                local results = {}
                for i = 1, #what do
                    local ch = what:sub(i, i)
                    if ch == "s" then table.insert(results, source)
                    elseif ch == "l" then table.insert(results, currentline)
                    elseif ch == "n" then table.insert(results, name)
                    elseif ch == "f" then table.insert(results, f)
                    elseif ch == "a" then table.insert(results, nparams) table.insert(results, isvararg)
                    elseif ch == "u" then table.insert(results, nups)
                    elseif ch == "w" then table.insert(results, whatKind)
                    else table.insert(results, nil) end
                end
                return table.unpack(results)
            end
            if type(f) == "nil" then
                error("invalid argument #1 to 'info' (number or function expected)", 2)
            end
            if type(f) == "number" then
                local results = {}
                if type(what) == "string" and #what > 0 and what ~= "*" then
                    for i = 1, #what do
                        local ch = what:sub(i, i)
                        local ok, val = pcall(_realDebugInfo, f, ch)
                        if ok then table.insert(results, val) else table.insert(results, nil) end
                    end
                    return table.unpack(results)
                end
                local ok, val = pcall(_realDebugInfo, f, what or "fl")
                if ok then return val end
                return nil
            end
            return nil
        end,
        traceback = function(msg, level)
            if _realDebugTraceback then
                local ok, tb = pcall(_realDebugTraceback, msg, level)
                if ok then return tb end
            end
            return tostring(msg or "")
        end,
    }, {
        __index = function(_, k)
            if k == "getinfo" then
                return function(f, what)
                    what = what or "*"
                    if what == "*" or what == "" then
                        if type(f) == "function" then
                            local isC = knownCFunctions[f] or cclosureSet[f]
                            if isC then
                                return {
                                    source = "[C]", short_src = "[C]", what = "C",
                                    currentline = -1, linedefined = -1, lastlinedefined = -1,
                                    name = "", nups = 0, nparams = 0, is_vararg = false, func = f,
                                }
                            end
                            local info = {}
                            local okS, src = pcall(_realDebugInfo, f, "s")
                            if okS then info.source = src info.short_src = src end
                            local okW, w = pcall(_realDebugInfo, f, "w")
                            if okW then info.what = w else info.what = "Lua" end
                            local okL, ln = pcall(_realDebugInfo, f, "l")
                            if okL then info.currentline = ln else info.currentline = -1 end
                            info.linedefined = -1
                            info.lastlinedefined = -1
                            local okN, nm = pcall(_realDebugInfo, f, "n")
                            if okN then info.name = nm or "" else info.name = "" end
                            local okA, np, iv = pcall(_realDebugInfo, f, "a")
                            if okA then info.nparams = np info.is_vararg = iv else info.nparams = 0 info.is_vararg = false end
                            local okU, nups = pcall(_realDebugInfo, f, "u")
                            if okU and type(nups) == "number" then info.nups = nups else info.nups = 0 end
                            info.func = f
                            return info
                        end
                        if type(f) == "number" then
                            local info = {}
                            local okS, src = pcall(_realDebugInfo, f, "s")
                            if okS then info.source = src info.short_src = src end
                            local okW, w = pcall(_realDebugInfo, f, "w")
                            if okW then info.what = w else info.what = "Lua" end
                            local okL, ln = pcall(_realDebugInfo, f, "l")
                            if okL then info.currentline = ln else info.currentline = -1 end
                            info.linedefined = -1
                            info.lastlinedefined = -1
                            local okN, nm = pcall(_realDebugInfo, f, "n")
                            if okN then info.name = nm or "" else info.name = "" end
                            local okA, np, iv = pcall(_realDebugInfo, f, "a")
                            if okA then info.nparams = np info.is_vararg = iv else info.nparams = 0 info.is_vararg = false end
                            local okU, nups = pcall(_realDebugInfo, f, "u")
                            if okU and type(nups) == "number" then info.nups = nups else info.nups = 0 end
                            info.func = nil
                            return info
                        end
                    end
                    return env.debug.info(f, what)
                end
            end
            if k == "getupvalue" then
                return function(f, i)
                    if type(f) ~= "function" then error("invalid argument #1 to 'getupvalue'", 2) end
                    if knownCFunctions[f] or cclosureSet[f] then
                        error("attempt to get upvalue of C closure", 2)
                    end
                    return nil
                end
            end
            if k == "setupvalue" then
                return function(f, i, v)
                    if type(f) ~= "function" then error("invalid argument #1 to 'setupvalue'", 2) end
                    if knownCFunctions[f] or cclosureSet[f] then
                        error("attempt to set upvalue of C closure", 2)
                    end
                    return v
                end
            end
            if k == "getconstants" then
                return function(f)
                    if type(f) ~= "function" then error("invalid argument #1 to 'getconstants'", 2) end
                    if knownCFunctions[f] or cclosureSet[f] then
                        error("attempt to get constants of C closure", 2)
                    end
                    local edits = constantEdits[f]
                    if edits then
                        local result = {}
                        for k, v in pairs(edits) do result[k] = v end
                        return result
                    end
                    return {}
                end
            end
            if k == "setconstant" then
                return function(f, idx, val)
                    if type(f) ~= "function" then error("invalid argument #1 to 'setconstant'", 2) end
                    if knownCFunctions[f] or cclosureSet[f] then
                        error("attempt to set constant of C closure", 2)
                    end
                    if type(idx) ~= "number" then error("invalid argument #2 to 'setconstant'", 2) end
                    if not constantEdits[f] then constantEdits[f] = {} end
                    constantEdits[f][idx] = val
                    return true
                end
            end
            if k == "getupvalues" then
                return function(f)
                    if type(f) ~= "function" then error("invalid argument #1 to 'getupvalues'", 2) end
                    return {}
                end
            end
            if k == "setfenv" then
                return function(f, env) return f end
            end
            if k == "getfenv" then
                return function(level)
                    if type(level) == "number" and level > 100 then return nil end
                    return env
                end
            end
            return nil
        end,
        __newindex = function() error("attempt to write to read-only library table", 2) end,
    })
    env.io = nil
    local function wrapPcall(f, ...)
        local results = table.pack(pcall(f, ...))
        local ok = results[1]
        if not ok and type(results[2]) == "string" and results[2]:find("stack", 1, true) then
            results[2] = "stack overflow"
        end
        return table.unpack(results, 1, results.n)
    end
    env.pcall = function(f, ...) return wrapPcall(f, ...) end
    env.xpcall = function(f, handler, ...)
        local results = table.pack(xpcall(f, handler, ...))
        local ok = results[1]
        if not ok and type(results[2]) == "string" and results[2]:find("stack", 1, true) then
            results[2] = "stack overflow"
        end
        return table.unpack(results, 1, results.n)
    end
    env.error = error; env.assert = assert
    env.tonumber = tonumber; local tostringCounter = 0
    env.tostring = function(v)
        if type(v) == "table" then
            local m = getmetatable(v)
            if m and m._isProxy then return m._name or "Instance" end
            if m and m._customAddr then return m._customAddr end
            tostringCounter += 1
            local addr = string.format("table: 0x%x", tostringCounter * 26544357612345 % 0x10000000000000000 + 0x100000000)
            if m then
                m._customAddr = addr
                return addr
            end
            return addr
        end
        if type(v) == "function" then
            if functionAddrMap[v] then return functionAddrMap[v] end
            tostringCounter += 1
            local id = tostringCounter
            local hi = (id * 2654435761) % 0x10000
            local lo = (id * 40503) % 0x100000000
            local addr = string.format("function: 0x%04x%012x", hi, lo)
            functionAddrMap[v] = addr
            return addr
        end
        if type(v) == "userdata" then
            local m = getmetatable(v)
            if m and m._customAddr then return m._customAddr end
            if m and m.__metatable ~= nil then return "userdata: " .. tostring(m.__metatable) end
            tostringCounter += 1
            local addr = string.format("userdata: 0x%x", tostringCounter * 26544357612345 % 0x10000000000000000 + 0x100000000)
            if m then
                m._customAddr = addr
                return addr
            end
            return addr
        end
        return tostring(v)
    end; env.type = type; env.select = select
    env.unpack = table.unpack; env.rawget = rawget; env.rawset = function(t, k, v)
        if type(t) == "table" and (frozenTables[t] or readonlyTables[t]) then
            error("attempt to modify a readonly table", 2)
        end
        return rawset(t, k, v)
    end; env.rawequal = rawequal
    env.rawlen = rawlen; env.setmetatable = function(t, mt)
        if type(t) == "table" and (frozenTables[t] or readonlyTables[t]) then
            error("attempt to modify a readonly table", 2)
        end
        local prevMt = getmetatable(t)
        if type(mt) == "table" and prevMt and prevMt._isReadonlyGuard and prevMt._isReadonlyLocked then
            local snapshot = prevMt.__index
            if type(snapshot) == "table" then
                for k, v in pairs(snapshot) do mt[k] = v end
            end
            local userNewindex = mt.__newindex
            mt.__newindex = function(tt, k, v)
                if readonlyTables[t] or frozenTables[t] then
                    error("attempt to modify a readonly table", 2)
                end
                if type(userNewindex) == "function" then
                    userNewindex(tt, k, v)
                else
                    rawset(tt, k, v)
                end
            end
            mt._isReadonlyGuard = true
        end
        return realSetmetatable(t, mt)
    end; env.getmetatable = function(t)
        if type(t) == "string" then return nil end
        local m = getmetatable(t)
        if m and m._isReadonlyGuard and m._isReadonlyLocked then
            local snapshot = m.__index
            if type(snapshot) == "table" then return snapshot end
            return nil
        end
        if m and m._isReadonlyGuard and m._isFrozen then
            local snapshot = m.__index
            if type(snapshot) == "table" then return snapshot end
            return nil
        end
        if m and m._isReadonlyGuard and m._originalMt then return m._originalMt end
        if m and m.__metatable ~= nil then return m.__metatable end
        if m and m._isProxy then
            local cls = m._className or ""
            if cls == "DataModel" or cls == "Workspace" or cls == "Instance" then
                return "The metatable is locked"
            end
        end
        if m and m._isReadonlyGuard then
            return nil
        end
        return m
    end
    env.ipairs = function(t, ...)
        if type(t) == "table" then
            local m = getmetatable(t)
            if m and m._isProxy then
                return function() return nil end, nil, 0
            end
        end
        return ipairs(t, ...)
    end; env.pairs = pairs; env.next = next; env._VERSION = "Luau"
    env.utf8 = setmetatable({
        char = utf8.char,
        codepoint = utf8.codepoint,
        codes = utf8.codes,
        len = utf8.len,
        offset = utf8.offset,
        nfcnormalize = utf8.nfcnormalize,
        nfdnormalize = utf8.nfdnormalize,
        charpattern = utf8.charpattern,
        graphemes = function(s)
            local i = 1
            local len = #s
            return function()
                if i > len then return nil end
                local start = i
                i += 1
                return start, i - 1
            end
        end,
    }, {
        __index = function(_, k) return function() return nil end end,
        __newindex = function() error("attempt to write to read-only library table", 2) end
    }); env.bit32 = copyLib(bit32); env.bit = env.bit32
    env.typeof = function(x)
        local t = type(x)
        if t == "table" then
            local m = getmetatable(x)
            if m and m._isProxy then
                if m._ctorName then return m._ctorName end
                if m._isMethod then return "function" end
                local fieldName = m._fieldName
                local parent = m._parent
                local parentMt = parent and getmetatable(parent) or nil
                if fieldName and parentMt and parentMt._className then
                    local runtimeTypeName = getPropertyRuntimeType(parentMt._className, fieldName)
                    if runtimeTypeName then
                        return runtimeTypeName
                    end
                    local memberInfo = resolveApiMember(parentMt._className, fieldName)
                    if memberInfo and (memberInfo.memberType == "Function" or memberInfo.memberType == "Method") then
                        return "function"
                    end
                end
                if m._signalForEvent or m._signalForProperty then
                    return "RBXScriptSignal"
                end
                local cls = m._className
                if cls == "RBXScriptConnection" then return cls end
                if cls == "DateTime" then return "DateTime" end
                if cls == "EnumItem" then return "EnumItem" end
                if cls == "Enum" then return "Enum" end
                if cls == "Secret" then return "Secret" end
                if cls == "PlayerMouse" then return "PlayerMouse" end
                return "Instance"
            end
            if m and m._isEnumType then return "Enum" end
        end
        return t
    end
    env.type = function(x)
        local t = type(x)
        if t == "table" then
            local m = getmetatable(x)
            if m and m._isProxy then
                local parent = m._parent
                local parentMt = parent and getmetatable(parent) or nil
                local memberInfo = nil
                if m._fieldName and parentMt and parentMt._className then
                    memberInfo = resolveApiMember(parentMt._className, m._fieldName)
                end
                if isCallableMember(memberInfo) then
                    return "function"
                end
                return "userdata"
            end
        end
        return t
    end
    env.print = function(...)
        local a={...}
        local p={}
        for i=1,select("#",...) do p[i]=serialize(a[i]) end
        emit("print(" .. table.concat(p, ", ") .. ")")
        return "nil"
    end
    env.warn = function(...)
        local a={...}
        local p={}
        for i=1,select("#",...) do p[i]=serialize(a[i]) end
        emit("warn(" .. table.concat(p, ", ") .. ")")
        return "nil"
    end
    env.setfenv = function(f, env)
        return f
    end
    env.ypcall = env.pcall
    env.settings = function()
        local s = makeProxy("GlobalSettings")
        local mt = getmetatable(s)
        mt._className = "GlobalSettings"
        mt._storedValues["ClassName"] = "GlobalSettings"
        mt._setKeys["ClassName"] = true
        return s
    end
    env.GetMemory = function() return 0 end
    env.GetGPUStats = function() return {} end
    env.GetPlatform = function() return "Windows" end
    env.getfenv = function(level)
        if type(level) == "number" then
            if level < 1 then
                error("invalid argument #1 to 'getfenv' (level out of range)", 2)
            end
            if level > 1 then
                error("invalid argument #1 to 'getfenv' (level out of range)", 2)
            end
        end
        if level == nil then
            return env
        end
        if type(level) == "function" then
            return env
        end
        return env
    end
    env.version = function() return "0.728.0.7280895" end
    env._VERSION = "Luau"
    local _vmInsnCount = 0
    local _vmInsnBudget = 1000000000
    env._VMC = function()
        _vmInsnCount += 1
        if _vmInsnCount > _vmInsnBudget then
            return true
        end
        return false
    end
    env.loadstring = function(src, chunkname)
        if type(src) ~= "string" then return nil, "invalid argument #1 to 'loadstring'" end
        if src:find('require%("@lune') or src:find("require%('@lune") or src:find('require%("lfs') or src:find("require%('lfs") then
            return nil, "blocked: lune/lfs require"
        end
        if #src > 5000 and src:sub(1, 5) == "local" then
            src = src:gsub("repeat ", "repeat if _VMC() then error('VM_BUDGET') end ")
            src = src:gsub("while true do", "while true do if _VMC() then error('VM_BUDGET') end ")
        end
        local ok, compiled = pcall(luau.compile, src, { optimizationLevel = 1 })
        if not ok then
            return nil, tostring(compiled)
        end
        local loadOk, fn = pcall(luau.load, compiled, { debugName = chunkname or "loadstring", environment = env, debugLevel = 0 })
        if not loadOk or type(fn) ~= "function" then
            return nil, tostring(fn)
        end
        return fn
    end
    env.load = function(src, chunkname, mode, envArg)
        if type(src) == "string" then
            local ok, compiled = pcall(luau.compile, src, { optimizationLevel = 1 })
            if not ok then return nil, tostring(compiled) end
            local loadOk, fn = pcall(luau.load, compiled, { debugName = chunkname or "load", environment = envArg or env })
            if not loadOk or type(fn) ~= "function" then return nil, tostring(fn) end
            return fn
        elseif type(src) == "function" then
            local chunks = {}
            while true do
                local chunk = src()
                if not chunk then break end
                table.insert(chunks, chunk)
            end
            local full = table.concat(chunks)
            return env.loadstring(full, chunkname, mode, envArg)
        end
        return nil, "invalid argument #1 to 'load'"
    end

    env.game = spyInstance("DataModel", "game", true)
    env.Game = env.game
    local gameMt = getmetatable(env.game)
    gameMt._storedValues["PlaceId"] = math.random(100000000, 2147483646)
    gameMt._setKeys["PlaceId"] = true
    local function randHex(n) local s = "" for _=1,n do s = s .. string.format("%x", math.random(0, 15)) end return s end
    gameMt._storedValues["JobId"] = randHex(8) .. "-" .. randHex(4) .. "-" .. randHex(4) .. "-" .. randHex(4) .. "-" .. randHex(12)
    gameMt._setKeys["JobId"] = true
    gameMt._storedValues["GameId"] = math.random(100000000, 2147483646)
    gameMt._setKeys["GameId"] = true
    gameMt._storedValues["CreatorId"] = math.random(1, 999999)
    gameMt._setKeys["CreatorId"] = true
    env.workspace = spyInstance("Workspace", "workspace", true)
    env.Workspace = env.workspace
    workspaceProxy = env.workspace
    local wsMt = getmetatable(env.workspace)
    wsMt._storedValues["Parent"] = env.game
    wsMt._setKeys["Parent"] = true
    local baseplate = makeProxy("Baseplate")
    local bpMt = getmetatable(baseplate)
    bpMt._className = "Part"
    bpMt._storedValues["Name"] = "Baseplate"
    bpMt._setKeys["Name"] = true
    bpMt._storedValues["ClassName"] = "Part"
    bpMt._setKeys["ClassName"] = true
    bpMt._storedValues["Parent"] = env.workspace
    bpMt._setKeys["Parent"] = true
    if not parentChildMap["workspace"] then parentChildMap["workspace"] = {} end
    parentChildMap["workspace"]["Baseplate"] = baseplate
    local terrain = makeProxy("Terrain")
    local terrainMt = getmetatable(terrain)
    terrainMt._className = "Terrain"
    terrainMt._storedValues["ClassName"] = "Terrain"
    terrainMt._setKeys["ClassName"] = true
    terrainMt._storedValues["Parent"] = env.workspace
    terrainMt._setKeys["Parent"] = true
    parentChildMap["workspace"]["Terrain"] = terrain
    env.script = spyInstance("LocalScript", "script", true)

    env.Instance = setmetatable({
        new = function(c)
            local cls = tostring(c or "Instance")
            if not getApiClassInfo(cls) then
                error("Instance.new: invalid class '" .. cls .. "'", 2)
            end
            if not isApiCreatableClass(cls) then
                error("Instance.new: cannot create class '" .. cls .. "'", 2)
            end
            local v = genVar("inst")
            emit(string.format('local %s = Instance.new("%s")', v, cls))
            local proxy = makeProxy(v)
            local mt = getmetatable(proxy)
            mt._className = cls
            mt._storedValues["ClassName"] = cls
            mt._setKeys["ClassName"] = true
            applyClassDefaults(proxy, cls)
            return proxy
        end,
    }, { __index = function(_, k) return makeProxy("Instance." .. tostring(k)) end })
    local enumCache = _G._enumCache or {}
    _G._enumCache = enumCache
    env.Enum = setmetatable({
        GetEnumItems = function() return {} end,
    }, {
        __index = function(_, k)
            if not enumCache[k] then
                local enumType = setmetatable({
                    GetEnumItems = function() return {
                        { Name = "Item1", Value = 0 },
                        { Name = "Item2", Value = 1 },
                    } end,
                    GetByValue = function() return nil end,
                }, {
                    __index = function(_, k2)
                        local cacheKey = tostring(k) .. "." .. tostring(k2)
                        if not enumCache[cacheKey] then
                            local item = makeProxy("Enum." .. tostring(k) .. "." .. tostring(k2))
                            local itemMt = getmetatable(item)
                            itemMt._className = "EnumItem"
                            itemMt._ctorName = "EnumItem"
                            itemMt._storedValues["Name"] = tostring(k2)
                            itemMt._setKeys["Name"] = true
                            local ENUM_VALUE_MAP = {
                                Material = { Plastic = 256, Neon = 1024, SmoothPlastic = 256, Wood = 512, Slate = 256, Concrete = 256, Metal = 256, Brick = 256, Sand = 256, Fabric = 256, Ice = 512, Grass = 256, Granite = 256, Marble = 256, DiamondPlate = 1024, Foil = 512, CorrodedMetal = 512, Glass = 512, Asphalt = 256, Basalt = 256, Bone = 256, Cardboard = 256, Ceramic = 256, Cobblestone = 256, Concrete = 256, DiamondPlate = 1024, Salt = 256, Snow = 256, WoodPlanks = 512 },
                                PartType = { Block = 0, Ball = 1, Cylinder = 2, Wedge = 3, CornerWedge = 4 },
                                SurfaceType = { Smooth = 0 },
                                HumanoidStateType = { Running = 12 },
                                MembershipType = { None = 0, Premium = 4, BuildersClub = 1, TurboBuildersClub = 2, OutrageousBuildersClub = 3 },
                            }
                            local val = 0
                            if ENUM_VALUE_MAP[tostring(k)] and ENUM_VALUE_MAP[tostring(k)][tostring(k2)] then
                                val = ENUM_VALUE_MAP[tostring(k)][tostring(k2)]
                            end
                            itemMt._storedValues["Value"] = val
                            itemMt._setKeys["Value"] = true
                            itemMt._storedValues["EnumType"] = tostring(k)
                            itemMt._setKeys["EnumType"] = true
                            enumCache[cacheKey] = item
                        end
                        return enumCache[cacheKey]
                    end
                })
                local etMt = getmetatable(enumType)
                etMt._isEnumType = true
                enumCache[k] = enumType
            end
            return enumCache[k]
        end
    })
    env.Enums = env.Enum
    pcall(function()
        local _ = env.Enum.MembershipType.None
    end)

    local DATA_TYPES = { Vector3 = true, Vector2 = true, UDim2 = true, UDim = true, CFrame = true }
    local function newCtor(name)
        return setmetatable({ new = function(...)
            local v = genVar(name:lower())
            local parts = {}
            local args = {...}
            for i = 1, select("#", ...) do table.insert(parts, serialize(args[i])) end
            if name == "NumberRange" and #args == 2 and type(args[1]) == "number" and type(args[2]) == "number" then
                if args[1] > args[2] then
                    error("NumberRange: min must be <= max", 0)
                end
            end
            emit(string.format('local %s = %s.new(%s)', v, name, table.concat(parts, ", ")))
            if DATA_TYPES[name] then
                return makeDataProxy(name, {...}, v)
            end
            local proxy = makeProxy(v)
            local mt = getmetatable(proxy)
            mt._ctorArgs = {...}
            mt._ctorName = name
            return proxy
        end }, { __index = function(_, k)
            local constants = {
                Vector3 = {
                    zero = {0, 0, 0}, one = {1, 1, 1},
                    xAxis = {1, 0, 0}, yAxis = {0, 1, 0}, zAxis = {0, 0, 1},
                },
                Vector2 = {
                    zero = {0, 0}, one = {1, 1},
                },
            }
            local c = constants[name]
            if c and c[k] then
                if DATA_TYPES[name] then
                    return makeDataProxy(name, c[k], name .. "." .. k)
                end
                local p = makeProxy(name .. "." .. k)
                local mt = getmetatable(p)
                mt._ctorArgs = c[k]
                mt._ctorName = name
                return p
            end
            return makeProxy(name .. "." .. tostring(k))
        end })
    end
    env.Vector3 = newCtor("Vector3")
    env.Vector2 = newCtor("Vector2")
    env.CFrame = newCtor("CFrame")
    env.UDim2 = newCtor("UDim2")
    env.UDim2.fromScale = function(x, y)
        local v = genVar("udim2")
        emit(string.format('local %s = UDim2.fromScale(%s, %s)', v, serialize(x), serialize(y)))
        return makeDataProxy("UDim2", {x or 0, 0, y or 0, 0}, v)
    end
    env.UDim2.fromOffset = function(x, y)
        local v = genVar("udim2")
        emit(string.format('local %s = UDim2.fromOffset(%s, %s)', v, serialize(x), serialize(y)))
        return makeDataProxy("UDim2", {0, x or 0, 0, y or 0}, v)
    end
    env.UDim = newCtor("UDim")
    local function argsToList(...)
        local args = {...}
        local parts = {}
        for i = 1, select("#", ...) do
            table.insert(parts, serialize(args[i]))
        end
        return table.concat(parts, ", ")
    end
    local function colorCtor(ctorName)
        return function(...)
            local v = genVar("color")
            local args = {...}
            emit(string.format('local %s = Color3.%s(%s)', v, ctorName, argsToList(...)))
            local proxy = makeProxy(v)
            local mt = getmetatable(proxy)
            mt._ctorName = "Color3"
            mt._ctorArgs = args
            if ctorName == "fromRGB" then
                mt._ctorArgs = { (args[1] or 0)/255, (args[2] or 0)/255, (args[3] or 0)/255 }
            elseif ctorName == "fromHSV" then
                local h, s, val = args[1] or 0, args[2] or 0, args[3] or 0
                local r, g, b
                local i = math.floor(h * 6)
                local f = h * 6 - i
                local p = val * (1 - s)
                local q = val * (1 - f * s)
                local t = val * (1 - (1 - f) * s)
                i = i % 6
                if i == 0 then r, g, b = val, t, p
                elseif i == 1 then r, g, b = q, val, p
                elseif i == 2 then r, g, b = p, val, t
                elseif i == 3 then r, g, b = p, q, val
                elseif i == 4 then r, g, b = t, p, val
                elseif i == 5 then r, g, b = val, p, q
                end
                mt._ctorArgs = { r or 0, g or 0, b or 0 }
            end
            return proxy
        end
    end
    env.Color3 = setmetatable({
        new = colorCtor("new"),
        fromRGB = colorCtor("fromRGB"),
        fromHSV = colorCtor("fromHSV"),
        fromHex = function(hex)
            hex = tostring(hex):gsub("#", "")
            local r = tonumber(hex:sub(1, 2), 16) or 0
            local g = tonumber(hex:sub(3, 4), 16) or 0
            local b = tonumber(hex:sub(5, 6), 16) or 0
            local v = genVar("color")
            emit(string.format('local %s = Color3.fromHex("%s")', v, hex))
            local proxy = makeProxy(v)
            local mt = getmetatable(proxy)
            mt._ctorName = "Color3"
            mt._ctorArgs = { r/255, g/255, b/255 }
            return proxy
        end,
    }, { __index = function(_, k) return makeProxy("Color3." .. tostring(k)) end })
    env.Rect = newCtor("Rect")
    env.Ray = newCtor("Ray")
    env.Region3 = newCtor("Region3")
    env.Region3int16 = newCtor("Region3int16")
    env.Random = newCtor("Random")
    env.Axes = newCtor("Axes")
    env.Faces = newCtor("Faces")
    env.PathWaypoint = newCtor("PathWaypoint")
    env.FloatCurveKey = newCtor("FloatCurveKey")
    env.RotationCurveKey = newCtor("RotationCurveKey")
    env.ValueCurveKey = newCtor("ValueCurveKey")
    env.SecurityCapabilities = newCtor("SecurityCapabilities")
    env.Vector2int16 = newCtor("Vector2int16")
    env.Vector3int16 = newCtor("Vector3int16")
    env.CatalogSearchParams = newCtor("CatalogSearchParams")
    env.SharedTable = newCtor("SharedTable")
    env.PhysicalProperties = newCtor("PhysicalProperties")
    env.Font = newCtor("Font")
    env.TweenInfo = newCtor("TweenInfo")
    env.NumberRange = newCtor("NumberRange")
    env.NumberSequence = newCtor("NumberSequence")
    env.NumberSequenceKeypoint = newCtor("NumberSequenceKeypoint")
    env.ColorSequence = newCtor("ColorSequence")
    env.ColorSequenceKeypoint = newCtor("ColorSequenceKeypoint")
    env.BrickColor = newCtor("BrickColor")
    env.OverlapParams = newCtor("OverlapParams")
    env.RaycastParams = newCtor("RaycastParams")
    env.DateTime = setmetatable({
        now = function()
            local dt = makeProxy("DateTime")
            local mt = getmetatable(dt)
            mt._className = "DateTime"
            mt._storedValues["UnixTimestamp"] = os.time()
            mt._storedValues["UnixTimestampMillis"] = os.time() * 1000
            return dt
        end,
        fromUnixTimestamp = function(ts)
            local dt = makeProxy("DateTime")
            local mt = getmetatable(dt)
            mt._className = "DateTime"
            mt._storedValues["UnixTimestamp"] = ts
            mt._storedValues["UnixTimestampMillis"] = ts * 1000
            return dt
        end,
        fromUniversalTime = function(...)
            local dt = makeProxy("DateTime")
            local mt = getmetatable(dt)
            mt._className = "DateTime"
            mt._storedValues["UnixTimestamp"] = os.time()
            mt._storedValues["UnixTimestampMillis"] = os.time() * 1000
            return dt
        end,
        fromLocalTime = function(...)
            local dt = makeProxy("DateTime")
            local mt = getmetatable(dt)
            mt._className = "DateTime"
            mt._storedValues["UnixTimestamp"] = os.time()
            mt._storedValues["UnixTimestampMillis"] = os.time() * 1000
            return dt
        end,
    }, { __index = function(_, k) return makeProxy("DateTime." .. tostring(k)) end })
    env.NumberRange = newCtor("NumberRange")
    env.NumberSequence = newCtor("NumberSequence")
    env.NumberSequenceKeypoint = newCtor("NumberSequenceKeypoint")
    env.ColorSequence = newCtor("ColorSequence")
    env.ColorSequenceKeypoint = newCtor("ColorSequenceKeypoint")
    env.PhysicalProperties = newCtor("PhysicalProperties")
    env.TweenInfo = newCtor("TweenInfo")
    env.RaycastParams = newCtor("RaycastParams")
    env.OverlapParams = newCtor("OverlapParams")
    env.PathWaypoint = newCtor("PathWaypoint")
    env.Font = setmetatable({}, { __index = function(_, k) return makeProxy("Font." .. tostring(k)) end })
    env.buffer = setmetatable({
        create = function(n)
            if type(n) ~= "number" then n = 0 end
            if n < 0 then n = 0 end
            if n > 100000000 then n = 100000000 end
            return buffer.create(math.floor(n))
        end,
        fromstring = function(s)
            s = s or ""
            return buffer.fromstring(s)
        end,
        tostring = function(b)
            if type(b) == "string" then return b end
            local ok, r = pcall(buffer.tostring, b)
            if ok then return r end
            return ""
        end,
        len = function(b)
            if type(b) == "string" then return #b end
            local ok, r = pcall(buffer.len, b)
            if ok then return r end
            return 0
        end,
        copy = function(...) return buffer.copy(...) end,
        fill = function(...) return buffer.fill(...) end,
        tobits = function(b) return buffer.tobits(b) end,
        frombits = function(...) return buffer.frombits(...) end,
        readi8 = function(...) return buffer.readi8(...) end,
        readu8 = function(...) return buffer.readu8(...) end,
        readi16 = function(...) return buffer.readi16(...) end,
        readu16 = function(...) return buffer.readu16(...) end,
        readi32 = function(...) return buffer.readi32(...) end,
        readu32 = function(...) return buffer.readu32(...) end,
        readf32 = function(...) return buffer.readf32(...) end,
        readf64 = function(...) return buffer.readf64(...) end,
        writei8 = function(...) return buffer.writei8(...) end,
        writeu8 = function(...) return buffer.writeu8(...) end,
        writei16 = function(...) return buffer.writei16(...) end,
        writeu16 = function(...) return buffer.writeu16(...) end,
        writei32 = function(...) return buffer.writei32(...) end,
        writeu32 = function(...) return buffer.writeu32(...) end,
        writef32 = function(...) return buffer.writef32(...) end,
        writef64 = function(...) return buffer.writef64(...) end,
        readstring = function(...) return buffer.readstring(...) end,
        writestring = function(...) return buffer.writestring(...) end,
    }, {
        _serialName = "buffer",
        __index = function(_, k)
            if type(k) == "string" and buffer[k] then
                return buffer[k]
            end
            return function() return 0 end
        end,
        __tostring = function() return "table: 0x" .. string.format("%x", math.random(1048576, 1099511627776)) end,
    })
    env.Buffer = env.buffer

    local YIELD_BUDGET = 1000
    local yieldCount = 0
    local function yieldTick()
        yieldCount += 1
        if yieldCount > YIELD_BUDGET then
            error(BUDGET_ERROR, 0)
        end
    end
    _G._yieldTick = yieldTick
    local function runCallback(f, ...)
        if type(f) ~= "function" then return end
        local savedYieldCount = yieldCount
        yieldCount = 0
        local cbStart = os.clock()
        local savedDeadline = _G._wallDeadline
        if not savedDeadline then
            _G._wallDeadline = cbStart + 3
        end
        local cbOpStart = opCount
        local ok, err = pcall(f, ...)
        if os.clock() > (_G._wallDeadline or math.huge) then
            pcall(function() process.exit(0) end)
        end
        _G._wallDeadline = savedDeadline
        yieldCount = savedYieldCount
        if not ok and tostring(err):find(BUDGET_ERROR, 1, true) then
        end
    end
    local realClock = os.clock
    local realTask = task
    local taskTbl = {
        wait = function(time)
            local t = tonumber(time)
            if t and t > 0 then
                if t > 3 then t = 0.5 end
                pcall(realTask.wait, t)
                return t, 1
            end
            pcall(realTask.wait, 0.015)
            return 0.015, 1
        end,
        spawn = function(f, ...)
            local args = table.pack(...)
            return realTask.spawn(function() runCallback(f, table.unpack(args, 1, args.n)) end)
        end,
        delay = function(t, f)
            local tt = tonumber(t) or 0
            if tt > 3 then
                return nil
            end
            return realTask.delay(tt, function() runCallback(f) end)
        end,
        cancel = function(co) pcall(function() realTask.cancel(co) end) end,
        clock = function() return os.clock() end,
        defer = function(f, ...)
            local args = table.pack(...)
            return realTask.defer(function() runCallback(f, table.unpack(args, 1, args.n)) end)
        end,
        synchronize = function() end,
        desynchronize = function() end,
    }
    env.task = setmetatable(taskTbl, {
        __newindex = function() error("attempt to write to read-only library table", 2) end
    })
    env.wait = function(time)
        local t = tonumber(time)
        if t and t > 0 then
            if t > 3 then t = 0.5 end
            pcall(realTask.wait, t)
            return t, 1
        end
        pcall(realTask.wait, 0.015)
        return 0.015, 1
    end
    env.spawn = env.task.spawn
    env.delay = env.task.delay
    env.tick = function() return os.time() end
    env.time = function() return os.time() end
    env.elapsedTime = function() return os.clock() end
    env.elapsedtime = env.elapsedTime
    env.stats = function() return {} end
    env.hookfunction = function(target, replacement)
        if type(target) ~= "function" then error("invalid argument #1 to 'hookfunction'", 2) end
        if type(replacement) ~= "function" then error("invalid argument #2 to 'hookfunction'", 2) end
        local prevReplacement = hookReplacements[target]
        local prevOriginal = originalBehaviors[target]
        local original = prevOriginal or target
        hookTargets[target] = true
        hookReplacements[target] = replacement
        originalBehaviors[target] = original
        local wrappedOriginal = function(...)
            if hookReplacements[target] then
                return hookReplacements[target](...)
            end
            return original(...)
        end
        local toReturn = prevReplacement or wrappedOriginal
        if not prevReplacement then
            cclosureSet[toReturn] = true
        end
        return toReturn
    end
    knownCFunctions[env.hookfunction] = true
    env.checkcaller = function() return false end
    env.getrawmetatable = function(t) return getmetatable(t) end
    env.identifyexecutor = function() return "envlog", "1.0" end
    env.http_request = function() return { StatusCode = 200, Body = "", Success = true } end
    env.request = env.http_request
    env.setclipboard = function() end
    env.readfile = function() return "" end
    env.writefile = function() end
    env.isfile = function() return false end
    env.newcclosure = function(f)
        if type(f) ~= "function" then error("invalid argument #1 to 'newcclosure'", 2) end
        local wrapper = function(...)
            return f(...)
        end
        cclosureSet[wrapper] = true
        cloneSources[wrapper] = f
        return wrapper
    end
    env.iscclosure = function(f)
        if type(f) ~= "function" then return false end
        if cclosureSet[f] then return true end
        if knownCFunctions[f] then return true end
        local dw = getFunctionWhat(f)
        if dw == "C" then return true end
        return false
    end
    env.islclosure = function(f)
        if type(f) ~= "function" then return false end
        if cclosureSet[f] then return false end
        if knownCFunctions[f] then return false end
        local dw = getFunctionWhat(f)
        if dw == "C" then return false end
        return true
    end
    env.getgenv = function() return env end
    env.getrenv = function() return setmetatable({}, { __index = env }) end
    env.gethui = function() return env.game end
    env.gethwid = function() return "sandbox-hwid-12345" end
    env.getcustomasset = function() return "rbxasset://temp" end
    env.getinstances = function() return {} end
    env.getnilinstances = function() return {} end
    env.getscripts = function() return {} end
    env.getloadedmodules = function() return {} end
    local runningScriptsList = { "Animate", "HealthScript", "SoundPlus", "RbxCharacter", "ControlScript", "CameraScript" }
    env.getrunningscripts = function()
        local result = {}
        for _, name in ipairs(runningScriptsList) do
            local proxy = makeProxy(name)
            local mt = getmetatable(proxy)
            mt._isRunningScript = true
            table.insert(result, proxy)
        end
        return result
    end
    env.getcallbackvalue = function(f) return f end
    env.isluau = function() return true end
    env.isourclosure = function() return false end
    env.isexecutorclosure = function() return false end
    knownCFunctions[env.print] = true
    knownCFunctions[env.warn] = true
    knownCFunctions[env.pcall] = true
    knownCFunctions[env.xpcall] = true
    knownCFunctions[env.error] = true
    knownCFunctions[env.assert] = true
    knownCFunctions[env.tonumber] = true
    knownCFunctions[env.tostring] = true
    knownCFunctions[env.type] = true
    knownCFunctions[env.typeof] = true
    knownCFunctions[env.select] = true
    knownCFunctions[env.pairs] = true
    knownCFunctions[env.ipairs] = true
    knownCFunctions[env.next] = true
    knownCFunctions[env.rawget] = true
    knownCFunctions[env.rawset] = true
    knownCFunctions[env.rawequal] = true
    knownCFunctions[env.rawlen] = true
    knownCFunctions[env.setmetatable] = true
    knownCFunctions[env.getmetatable] = true
    knownCFunctions[env.unpack] = true
    knownCFunctions[env.getfenv] = true
    knownCFunctions[env.setfenv] = true
    knownCFunctions[env.loadstring] = true
    knownCFunctions[env.load] = true
    knownCFunctions[env.ypcall] = true
    knownCFunctions[env.settings] = true
    knownCFunctions[env.wait] = true
    knownCFunctions[env.spawn] = true
    knownCFunctions[env.delay] = true
    knownCFunctions[env.tick] = true
    knownCFunctions[env.time] = true
    knownCFunctions[env.elapsedTime] = true
    knownCFunctions[env.version] = true
    knownCFunctions[env.isluau] = true
    knownCFunctions[env.iscclosure] = true
    knownCFunctions[env.islclosure] = true
    knownCFunctions[env.newcclosure] = true
    env.getscriptbytecode = function(script)
        if script == nil then error("invalid argument to getscriptbytecode", 2) end
        if type(script) == "table" then
            local m = getmetatable(script)
            if m and m._isProxy then
                local nm = m._name or ""
                if nm:find("Animate") then return "bytecode" end
                if nm:find("LocalScript") or nm:find("inst") then return nil end
                return nil
            end
        end
        error("invalid argument to getscriptbytecode", 2)
    end
    env.getscriptclosure = function(script)
        return function() end
    end
    env.decompile = function(script)
        if type(script) == "table" then
            local m = getmetatable(script)
            if m and m._isProxy then
                local nm = m._name or ""
                if nm:find("LocalScript") or nm:find("inst") then return "Bytecode is empty" end
            end
        end
        return "decompile failed"
    end
    env.getscripthash = function() return "" end
    env.clonefunction = function(f)
        if type(f) ~= "function" then error("invalid argument #1 to 'clonefunction'", 2) end
        local source = cloneSources[f] or f
        local originalBehavior = originalBehaviors[f] or source
        local wrapper = function(...)
            return originalBehavior(...)
        end
        cloneSources[wrapper] = source
        cloneWrappers[wrapper] = f
        if cclosureSet[f] then cclosureSet[wrapper] = true end
        return wrapper
    end
    env.cloneref = function(ref) return ref end
    env.compareinstances = function(a, b) return a == b end
    env.setclipboard = function() end
    env.getclipboard = function() return "" end
    env.readfile = function() return "" end
    env.writefile = function() end
    env.appendfile = function() end
    env.makefolder = function() end
    env.delfile = function() end
    env.delfolder = function() end
    env.isfile = function() return false end
    env.isfolder = function() return false end
    env.listfiles = function() return {} end
    env.loadfile = function() return nil end
    env.gethiddenproperty = function() return nil, false end
    env.sethiddenproperty = function() return false end
    env.getscriptable = function() return true end
    env.setscriptable = function() return true end
    env.getconnections = function() return {} end
    env.getsenv = function() return env end
    env.setthreadidentity = function(id) if id < 0 then error("invalid identity", 2) end end
    env.getthreadidentity = function() return 2 end
    env.getidentity = function() return 2 end
    env.setidentity = function(id) if id < 0 then error("invalid identity", 2) end end
    env.fireclickdetector = function() end
    env.fireproximityprompt = function() end
    env.hookmetamethod = function() return function() end end
    env.isrbxactive = function() return true end
    env.lz4compress = function(s) return s end
    env.lz4decompress = function(s) return s end
    env.getnamecallmethod = function() return "" end
    env.setnamecallmethod = function() end
    env.setrawmetatable = function(t, mt) return setmetatable(t, mt) end
    env.isreadonly = function(t)
        if type(t) ~= "table" then return false end
        return readonlyTables[t] == true or frozenTables[t] == true
    end
    env.setreadonly = function(t, flag)
        if type(t) ~= "table" then return end
        if flag == false or flag == nil then
            readonlyTables[t] = nil
        else
            readonlyTables[t] = true
            local snapshot = {}
            for k, v in pairs(t) do snapshot[k] = v end
            for k in pairs(t) do rawset(t, k, nil) end
            local guardMt = {
                __index = snapshot,
                __newindex = function(tt, k, v)
                    error("attempt to modify a readonly table", 2)
                end,
                _isReadonlyGuard = true,
                _isReadonlyLocked = true,
            }
            realSetmetatable(t, guardMt)
        end
    end
    env.getrenderproperty = function() return nil end
    env.setrenderproperty = function() end
    env.cleardrawcache = function() end
    env.toast = function() end
    env.messagebox = function() return 1 end
    env.zstdcompress = function(s) return s end
    env.zstddecompress = function(s) return s end
    env.qrcode = function() return "" end
    env.newproxy = function(arg)
        local proxy = newproxy(arg)
        if arg == true then
            local m = getmetatable(proxy)
            if m then
                m._isUserdataProxy = true
            end
        end
        return proxy
    end
    env.getgc = function() return {} end
    env.gcinfo = function() return collectgarbage("count") end
    env.collectgarbage = function(opt)
        if opt == "count" then
            return collectgarbage("count")
        elseif opt == "step" then
            return collectgarbage("step")
        elseif opt == "collect" then
            return collectgarbage("collect")
        elseif opt == "stop" then
            return collectgarbage("stop")
        elseif opt == "restart" then
            return collectgarbage("restart")
        end
        return collectgarbage(opt or "collect")
    end
    env.require = function(modname)
        if type(modname) == "table" and getmetatable(modname) and getmetatable(modname)._className then
            return modname
        end
        error("attempt to call a nil value", 2)
    end
    knownCFunctions[env.require] = true
    env.shared = setmetatable({}, {
        _serialName = "shared",
        __index = function(_, k) return env[k] end,
        __newindex = function(t, k, v) env[k] = v; rawset(t, k, v) end,
        __tostring = function() return "table: 0x" .. string.format("%x", math.random(1048576, 1099511627776)) end,
        __pairs = function() return pairs(env) end,
        __len = function() return 0 end,
    })
    env.dofile = nil
    env.package = nil

    local blockedGlobals = {
        require = true,
        dofile = true,
        package = true,
        loadfile = true,
        io = true,
    }
    setmetatable(env, {
        __index = function(t, k)
            if blockedGlobals[k] then return nil end
            if k == "iscclosure" then return function(f) return type(f) == "function" end end
            if k == "islclosure" then return function(f) return false end end
            if k == "newcclosure" then return function(f) return f end end
            if k == "hookfunction" then return function(t, r) return t end end
            if k == "clonefunction" then return function(f) return f end end
            if k == "cloneref" then return function(r) return r end end
            if k == "getrawmetatable" then return function(t) return getmetatable(t) end end
            if k == "setrawmetatable" then return function(t, mt) return setmetatable(t, mt) end end
            if k == "getgenv" then return function() return env end end
            if k == "getrenv" then return function() return env end end
            if k == "getregistry" then return function() return {} end end
            if k == "getidentity" then return function() return 2 end end
            if k == "identifyexecutor" then return function() return "envlog", "1.0" end end
            if k == "isluau" then return function() return true end end
            if k == "checkcaller" then return function() return false end end
            if k == "getinstances" then return function() return {} end end
            if k == "getnilinstances" then return function() return {} end end
            if k == "getscripts" then return function() return {} end end
            if k == "getloadedmodules" then return function() return {} end end
            if k == "getrunningscripts" then return function() return {} end end
            if k == "Drawing" then return makeProxy("Drawing") end
            if k == "crypt" then return makeProxy("crypt") end
            if k == "base64" then return { encode = function(s) return s end, decode = function(s) return s end } end
            if k == "http_request" then return function() return {StatusCode=200,Body="",Success=true} end end
            if k == "request" then return function() return {StatusCode=200,Body="",Success=true} end end
            if k == "setclipboard" then return function() end end
            if k == "readfile" then return function() return "" end end
            if k == "writefile" then return function() end end
            if k == "isfile" then return function() return false end end
            if k == "isfolder" then return function() return false end end
            if k == "getnamecallmethod" then return function() return "" end end
            if k == "hookmetamethod" then return function() return function() end end end
            if k == "newproxy" then return function(a) return newproxy(a) end end
            if k == "setreadonly" then return function() end end
            if k == "isreadonly" then return function() return false end end
            if k == "fireclickdetector" then return function() end end
            if k == "fireproximityprompt" then return function() end end
            if k == "getscriptbytecode" then return function() return "" end end
            if k == "decompile" then return function() return "" end end
            if k == "getscripthash" then return function() return "" end end
            if k == "gethui" then return function() return env.game end end
            if k == "gethwid" then return function() return "sandbox" end end
            if k == "getcustomasset" then return function() return "rbxasset://temp" end end
            if k == "syn" then return setmetatable({request=function() return {StatusCode=200,Body="",Success=true} end}, {__index=function() return function() return nil end end}) end
            return nil
        end,
        __newindex = function(t, k, v)
            rawset(t, k, v)
        end,
    })
    env.Drawing = setmetatable({}, { __index = function(_, k) return makeProxy("Drawing." .. tostring(k)) end })
    env.crypt = setmetatable({}, { __index = function(_, k) return function() return makeProxy("crypt." .. tostring(k)) end end })
    env.base64 = { encode = function(s) return s or "" end, decode = function(s) return s or "" end }
    env.syn = setmetatable({
        request = function() return { StatusCode = 200, Body = "", Success = true } end,
        queue = function() return {} end,
        crypt = env.crypt,
        base64 = env.base64,
        aux = setmetatable({}, { __index = function(_, k) return function() return nil end end }),
    }, { __index = function(_, k) return function() return nil end end })
    env.getregistry = function() return {} end
    env.getidentity = function() return 2 end
    env.getthread = function() return coroutine.running() end
    env.getstack = function() return {} end
    env.getparams = function() return {} end
    env.isourclosure = function() return true end
    env.isexecutorclosure = function() return true end
    env.isfunction = function(f) return type(f) == "function" end
    env.Path2DControlPoint = makeProxy("Path2DControlPoint")
    env.CrosshairImage = makeProxy("CrosshairImage")
    env.IB_CRASH = false
    env.DControlPoint = makeProxy("DControlPoint")
    env.process = setmetatable({
        exit = function() emit("-- process.exit() called") end,
        args = {}, env = {}, cwd = function() return "/" end, os = "linux", pid = 1,
    }, { __index = function(_, k) return makeProxy("process." .. tostring(k)) end })

    return env
end

local function isGenericVar(name: string): boolean
    return name:match("^v%d+$") ~= nil or name:match("^color%d+$") ~= nil or name:match("^inst%d+$") ~= nil
end

local function deadCodeElimination()
    local result = {}
    for _, line in ipairs(lines) do
        local v = string.match(line, "^local ([%a_][%w_]*%d+) = (.+)$")
        if v and isGenericVar(v) and (usedVars[v] or 0) == 0 then
            local expr = string.match(line, "^local [%a_][%w_]*%d+ = (.+)$")
            if not expr:match("^Color3%.") and not expr:match("^Instance%.new") and not expr:match("^Vector3%.") then
                table.insert(result, expr)
            end
        else
            table.insert(result, line)
        end
    end
    lines = result
end

local function inlineVars()
    if not Settings.inline then return end
    local maxIter = 100
    while maxIter > 0 do
        maxIter -= 1

        local useCount = {}
        local defIdx = {}
        local defExpr = {}
        for i, line in ipairs(lines) do
            local v, expr = string.match(line, "^local ([%a_][%w_]*%d+) = (.+)$")
            if v and isGenericVar(v) then
                defIdx[v] = i
                defExpr[v] = expr
            end
            for var in string.gmatch(line, "[%a_][%w_]*%d+") do
                if var ~= v then
                    useCount[var] = (useCount[var] or 0) + 1
                end
            end
        end

        local bestVar = nil
        local bestIdx = 0
        for v, idx in pairs(defIdx) do
            if (useCount[v] or 0) == 1 and idx > bestIdx then
                local expr = defExpr[v]
                if #expr < 200 and not expr:match("^function") and not expr:match("^%{") then
                    bestVar = v
                    bestIdx = idx
                end
            end
        end

        if not bestVar then break end

        local expr = defExpr[bestVar]
        local pattern = "%f[%w_]" .. bestVar .. "%f[^%w_]"
        local newLines = {}
        for i, line in ipairs(lines) do
            if i == bestIdx then
            else
                table.insert(newLines, (string.gsub(line, pattern, expr)))
            end
        end
        lines = newLines
    end
end

local function beautify()
    if not Settings.beautify then return end
    local result = {}
    local lastLine = nil
    local lastGroup = nil
    for _, line in ipairs(lines) do
        if line ~= lastLine then
            local group = nil
            if line:match(":GetService%(") then group = "service"
            elseif line:match(":Tab%(") then group = "tab"
            elseif line:match(":Section%(") then group = "section"
            elseif line:match(":Connect%(") then group = "connect"
            end
            if group and group ~= lastGroup and #result > 0 then
                table.insert(result, "")
            end
            table.insert(result, line)
            lastLine = line
            if group then lastGroup = group end
        end
    end
    lines = result
end

local DARKLUA_BIN = (process.env.DARKLUA_BIN or "darklua") :: string
local SANDBOX_PRELUDE = table.concat({
    "local io = nil",
    "local dofile = nil",
    "",
}, "\n")

local function isValidIdent(s: string): boolean
    return s ~= "" and s:match("^[%a_][%w_]*$") ~= nil
end

local function splitTableEntries(body: string): { string }
    local entries: { string } = {}
    local depth = 0
    local inStr = false
    local strDelim = ""
    local inLong = false
    local longLevel = 0
    local startIdx = 1
    local i = 1
    while i <= #body do
        local ch = body:sub(i, i)
        local two = body:sub(i, i + 1)
        if inLong then
            local close = "]" .. string.rep("=", longLevel) .. "]"
            if body:sub(i, i + #close - 1) == close then
                inLong = false
                i += #close
                continue
            end
            i += 1
            continue
        end
        if inStr then
            if ch == "\\" then
                i += 2
                continue
            end
            if ch == strDelim then
                inStr = false
            end
            i += 1
            continue
        end
        if two == "[[" or (two == "[" and body:match("^%[=%[", i)) then
            local m = body:match("^%[(=*)%[", i)
            if m then
                inLong = true
                longLevel = #m
                i += 2 + #m
                continue
            end
        end
        if ch == '"' or ch == "'" then
            inStr = true
            strDelim = ch
            i += 1
            continue
        end
        if ch == "{" or ch == "(" or ch == "[" then
            depth += 1
        elseif ch == "}" or ch == ")" or ch == "]" then
            depth -= 1
        elseif ch == "," and depth == 0 then
            local entry = body:sub(startIdx, i - 1)
            entry = entry:gsub("^%s+", ""):gsub("%s+$", "")
            if entry ~= "" then table.insert(entries, entry) end
            startIdx = i + 1
        end
        i += 1
    end
    local last = body:sub(startIdx, #body)
    last = last:gsub("^%s+", ""):gsub("%s+$", "")
    if last ~= "" then table.insert(entries, last) end
    return entries
end

local function findTableBody(s: string, start: number): (number?, number?)
    if s:sub(start, start) ~= "{" then return nil end
    local depth = 1
    local i = start + 1
    local inStr = false
    local strDelim = ""
    local inLong = false
    local longLevel = 0
    while i <= #s do
        local ch = s:sub(i, i)
        if inLong then
            local close = "]" .. string.rep("=", longLevel) .. "]"
            if s:sub(i, i + #close - 1) == close then
                inLong = false
                i += #close
                continue
            end
            i += 1
            continue
        end
        if inStr then
            if ch == "\\" then i += 2; continue end
            if ch == strDelim then inStr = false end
            i += 1
            continue
        end
        local m = s:match("^%[(=*)%[", i)
        if m then
            inLong = true
            longLevel = #m
            i += 2 + #m
            continue
        end
        if ch == '"' or ch == "'" then
            inStr = true
            strDelim = ch
            i += 1
            continue
        end
        if ch == "{" then
            depth += 1
        elseif ch == "}" then
            depth -= 1
            if depth == 0 then return start + 1, i - 1 end
        end
        i += 1
    end
    return nil
end

local function expandTable(body: string, baseIndent: string, parentIndent: string): string
    local entries = splitTableEntries(body)
    if #entries <= 1 then
        if #entries == 0 then
            return "{}"
        end
        return "{ " .. entries[1] .. " }"
    end

    local lines: { string } = {}
    for idx, entry in ipairs(entries) do
        local expanded = entry
        expanded = expanded:gsub("%s*,%s*$", "")
        if idx == #entries then
            table.insert(lines, baseIndent .. expanded)
        else
            table.insert(lines, baseIndent .. expanded .. ",")
        end
    end
    return "{\n" .. table.concat(lines, "\n") .. "\n" .. parentIndent .. "}"
end

local function findEmptyFunction(s: string, start: number): (number?, number?)
    local i = start
    local inStr = false
    local strDelim = ""
    local inLong = false
    local longLevel = 0
    while i <= #s do
        local ch = s:sub(i, i)
        if inLong then
            local close = "]" .. string.rep("=", longLevel) .. "]"
            if s:sub(i, i + #close - 1) == close then
                inLong = false
                i += #close
                continue
            end
            i += 1
            continue
        end
        if inStr then
            if ch == "\\" then i += 2; continue end
            if ch == strDelim then inStr = false end
            i += 1
            continue
        end
        local m = s:match("^%[(=*)%[", i)
        if m then
            inLong = true
            longLevel = #m
            i += 2 + #m
            continue
        end
        if ch == '"' or ch == "'" then
            inStr = true
            strDelim = ch
            i += 1
            continue
        end
        local fStart = s:match("^function%s*%(", i)
        if fStart then
            local parenStart = s:find("(", i, true)
            if parenStart then
                local depth = 1
                local j = parenStart + 1
                while j <= #s and depth > 0 do
                    local c = s:sub(j, j)
                    if c == "(" then depth += 1
                    elseif c == ")" then depth -= 1 end
                    j += 1
                end
                local k = j
                while k <= #s and (s:sub(k, k):match("%s")) do k += 1 end
                if s:sub(k, k + 2) == "end" then
                    local after = s:sub(k + 3, k + 3)
                    if after == "" or not after:match("[%w_]") then
                        return i, k + 2
                    end
                end
            end
        end
        i += 1
    end
    return nil
end

local function leadingIndent(line: string): string
    return line:match("^([\t ]*)") or ""
end

local function beautifyLine(line: string): { string }
    local indent = leadingIndent(line)
    local body = line:sub(#indent + 1)

    local function expandAllTables(s: string): string
        local result = s
        local progress = true
        local guard = 0
        while progress and guard < 50 do
            guard += 1
            progress = false
            local pos = 1
            while pos <= #result do
                local bs = string.find(result, "{", pos, true)
                if not bs then break end
                local bodyStart, bodyEnd = findTableBody(result, bs)
                if bodyStart and bodyEnd then
                    local innerBody = result:sub(bodyStart, bodyEnd)
                    if not innerBody:find("\n", 1, true) then
                        local entries = splitTableEntries(innerBody)
                        if #entries > 1 then
                            local innerExpanded = expandTable(innerBody, indent .. "\t", indent)
                            local before = result:sub(1, bs - 1)
                            local after = result:sub(bodyEnd + 2)
                            result = before .. innerExpanded .. after
                            progress = true
                            pos = #before + #innerExpanded + 1
                            continue
                        end
                    end
                    pos = bs + 1
                else
                    pos = bs + 1
                end
            end
        end
        return result
    end

    body = expandAllTables(body)

    local function expandAllEmptyFunctions(s: string): string
        local result = s
        local guard = 0
        while guard < 50 do
            guard += 1
            local fs, fe = findEmptyFunction(result, 1)
            if not fs then break end
            local fnText = result:sub(fs, fe)
            local params = fnText:match("^function(%s*%b())")
            local replacement = "function" .. (params or "()") .. "\n" .. indent .. "end"
            result = result:sub(1, fs - 1) .. replacement .. result:sub(fe + 1)
        end
        return result
    end

    body = expandAllEmptyFunctions(body)

    local outLines: { string } = {}
    for line2 in body:gmatch("[^\n]*") do
        if line2 ~= "" then
            if #outLines == 0 and line2:sub(1, 1) ~= "\t" and line2:sub(1, 1) ~= " " then
                table.insert(outLines, indent .. line2)
            else
                table.insert(outLines, line2)
            end
        end
    end
    if #outLines == 0 then
        table.insert(outLines, indent .. body)
    elseif outLines[1]:sub(1, #indent) ~= indent and outLines[1]:sub(1, 1) ~= "\t" and outLines[1]:sub(1, 1) ~= " " then
        outLines[1] = indent .. outLines[1]
    end
    return outLines
end

local function iterLines(s: string): () -> string?
    local pos = 1
    local len = #s
    return function(): string?
        if pos > len then return nil end
        local eol = s:find("\n", pos, true) or (len + 1)
        local line = s:sub(pos, eol - 1)
        pos = eol + 1
        return line
    end
end

local function customBeautify(source: string): string
    if not Settings.beautify then return source end
    local output: { string } = {}
    for line in iterLines(source) do
        if line == "" then
            table.insert(output, "")
        else
            local beautified = beautifyLine(line)
            for _, l in ipairs(beautified) do
                table.insert(output, l)
            end
        end
    end
    local collapsed: { string } = {}
    local blankRun = 0
    for _, l in ipairs(output) do
        if l == "" then
            blankRun += 1
            if blankRun <= 1 then table.insert(collapsed, l) end
        else
            blankRun = 0
            table.insert(collapsed, l)
        end
    end
    while #collapsed > 0 and collapsed[#collapsed] == "" do
        table.remove(collapsed, #collapsed)
    end
    return table.concat(collapsed, "\n")
end

local function darkluaBeautify(source: string): string
    return customBeautify(source)
end

local function dump(source: string): string
    lines = {}
    varCount = 0
    usedVars = {}
    for k in pairs(propertyChangeCallbacks) do propertyChangeCallbacks[k] = nil end
    for i = #eventConnections, 1, -1 do eventConnections[i] = nil end
    for k in pairs(instanceTags) do instanceTags[k] = nil end
    for k in pairs(serviceCache) do serviceCache[k] = nil end
    for k in pairs(destroyedInstances) do destroyedInstances[k] = nil end
    for k in pairs(memStorage) do memStorage[k] = nil end
    for k in pairs(parentChildMap) do parentChildMap[k] = nil end
    awakePartsCount = 0
    for k in pairs(unanchoredParts) do unanchoredParts[k] = nil end
    for k in pairs(frozenTables) do frozenTables[k] = nil end
    for k in pairs(readonlyTables) do readonlyTables[k] = nil end
    for k in pairs(functionAddrMap) do functionAddrMap[k] = nil end
    emit("-- EnvLog output")
    emit("")
    local env = createEnv()

    local fn
    local loadOk, loadErr = pcall(function()
        local compiled = luau.compile(SANDBOX_PRELUDE .. source, { optimizationLevel = 2 })
        fn = luau.load(compiled, { debugName = "envlog", environment = env })
    end)
    if not loadOk or not fn then
        emit(string.format("-- Load error: %s", tostring(loadErr):sub(1, 200)))
        return table.concat(lines, "\n")
    end

    local INSN_BUDGET = 80000000
    local insnCount = 0
    local timedOut = false
    local wallLimit = tonumber(Settings.timeout) or 60
    if wallLimit > 5 then wallLimit = 5 end
    local wallStart = os.clock()
    _G._wallDeadline = wallStart + wallLimit

    local watchdogCo = task.spawn(function()
        while true do
            task.wait(0.5)
            if os.clock() > (_G._wallDeadline or math.huge) then
                pcall(function() process.exit(0) end)
                return
            end
            if not _G._wallDeadline then return end
        end
    end)

    local ok, err = pcall(fn)
    _G._wallDeadline = nil
    pcall(function() task.cancel(watchdogCo) end)
    if not ok then
        local errStr = tostring(err)
        if not errStr:find(BUDGET_ERROR, 1, true) then
            emit(string.format("-- Runtime error: %s", errStr:sub(1, 300)))
        else
            emit(string.format("-- Budget reached after %d instructions / %.2fs", insnCount, os.clock() - wallStart))
        end
    end

    inlineVars()
    deadCodeElimination()
    beautify()
    local raw = table.concat(lines, "\n")
    return darkluaBeautify(raw)
end

if Settings.ipt then
    local ok, err = pcall(function()
        if not fs.isFile(Settings.ipt) then
            error("File not found: " .. Settings.ipt)
        end
    end)
    if not ok then
        stdio.write("Error: " .. tostring(err) .. "\n")
        process.exit(1)
    end
    local source = fs.readFile(Settings.ipt)
    local result = dump(source)
    fs.writeFile(Settings.out, result)
    stdio.write(string.format("Done! Output: %s (%d bytes, %d lines)\n", Settings.out, #result, #lines))
    process.exit(0)
end

while true do
    local input = stdio.readLine()
    if not input or input == "" then break end
    local decoded = serde.decode("json", input)
    local result = dump(decoded.script)
    stdio.write(result)
    stdio.write("\n---END---\n")
end
