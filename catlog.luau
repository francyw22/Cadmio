local fs = require("@lune/fs")
local process = require("@lune/process")
local stdio = require("@lune/stdio")
local task = require("@lune/task")
local serde = require("@lune/serde")
local roblox = require("@lune/roblox")
local luau = require("@lune/luau")
local net = require("@lune/net")
local Instance = roblox.Instance
local RealEnum = roblox.Enum
local RealVector3 = roblox.Vector3
local RealCFrame = roblox.CFrame
local RealUDim2 = roblox.UDim2
local RealColor3 = roblox.Color3
local Settings = {
    out = "out.lua",
    hookOp = false,
    minifier = true,
    timeout = 25,
    maxOps = 15_000_000,
    ipt = nil :: string?,
    debug = false,
}
for _, arg in process.args do
    local k, v = string.match(arg, "([%w_]+)=(.+)")
    if not k and string.sub(arg, 1, 1) == "!" then
        Settings[string.sub(arg, 2)] = false
    elseif not k and not Settings.ipt then
        Settings.ipt = arg
    elseif k then
        Settings[k] = if v == "true" then true elseif v == "false" then false elseif tonumber(v) then tonumber(v) else v
    end
end
local lines = {}
local indent = 0
local varCount = 0
local function emit(text: string)
    table.insert(lines, string.rep("  ", indent) .. text)
end
local function push() indent += 1 end
local function pop() indent -= 1 end
local function genVar(prefix: string?): string
    varCount += 1
    return (prefix or "v") .. tostring(varCount)
end
local serialize: (any, number?) -> string
function serialize(value: any, depth: number?): string
    depth = depth or 0
    if depth > 5 then return "nil" end
    local t = typeof(value)
    if t == "nil" then return "nil"
    elseif t == "boolean" then return value and "true" or "false"
    elseif t == "number" then
        if value ~= value then return "0/0"
        elseif value == math.huge then return "math.huge"
        elseif value == -math.huge then return "-math.huge" end
        return tostring(value)
    elseif t == "string" then
        if #value > 200 then
            return string.format("[=[%s...]=]", string.sub(value, 1, 200))
        end
        local escaped = string.gsub(value, "\\", "\\\\")
        escaped = string.gsub(escaped, "\"", "\\\"")
        escaped = string.gsub(escaped, "\n", "\\n")
        escaped = string.gsub(escaped, "\r", "\\r")
        escaped = string.gsub(escaped, "\t", "\\t")
        return '"' .. escaped .. '"'
    elseif t == "Vector3" then
        return string.format("Vector3.new(%s, %s, %s)",
            tostring(value.X), tostring(value.Y), tostring(value.Z))
    elseif t == "CFrame" then
        return string.format("CFrame.new(%s, %s, %s)",
            tostring(value.X), tostring(value.Y), tostring(value.Z))
    elseif t == "UDim2" then
        return string.format("UDim2.new(%s, %s, %s, %s)",
            tostring(value.X.Scale), tostring(value.X.Offset),
            tostring(value.Y.Scale), tostring(value.Y.Offset))
    elseif t == "Color3" then
        return string.format("Color3.fromRGB(%d, %d, %d)",
            math.floor(value.R * 255), math.floor(value.G * 255), math.floor(value.B * 255))
    elseif t == "EnumItem" then
        return tostring(value)
    elseif t == "Instance" then
        return string.format('Instance.new("%s")', value.ClassName)
    elseif t == "table" then
        local parts = {}
        local isArray = true
        local count = 0
        for k, v in pairs(value) do
            count += 1
            if type(k) ~= "number" then isArray = false end
            if isArray then table.insert(parts, serialize(v, depth + 1)) end
        end
        if isArray and count > 0 then
            return "{" .. table.concat(parts, ", ") .. "}"
        end
        for k, v in pairs(value) do
            local keyStr = if type(k) == "string" and string.match(k, "^[%a_][%w_]*$")
                then k else "[" .. serialize(k, depth + 1) .. "]"
            table.insert(parts, keyStr .. " = " .. serialize(v, depth + 1))
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    elseif t == "function" then return "function() end" end
    return "nil"
end
local function makeSignal(name: string, instName: string)
    return setmetatable({}, {
        __index = function(_, k: string)
            if k == "Connect" or k == "connect" then
                return function(cb: any)
                    emit(string.format('-- %s.%s:Connect(callback)', instName, name))
                    return setmetatable({}, {
                        __index = function() return function() end end,
                        Disconnect = function() end,
                    })
                end
            end
            if k == "Wait" then return function() return nil end end
            return function() end
        end,
    })
end
local EventNames = {
    "MouseButton1Click", "MouseButton2Click", "MouseEnter", "MouseLeave",
    "MouseMoved", "Activated", "Deactivated", "FocusLost", "FocusGained",
    "Changed", "AncestryChanged", "ChildAdded", "ChildRemoved",
    "DescendantAdded", "DescendantRemoving", "ChildAdded",
    "InputBegan", "InputChanged", "InputEnded", "Heartbeat",
    "RenderStepped", "Stepped", "TouchStarted", "TouchEnded",
    "Idled", "PostSimulation", "PreSimulation", "PreRender",
    "SelectionChanged", "Focused", "FocusLost",
    "PlayerAdded", "PlayerRemoving", "CharacterAdded",
    "PlayerConnect", "PlayerDisconnect",
}
local function spyInstance(inst: any, name: string?): any
    local varName = name or genVar("inst")
    emit(string.format('local %s = Instance.new("%s")', varName, inst.ClassName))
    local children = {}
    local proxy = setmetatable({}, {
        __index = function(_, k: string)
            local knownEvents = {
                MouseButton1Click = true, MouseButton2Click = true,
                MouseEnter = true, MouseLeave = true, MouseMoved = true,
                Activated = true, Deactivated = true, FocusLost = true,
                FocusGained = true, Changed = true, AncestryChanged = true,
                ChildAdded = true, ChildRemoved = true,
                DescendantAdded = true, DescendantRemoving = true,
                InputBegan = true, InputChanged = true, InputEnded = true,
                Heartbeat = true, RenderStepped = true, Stepped = true,
                TouchStarted = true, TouchEnded = true,
                Idled = true, PostSimulation = true, PreSimulation = true,
                PreRender = true, SelectionChanged = true,
                PlayerAdded = true, PlayerRemoving = true,
                CharacterAdded = true, CharacterRemoving = true,
                OnServerEvent = true, OnClientEvent = true,
                CurrentCameraChanged = true, SessionEnd = true,
                Write = true, Read = true, Closed = true,
                Linking = true, Unlinking = true,
                WorldRoot = true,
            }
            if knownEvents[k] then
                return makeSignal(k, varName)
            end
            if type(k) == "string" and (#k > 3) and
               (string.sub(k, -2) == "ed" or string.sub(k, -7) == "Changed" or
                string.sub(k, 1, 2) == "On" or string.sub(k, -6) == "Adding" or
                string.sub(k, -7) == "Removing") then
                return makeSignal(k, varName)
            end
            if k == "GetService" then
                return function(_, serviceName: string?)
                    local svcName = tostring(serviceName or "Service")
                    emit(string.format('local svc = %s:GetService("%s")', varName, svcName))
                    local ok, svcInst = pcall(Instance.new, svcName)
                    if not ok then svcInst = Instance.new("Model") end
                    local svc = spyInstance(svcInst, "svc_" .. svcName)
                    if svcName == "Players" then
                        local lp = spyInstance(Instance.new("Player"), "localPlayer")
                        emit('local localPlayer = Players.LocalPlayer')
                        pcall(function() svcInst.LocalPlayer = Instance.new("Player") end)
                    end
                    return svc
                end
            end
            if k == "FindService" then
                return function(_, n: string?) return nil end
            end
            if k == "IsLoaded" then return function() return true end end
            if k == "HttpGet" then
                return function(_, url: string?)
                    local urlStr = tostring(url or "")
                    emit(string.format('%s:HttpGet("%s")', varName, urlStr))
                    local ok, response = pcall(net.request, urlStr)
                    if ok and response and response.body then return response.body end
                    return ""
                end
            end
            if k == "HttpGetAsync" then
                return function(_, url: string?)
                    local urlStr = tostring(url or "")
                    emit(string.format('%s:HttpGetAsync("%s")', varName, urlStr))
                    local ok, response = pcall(net.request, urlStr)
                    if ok and response and response.body then return response.body end
                    return ""
                end
            end
            if k == "HttpPost" then
                return function(_, url: string?, data: string?)
                    emit(string.format('%s:HttpPost("%s", ...)', varName, tostring(url or "")))
                    return ""
                end
            end
            if k == "HttpPostAsync" then
                return function(_, url: string?, data: string?)
                    emit(string.format('%s:HttpPostAsync("%s", ...)', varName, tostring(url or "")))
                    return ""
                end
            end
            if k == "GetAsync" then
                return function(_, url: string?)
                    local urlStr = tostring(url or "")
                    emit(string.format('%s:GetAsync("%s")', varName, urlStr))
                    local ok, response = pcall(net.request, urlStr)
                    if ok and response and response.body then return response.body end
                    return ""
                end
            end
            if k == "PostAsync" then
                return function(_, url: string?, data: string?)
                    emit(string.format('%s:PostAsync("%s", ...)', varName, tostring(url or "")))
                    return ""
                end
            end
            if k == "RequestAsync" then
                return function(opts: any)
                    local urlStr = ""
                    if type(opts) == "table" then urlStr = tostring(opts.url or "") end
                    emit(string.format('%s:RequestAsync("%s")', varName, urlStr))
                    local ok, response = pcall(net.request, opts)
                    if ok and response then
                        return { StatusCode = response.status or 200, Body = response.body or "", Success = true }
                    end
                    return { StatusCode = 200, Body = "", Success = true }
                end
            end
            if k == "GenerateGUID" then return function() return "00000000-0000-0000-0000-000000000000" end end
            if k == "JSONEncode" then
                return function(_, data: any)
                    local ok, encoded = pcall(serde.encode, "json", data, false)
                    return ok and encoded or "{}"
                end
            end
            if k == "JSONDecode" then
                return function(_, str: string)
                    local ok, decoded = pcall(serde.decode, "json", str or "")
                    return ok and decoded or {}
                end
            end
            if k == "UrlEncode" then
                return function(_, str: string)
                    local s = tostring(str or "")
                    return (s:gsub("([^%w%-%.%_%~])", function(c: string)
                        return string.format("%%%02X", string.byte(c))
                    end))
                end
            end
            if k == "IsClient" then return function() return true end end
            if k == "IsServer" then return function() return false end end
            if k == "IsStudio" then return function() return false end end
            if k == "IsRunning" then return function() return true end end
            if k == "RenderStepped" then return makeSignal("RenderStepped", varName) end
            if k == "Heartbeat" then return makeSignal("Heartbeat", varName) end
            if k == "Stepped" then return makeSignal("Stepped", varName) end
            if k == "Create" then
                return function(_, obj: any, info: any, props: any)
                    emit(string.format('-- %s:Create(tween)', varName))
                    return setmetatable({}, {
                        __index = function(t2, k2)
                            if k2 == "Play" then return function() emit('-- tween:Play()') end end
                            if k2 == "Cancel" then return function() end end
                            if k2 == "Pause" then return function() end end
                            return function() end
                        end,
                    })
                end
            end
            if k == "IsKeyDown" then return function() return false end end
            if k == "GetMouseLocation" then return function() return env.Vector2.new(0, 0) end end
            if k == "GetFocusedTextBox" then return function() return nil end end
            if k == "GetMouseDelta" then return function() return env.Vector3.new(0, 0, 0) end end
            if k == "GetMouseButtonsPressed" then return function() return {} end end
            if k == "TouchEnabled" then return false end
            if k == "KeyboardEnabled" then return true end
            if k == "MouseEnabled" then return true end
            if k == "GamepadEnabled" then return false end
            if k == "LocalPlayer" then
                local lp = spyInstance(Instance.new("Player"), "localPlayer")
                return lp
            end
            if k == "GetPlayers" then return function() return {} end end
            if k == "GetPlayerByUserId" then return function() return nil end end
            if k == "GetNameFromUserIdAsync" then return function() return "Player1" end end
            if k == "GetUserIdFromNameAsync" then return function() return 1 end end
            if k == "MaxPlayers" then return 50 end
            if k == "NumPlayers" then return 1 end
            if k == "UserId" then return 1 end
            if k == "DisplayName" then return "Display1" end
            if k == "AccountAge" then return 365 end
            if k == "MembershipType" then return env.Enum.MembershipType.None end
            if k == "Character" then return nil end
            if k == "Backpack" then return nil end
            if k == "PlayerGui" then return spyInstance(Instance.new("PlayerGui"), "playerGui") end
            if k == "PlayerScripts" then return spyInstance(Instance.new("PlayerScripts"), "playerScripts") end
            if k == "Kick" then return function() end end
            if k == "FireServer" then
                return function(...)
                    local args = { ... }
                    local parts = {}
                    for i = 2, select("#", ...) do table.insert(parts, serialize(args[i])) end
                    emit(string.format('%s:FireServer(%s)', varName, table.concat(parts, ", ")))
                end
            end
            if k == "FireClient" then return function() end end
            if k == "FireAllClients" then return function() end end
            if k == "InvokeServer" then return function() return nil end end
            if k == "InvokeClient" then return function() return nil end end
            if k == "FindFirstChild" or k == "FindFirstAncestor" or
               k == "FindFirstDescendant" or k == "FindFirstChildWhichIsA" or
               k == "FindFirstChildOfClass" or k == "FindFirstAncestorWhichIsA" or
               k == "FindFirstAncestorOfClass" then
                return function(_, n: any) return nil end
            end
            if k == "WaitForChild" then
                return function(_, n: any, timeout: number?)
                    local childName = tostring(n or "Instance")
                    emit(string.format('local found = %s:WaitForChild("%s")', varName, childName))
                    local ok, childInst = pcall(Instance.new, childName)
                    if not ok then childInst = Instance.new("Model") end
                    local child = spyInstance(childInst)
                    table.insert(children, child)
                    return child
                end
            end
            if k == "GetChildren" then
                return function() return children end
            end
            if k == "GetDescendants" then
                return function()
                    local desc = {}
                    for _, c in ipairs(children) do
                        table.insert(desc, c)
                    end
                    return desc
                end
            end
            if k == "IsA" then
                return function(_, cn: string) return cn == inst.ClassName end
            end
            if k == "IsAncestorOf" then return function() return false end end
            if k == "IsDescendantOf" then return function() return false end end
            if k == "Clone" then
                return function()
                    emit(string.format('local cloned = %s:Clone()', varName))
                    local ok, cloned = pcall(Instance.new, inst.ClassName)
                    if not ok then cloned = Instance.new("Model") end
                    return spyInstance(cloned, varName .. "_clone")
                end
            end
            if k == "Destroy" then
                return function() emit(string.format('%s:Destroy()', varName)) end
            end
            if k == "ClearAllChildren" then return function() children = {} end end
            if k == "GetPropertyChangedSignal" then
                return function(prop: string?)
                    return makeSignal("PropertyChangedSignal_" .. tostring(prop or ""), varName)
                end
            end
            if k == "GetDebugId" then return function() return 0 end end
            if k == "GetFullName" then
                return function() return varName end
            end
            if k == "SetAttribute" then return function() end end
            if k == "GetAttribute" then return function() return nil end end
            if k == "GetAttributes" then return function() return {} end end
            if k == "ListAttributes" then return function() return {} end end
            if k == "CurrentCamera" then
                local cam = spyInstance(Instance.new("Camera"), "camera")
                return cam
            end
            if k == "Camera" then
                return spyInstance(Instance.new("Camera"), "camera")
            end
            if k == "WorldToViewportPoint" then
                return function(_, pos: any) return { Position = env.Vector3.new(0, 0, 0), OnScreen = true } end
            end
            if k == "WorldToScreenPoint" then
                return function(_, pos: any) return { Position = env.Vector3.new(0, 0, 0), OnScreen = true } end
            end
            if k == "ScreenToWorldPoint" then
                return function(_, pos: any) return env.Vector3.new(0, 0, 0) end
            end
            if k == "ViewportPointToRay" then
                return function() return env.Ray or setmetatable({}, {__index = function() return 0 end}) end
            end
            if k == "CFrame" then
                local ok, val = pcall(function() return inst[k] end)
                if ok and val then return val end
                return env.CFrame.new()
            end
            if k == "CameraType" then return env.Enum.CameraType.Fixed end
            if k == "FieldOfView" then return 70 end
            if k == "Text" then
                local ok, val = pcall(function() return inst[k] end)
                if ok and val ~= nil then return val end
                return ""
            end
            if k == "AbsolutePosition" then return env.Vector2.new(0, 0) end
            if k == "AbsoluteSize" then return env.Vector2.new(0, 0) end
            if k == "AbsoluteRotation" then return 0 end
            if k == "Transparency" then return 0 end
            if k == "Visible" then return true end
            if k == "Active" then return false end
            if k == "ZIndex" then return 1 end
            if k == "LayoutOrder" then return 0 end
            if k == "GetProductInfo" then
                return function() return { Name = "Product", Description = "", PriceInRobux = 0, Creator = { Name = "Creator" } } end
            end
            if k == "PlayerOwnsAsset" then return function() return false end end
            if k == "PromptPurchase" then return function() end end
            if k == "PromptProductPurchase" then return function() end end
            if k == "Play" then return function() end end
            if k == "Stop" then return function() end end
            if k == "Pause" then return function() end end
            if k == "Resume" then return function() end end
            if k == "CaptureController" then return function() end end
            if k == "ClickButton2" then return function() end end
            if k == "ClickButton1" then return function() end end
            if k == "MoveCamera" then return function() end end
            if k == "SetVirtualScroll" then return function() end end
            if k == "Button1Down" then return function() end end
            if k == "Button1Up" then return function() end end
            if k == "Button2Down" then return function() end end
            if k == "Button2Up" then return function() end end
            if k == "GetTotalMemoryUsageMb" then return function() return 800 end end
            if k == "GetMemoryUsageMbForTag" then return function() return 100 end end
            if k == "AddTag" then return function() end end
            if k == "RemoveTag" then return function() end end
            if k == "HasTag" then return function() return false end end
            if k == "GetAllTags" then return function() return {} end end
            if k == "GetTagged" then return function() return {} end end
            if k == "GetInstanceAddedSignal" then return function() return makeSignal("InstanceAdded", varName) end end
            if k == "GetInstanceRemovedSignal" then return function() return makeSignal("InstanceRemoved", varName) end end
            if k == "GetPartBoundsInBox" then return function() return {} end end
            if k == "GetPartBoundsInRadius" then return function() return {} end end
            if k == "GetPartsInPart" then return function() return {} end end
            if k == "Blockcast" then return function() return nil end end
            if k == "Raycast" then return function() return nil end end
            if k == "Shapecast" then return function() return nil end end
            if k == "Spherecast" then return function() return nil end end
            if k == "ReadVoxels" then return function() return {}, {} end end
            if k == "WriteVoxels" then return function() end end
            if k == "FillBlock" then return function() end end
            if k == "FillBall" then return function() end end
            if k:match("Fill") then return function() end end
            if k == "GetPositionOnCurve" then return function() return env.Vector2.new(0, 0) end end
            if k == "GetPositionOnCurveArcLength" then return function() return env.Vector2.new(0, 0) end end
            if k == "GetTangentOnCurve" then return function() return env.Vector2.new(0, 0) end end
            if k == "GetTangentOnCurveArcLength" then return function() return env.Vector2.new(0, 0) end end
            if k == "GetLength" then return function() return 0 end end
            if k == "SetControlPoints" then return function() end end
            if k == "GetControlPoints" then return function() return {} end end
            if k == "DecompressBuffer" then
                return function(_, buf: any, algo: any)
                    local data
                    if type(buf) == "table" then data = buf._data or ""
                    elseif type(buf) == "string" then data = buf
                    else data = tostring(buf) end
                    return env.buffer.fromstring(data)
                end
            end
            if k == "CompressBuffer" then return function(_, b: any) return b end end
            if k == "Base64Encode" then
                return function(_, s: string) return (tostring(s or ""):gsub(".", function(c) return string.format("%02x", string.byte(c)) end)) end
            end
            if k == "Base64Decode" then return function(_, s: string) return s end end
            if k == "ComputeStringHash" then return function() return "" end end
            if k == "ComputeBufferHash" then return function() return env.buffer.create(4) end end
            if k == "GetItem" then return function() return nil end end
            if k == "SetItem" then return function() end end
            if k == "RemoveItem" then return function() end end
            if k == "Flush" then return function() end end
            local ok, val = pcall(function() return inst[k] end)
            if ok and val ~= nil then return val end
            if type(k) == "string" and #k > 0 then
                return makeSignal(k, varName)
            end
            return nil
        end,
        __newindex = function(_, k: string, v: any)
            if k == "Parent" or k == "Name" or k == "ClassName" then
                emit(string.format('%s.%s = %s', varName, k, serialize(v)))
            elseif type(v) == "function" then
                emit(string.format('%s.%s = function() end', varName, k))
            else
                emit(string.format('%s.%s = %s', varName, k, serialize(v)))
            end
            pcall(function() inst[k] = v end)
        end,
        __tostring = function() return varName end,
        __eq = function(a: any, b: any) return false end,
        __len = function() return 0 end,
        __iter = function() return function() return nil end end,
    })
    return proxy
end
local function createEnv()
    local env = {}
    env._G = env
    env._ENV = env
    env.math = math
    env.string = string
    env.table = table
    env.coroutine = coroutine
    env.os = os
    env.debug = debug
    env.pcall = pcall
    env.xpcall = xpcall
    env.error = error
    env.assert = assert
    env.tonumber = tonumber
    env.tostring = tostring
    env.type = type
    env.select = select
    env.unpack = table.unpack
    env.rawget = rawget
    env.rawset = rawset
    env.rawequal = rawequal
    env.rawlen = rawlen
    env.setmetatable = setmetatable
    env.getmetatable = getmetatable
    env.ipairs = ipairs
    env.pairs = pairs
    env.next = next
    env._VERSION = "Lua 5.1"
    env.utf8 = utf8
    env.setfenv = function(f: any, t: any): any
        if type(f) == "number" then
            local info = debug.getinfo(f + 1, "f")
            if not info or not info.func then return f end
            f = info.func
        end
        if type(f) ~= "function" then return f end
        for i = 1, 32 do
            local ok, name = pcall(debug.getupvalue, f, i)
            if not ok or name == nil then break end
            if name == "_ENV" then debug.setupvalue(f, i, t); return f end
        end
        pcall(debug.setupvalue, f, 1, t)
        return f
    end
    env.getfenv = function(f: any): any
        if type(f) == "number" then
            local info = debug.getinfo(f + 1, "f")
            if not info or not info.func then return env end
            f = info.func
        end
        if type(f) ~= "function" then return env end
        for i = 1, 32 do
            local ok, name, val = pcall(debug.getupvalue, f, i)
            if not ok or name == nil then break end
            if name == "_ENV" then return val end
        end
        return env
    end
    env.loadstring = function(source: string, name: string?, mode: any?, env2: any?)
        if mode ~= nil and type(mode) ~= "string" then env2 = mode; mode = nil end
        if env2 == nil then env2 = env end
        local ok, compiled = pcall(luau.compile, source or "", { optimizationLevel = 2 })
        if not ok then return nil, tostring(compiled) end
        local loadOk, fn = pcall(luau.load, compiled, { debugName = name or "spy", environment = env2 })
        if not loadOk or not fn then return nil, tostring(fn) end
        local wrapper = function(...)
            local runOk, result = pcall(fn, ...)
            if runOk then
                return result
            end
            emit(string.format('-- loadstring("%s")() failed: %s', tostring(name or ""), tostring(result):sub(1, 100)))
            local proxy = setmetatable({}, {
                __index = function(t, k)
                    return function(...)
                        local args = { ... }
                        local parts = {}
                        for i = 1, select("#", ...) do
                            table.insert(parts, serialize(args[i]))
                        end
                        emit(string.format('-- %s(%s)', tostring(k), table.concat(parts, ", ")))
                        return setmetatable({}, {
                            __index = function(t2, k2)
                                if k2 == "Connect" or k2 == "connect" then
                                    return function()
                                        emit(string.format('-- %s:Connect(callback)', tostring(k)))
                                        return setmetatable({}, {__index = function() return function() end end, Disconnect = function() end})
                                    end
                                end
                                return function(...)
                                    local a2 = { ... }
                                    local p2 = {}
                                    for i = 1, select("#", ...) do table.insert(p2, serialize(a2[i])) end
                                    emit(string.format('-- .%s(%s)', tostring(k2), table.concat(p2, ", ")))
                                    return t2
                                end
                            end,
                            __call = function() return t end,
                        })
                    end
                end,
                __call = function() return setmetatable({}, { __index = function() return function() end end }) end,
            })
            return proxy
        end
        return wrapper
    end
    env.load = env.loadstring
    env.print = function(...)
        local args = { ... }
        local parts = {}
        for i = 1, select("#", ...) do
            table.insert(parts, serialize(args[i]))
        end
        emit(string.format('print(%s)', table.concat(parts, ", ")))
    end
    env.warn = env.print
    env.bit32 = bit32
    env.bit = env.bit32
    local BufferMT = {}
    BufferMT.__index = BufferMT
    local function makeBuffer(data: string)
        return setmetatable({ _data = data or "", _size = #(data or "") }, BufferMT)
    end
    function BufferMT.readu8(b: any, o: number) return string.byte(b._data, o) or 0 end
    function BufferMT.readu16(b: any, o: number) return (string.byte(b._data, o) or 0) + (string.byte(b._data, o + 1) or 0) * 256 end
    function BufferMT.readu32(b: any, o: number) return (string.byte(b._data, o) or 0) + (string.byte(b._data, o + 1) or 0) * 256 + (string.byte(b._data, o + 2) or 0) * 65536 + (string.byte(b._data, o + 3) or 0) * 16777216 end
    function BufferMT.readi32(b: any, o: number) local v = BufferMT.readu32(b, o); if v >= 2147483648 then v -= 4294967296 end; return v end
    function BufferMT.readf32(b: any, o: number) return string.unpack("f", b._data, o) end
    function BufferMT.readf64(b: any, o: number) return string.unpack("d", b._data, o) end
    function BufferMT.readstring(b: any, o: number, l: number) return string.sub(b._data, o + 1, o + l) end
    function BufferMT.writeu8(b: any, o: number, v: number) b._data = string.sub(b._data, 1, o) .. string.char(math.floor(v or 0) % 256) .. string.sub(b._data, o + 2) end
    function BufferMT.writeu32(b: any, o: number, v: number) v = math.floor(v or 0); b._data = string.sub(b._data, 1, o) .. string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256) .. string.sub(b._data, o + 5) end
    function BufferMT.writei32(b: any, o: number, v: number) BufferMT.writeu32(b, o, v) end
    function BufferMT.writestring(b: any, o: number, s: string) b._data = string.sub(b._data, 1, o) .. s .. string.sub(b._data, o + #s + 1) end
    function BufferMT.tostring(b: any) return b._data end
    function BufferMT.len(b: any) return b._size end
    env.buffer = {
        create = function(n: number) return makeBuffer(string.rep("\0", math.max(0, n))) end,
        fromstring = function(s: string?) return makeBuffer(s) end,
        fromblob = function(s: string?) return makeBuffer(s) end,
        len = function(b: any) return b._size end,
        size = function(b: any) return b._size end,
        readu8 = function(b: any, o: number) return b:readu8(o) end,
        readu16 = function(b: any, o: number) return b:readu16(o) end,
        readu32 = function(b: any, o: number) return b:readu32(o) end,
        readi32 = function(b: any, o: number) return b:readi32(o) end,
        readf32 = function(b: any, o: number) return b:readf32(o) end,
        readf64 = function(b: any, o: number) return b:readf64(o) end,
        readstring = function(b: any, o: number, l: number) return b:readstring(o, l) end,
        writeu8 = function(b: any, o: number, v: number) b:writeu8(o, v) end,
        writeu32 = function(b: any, o: number, v: number) b:writeu32(o, v) end,
        writei32 = function(b: any, o: number, v: number) b:writei32(o, v) end,
        writestring = function(b: any, o: number, s: string) b:writestring(o, s) end,
        tostring = function(b: any) return b._data end,
        copy = function(b: any, so: number, sb: any, ss: number, l: number) b._data = string.sub(b._data, 1, so) .. string.sub(sb._data, ss + 1, ss + l) .. string.sub(b._data, so + l + 1) end,
        fill = function(b: any, o: number, v: number, c: number) b._data = string.sub(b._data, 1, o) .. string.rep(string.char(math.floor(v or 0) % 256), c) .. string.sub(b._data, o + c + 1) end,
    }
    env.Instance = setmetatable({
        new = function(className: string?, parent: any?)
            local cls = className or "Instance"
            local ok, inst = pcall(Instance.new, cls)
            if not ok then
                ok, inst = pcall(Instance.new, "Model")
            end
            local spy = spyInstance(inst)
            if parent then spy.Parent = parent end
            return spy
        end,
    }, {
        __index = function(_, k: string)
            return function(...) return spyInstance(Instance.new(tostring(k))) end
        end,
    })
    env.Enum = RealEnum or setmetatable({}, { __index = function() return setmetatable({}, { __index = function() return { Name = "", Value = 0 } end }) end })
    env.Enums = env.Enum
    env.Vector3 = RealVector3 or setmetatable({}, { __call = function() return { X = 0, Y = 0, Z = 0 } end })
    env.Vector2 = env.Vector3
    env.CFrame = RealCFrame or setmetatable({}, { __call = function() return { X = 0, Y = 0, Z = 0 } end })
    env.UDim2 = RealUDim2 or setmetatable({}, { __call = function() return { X = 0, Y = 0, Width = 0, Height = 0 } end })
    env.Color3 = RealColor3 or setmetatable({ fromRGB = function() return { R = 0, G = 0, B = 0 } end }, { __call = function() return { R = 0, G = 0, B = 0 } end })
    env.typeof = function(x: any)
        local t = type(x)
        if t == "table" then
            local mt = getmetatable(x)
            if mt and mt.__tostring then
                local s = tostring(x)
                if string.find(s, "Instance") then return "Instance" end
            end
        end
        return t
    end
    env.Random = setmetatable({
        new = function(seed: number?) return setmetatable({
            NextInteger = function() return 0 end,
            NextNumber = function() return 0 end,
            NextUnitVector = function() return env.Vector3.new(0, 0, 0) end,
            Shuffle = function(_, t: any) return t end,
        }, {}) end,
    }, { __call = function() return setmetatable({
        NextInteger = function() return 0 end,
        NextNumber = function() return 0 end,
        NextUnitVector = function() return env.Vector3.new(0, 0, 0) end,
        Shuffle = function(_, t: any) return t end,
    }, {}) end })
    env.Path2DControlPoint = setmetatable({ new = function() return env.Instance.new("Part") end }, { __call = function() return env.Instance.new("Part") end })
    local gameObj = spyInstance(Instance.new("DataModel"), "game")
    local gameMT = getmetatable(gameObj)
    env.game = gameObj
    env.Game = gameObj
    local wsObj = spyInstance(Instance.new("Workspace"), "workspace")
    env.workspace = wsObj
    env.Workspace = wsObj
    env.script = spyInstance(Instance.new("LocalScript"), "script")
    env.task = {
        wait = function(t: number?) return 0 end,
        delay = function(t: number?, fn: any) task.spawn(fn) end,
        spawn = function(fn: any, ...) local co = coroutine.create(fn) coroutine.resume(co, ...) end,
        cancel = function() end,
        clock = function() return os.clock() end,
        getElapsedTime = function() return os.clock() end,
    }
    env.wait = function(t: number?) return 0 end
    env.spawn = env.task.spawn
    env.delay = env.task.delay
    env.tick = function() return os.time() + os.clock() % 1 end
    env.time = function() return os.time() end
    env.hookfunction = function(...) return ... end
    env.hookfunc = env.hookfunction
    env.replaceclosure = env.hookfunction
    env.checkcaller = function() return false end
    env.getrawmetatable = function(t: any) return getmetatable(t) end
    env.getrawmeta = env.getrawmetatable
    env.setrawmetatable = function(t: any, m: any) return setmetatable(t, m) end
    env.identifyexecutor = function() return "envlog", "1.0" end
    env.identifyexec = env.identifyexecutor
    env.execname = function() return "envlog" end
    env.getexecutorname = env.execname
    env.syn = function() end
    env.http_request = function(opts: any?)
        if type(opts) == "string" then
            opts = { url = opts }
        end
        local urlStr = ""
        if type(opts) == "table" then urlStr = tostring(opts.url or "") end
        emit(string.format('http_request("%s")', urlStr))
        local ok, response = pcall(net.request, opts)
        if ok and response then
            return { StatusCode = response.status or 200, Body = response.body or "", Success = true }
        end
        return { StatusCode = 200, Body = "", Success = true }
    end
    env.request = env.http_request
    env.setclipboard = function(s: string) end
    env.toclipboard = env.setclipboard
    env.readfile = function(p: string) return "" end
    env.writefile = function(p: string, c: string) end
    env.isfile = function(p: string) return false end
    env.isfolder = function(p: string) return false end
    env.makefolder = function(p: string) end
    env.listfiles = function(p: string) return {} end
    env.newcclosure = function(f: any) return f end
    env.newlclosure = function(f: any) return f end
    env.getgenv = function() return env end
    env.getrenv = function() return env end
    env.getreg = function() return {} end
    env.getloadedmodules = function() return {} end
    env.getnilinstances = function() return {} end
    env.getinstances = function() return {} end
    env.getconnections = function() return {} end
    env.getnamecallmethod = function() return "" end
    env.setreadonly = function(t: any, ro: boolean) return t end
    env.isreadonly = function(t: any) return false end
    env.gethui = function() return env.game end
    env.getthreadidentity = function() return 7 end
    env.getidentity = env.getthreadidentity
    env.setidentity = function() end
    env.gethwid = function() return "HWID-PLACEHOLDER" end
    env.firetouchinterest = function() end
    env.fireclickdetector = function() end
    env.fireproximityprompt = function() end
    env.firesignal = function() end
    env.clonefunction = function(f: any) return f end
    env.clonefunc = env.clonefunction
    env.decompile = function() return "-- decompile not available" end
    env.getconstant = function() return nil end
    env.setconstant = function() end
    env.getconstants = function() return {} end
    env.getstack = function() return nil end
    env.setstack = function() end
    env.getupvalue = function() return nil end
    env.setupvalue = function() end
    env.getupvalues = function() return {} end
    env.getprotos = function() return {} end
    env.iscclosure = function(f: any) return type(f) == "function" end
    env.islclosure = function(f: any) return type(f) == "function" end
    env.isexecutorclosure = function() return true end
    env.is_synapse_function = function() return true end
    env.Drawing = setmetatable({}, { __index = function() return setmetatable({ new = function() return setmetatable({}, { __index = function() return function() end end }) end }, { __index = function() return function() end end }) end })
    env.ifthenelse = function(c: any, a: any, b: any) if c then return a else return b end end
    env.newproxy = function() return setmetatable({}, {}) end
    env.gcinfo = function() return 0 end
    env.collectgarbage = function() return 0 end
    env.require = function() return nil end
    env.UserSettings = function() return setmetatable({}, { __index = function() return nil end }) end
    env.HttpService = env.Instance.new("HttpService")
    env.HttpService.GenerateGUID = function() return "00000000-0000-0000-0000-000000000000" end
    env.HttpService.JSONEncode = function(_, t: any) return "{}" end
    env.HttpService.JSONDecode = function(_, s: string) return {} end
    env.HttpService.UrlEncode = function(_, s: string) return s end
    return env
end
local function dump(source: string): string
    lines = {}
    indent = 0
    varCount = 0
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
    local timedOut = false
    task.delay(Settings.timeout, function()
        timedOut = true
    end)
    local ok, err = pcall(fn)
    if not ok then
        emit(string.format("-- Runtime error: %s", tostring(err):sub(1, 300)))
        local tb = debug.traceback(tostring(err), 1)
        if tb then
            for line in string.gmatch(tb, "[^\n]+") do
                if #line > 0 and #line < 200 then
                    emit(string.format("--   %s", line))
                end
            end
        end
    end
    if timedOut then
        emit("-- Timeout reached, output may be partial")
    end
    return table.concat(lines, "\n")
end
if Settings.ipt then
    local source = fs.readFile(Settings.ipt)
    local result = dump(source)
    fs.writeFile(Settings.out, result)
    stdio.write(string.format("Done! Output: %s (%d bytes)\n", Settings.out, #result))
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
