-- F3X Sync test client for Potassium.
-- Scope: F3X-created/cloned shared builds, supported mesh/effect children,
-- and opted-in clients' local Lighting settings. All copies remain client-side.

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local LocalPlayer = Players.LocalPlayer

local ENDPOINT = "wss://f3x-sync.onrender.com"
local ASSET_ID = "rbxassetid://6695644299"
local ROOM = "f3x-" .. tostring(game.PlaceId) .. "-" .. tostring(game.JobId)
local MAX_PARTS = 300
local UPDATE_INTERVAL = 0.15

local function notify(message)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title = "F3X Sync Test", Text = message, Duration = 5
        })
    end)
    print("[F3X Sync] " .. message)
end

if typeof(WebSocket) ~= "table" or typeof(WebSocket.connect) ~= "function" then
    notify("This executor does not support WebSocket.connect")
    return
end

local socketOk, socket = pcall(function() return WebSocket.connect(ENDPOINT) end)
if not socketOk or not socket then
    notify("Could not connect to the sync server")
    warn("[F3X Sync] " .. tostring(socket))
    return
end

local myPrefix = tostring(LocalPlayer.UserId) .. ":" .. tostring(math.floor(os.clock() * 100000))
local nextId = 0
local localParts, localById, remoteParts = {}, {}, {}
local lastSent, remoteLastSent = {}, {}
local localPartCount = 0

local visuals = Workspace:FindFirstChild("F3XSync_Visuals")
if not visuals then
    visuals = Instance.new("Folder")
    visuals.Name = "F3XSync_Visuals"
    visuals.Parent = Workspace
end

local function send(payload)
    payload.room = ROOM
    local ok, encoded = pcall(function() return HttpService:JSONEncode(payload) end)
    if ok then pcall(function() socket:Send(encoded) end) end
end

local function finite(n)
    return type(n) == "number" and n == n and n > -1000000 and n < 1000000
end

local function colorArray(c)
    return {c.R, c.G, c.B}
end

local function safeString(value, maxLength)
    return type(value) == "string" and string.sub(value, 1, maxLength) or ""
end

local allowedClasses = {
    Part = true, WedgePart = true, CornerWedgePart = true, TrussPart = true,
    Seat = true, VehicleSeat = true, SpawnLocation = true
}

local meshClasses = {SpecialMesh = true, BlockMesh = true, CylinderMesh = true}
local effectClasses = {Fire = true, Smoke = true, Sparkles = true}

local function captureChild(child)
    if meshClasses[child.ClassName] then
        local data = {className = child.ClassName, name = safeString(child.Name, 80)}
        if child:IsA("SpecialMesh") then
            data.meshType = child.MeshType.Name
            data.meshId = safeString(child.MeshId, 300)
            data.textureId = safeString(child.TextureId, 300)
            data.scale = {child.Scale.X, child.Scale.Y, child.Scale.Z}
            data.offset = {child.Offset.X, child.Offset.Y, child.Offset.Z}
            data.vertexColor = colorArray(child.VertexColor)
        else
            data.scale = {child.Scale.X, child.Scale.Y, child.Scale.Z}
            data.offset = {child.Offset.X, child.Offset.Y, child.Offset.Z}
        end
        return data
    elseif effectClasses[child.ClassName] then
        local data = {className = child.ClassName, name = safeString(child.Name, 80), enabled = child.Enabled}
        if child:IsA("Fire") then
            data.color = colorArray(child.Color)
            data.secondaryColor = colorArray(child.SecondaryColor)
            data.heat = child.Heat
            data.size = child.Size
        elseif child:IsA("Smoke") then
            data.color = colorArray(child.Color)
            data.opacity = child.Opacity
            data.riseVelocity = child.RiseVelocity
            data.size = child.Size
        elseif child:IsA("Sparkles") then
            data.sparkleColor = colorArray(child.SparkleColor)
        end
        return data
    end
    return nil
end

local function capture(part, id)
    if not part or not part:IsA("BasePart") then return nil end
    local s, c = part.Size, part.Color
    local children = {}
    for _, child in ipairs(part:GetChildren()) do
        local data = captureChild(child)
        if data then table.insert(children, data) end
    end
    return {
        id = id, className = part.ClassName, name = safeString(part.Name, 80),
        size = {s.X, s.Y, s.Z}, cframe = {part.CFrame:GetComponents()},
        color = {c.R, c.G, c.B}, material = part.Material.Name,
        transparency = part.Transparency, reflectance = part.Reflectance,
        shape = part:IsA("Part") and part.Shape.Name or nil,
        topSurface = part:IsA("Part") and part.TopSurface.Name or nil,
        bottomSurface = part:IsA("Part") and part.BottomSurface.Name or nil,
        children = children
    }
end

local function validVector(values, positive)
    if type(values) ~= "table" or #values ~= 3 then return false end
    for _, v in ipairs(values) do
        if not finite(v) or (positive and (v <= 0 or v > 2048)) then return false end
    end
    return true
end

local function validBuild(b)
    if type(b) ~= "table" or type(b.id) ~= "string" or #b.id > 100
        or not allowedClasses[b.className] then return false end
    if not validVector(b.size, true) or type(b.cframe) ~= "table" or #b.cframe ~= 12
        or not validVector(b.color, false) then return false end
    for _, v in ipairs(b.cframe) do if not finite(v) then return false end end
    for _, v in ipairs(b.color) do if v < 0 or v > 1 then return false end end
    return true
end

local function encode(value)
    local ok, result = pcall(function() return HttpService:JSONEncode(value) end)
    return ok and result or nil
end

local function validColor(values)
    if type(values) ~= "table" or #values ~= 3 then return false end
    for _, v in ipairs(values) do if not finite(v) or v < 0 or v > 1 then return false end end
    return true
end

local function applyChildren(part, children)
    if type(children) ~= "table" then children = {} end
    local wanted = {}
    for _, data in ipairs(children) do
        if type(data) == "table" and (meshClasses[data.className] or effectClasses[data.className]) then
            local key = data.className .. ":" .. safeString(data.name, 80)
            wanted[key] = true
            local child
            for _, existing in ipairs(part:GetChildren()) do
                if existing.ClassName == data.className and existing.Name == safeString(data.name, 80) then
                    child = existing
                    break
                end
            end
            if not child then
                local ok, created = pcall(Instance.new, data.className)
                if ok then child = created; child.Name = safeString(data.name, 80); child.Parent = part end
            end
            if child then
                pcall(function()
                    if meshClasses[data.className] then
                        if data.className == "SpecialMesh" then
                            child.MeshType = Enum.MeshType[data.meshType] or Enum.MeshType.FileMesh
                            child.MeshId = safeString(data.meshId, 300)
                            child.TextureId = safeString(data.textureId, 300)
                            if validVector(data.scale, false) then child.Scale = Vector3.new(table.unpack(data.scale)) end
                            if validVector(data.offset, false) then child.Offset = Vector3.new(table.unpack(data.offset)) end
                            if validColor(data.vertexColor) then child.VertexColor = Color3.new(table.unpack(data.vertexColor)) end
                        else
                            if validVector(data.scale, false) then child.Scale = Vector3.new(table.unpack(data.scale)) end
                            if validVector(data.offset, false) then child.Offset = Vector3.new(table.unpack(data.offset)) end
                        end
                    elseif effectClasses[data.className] then
                        child.Enabled = data.enabled == true
                        if data.className == "Fire" then
                            if validColor(data.color) then child.Color = Color3.new(table.unpack(data.color)) end
                            if validColor(data.secondaryColor) then child.SecondaryColor = Color3.new(table.unpack(data.secondaryColor)) end
                            if finite(data.heat) then child.Heat = math.clamp(data.heat, -25, 25) end
                            if finite(data.size) then child.Size = math.clamp(data.size, 0, 50) end
                        elseif data.className == "Smoke" then
                            if validColor(data.color) then child.Color = Color3.new(table.unpack(data.color)) end
                            if finite(data.opacity) then child.Opacity = math.clamp(data.opacity, 0, 1) end
                            if finite(data.riseVelocity) then child.RiseVelocity = math.clamp(data.riseVelocity, 0, 100) end
                            if finite(data.size) then child.Size = math.clamp(data.size, 0, 50) end
                        elseif data.className == "Sparkles" and validColor(data.sparkleColor) then
                            child.SparkleColor = Color3.new(table.unpack(data.sparkleColor))
                        end
                    end
                end)
            end
        end
    end
    for _, existing in ipairs(part:GetChildren()) do
        if meshClasses[existing.ClassName] or effectClasses[existing.ClassName] then
            local key = existing.ClassName .. ":" .. safeString(existing.Name, 80)
            if not wanted[key] then existing:Destroy() end
        end
    end
end

local function applyBuild(part, b)
    part.Name = safeString(b.name, 80)
    part.Size = Vector3.new(table.unpack(b.size))
    part.CFrame = CFrame.new(table.unpack(b.cframe))
    part.Color = Color3.new(table.unpack(b.color))
    pcall(function() part.Material = Enum.Material[b.material] end)
    part.Transparency = math.clamp(tonumber(b.transparency) or 0, 0, 1)
    part.Reflectance = math.clamp(tonumber(b.reflectance) or 0, 0, 1)
    -- Copies collide locally on each opted-in client; this is not server physics.
    part.Anchored, part.CanCollide, part.CanTouch, part.CanQuery = true, true, true, true
    if part:IsA("Part") then
        pcall(function() part.Shape = Enum.PartType[b.shape] end)
        pcall(function() part.TopSurface = Enum.SurfaceType[b.topSurface] end)
        pcall(function() part.BottomSurface = Enum.SurfaceType[b.bottomSurface] end)
    end
    applyChildren(part, b.children)
end

local function createRemote(b)
    if not validBuild(b) then return end
    local ownPart = localById[b.id]
    if ownPart then
        pcall(applyBuild, ownPart, b)
        local current = capture(ownPart, b.id)
        lastSent[ownPart] = current and encode(current) or encode(b)
        return
    end
    local part = remoteParts[b.id]
    if not part then
        if #visuals:GetChildren() >= MAX_PARTS then return end
        local ok, created = pcall(Instance.new, b.className)
        if not ok or not created then return end
        part = created
        part.Parent = visuals
        remoteParts[b.id] = part
    end
    local ok = pcall(applyBuild, part, b)
    if ok then
        local current = capture(part, b.id)
        remoteLastSent[b.id] = current and encode(current) or encode(b)
    end
end

local function removeBuild(id)
    if type(id) ~= "string" then return end
    local ownPart = localById[id]
    if ownPart then
        lastSent[ownPart] = "__deleted"
        localById[id], localParts[ownPart] = nil, nil
        localPartCount = math.max(0, localPartCount - 1)
        pcall(function() ownPart:Destroy() end)
    end
    local remotePart = remoteParts[id]
    if remotePart then
        remoteParts[id], remoteLastSent[id] = nil, "__deleted"
        pcall(function() remotePart:Destroy() end)
    end
end

-- A small, allowlisted set of local environment properties is synchronized.
local function captureLighting()
    return {
        clockTime = Lighting.ClockTime,
        brightness = Lighting.Brightness,
        ambient = colorArray(Lighting.Ambient),
        outdoorAmbient = colorArray(Lighting.OutdoorAmbient),
        colorShiftTop = colorArray(Lighting.ColorShift_Top),
        colorShiftBottom = colorArray(Lighting.ColorShift_Bottom),
        fogColor = colorArray(Lighting.FogColor),
        fogStart = Lighting.FogStart,
        fogEnd = Lighting.FogEnd,
        exposure = Lighting.ExposureCompensation,
        globalShadows = Lighting.GlobalShadows
    }
end

local function applyLighting(data)
    if type(data) ~= "table" then return end
    pcall(function()
        if finite(data.clockTime) then Lighting.ClockTime = data.clockTime % 24 end
        if finite(data.brightness) then Lighting.Brightness = math.clamp(data.brightness, 0, 10) end
        if validColor(data.ambient) then Lighting.Ambient = Color3.new(table.unpack(data.ambient)) end
        if validColor(data.outdoorAmbient) then Lighting.OutdoorAmbient = Color3.new(table.unpack(data.outdoorAmbient)) end
        if validColor(data.colorShiftTop) then Lighting.ColorShift_Top = Color3.new(table.unpack(data.colorShiftTop)) end
        if validColor(data.colorShiftBottom) then Lighting.ColorShift_Bottom = Color3.new(table.unpack(data.colorShiftBottom)) end
        if validColor(data.fogColor) then Lighting.FogColor = Color3.new(table.unpack(data.fogColor)) end
        if finite(data.fogStart) then Lighting.FogStart = math.clamp(data.fogStart, 0, 100000) end
        if finite(data.fogEnd) then Lighting.FogEnd = math.clamp(data.fogEnd, 0, 100000) end
        if finite(data.exposure) then Lighting.ExposureCompensation = math.clamp(data.exposure, -5, 5) end
        if type(data.globalShadows) == "boolean" then Lighting.GlobalShadows = data.globalShadows end
    end)
end

local lastLightingSent = nil
local applyingLighting = false

local function receive(raw)
    local ok, message = pcall(function() return HttpService:JSONDecode(raw) end)
    if not ok or type(message) ~= "table" then return end
    if message.type == "snapshot" then
        if type(message.builds) == "table" then
            for _, build in ipairs(message.builds) do createRemote(build) end
        end
        if type(message.lighting) == "table" then
            applyingLighting = true
            applyLighting(message.lighting)
            lastLightingSent = encode(captureLighting())
            applyingLighting = false
        else
            local initial = captureLighting()
            lastLightingSent = encode(initial)
            send({type = "lighting", lighting = initial})
        end
    elseif message.type == "create" or message.type == "update" then
        if type(message.build) == "table" then createRemote(message.build) end
    elseif message.type == "delete" then
        removeBuild(message.id)
    elseif message.type == "lighting" and type(message.lighting) == "table" then
        applyingLighting = true
        applyLighting(message.lighting)
        lastLightingSent = encode(captureLighting())
        applyingLighting = false
    end
end

socket.OnMessage:Connect(receive)
send({type = "join", room = ROOM})

local function registerLocalPart(part)
    if not part or not part:IsA("BasePart") or localParts[part] then return end
    if localPartCount >= MAX_PARTS then notify("Local sync limit reached"); return end
    nextId += 1
    local id = myPrefix .. ":" .. tostring(nextId)
    localParts[part], localById[id] = id, part
    localPartCount += 1
    local snapshot = capture(part, id)
    if snapshot then
        lastSent[part] = encode(snapshot)
        send({type = "create", build = snapshot})
    end
end

getgenv().F3XSyncRegisterPart = registerLocalPart

local assetOk, objects = pcall(function() return game:GetObjects(ASSET_ID) end)
if not assetOk or type(objects) ~= "table" or not objects[1] then
    notify("Could not load the original F3X asset")
    warn("[F3X Sync] Asset loading error: " .. tostring(objects))
    return
end

local sourceOk, source = pcall(function() return objects[1].Source end)
if not sourceOk or type(source) ~= "string" then
    notify("Could not read F3X source; source access is unavailable")
    warn("[F3X Sync] Source read error: " .. tostring(source))
    return
end

local cloneNeedle = 'local rd=xj1:Clone%(%)rd%.Parent=Workspace'
local clonePatch = 'local rd=xj1:Clone()rd.Parent=Workspace' ..
    ' if getgenv().F3XSyncRegisterPart then getgenv().F3XSyncRegisterPart(rd) end'
local newPartNeedle = 'GxQqHPYH.Anchored=true'
local newPartPatch = newPartNeedle ..
    ' if getgenv().F3XSyncRegisterPart then getgenv().F3XSyncRegisterPart(GxQqHPYH) end'

local patchedSource, cloneCount = source:gsub(cloneNeedle, clonePatch, 1)
local newPartCount
patchedSource, newPartCount = patchedSource:gsub(newPartNeedle, newPartPatch, 1)
if cloneCount ~= 1 or newPartCount ~= 1 then
    notify("F3X source patch check failed")
    warn("[F3X Sync] Clone matches: " .. tostring(cloneCount) ..
        ", New Part matches: " .. tostring(newPartCount))
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

notify("Test client connected; shared build/effect sync active")

task.spawn(function()
    while true do
        task.wait(UPDATE_INTERVAL)
        for part, id in pairs(localParts) do
            local exists = false
            pcall(function() exists = part:IsDescendantOf(Workspace) end)
            if not exists then
                if lastSent[part] ~= "__deleted" then
                    send({type = "delete", id = id})
                    lastSent[part] = "__deleted"
                end
            else
                local ok, snapshot = pcall(capture, part, id)
                if ok and snapshot then
                    local encoded = encode(snapshot)
                    if encoded and encoded ~= lastSent[part] then
                        send({type = "update", build = snapshot})
                        lastSent[part] = encoded
                    end
                end
            end
        end
        for id, part in pairs(remoteParts) do
            local exists = false
            pcall(function() exists = part:IsDescendantOf(Workspace) end)
            if not exists then
                if remoteLastSent[id] ~= "__deleted" then
                    send({type = "delete", id = id})
                    remoteLastSent[id] = "__deleted"
                end
                remoteParts[id] = nil
            else
                local ok, snapshot = pcall(capture, part, id)
                if ok and snapshot then
                    local encoded = encode(snapshot)
                    if encoded and encoded ~= remoteLastSent[id] then
                        send({type = "update", build = snapshot})
                        remoteLastSent[id] = encoded
                    end
                end
            end
        end
        if not applyingLighting then
            local current = encode(captureLighting())
            if current and current ~= lastLightingSent then
                send({type = "lighting", lighting = captureLighting()})
                lastLightingSent = current
            end
        end
    end
end)

print("[F3X Sync] Room: " .. ROOM)
