local Framework = GarageFramework
if not Framework.Core then return end

local T = DaGarageText

local Menu = (function()
    local Menu = {}

    local stack = {}
    local nextId = 0
    local focused = false
    local scheduled = false
    local ready = false
    local suspended = false

    local function update()
        local wantsFocus = ready and not suspended and #stack > 0
        if focused ~= wantsFocus then
            SetNuiFocus(wantsFocus, wantsFocus)
            focused = wantsFocus
        end
        if scheduled then return end
        scheduled = true
        SetTimeout(0, function()
            scheduled = false
            if not ready then return end
            local menu = not suspended and stack[#stack]
            SendNUIMessage({
                type = 'dagarage:menu',
                menu = menu and {
                    id = menu.id, name = menu.name, data = menu.data,
                    selection = menu.selection, nested = #stack > 1
                } or false
            })
        end)
    end

    function Menu.get(name)
        for _, menu in ipairs(stack) do
            if menu.name == name then return menu end
        end
    end

    function Menu.any()
        return #stack > 0
    end

    function Menu.suspend(value)
        suspended = value
        update()
    end

    function Menu.close(name)
        local menu = Menu.get(name)
        if menu then menu.close() end
    end

    function Menu.closeAll()
        while #stack > 0 do stack[#stack].close() end
    end

    function Menu.open(name, data, submit, cancel, onClose)
        Menu.close(name)
        nextId = nextId + 1
        local menu = { id = nextId, name = name, data = data, selection = 1, submit = submit, cancel = cancel }
        menu.close = function()
            for index, item in ipairs(stack) do
                if item == menu then
                    table.remove(stack, index)
                    if onClose then onClose() end
                    update()
                    return
                end
            end
        end
        stack[#stack + 1] = menu
        update()
        return menu
    end

    RegisterNUICallback('ready', function(_, reply)
        ready = true
        SendNUIMessage({ type = 'dagarage:settings', colors = Config.UIColors, language = Config.Locale, texts = DaGarageLocale() })
        update()
        reply(true)
    end)

    RegisterNUICallback('choose', function(payload, reply)
        local menu = not suspended and stack[#stack]
        local index = type(payload) == 'table' and type(payload.index) == 'number' and math.tointeger(payload.index)
        local item = menu and index and payload.id == menu.id and menu.data.elements[index]
        reply(true)
        if item and not item.disabled and item.value ~= nil and item.value ~= 'info' and menu.submit then
            menu.selection = index
            menu.submit({ current = item }, menu)
        end
    end)

    RegisterNUICallback('back', function(payload, reply)
        local menu = not suspended and stack[#stack]
        reply(true)
        if not menu or type(payload) ~= 'table' or payload.id ~= menu.id then return end
        if menu.cancel then menu.cancel({}, menu) else menu.close() end
    end)

    return Menu
end)()

local busy = false
local menuName = 'personal_vehicles'
local entranceMenu = 'garage_entrance'
local detailMenu = 'vehicle_details'
local previewMenu = 'vehicle_preview'
local infoMenu = 'interior_vehicle_info'
local societyMenu = 'society_models'
local filterMenu = 'vehicle_filter'
local listOptionsMenu = 'vehicle_list_options'
local adminMenu = 'garage_admin'
local adminChoiceMenu = 'garage_admin_choice'
local resource = GetCurrentResourceName()
local interior, preview
local lookCard
local searching = false
local adminBusy = false
local adminPlacement
local garageBlips, databaseGarages = {}, {}
local garageVersion = -1
local statuses = {
    stored = T('Eingeparkt'),
    outside = T('Draußen'),
    missing = T('Nicht auffindbar'),
    impounded = T('Beschlagnahmt')
}

local function dispatch(action, garageId, callback, ...)
    if busy then return end
    busy = true
    Framework.TriggerCallback('DaGarage:' .. action, function(result, message)
        busy = false
        callback(result, message)
    end, garageId, ...)
end

local function request(action, garageId, callback, ...)
    dispatch(action, garageId, function(result, message)
        if not result then return Framework.Notify(message or T('Die Garage ist momentan nicht verfügbar.')) end
        callback(result)
    end, ...)
end

local function canUseGarage(garage, manage)
    local society = garage.society
    if not society then return not manage end
    if manage and type(society.manageGrade) ~= 'number' then return false end
    local job = Framework.GetPlayerData().job
    local minimum = math.max(society.minGrade or 0, manage and society.manageGrade or 0)
    return job and job.name == society.job and (tonumber(job.grade) or -1) >= minimum
end

local function applySavedPaint(vehicle, props)
    local primary, secondary = props.customPrimaryColor, props.customSecondaryColor
    ClearVehicleCustomPrimaryColour(vehicle)
    ClearVehicleCustomSecondaryColour(vehicle)
    SetVehicleColours(vehicle, props.color1, props.color2)
    if type(primary) == 'table' and primary[1] and primary[2] and primary[3] then
        SetVehicleCustomPrimaryColour(vehicle, primary[1], primary[2], primary[3])
    end
    if type(secondary) == 'table' and secondary[1] and secondary[2] and secondary[3] then
        SetVehicleCustomSecondaryColour(vehicle, secondary[1], secondary[2], secondary[3])
    end
end

local function applyGarageProperties(vehicle, props)
    Framework.SetVehicleProperties(vehicle, props)
    applySavedPaint(vehicle, props)
    SetVehicleModKit(vehicle, 0)
    if props.modSmokeEnabled == false then ToggleVehicleMod(vehicle, 20, false) end
    if props.modLightbar ~= nil then SetVehicleMod(vehicle, 49, props.modLightbar, false) end
end

local function enterVehicle(spawned, finish)
    CreateThread(function()
        local netId, props = spawned.netId, spawned.properties
        local deadline = GetGameTimer() + 5000
        local nextControlRequest = 0
        while GetGameTimer() < deadline do
            if NetworkDoesEntityExistWithNetworkId(netId) then
                local vehicle = NetToVeh(netId)
                local ped = PlayerPedId()
                if vehicle ~= 0 and DoesEntityExist(vehicle) then
                    local state = Entity(vehicle).state
                    if NetworkHasControlOfEntity(vehicle) then
                        applyGarageProperties(vehicle, props)
                        local fuel = type(state.fuel) == 'number' and state.fuel or props.fuelLevel
                        if type(fuel) == 'number' then
                            SetVehicleFuelLevel(vehicle, fuel)
                            if Config.SetFuel then
                                pcall(Config.SetFuel, vehicle, fuel)
                            end
                        end
                        if GetVehiclePedIsIn(ped, false) == 0 and GetPedInVehicleSeat(vehicle, -1) == 0 then
                            TaskWarpPedIntoVehicle(ped, vehicle, -1)
                        end
                        -- Initial network sync can overwrite the paint and plate just after the warp.
                        SetTimeout(180, function()
                            if NetworkDoesEntityExistWithNetworkId(netId) and NetToVeh(netId) == vehicle
                                and NetworkHasControlOfEntity(vehicle) then
                                SetVehicleNumberPlateText(vehicle, props.plate)
                                applySavedPaint(vehicle, props)
                                if Config.UseMyFuelTankData and GetResourceState('myFuel') == 'started'
                                    and not state.myFuelTankStatus then
                                    TriggerServerEvent('myFuel:initFuelForVehicle', netId)
                                end
                            end
                        end)
                        Framework.Notify(T('Fahrzeug ausgeparkt.'))
                        if finish then finish() end
                        return
                    elseif GetGameTimer() >= nextControlRequest then
                        NetworkRequestControlOfEntity(vehicle)
                        nextControlRequest = GetGameTimer() + 250
                    end
                end
            end
            Wait(50)
        end
        Framework.Notify(T('Dein Fahrzeug wurde ausgeparkt. Du findest es an der Ausfahrt.'))
        if finish then finish() end
    end)
end

local function movePed(point, waitForCollision)
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, true)
    RequestCollisionAtCoord(point.x, point.y, point.z)
    SetEntityCoordsNoOffset(ped, point.x, point.y, point.z, false, false, false)
    if type(point) == 'vector4' then SetEntityHeading(ped, point.w) end
    if waitForCollision then
        local deadline = GetGameTimer() + 4000
        while not HasCollisionLoadedAroundEntity(ped) and GetGameTimer() < deadline do Wait(0) end
    end
    FreezeEntityPosition(ped, false)
    return HasCollisionLoadedAroundEntity(ped)
end

local function vehicleFootprint(vehicle, model)
    local minimum, maximum = GetModelDimensions(model)
    local center = GetOffsetFromEntityInWorldCoords(vehicle, (minimum.x + maximum.x) / 2, (minimum.y + maximum.y) / 2, 0.0)
    local forward = GetEntityForwardVector(vehicle)
    local length = math.sqrt(forward.x ^ 2 + forward.y ^ 2)
    local x, y = forward.x / length, forward.y / length
    return center, vector2(x, y), vector2(y, -x), (maximum.y - minimum.y) / 2 + 0.1, (maximum.x - minimum.x) / 2 + 0.1
end

local function overlapsParkedVehicle(vehicle, model, parkedVehicles)
    local function projection(a, b)
        return math.abs(a.x * b.x + a.y * b.y)
    end
    local center, forward, right, length, width = vehicleFootprint(vehicle, model)
    for other, props in pairs(parkedVehicles) do
        if DoesEntityExist(other) then
            local otherCenter, otherForward, otherRight, otherLength, otherWidth = vehicleFootprint(other, props.model)
            local horizontal = vector2(otherCenter.x - center.x, otherCenter.y - center.y)
            local overlaps = true
            for _, axis in ipairs({ forward, right, otherForward, otherRight }) do
                local separation = projection(horizontal, axis)
                local extent = length * projection(forward, axis) + width * projection(right, axis)
                    + otherLength * projection(otherForward, axis) + otherWidth * projection(otherRight, axis)
                if separation >= extent then
                    overlaps = false
                    break
                end
            end
            if overlaps then return true end
        end
    end
end

local function clearInteriorSlot(vehicle, model, parkedVehicles)
    if overlapsParkedVehicle(vehicle, model, parkedVehicles) then return false end
    local minimum, maximum = GetModelDimensions(model)
    local traces = {}
    for _, height in ipairs({ minimum.z + (maximum.z - minimum.z) * 0.35, minimum.z + (maximum.z - minimum.z) * 0.75 }) do
        local origin = GetOffsetFromEntityInWorldCoords(vehicle, 0.0, 0.0, height)
        for _, x in ipairs({ minimum.x, maximum.x }) do
            for _, y in ipairs({ minimum.y, maximum.y }) do
                local target = GetOffsetFromEntityInWorldCoords(vehicle, x, y, height)
                traces[#traces + 1] = StartShapeTestLosProbe(origin.x, origin.y, origin.z,
                    target.x, target.y, target.z, 19, vehicle, 7)
            end
        end
    end
    local deadline = GetGameTimer() + 350
    local blocked = false
    while #traces > 0 and GetGameTimer() < deadline do
        for index = #traces, 1, -1 do
            local status, hit = GetShapeTestResult(traces[index])
            if status ~= 1 then
                table.remove(traces, index)
                blocked = blocked or (status == 2 and (hit == true or hit == 1))
            end
        end
        if #traces > 0 then Wait(0) end
    end
    return not blocked
end

local function placeInteriorVehicle(vehicle, model, point, checkClearance, parkedVehicles)
    RequestCollisionAtCoord(point.x, point.y, point.z)
    local deadline = GetGameTimer() + 1200
    while not HasCollisionLoadedAroundEntity(vehicle) or not SetVehicleOnGroundProperly(vehicle) do
        if GetGameTimer() >= deadline then return false end
        Wait(50)
    end
    return not checkClearance or clearInteriorSlot(vehicle, model, parkedVehicles)
end

local function localVehicle(props, point, parked, checkClearance, alternative, parkedVehicles)
    local model = props.model
    if not IsModelInCdimage(model) or not IsModelAVehicle(model) then return end
    RequestModel(model)
    local deadline = GetGameTimer() + 3500
    while not HasModelLoaded(model) and GetGameTimer() < deadline do Wait(0) end
    if not HasModelLoaded(model) then
        SetModelAsNoLongerNeeded(model)
        return
    end
    local vehicle = CreateVehicle(model, point.x, point.y, point.z, point.w, false, false)
    SetModelAsNoLongerNeeded(model)
    if vehicle == 0 then return end
    SetEntityAsMissionEntity(vehicle, true, false)
    if parked then
        FreezeEntityPosition(vehicle, true)
        SetEntityVisible(vehicle, false, false)
        SetEntityCollision(vehicle, false, false)
    end
    applyGarageProperties(vehicle, props)
    if parked then
        local placed = placeInteriorVehicle(vehicle, model, point, checkClearance, parkedVehicles)
        if not placed and alternative then
            SetEntityCoordsNoOffset(vehicle, alternative.x, alternative.y, alternative.z, false, false, false)
            SetEntityHeading(vehicle, alternative.w)
            placed = placeInteriorVehicle(vehicle, model, alternative, checkClearance, parkedVehicles)
        end
        if not placed then
            DeleteEntity(vehicle)
            return
        end
        SetEntityCollision(vehicle, true, true)
        SetEntityVisible(vehicle, true, false)
    else
        SetVehicleOnGroundProperly(vehicle)
    end
    return vehicle
end

local function closePreview()
    local current = preview
    if not current then return end
    preview = nil
    if current.cam then
        RenderScriptCams(false, false, 0, true, false)
        DestroyCam(current.cam, false)
    end
    if current.vehicle then DeleteEntity(current.vehicle) end
    if current.room then UnpinInterior(current.room) end
    ClearFocus()
end

local function rotatePreview(current, degrees)
    local vehicle = current.vehicle
    current.heading = current.heading or GetEntityHeading(vehicle)
    current.targetHeading = (current.targetHeading or current.heading) + degrees
    if current.rotating then return end
    current.rotating = true
    CreateThread(function()
        while preview == current and DoesEntityExist(vehicle) do
            local remaining = current.targetHeading - current.heading
            if math.abs(remaining) < 0.25 then
                current.heading = current.targetHeading
                SetEntityHeading(vehicle, current.heading % 360)
                break
            end
            current.heading = current.heading + remaining * (1 - math.exp(-GetFrameTime() * 18))
            SetEntityHeading(vehicle, current.heading % 360)
            Wait(0)
        end
        current.rotating = false
    end)
end

local function openPreview(garageId, plate, title)
    if preview or not Config.Preview then return end
    request('preview', garageId, function(props)
        if not Menu.get(detailMenu) then return end
        local point = Config.Preview
        local current = { garageId = garageId }
        preview = current
        local deadline = GetGameTimer() + 3000
        SetFocusPosAndVel(point.x, point.y, point.z, 0.0, 0.0, 0.0)
        RequestCollisionAtCoord(point.x, point.y, point.z)
        local room
        repeat
            room = GetInteriorAtCoords(point.x, point.y, point.z)
            if room ~= 0 and not current.room then
                PinInteriorInMemory(room)
                current.room = room
            end
            if room ~= 0 and IsInteriorReady(room) then break end
            Wait(50)
        until preview ~= current or GetGameTimer() >= deadline
        if preview ~= current then return end
        if room == 0 or not IsInteriorReady(room) then
            closePreview()
            return Framework.Notify(T('Der Vorschauplatz konnte nicht geladen werden.'))
        end
        local vehicle = localVehicle(props, point)
        if preview ~= current or not Menu.get(detailMenu) then
            if vehicle then DeleteEntity(vehicle) end
            if preview == current then closePreview() end
            return
        end
        if not vehicle then
            closePreview()
            return Framework.Notify(T('Die Fahrzeugvorschau konnte nicht geladen werden.'))
        end
        current.vehicle = vehicle
        FreezeEntityPosition(vehicle, true)
        SetEntityCollision(vehicle, false, false)
        local camera = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
        current.cam = camera
        SetCamCoord(camera, point.x - 3.3, point.y + 5.4, point.z + 2.0)
        PointCamAtEntity(camera, vehicle, 0.0, 0.0, 0.2, true)
        SetCamFov(camera, 49.0)
        RenderScriptCams(true, false, 0, true, false)

        Menu.open(previewMenu, {
            title = title,
            align = 'top-left',
            elements = {
                { label = T('Nach links drehen'), value = -30 },
                { label = T('Nach rechts drehen'), value = 30 },
                { label = T('Vorschau schließen'), value = 0 }
            }
        }, function(data, menu)
            local rotation = data.current.value
            if rotation == 0 then
                menu.close()
            elseif preview == current then
                rotatePreview(current, rotation)
            end
        end, function(_, menu)
            menu.close()
        end, closePreview)
    end, plate)
end

local function clearInteriorVehicles(session)
    for vehicle in pairs(session.display) do DeleteEntity(vehicle) end
    session.display = {}
end

local function hideLookCard()
    if not lookCard then return end
    lookCard = nil
    SendNUIMessage({ type = 'dagarage:look', vehicle = false })
end

local function showPage(session, page)
    if session.loading then return end
    session.loading = true
    session.page = page
    hideLookCard()
    clearInteriorVehicles(session)
    CreateThread(function()
        local slots = session.profile.slots
        local placementFailed = false
        for index, slot in ipairs(slots) do
            local number = (page - 1) * #slots + index
            local props = session.vehicles[number]
            if props then
                local alternative = session.profile.slotAlternatives and session.profile.slotAlternatives[index]
                local vehicle = localVehicle(props, slot, true, session.profile.checkClearance, alternative, session.display)
                if interior ~= session then
                    if vehicle then DeleteEntity(vehicle) end
                    return
                end
                if vehicle then
                    -- The display car only moves inside. The real tank is restored outside.
                    SetVehicleFuelLevel(vehicle, 100.0)
                    session.display[vehicle] = props
                else
                    placementFailed = true
                end
            end
        end
        session.loading = false
        if placementFailed then
            Framework.Notify(T('Ein Fahrzeug konnte im Innenraum nicht abgestellt werden. Du findest es in der Liste am Eingang.'))
        end
    end)
end

local function updateInteriorPages(session)
    local capacity = #session.profile.slots
    local highest = 0
    for slot in pairs(session.vehicles) do highest = math.max(highest, slot) end
    session.pages = {}
    for slot in pairs(session.vehicles) do session.pages[math.ceil(slot / capacity)] = true end
    session.lastPage = math.max(1, math.ceil(highest / capacity))
end

local function finishInterior(session, spawned)
    interior = nil
    hideLookCard()
    Menu.close(infoMenu)
    local ped = PlayerPedId()
    if GetVehiclePedIsIn(ped, false) ~= 0 then
        ClearPedTasksImmediately(ped)
    end
    clearInteriorVehicles(session)
    if session.room then UnpinInterior(session.room) end
    local garage = Config.Garages[session.garageId]
    movePed(spawned and garage.spawn or session.marker or garage.marker, true)
    local function finish()
        DoScreenFadeIn(140)
        SetTimeout(800, function()
            Framework.TriggerCallback('DaGarage:completeInteriorReturn', function() end, session.garageId)
        end)
    end
    if spawned then enterVehicle(spawned, finish) else finish() end
end

local function exitInterior(session, plate, display)
    if busy or session.transitioning then return end
    session.transitioning = true
    if display then FreezeEntityPosition(display, true) end
    local fade = 120
    local fadeEnd = GetGameTimer() + fade
    DoScreenFadeOut(fade)
    dispatch(plate and 'interiorDriveOut' or 'interiorLeave', session.garageId, function(result, message)
        if not result then
            if display and DoesEntityExist(display) then FreezeEntityPosition(display, false) end
            session.transitioning = false
            DoScreenFadeIn(140)
            return Framework.Notify(message or T('Die Ausfahrt ist gerade nicht verfügbar.'))
        end
        local remaining = fadeEnd - GetGameTimer()
        if remaining > 0 then Wait(remaining) end
        finishInterior(session, plate and result or nil)
    end, plate)
end

local function enterInterior(garageId, profile)
    request('interiorEnter', garageId, function(layout)
        local session = {
            garageId = garageId, profile = profile, vehicles = {}, occupied = {},
            display = {}, transitioning = true
        }
        for _, entry in ipairs(layout.vehicles) do
            entry.props.slot = entry.slot
            session.vehicles[entry.slot] = entry.props
        end
        for _, slot in ipairs(layout.reserved) do session.occupied[slot] = true end
        updateInteriorPages(session)
        interior = session
        DoScreenFadeOut(250)
        Wait(270)
        for _, ipl in ipairs(profile.ipls or {}) do RequestIpl(ipl) end
        local entry = profile.entry
        local room = GetInteriorAtCoords(entry.x, entry.y, entry.z)
        if room ~= 0 then
            PinInteriorInMemory(room)
            session.room = room
        end
        local loaded = movePed(entry, true)
        session.transitioning = false
        if not loaded then
            Framework.Notify(T('Der Garageninnenraum konnte nicht geladen werden.'))
            return exitInterior(session)
        end
        local firstPage = 1
        while not session.pages[firstPage] and firstPage < session.lastPage do firstPage = firstPage + 1 end
        showPage(session, firstPage)
        DoScreenFadeIn(250)
    end)
end

local function percent(value, maximum)
    if type(value) ~= 'number' then return T('Unbekannt') end
    return ('%.0f %%'):format(math.min(100, math.max(0, value / maximum * 100)))
end

local function labelText(key, fallback)
    if not key or key == '' or key == 'NULL' or key == 'CARNOTFOUND' then return fallback end
    local label = GetLabelText(key)
    return label ~= 'NULL' and label or fallback
end

local function interiorVehicleData(vehicle, props)
    local modelKey = GetDisplayNameFromVehicleModel(props.model)
    local data = {
        model = labelText(modelKey, modelKey or T('Unbekannt')),
        make = labelText(GetMakeNameFromVehicleModel(props.model), T('Unbekannt')),
        class = labelText(('VEH_CLASS_%d'):format(GetVehicleClass(vehicle)), T('Unbekannt')),
        plate = props.plate,
        slot = props.slot,
        fuel = percent(props.fuelLevel, 100)
    }
    if Config.UseMyFuelTankData and GetResourceState('myFuel') == 'started' then
        local ok, fuelType = pcall(function() return exports.myFuel:GetFuelType(vehicle) end)
        data.fuelType = ok and type(fuelType) == 'string' and fuelType ~= '' and fuelType or T('Unbekannt')
    end
    return data
end

local function canAssignSlot(session)
    local garage = Config.Garages[session.garageId]
    return interior == session and not session.loading and GetVehiclePedIsIn(PlayerPedId(), false) == 0
        and (not garage.society or canUseGarage(garage, true))
end

local function openSlotPicker(session, props, parent)
    if busy or not canAssignSlot(session) then return end
    local capacity = #session.profile.slots
    local options = {}
    local limit = Config.GetGarageCapacity(Config.Garages[session.garageId])
    for slot = 1, limit do
        if not session.occupied[slot] then
            options[#options + 1] = { label = (T('Stellplatz %d')):format(slot), value = slot }
        end
    end
    if #options == 0 then
        return Framework.Notify(T('Alle Stellplätze sind belegt oder reserviert.'))
    end
    Menu.open('assign_slot', {
        title = T('Freie Stellplätze'),
        elements = options
    }, function(selection, picker)
        if busy or not canAssignSlot(session) then return end
        local oldSlot = props.slot
        request('assignSlot', session.garageId, function(newSlot)
            if interior ~= session then return end
            session.vehicles[oldSlot], session.occupied[oldSlot] = nil, nil
            props.slot = newSlot
            session.vehicles[newSlot], session.occupied[newSlot] = props, true
            updateInteriorPages(session)
            picker.close()
            parent.close()
            showPage(session, math.ceil(newSlot / capacity))
            Framework.Notify((T('Stellplatz %d gespeichert.')):format(newSlot))
        end, props.plate, selection.current.value, oldSlot)
    end)
end

local function openSlotStation(session)
    if busy or not canAssignSlot(session) then return end
    hideLookCard()
    local vehicles = {}
    for slot, props in pairs(session.vehicles) do
        local key = GetDisplayNameFromVehicleModel(props.model)
        vehicles[#vehicles + 1] = {
            label = (T('%s [%s] · Stellplatz %d')):format(labelText(key, key or T('Unbekannt')), props.plate, slot),
            value = slot
        }
    end
    table.sort(vehicles, function(a, b) return a.value < b.value end)
    if #vehicles == 0 then
        vehicles[1] = { label = T('Hier stehen keine Fahrzeuge.'), value = 'info' }
    end
    Menu.open('slot_station', { title = T('Stellplätze verwalten'), elements = vehicles }, function(data, menu)
        local props = session.vehicles[data.current.value]
        if props then openSlotPicker(session, props, menu) end
    end)
end

local function openInteriorInfo(session, vehicle, props)
    hideLookCard()
    local details = interiorVehicleData(vehicle, props)
    local elements = {
        { label = T('Modell · ') .. details.model },
        { label = T('Hersteller · ') .. details.make },
        { label = T('Klasse · ') .. details.class },
        { label = T('Kennzeichen · ') .. details.plate },
        { label = (T('Stellplatz · %d')):format(details.slot) },
        { label = T('Tankstand (gespeichert) · ') .. details.fuel }
    }
    if details.fuelType then
        elements[#elements + 1] = { label = T('Kraftstoff · ') .. details.fuelType }
    end
    if canAssignSlot(session) then
        elements[#elements + 1] = { label = T('Stellplatz ändern'), value = 'assign' }
    end
    Menu.open(infoMenu, {
        title = details.model,
        align = 'top-left',
        elements = elements
    }, function(data, menu)
        if data.current.value == 'assign' then openSlotPicker(session, props, menu) end
    end, function(_, menu) menu.close() end)
end

local function lookedAtVehicle(session, ped, coords, now)
    if session.lookTrace then
        local state, hit, _, _, vehicle = GetShapeTestResult(session.lookTrace)
        if state ~= 1 then
            session.lookTrace = nil
            if state == 2 and hit and session.display[vehicle] then
                session.lookVehicle = vehicle
                session.lastLookHit = now
            end
        end
    end
    if not session.lookTrace and now >= (session.nextLookTrace or 0) then
        local camera = GetGameplayCamCoord()
        local rotation = GetGameplayCamRot(2)
        local pitch, heading = math.rad(rotation.x), math.rad(rotation.z)
        local direction = vector3(-math.sin(heading) * math.cos(pitch), math.cos(heading) * math.cos(pitch), math.sin(pitch))
        local target = camera + direction * 10.0
        session.lookTrace = StartShapeTestLosProbe(camera.x, camera.y, camera.z, target.x, target.y, target.z, 19, ped, 7)
        session.nextLookTrace = now + 75
    end
    local vehicle = session.lookVehicle
    if vehicle and now - session.lastLookHit <= 150 and session.display[vehicle] and DoesEntityExist(vehicle)
        and #(coords - GetEntityCoords(vehicle)) <= 6.0 then
        return vehicle, session.display[vehicle]
    end
end

local function showLookCard(vehicle, props, now)
    if not vehicle then return hideLookCard() end
    if not lookCard or lookCard.vehicle ~= vehicle then
        hideLookCard()
        local _, maximum = GetModelDimensions(props.model)
        lookCard = { vehicle = vehicle, height = maximum.z + 0.2, nextUpdate = 0 }
    end
    if now < lookCard.nextUpdate then return end
    lookCard.nextUpdate = now + 45
    local point = GetOffsetFromEntityInWorldCoords(vehicle, 0.0, 0.0, lookCard.height)
    local visible, x, y = GetScreenCoordFromWorldCoord(point.x, point.y, point.z)
    if not visible then
        if lookCard.x then
            lookCard.x, lookCard.y = nil, nil
            SendNUIMessage({ type = 'dagarage:look', vehicle = false })
        end
        return
    end
    local first = lookCard.x == nil
    if not first and math.abs(x - lookCard.x) < 0.0007 and math.abs(y - lookCard.y) < 0.0007 then return end
    lookCard.x, lookCard.y = x, y
    SendNUIMessage({
        type = 'dagarage:look', id = vehicle,
        vehicle = first and interiorVehicleData(vehicle, props) or nil, x = x, y = y
    })
end

local function modLevel(value)
    if type(value) ~= 'number' then return T('Unbekannt') end
    if value < 0 then return T('Serie') end
    return (T('Stufe %d')):format(math.floor(value) + 1)
end

local function paint(value)
    if type(value) == 'table' and tonumber(value[1]) and tonumber(value[2]) and tonumber(value[3]) then
        return ('RGB %.0f / %.0f / %.0f'):format(value[1], value[2], value[3])
    end
    if type(value) == 'number' then return (T('GTA-Farbnummer %.0f')):format(value) end
    return T('Unbekannt')
end

local function openDetails(garageId, vehicle, title, listMenu, refreshList)
    local elements = {}
    local function add(label, value)
        elements[#elements + 1] = { label = label, value = value or 'info' }
    end
    local recover = vehicle.status == 'missing' and Config.RecoverMissingVehicles
    if (vehicle.status == 'stored' or recover) and (not vehicle.remoteGarage or vehicle.remoteFee ~= nil) then
        local label = recover and T('Fahrzeug zurückholen') or T('Ausparken')
        if vehicle.remoteGarage then label = (T('Hier abholen · $%d')):format(vehicle.remoteFee) end
        add(label, 'retrieve')
    end
    if Config.Preview then add('3D-Vorschau', 'preview') end
    if vehicle.status == 'outside' and vehicle.hasPosition then add(T('Wegpunkt setzen'), 'waypoint') end
    if refreshList then add(vehicle.favorite and T('Favorit entfernen') or T('Als Favorit markieren'), 'favorite') end
    add(T('Status · ') .. statuses[vehicle.status])
    local parkedLabel = vehicle.remoteGarage or (vehicle.status == 'stored' and vehicle.parkedLabel)
    if parkedLabel then add(T('Einparkgarage · ') .. parkedLabel) end
    local function reading(value, maximum, live)
        local saved = type(value) == 'number' and vehicle.status == 'outside' and not live
        return percent(value, maximum) .. (saved and (" " .. T("(zuletzt gespeichert)")) or '')
    end
    add(T('Tankstand · ') .. reading(vehicle.fuel, 100, vehicle.fuelLive))
    if vehicle.wrongFuel then
        add(vehicle.blocked and T('Fehlbetankung · Motorsperre aktiv') or T('Fehlbetankung'))
        if vehicle.dispensedFuel then add(T('Getankt · ') .. vehicle.dispensedFuel) end
        if vehicle.requiredFuel then add(T('Benötigt · ') .. vehicle.requiredFuel) end
    end
    add(T('Motorzustand · ') .. reading(vehicle.engine, 1000, vehicle.conditionLive))
    add(T('Karosserie · ') .. reading(vehicle.body, 1000, vehicle.conditionLive))
    local tuning = vehicle.tuning
    add(T('Motortuning · ') .. modLevel(tuning.engine))
    add(T('Bremsen · ') .. modLevel(tuning.brakes))
    add(T('Getriebe · ') .. modLevel(tuning.transmission))
    local turbo = type(tuning.turbo) == 'boolean' and (tuning.turbo and T('Eingebaut') or T('Serie')) or T('Unbekannt')
    add(T('Turbo · ') .. turbo)
    add(T('Primärlack · ') .. paint(tuning.primary))
    add(T('Sekundärlack · ') .. paint(tuning.secondary))

    Menu.open(detailMenu, {
        title = title,
        align = 'top-left',
        elements = elements
    }, function(data, menu)
        local action = data.current.value
        if action == 'retrieve' and not busy then
            local spawn = Config.Garages[garageId] and Config.Garages[garageId].spawn
            if spawn and IsAnyVehicleNearPoint(spawn.x, spawn.y, spawn.z, Config.SpawnClearance) then
                return Framework.Notify(T('Am Ausparkpunkt steht bereits ein Fahrzeug.'))
            end
            Menu.closeAll()
            request('retrieve', garageId, enterVehicle, vehicle.plate, recover, vehicle.remoteFee)
        elseif action == 'waypoint' then
            request('waypoint', garageId, function(position)
                SetNewWaypoint(position.x + 0.0, position.y + 0.0)
                Framework.Notify(T('Wegpunkt zum Fahrzeug gesetzt.'))
            end, vehicle.plate)
        elseif action == 'preview' then
            openPreview(garageId, vehicle.plate, title)
        elseif action == 'favorite' and refreshList then
            local favorite = not vehicle.favorite
            request('setFavorite', garageId, function()
                vehicle.favorite = favorite
                if Menu.get(detailMenu) == menu then menu.close() end
                if Menu.get(menuName) == listMenu then
                    listMenu.close()
                    refreshList()
                end
            end, vehicle.plate, favorite)
        end
    end, function(_, menu)
        menu.close()
    end)
end

local function openSocietyModels(garageId, garage)
    local elements = {}
    for _, spawnName in ipairs(garage.society.models) do
        local modelKey = GetDisplayNameFromVehicleModel(joaat(spawnName))
        local label = labelText(modelKey, spawnName)
        elements[#elements + 1] = {
            label = (T('%s [%s] hinzufügen')):format(label, spawnName),
            value = spawnName
        }
    end
    Menu.open(societyMenu, {
        title = T('Fahrzeug zum Fuhrpark hinzufügen'),
        align = 'top-left',
        elements = elements
    }, function(data)
        request('societyAddVehicle', garageId, function(plate)
            Menu.closeAll()
            Framework.Notify((T('Fahrzeug %s wurde im Fuhrpark eingeparkt.')):format(plate))
        end, data.current.value)
    end, function(_, menu) menu.close() end)
end

local filters = {
    { label = T('Alle'), value = 'all' },
    { label = T('Hier'), value = 'here' },
    { label = T('Andere Garage'), value = 'other' },
    { label = T('Draußen'), value = 'outside' }
}

local function matchesLocation(vehicle, filter)
    if filter == 'here' then return vehicle.status == 'stored' and not vehicle.parkedElsewhere end
    if filter == 'other' then return vehicle.parkedElsewhere end
    if filter == 'outside' then return vehicle.status == 'outside' end
    return true
end

local function searchKey(value)
    return value:lower():gsub('Ä', 'ä'):gsub('Ö', 'ö'):gsub('Ü', 'ü'):gsub('%s+', '')
end

local function openGarage(garageId, garage)
    request('list', garageId, function(vehicles)
        if #(GetEntityCoords(PlayerPedId()) - garage.marker) > Config.InteractionDistance then return end
        local canAdd = canUseGarage(garage, true) and #(garage.society.models or {}) > 0
        local private = not garage.society
        local profile = Config.Interiors[garage.interior]
        if profile and profile.resource and GetResourceState(profile.resource) ~= 'started' then profile = nil end
        local scope = 'all'
        local insideCount = 0
        local query, filter = '', filters[1]
        for _, vehicle in ipairs(vehicles) do
            local model = GetDisplayNameFromVehicleModel(vehicle.model)
            local name = labelText(model, model or T('Unbekannt'))
            vehicle.title = ('%s [%s]'):format(name, vehicle.plate)
            vehicle.name = name
            if vehicle.parkedInside then insideCount = insideCount + 1 end
            vehicle.searchName, vehicle.searchPlate = searchKey(name), searchKey(vehicle.plate)
        end

        local function renderList()
            if #(GetEntityCoords(PlayerPedId()) - garage.marker) > Config.InteractionDistance then return end
            local elements, matches = {}, {}
            local needle = searchKey(query)
            for index, vehicle in ipairs(vehicles) do
                local inScope = scope == 'all' or (scope == 'inside' and vehicle.parkedInside)
                    or (scope == 'other' and not vehicle.parkedInside)
                if inScope and matchesLocation(vehicle, filter.value)
                    and (needle == '' or vehicle.searchName:find(needle, 1, true) or vehicle.searchPlate:find(needle, 1, true)) then
                    matches[#matches + 1] = index
                end
            end
            table.sort(matches, function(a, b)
                if vehicles[a].favorite ~= vehicles[b].favorite then return vehicles[a].favorite end
                return a < b
            end)
            for _, index in ipairs(matches) do
                local vehicle = vehicles[index]
                local location = vehicle.remoteGarage or (vehicle.parkedElsewhere and vehicle.parkedLabel)
                local status = vehicle.status == 'stored' and location or statuses[vehicle.status]
                local warning = vehicle.blocked and T('Motorsperre') or vehicle.wrongFuel and T('Fehlbetankung') or nil
                local saved = vehicle.status == 'outside' and not vehicle.fuelLive and type(vehicle.fuel) == 'number'
                elements[#elements + 1] = {
                    label = vehicle.name, plate = vehicle.plate, status = status, statusCode = vehicle.status,
                    fuel = percent(vehicle.fuel, 100), fuelValue = vehicle.fuel, fuelSaved = saved,
                    engine = percent(vehicle.engine, 1000), body = percent(vehicle.body, 1000),
                    conditionSaved = vehicle.status == 'outside' and not vehicle.conditionLive,
                    favorite = vehicle.favorite, warning = warning,
                    value = index
                }
            end
            if #matches == 0 then
                local empty = #vehicles == 0 and T('Keine Fahrzeuge vorhanden') or T('Keine passenden Fahrzeuge')
                if scope == 'inside' and insideCount == 0 then empty = T('Keine Fahrzeuge in dieser Garage') end
                if scope == 'other' and #vehicles == insideCount then empty = T('Keine anderen Fahrzeuge vorhanden') end
                elements[#elements + 1] = { label = empty, value = 'info' }
            end
            if scope == 'all' then
                if insideCount > 0 then
                    elements[#elements + 1] = { label = T('Fahrzeuge in dieser Garage anzeigen'), value = 'show_inside' }
                end
                if profile and #vehicles > insideCount then
                    elements[#elements + 1] = { label = T('Andere Fahrzeuge anzeigen'), value = 'show_other' }
                end
            else
                elements[#elements + 1] = { label = T('Alle Fahrzeuge anzeigen'), value = 'show_all' }
            end
            if canAdd then elements[#elements + 1] = { label = T('Fahrzeug zum Fuhrpark hinzufügen'), value = 'society_add' } end
            if private and #vehicles > 0 then
                elements[#elements + 1] = { label = T('Listenoptionen'), value = 'options' }
            end

            local function openOptions(list)
                local options = {
                    { label = query == '' and T('Fahrzeug suchen') or T('Suche · ') .. query, value = 'search' }
                }
                if scope ~= 'inside' then
                    options[#options + 1] = { label = T('Standort · ') .. filter.label, value = 'filter' }
                end
                if query ~= '' then
                    options[#options + 1] = { label = T('Suche zurücksetzen'), value = 'clear_search' }
                end
                Menu.open(listOptionsMenu, {
                    title = T('Listenoptionen'), align = 'top-left', elements = options
                }, function(data, menu)
                    local action = data.current.value
                    if action == 'search' then
                        searching = true
                        Menu.suspend(true)
                        menu.close()
                        list.close()
                        AddTextEntry('DAGARAGE_SEARCH', T('Modell oder Kennzeichen suchen'))
                        DisplayOnscreenKeyboard(1, 'DAGARAGE_SEARCH', '', query, '', '', '', 48)
                        CreateThread(function()
                            local state = UpdateOnscreenKeyboard()
                            while state == 0 do
                                Wait(0)
                                state = UpdateOnscreenKeyboard()
                            end
                            if state == 1 then query = (GetOnscreenKeyboardResult() or ''):match('^%s*(.-)%s*$') end
                            searching = false
                            Menu.suspend(false)
                            renderList()
                        end)
                    elseif action == 'clear_search' then
                        query = ''
                        menu.close()
                        list.close()
                        renderList()
                    elseif action == 'filter' then
                        Menu.open(filterMenu, {
                            title = T('Standort'), align = 'top-left', elements = filters
                        }, function(selection, picker)
                            filter = selection.current
                            picker.close()
                            menu.close()
                            list.close()
                            renderList()
                        end, function(_, picker) picker.close() end)
                    end
                end, function(_, menu) menu.close() end)
            end

            Menu.open(menuName, {
                title = garage.label,
                subtitle = scope == 'inside' and T('Fahrzeuge in dieser Garage') or scope == 'other' and T('Andere Fahrzeuge') or T('Fahrzeugliste'),
                layout = 'vehicles', elements = elements
            }, function(data, menu)
                local index = data.current.value
                if busy then return end
                if index == 'show_all' or index == 'show_inside' or index == 'show_other' then
                    scope = index:sub(6)
                    filter = filters[1]
                    menu.close()
                    return renderList()
                end
                if index == 'society_add' and canAdd then return openSocietyModels(garageId, garage) end
                if index == 'options' then return openOptions(menu) end
                local vehicle = vehicles[index]
                if vehicle then openDetails(garageId, vehicle, vehicle.title, menu, private and renderList or nil) end
            end, function(_, menu) menu.close() end)
        end
        if not profile then return renderList() end
        local capacity = Config.GetGarageCapacity(garage)
        local parkedLabel = capacity and (T('%d / %d Fahrzeuge eingeparkt')):format(insideCount, capacity)
            or (insideCount == 1 and T('1 Fahrzeug hier eingeparkt') or (T('%d Fahrzeuge hier eingeparkt')):format(insideCount))
        Menu.open(entranceMenu, {
            title = garage.label,
            layout = 'entrance',
            elements = {
                { label = T('Garage betreten'), value = 'enter', description = parkedLabel },
                { label = T('Fahrzeuge in dieser Garage anzeigen'), value = 'inside', description = T('Details, Vorschau und Ausparken') },
                { label = T('Andere Fahrzeuge anzeigen'), value = 'browse',
                    description = T('Fahrzeuge draußen, an anderen Standorten oder ohne Stellplatz') }
            }
        }, function(data)
            if busy then return end
            if data.current.value == 'enter' then
                Menu.closeAll()
                return enterInterior(garageId, profile)
            end
            scope = data.current.value == 'inside' and 'inside' or 'other'
            query, filter = '', filters[1]
            renderList()
        end)
    end)
end

local function handleInterior(session, ped)
    if session.transitioning then
        hideLookCard()
        DisableControlAction(0, 71, true)
        DisableControlAction(0, 72, true)
        DisableControlAction(0, 75, true)
        return
    end
    if not canUseGarage(Config.Garages[session.garageId], false) then
        return exitInterior(session)
    end
    local coords = GetEntityCoords(ped)
    local vehicle = GetVehiclePedIsIn(ped, false)
    local props = session.display[vehicle]
    local onFoot = vehicle == 0
    if Menu.any() then
        hideLookCard()
        session.driveOut = nil
        DisableControlAction(0, 71, true)
        DisableControlAction(0, 72, true)
        return
    end
    local now = GetGameTimer()
    local lookedVehicle, lookedProps
    if onFoot and not session.loading then
        lookedVehicle, lookedProps = lookedAtVehicle(session, ped, coords, now)
    end
    showLookCard(lookedVehicle, lookedProps, now)
    if lookedVehicle then
        vehicle, props = lookedVehicle, lookedProps
    elseif onFoot then
        local closestDistance = 3.0
        for display, entry in pairs(session.display) do
            if DoesEntityExist(display) then
                local distance = #(coords - GetEntityCoords(display))
                if distance < closestDistance then
                    vehicle, props, closestDistance = display, entry, distance
                end
            end
        end
    end
    local help = {}
    if props then
        if not lookCard then help[#help + 1] = T('~INPUT_VEH_HEADLIGHT~ Fahrzeugdaten') end
        if IsControlJustReleased(0, 74) then return openInteriorInfo(session, vehicle, props) end
    end
    local door, station = session.profile.door, session.profile.slotStation
    if onFoot then
        DrawMarker(1, door.x, door.y, door.z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
            1.15, 1.15, 0.3, 104, 219, 167, 180, false, false, 2, false, nil, nil, false)
        local exitDistance = #(coords - door)
        local stationDistance = math.huge
        if station and canAssignSlot(session) then
            stationDistance = #(coords - station)
            DrawMarker(1, station.x, station.y, station.z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                1.35, 1.35, 0.35, 255, 163, 111, 185, false, false, 2, false, nil, nil, false)
        end
        if stationDistance < 2.25 and stationDistance < exitDistance then
            help[#help + 1] = T('~INPUT_CONTEXT~ Stellplätze verwalten')
            if IsControlJustReleased(0, 38) then return openSlotStation(session) end
        elseif exitDistance < 2.5 then
            help[#help + 1] = T('~INPUT_CONTEXT~ Garage zu Fuß verlassen')
            if IsControlJustReleased(0, 38) then return exitInterior(session) end
        end
    end
    if onFoot and session.lastPage > 1 and not session.loading then
        local nextPage = session.page
        repeat
            nextPage = nextPage % session.lastPage + 1
        until session.pages[nextPage] or nextPage == session.page
        if nextPage ~= session.page then
            help[#help + 1] = T('~INPUT_DETONATE~ Weitere Stellplätze anzeigen')
            if IsControlJustReleased(0, 47) then showPage(session, nextPage) end
        end
    end
    local drivePressed = IsControlPressed(0, 71) or IsControlPressed(0, 72)
    if not onFoot and props and GetPedInVehicleSeat(vehicle, -1) == ped then
        help[#help + 1] = T('~INPUT_VEH_ACCELERATE~ / ~INPUT_VEH_BRAKE~ Ausparken')
        if drivePressed then
            if IsEntityPositionFrozen(vehicle) then FreezeEntityPosition(vehicle, false) end
            local drive = session.driveOut
            if not drive or drive.vehicle ~= vehicle then
                session.driveOut = nil
                if math.abs(GetEntitySpeedVector(vehicle, true).y) > 0.12 then
                    session.driveOut = { vehicle = vehicle, startedAt = now }
                end
            elseif not drive.triggered and now - drive.startedAt >= 350 then
                drive.triggered = true
                return exitInterior(session, props.plate, vehicle)
            end
        else
            session.driveOut = nil
        end
    else
        session.driveOut = nil
    end
    if #help > 0 then Framework.Help(table.concat(help, '  ·  ')) end
end

local function storeVehicle(garageId, vehicle)
    if not NetworkGetEntityIsNetworked(vehicle) then return Framework.Notify(T('Ungültiges Fahrzeug.')) end
    local properties = Framework.GetVehicleProperties(vehicle)
    if not properties then return Framework.Notify(T('Die Fahrzeugdaten konnten nicht gelesen werden.')) end
    -- Explicit false lets the server distinguish removed custom paint from an older snapshot.
    properties.customPrimaryColor = properties.customPrimaryColor or false
    properties.customSecondaryColor = properties.customSecondaryColor or false
    properties.customXenonColor = properties.customXenonColor or false
    local fuel = GetVehicleFuelLevel(vehicle)
    if Config.GetFuel then
        local ok, level = pcall(Config.GetFuel, vehicle)
        if ok and type(level) == 'number' and level >= 0 and level <= 100 then
            fuel = level
        end
    end
    request('store', garageId, function()
        Framework.Notify(T('Fahrzeug eingeparkt.'))
    end, VehToNet(vehicle), {
        fuel = fuel,
        engine = GetVehicleEngineHealth(vehicle),
        body = GetVehicleBodyHealth(vehicle),
        tank = GetVehiclePetrolTankHealth(vehicle),
        properties = properties
    })
end

local function updateGarageBlip(id, garage)
    if garageBlips[id] then RemoveBlip(garageBlips[id]) end
    garageBlips[id] = nil
    if not garage then return end
    local blip = AddBlipForCoord(garage.marker.x, garage.marker.y, garage.marker.z)
    SetBlipSprite(blip, 357)
    SetBlipColour(blip, 3)
    SetBlipScale(blip, 0.75)
    SetBlipAsShortRange(blip, true)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(T('Garage'))
    EndTextCommandSetBlipName(blip)
    garageBlips[id] = blip
end

local function applyGarageLocations(version, records)
    if version <= garageVersion then return end
    for id in pairs(databaseGarages) do
        if not records[id] then
            Config.Garages[id] = nil
            updateGarageBlip(id)
        end
    end
    for id, record in pairs(records) do
        local previous = databaseGarages[id]
        if not previous or previous.revision ~= record.revision then
            local definition = record.definition
            local marker, spawn = definition.marker, definition.spawn
            local garage = {
                label = record.label,
                marker = vector3(marker.x, marker.y, marker.z),
                spawn = vector4(spawn.x, spawn.y, spawn.z, spawn.w),
                interior = definition.interior,
                society = definition.society and (Config.AdminSocieties[definition.society] or { job = false }) or nil
            }
            Config.Garages[id] = garage
            updateGarageBlip(id, garage)
        end
    end
    databaseGarages, garageVersion = records, version
end

RegisterNetEvent('DaGarage:garageLocations', function(version, records)
    if source == 65535 then applyGarageLocations(version, records) end
end)

local function loadGarageLocations()
    Framework.TriggerCallback('DaGarage:garageLocations', applyGarageLocations)
end

local openAdminList

local function adminRequest(action, callback, ...)
    if adminBusy then return end
    adminBusy = true
    Framework.TriggerCallback('DaGarage:' .. action, function(result, message)
        adminBusy = false
        if result then callback(result) else Framework.Notify(message or T('Die Änderung ist fehlgeschlagen.')) end
    end, ...)
end

local function locationLabel(point)
    if not point then return T('nicht gesetzt') end
    return ('%.1f, %.1f, %.1f'):format(point.x, point.y, point.z)
end

local function profileLabel(profiles, key, fallback)
    local profile = profiles[key]
    return (profile and profile.label and T(profile.label)) or key or T(fallback)
end

local function parseAdminPosition(input, needsHeading)
    local expected = needsHeading and 4 or 3
    input = input:gsub('[%(%)]', '')
    for _, pattern in ipairs({ '[^%s;]+', '[^,%s;]+' }) do
        local coordinates = {}
        for part in input:gmatch(pattern) do
            local value = tonumber((part:gsub(',', '.')))
            if not value or math.abs(value) >= 100000 then break end
            coordinates[#coordinates + 1] = value
        end
        local _, parts = input:gsub(pattern, '')
        if #coordinates == expected and parts == expected then
            return { x = coordinates[1], y = coordinates[2], z = coordinates[3], w = coordinates[4] }
        end
    end
end

local function openAdminEditor(draft)
    local definition = draft.definition
    local limit = Config.GetGarageCapacity(definition)
    local capacityLabel = limit and (T('%d Stellplätze')):format(limit) or T('Unbegrenzt')
    local elements = {
        { label = T('Name · ') .. (draft.label ~= '' and draft.label or T('nicht gesetzt')), value = 'label' },
        { label = T('Eingang · ') .. locationLabel(definition.marker), value = 'marker' },
        { label = T('Ausparkpunkt · ') .. locationLabel(definition.spawn), value = 'spawn' },
        { label = T('Innenraum · ') .. profileLabel(Config.Interiors, definition.interior, 'Keiner'), value = 'interior' },
        { label = T('Kapazität · ') .. capacityLabel, value = 'info' },
        { label = T('Fuhrpark · ') .. profileLabel(Config.AdminSocieties, definition.society, 'Privat'), value = 'society' },
        { label = T('Standort speichern'), value = 'save' }
    }
    if draft.id then elements[#elements + 1] = { label = T('Standort löschen'), value = 'delete' } end

    local function save(action, editor, confirm)
        adminRequest('adminSave', function(snapshot)
            applyGarageLocations(snapshot.version, snapshot.records)
            if confirm then confirm.close() end
            editor.close()
            Framework.Notify(action == 'delete' and T('Standort gelöscht.') or T('Standort gespeichert.'))
            openAdminList()
        end, {
            action = action, id = draft.id, revision = draft.revision,
            label = draft.label, definition = definition
        })
    end

    Menu.open(adminMenu, {
        title = draft.id and T('Garagenstandort bearbeiten') or T('Garagenstandort anlegen'),
        align = 'top-left',
        elements = elements
    }, function(data, menu)
        if adminBusy then return end
        local field = data.current.value
        if field == 'marker' or field == 'spawn' then
            local function applyPoint(point)
                definition[field] = point
                openAdminEditor(draft)
            end
            return Menu.open(adminChoiceMenu, {
                title = field == 'marker' and T('Eingang setzen') or T('Ausparkpunkt setzen'),
                elements = {
                    { label = T('Aktuelle Position übernehmen'), value = 'here' },
                    { label = T('Zur Stelle laufen und mit E setzen'), value = 'place' },
                    { label = T('Koordinaten eingeben'), value = 'coords' }
                }
            }, function(selection, picker)
                if adminBusy then return end
                local choice = selection.current.value
                if choice == 'here' then
                    return adminRequest('adminPosition', function(point)
                        if Menu.get(adminChoiceMenu) ~= picker then return end
                        picker.close()
                        menu.close()
                        applyPoint(point)
                    end)
                end
                picker.close()
                menu.close()
                if choice == 'place' then
                    adminPlacement = { apply = applyPoint, cancel = function() openAdminEditor(draft) end }
                    return
                end
                local point = definition[field]
                local initial = point and ('%.3f %.3f %.3f'):format(point.x, point.y, point.z) or ''
                if point and field == 'spawn' then initial = initial .. (' %.3f'):format(point.w) end
                searching = true
                AddTextEntry('DAGARAGE_ADMIN_COORDS', field == 'spawn' and T('X Y Z und Blickrichtung eingeben') or T('X Y Z eingeben'))
                DisplayOnscreenKeyboard(1, 'DAGARAGE_ADMIN_COORDS', '', initial, '', '', '', 100)
                CreateThread(function()
                    local state = UpdateOnscreenKeyboard()
                    while state == 0 do
                        Wait(0)
                        state = UpdateOnscreenKeyboard()
                    end
                    searching = false
                    if state == 1 then
                        local parsed = parseAdminPosition(GetOnscreenKeyboardResult() or '', field == 'spawn')
                        if parsed then return applyPoint(parsed) end
                        Framework.Notify(T('Ungültige Koordinaten. Trenne die Werte mit Leerzeichen.'))
                    end
                    openAdminEditor(draft)
                end)
            end)
        end
        if field == 'label' then
            searching = true
            menu.close()
            AddTextEntry('DAGARAGE_ADMIN_INPUT', T('Name der Garage'))
            DisplayOnscreenKeyboard(1, 'DAGARAGE_ADMIN_INPUT', '', draft.label, '', '', '', 100)
            CreateThread(function()
                local state = UpdateOnscreenKeyboard()
                while state == 0 do
                    Wait(0)
                    state = UpdateOnscreenKeyboard()
                end
                if state == 1 then draft.label = GetOnscreenKeyboardResult() or '' end
                searching = false
                openAdminEditor(draft)
            end)
            return
        end
        if field == 'interior' or field == 'society' then
            local choices = { { label = field == 'interior' and T('Kein Innenraum') or T('Privat'), value = '' } }
            local profiles = field == 'interior' and Config.Interiors or Config.AdminSocieties
            for profile in pairs(profiles) do
                local count = field == 'interior' and Config.GetGarageCapacity({ interior = profile })
                local name = profileLabel(profiles, profile)
                local label = count and (T('%s · %d Fahrzeuge insgesamt')):format(name, count) or name
                choices[#choices + 1] = { label = label, value = profile }
            end
            return Menu.open(adminChoiceMenu, {
                title = field == 'interior' and T('Innenraum auswählen') or T('Fuhrpark auswählen'),
                align = 'top-left', elements = choices
            }, function(selection, picker)
                local choice = selection.current.value
                definition[field] = choice ~= '' and choice or nil
                picker.close()
                menu.close()
                openAdminEditor(draft)
            end, function(_, picker) picker.close() end)
        end
        if field == 'save' then return save(draft.id and 'update' or 'create', menu) end
        if field == 'delete' then
            return Menu.open(adminChoiceMenu, {
                title = T('Standort entfernen?'),
                align = 'top-left',
                elements = { { label = T('Abbrechen'), value = 'cancel' }, { label = T('Standort löschen'), value = 'delete' } }
            }, function(selection, confirm)
                if selection.current.value == 'delete' then save('delete', menu, confirm) else confirm.close() end
            end, function(_, confirm) confirm.close() end)
        end
    end, function(_, menu)
        if adminBusy then return end
        menu.close()
        openAdminList()
    end)
end

openAdminList = function()
    local locations = {}
    for id, garage in pairs(Config.Garages) do
        local record = databaseGarages[id]
        local label = garage.label
        locations[#locations + 1] = { label = record and label or label .. ' (Config)', value = id }
    end
    table.sort(locations, function(a, b) return a.label < b.label end)
    table.insert(locations, 1, { label = T('Standort anlegen'), value = 'new' })
    Menu.open(adminMenu, {
        title = T('Garagen verwalten'), align = 'top-left', elements = locations
    }, function(data, menu)
        local id = data.current.value
        if id == 'new' then
            menu.close()
            return openAdminEditor({ label = '', definition = { interior = 'gta' } })
        end
        local record = databaseGarages[id]
        if not record then return Framework.Notify(T('Dieser Standort wird in config.lua verwaltet.')) end
        menu.close()
        openAdminEditor({
            id = record.id, revision = record.revision, label = record.label,
            definition = {
                marker = record.definition.marker, spawn = record.definition.spawn,
                interior = record.definition.interior, society = record.definition.society
            }
        })
    end, function(_, menu) menu.close() end)
end

RegisterNetEvent('DaGarage:openAdmin', function(version, records)
    if source ~= 65535 or interior or preview or busy or adminBusy or searching or adminPlacement then return end
    applyGarageLocations(version, records)
    Menu.closeAll()
    openAdminList()
end)

CreateThread(function()
    for id, garage in pairs(Config.Garages) do updateGarageBlip(id, garage) end
    loadGarageLocations()

    while true do
        local sleep = 750
        local ped = PlayerPedId()
        if adminPlacement then
            local placement = adminPlacement
            Framework.Help(T('~INPUT_CONTEXT~ Position übernehmen  ·  ~INPUT_FRONTEND_PAUSE_ALTERNATE~ Abbrechen'))
            DisableControlAction(0, 200, true)
            if not adminBusy and IsDisabledControlJustReleased(0, 200) then
                adminPlacement = nil
                placement.cancel()
            elseif not adminBusy and IsControlJustReleased(0, 38) then
                adminRequest('adminPosition', function(point)
                    if adminPlacement ~= placement then return end
                    adminPlacement = nil
                    placement.apply(point)
                end)
            end
            Wait(0)
            goto continue
        end
        if interior then
            handleInterior(interior, ped)
            Wait(0)
            goto continue
        end
        if preview then
            DisableControlAction(0, 30, true)
            DisableControlAction(0, 31, true)
            DisableControlAction(0, 24, true)
            DisableControlAction(0, 25, true)
            Wait(0)
            goto continue
        end
        local position = GetEntityCoords(ped)
        local nearest, nearestDistance = nil, Config.InteractionDistance
        for id, garage in pairs(Config.Garages) do
            local distance = #(position - garage.marker)
            if distance < Config.DrawDistance then
                sleep = 0
                local marker = garage.marker
                DrawMarker(1, marker.x, marker.y, marker.z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                    3.0, 3.0, 0.35, 40, 150, 225, 130, false, false, 2, false, nil, nil, false)
            end
            if distance < nearestDistance and canUseGarage(garage, false) then nearest, nearestDistance = id, distance end
        end
        if nearest and not busy and not searching and not Menu.any() then
            local garage = Config.Garages[nearest]
            local vehicle = GetVehiclePedIsIn(ped, false)
            if vehicle == 0 then
                local profile = Config.Interiors[garage.interior]
                local help = T('~INPUT_CONTEXT~ Garage öffnen')
                if profile then
                    help = help .. '  ·  ~INPUT_DETONATE~ Garage betreten'
                    DisableControlAction(0, 47, true)
                end
                Framework.Help(help)
                if IsControlJustReleased(0, 38) then
                    openGarage(nearest, garage)
                elseif profile and IsDisabledControlJustReleased(0, 47) then
                    enterInterior(nearest, profile)
                end
            elseif GetPedInVehicleSeat(vehicle, -1) == ped then
                Framework.Help(T('~INPUT_CONTEXT~ Fahrzeug einparken'))
                if IsControlJustReleased(0, 38) then storeVehicle(nearest, vehicle) end
            end
        end
        Wait(sleep)
        ::continue::
    end
end)

AddEventHandler('onResourceStop', function(stopped)
    if stopped ~= resource then return end
    if searching then CancelOnscreenKeyboard() end
    for _, blip in pairs(garageBlips) do RemoveBlip(blip) end
    Menu.closeAll()
    hideLookCard()
    closePreview()
    if interior then
        local session = interior
        interior = nil
        clearInteriorVehicles(session)
        if session.room then UnpinInterior(session.room) end
        movePed(Config.Garages[session.garageId].marker, false)
        DoScreenFadeIn(0)
    end
end)

local function recoverInterior()
    if interior then return end
    Framework.TriggerCallback('DaGarage:recoverInterior', function(saved)
        if saved and not interior then finishInterior({ garageId = saved.garageId, marker = saved.marker, display = {} }) end
    end)
end

RegisterCommand('garageverlassen', function()
    if GetVehiclePedIsIn(PlayerPedId(), false) ~= 0 or busy then return end
    if interior then
        Menu.closeAll()
        exitInterior(interior)
    else
        recoverInterior()
    end
end, false)

if Framework.Name == 'qbcore' then
    RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function()
        loadGarageLocations()
        SetTimeout(1500, recoverInterior)
    end)
else
    AddEventHandler('esx:onPlayerSpawn', function() SetTimeout(1500, recoverInterior) end)
    RegisterNetEvent('esx:playerLoaded', loadGarageLocations)
end
CreateThread(function()
    if Framework.IsPlayerLoaded() then recoverInterior() end
end)
