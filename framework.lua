GarageFramework = {}
local bridge = GarageFramework
local mode = Config.Framework or 'auto'

if (mode == 'auto' or mode == 'esx') and GetResourceState('es_extended') == 'started' then
    bridge.Name = 'esx'
    bridge.Core = exports.es_extended:getSharedObject()
elseif (mode == 'auto' or mode == 'qbcore') and GetResourceState('qb-core') == 'started' then
    bridge.Name = 'qbcore'
    bridge.Core = exports['qb-core']:GetCoreObject()
end

local core = bridge.Core
if not core then
    print('[DaGarage] Start es_extended or qb-core before DaGarage and check Config.Framework.')
    return
end

local qbPropertyNames = {
    modCustomFrontWheels = 'modCustomTiresF',
    modCustomBackWheels = 'modCustomTiresR',
    modRoofLivery = 'liveryRoof',
    modLightbar = 'modKit49',
    doorsBroken = 'doorStatus',
    tyreBurst = 'tireBurstState'
}
local qbColorNames = {
    customPrimaryColor = 'color1',
    customSecondaryColor = 'color2',
    customXenonColor = 'xenonColor'
}

function bridge.FromQBProperties(props)
    for garageName, qbName in pairs(qbPropertyNames) do
        if props[qbName] ~= nil then props[garageName] = props[qbName] end
    end
    if type(props.windowStatus) == 'table' then
        props.windowsBroken = {}
        for window, intact in pairs(props.windowStatus) do
            if type(intact) == 'boolean' then props.windowsBroken[tostring(window)] = not intact end
        end
    end
    for garageName, qbName in pairs(qbColorNames) do
        if type(props[qbName]) == 'table' then
            props[garageName] = props[qbName]
            props[qbName] = nil
        end
    end
    return props
end

function bridge.ToQBProperties(props)
    local result = {}
    for key, value in pairs(props) do result[key] = value end
    for garageName, qbName in pairs(qbPropertyNames) do
        if props[garageName] ~= nil then result[qbName] = props[garageName] end
    end
    if type(props.windowsBroken) == 'table' then
        result.windowStatus = {}
        for window, broken in pairs(props.windowsBroken) do
            result.windowStatus[window] = not broken
        end
    end
    for garageName, qbName in pairs(qbColorNames) do
        if props[garageName] then result[qbName] = props[garageName] end
    end
    return result
end

if bridge.Name == 'esx' then
    if IsDuplicityVersion() then
        bridge.GetPlayer = core.GetPlayerFromId
        bridge.RegisterCallback = core.RegisterServerCallback
        bridge.GetVehicleType = core.GetVehicleType
        bridge.NotifyPlayer = function(source, message)
            TriggerClientEvent('esx:showNotification', source, message)
        end
        bridge.IsAdmin = function(source)
            local player = bridge.GetPlayer(source)
            local group = player and player.getGroup()
            return group == 'admin' or group == 'superadmin'
        end
    else
        bridge.TriggerCallback = core.TriggerServerCallback
        bridge.GetPlayerData = core.GetPlayerData
        bridge.IsPlayerLoaded = core.IsPlayerLoaded
        bridge.Notify = core.ShowNotification
        bridge.Help = core.ShowHelpNotification
        bridge.GetVehicleProperties = core.Game.GetVehicleProperties
        bridge.SetVehicleProperties = core.Game.SetVehicleProperties
    end
elseif IsDuplicityVersion() then
    bridge.RegisterCallback = core.Functions.CreateCallback
    bridge.GetPlayer = function(source)
        local player = core.Functions.GetPlayer(source)
        if not player then return end
        return {
            identifier = player.PlayerData.citizenid,
            getJob = function()
                local job = player.PlayerData.job
                return job and { name = job.name, grade = job.grade.level }
            end,
            getMoney = function() return player.Functions.GetMoney('cash') end,
            removeMoney = function(amount, reason) return player.Functions.RemoveMoney('cash', amount, reason) end
        }
    end
    bridge.IsAdmin = function(source)
        return core.Functions.GetPlayer(source) ~= nil and core.Functions.HasPermission(source, { 'admin', 'god' })
    end
    bridge.NotifyPlayer = function(source, message)
        TriggerClientEvent('QBCore:Notify', source, message)
    end
    bridge.GetVehicleType = function(model, _, reply)
        local hashes = core.Shared.VehicleHashes or {}
        local unsigned = model & 0xffffffff
        local signed = unsigned >= 0x80000000 and unsigned - 0x100000000 or unsigned
        local vehicle = hashes[signed] or hashes[unsigned]
        if not vehicle then
            for name, definition in pairs(core.Shared.Vehicles) do
                if (joaat(name) & 0xffffffff) == unsigned then
                    vehicle = definition
                    break
                end
            end
        end
        reply(vehicle and vehicle.type)
    end
    bridge.GrantVehicleKeys = function(source, plate)
        if GetResourceState('qb-vehiclekeys') == 'started' then
            local ok, err = pcall(function()
                exports['qb-vehiclekeys']:GiveKeys(source, plate:match('^%s*(.-)%s*$'))
            end)
            if not ok then print(('[DaGarage] qb-vehiclekeys GiveKeys failed: %s'):format(err)) end
        end
    end
else
    bridge.TriggerCallback = core.Functions.TriggerCallback
    bridge.Notify = core.Functions.Notify
    bridge.Help = function(message)
        BeginTextCommandDisplayHelp('STRING')
        AddTextComponentSubstringPlayerName(message)
        EndTextCommandDisplayHelp(0, false, false, -1)
    end
    bridge.IsPlayerLoaded = function() return LocalPlayer.state.isLoggedIn end
    bridge.GetPlayerData = function()
        local player = core.Functions.GetPlayerData()
        local job = player.job
        return { job = job and { name = job.name, grade = job.grade.level } }
    end
    bridge.GetVehicleProperties = function(vehicle)
        local props = core.Functions.GetVehicleProperties(vehicle)
        return props and bridge.FromQBProperties(props)
    end
    bridge.SetVehicleProperties = function(vehicle, props)
        core.Functions.SetVehicleProperties(vehicle, bridge.ToQBProperties(props))
    end
end
