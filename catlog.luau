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

local function loadApiDump()
    local raw = fs.readFile(API_DUMP_PATH)
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
    error("Failed to load API dump from " .. API_DUMP_PATH .. ": " .. tostring(apiLoadErr))
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
local OP_BUDGET = 5000000
local BUDGET_ERROR = "__OP_BUDGET_EXCEEDED__"

local function emit(text: string)
    table.insert(lines, text)
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
end

local function isProxy(v: any): boolean
    return type(v) == "table" and getmetatable(v) ~= nil and getmetatable(v)._isProxy == true
end

local function proxyName(v: any): string
    if isProxy(v) then return getmetatable(v)._name or "proxy" end
    return "nil"
end

local function proxyParent(v: any): any?
    if isProxy(v) then return getmetatable(v)._parent end
    return nil
end

local function proxyField(v: any): string?
    if isProxy(v) then return getmetatable(v)._fieldName end
    return nil
end

local function markUsed(v: any)
    if not isProxy(v) then return end
    local mt = getmetatable(v)
    usedVars[mt._name] = true
    if mt._parent then
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
            markUsed(value)
            return m._name
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
    local numericPseudoProps = {
        Magnitude = true, X = true, Y = true, Z = true,
        W = true, Width = true, Height = true, Depth = true,
        Value = true, Alpha = true, Beta = true,
        StudsOffset = true, Radians = true,
        UserId = true, AccountAge = true, AccountIdReplicate = true,
        Health = true, MaxHealth = true, WalkSpeed = true, JumpPower = true,
        JumpHeight = true, HipHeight = true,
        CameraMinZoomDistance = true, CameraMaxZoomDistance = true,
        Volume = true, Pitch = true, TimeLength = true, TimePosition = true,
        VolumeAlt = true,
        Brightness = true, FogEnd = true, FogStart = true,
        Transparency = true, Reflectance = true, Rotation = true,
        BorderSizePixel = true, ZIndex = true, LayoutOrder = true,
        TextSize = true, TextTransparency = true, TextStrokeTransparency = true,
        BackgroundTransparency = true,
        FieldOfView = true, HeadScale = true,
        ClockTime = true, GeographicLatitude = true,
        ExposureCompensation = true,
        Gravity = true, FallSpeed = true,
        MaxForce = true, Force = true, Torque = true,
        Period = true, Amplitude = true,
        OffsetAngle = true, Angle = true,
        FormFactor = true, Shape = true,
        TopParamA = true, TopParamB = true, BottomParamA = true, BottomParamB = true,
        LeftParamA = true, LeftParamB = true, RightParamA = true, RightParamB = true,
        FrontParamA = true, FrontParamB = true, BackParamA = true, BackParamB = true,
        Friction = true, Elasticity = true, ElasticityWeight = true, FrictionWeight = true,
        Mass = true, MaxSlopeAngle = true,
        MaxThrust = true, MaxSpeed = true, ThrustSpeed = true,
        TargetOffset = true,
        HipHeightScales = true, WalkSpeedScales = true,
        CameraMinZoomDistance = true,
        FallenPartsDestroyHeight = true, NetworkOwnershipAutoOffset = true,
        DeleteOnFallenDestroy = true,
        Absent = true,
        WalkSpeedScale = true, WalkDirection = true,
        DistributedGameTime = true,
        Intensity = true, Brightness = true,
        Threshold = true, BlurSize = true,
        MaxBlurSize = true, Radius = true,
    }
    mt.__index = function(t, k)
        tick()
        local ks = tostring(k)
        if ks == "Parent" and not setKeys[ks] then
            return nil
        end
        if setKeys[ks] then
            return storedValues[ks]
        end
        if ks == "Parent" and destroyedInstances[name] then
            return nil
        end
        if mt._className == "DataModel" and isApiServiceClass(ks) and serviceCache[ks] then
            return serviceCache[ks]
        end
        if mt._className == "Players" and ks == "LocalPlayer" then
            if not children[ks] then
                local player = makeProxy("LocalPlayer")
                local pmt = getmetatable(player)
                pmt._className = "Player"
                pmt._storedValues["ClassName"] = "Player"
                pmt._setKeys["ClassName"] = true
                pmt._storedValues["UserId"] = 0
                pmt._setKeys["UserId"] = true
                pmt._storedValues["Character"] = nil
                pmt._setKeys["Character"] = true
                children[ks] = player
            end
            return children[ks]
        end
        if mt._className == "Workspace" and ks == "CurrentCamera" then
            if not children[ks] then
                local cam = makeProxy("CurrentCamera")
                local cmt = getmetatable(cam)
                cmt._className = "Camera"
                cmt._storedValues["ClassName"] = "Camera"
                cmt._setKeys["ClassName"] = true
                children[ks] = cam
            end
            return children[ks]
        end
        if ks == "ClassName" and mt._className then
            return mt._className
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
        if mt._ctorArgs and (ks == "X" or ks == "Y" or ks == "Z" or ks == "W") then
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
            local scale = mt._ctorArgs[idx*2-1] or 0
            local offset = mt._ctorArgs[idx*2] or 0
            return makeProxy(name .. "." .. ks)
        end
        if mt._ctorName == "UDim" and (ks == "Scale" or ks == "Offset") then
            local idx = ({ Scale = 1, Offset = 2 })[ks]
            local val = mt._ctorArgs[idx]
            if type(val) == "number" then return val end
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

        if not children[ks] then
            local child = makeProxy(name .. "." .. ks)
            local cmt = getmetatable(child)
            cmt._parent = t
            cmt._fieldName = ks
            children[ks] = child
        end
        return children[ks]
    end
    local positiveNumberProps = {
        FieldOfView = true, WalkSpeed = true, JumpPower = true,
        MaxHealth = true, Health = true, TextSize = true,
        Volume = true, Brightness = true, Gravity = true,
        CameraMinZoomDistance = true, CameraMaxZoomDistance = true,
        MaxForce = true, Force = true, Torque = true,
        MaxSpeed = true, MaxThrust = true,
    }
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
        end
        if ks == "AssemblyLinearVelocity" and isProxy(v) then
            local velMt = getmetatable(v)
            if velMt and velMt._ctorArgs then
                local vx = velMt._ctorArgs[1] or 0
                storedValues["Position"] = makeProxy(name .. ".Position")
                local posMt = getmetatable(storedValues["Position"])
                posMt._ctorArgs = { vx * 0.1, 0, 0 }
                posMt._ctorName = "Vector3"
            end
        end
        if ks == "Anchored" and v == false and storedValues["Position"] == nil then
            storedValues["Position"] = makeProxy(name .. ".Position")
            local posMt = getmetatable(storedValues["Position"])
            posMt._ctorArgs = { 0, -500, 0 }
            posMt._ctorName = "Vector3"
            storedValues["Parent"] = nil
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
            serviceCache[serviceName] = serviceProxy
            emit(string.format('local %s = %s:GetService(%s)', serviceName, parentName, serialize(firstArg)))
            return serviceProxy
        end

        if isMethod and fieldName == "GetPropertyChangedSignal" and parent and type(firstArg) == "string" then
            local parentName = proxyName(parent)
            local parentMt = getmetatable(parent)
            local cls = parentMt and parentMt._className or ""
            local memberInfo = resolveApiMember(cls, firstArg)
            if not isPropertyMember(memberInfo) then
                emit(string.format('local %s = %s:GetPropertyChangedSignal(%s)', retName, parentName, serialize(firstArg)))
                error("GetPropertyChangedSignal: '" .. firstArg .. "' is not a valid property", 0)
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
            emit(string.format('%s()', callExpr))
            return makeProxy(retName)
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
            return makeProxy(retName)
        end

        if isMethod and fieldName == "GetMemStats" and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:GetMemStats()', retName, parentName))
            return { cpuLoad = 0, gpuLoad = 0, ram = 0, vram = 0 }
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
            end
            return nil
        end

        if isMethod and (fieldName == "FindFirstDescendant" or fieldName == "FindFirstChildWhichIsA" or fieldName == "FindFirstChildOfClass") and parent then
            local parentName = proxyName(parent)
            emit(string.format('local %s = %s:%s(%s)', retName, parentName, fieldName, table.concat(parts, ", ")))
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
            return string.format("{%08x-%04x-%04x-%04x-%012x}", guidCounter, guidCounter, guidCounter, guidCounter, guidCounter)
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
            emit(string.format('local %s = %s:%s(%s)', retName, parentName, fieldName, table.concat(parts, ", ")))
            return { _data = "compressed", _size = 6 }
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
            return {}
        end

        if isMethod and fieldName == "GetDescendants" and parent then
            local parentName = proxyName(parent)
            emit(string.format('%s:GetDescendants()', parentName))
            return {}
        end

        if isMethod and fieldName == "GetPlayers" and parent then
            local parentName = proxyName(parent)
            emit(string.format('%s:GetPlayers()', parentName))
            return {}
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
    mt.__iter = function(t)
        return function() return nil end, nil, 0
    end
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
        local proxy = makeProxy(retName)
        local pmt = getmetatable(proxy)
        pmt._ctorName = "Vector3"
        pmt._ctorArgs = { x, y, z }
        return proxy
    end
    local function getVector3Args(v)
        if isProxy(v) then
            local m = getmetatable(v)
            if m and m._ctorName == "Vector3" and m._ctorArgs then
                return m._ctorArgs[1] or 0, m._ctorArgs[2] or 0, m._ctorArgs[3] or 0
            end
        end
        return nil
    end
    mt.__add = function(a, b)
        local sa = isProxy(a) and proxyName(a) or serialize(a)
        local sb = isProxy(b) and proxyName(b) or serialize(b)
        markUsed(a); markUsed(b)
        local ax, ay, az = getVector3Args(a)
        local bx, by, bz = getVector3Args(b)
        if ax and bx then
            return makeVector3FromArgs(ax + bx, ay + by, az + bz)
        end
        local retName = genVar("v")
        emit(string.format('local %s = %s + %s', retName, sa, sb))
        return makeProxy(retName)
    end
    mt.__sub = function(a, b)
        local sa = isProxy(a) and proxyName(a) or serialize(a)
        local sb = isProxy(b) and proxyName(b) or serialize(b)
        markUsed(a); markUsed(b)
        local ax, ay, az = getVector3Args(a)
        local bx, by, bz = getVector3Args(b)
        if ax and bx then
            return makeVector3FromArgs(ax - bx, ay - by, az - bz)
        end
        local retName = genVar("v")
        emit(string.format('local %s = %s - %s', retName, sa, sb))
        return makeProxy(retName)
    end
    mt.__mul = function(a, b)
        local sa = isProxy(a) and proxyName(a) or serialize(a)
        local sb = isProxy(b) and proxyName(b) or serialize(b)
        markUsed(a); markUsed(b)
        local ax, ay, az = getVector3Args(a)
        local bx, by, bz = getVector3Args(b)
        if ax and bx then
            return makeVector3FromArgs(ax * bx, ay * by, az * bz)
        end
        if ax and type(b) == "number" then
            return makeVector3FromArgs(ax * b, ay * b, az * b)
        end
        if type(a) == "number" and bx then
            return makeVector3FromArgs(a * bx, a * by, a * bz)
        end
        local retName = genVar("v")
        emit(string.format('local %s = %s * %s', retName, sa, sb))
        return makeProxy(retName)
    end
    mt.__div = function(a, b)
        local sa = isProxy(a) and proxyName(a) or serialize(a)
        local sb = isProxy(b) and proxyName(b) or serialize(b)
        markUsed(a); markUsed(b)
        local ax, ay, az = getVector3Args(a)
        local bx, by, bz = getVector3Args(b)
        if ax and bx then
            return makeVector3FromArgs(ax / bx, ay / by, az / bz)
        end
        if ax and type(b) == "number" then
            return makeVector3FromArgs(ax / b, ay / b, az / b)
        end
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
            return getmetatable(a)._name == getmetatable(b)._name
        end
        return false
    end
    mt.__lt = function(a, b) return false end
    mt.__le = function(a, b) return rawequal(a, b) end
    mt.__iter = function() return function() return nil end end

    return setmetatable({}, mt)
end

local function spyInstance(className: string, name: string?, silent: boolean?): any
    local varName = name or genVar("inst")
    if not silent then
        emit(string.format('local %s = Instance.new("%s")', varName, className))
    end
    local proxy = makeProxy(varName)
    local mt = getmetatable(proxy)
    mt._className = className
    mt._storedValues["ClassName"] = className
    mt._setKeys["ClassName"] = true
    return proxy
end

local env
local _realDebug = debug
local _realDebugInfo = _realDebug and _realDebug.info or nil
local _realDebugTraceback = _realDebug and _realDebug.traceback or nil
local knownCFunctions = {}
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
    local cclosureSet = setmetatable({}, { __mode = "k" })
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
    -- Explicitly register custom math functions as C closures
    for _, v in pairs(env.math) do
        if type(v) == "function" then knownCFunctions[v] = true end
    end
    knownCFunctions[env.math.clamp] = true
    knownCFunctions[env.math.sign] = true
    knownCFunctions[env.math.round] = true
    knownCFunctions[env.math.noise] = true
    knownCFunctions[env.math.randomseed] = true
    env.string = copyLib(string)
    registerCFunctions(env.string)
    env.table = copyLib(table, {
        isfrozen = function() return true end,
        freeze = function(t) return t end,
        find = function() return nil end,
        clone = function(t) return t end,
    })
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
    env.debug = nil
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
        return tostring(v)
    end; env.type = type; env.select = select
    env.unpack = table.unpack; env.rawget = rawget; env.rawset = rawset; env.rawequal = rawequal
    env.rawlen = rawlen; env.setmetatable = setmetatable; env.getmetatable = function(t)
        if type(t) == "string" then return nil end
        local m = getmetatable(t)
        if m and m.__metatable ~= nil then return m.__metatable end
        if m and m._isProxy then
            local cls = m._className or ""
            if cls == "DataModel" or cls == "Workspace" or cls == "Instance" then
                return "The metatable is locked"
            end
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
                local fieldName = m._fieldName
                local parent = m._parent
                local parentMt = parent and getmetatable(parent) or nil
                if fieldName and parentMt and parentMt._className then
                    local runtimeTypeName = getPropertyRuntimeType(parentMt._className, fieldName)
                    if runtimeTypeName then
                        return runtimeTypeName
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
        error("setfenv: cannot change environment of given object", 2)
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
    env.buffer = {
        create = function(size) return { _size = size, _data = {} } end,
        readi8 = function(buf, offset) return 0 end,
        readu8 = function(buf, offset) return 0 end,
        readi16 = function(buf, offset) return 0 end,
        readu16 = function(buf, offset) return 0 end,
        readi32 = function(buf, offset) return 0 end,
        readu32 = function(buf, offset) return 0 end,
        readf32 = function(buf, offset) return 0 end,
        readf64 = function(buf, offset) return 0 end,
        writei8 = function(buf, offset, val) end,
        writeu8 = function(buf, offset, val) end,
        writei16 = function(buf, offset, val) end,
        writeu16 = function(buf, offset, val) end,
        writei32 = function(buf, offset, val) end,
        writeu32 = function(buf, offset, val) if offset and offset > 100000 then error("buffer overflow", 0) end end,
        writef32 = function(buf, offset, val) end,
        writef64 = function(buf, offset, val) end,
        readstring = function(buf, offset, count) return string.rep("l", count or 0) end,
        writestring = function(buf, offset, str) end,
        len = function(buf) return type(buf) == "table" and buf._size or 0 end,
        copy = function(dst, dstOffset, src, srcOffset, count) end,
        fill = function(buf, offset, val, count) end,
        tobits = function(buf) return {} end,
        frombits = function(bits) return { _size = 0, _data = {} } end,
    }
    env.getfenv = function(level)
        if type(level) == "number" and level > 100 then return nil end
        return env
    end
    env.version = function() return "0.728.0.7280895" end
    env._VERSION = "Luau"
    env.loadstring = nil
    env.load = nil

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
            return proxy
        end,
    }, { __index = function(_, k) return makeProxy("Instance." .. tostring(k)) end })
    env.Enum = setmetatable({
        GetEnumItems = function() return {} end,
    }, {
        __index = function(_, k)
            local enumType = setmetatable({
                GetEnumItems = function() return {
                    { Name = "Item1", Value = 0 },
                    { Name = "Item2", Value = 1 },
                } end,
                GetByValue = function() return nil end,
            }, {
                __index = function(_, k2)
                    local item = makeProxy("Enum." .. tostring(k) .. "." .. tostring(k2))
                    local itemMt = getmetatable(item)
                    itemMt._className = "EnumItem"
                    itemMt._ctorName = "EnumItem"
                    itemMt._storedValues["Name"] = tostring(k2)
                    itemMt._setKeys["Name"] = true
                    itemMt._storedValues["Value"] = 0
                    itemMt._setKeys["Value"] = true
                    itemMt._storedValues["EnumType"] = tostring(k)
                    itemMt._setKeys["EnumType"] = true
                    return item
                end
            })
            local etMt = getmetatable(enumType)
            etMt._isEnumType = true
            return enumType
        end
    })
    env.Enums = env.Enum

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
            local proxy = makeProxy(v)
            local mt = getmetatable(proxy)
            mt._ctorArgs = {...}
            mt._ctorName = name
            return proxy
        end }, { __index = function(_, k) return makeProxy(name .. "." .. tostring(k)) end })
    end
    env.Vector3 = newCtor("Vector3")
    env.Vector2 = newCtor("Vector2")
    env.CFrame = newCtor("CFrame")
    env.UDim2 = newCtor("UDim2")
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
        create = function(n) return { _data = string.rep("\0", n or 0) } end,
        fromstring = function(s) return { _data = s or "" } end,
        tostring = function(b) return b and b._data or "" end,
        len = function(b) return b and #(b._data) or 0 end,
    }, {
        _serialName = "buffer",
        __index = function() return function() end end,
        __tostring = function() return "table: 0x" .. string.format("%x", math.random(1048576, 1099511627776)) end,
    })
    env.Buffer = env.buffer

    local YIELD_BUDGET = 1
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
        local ok, err = pcall(f, ...)
        yieldCount = savedYieldCount
        if not ok and tostring(err):find(BUDGET_ERROR, 1, true) then
        end
    end
    local taskTbl = {
        wait = function(time)
            yieldTick(); tick()
            return time or 0.015
        end,
        spawn = function(f, ...)
            tick()
            local args = table.pack(...)
            local co = coroutine.create(function() runCallback(f, table.unpack(args, 1, args.n)) end)
            coroutine.resume(co)
            return co
        end,
        delay = function(t, f)
            tick()
            local co = coroutine.create(function() runCallback(f) end)
            return co
        end,
        cancel = function(co) end,
        clock = function() return os.clock() end,
        defer = function(f, ...)
            tick()
            local args = table.pack(...)
            local co = coroutine.create(function() runCallback(f, table.unpack(args, 1, args.n)) end)
            return co
        end,
        synchronize = function() end,
        desynchronize = function() end,
    }
    env.task = setmetatable(taskTbl, {
        __newindex = function() error("attempt to write to read-only library table", 2) end
    })
    env.wait = function(time) yieldTick(); return time or 0.015 end
    env.spawn = env.task.spawn
    env.delay = env.task.delay
    env.tick = function() return os.time() end
    env.time = function() return os.time() end
    env.elapsedTime = function() return os.clock() end
    env.elapsedtime = env.elapsedTime
    env.stats = function() return {} end
    env.hookfunction = function(...) return ... end
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
        if type(f) == "function" then cclosureSet[f] = true end
        return f
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
    -- Register sandbox functions as C closures for iscclosure checks
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
    env.clonefunction = function(f) return f end
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
    env.isreadonly = function() return false end
    env.setreadonly = function() end
    env.getrenderproperty = function() return nil end
    env.setrenderproperty = function() end
    env.cleardrawcache = function() end
    env.toast = function() end
    env.messagebox = function() return 1 end
    env.zstdcompress = function(s) return s end
    env.zstddecompress = function(s) return s end
    env.qrcode = function() return "" end
    env.newproxy = function() return setmetatable({}, {}) end
    env.getgc = function() return {} end
    env.gcinfo = function() return 0 end
    env.collectgarbage = function() return 0 end
    env.require = nil
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
        load = true,
        loadstring = true,
        loadfile = true,
        debug = true,
        io = true,
    }
    setmetatable(env, {
        __index = function(t, k)
            if blockedGlobals[k] then return nil end
            return nil
        end,
        __newindex = function(t, k, v)
            rawset(t, k, v)
        end,
    })
    env.Drawing = setmetatable({}, { __index = function(_, k) return makeProxy("Drawing." .. tostring(k)) end })
    env.crypt = setmetatable({}, { __index = function(_, k) return function() return makeProxy("crypt." .. tostring(k)) end end })
    env.base64 = { encode = function(s) return s or "" end, decode = function(s) return s or "" end }
    env.syn = setmetatable({}, { __index = function(_, k) return makeProxy("syn." .. tostring(k)) end })
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
    "local debug = nil",
    "local load = nil",
    "local loadstring = nil",
    "local dofile = nil",
    "local require = nil",
    "local package = nil",
    "local loadfile = nil",
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
    local ok, err = pcall(fn)
    if not ok then
        local errStr = tostring(err)
        if not errStr:find(BUDGET_ERROR, 1, true) then
            emit(string.format("-- Runtime error: %s", errStr:sub(1, 300)))
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
