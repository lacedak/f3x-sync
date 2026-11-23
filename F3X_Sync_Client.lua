-- F3X Sync client adapter for Potassium.
-- Syncs F3X-created parts and edits to opted-in clients in the same server.
-- Shared copies remain client-side; collision is local to each opted-in client.

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

if typeof(WebSocket) ~= "table"
    or typeof(WebSocket.connect) ~= "function" then
    notify("This executor does not support WebSocket.connect")
    return
end

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
local localParts = {}       -- [Instance] = id
local localById = {}        -- [id] = Instance
local localPartCount = 0
local remoteParts = {}      -- [id] = local visual copy
local lastSent = {}         -- last state sent for local parts
local remoteLastSent = {}   -- last state seen/sent for remote copies

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
        or #b.id > 100
        or not allowedClasses[b.className] then
        return false
    end

    if type(b.size) ~= "table" or #b.size ~= 3
        or type(b.cframe) ~= "table" or #b.cframe ~= 12
        or type(b.color) ~= "table" or #b.color ~= 3 then
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

local function encodeBuild(build)
    local ok, encoded = pcall(function()
        return HttpService:JSONEncode(build)
    end)
    return ok and encoded or nil
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

    part.Transparency = math.clamp(tonumber(b.transparency) or 0, 0, 1)
    part.Reflectance = math.clamp(tonumber(b.reflectance) or 0, 0, 1)

    -- Local collision: each opted-in client collides with this local copy.
    -- Anchoring keeps the copies stable; it does not create shared server physics.
    part.Anchored = true
    part.CanCollide = true
    part.CanTouch = true
    part.CanQuery = true

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

    -- If this is one of our original local parts, update it in place.
    local ownPart = localById[b.id]
    if ownPart then
        pcall(applyBuild, ownPart, b)
        lastSent[ownPart] = encodeBuild(b)
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

    local applied = pcall(applyBuild, part, b)
    if applied then
        remoteLastSent[b.id] = encodeBuild(b)
    end
end

local function removeBuild(id)
    if type(id) ~= "string" then
        return
    end

    local ownPart = localById[id]
    if ownPart then
        lastSent[ownPart] = "__deleted"
        localById[id] = nil
        localParts[ownPart] = nil
        localPartCount = math.max(0, localPartCount - 1)
        pcall(function()
            ownPart:Destroy()
        end)
    end

    local remotePart = remoteParts[id]
    if remotePart then
        remoteParts[id] = nil
        remoteLastSent[id] = "__deleted"
        pcall(function()
            remotePart:Destroy()
        end)
    end
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
            for _, build in ipairs(message.builds) do
                createRemote(build)
            end
        end

    elseif message.type == "create" or message.type == "update" then
        if type(message.build) == "table" then
            createRemote(message.build)
        end

    elseif message.type == "delete" then
        removeBuild(message.id)
    end
end

socket.OnMessage:Connect(receive)
send({type = "join", room = ROOM})

-- Register only parts created by the patched F3X handlers.
local function registerLocalPart(part)
    if not part or not part:IsA("BasePart") or localParts[part] then
        return
    end
    if localPartCount >= MAX_PARTS then
        notify("Local sync limit reached")
        return
    end

    nextId += 1
    local id = myPrefix .. ":" .. tostring(nextId)

    localParts[part] = id
    localById[id] = part
    localPartCount += 1

    local snapshot = capture(part, id)
    if snapshot then
        lastSent[part] = encodeBuild(snapshot)
        send({type = "create", build = snapshot})
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

local sourceOk, source = pcall(function()
    return objects[1].Source
end)

if not sourceOk or type(source) ~= "string" then
    notify("Could not read F3X source; source access is unavailable")
    warn("[F3X Sync] Source read error: " .. tostring(source))
    return
end

-- Patch the exact F3X clone creation point.
local cloneNeedle = 'local rd=xj1:Clone%(%)rd%.Parent=Workspace'
local clonePatch =
    'local rd=xj1:Clone()rd.Parent=Workspace' ..
    ' if getgenv().F3XSyncRegisterPart then getgenv().F3XSyncRegisterPart(rd) end'

-- Patch the exact F3X New Part creation point.
local newPartNeedle = 'GxQqHPYH.Anchored=true'
local newPartPatch = newPartNeedle ..
    ' if getgenv().F3XSyncRegisterPart then getgenv().F3XSyncRegisterPart(GxQqHPYH) end'

local patchedSource, cloneCount = source:gsub(cloneNeedle, clonePatch, 1)
local newPartCount
patchedSource, newPartCount = patchedSource:gsub(newPartNeedle, newPartPatch, 1)

if cloneCount ~= 1 or newPartCount ~= 1 then
    notify("F3X source patch check failed")
    warn("[F3X Sync] Clone matches: " .. tostring(cloneCount)
        .. ", New Part matches: " .. tostring(newPartCount))
    return
end

local compileOk, compiled = pcall(loadstring, patchedSource)
if not compileOk or type(compiled) ~= "function" then
    notify("Could not compile patched F3X source")
    warn("[F3X Sync] Compile error: " .. tostring(compiled))
    return
end

local runOk, runError = pcall(compiled)
if not runOk then
    notify("F3X started with an error")
    warn("[F3X Sync] F3X load error: " .. tostring(runError))
    return
end

notify("Original F3X loaded; sync connected")

-- Poll locally-created parts and remote visual copies.
-- Editing a remote copy with F3X sends the changed state to everyone else.
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
                    send({type = "delete", id = id})
                    lastSent[part] = "__deleted"
                end
            else
                local snapshotOk, snapshot = pcall(capture, part, id)
                if snapshotOk and snapshot then
                    local encoded = encodeBuild(snapshot)
                    if encoded and encoded ~= lastSent[part] then
                        send({
                            type = lastSent[part] == "__deleted" and "create" or "update",
                            build = snapshot
                        })
                        lastSent[part] = encoded
                    end
                end
            end
        end

        for id, part in pairs(remoteParts) do
            local exists = false
            pcall(function()
                exists = part:IsDescendantOf(Workspace)
            end)

            if not exists then
                if remoteLastSent[id] ~= "__deleted" then
                    send({type = "delete", id = id})
                    remoteLastSent[id] = "__deleted"
                end
                remoteParts[id] = nil
            else
                local snapshotOk, snapshot = pcall(capture, part, id)
                if snapshotOk and snapshot then
                    local encoded = encodeBuild(snapshot)
                    if encoded and encoded ~= remoteLastSent[id] then
                        send({type = "update", build = snapshot})
                        remoteLastSent[id] = encoded
                    end
                end
            end
        end
    end
end)

print("[F3X Sync] Room: " .. ROOM)
