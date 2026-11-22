local Framework = GarageFramework
if not Framework.Core then return end

local T = DaGarageText

local activePlayers, activeSpawns = {}, {}
local activeVehicles = {}
local checkedOut = {}
local activeLayouts = {}
local nextRequest = {}
local interiorSessions = {}
local changingGarages = {}
local schemaError
local schemaReady = false
local vehicleTypes = { automobile = true, bike = true }
local isQB = Framework.Name == 'qbcore'
local vehicleTable = isQB and 'player_vehicles' or 'owned_vehicles'
local sqlParts = {
    vehicles = vehicleTable,
    status = isQB and 'state' or 'stored',
    props = isQB and 'mods' or 'vehicle',
    propsMatch = isQB and "BINARY COALESCE(mods, '')" or 'BINARY vehicle',
    propsRead = isQB and "COALESCE(mods, '') AS vehicle, vehicle AS modelName, hash AS modelHash, fuel, engine, body"
        or 'vehicle',
    statusRead = isQB and 'state AS stored' or 'stored',
    owner = isQB and 'COALESCE(dagarage_society, citizenid)' or 'owner',
    slotOwner = isQB and 'citizenid' or 'owner'
}

local DB = {}
for _, operation in ipairs({ 'query', 'single', 'scalar', 'update', 'insert' }) do
    DB[operation] = function(statement, parameters)
        return MySQL[operation].await((statement:gsub('{(%w+)}', sqlParts)), parameters)
    end
end

local function fleetScope(alias)
    local prefix = alias and alias .. '.' or ''
    if isQB then
        return ("COALESCE(%sdagarage_society, %scitizenid) = ?"):format(prefix, prefix)
    end
    local owner, job = prefix .. 'owner', prefix .. 'job'
    return owner .. ' = ? AND ' .. prefix .. "type = 'car' AND (COALESCE(" .. job ..
        ", '') = '' OR " .. owner .. " = CONCAT('society_', " .. job .. '))'
end

local fleet = fleetScope()
local fields = fleet .. ' AND plate = ?'

local function accessOwner(player, garage, management)
    if not garage.society then
        if not management and player.identifier:sub(1, 8) ~= 'society_' then return player.identifier end
        return
    end
    local society, job = garage.society, player.getJob()
    if management and type(society.manageGrade) ~= 'number' then return end
    local minimum = math.max(society.minGrade or 0, management and society.manageGrade or 0)
    if job and job.name == society.job and (tonumber(job.grade) or -1) >= minimum then
        return 'society_' .. society.job
    end
end

local function retrievalLocation(savedGarage, currentGarage)
    if Config.GarageMode ~= 'local' or savedGarage == nil or savedGarage == currentGarage then return end
    local home = Config.Garages[savedGarage]
    if not home then return end
    local fee = Config.RemoteRetrievalFee
    if type(fee) == 'number' and fee >= 0 then return home.label, math.tointeger(fee) end
    return home.label
end

local function advancedParking()
    if GetResourceState('AdvancedParking') == 'started' then return exports.AdvancedParking end
end

local function savedParkingPosition(plate)
    local parking = advancedParking()
    if parking then return parking:GetVehiclePosition(plate) end
end

local function configureParking()
    local parking = advancedParking()
    if not parking then return end
    -- AdvancedParking captures live mods. Replaying the original garage snapshot could undo them.
    parking:AddStateBagsToIgnoreList('VehicleProperties', 'myFuelTankStatus')
end

AddEventHandler('onResourceStart', function(resource)
    if resource == 'AdvancedParking' or resource == GetCurrentResourceName() then configureParking() end
end)

local function normalizedPlate(plate)
    return type(plate) == 'string' and plate:match('^%s*(.-)%s*$'):upper() or ''
end

local function checkoutPlate(vehicle)
    local checkout = checkedOut[vehicle]
    if checkout and NetworkGetNetworkIdFromEntity(vehicle) == checkout.netId then return checkout.plate end
end

local checkoutSnapshotKey = 'checked_out_snapshot'
local checkoutEpoch = GlobalState.daGarageCheckoutEpoch
if not checkoutEpoch then
    checkoutEpoch = ('%d:%d:%d'):format(os.time(), GetGameTimer(), math.random(0, 0x7fffffff))
    GlobalState.daGarageCheckoutEpoch = checkoutEpoch
end

local snapshot = GetResourceKvpString(checkoutSnapshotKey)
if snapshot then
    local ok, saved = pcall(json.decode, snapshot)
    if ok and type(saved) == 'table' and saved.epoch == checkoutEpoch and type(saved.vehicles) == 'table' then
        for _, checkout in ipairs(saved.vehicles) do
            local vehicle = NetworkGetEntityFromNetworkId(checkout.netId)
            if vehicle ~= 0 and vehicle == checkout.entity and DoesEntityExist(vehicle)
                and (GetEntityModel(vehicle) & 0xffffffff) == checkout.model then
                checkedOut[vehicle] = checkout
            end
        end
    end
    DeleteResourceKvp(checkoutSnapshotKey)
end

AddEventHandler('entityRemoved', function(vehicle)
    checkedOut[vehicle] = nil
end)

local function favoriteKey(owner, props)
    return ('favorite:%s:%d:%s'):format(owner, props.model & 0xffffffff, normalizedPlate(props.plate))
end

local function properties(row)
    local ok, props = pcall(json.decode, row.vehicle or '')
    if isQB then
        if not ok or type(props) ~= 'table' then props = {} end
        ok = true
        Framework.FromQBProperties(props)
        props.model = tonumber(row.modelHash) or tonumber(row.modelName)
            or (row.modelName and row.modelName ~= '' and joaat(row.modelName)) or props.model
        props.fuelLevel = tonumber(row.fuel) or props.fuelLevel
        props.engineHealth = tonumber(row.engine) or props.engineHealth
        props.bodyHealth = tonumber(row.body) or props.bodyHealth
    end
    if not ok or type(props) ~= 'table' or type(props.model) ~= 'number' or not math.tointeger(props.model) then return end
    props.plate = row.plate
    -- Older ownership records can contain only a model and plate. Do not reroll their paint on each spawn.
    props.color1 = tonumber(props.color1) or 0
    props.color2 = tonumber(props.color2) or props.color1
    return props
end

local function context(source, garageId)
    local garage = Config.Garages[garageId]
    local player = Framework.GetPlayer(source)
    local ped = GetPlayerPed(source)
    if garage and player and ped ~= 0 and GetPlayerRoutingBucket(source) == 0
        and #(GetEntityCoords(ped) - garage.marker) <= Config.InteractionDistance then
        local owner = accessOwner(player, garage)
        if owner then return garage, owner, ped, player end
    end
end

local function interiorMember(source, garageId, allowReturn)
    local session = interiorSessions[source]
    local player = Framework.GetPlayer(source)
    if session and session.garageId == garageId and player and player.identifier == session.character
        and (allowReturn or GetPlayerRoutingBucket(source) == session.bucket) then
        return session, GetPlayerPed(source), player
    end
end

local function inside(source, garageId)
    local session, ped, player = interiorMember(source, garageId)
    if session and ped ~= 0 and accessOwner(player, Config.Garages[garageId]) == session.owner then
        return session, ped, player
    end
end

local function lockVehicle(request, plate)
    local key = normalizedPlate(plate)
    if activeVehicles[key] and activeVehicles[key] ~= request then return false end
    if request.plate then activeVehicles[request.plate] = nil end
    request.plate = key
    activeVehicles[key] = request
    return true
end

local function lockLayout(request, owner, garageId)
    local key = owner .. ':' .. garageId
    if activeLayouts[key] then return false end
    request.layout = key
    request.layoutGarage = garageId
    activeLayouts[key] = true
    return true
end

local function garageHasSpace(request, owner, garageId)
    local capacity = Config.GetGarageCapacity(Config.Garages[garageId])
    if not capacity then return true end
    if not lockLayout(request, owner, garageId) then
        return false, T('Die Fahrzeugbelegung wird gerade geändert. Versuche es erneut.')
    end
    local parked = tonumber(DB.scalar('SELECT COUNT(*) FROM {vehicles} WHERE ' .. fleet ..
        ' AND {status} = 1 AND dagarage_location = ?', { owner, garageId }))
    if parked >= capacity then
        return false, (T('Diese Garage ist voll (%d/%d Fahrzeuge).')):format(parked, capacity)
    end
    return true
end

local function recoveryKey(owner)
    return 'interior:' .. owner
end

local function interiorReturn(owner)
    local value = GetResourceKvpString(recoveryKey(owner))
    if not value then return end
    if value:sub(1, 1) ~= '{' then return { garageId = value } end
    local ok, saved = pcall(json.decode, value)
    if ok then return saved end
end

local function releaseInterior(source)
    interiorSessions[source] = nil
    SetPlayerRoutingBucket(source, 0)
end

local function garageCallback(name, action, allowed)
    Framework.RegisterCallback('DaGarage:' .. name, function(source, reply, garageId, ...)
        if not schemaReady then
            return reply(false, schemaError or T('Die Garagendatenbank wird gerade vorbereitet.'))
        end
        local now = GetGameTimer()
        if activePlayers[source] or (nextRequest[source] or 0) > now then
            return reply(false, T('Bitte warte einen Moment.'))
        end
        if type(garageId) ~= 'string' or changingGarages[garageId] or not (allowed or context)(source, garageId) then
            return reply(false, T('Du hast hier gerade keinen Zugang zur Garage.'))
        end
        local request = { garageId = garageId }
        activePlayers[source] = request
        nextRequest[source] = now + 350
        local ok, result, message = pcall(action, source, garageId, request, ...)
        if activeSpawns[garageId] == request then activeSpawns[garageId] = nil end
        if request.plate then activeVehicles[request.plate] = nil end
        if request.layout then activeLayouts[request.layout] = nil end
        activePlayers[source] = nil
        if not ok then
            print(('[DaGarage] %s: %s'):format(name, result))
            return reply(false, T('Die Garage ist momentan nicht verfügbar.'))
        end
        reply(result, message)
    end)
end

AddEventHandler('playerDropped', function()
    nextRequest[source] = nil
    interiorSessions[source] = nil
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    local vehicles = {}
    for vehicle, checkout in pairs(checkedOut) do
        if DoesEntityExist(vehicle) and checkoutPlate(vehicle) then vehicles[#vehicles + 1] = checkout end
    end
    if #vehicles > 0 then
        SetResourceKvp(checkoutSnapshotKey, json.encode({ epoch = checkoutEpoch, vehicles = vehicles }))
    end
    for source in pairs(interiorSessions) do SetPlayerRoutingBucket(source, 0) end
end)

Framework.RegisterCallback('DaGarage:recoverInterior', function(source, reply)
    local player = Framework.GetPlayer(source)
    if not player or interiorSessions[source] then return reply(false) end
    local saved = interiorReturn(player.identifier)
    if not saved then return reply(false) end
    local garage = Config.Garages[saved.garageId]
    local profile = garage and Config.Interiors[garage.interior]
    local door = saved.door and vector3(saved.door.x, saved.door.y, saved.door.z) or (profile and profile.door)
    local marker = garage and garage.marker or saved.marker
    local ped = GetPlayerPed(source)
    if ped == 0 then return reply(false) end
    if not marker or not door or #(GetEntityCoords(ped) - door) > 150.0 then
        DeleteResourceKvp(recoveryKey(player.identifier))
        return reply(false)
    end
    reply({ garageId = saved.garageId, marker = { x = marker.x, y = marker.y, z = marker.z } })
end)

Framework.RegisterCallback('DaGarage:completeInteriorReturn', function(source, reply, garageId)
    local player, garage, ped = Framework.GetPlayer(source), Config.Garages[garageId], GetPlayerPed(source)
    if not player or ped == 0 or interiorSessions[source] or GetPlayerRoutingBucket(source) ~= 0 then return reply(false) end
    local saved = interiorReturn(player.identifier)
    if not saved or saved.garageId ~= garageId then return reply(false) end
    local marker, spawn = garage and garage.marker or saved.marker, garage and garage.spawn
    local coords = GetEntityCoords(ped)
    local atMarker = marker and #(coords - vector3(marker.x, marker.y, marker.z)) <= 10.0
    local atSpawn = spawn and #(coords - vector3(spawn.x, spawn.y, spawn.z)) <= 10.0
    if not atMarker and not atSpawn then
        return reply(false)
    end
    DeleteResourceKvp(recoveryKey(player.identifier))
    reply(true)
end)

garageCallback('interiorEnter', function(source, garageId, request)
    local garage, owner, ped, player = context(source, garageId)
    local profile = Config.Interiors[garage.interior]
    if not profile or #profile.slots == 0 or (profile.resource and GetResourceState(profile.resource) ~= 'started') then
        return false, T('Der Garageninnenraum ist gerade nicht verfügbar.')
    end
    if GetVehiclePedIsIn(ped, false) ~= 0 then return false, T('Bitte steige zuerst aus.') end
    if not lockLayout(request, owner, garageId) then return false, T('Die Stellplätze werden gerade geladen. Versuche es erneut.') end
    local rows = DB.query([[
        SELECT plate, {propsRead}, {statusRead}, dagarage_slot FROM {vehicles}
        WHERE
    ]] .. fleet .. ' AND dagarage_location = ? ORDER BY plate', { owner, garageId })
    local capacity = Config.GetGarageCapacity(garage)
    local vehicles, occupied, reserved = {}, {}, {}
    for _, row in ipairs(rows) do
        local slot = tonumber(row.dagarage_slot)
        if slot and slot >= 1 and slot <= capacity then occupied[slot] = row end
    end
    local function freeSlot()
        for slot = 1, capacity do
            if not occupied[slot] then return slot end
        end
        for slot = 1, capacity do
            local parked = occupied[slot]
            if tonumber(parked.stored) ~= 1 then
                local changed = DB.update('UPDATE {vehicles} SET dagarage_slot = NULL WHERE ' .. fields ..
                    ' AND {status} <> 1 AND dagarage_location = ? AND dagarage_slot = ?', { owner, parked.plate, garageId, slot })
                if changed == 1 then
                    occupied[slot], parked.dagarage_slot = nil, nil
                    return slot
                end
            end
        end
    end
    local outside = {}
    for _, vehicle in ipairs(GetAllVehicles()) do
        outside[normalizedPlate(GetVehicleNumberPlateText(vehicle))] = true
        local plate = checkoutPlate(vehicle)
        if plate then outside[normalizedPlate(plate)] = true end
    end
    for _, row in ipairs(rows) do
        local props = properties(row)
        if tonumber(row.stored) == 1 and props and not outside[normalizedPlate(row.plate)]
            and not savedParkingPosition(row.plate) then
            local slot = tonumber(row.dagarage_slot)
            if not slot or slot < 1 or slot > capacity then
                local target, previous = freeSlot(), slot or 0
                slot = nil
                if target then
                    local changed = DB.update('UPDATE IGNORE {vehicles} SET dagarage_slot = ? WHERE ' .. fields ..
                        ' AND {status} = 1 AND dagarage_location = ? AND dagarage_slot <=> NULLIF(?, 0)',
                        { target, owner, row.plate, garageId, previous })
                    if changed == 1 then
                        slot = target
                        occupied[slot] = row
                    end
                end
            end
            if slot then vehicles[#vehicles + 1] = { slot = slot, props = props } end
        end
    end
    for slot in pairs(occupied) do reserved[#reserved + 1] = slot end
    local _, currentOwner, currentPed, currentPlayer = context(source, garageId)
    if currentOwner ~= owner or currentPlayer.identifier ~= player.identifier or GetVehiclePedIsIn(currentPed, false) ~= 0 then
        return false, T('Du bist zu weit von der Garage entfernt.')
    end
    local bucket = Config.InteriorBucketBase + source
    local marker, door = garage.marker, profile.door
    SetResourceKvp(recoveryKey(player.identifier), json.encode({
        garageId = garageId,
        marker = { x = marker.x, y = marker.y, z = marker.z },
        door = { x = door.x, y = door.y, z = door.z }
    }))
    SetRoutingBucketPopulationEnabled(bucket, false)
    SetRoutingBucketEntityLockdownMode(bucket, 'strict')
    SetPlayerRoutingBucket(source, bucket)
    interiorSessions[source] = {
        garageId = garageId, character = player.identifier, owner = owner, bucket = bucket, profile = profile
    }
    return { vehicles = vehicles, reserved = reserved }
end)

garageCallback('assignSlot', function(source, garageId, request, plate, slot, previousSlot)
    local session, ped, player = inside(source, garageId)
    if type(plate) ~= 'string' or #plate > 12 or type(slot) ~= 'number'
        or slot < 1 or slot % 1 ~= 0 or type(previousSlot) ~= 'number' or ped == 0 then
        return false, T('Ungültiger Stellplatz.')
    end
    local garage = Config.Garages[garageId]
    if garage.society and not accessOwner(player, garage, true) then
        return false, T('Dein Rang erlaubt keine Stellplatzänderungen.')
    end
    if not lockVehicle(request, plate) then return false, T('Dieses Fahrzeug wird gerade benutzt.') end
    if slot > Config.GetGarageCapacity(garage) then return false, T('Dieser Stellplatz existiert in dieser Garage nicht.') end
    if not lockLayout(request, session.owner, garageId) then return false, T('Die Stellplätze werden gerade geändert.') end
    local taken = DB.scalar([[
        SELECT 1 FROM {vehicles} WHERE {owner} = ? AND dagarage_location = ? AND dagarage_slot = ? LIMIT 1
    ]], { session.owner, garageId, slot })
    if taken then return false, T('Dieser Stellplatz ist bereits reserviert.') end
    local current, _, currentPlayer = inside(source, garageId)
    if not current or (garage.society and not accessOwner(currentPlayer, garage, true)) then
        return false, T('Du bist nicht mehr für diese Änderung berechtigt.')
    end
    local changed = DB.update('UPDATE IGNORE {vehicles} SET dagarage_slot = ? WHERE ' .. fields ..
        ' AND {status} = 1 AND dagarage_location = ? AND dagarage_slot = ?', { slot, session.owner, plate, garageId, previousSlot })
    if changed ~= 1 then return false, T('Der Fahrzeugstand hat sich geändert. Öffne die Garage erneut.') end
    return slot
end, inside)

garageCallback('interiorLeave', function(source)
    releaseInterior(source)
    return true
end, function(source, garageId)
    return interiorMember(source, garageId, true)
end)

garageCallback('list', function(source, garageId)
    local garage, owner = context(source, garageId)
    local rows = DB.query([[
        SELECT plate, {propsRead}, {statusRead}, dagarage_location FROM {vehicles}
        WHERE
    ]] .. fleet .. ' ORDER BY plate', { owner })
    local plates, list = {}, {}
    for _, row in ipairs(rows) do plates[#plates + 1] = row.plate end
    if #plates == 0 then return list end
    local tanks = Config.UseMyFuelTankData and GetResourceState('myFuel') == 'started' and DB.query([[
        SELECT t.plate, t.model, t.required_fuel, t.dispensed_fuel, t.fuel_level, t.drive_seconds_left
        FROM myfuel_vehicle_tanks t
        JOIN {vehicles} v ON BINARY t.plate = BINARY UPPER(TRIM(v.plate))
        WHERE
    ]] .. fleetScope('v'), { owner }) or {}
    local tankByVehicle = {}
    for _, tank in ipairs(tanks) do
        tankByVehicle[tank.plate .. ':' .. tank.model] = tank
    end
    local parking = advancedParking()
    local positions = parking and parking:GetVehiclePositions(plates) or {}
    local knownPositions, outsidePlates, liveVehicles = {}, {}, {}
    for plate in pairs(positions) do
        local normalized = normalizedPlate(plate)
        knownPositions[normalized] = true
        outsidePlates[normalized] = true
    end
    for _, vehicle in ipairs(GetAllVehicles()) do
        local plate = normalizedPlate(GetVehicleNumberPlateText(vehicle))
        local model = GetEntityModel(vehicle) & 0xffffffff
        outsidePlates[plate] = true
        liveVehicles[plate .. ':' .. model] = vehicle
        local canonical = checkoutPlate(vehicle)
        if canonical then
            canonical = normalizedPlate(canonical)
            outsidePlates[canonical] = true
            liveVehicles[canonical .. ':' .. model] = vehicle
        end
    end
    for _, row in ipairs(rows) do
        local props = properties(row)
        if props then
            local status = tonumber(row.stored) or 0
            local plate = normalizedPlate(row.plate)
            local key = plate .. ':' .. (props.model & 0xffffffff)
            local outside = outsidePlates[plate]
            local tank, live = tankByVehicle[key], liveVehicles[key]
            local liveFuel = live and Entity(live).state.fuel
            local fuel = type(liveFuel) == 'number' and liveFuel or (tank and tonumber(tank.fuel_level)) or props.fuelLevel
            local wrongFuel = tank and tank.dispensed_fuel ~= nil
            local home, fee = retrievalLocation(row.dagarage_location, garageId)
            if status == 2 or outside then home, fee = nil, nil end
            local parkedGarage = Config.Garages[row.dagarage_location]
            list[#list + 1] = {
                model = props.model, plate = row.plate,
                status = status == 2 and 'impounded' or outside and 'outside'
                    or status == 1 and 'stored' or 'missing',
                parkedInside = status == 1 and not outside and row.dagarage_location == garageId,
                remoteGarage = home,
                remoteFee = fee,
                parkedElsewhere = not garage.society and status == 1 and not outside and parkedGarage ~= nil
                    and row.dagarage_location ~= garageId,
                parkedLabel = not garage.society and parkedGarage and parkedGarage.label or nil,
                favorite = not garage.society and GetResourceKvpInt(favoriteKey(owner, props)) == 1,
                hasPosition = knownPositions[plate] or live ~= nil,
                fuel = fuel,
                fuelLive = type(liveFuel) == 'number',
                engine = live and GetVehicleEngineHealth(live) or props.engineHealth,
                body = live and GetVehicleBodyHealth(live) or props.bodyHealth,
                conditionLive = live ~= nil,
                wrongFuel = wrongFuel,
                blocked = wrongFuel and (tonumber(tank.drive_seconds_left) or 0) <= 0,
                requiredFuel = wrongFuel and tank.required_fuel or nil,
                dispensedFuel = wrongFuel and tank.dispensed_fuel or nil,
                tuning = {
                    engine = props.modEngine, brakes = props.modBrakes,
                    transmission = props.modTransmission, turbo = props.modTurbo,
                    primary = props.customPrimaryColor or props.color1,
                    secondary = props.customSecondaryColor or props.color2
                }
            }
        end
    end
    return list
end)

garageCallback('setFavorite', function(source, garageId, _, plate, favorite)
    if type(plate) ~= 'string' or #plate > 12 or type(favorite) ~= 'boolean' then
        return false, T('Ungültiger Favorit.')
    end
    local garage, owner = context(source, garageId)
    if garage.society then return false, T('Favoriten sind für private Fahrzeuge verfügbar.') end
    local row = DB.single('SELECT plate, {propsRead} FROM {vehicles} WHERE ' .. fields, { owner, plate })
    local _, currentOwner = context(source, garageId)
    local props = row and properties(row)
    if not props or owner ~= currentOwner then return false, T('Dieses Fahrzeug ist nicht verfügbar.') end
    local key = favoriteKey(owner, props)
    if favorite then SetResourceKvpInt(key, 1) else DeleteResourceKvp(key) end
    return true
end)

garageCallback('preview', function(source, garageId, _, plate)
    if type(plate) ~= 'string' or #plate > 12 then return false, T('Ungültiges Kennzeichen.') end
    local _, owner = context(source, garageId)
    local row = DB.single('SELECT plate, {propsRead} FROM {vehicles} WHERE ' .. fields, { owner, plate })
    return (row and properties(row)) or false, T('Für dieses Fahrzeug ist keine Vorschau verfügbar.')
end)

garageCallback('waypoint', function(source, garageId, _, plate)
    if type(plate) ~= 'string' or #plate > 12 then return false, T('Ungültiges Kennzeichen.') end
    local _, owner = context(source, garageId)
    local row = DB.single('SELECT plate, {statusRead}, {propsRead} FROM {vehicles} WHERE ' .. fields, { owner, plate })
    local _, currentOwner = context(source, garageId)
    local props = row and properties(row)
    if not props or tonumber(row.stored) == 2 or currentOwner ~= owner then
        return false, T('Dieses Fahrzeug ist nicht verfügbar.')
    end
    local position = savedParkingPosition(row.plate)
    if not position then
        local key = normalizedPlate(row.plate)
        for _, vehicle in ipairs(GetAllVehicles()) do
            if (normalizedPlate(GetVehicleNumberPlateText(vehicle)) == key or normalizedPlate(checkoutPlate(vehicle)) == key)
                and (GetEntityModel(vehicle) & 0xffffffff) == (props.model & 0xffffffff) then
                position = GetEntityCoords(vehicle)
                break
            end
        end
    end
    if not position then return false, T('Für dieses Fahrzeug ist gerade kein Standort bekannt.') end
    return { x = position.x, y = position.y }
end)

local function modelType(model, source)
    local result = promise.new()
    local resolved = false
    local function finish(kind)
        if resolved then return end
        resolved = true
        result:resolve(kind or false)
    end
    SetTimeout(4500, function() finish(false) end)
    Framework.GetVehicleType(model, source, finish)
    return Citizen.Await(result)
end

garageCallback('societyAddVehicle', function(source, garageId, request, spawnName)
    local garage, owner, _, player = context(source, garageId)
    if not accessOwner(player, garage, true) then return false, T('Dein Rang erlaubt keine Fahrzeugaufnahme.') end
    local allowed = false
    for _, model in ipairs(garage.society.models or {}) do
        if model == spawnName then
            allowed = true
            break
        end
    end
    if not allowed or type(spawnName) ~= 'string' then return false, T('Dieses Modell ist für den Fuhrpark nicht freigegeben.') end

    local hash = joaat(spawnName)
    if not vehicleTypes[modelType(hash, source)] then return false, T('Das Fahrzeugmodell ist hier nicht verfügbar.') end
    local space, reason = garageHasSpace(request, owner, garageId)
    if not space then return false, reason end
    for _ = 1, 8 do
        local _, currentOwner, _, currentPlayer = context(source, garageId)
        if currentOwner ~= owner or currentPlayer.identifier ~= player.identifier or not accessOwner(currentPlayer, garage, true) then
            return false, T('Du hast hier gerade keinen Zugang zum Fuhrpark.')
        end
        local plate = ('DG%06d'):format(math.random(0, 999999))
        if lockVehicle(request, plate) and not savedParkingPosition(plate)
            and not DB.scalar('SELECT 1 FROM {vehicles} WHERE plate = ? LIMIT 1', { plate }) then
            local props = json.encode({ model = hash, plate = plate })
            local added
            if isQB then
                added = DB.update([[
                    INSERT IGNORE INTO player_vehicles
                        (dagarage_society, plate, vehicle, hash, mods, state, dagarage_location)
                    VALUES (?, ?, ?, ?, ?, 1, ?)
                ]], { owner, plate, spawnName, tostring(hash), props, garageId })
            else
                added = DB.update([[
                    INSERT IGNORE INTO owned_vehicles (owner, plate, vehicle, type, job, stored, dagarage_location)
                    VALUES (?, ?, ?, 'car', ?, 1, ?)
                ]], { owner, plate, props, garage.society.job, garageId })
            end
            if added == 1 then return plate end
        end
    end
    return false, T('Für das Fahrzeug konnte kein Kennzeichen vergeben werden.')
end)

local function retrieve(source, garageId, request, plate, recovery, quotedFee, fromInterior)
    if type(plate) ~= 'string' or #plate > 12 then return false, T('Ungültiges Kennzeichen.') end
    if activeSpawns[garageId] then return false, T('Die Ausfahrt wird gerade benutzt.') end
    if not lockVehicle(request, plate) then return false, T('Dieses Fahrzeug wird gerade benutzt.') end
    activeSpawns[garageId] = request
    local garage, owner, ped, player = context(source, garageId)
    if fromInterior then
        local session = inside(source, garageId)
        if not session then return false, T('Du bist nicht mehr in dieser Garage.') end
        garage, owner = Config.Garages[garageId], session.owner
    elseif GetVehiclePedIsIn(ped, false) ~= 0 then
        return false, T('Bitte steige zuerst aus.')
    end

    local row = DB.single('SELECT plate, {propsRead}, {statusRead}, dagarage_location FROM {vehicles} WHERE ' ..
        fields, { owner, plate })
    local props = row and properties(row)
    if not props then return false, T('Dieses Fahrzeug ist nicht verfügbar.') end
    local stored = tonumber(row.stored)
    if fromInterior and (stored ~= 1 or row.dagarage_location ~= garageId) then
        return false, T('Dieses Fahrzeug steht nicht mehr in dieser Garage.')
    end
    if stored ~= 1 and not (stored == 0 and recovery == true and Config.RecoverMissingVehicles) then
        return false, T('Dieses Fahrzeug steht nicht zur Abholung bereit.')
    end
    local home, fee = retrievalLocation(row.dagarage_location, garageId)
    if home and fee == nil then return false, (T('Dieses Fahrzeug steht bei %s.')):format(home) end
    if quotedFee ~= fee then return false, T('Die Abholbedingungen haben sich geändert. Öffne die Garage erneut.') end
    local kind = modelType(props.model, source)
    if not vehicleTypes[kind] then return false, T('Dieses Modell wird an dieser Garage nicht unterstützt.') end

    local function ready()
        if fromInterior then return inside(source, garageId) ~= nil end
        local _, currentOwner, currentPed, currentPlayer = context(source, garageId)
        return currentOwner == owner and currentPlayer.identifier == player.identifier and GetVehiclePedIsIn(currentPed, false) == 0
    end
    if not ready() then return false, T('Du bist zu weit von der Garage entfernt.') end
    local spawn = garage.spawn
    local position = vector3(spawn.x, spawn.y, spawn.z)
    local function spawnObstruction()
        if savedParkingPosition(row.plate) then return T('Das Fahrzeug ist bereits draußen.') end
        local plateKey = normalizedPlate(row.plate)
        for _, vehicle in ipairs(GetAllVehicles()) do
            if normalizedPlate(GetVehicleNumberPlateText(vehicle)) == plateKey
                or normalizedPlate(checkoutPlate(vehicle)) == plateKey then
                return T('Das Fahrzeug ist bereits draußen.')
            end
            if GetEntityRoutingBucket(vehicle) == 0 and #(GetEntityCoords(vehicle) - position) <= Config.SpawnClearance then
                return T('Am Ausparkpunkt steht bereits ein Fahrzeug.')
            end
        end
    end
    local obstruction = spawnObstruction()
    if obstruction then return false, obstruction end

    local savedGarage = stored == 1 and Config.Garages[row.dagarage_location]
    if savedGarage and Config.GetGarageCapacity(savedGarage) and not lockLayout(request, owner, row.dagarage_location) then
        return false, T('Die Fahrzeugbelegung wird gerade geändert. Versuche es erneut.')
    end

    -- Keep the previous database state if creation fails. Reserve the car before spawning it.
    if stored == 1 and DB.update('UPDATE {vehicles} SET {status} = 0 WHERE ' .. fields ..
        " AND {status} = 1 AND {propsMatch} = ? AND dagarage_location <=> NULLIF(?, '')",
        { owner, row.plate, row.vehicle, row.dagarage_location or '' }) ~= 1 then
        return false, T('Der Fahrzeugstand hat sich geändert. Öffne die Garage erneut.')
    end
    local vehicle = 0
    local failure
    local ok, netId = pcall(function()
        if not ready() then return end
        obstruction = spawnObstruction()
        if obstruction then return end
        local player = Framework.GetPlayer(source)
        if fee and fee > 0 and player.getMoney() < fee then
            failure = (T('Du brauchst $%d in bar, um das Fahrzeug hier abzuholen.')):format(fee)
            return
        end
        vehicle = CreateVehicleServerSetter(props.model, kind, spawn.x, spawn.y, spawn.z, spawn.w)
        if vehicle == 0 or not DoesEntityExist(vehicle) then return end
        SetEntityOrphanMode(vehicle, 2)
        SetVehicleNumberPlateText(vehicle, row.plate)
        local state = Entity(vehicle).state
        if type(props.fuelLevel) == 'number' then
            state:set('fuel', math.max(0, math.min(100, props.fuelLevel)), true)
        end
        state:set('VehicleProperties', props, true)
        local id = NetworkGetNetworkIdFromEntity(vehicle)
        if id == 0 then return end
        if fee and fee > 0 and player.removeMoney(fee, T('DaGarage Fremdausparken')) == false then return end
        return id
    end)
    if ok and netId and netId ~= 0 then
        local checkout = { entity = vehicle, netId = netId, plate = row.plate, model = props.model & 0xffffffff }
        checkedOut[vehicle] = checkout
        if Framework.GrantVehicleKeys then Framework.GrantVehicleKeys(source, row.plate) end
        SetTimeout(350, function()
            if checkedOut[vehicle] == checkout and DoesEntityExist(vehicle) and checkoutPlate(vehicle)
                and normalizedPlate(GetVehicleNumberPlateText(vehicle)) ~= normalizedPlate(checkout.plate) then
                SetVehicleNumberPlateText(vehicle, checkout.plate)
            end
        end)
        if fromInterior then releaseInterior(source) end
        return { netId = netId, properties = props }
    end
    if vehicle ~= 0 and DoesEntityExist(vehicle) then DeleteEntity(vehicle) end
    if stored == 1 then
        DB.update('UPDATE {vehicles} SET {status} = 1 WHERE ' .. fields ..
            " AND {status} = 0 AND dagarage_location <=> NULLIF(?, '')",
            { owner, row.plate, row.dagarage_location or '' })
    end
    if not ok then print(('[DaGarage] Spawn: %s'):format(netId)) end
    return false, failure or obstruction or T('Das Fahrzeug konnte nicht ausgeparkt werden.')
end

garageCallback('retrieve', function(source, garageId, request, plate, recovery, quotedFee)
    return retrieve(source, garageId, request, plate, recovery, quotedFee, false)
end)

garageCallback('interiorDriveOut', function(source, garageId, request, plate)
    return retrieve(source, garageId, request, plate, false, nil, true)
end, inside)

local function bounded(value, minimum, maximum)
    if type(value) == 'number' and value >= minimum and value <= maximum then return value end
end

local numericVehicleProperties = {
    'plateIndex', 'color1', 'color2', 'pearlescentColor', 'wheelColor', 'dashboardColor', 'interiorColor',
    'wheels', 'windowTint', 'xenonColor', 'modSpoilers', 'modFrontBumper', 'modRearBumper',
    'modSideSkirt', 'modExhaust', 'modFrame', 'modGrille', 'modHood', 'modFender', 'modRightFender',
    'modRoof', 'modRoofLivery', 'modEngine', 'modBrakes', 'modTransmission', 'modHorns',
    'modSuspension', 'modArmor', 'modFrontWheels', 'modBackWheels', 'modPlateHolder', 'modVanityPlate',
    'modTrimA', 'modOrnaments', 'modDashboard', 'modDial', 'modDoorSpeaker', 'modSeats',
    'modSteeringWheel', 'modShifterLeavers', 'modAPlate', 'modSpeakers', 'modTrunk', 'modHydrolic',
    'modEngineBlock', 'modAirFilter', 'modStruts', 'modArchCover', 'modAerials', 'modTrimB',
    'modTank', 'modWindows', 'modLivery', 'modLightbar'
}
local booleanVehicleProperties = {
    'tyresCanBurst', 'modTurbo', 'modSmokeEnabled', 'modXenon', 'modCustomFrontWheels', 'modCustomBackWheels'
}
local vehicleColorProperties = { 'customPrimaryColor', 'customSecondaryColor', 'customXenonColor', 'neonColor', 'tyreSmokeColor' }
local vehicleBooleanMaps = { extras = 20, windowsBroken = 7, doorsBroken = 15, tyreBurst = 7 }

local function mergeVehicleSnapshot(saved, snapshot)
    for _, key in ipairs(numericVehicleProperties) do
        local value = bounded(snapshot[key], -1, 65535)
        if value and math.tointeger(value) then saved[key] = value end
    end
    for _, key in ipairs(booleanVehicleProperties) do
        if type(snapshot[key]) == 'boolean' then saved[key] = snapshot[key] end
    end
    for _, key in ipairs(vehicleColorProperties) do
        local rgb = snapshot[key]
        if rgb == false then
            saved[key] = nil
        elseif type(rgb) == 'table' and bounded(rgb[1], 0, 255) and bounded(rgb[2], 0, 255) and bounded(rgb[3], 0, 255) then
            saved[key] = { math.floor(rgb[1]), math.floor(rgb[2]), math.floor(rgb[3]) }
        end
    end
    local neon = snapshot.neonEnabled
    if type(neon) == 'table' and type(neon[1]) == 'boolean' and type(neon[2]) == 'boolean'
        and type(neon[3]) == 'boolean' and type(neon[4]) == 'boolean' then
        saved.neonEnabled = { neon[1], neon[2], neon[3], neon[4] }
    end
    for key, maximum in pairs(vehicleBooleanMaps) do
        local entries = snapshot[key]
        if type(entries) == 'table' then
            local normalized = {}
            for index = 0, maximum do
                local id = tostring(index)
                local value = entries[id]
                if value == nil then value = entries[index] end
                if type(value) == 'boolean' then normalized[id] = value end
            end
            saved[key] = normalized
        end
    end
    saved.dirtLevel = bounded(snapshot.dirtLevel, 0, 15) or saved.dirtLevel
end

local function waitUntil(predicate, timeout)
    local deadline = GetGameTimer() + timeout
    while not predicate() do
        if GetGameTimer() >= deadline then return false end
        Wait(50)
    end
    return true
end

garageCallback('store', function(source, garageId, request, netId, condition)
    local _, owner, ped = context(source, garageId)
    if type(netId) ~= 'number' or netId % 1 ~= 0 or netId < 1 or netId > 65535
        or type(condition) ~= 'table' then return false, T('Ungültiges Fahrzeug.') end
    local vehicle = NetworkGetEntityFromNetworkId(netId)
    local function canStore()
        local _, currentOwner, currentPed = context(source, garageId)
        return currentOwner == owner and ped == currentPed and vehicle ~= 0
            and NetworkGetEntityFromNetworkId(netId) == vehicle and GetEntityType(vehicle) == 2
            and GetPedInVehicleSeat(vehicle, -1) == ped and GetEntitySpeed(vehicle) < 1.0
    end
    if not canStore() then return false, T('Halte als Fahrer auf der Garagenmarkierung an.') end
    local function hasPassengers()
        for _, playerId in ipairs(GetPlayers()) do
            local otherPed = GetPlayerPed(playerId)
            if otherPed ~= 0 and otherPed ~= ped and GetVehiclePedIsIn(otherPed, false) == vehicle then
                return true
            end
        end
    end
    if hasPassengers() then return false, T('Alle Mitfahrer müssen zuerst aussteigen.') end
    local visiblePlate = normalizedPlate(GetVehicleNumberPlateText(vehicle))
    local canonical = checkoutPlate(vehicle)
    local selectOwned = 'SELECT plate, {propsRead}, {statusRead}, dagarage_location, dagarage_slot FROM {vehicles} WHERE '
    if not lockVehicle(request, canonical or visiblePlate) then return false, T('Dieses Fahrzeug wird gerade benutzt.') end
    local row
    if canonical then
        row = DB.single(selectOwned .. fields, { owner, canonical })
        if not row and visiblePlate ~= '' and visiblePlate ~= normalizedPlate(canonical)
            and not DB.scalar('SELECT 1 FROM {vehicles} WHERE plate = ? LIMIT 1', { canonical }) then
            -- An external registration can replace the original plate on both the row and the entity.
            canonical = nil
        end
    end
    if not canonical and visiblePlate ~= '' then
        if not lockVehicle(request, visiblePlate) then return false, T('Dieses Fahrzeug wird gerade benutzt.') end
        row = DB.single(selectOwned .. fleet .. ' AND TRIM(plate) = ?', { owner, visiblePlate })
        if not row then
            -- Some plates can return without a space or separator. Only use an unambiguous match.
            local compact = visiblePlate:gsub('[ %-]', '')
            if compact:match('^[A-Z0-9]+$') then
                local matches = DB.query([[
                    SELECT plate FROM {vehicles}
                    WHERE BINARY REPLACE(REPLACE(UPPER(TRIM(plate)), ' ', ''), '-', '') = ?
                    LIMIT 2
                ]], { compact })
                if #matches == 1 then
                    local plate = matches[1].plate
                    if not lockVehicle(request, plate) then return false, T('Dieses Fahrzeug wird gerade benutzt.') end
                    row = DB.single(selectOwned .. fields, { owner, plate })
                end
            end
        end
    end
    if not row then
        local plate = visiblePlate:gsub('[%c~]', ''):sub(1, 12)
        return false, (T('Das Fahrzeug meldet Kennzeichen „%s“. Dazu wurde kein passender Eintrag für dich oder diesen Fuhrpark gefunden.'))
            :format(plate ~= '' and plate or T('leer'))
    end
    if tonumber(row.stored) == 2 then return false, T('Dieses Fahrzeug ist beschlagnahmt.') end
    local props = row and properties(row)
    if not props or (GetEntityModel(vehicle) & 0xffffffff) ~= (props.model & 0xffffffff) then
        return false, T('Das Fahrzeugmodell passt nicht zum hinterlegten Kennzeichen.')
    end
    if tonumber(row.stored) ~= 1 or row.dagarage_location ~= garageId then
        local space, reason = garageHasSpace(request, owner, garageId)
        if not space then return false, reason end
    end
    if not canStore() then return false, T('Das Fahrzeug ist nicht mehr einparkbereit.') end

    local snapshot = condition.properties
    if snapshot ~= nil then
        if type(snapshot) ~= 'table' or type(snapshot.model) ~= 'number' or not math.tointeger(snapshot.model)
            or (snapshot.model & 0xffffffff) ~= (props.model & 0xffffffff) then
            return false, T('Die Fahrzeugdaten passen nicht zum Fahrzeug.')
        end
        mergeVehicleSnapshot(props, snapshot)
    end
    props.fuelLevel = bounded(condition.fuel, 0, 100) or props.fuelLevel
    props.engineHealth = bounded(condition.engine, -4000, 1000) or props.engineHealth
    props.bodyHealth = bounded(condition.body, 0, 1000) or props.bodyHealth
    props.tankHealth = bounded(condition.tank, -4000, 1000) or props.tankHealth
    local saved = json.encode(isQB and Framework.ToQBProperties(props) or props)
    local previousSlot = tonumber(row.dagarage_slot) or 0
    local slot = row.dagarage_location == garageId and previousSlot or 0
    local updates = '{status} = 1, {props} = ?, dagarage_location = ?, dagarage_slot = NULLIF(?, 0)'
    local parameters = { saved, garageId, slot }
    if isQB then
        updates = updates .. ', fuel = ?, engine = ?, body = ?'
        parameters[4] = props.fuelLevel or 100
        parameters[5] = props.engineHealth or 1000
        parameters[6] = props.bodyHealth or 1000
    end
    for _, value in ipairs({ owner, row.plate, row.stored, row.vehicle, row.dagarage_location or '', previousSlot }) do
        parameters[#parameters + 1] = value
    end
    local changed = DB.update('UPDATE {vehicles} SET ' .. updates .. ' WHERE ' ..
        fields .. " AND {status} = ? AND {propsMatch} = ? AND dagarage_location <=> NULLIF(?, '')" ..
        ' AND dagarage_slot <=> NULLIF(?, 0)',
        parameters)
    if changed ~= 1 then
        local current = DB.single('SELECT {statusRead}, {propsRead}, dagarage_location, dagarage_slot FROM {vehicles} WHERE ' ..
            fields, { owner, row.plate })
        if not current or tonumber(current.stored) ~= 1 or current.vehicle ~= saved or current.dagarage_location ~= garageId
            or (tonumber(current.dagarage_slot) or 0) ~= slot then
            return false, T('Der Fahrzeugstand hat sich geändert. Versuche es erneut.')
        end
    end

    local function gone()
        return not DoesEntityExist(vehicle) or NetworkGetEntityFromNetworkId(netId) ~= vehicle
    end

    local function fullyRemoved()
        return gone() and not savedParkingPosition(row.plate)
    end

    local orphanMode
    local ok, removed, reason = pcall(function()
        if gone() then return waitUntil(fullyRemoved, 2000) end
        if not canStore() then return false, T('Halte während des Einparkens auf der Garagenmarkierung an.') end
        if hasPassengers() then return false, T('Alle Mitfahrer müssen zuerst aussteigen.') end

        local parking = advancedParking()
        if parking then
            local tracked = Entity(vehicle).state.ap_id or parking:GetStateBagsFromPlate(row.plate)
            if parking:DeleteVehicle(vehicle, false) or tracked then
                return waitUntil(fullyRemoved, 2000), T('AdvancedParking hat das Entfernen nicht bestätigt.')
            end
            if gone() then return waitUntil(fullyRemoved, 2000) end
        end

        -- Checked-out vehicles may be protected by KeepEntity until they are explicitly stored.
        orphanMode = GetEntityOrphanMode(vehicle)
        if orphanMode == 2 then SetEntityOrphanMode(vehicle, 0) end
        DeleteEntity(vehicle)
        if waitUntil(fullyRemoved, 750) then return true end
        if gone() then return waitUntil(fullyRemoved, 1250) end

        if canStore() and not hasPassengers() then
            TaskLeaveVehicle(ped, vehicle, 16)
            waitUntil(function() return gone() or GetPedInVehicleSeat(vehicle, -1) ~= ped end, 1250)
        end
        if not gone() then
            if GetPedInVehicleSeat(vehicle, -1) ~= 0 or hasPassengers() then
                return false, T('Das Fahrzeug ist noch besetzt. Bitte bleib an der Markierung und versuche es erneut.')
            end
            local garage, currentOwner = context(source, garageId)
            if currentOwner ~= owner or #(GetEntityCoords(vehicle) - garage.marker) > Config.InteractionDistance
                or GetEntitySpeed(vehicle) >= 1.0 then
                return false, T('Das Fahrzeug ist nicht mehr einparkbereit.')
            end
            DeleteEntity(vehicle)
        end
        return waitUntil(fullyRemoved, 1500)
    end)
    if ok and removed then return true end
    if not ok then print(('[DaGarage] Einparken: %s'):format(removed)) end
    if orphanMode == 2 and not gone() then SetEntityOrphanMode(vehicle, orphanMode) end
    DB.update("UPDATE {vehicles} SET {status} = ?, dagarage_location = NULLIF(?, ''), dagarage_slot = NULLIF(?, 0) WHERE " ..
        fields .. ' AND {status} = 1 AND {propsMatch} = ? AND dagarage_location = ? AND dagarage_slot <=> NULLIF(?, 0)',
        { row.stored, row.dagarage_location or '', previousSlot, owner, row.plate, saved, garageId, slot })
    return false, reason or T('FiveM hat das Entfernen des Fahrzeugs nicht bestätigt. Es bleibt ausgeparkt.')
end)

local adminGarages = {}
local garageVersion = 0
local garageStorageReady = false

local function garageKey(id)
    return 'dagarage_db_' .. id
end

local function validCoordinate(value)
    return type(value) == 'number' and math.abs(value) < 100000
end

local function validPoint(point)
    return type(point) == 'table' and validCoordinate(point.x) and validCoordinate(point.y) and validCoordinate(point.z)
end

local function garageDefinition(input, checkProfiles)
    if type(input) ~= 'table' or not validPoint(input.marker) or not validPoint(input.spawn)
        or not validCoordinate(input.spawn.w) then return end
    if input.interior and (type(input.interior) ~= 'string' or (checkProfiles and not Config.Interiors[input.interior])) then return end
    if input.society and (type(input.society) ~= 'string' or (checkProfiles and not Config.AdminSocieties[input.society])) then return end
    local marker, spawn = input.marker, input.spawn
    return {
        marker = { x = marker.x, y = marker.y, z = marker.z },
        spawn = { x = spawn.x, y = spawn.y, z = spawn.z, w = spawn.w % 360 },
        interior = input.interior, society = input.society
    }
end

local function publishGarage(record)
    local key, definition = garageKey(record.id), record.definition
    local marker, spawn = definition.marker, definition.spawn
    adminGarages[key] = record
    Config.Garages[key] = {
        label = record.label,
        marker = vector3(marker.x, marker.y, marker.z),
        spawn = vector4(spawn.x, spawn.y, spawn.z, spawn.w),
        interior = definition.interior,
        society = definition.society and (Config.AdminSocieties[definition.society] or { job = false }) or nil
    }
end

local function migrateVehicleSchema()
    local columns = DB.query([[
        SELECT COLUMN_NAME AS name FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '{vehicles}'
          AND COLUMN_NAME IN ('dagarage_location', 'dagarage_slot', 'dagarage_society')
    ]])
    local existing = {}
    for _, column in ipairs(columns) do existing[column.name] = true end
    if not existing.dagarage_location then
        DB.query('ALTER TABLE {vehicles} ADD COLUMN dagarage_location VARCHAR(60) NULL')
    end
    if not existing.dagarage_slot then
        DB.query('ALTER TABLE {vehicles} ADD COLUMN dagarage_slot INT UNSIGNED NULL')
    end
    if isQB and not existing.dagarage_society then
        DB.query('ALTER TABLE player_vehicles ADD COLUMN dagarage_society VARCHAR(60) NULL')
    end
    local index = DB.scalar([[
        SELECT 1 FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '{vehicles}'
          AND INDEX_NAME = 'uq_dagarage_owner_location_slot' AND NON_UNIQUE = 0 LIMIT 1
    ]])
    if not index then
        DB.query([[
            ALTER TABLE {vehicles} ADD UNIQUE KEY uq_dagarage_owner_location_slot
            ({slotOwner}, dagarage_location, dagarage_slot)
        ]])
    end
    if isQB and not DB.scalar([[
        SELECT 1 FROM information_schema.STATISTICS
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'player_vehicles'
          AND INDEX_NAME = 'uq_dagarage_society_location_slot' AND NON_UNIQUE = 0 LIMIT 1
    ]]) then
        DB.query([[
            ALTER TABLE player_vehicles ADD UNIQUE KEY uq_dagarage_society_location_slot
            (dagarage_society, dagarage_location, dagarage_slot)
        ]])
    end
end

local function loadStoredGarages()
    local tableExists = DB.scalar([[
        SELECT 1 FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'dagarage_garages' LIMIT 1
    ]])
    if not tableExists then
        local migration = assert(LoadResourceFile(GetCurrentResourceName(), 'dagarage_garages.sql'), 'dagarage_garages.sql fehlt')
        DB.query(migration)
    end
    local rows = DB.query('SELECT id, revision, label, definition FROM dagarage_garages')
    for _, row in ipairs(rows) do
        local decoded, definition = pcall(json.decode, row.definition)
        row.definition = decoded and garageDefinition(definition)
        if row.definition and not Config.Garages[garageKey(row.id)] then
            publishGarage(row)
        else
            print(('[DaGarage] Datenbank-Standort %s konnte nicht geladen werden.'):format(row.id))
        end
    end
    garageStorageReady = true
    garageVersion = garageVersion + 1
    TriggerClientEvent('DaGarage:garageLocations', -1, garageVersion, adminGarages)
end

MySQL.ready(function()
    local ok, err = pcall(migrateVehicleSchema)
    if not ok then
        schemaError = T('Die Garagendatenbank ist nicht eingerichtet. Bitte informiere einen Admin.')
        print(('[DaGarage] Fahrzeugmigration fehlgeschlagen. Prüfe %s und die ALTER-Berechtigung: %s'):format(vehicleTable, err))
        return
    end
    schemaReady = true

    ok, err = pcall(loadStoredGarages)
    if not ok then
        print(('[DaGarage] Admin-Standorte konnten nicht geladen werden. Prüfe dagarage_garages.sql und die CREATE-Berechtigung: %s'):format(err))
    end
end)

Framework.RegisterCallback('DaGarage:garageLocations', function(_, reply)
    reply(garageVersion, adminGarages)
end)

RegisterCommand('dagarageadmin', function(source)
    if source == 0 then return end
    if not Framework.IsAdmin(source) then
        return Framework.NotifyPlayer(source, T('Du darfst keine Garagen verwalten.'))
    end
    if not garageStorageReady then
        return Framework.NotifyPlayer(source, T('Garagenverwaltung nicht verfügbar. Prüfe die SQL-Migration.'))
    end
    TriggerClientEvent('DaGarage:openAdmin', source, garageVersion, adminGarages)
end, false)

Framework.RegisterCallback('DaGarage:adminPosition', function(source, reply)
    if not Framework.IsAdmin(source) then return reply(false, T('Du darfst keine Garagen verwalten.')) end
    local ped = GetPlayerPed(source)
    if ped == 0 or GetPlayerRoutingBucket(source) ~= 0 then
        return reply(false, T('Speichere die Position in der öffentlichen Spielwelt.'))
    end
    local point = GetEntityCoords(ped)
    reply({ x = point.x, y = point.y, z = point.z, w = GetEntityHeading(ped) })
end)

local function garageInUse(key)
    for _, state in pairs(interiorSessions) do
        if state.garageId == key then return true end
    end
    for _, request in pairs(activePlayers) do
        if request.garageId == key or request.layoutGarage == key then return true end
    end
    return false
end

local function changeGarage(source, action, record, label, definition)
    if not Framework.IsAdmin(source) then return false, T('Du darfst keine Garagen verwalten.') end
    local key = record and garageKey(record.id)
    if action == 'delete' then
        local removed = DB.update([[
            DELETE FROM dagarage_garages WHERE id = ? AND revision = ?
                AND NOT EXISTS (SELECT 1 FROM {vehicles} WHERE dagarage_location = ?)
        ]], { record.id, record.revision, key })
        if removed ~= 1 then return false, T('Der Standort hat sich geändert oder ihm sind noch Fahrzeuge zugeordnet.') end
        adminGarages[key], Config.Garages[key] = nil, nil
    elseif record then
        local societyChanged = record.definition.society ~= definition.society
        local updated = DB.update([[
            UPDATE dagarage_garages SET label = ?, definition = ?, revision = revision + 1
            WHERE id = ? AND revision = ?
                AND (? = 0 OR NOT EXISTS (SELECT 1 FROM {vehicles} WHERE dagarage_location = ?))
        ]], { label, json.encode(definition), record.id, record.revision, societyChanged and 1 or 0, key })
        if updated ~= 1 then
            return false, T('Der Standort hat sich geändert oder der Fuhrpark ist durch Fahrzeugzuordnungen belegt.')
        end
        publishGarage({ id = record.id, revision = record.revision + 1, label = label, definition = definition })
    else
        local id = DB.insert('INSERT INTO dagarage_garages (label, definition) VALUES (?, ?)',
            { label, json.encode(definition) })
        if not id or id < 1 then return false, T('Der Standort konnte nicht gespeichert werden.') end
        if Config.Garages[garageKey(id)] then return false, T('Der Standortschlüssel kollidiert mit der Konfiguration.') end
        publishGarage({ id = id, revision = 1, label = label, definition = definition })
    end
    garageVersion = garageVersion + 1
    TriggerClientEvent('DaGarage:garageLocations', -1, garageVersion, adminGarages)
    return { version = garageVersion, records = adminGarages }
end

Framework.RegisterCallback('DaGarage:adminSave', function(source, reply, payload)
    if not Framework.IsAdmin(source) then return reply(false, T('Du darfst keine Garagen verwalten.')) end
    if not garageStorageReady then return reply(false, T('Garagenverwaltung nicht verfügbar. Prüfe die SQL-Migration.')) end
    if type(payload) ~= 'table' then return reply(false, T('Ungültige Änderung.')) end
    local action, id, revision, label = payload.action, payload.id, payload.revision, payload.label
    if action ~= 'create' and action ~= 'update' and action ~= 'delete' then return reply(false, T('Ungültige Aktion.')) end
    local key, record
    if action ~= 'create' then
        if type(id) ~= 'number' or id < 1 or id % 1 ~= 0 then return reply(false, T('Ungültiger Standort.')) end
        key = garageKey(id)
        record = adminGarages[key]
        if not record or record.revision ~= revision then return reply(false, T('Der Standort hat sich geändert. Öffne das Menü erneut.')) end
        if changingGarages[key] or garageInUse(key) then return reply(false, T('Dieser Standort wird gerade benutzt.')) end
    end
    local definition
    if action ~= 'delete' then
        label = type(label) == 'string' and label:match('^%s*(.-)%s*$')
        definition = garageDefinition(payload.definition, true)
        if not label or label == '' or #label > 100 or label:find('[%c<>~]') or not definition then
            return reply(false, T('Gib einen gültigen Namen, Eingang und Ausparkpunkt an.'))
        end
    end
    if key then changingGarages[key] = true end
    local ok, result, message = pcall(changeGarage, source, action, record, label, definition)
    if key then changingGarages[key] = nil end
    if not ok then
        print(('[DaGarage] Garagenverwaltung: %s'):format(result))
        return reply(false, T('Die Änderung konnte nicht in der Datenbank gespeichert werden.'))
    end
    reply(result, message)
end)
