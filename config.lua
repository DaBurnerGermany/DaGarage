Config = {}

Config.Locale = 'en' -- 'en' or 'de'
-- Enable myFuel tank initialization, fuel type and misfueling data.
Config.UseMyFuelTankData = true

-- Client hooks. Replace these functions for other fuel scripts, or set them to nil for native fuel levels.
Config.GetFuel = function(vehicle, theme)
    if GetResourceState('myFuel') == 'started' then
        return exports.myFuel:GetFuel(vehicle)
    else
        return nil
    end 
end

Config.SetFuel = function(vehicle, level)
    if GetResourceState('myFuel') == 'started' then
        exports.myFuel:SetFuel(vehicle, level)
    end
end

Config.UIColors = {
    accent = '#ffa36f',
    selected = '#39271f',
    background = '#121719',
    card = '#191f22',
    border = '#30383b',
    text = '#f2f4f3',
    muted = '#a8b3b6',
    success = '#8adeb6',
    danger = '#ffb09e'
}

Config.DrawDistance = 25.0
Config.InteractionDistance = 4.0
Config.SpawnClearance = 4.0
Config.RecoverMissingVehicles = true

-- 'shared': retrieve your vehicles from any garage that serves the same owner or fleet.
-- 'local': vehicles are assigned to the garage where they were last parked.
Config.GarageMode = 'shared'
-- Local mode only. false disables remote retrieval; a number sets the cash fee.
Config.RemoteRetrievalFee = false

-- Profiles use built-in GTA interiors or an installed MLO.
-- MLO profiles use the same fields and may set resource = 'my_mlo'.
Config.Interiors = {
    gta_klein = {
        label = 'Small GTA garage',
        entry = vector4(174.1, -1007.2, -99.0, 0.0),
        door = vector3(171.7, -1007.4, -99.0),
        slotStation = vector3(177.6, -1007.3, -99.0),
        checkClearance = true,
        slots = {
            vector4(170.7, -1003.9, -99.0, 180.0),
            vector4(175.6, -1003.9, -99.0, 180.0)
        }
    },
    gta_mittel = {
        label = 'Medium GTA garage',
        entry = vector4(198.4, -1006.3, -99.0, 0.0),
        door = vector3(196.7, -1006.3, -99.0),
        slotStation = vector3(201.0, -1000.0, -99.0),
        checkClearance = true,
        slots = {
            vector4(194.0, -995.8, -99.0, 225.0),
            vector4(202.1, -997.8, -99.0, 175.0),
            vector4(198.3, -997.5, -99.0, 175.0),
            vector4(194.1, -1002.3, -99.0, 190.0)
        },
        slotAlternatives = {
            vector4(194.9, -996.4, -99.0, 195.0),
            vector4(202.3, -998.7, -99.0, 175.0),
            vector4(198.6, -998.4, -99.0, 180.0),
            vector4(194.7, -1002.7, -99.0, 180.0)
        }
    },
    gta = {
        label = 'Standard GTA garage',
        entry = vector4(225.5, -1001.0, -99.0, 0.0),
        door = vector3(225.5, -1001.0, -99.0),
        slotStation = vector3(228.6, -984.0, -99.0),
        checkClearance = true,
        slots = {
            vector4(224.0, -987.5, -99.0, 270.0),
            vector4(224.0, -992.0, -99.0, 270.0),
            vector4(224.0, -996.5, -99.0, 270.0),
            vector4(233.2, -987.5, -99.0, 90.0),
            vector4(233.2, -992.0, -99.0, 90.0),
            vector4(233.2, -996.5, -99.0, 90.0)
        },
        slotAlternatives = {
            vector4(224.7, -987.5, -99.0, 270.0),
            vector4(224.7, -992.0, -99.0, 270.0),
            vector4(224.7, -996.5, -99.0, 270.0),
            vector4(232.5, -987.5, -99.0, 90.0),
            vector4(232.5, -992.0, -99.0, 90.0),
            vector4(232.5, -996.5, -99.0, 90.0)
        }
    }
}

-- The large profile uses the built-in ten-car interior with two pages of six spaces.
local gtaInterior = Config.Interiors.gta
Config.Interiors.gta_gross = {
    label = 'Large GTA garage',
    entry = gtaInterior.entry, door = gtaInterior.door, slotStation = gtaInterior.slotStation,
    slots = gtaInterior.slots, pages = 2,
    checkClearance = gtaInterior.checkClearance, slotAlternatives = gtaInterior.slotAlternatives
}

function Config.GetGarageCapacity(garage)
    local profile = Config.Interiors[garage.interior]
    if profile and #profile.slots > 0 then return #profile.slots * (profile.pages or 1) end
end

Config.InteriorBucketBase = 50000
Config.Preview = vector4(228.6, -989.5, -99.0, 180.0)

-- Optional Society profiles for locations created in the admin menu.
Config.AdminSocieties = {
    police = {
        label = 'Police fleet',
        job = 'police',
        minGrade = 0,
        manageGrade = 3,
        models = { 'police', 'police2' }
    }
}

Config.Garages = {
    -- Example of an additional location:
    -- police_fleet = {
    --     label = 'Police fleet',
    --     marker = vector3(454.6, -1017.4, 28.4),
    --     spawn = vector4(438.4, -1018.3, 28.6, 90.0),
    --     interior = 'gta',
    --     society = { job = 'police', minGrade = 0, manageGrade = 3, models = { 'police', 'police2' } }
    -- },
    vespucci = {
        label = 'Vespucci Boulevard Garage',
        marker = vector3(-285.2, -886.5, 31.0),
        spawn = vector4(-309.3, -897.0, 31.0, 351.9),
        interior = 'gta'
    },
    legion = {
        label = 'San Andreas Avenue Garage',
        marker = vector3(216.4, -786.6, 30.8),
        spawn = vector4(218.9, -779.7, 30.8, 340.0),
        interior = 'gta'
    }
}
