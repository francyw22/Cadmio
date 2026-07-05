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

local serviceNames = {
    Players = "Players",
    Workspace = "Workspace",
    ReplicatedStorage = "ReplicatedStorage",
    ServerStorage = "ServerStorage",
    ServerScriptService = "ServerScriptService",
    StarterGui = "StarterGui",
    StarterPack = "StarterPack",
    StarterPlayer = "StarterPlayer",
    Lighting = "Lighting",
    SoundService = "SoundService",
    Chat = "Chat",
    RunService = "RunService",
    UserInputService = "UserInputService",
    TweenService = "TweenService",
    GroupService = "GroupService",
    AnimationClipProvider = "AnimationClipProvider",
    HttpService = "HttpService",
    MarketplaceService = "MarketplaceService",
    TeleportService = "TeleportService",
    PathfindingService = "PathfindingService",
    CollectionService = "CollectionService",
    PhysicsService = "PhysicsService",
    ProximityPromptService = "ProximityPromptService",
    ContextActionService = "ContextActionService",
    GuiService = "GuiService",
    HapticService = "HapticService",
    VRService = "VRService",
    CoreGui = "CoreGui",
    Teams = "Teams",
    InsertService = "InsertService",
    DataStoreService = "DataStoreService",
    MessagingService = "MessagingService",
    TextService = "TextService",
    TextChatService = "TextChatService",
    NetworkClient = "NetworkClient",
    ContentProvider = "ContentProvider",
    Debris = "Debris",
    MemStorageService = "MemStorageService",
    ChangeHistoryService = "ChangeHistoryService",
    PlayerEmulatorService = "PlayerEmulatorService",
    StylingService = "StylingService",
    ScriptContext = "ScriptContext",
    LocalizationService = "LocalizationService",
    PolicyService = "PolicyService",
    CaptureService = "CaptureService",
    AnalyticsService = "AnalyticsService",
    EncodingService = "EncodingService",
    CorePackages = "CorePackages",
    RobloxReplicatedStorage = "RobloxReplicatedStorage",
    RobloxGui = "RobloxGui",
    AvatarEditorService = "AvatarEditorService",
    SocialService = "SocialService",
    VoiceChatService = "VoiceChatService",
    AdService = "AdService",
    GeometryService = "GeometryService",
    AssetService = "AssetService",
    LocalizationService = "LocalizationService",
    NotificationService = "NotificationService",
    ProcessInstancePhysicsService = "ProcessInstancePhysicsService",
    FriendService = "FriendService",
    SessionService = "SessionService",
    TimerService = "TimerService",
    TouchInputService = "TouchInputService",
    GamepadService = "GamepadService",
    KeyboardService = "KeyboardService",
    MouseService = "MouseService",
    OmniRecommendationsService = "OmniRecommendationsService",
    PerformanceService = "PerformanceService",
    PlatformFriendService = "PlatformFriendService",
    ReplicatedFirst = "ReplicatedFirst",
    SpawnLocation = "SpawnLocation",
    LogService = "LogService",
    Stats = "Stats",
    TweenService = "TweenService",
    Debris = "Debris",
    CoreGui = "CoreGui",
    MarketplaceService = "MarketplaceService",
    NotificationService = "NotificationService",
    GuidRegistryService = "GuidRegistryService",
    NetworkServer = "NetworkServer",
    Geometry = "Geometry",
    VirtualInputManager = "VirtualInputManager",
    MLModelDeliveryService = "MLModelDeliveryService",
    PartyEmulatorService = "PartyEmulatorService",
    PlatformFriendsService = "PlatformFriendsService",
    FriendService = "FriendService",
    OmniRecommendationsService = "OmniRecommendationsService",
    PerformanceControlService = "PerformanceControlService",
    RbxAnalyticsService = "RbxAnalyticsService",
    AbuseReportService = "AbuseReportService",
    AdService = "AdService",
    AdPortalService = "AdPortalService",
    AppUpdateService = "AppUpdateService",
    BrowserService = "BrowserService",
    CookiesService = "CookiesService",
    CoreGui = "CoreGui",
    GamesService = "GamesService",
    KeyboardService = "KeyboardService",
    MarketplaceService = "MarketplaceService",
    MouseService = "MouseService",
    NotificationService = "NotificationService",
    PurchaseDataService = "PurchaseDataService",
    TimerService = "TimerService",
    UGCValidationService = "UGCValidationService",
}
local serviceShortcuts = {
    Players = "Players",
    UserInputService = "UIS",
    RunService = "RunService",
    ReplicatedStorage = "ReplicatedStorage",
    TweenService = "TweenService",
    Workspace = "Workspace",
    Lighting = "Lighting",
    StarterGui = "StarterGui",
    CoreGui = "CoreGui",
    HttpService = "HttpService",
    MarketplaceService = "MarketplaceService",
    DataStoreService = "DataStoreService",
    TeleportService = "TeleportService",
    SoundService = "SoundService",
    Chat = "Chat",
    Teams = "Teams",
    ProximityPromptService = "ProximityPromptService",
    ContextActionService = "ContextActionService",
    CollectionService = "CollectionService",
    PathfindingService = "PathfindingService",
    Debris = "Debris"
}
local classParents = {
    DataModel = {"DataModel", "ServiceProvider", "Instance"},
    Workspace = {"Workspace", "WorldRoot", "Model", "PVInstance", "Instance"},
    Camera = {"Camera", "Instance"},
    Players = {"Players", "Instance"},
    Player = {"Player", "Instance"},
    PlayerGui = {"PlayerGui", "BasePlayerGui", "Instance"},
    Backpack = {"Backpack", "Instance"},
    PlayerScripts = {"PlayerScripts", "Instance"},
    Folder = {"Folder", "Instance"},
    Model = {"Model", "PVInstance", "Instance"},
    Part = {"Part", "BasePart", "PVInstance", "Instance"},
    BasePart = {"BasePart", "PVInstance", "Instance"},
    ModuleScript = {"ModuleScript", "LuaSourceContainer", "Instance"},
    LocalScript = {"LocalScript", "Script", "LuaSourceContainer", "Instance"},
    Script = {"Script", "LuaSourceContainer", "Instance"},
    Humanoid = {"Humanoid", "Instance"},
    SoundService = {"SoundService", "Instance"},
    Lighting = {"Lighting", "Instance"},
    HttpService = {"HttpService", "Instance"},
    TweenService = {"TweenService", "Instance"},
    RunService = {"RunService", "Instance"},
    TextService = {"TextService", "Instance"},
    GuiService = {"GuiService", "Instance"},
    ContentProvider = {"ContentProvider", "Instance"},
    CollectionService = {"CollectionService", "Instance"},
    MemStorageService = {"MemStorageService", "Instance"},
    NetworkClient = {"NetworkClient", "Instance"},
    ClientReplicator = {"ClientReplicator", "Instance"},
}

game:GetService = function(self, serviceName)
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

local lines = {}
local varCount = 0
local usedVars = {}
local opCount = 0
local OP_BUDGET = 5000
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

makeProxy = function(name: string): any
    local children = {}
    local mt = {
        _name = name,
        _isProxy = true,
        _parent = nil,
        _fieldName = nil,
        _descriptive = false,
    }
    mt.__index = function(t, k)
        tick()
        local ks = tostring(k)
        if not children[ks] then
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
        if isProxy(v) then
            markUsed(v)
            emit(string.format('%s.%s = %s', name, ks, proxyName(v)))
        elseif type(v) == "function" then
            emit(string.format('%s.%s = function() end', name, ks))
        else
            emit(string.format('%s.%s = %s', name, ks, serialize(v)))
        end
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

        if isStatementCall then
            emit(string.format('%s(%s)', callExpr, table.concat(parts, ", ")))
            return makeProxy(retName)
        end
        emit(string.format('local %s = %s(%s)', retName, callExpr, table.concat(parts, ", ")))
        return makeProxy(retName)
    end
    mt.__tostring = function() return name end
    mt.__concat = function(a, b)
        local sa = isProxy(a) and proxyName(a) or serialize(a)
        local sb = isProxy(b) and proxyName(b) or serialize(b)
        markUsed(a); markUsed(b)
        local retName = genVar("v")
        emit(string.format('local %s = %s .. %s', retName, sa, sb))
        return makeProxy(retName)
    end
    mt.__add = function(a, b)
        local sa = isProxy(a) and proxyName(a) or serialize(a)
        local sb = isProxy(b) and proxyName(b) or serialize(b)
        markUsed(a); markUsed(b)
        local retName = genVar("v")
        emit(string.format('local %s = %s + %s', retName, sa, sb))
        return makeProxy(retName)
    end
    mt.__sub = function(a, b)
        local sa = isProxy(a) and proxyName(a) or serialize(a)
        local sb = isProxy(b) and proxyName(b) or serialize(b)
        markUsed(a); markUsed(b)
        local retName = genVar("v")
        emit(string.format('local %s = %s - %s', retName, sa, sb))
        return makeProxy(retName)
    end
    mt.__mul = function(a, b)
        local sa = isProxy(a) and proxyName(a) or serialize(a)
        local sb = isProxy(b) and proxyName(b) or serialize(b)
        markUsed(a); markUsed(b)
        local retName = genVar("v")
        emit(string.format('local %s = %s * %s', retName, sa, sb))
        return makeProxy(retName)
    end
    mt.__div = function(a, b)
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
    mt.__eq = function() return false end
    mt.__lt = function() return false end
    mt.__le = function() return false end
    mt.__iter = function() return function() return nil end end

    return setmetatable({}, mt)
end

local function spyInstance(className: string, name: string?): any
    local varName = name or genVar("inst")
    emit(string.format('local %s = Instance.new("%s")', varName, className))
    return makeProxy(varName)
end

local env
local function createEnv()
    env = {}
    env._G = env; env._ENV = env
    local function copyLib(lib)
        local c = {}
        for k, v in pairs(lib) do c[k] = v end
        return c
    end
    env.math = copyLib(math)
    env.string = copyLib(string)
    env.table = copyLib(table)
    env.coroutine = copyLib(coroutine)
    env.coroutine.yield = function() return nil end
    env.os = copyLib(os)
    env.os.exit = function() emit("-- os.exit() called") end
    env.os.halt = function() emit("-- os.halt() called") end
    env.debug = debug
    env.io = nil
    env.pcall = pcall; env.xpcall = xpcall; env.error = error; env.assert = assert
    env.tonumber = tonumber; env.tostring = tostring; env.type = type; env.select = select
    env.unpack = table.unpack; env.rawget = rawget; env.rawset = rawset; env.rawequal = rawequal
    env.rawlen = rawlen; env.setmetatable = setmetatable; env.getmetatable = getmetatable
    env.ipairs = ipairs; env.pairs = pairs; env.next = next; env._VERSION = "Lua 5.1"
    env.utf8 = utf8; env.bit32 = bit32; env.bit = bit32
    env.typeof = function(x)
        local t = type(x)
        if t == "table" then
            local m = getmetatable(x)
            if m and m._isProxy then return "Instance" end
        end
        return t
    end
    env.print = function(...)
        local a={...}
        local p={}
        for i=1,select("#",...) do p[i]=serialize(a[i]) end
        emit("print(" .. table.concat(p, ", ") .. ")")
    end
    env.warn = env.print
    env.setfenv = function(f) return f end
    env.getfenv = function() return env end
    env.loadstring = makeProxy("loadstring")
    env.load = env.loadstring

    env.game = spyInstance("DataModel", "game")
    env.Game = env.game
    env.workspace = spyInstance("Workspace", "workspace")
    env.Workspace = env.workspace
    env.script = spyInstance("LocalScript", "script")

    env.Instance = setmetatable({
        new = function(c)
            local cls = tostring(c or "Instance")
            local v = genVar("inst")
            emit(string.format('local %s = Instance.new("%s")', v, cls))
            return makeProxy(v)
        end,
    }, { __index = function(_, k) return makeProxy("Instance." .. tostring(k)) end })
    env.Enum = setmetatable({}, { __index = function(_, k) return makeProxy("Enum." .. tostring(k)) end })
    env.Enums = env.Enum

    local function newCtor(name)
        return setmetatable({ new = function(...)
            local v = genVar(name:lower())
            local parts = {}
            local args = {...}
            for i = 1, select("#", ...) do table.insert(parts, serialize(args[i])) end
            emit(string.format('local %s = %s.new(%s)', v, name, table.concat(parts, ", ")))
            return makeProxy(v)
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
    env.Color3 = setmetatable({
        new = function(...) local v = genVar("color"); emit(string.format('local %s = Color3.new(%s)', v, argsToList(...))); return makeProxy(v) end,
        fromRGB = function(...) local v = genVar("color"); emit(string.format('local %s = Color3.fromRGB(%s)', v, argsToList(...))); return makeProxy(v) end,
        fromHSV = function(...) local v = genVar("color"); emit(string.format('local %s = Color3.fromHSV(%s)', v, argsToList(...))); return makeProxy(v) end,
    }, { __index = function(_, k) return makeProxy("Color3." .. tostring(k)) end })
    env.Rect = newCtor("Rect")
    env.Ray = newCtor("Ray")
    env.Region3 = newCtor("Region3")
    env.Random = newCtor("Random")
    env.DateTime = setmetatable({}, { __index = function(_, k) return makeProxy("DateTime." .. tostring(k)) end })
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
    }, { __index = function() return function() end end })
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
    env.task = {
        wait = function() yieldTick(); return 0 end,
        spawn = function(f, ...) runCallback(f, ...) end,
        delay = function(t, f) runCallback(f) end,
        cancel = function() end,
        clock = function() return os.clock() end,
        defer = function(f, ...) runCallback(f, ...) end,
        synchronize = function() end,
        desynchronize = function() end,
    }
    env.wait = function() yieldTick(); return 0 end
    env.spawn = env.task.spawn
    env.delay = env.task.delay
    env.tick = function() return os.time() end
    env.time = function() return os.time() end
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
    env.newcclosure = function(f) return f end
    env.getgenv = function() return env end
    env.getrenv = function() return env end
    env.gethui = function() return env.game end
    env.newproxy = function() return setmetatable({}, {}) end
    env.gcinfo = function() return 0 end
    env.collectgarbage = function() return 0 end
    env.require = function() return nil end
    env.shared = env
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

local function dump(source: string): string
    lines = {}
    varCount = 0
    usedVars = {}
    emit("-- EnvLog output")
    emit("")
    local env = createEnv()

    local fn
    local loadOk, loadErr = pcall(function()
        local compiled = luau.compile(source, { optimizationLevel = 2 })
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
    return table.concat(lines, "\n")
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
