-- ############################################################################# 
-- # Jeti ECU Telemetry
-- # Jeti Advanced ECU LUA Script. Easy telemetry displaying, advanced alarms, easy setup, very configurable, easy to setup new ecu types
-- # Some Lua ideas copied from Jeti and TeroS
-- #
-- # Copyright (c) 2017, Original idea by Thomas Ekdahl (thomas@ekdahl.no).
-- # Telemetry display code graphics borrowed from ECU data display made by Bernd Woköck
-- #
-- # License: Share alike                                       
-- # Can be used and changed non commercial, but feel free to send us changes back to be incorporated in the main code.
-- # If using parts of this project elsewhere, please give me credit for it
-- #                       
-- # Version: 3.0
-- ############################################################################# 

local loadh      = require "ecu/lib/loadhelper"
local tableh     = require "ecu/lib/tablehelper"
local alarmh     = require "ecu/lib/alarmhelper"
local sensorh    = require "ecu/lib/sensorhelper"
local fuelh      = require "ecu/lib/fuelhelper"
local logh       = require "ecu/lib/loghelper"
--local fake       = require "ecu/lib/fakesensor"
local window1    = require "ecu/lib/window1"
local window2    = require "ecu/lib/window2"
--local window3 = require "ecu/lib/window3"
--local window4 = require "ecu/lib/window4"

local APP_ROOT = "Apps/ecu"
local EMPTY_SENSOR = {value = 0, max = 0, valid = false}
-- Sensors that must be online for the ECU to count as online (alarm arming, OFFLINE display).
-- Optional sensors (rpm2, pumpv, ecuv, fuel, throttle...) can be missing without disabling the alarms.
local CRITICAL_SENSORS = {status = true, rpm = true, egt = true}
local FAULT_AUDIO = {enable = true, file = "Error.wav"}
local FAULT_REPEAT_SECONDS = 30
local OFFLINE_REPEAT_SECONDS = 15 -- repeat the ECU offline warning this often...
local OFFLINE_MAX_ALERTS = 5      -- ...at most this many times per offline period
local OFFLINE_AUDIO = {enable = true, file = "Ecu converter offline.wav"}

-- Monotonic seconds since the transmitter started. system.getTime() is the wall clock and jumps
-- when the date/time is changed, which would stretch or cut the alarm cooldown windows.
local function nowSeconds()
    return system.getTimeCounter() // 1000
end

logh.init("ECU")

local function newSensorEntry()
    return {
        sensor = {value = 0, max = 0, valid = false},
        percent = 0,
        text = nil
    }
end

local function newSensorTable()
    return {
        rpm = newSensorEntry(),
        rpm2 = newSensorEntry(),
        egt = newSensorEntry(),
        pumpv = newSensorEntry(),
        ecuv = newSensorEntry(),
        fuel = newSensorEntry(),
        status = newSensorEntry()
    }
end

-----------------------------------------------------------------------------
local config             = {}
local SensorT            = newSensorTable()
local enableAlarmAudio   = true
local enableAlarmHaptic  = true
local enableAlarmMessage = true
local fuelAlarm          = {}
local TankSize           = 0

-----------------------------------------------------------------------------
-- Locals for the application
local prevStatus = 0
local audioOffSwitch, hapticOffSwitch, messageOffSwitch = 0,0,0
local configValid = false

local lang              = {"..."} -- Language read from file

local alarmTriggeredTime   = { -- stores latest datetime on the alarm triggered, used to not repeat alarms to often
    rpm    = 0,
    rpm2   = 0,
    egt    = 0,
    pumpv  = 0,
    ecuv   = 0,
    fuel   = 0,  -- in ml from ecu
    status = 0,
    offline= 0,
    fuelsensorproblem = 0
}

local alarmLowValuePassed = { -- enables alarms once a sensor has reported a real value. Status alarm is always enabled. All others require a non-zero reading first so initialisation artifacts (0.0) never trigger false alarms.
    rpm    = false,
    rpm2   = false,
    egt    = false,
    pumpv  = false,
    ecuv   = false,  -- armed on first non-zero reading (not on low.value) so a 0.0 init reading never triggers
    fuel   = false,  -- in ml from ecu
    status = true
}

-- While the turbine is in a planned stop state (Stop, Cooling, Ready...) RPM, EGT and pump voltage
-- fall below their low limits on purpose, so those low alarms are not armed. Battery stays armed.
local STOP_GATED_SENSORS = {rpm = true, rpm2 = true, egt = true, pumpv = true}
local turbineStopped = false

local sensorState = {
    configured = 0,
    valid = 0,
    allOnline = false,
    hadFullSignal = false,
    offlineAlerts = 0, -- offline warnings given since the ECU was last online
    configError = false -- true when a sensor is selected but the configuration is unusable (no monitoring)
}

local nextFaultAlert = 0 -- system time of the next repeated "monitoring is off" warning

local SensorID              = 0
local ConverterTypeTable    = {"..."}   -- Array with all available turbine types
local ConverterType         = "vspeak"  -- the turbine type chosen

local TurbineTypeTable      = {"..."}   -- Array with all available turbine types
local TurbineType           = "hornet"  -- the turbine type chosen

local TurbineConfigTable    = {"..."}   -- Array with all available config fields
local TurbineConfig         = "generic"  -- the turbine config file chosen

local BatteryConfigTable    = {"..."}   -- Array with all available battery configs
local BatteryConfig         = "life-2s"  -- the battery config file chosen
local SensorMenuSensors     = {"..."}

----------------------------------------------------------------------
-- Reset low-value alarm activation flags.
local function resetAlarmLowValuePassed()
    for sensorName, _ in pairs(alarmLowValuePassed) do
        alarmLowValuePassed[sensorName] = (sensorName == "status")
    end
end

----------------------------------------------------------------------
-- Reset runtime monitoring state after configuration changes.
local function resetMonitoringState()
    prevStatus = 0
    turbineStopped = false
    SensorT = newSensorTable()
    sensorState.configured = 0
    sensorState.valid = 0
    sensorState.allOnline = false
    sensorState.hadFullSignal = false
    sensorState.offlineAlerts = 0

    for alarmKey, _ in pairs(fuelAlarm) do
        fuelAlarm[alarmKey] = nil
    end

    resetAlarmLowValuePassed()
end

----------------------------------------------------------------------
-- Check if a sensor mapping exists and is enabled.
local function hasSensorMapping(sensorName)
    return config.converter
        and config.converter.sensormap
        and tonumber(config.converter.sensormap[sensorName] or 0) > 0
end

----------------------------------------------------------------------
-- Validate the loaded configuration structure.
local requiredConfig  = {"converter", "fuel"}
local mappedSensors   = {"rpm", "rpm2", "egt", "pumpv", "ecuv", "fuel", "status"}
local thresholdSensors = {"rpm", "rpm2", "egt", "pumpv", "ecuv"}

local function validThreshold(threshold)
    return type(threshold) == "table" and type(threshold.value) == "number"
end

local function validateConfig()
    local sensorConfig

    if(not config or not next(config)) then
        logh.error("validateConfig", "ECU config missing", 3)
        return false
    end

    for _, configKey in ipairs(requiredConfig) do
        if(not config[configKey]) then
            logh.error("validateConfig", string.format("Missing config: %s", configKey), 3)
            return false
        end
    end

    if(not config.converter.sensormap) then
        logh.error("validateConfig", "Missing converter sensor map", 3)
        return false
    end

    for _, sensorName in ipairs(mappedSensors) do
        if(hasSensorMapping(sensorName) and not config[sensorName]) then
            logh.error("validateConfig", string.format("Missing sensor config: %s", sensorName), 3)
            return false
        end
    end

    if(hasSensorMapping("fuel") and not config.converter.fuel) then
        logh.error("validateConfig", "Missing converter fuel config", 3)
        return false
    end

    if(hasSensorMapping("status") and not config.converter.statusmap) then
        logh.error("validateConfig", "Missing status config", 3)
        return false
    end

    -- Alarm structure is dereferenced in the runtime loop, so reject incomplete presets here
    -- instead of failing later while the turbine is running.
    for _, sensorName in ipairs(thresholdSensors) do
        if(hasSensorMapping(sensorName)) then
            sensorConfig = config[sensorName]
            if(type(sensorConfig) ~= "table"
                or sensorConfig.sensorname ~= sensorName
                or not validThreshold(sensorConfig.high)
                or not validThreshold(sensorConfig.low)) then
                logh.error("validateConfig", string.format("Invalid high/low alarm config: %s", sensorName), 3)
                return false
            end
        end
    end

    if(hasSensorMapping("fuel")) then
        sensorConfig = config.fuel
        if(type(sensorConfig) ~= "table"
            or sensorConfig.sensorname ~= "fuel"
            or type(sensorConfig.tanksize) ~= "number"
            or type(sensorConfig.sensorproblem) ~= "table"
            or type(sensorConfig.alarms) ~= "table") then
            logh.error("validateConfig", "Invalid fuel config", 3)
            return false
        end

        for _, alarm in ipairs(sensorConfig.alarms) do
            if(not validThreshold(alarm)) then
                logh.error("validateConfig", "Invalid fuel alarm threshold", 3)
                return false
            end
        end
    end

    if(hasSensorMapping("status")
        and (type(config.status) ~= "table" or config.status.sensorname ~= "status")) then
        logh.error("validateConfig", "Invalid status config", 3)
        return false
    end

    return true
end

----------------------------------------------------------------------
-- Menu tables start with a "..." placeholder entry that is not a real selection.
local PLACEHOLDER = "..."

local function pickEntry(options, index, fallback)
    local value = options[index]

    if(value == nil or value == PLACEHOLDER) then
        value = options[2]
    end

    if(value == nil or value == PLACEHOLDER) then
        return fallback
    end
    return value
end

local function realValue(value, default)
    if(type(value) ~= "string" or value == "" or value == PLACEHOLDER) then
        return default
    end
    return value
end

----------------------------------------------------------------------
-- Normalize turbine config selection after turbine changes.
local function refreshTurbineConfigSelection()
    local TurbineConfigIndex
    local configPath

    if(type(TurbineType) ~= "string" or TurbineType == "") then
        logh.error("refreshTurbineConfigSelection", string.format("Invalid turbine type: %s", tostring(TurbineType)), 3)
        return
    end

    configPath = string.format("%s/turbine/%s", APP_ROOT, TurbineType)
    TurbineConfigTable, TurbineConfigIndex = tableh.fromFiles(configPath, TurbineConfig)
    TurbineConfig = pickEntry(TurbineConfigTable, TurbineConfigIndex, TurbineConfig)
    system.pSave("TurbineConfig", TurbineConfig)
end

----------------------------------------------------------------------
-- Normalize turbine selections after a converter or turbine change.
local function refreshTurbineSelections()
    local TurbineTypeIndex
    local converterPath

    if(type(ConverterType) ~= "string" or ConverterType == "") then
        logh.error("refreshTurbineSelections", string.format("Invalid converter type: %s", tostring(ConverterType)), 3)
        return
    end

    converterPath = string.format("%s/converter/%s", APP_ROOT, ConverterType)
    TurbineTypeTable, TurbineTypeIndex = tableh.fromDirectory(converterPath, TurbineType)
    TurbineType = pickEntry(TurbineTypeTable, TurbineTypeIndex, TurbineType)
    system.pSave("TurbineType", TurbineType)

    refreshTurbineConfigSelection()
end

--------------------------------------------------------------------
-- Read the config file for a spesific turbine, this is the first config that has to be run
local function loadConfig()
    local selectionValues = {
        ConverterType = ConverterType,
        TurbineType = TurbineType,
        TurbineConfig = TurbineConfig,
        BatteryConfig = BatteryConfig
    }
    local currentConfig = loadh.fileJson(string.format("%s/turbine/%s/%s.jsn", APP_ROOT, TurbineType, TurbineConfig)) or {}

    for selectionName, selectionValue in pairs(selectionValues) do
        if(type(selectionValue) ~= "string" or selectionValue == "") then
            logh.error("loadConfig", string.format("Invalid %s selection: %s", selectionName, tostring(selectionValue)), 3)
            config = {}
            resetMonitoringState()
            return false
        end
    end

    -- Generic config loading adding to default turbine config
    currentConfig.ecuv = loadh.fileJson(string.format("%s/batterypack/%s.jsn", APP_ROOT, BatteryConfig))
    currentConfig.fuel = loadh.fileJson(string.format("%s/fuel/config.jsn", APP_ROOT))
    currentConfig.status = loadh.fileJson(string.format("%s/status/%s.jsn", APP_ROOT, TurbineType))
    currentConfig.converter = loadh.fileJson(string.format("%s/converter/%s/%s/config.jsn", APP_ROOT, ConverterType, TurbineType))

    config = currentConfig
    resetMonitoringState()

    return validateConfig()
end

----------------------------------------------------------------------
-- Validate selectbox values before applying runtime changes.
local function getSelectionValue(options, value, scope, selectionName)
    local index = tonumber(value)
    local selection

    if(not index) then
        logh.error(scope, string.format("Invalid %s selection index: %s", selectionName, tostring(value)), 3)
        return nil
    end

    selection = options and options[index]
    if(selection == PLACEHOLDER) then
        return nil -- "..." is not a selection, keep the current one
    end

    if(not selection) then
        logh.error(scope, string.format("Missing %s selection for index: %s", selectionName, tostring(value)), 3)
        return nil
    end

    return selection
end

----------------------------------------------------------------------
-- Reload config and keep callback-time errors visible in the logger.
local function reloadConfig(scope)
    local ok
    local result

    ok, result = pcall(loadConfig)
    if(ok) then
        configValid = (result == true)
    else
        configValid = false
        logh.error(scope, string.format("Configuration reload failed: %s", tostring(result)), 3)
    end

    sensorState.configError = not configValid
    return configValid
end

----------------------------------------------------------------------
-- Rebuild the form after menu changes that affect dependent selections.
local function reinitForm(scope)
    local ok
    local result

    ok, result = pcall(form.reinit, 1)
    if(not ok) then
        logh.error(scope, string.format("Form reinit failed: %s", tostring(result)), 3)
    end
end

----------------------------------------------------------------------
--
local function ConverterTypeChanged(value)
    local selection = getSelectionValue(ConverterTypeTable, value, "ConverterTypeChanged", "converter type")

    if(not selection) then
        return
    end

    ConverterType  = selection --The value is local to this function and not global to script, hence it must be set explicitly.
    system.pSave("ConverterType",  ConverterType)
    refreshTurbineSelections()
    reloadConfig("ConverterTypeChanged")
    reinitForm("ConverterTypeChanged")
end

----------------------------------------------------------------------
--
local function TurbineTypeChanged(value)
    local selection = getSelectionValue(TurbineTypeTable, value, "TurbineTypeChanged", "turbine type")

    if(not selection) then
        return
    end

    TurbineType  = selection --The value is local to this function and not global to script, hence it must be set explicitly.
    system.pSave("TurbineType", TurbineType)
    refreshTurbineConfigSelection()
    reloadConfig("TurbineTypeChanged")
    reinitForm("TurbineTypeChanged")
end

----------------------------------------------------------------------
--
local function TurbineConfigChanged(value)
    local selection = getSelectionValue(TurbineConfigTable, value, "TurbineConfigChanged", "turbine config")

    if(not selection) then
        return
    end

    TurbineConfig  = selection --The value is local to this function and not global to script, hence it must be set explicitly.
    system.pSave("TurbineConfig", TurbineConfig)
    reloadConfig("TurbineConfigChanged")
end

----------------------------------------------------------------------
--
local function BatteryConfigChanged(value)
    local selection = getSelectionValue(BatteryConfigTable, value, "BatteryConfigChanged", "battery config")

    if(not selection) then
        return
    end

    BatteryConfig  = selection --The value is local to this function and not global to script, hence it must be set explicitly.
    system.pSave("BatteryConfig", BatteryConfig)
    reloadConfig("BatteryConfigChanged")
end

--------------------------------------------------------------------
-- Store settings when changed by user
local function SensorChanged(value)
    local sensor = SensorMenuSensors[value]

    -- Index 1 is the "..." placeholder (a string), which means "no sensor selected".
    -- SensorID 0 disables monitoring instead of leaving a nil id for the runtime loop.
    if(type(sensor) == "table" and type(sensor.id) == "number") then
        SensorID = sensor.id
    else
        SensorID = 0
        if(sensor == nil) then
            logh.warn("SensorChanged", string.format("Missing sensor selection for index: %s", tostring(value)), 3)
        end
    end

    system.pSave("SensorID", SensorID)
    resetMonitoringState()

    -- Try to auto detect sensor from params later, to drop one menu element
    -- ECUconverter  = ECUconverterA[value]
    -- system.pSave("ECUconverter",  ECUconverter)
end

----------------------------------------------------------------------
--
local function initForm(subform)
    local ok
    local result

    ok, result = pcall(function()
        -- make all the dynamic menu items
        local ConverterTypeIndex, TurbineTypeIndex, TurbineConfigIndex, BatteryConfigIndex, SensorMenuIndex = 1,1,1,1,1
        local SensorMenuT = {"..."}
        SensorMenuSensors, SensorMenuT, SensorMenuIndex = sensorh.getSensorTable(SensorID) -- Returns only sensor names

        collectgarbage()

        ConverterTypeTable, ConverterTypeIndex  = tableh.fromDirectory(string.format("%s/converter", APP_ROOT), ConverterType)
        TurbineTypeTable,   TurbineTypeIndex    = tableh.fromDirectory(string.format("%s/converter/%s", APP_ROOT, ConverterType), TurbineType)
        TurbineConfigTable, TurbineConfigIndex  = tableh.fromFiles(string.format("%s/turbine/%s", APP_ROOT, TurbineType), TurbineConfig)
        BatteryConfigTable, BatteryConfigIndex  = tableh.fromFiles(string.format("%s/batterypack", APP_ROOT), BatteryConfig)
        collectgarbage()

        form.addRow(2)
        form.addLabel({label=lang.selectConverterType, width=200})
        form.addSelectbox(ConverterTypeTable, ConverterTypeIndex, true, ConverterTypeChanged)

        form.addRow(2)
        form.addLabel({label=lang.selectTurbineType, width=200})
        form.addSelectbox(TurbineTypeTable, TurbineTypeIndex, true, TurbineTypeChanged)

        form.addRow(2)
        form.addLabel({label=lang.selectTurbineConfig, width=200})
        form.addSelectbox(TurbineConfigTable, TurbineConfigIndex, true, TurbineConfigChanged)

        form.addRow(2)
        form.addLabel({label=lang.selectTurbineSensor, width=200})
        form.addSelectbox(SensorMenuT, SensorMenuIndex, true, SensorChanged)

        form.addRow(2)
        form.addLabel({label='Tank size', width=200})
        form.addIntbox(TankSize,0,10000,0,0,50,function(value)
            TankSize = value
            system.pSave("TankSize", value)
            fuelAlarm.tanksizeset = nil -- apply the new tank size on the next fuel reading
        end)

        form.addRow(2)
        form.addLabel({label=lang.selectBatteryConfig, width=200})
        form.addSelectbox(BatteryConfigTable, BatteryConfigIndex, true, BatteryConfigChanged)

        form.addRow(2)
        form.addLabel({label=lang.AudioOffSwitch, width=200})
        form.addInputbox(audioOffSwitch,true, function(value) audioOffSwitch=value; system.pSave("audioOffSwitch",value) end ) 

        form.addRow(2)
        form.addLabel({label=lang.HapticOffSwitch, width=200})
        form.addInputbox(hapticOffSwitch,true, function(value) hapticOffSwitch=value; system.pSave("hapticOffSwitch",value) end ) 

        form.addRow(2)
        form.addLabel({label=lang.MessageOffSwitch, width=200})
        form.addInputbox(messageOffSwitch,true, function(value) messageOffSwitch=value; system.pSave("messageOffSwitch",value) end ) 

        form.addRow(1)
        form.addLabel({label=string.format("ECU converter: %s",ConverterType)})

        collectgarbage()
    end)

    if(not ok) then
        logh.error("initForm", string.format("Form build failed: %s", tostring(result)), 3)
    end
end


----------------------------------------------------------------------
-- Re-init correct form if navigation buttons are pressed
local function keyPressed(key)
    form.reinit(1)
end

----------------------------------------------------------------------
-- Process fuel Alarms
local function processFuel(tmpCfg)
    local thresholdI
    local thresholdV
    local sensorEntry
    local sensor

    if(not tmpCfg) then
        return
    end

    sensorEntry = SensorT[tmpCfg.sensorname]
    sensor = sensorEntry and sensorEntry.sensor
    if(not sensorEntry or not sensor) then
        return
    end

    if(not sensor.valid) then
        sensorEntry.percent = 0
        return
    end

    if(sensor.value >= 0) then
        fuelh.initFuelSetup(tmpCfg) -- Important, runs only on startup
        sensorEntry.percent = fuelh.calculateFuelPercent(tmpCfg)

        -- Re-arm thresholds once the level is clearly back above them (refuel), so the next
        -- flight is protected without having to change the configuration. The 5 point margin
        -- keeps a noisy reading near a threshold from repeating the alarm.
        for _, fuelThreshold in ipairs(tmpCfg.alarms) do
            if(fuelAlarm[fuelThreshold.value] and sensorEntry.percent > fuelThreshold.value + 5) then
                fuelAlarm[fuelThreshold.value] = nil
            end
        end

        thresholdI, thresholdV = fuelh.FuelThresholdPassed(tmpCfg)
        if(fuelAlarm[thresholdV] or alarmTriggeredTime.fuel >= nowSeconds() or thresholdV >= 100) then
            return
        end

        fuelAlarm[thresholdV] = true -- Alarm has been given, never repeat
        alarmh.All(tmpCfg.alarms[thresholdI],string.format("%s (%.1f < %.1f)", tmpCfg.alarms[thresholdI].text, sensorEntry.percent, thresholdV))
        alarmTriggeredTime.fuel = nowSeconds() + 5 -- 5 seconds pause until next alarm
        return
    end

    if(alarmTriggeredTime.fuelsensorproblem < nowSeconds()) then
        logh.warn("processFuel", string.format("%s: %.1f", tmpCfg.sensorproblem.text, sensor.value))
        alarmh.All(tmpCfg.sensorproblem,string.format("%s: %.1f", tmpCfg.sensorproblem.text, sensor.value))
        alarmTriggeredTime.fuelsensorproblem = nowSeconds() + 15 -- 15 seconds pause until next alarm
    end
end

----------------------------------------------------------------------
-- readGenericSensor high/low value alarms
-- ToDo: These alarms will be repeated to often, how to avoid that? Second counter, repeat counter?

local function processGeneric(tmpCfg)
    local sensorEntry
    local sensor

    if(not tmpCfg) then
        logh.error("processGeneric", "Missing sensor configuration", 3)
        return
    end

    sensorEntry = SensorT[tmpCfg.sensorname]
    if(not sensorEntry) then
        logh.error("processGeneric", string.format("Missing sensor mapping: %s", tostring(tmpCfg.sensorname)), 3)
        return
    end

    sensor = sensorEntry.sensor
    if(not sensor or not sensor.valid) then
        return
    end

    sensorEntry.percent = fuelh.calcPercent(sensor.value, tmpCfg.high.value, tmpCfg.low.value)

    if(alarmTriggeredTime[tmpCfg.sensorname] >= nowSeconds()) then
        return
    end

    -- Arm low-alarm guard only after the startup grace period has passed, so transient
    -- sensor values during ECU self-test cannot pre-arm the flag before real data arrives.
    -- ecuv uses > 0 so any real voltage (even a low battery) arms it immediately.
    -- All other sensors require exceeding the low threshold first.
    local armThreshold = (tmpCfg.sensorname == "ecuv") and 0 or tmpCfg.low.value
    if(sensor.value > armThreshold and not alarmLowValuePassed[tmpCfg.sensorname]
        and not (turbineStopped and STOP_GATED_SENSORS[tmpCfg.sensorname])) then
        alarmLowValuePassed[tmpCfg.sensorname] = true
    end

    if(sensor.value > tmpCfg.high.value) then
        alarmTriggeredTime[tmpCfg.sensorname] = nowSeconds() + 30
        alarmh.All(tmpCfg.high,string.format("%s (%.1f > %.1f)", tmpCfg.high.text, sensor.value, tmpCfg.high.value))
    elseif(sensor.value < tmpCfg.low.value and alarmLowValuePassed[tmpCfg.sensorname]) then
        alarmTriggeredTime[tmpCfg.sensorname] = nowSeconds() + 30
        alarmh.All(tmpCfg.low,string.format("%s (%.1f < %.1f)", tmpCfg.low.text, sensor.value, tmpCfg.low.value))
    end
end


-- Planned stop states. RPM, EGT and pump voltage fall below their low limits on purpose here.
local STOPPED_WORDS = {"stop", "off", "cool", "ready", "lock", "standby", "trim low", "stick low"}

local function isStoppedStatus(statusText)
    local lowered = string.lower(statusText)

    for _, word in ipairs(STOPPED_WORDS) do
        if(string.find(lowered, word, 1, true)) then
            return true
        end
    end
    return false
end

local function processStatus(tmpCfg)
    local sensorEntry
    local sensor
    local statusCode
    local statusText

    if(not tmpCfg) then
        logh.error("processStatus", "Missing status configuration", 3)
        return
    end

    sensorEntry = SensorT[tmpCfg.sensorname]
    if(not sensorEntry) then
        logh.error("processStatus", string.format("Missing sensor mapping: %s", tostring(tmpCfg.sensorname)), 2)
        return
    end

    sensor = sensorEntry.sensor
    if(not sensor or not sensor.valid) then
        sensorEntry.text = "OFFLINE"
        return
    end

    statusCode = tostring(math.floor(sensor.value))
    statusText = config.converter.statusmap and config.converter.statusmap[statusCode]
    sensorEntry.text = statusText

    if(not statusText) then
        logh.error("processStatus", string.format("Unknown status code: %s", statusCode), 2)
        return
    end

    -- If status hasn't changed since last check, nothing to do
    if(prevStatus == statusText) then
        return
    end

    -- Always track the current status, even during startup suppression,
    -- so that stable at-rest states don't trigger an alarm when suppression lifts
    prevStatus = statusText

    -- A planned stop must not raise RPM/EGT/pump "low" alarms while the turbine spools down:
    -- disarm them and keep them disarmed until the next run (a real reading above the low limit).
    turbineStopped = isStoppedStatus(statusText)
    if(turbineStopped) then
        for sensorName, _ in pairs(STOP_GATED_SENSORS) do
            alarmLowValuePassed[sensorName] = false
        end
    end

    -- If still inside the startup cooldown, suppress the alarm output
    if(alarmTriggeredTime[tmpCfg.sensorname] >= nowSeconds()) then
        return
    end

    if(not config.status[statusText]) then
        logh.error("processStatus", string.format("Unknown status config: %s", statusText), 3)
        if(enableAlarmAudio) then
            alarmh.Audio({enable = true, file = "Unknown status configuration.wav"})
        end
        return
    end

    alarmh.All(config.status[statusText], statusText)
end

----------------------------------------------------------------------
-- Check if switch to enable alarms is set, sets global enableAlarm value
local function enableAlarmCheck(OffSwitch)
    if(not OffSwitch) then
        return true
    end

    local Switch   = system.getSwitchInfo(OffSwitch)

    if(Switch and Switch.assigned ~= false) then -- an unassigned switch never disables the alarms
        if(Switch.value < 0) then  -- turned off by switch, will always override status handling
            return false
        else
            return true
        end
    end
    return true
end

----------------------------------------------------------------------
-- Reset all alarms with 10 seconds pause until telemetry systems is stabilised after first loop with all sensors read
local function resetAlarmTriggeredTime(delay)

    for tmpName, _ in pairs(alarmTriggeredTime) do
        alarmTriggeredTime[tmpName] = nowSeconds() + delay
    end
end

----------------------------------------------------------------------
-- Read and map all sensors to names instead of param values for easier processing
local function readParamsFromSensor(tmpSensorID)

    local countSensorsValid = 0
    local countSensors      = 0
    local countCritical     = 0
    local countCriticalValid = 0
    local sensorEntry
    local sensorParam

    for tmpSensorName, tmpSensorParam in pairs(config.converter.sensormap) do
        sensorEntry = SensorT[tmpSensorName] or newSensorEntry()
        SensorT[tmpSensorName] = sensorEntry
        sensorParam = tonumber(tmpSensorParam) or 0

        if(sensorParam > 0) then
            --print(string.format("rsensor: %s : %s : %s", tmpSensorID, tmpSensorName, tonumber(tmpSensorParam)))
            sensorEntry.sensor = system.getSensorByID(tmpSensorID, sensorParam)

            if(sensorEntry.sensor) then
                countSensors = countSensors + 1
                if(CRITICAL_SENSORS[tmpSensorName]) then
                    countCritical = countCritical + 1
                end

                if(sensorEntry.sensor.valid) then
                    countSensorsValid = countSensorsValid + 1
                    if(CRITICAL_SENSORS[tmpSensorName]) then
                        countCriticalValid = countCriticalValid + 1
                    end
                else
                    -- The sensor exist, but is not valid yet.
                    sensorEntry.sensor.value = 0
                    sensorEntry.percent = 0
                end
            else
                -- The sensor does not exist, ignore it. (not counting, no values)
                sensorEntry.sensor = EMPTY_SENSOR
                sensorEntry.percent = 0
            end
        else 
            -- Parm is zero, so this sensor does not exist for this converter, we fake it with zero values.
            sensorEntry.sensor = EMPTY_SENSOR
            sensorEntry.percent = 0
        end
    end

    sensorState.configured = countSensors
    sensorState.valid = countSensorsValid
    -- Online means every critical sensor (status, rpm, egt) reports valid data. A missing or
    -- invalid optional sensor must not keep the alarms disabled. Converters that provide none of
    -- the critical sensors fall back to requiring all of their sensors.
    if(countCritical > 0) then
        sensorState.allOnline = (countCriticalValid == countCritical)
    else
        sensorState.allOnline = (countSensors > 0 and countSensorsValid == countSensors)
    end

    --print(string.format("configured: %s valid: %s", #config.converter.sensormap, countSensorsValid))
    if(sensorState.allOnline) then
        sensorState.offlineAlerts = 0
        if(not sensorState.hadFullSignal) then
            sensorState.hadFullSignal = true
            resetAlarmTriggeredTime(30) -- Suppress all alarms for 30 s after first full signal to let ECU boot states settle
        end
    elseif((sensorState.hadFullSignal or sensorState.offlineAlerts > 0)
        and sensorState.offlineAlerts < OFFLINE_MAX_ALERTS
        and alarmTriggeredTime.offline < nowSeconds()) then -- Only trigger if the ECU has been online before
        -- A critical sensor stopped reporting, so the ECU is somehow offline. The warning is repeated a few
        -- times (a single announcement is easy to miss) and then stops until the ECU has been online again.
        alarmTriggeredTime.offline = nowSeconds() + OFFLINE_REPEAT_SECONDS
        sensorState.offlineAlerts = sensorState.offlineAlerts + 1

        sensorState.hadFullSignal = false

        logh.warn(
            "readParamsFromSensor",
            string.format("ECU offline - configured: %s valid: %s", countSensors, countSensorsValid),
            enableAlarmMessage and 3 or nil
        )

        if(enableAlarmAudio) then
            alarmh.Audio(OFFLINE_AUDIO)
        end 

        if(enableAlarmHaptic) then
            system.vibration(false, 4);
        end
    end
end

----------------------------------------------------------------------
-- Application initialization. Has to be the second last function so all other functions is initialized
local function init()
    -- Load translation files  
    system.registerForm(1,MENU_APPS,lang.appName, initForm, keyPressed)

    SensorID          = system.pLoad("SensorID", 0)
    ConverterType     = realValue(system.pLoad("ConverterType", "vspeak"), "vspeak")
    TurbineType       = realValue(system.pLoad("TurbineType", "jetcat"), "jetcat")
    TurbineConfig     = realValue(system.pLoad("TurbineConfig", "generic"), "generic")
    BatteryConfig     = realValue(system.pLoad("BatteryConfig", "lipo-2s"), "lipo-2s")
    TankSize          = system.pLoad("TankSize", 3500)
    audioOffSwitch    = system.pLoad("audioOffSwitch")
    hapticOffSwitch   = system.pLoad("hapticOffSwitch")
    messageOffSwitch  = system.pLoad("messageOffSwitch")

    alarmh.init(
        function()
            return enableAlarmMessage
        end,
        function()
            return enableAlarmHaptic
        end,
        function()
            return enableAlarmAudio
        end,
        APP_ROOT
    )

    fuelh.init(
        function()
            return config
        end,
        function()
            return SensorT
        end,
        function()
            return TankSize
        end,
        function()
            return fuelAlarm
        end
    )

    window1.init(function()
        return SensorID, SensorT, config, sensorState
    end)

    window2.init(function()
        return SensorID, SensorT, config, sensorState
    end)

    -- A failure here must not stop the app from starting: the windows and the repeated warning
    -- in loop() report an unusable configuration instead.
    pcall(refreshTurbineSelections)

    -- read all the config files
    reloadConfig("init")

    system.registerTelemetry(1, lang.window1, 2,window1.show)
    system.registerTelemetry(2, lang.window2, 2, window2.show)

    --system.registerTelemetry(2, lang.window1, 2, telemetry1.window)  
    --system.registerTelemetry(2, "Large", 4, window4.show)  - Full screen 

    resetAlarmTriggeredTime(10800) -- No alarms until 3 hours after turn on, or another reset event (like all sensors online)

    collectgarbage()
end

----------------------------------------------------------------------
-- One cycle of sensor reading and alarm processing (called through pcall from loop)
local function loopBody()
    enableAlarmAudio   = enableAlarmCheck(audioOffSwitch)
    enableAlarmHaptic  = enableAlarmCheck(hapticOffSwitch)
    enableAlarmMessage = enableAlarmCheck(messageOffSwitch)

    readParamsFromSensor(SensorID)

    -- All converters has these sensors
    if(hasSensorMapping("fuel")) then
        processFuel(config.fuel)
    end

    if(hasSensorMapping("rpm")) then
        processGeneric(config.rpm)
    end

    if(hasSensorMapping("egt")) then
        processGeneric(config.egt)
    end

    if(hasSensorMapping("pumpv")) then
        processGeneric(config.pumpv)
    end

    if(hasSensorMapping("ecuv")) then
        processGeneric(config.ecuv)
    end

    -- Check if converter has these sensor before processing them, since the availibility varies
    if(hasSensorMapping("status")) then
        processStatus(config.status)
    end
    if(hasSensorMapping("rpm2")) then
        processGeneric(config.rpm2)
    end
end

----------------------------------------------------------------------
-- Repeated warning while the monitoring is not working (unusable config or a runtime fault),
-- so the pilot is never left believing the turbine is being monitored. Throttled so a
-- persistent fault does not flood the message box or allocate every loop cycle.
local function faultAlert(reason, detail)
    local now = nowSeconds()

    if(now < nextFaultAlert) then
        return
    end
    nextFaultAlert = now + FAULT_REPEAT_SECONDS

    if(detail) then
        reason = string.format("%s: %s", reason, tostring(detail))
    end
    logh.error("loop", reason, 3)

    if(enableAlarmCheck(audioOffSwitch)) then
        alarmh.Audio(FAULT_AUDIO)
    end
end

----------------------------------------------------------------------
-- Loop has to be the last function, so every other function is initialized
local function loop()
    local ok
    local err

    --fake.makeSensorValues()
    if(not SensorID or SensorID == 0) then
        return
    end

    if(not configValid) then
        faultAlert("Configuration invalid - ECU monitoring is OFF")
        return
    end

    -- A Lua error must never stop the app silently: report it and keep running.
    ok, err = pcall(loopBody)
    if(not ok) then
        faultAlert("ECU monitoring fault", err)
    end
end

lang = loadh.fileJson(string.format("%s/locale/%s.jsn", APP_ROOT, system.getLocale()))
    or loadh.fileJson(string.format("%s/locale/en.jsn", APP_ROOT))
    or {appName = "ECU", window1 = "ECU", window2 = "ECU"}

return {init=init, loop=loop, author="Thomas Ekdahl - thomas@ekdahl.no", version='3.0', name=lang.appName}