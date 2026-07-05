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
}
for _, arg in process.args do
    local k, v = string.match(arg, "([%w_]+)=(.+)")
    if k then
        Settings[k] = if v == "true" then true elseif v == "false" then false elseif tonumber(v) then tonumber(v) else v
    elseif not Settings.ipt and not string.match(arg, "^%-") then
        Settings.ipt = arg
    end
end

local lines = {}
local varCount = 0
local function emit(text: string)
    table.insert(lines, text)
end
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
    elseif t == "number" then return tostring(value)
    elseif t == "string" then
        if #value > 200 then return string.format("[=[%s...]=]", string.sub(value, 1, 200)) end
        local escaped = string.gsub(value, "\\", "\\\\")
        escaped = string.gsub(escaped, "\"", "\\\"")
        escaped = string.gsub(escaped, "\n", "\\n")
        return '"' .. escaped .. '"'
    elseif t == "table" then
        local parts = {}
        for k, v in pairs(value) do
            local keyStr = if type(k) == "string" and string.match(k, "^[%a_][%w_]*$") then k else "[" .. serialize(k, depth + 1) .. "]"
            table.insert(parts, keyStr .. " = " .. serialize(v, depth + 1))
        end
        return "{" .. table.concat(parts, ", ") .. "}"
    elseif t == "function" then return "function() end" end
    return "nil"
end

-- universal permissive proxy
local function makeProxy(name: string?): any
    local pname = name or "proxy"
    return setmetatable({}, {
        __index = function(_, k)
            return makeProxy(pname .. "." .. tostring(k))
        end,
        __newindex = function(_, k, v)
            if type(v) == "function" then
                emit(string.format('%s.%s = function() end', pname, tostring(k)))
            else
                emit(string.format('%s.%s = %s', pname, tostring(k), serialize(v)))
            end
        end,
        __call = function(_, ...)
            local args = { ... }
            local parts = {}
            for i = 1, select("#", ...) do
                local a = args[i]
                if type(a) == "table" and getmetatable(a) and getmetatable(a).__tostring then
                    table.insert(parts, tostring(a))
                else
                    table.insert(parts, serialize(a))
                end
            end
            emit(string.format('%s(%s)', pname, table.concat(parts, ", ")))
            return makeProxy(pname .. ".ret")
        end,
        __tostring = function() return pname end,
        __concat = function(a, b) return tostring(a) .. tostring(b) end,
        __add = function() return makeProxy(pname .. "+") end,
        __sub = function() return makeProxy(pname .. "-") end,
        __mul = function() return makeProxy(pname .. "*") end,
        __div = function() return makeProxy(pname .. "/") end,
        __mod = function() return makeProxy(pname .. "%") end,
        __pow = function() return makeProxy(pname .. "^") end,
        __unm = function() return makeProxy(pname .. "-") end,
        __len = function() return 0 end,
        __eq = function() return false end,
        __lt = function() return false end,
        __le = function() return false end,
        __iter = function() return function() return nil end end,
    })
end

-- spyInstance: emits Instance.new + returns makeProxy for full permissiveness
local function spyInstance(className: string, name: string?): any
    local varName = name or genVar("inst")
    emit(string.format('local %s = Instance.new("%s")', varName, className))
    return makeProxy(varName)
end

local env
local function createEnv()
    env = {}
    env._G = env; env._ENV = env
    -- copy stdlib
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
            if m and m.__tostring then return "Instance" end
        end
        return t
    end
    env.print = function(...) local a={...} local p={} for i=1,select("#",...) do p[i]=tostring(a[i]) end emit("print(" .. table.concat(p, ", ") .. ")") end
    env.warn = env.print
    env.setfenv = function(f) return f end
    env.getfenv = function() return env end
    env.loadstring = function()
        emit("-- loadstring()")
        return function()
            emit("loadstring_ret()")
            return makeProxy("loadstring_ret")
        end
    end
    env.load = env.loadstring

    env.game = spyInstance("DataModel", "game")
    env.Game = env.game
    env.workspace = spyInstance("Workspace", "workspace")
    env.Workspace = env.workspace
    env.script = spyInstance("LocalScript", "script")

    env.Instance = setmetatable({
        new = function(c)
            local cls = tostring(c or "Instance")
            emit('local inst = Instance.new("' .. cls .. '")')
            return spyInstance(cls)
        end,
    }, { __index = function(_, k) return makeProxy("Instance." .. tostring(k)) end })
    env.Enum = setmetatable({}, { __index = function(_, k) return makeProxy("Enum." .. tostring(k)) end })
    env.Enums = env.Enum

    -- pure Lua replacements for Roblox types
    local function newCtor(name)
        return setmetatable({ new = function(...) return makeProxy(name) end },
            { __index = function(_, k) return makeProxy(name .. "." .. tostring(k)) end })
    end
    env.Vector3 = newCtor("Vector3")
    env.Vector2 = newCtor("Vector2")
    env.CFrame = newCtor("CFrame")
    env.UDim2 = newCtor("UDim2")
    env.UDim = newCtor("UDim")
    env.Color3 = setmetatable({
        new = function() return makeProxy("Color3") end,
        fromRGB = function() return makeProxy("Color3") end,
        fromHSV = function() return makeProxy("Color3") end,
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

    env.task = {
        wait = function() return 0 end,
        spawn = function(f, ...) emit("-- task.spawn()") end,
        delay = function(t, f) emit("-- task.delay()") end,
        cancel = function() end,
        clock = function() return os.clock() end,
        defer = function(f, ...) emit("-- task.defer()") end,
        synchronize = function() end,
        desynchronize = function() end,
    }
    env.wait = function() return 0 end
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

    -- CRITICAL: override process.exit and other dangerous globals
    -- because Lune exposes process as a global and the script may call process.exit
    env.process = setmetatable({
        exit = function() emit("-- process.exit() called") end,
        args = {},
        env = {},
        cwd = function() return "/" end,
        os = "linux",
        pid = 1,
    }, { __index = function(_, k) return makeProxy("process." .. tostring(k)) end })

    return env
end

local function dump(source: string): string
    lines = {}
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
    local ok, err = pcall(fn)
    if not ok then
        emit(string.format("-- Runtime error: %s", tostring(err):sub(1, 300)))
    end
    return table.concat(lines, "\n")
end

if Settings.ipt then
    local source = fs.readFile(Settings.ipt)
    local result = dump(source)
    fs.writeFile(Settings.out, result)
    stdio.write(string.format("Done! Output: %s (%d bytes, %d lines)\n", Settings.out, #result, #lines))
    process.exit(0)
end
