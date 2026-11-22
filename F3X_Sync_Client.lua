
-- F3X Sync client adapter for Potassium.
-- Mirrors only F3X-created parts to other opted-in clients.
-- Shared parts are local visual copies, not server-owned parts.

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")
local LocalPlayer = Players.LocalPlayer

local ENDPOINT = "wss://f3x-sync.onrender.com"
local ASSET_ID = "rbxassetid://6695644299"
local ROOM = "f3x-" .. tostring(game.PlaceId) .. "-" .. tostring(game.JobId)
local MAX_PARTS = 300
local UPDATE_INTERVAL = 0.15

local function notify(message)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = "F3X Sync",
            Text = message,
            Duration = 5
        })
    end)
    print("[F3X Sync] " .. message)
end

-- Check WebSocket support.
if typeof(WebSocket) ~= "table"
    or typeof(WebSocket.connect) ~= "function" then
    notify("This executor does not support WebSocket.connect")
    return
end

-- Connect to the relay.
local socketOk, socket = pcall(function()
    return WebSocket.connect(ENDPOINT)
end)

if not socketOk or not socket then
    notify("Could not connect to the sync server")
    warn("[F3X Sync] " .. tostring(socket))
    return
end

local myPrefix = tostring(LocalPlayer.UserId)
    .. ":" .. tostring(math.floor(os.clock() * 100000))

local nextId = 0
local localParts = {}
local localPartCount = 0
local remoteParts = {}
local lastSent = {}

-- Local-only folder for other clients' builds.
local visuals = Workspace:FindFirstChild("F3XSync_Visuals")

if not visuals then
    visuals = Instance.new("Folder")
    visuals.Name = "F3XSync_Visuals"
    visuals.Parent = Workspace
end

local function send(payload)
    payload.room = ROOM

    local ok, encoded = pcall(function()
        return HttpService:JSONEncode(payload)
    end)

    if ok then
        pcall(function()
            socket:Send(encoded)
        end)
    end
end

local function finite(n)
    return type(n) == "number"
        and n == n
        and n > -1000000
        and n < 1000000
end

local function capture(part, id)
    if not part or not part:IsA("BasePart") then
        return nil
    end

    local cf = {part.CFrame:GetComponents()}
    local s = part.Size
    local c = part.Color

    return {
        id = id,
        className = part.ClassName,
        name = string.sub(part.Name, 1, 80),
        size = {s.X, s.Y, s.Z},
        cframe = cf,
        color = {c.R, c.G, c.B},
        material = part.Material.Name,
        transparency = part.Transparency,
        reflectance = part.Reflectance,
        anchored = part.Anchored,
        canCollide = part.CanCollide,
        shape = part:IsA("Part") and part.Shape.Name or nil,
        topSurface = part:IsA("Part") and part.TopSurface.Name or nil,
        bottomSurface = part:IsA("Part") and part.BottomSurface.Name or nil
    }
end

local allowedClasses = {
    Part = true,
    WedgePart = true,
    CornerWedgePart = true,
    TrussPart = true,
    Seat = true,
    VehicleSeat = true,
    SpawnLocation = true
}

local function validBuild(b)
    if type(b) ~= "table"
        or type(b.id) ~= "string"
        or #b.id > 100 then
        return false
    end

    if not allowedClasses[b.className] then
        return false
    end

    if type(b.size) ~= "table" or #b.size ~= 3 then
        return false
    end

    if type(b.cframe) ~= "table" or #b.cframe ~= 12 then
        return false
    end

    if type(b.color) ~= "table" or #b.color ~= 3 then
        return false
    end

    for _, v in ipairs(b.size) do
        if not finite(v) or v <= 0 or v > 2048 then
            return false
        end
    end

    for _, v in ipairs(b.cframe) do
        if not finite(v) then
            return false
        end
    end

    for _, v in ipairs(b.color) do
        if not finite(v) or v < 0 or v > 1 then
            return false
        end
    end

    return true
end

local function applyBuild(part, b)
    local size = b.size
    local cf = b.cframe
    local color = b.color

    part.Name = type(b.name) == "string"
        and string.sub(b.name, 1, 80)
        or "F3X Shared Part"

    part.Size = Vector3.new(size[1], size[2], size[3])
    part.CFrame = CFrame.new(table.unpack(cf))
    part.Color = Color3.new(color[1], color[2], color[3])

    pcall(function()
        part.Material = Enum.Material[b.material]
    end)

    part.Transparency = math.clamp(
        tonumber(b.transparency) or 0, 0, 1
    )

    part.Reflectance = math.clamp(
        tonumber(b.reflectance) or 0, 0, 1
    )

    -- Remote copies are visual only.
    part.Anchored = true
    part.CanCollide = false
    part.CanTouch = false
    part.CanQuery = false

    if part:IsA("Part") then
        pcall(function()
            part.Shape = Enum.PartType[b.shape]
        end)

        pcall(function()
            part.TopSurface = Enum.SurfaceType[b.topSurface]
        end)

        pcall(function()
            part.BottomSurface = Enum.SurfaceType[b.bottomSurface]
        end)
    end
end

local function createRemote(b)
    if not validBuild(b) then
        return
    end

    local part = remoteParts[b.id]

    if not part then
        if #visuals:GetChildren() >= MAX_PARTS then
            return
        end

        local ok, newPart = pcall(Instance.new, b.className)

        if not ok or not newPart then
            return
        end

        part = newPart
        part.Parent = visuals
        remoteParts[b.id] = part
    end

    pcall(applyBuild, part, b)
end

local function receive(raw)
    local ok, message = pcall(function()
        return HttpService:JSONDecode(raw)
    end)

    if not ok or type(message) ~= "table" then
        return
    end

    if message.type == "snapshot" then
        if type(message.builds) == "table" then
            for _, b in ipairs(message.builds) do
                createRemote(b)
            end
        end

    elseif message.type == "create"
        or message.type == "update" then

        if type(message.build) == "table" then
            createRemote(message.build)
        end

    elseif message.type == "delete" then
        local id = message.id
        local part = type(id) == "string"
            and remoteParts[id]

        if part then
            remoteParts[id] = nil
            pcall(function()
                part:Destroy()
            end)
        end
    end
end

socket.OnMessage:Connect(receive)
send({type = "join", room = ROOM})

-- Register only parts created by the patched F3X handlers.
local function registerLocalPart(part)
    if not part
        or not part:IsA("BasePart")
        or localParts[part] then
        return
    end

    if localPartCount >= MAX_PARTS then
        notify("Local sync limit reached")
        return
    end

    nextId += 1

    local id = myPrefix .. ":" .. tostring(nextId)

    localParts[part] = id
    localPartCount += 1

    local snapshot = capture(part, id)

    if snapshot then
        lastSent[part] = HttpService:JSONEncode(snapshot)
        send({
            type = "create",
            build = snapshot
        })
    end
end

getgenv().F3XSyncRegisterPart = registerLocalPart

-- Load the original F3X asset.
local assetOk, objects = pcall(function()
    return game:GetObjects(ASSET_ID)
end)

if not assetOk or type(objects) ~= "table" or not objects[1] then
    notify("Could not load the original F3X asset")
    warn("[F3X Sync] Asset loading error: " .. tostring(objects))
    return
end

-- Read its source.
local sourceOk, source = pcall(function()
    return objects[1].Source
end)

if not sourceOk or type(source) ~= "string" then
    notify("Could not read F3X source; source access is unavailable")
    warn("[F3X Sync] Source read error: " .. tostring(source))
    return
end

-- Patch the exact F3X clone creation point.
local cloneNeedle = 'local rd=xj1:Clone()rd.Parent=Workspace'

local clonePatch = cloneNeedle ..
    ' if getgenv().F3XSyncRegisterPart then getgenv().F3XSyncRegisterPart(rd) end'

-- Patch the exact F3X New Part creation point.
local newPartNeedle = 'GxQqHPYH.Anchored=true'

local newPartPatch = newPartNeedle ..
    ' if getgenv().F3XSyncRegisterPart then getgenv().F3XSyncRegisterPart(GxQqHPYH) end'

-- IMPORTANT: gsub returns the new string FIRST, then the match count.
local patchedSource, cloneCount =
    source:gsub(cloneNeedle, clonePatch, 1)

local newPartCount
patchedSource, newPartCount =
    patchedSource:gsub(newPartNeedle, newPartPatch, 1)

if cloneCount ~= 1 or newPartCount ~= 1 then
    notify("F3X source patch check failed")

    warn(
        "[F3X Sync] Clone matches: "
        .. tostring(cloneCount)
        .. ", New Part matches: "
        .. tostring(newPartCount)
    )

    return
end

-- Compile the patched original source.
local compileOk, compiled = pcall(loadstring, patchedSource)

if not compileOk or type(compiled) ~= "function" then
    notify("Could not compile patched F3X source")
    warn("[F3X Sync] Compile error: " .. tostring(compiled))
    return
end

-- Start the original F3X.
local runOk, runError = pcall(compiled)

if not runOk then
    notify("F3X started with an error")
    warn("[F3X Sync] F3X load error: " .. tostring(runError))
    return
end

notify("Original F3X loaded; sync connected")

-- Send changes only for registered F3X-created parts.
task.spawn(function()
    while true do
        task.wait(UPDATE_INTERVAL)

        for part, id in pairs(localParts) do
            local exists = false

            pcall(function()
                exists = part:IsDescendantOf(Workspace)
            end)

            if not exists then
                if lastSent[part] ~= "__deleted" then
                    send({
                        type = "delete",
                        id = id
                    })

                    lastSent[part] = "__deleted"
                end
            else
                local snapshotOk, snapshot =
                    pcall(capture, part, id)

                if snapshotOk and snapshot then
                    local encodedOk, encoded = pcall(function()
                        return HttpService:JSONEncode(snapshot)
                    end)

                    if encodedOk and encoded ~= lastSent[part] then
                        send({
                            type = lastSent[part] == "__deleted"
                                and "create" or "update",
                            build = snapshot
                        })

                        lastSent[part] = encoded
                    end
                end
            end
        end
    end
end)

print("[F3X Sync] Room: " .. ROOM)
