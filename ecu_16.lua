-- ############################################################################# 
-- # Jeti ECU Telemetry
-- # Jeti Advanced ECU LUA Script. Easy telemetry displaying, advanced alarms, easy setup, very configurable, easy to setup new ecu types
-- # Some Lua ideas copied from Jeti and TeroS
-- #
-- # Copyright (c) 2017, Original idea by Thomas Ekdahl (thomas@ekdahl.no) co-developed with Volker Weigt the maker of vspeak hardware.
-- # Telemetry display code graphics borrowed from ECU data display made by Bernd Woköck
-- #
-- # License: Share alike                                       
-- # Can be used and changed non commercial, but feel free to send us changes back to be incorporated in the main code.
-- #                       
-- # 0.9 - Initial release
-- ############################################################################# 

-- Complete turbine config object dynamically assembled (everything here is local to keep the shared Lua environment clean)
local config          = {"..."} -- Complete turbine config object dynamically assembled
-- Sensor entries by sensorname as configured in the ecu converter, created by readParamsFromSensor
local SensorT           = {}
local SensorMenuSensors = {"..."} -- Sensors offered in the setup menu (index 1 is the "..." placeholder)
local EMPTY_SENSOR      = {value = 0, max = 0, valid = false} -- Shared stand-in for missing sensors, never written
local configValid       = false   -- false = config unusable, nothing is monitored
local nextFaultAlert    = 0       -- Next time the "monitoring is off" warning may repeat
-- While the turbine is in a planned stop state, RPM, EGT and pump voltage fall below their low
-- limits on purpose, so those low alarms are not armed. The ECU battery stays armed.
local turbineStopped    = false
local offlineAlerts     = 0       -- ECU offline warnings given since the ECU was last online
local nextOfflineAlert  = 0

-- Monotonic seconds since the transmitter started. system.getTime() is the wall clock and jumps
-- when the date/time is changed, which would stretch or cut the alarm cooldown windows.
local function nowSeconds()
    return system.getTimeCounter() // 1000
end

-- Sensors that must be valid for the ECU to count as online
local CRITICAL_SENSORS = {status = true, rpm = true, egt = true}

-- Status names that deserve audio (faults); other statuses only show a message (silent cockpit)
local FAULT_WORDS = {"fail", "error", "bad", "flameout", "high temp", "low rpm", "speed low", "overload",
    "battery low", "time out", "timeout", "lost", "emergency", "unknown", "weak", "over ", "no ", "wrong",
    "comm", "diff", "watchdog", "glow plug", "reboot", "accelerate slow", "clutch", "out of fuel",
    "temp off", "power", "max rpm", "supply"}

-- Planned stop states, where RPM/EGT/pump voltage fall below their low limits on purpose
local STOPPED_WORDS = {"stop", "off", "cool", "ready", "lock", "standby", "trim low", "stick low"}

local function hasWord(text, words)
    local lowered = string.lower(text)

    for i = 1, #words do
        if(string.find(lowered, words[i], 1, true)) then
            return true
        end
    end
    return false
end

-- Menu tables start with a "..." placeholder that is not a real selection
local function selected(options, value)
    local item = options[value]

    if(item == nil or item == "...") then
        return nil
    end
    return item
end

local function realValue(value, default)
    if(type(value) ~= "string" or value == "" or value == "...") then
        return default
    end
    return value
end

-- Locals for the application
local enableAlarm                 = false
local prevStatusID, prevFuelLevel, TankSize = 0,0,0
local hadFullSignal               = false  -- true after all sensors first go valid
local alarmOffSwitch

local lang              = {"..."} -- Language read from file

local alarmLowValuePassed = { -- arms low alarms once a sensor reports a real value; ecuv uses > 0 so a 0.0 init reading never triggers
    rpm    = false,
    rpm2   = false,
    egt    = false,
    pumpv  = false,
    ecuv   = false,  -- armed on first non-zero reading, not on low threshold
    fuel   = false,
    status = true
}

local alarmTriggeredTime   = { -- stores latest datetime on the alarm triggered, used to not repeat alarms to often
    rpm    = 0,
    rpm2   = 0,
    egt    = 0,
    pumpv  = 0,
    ecuv   = 0,
    fuel   = 0,  -- in ml from ecu
    status = 0,
}

local SensorID              = 0
local ConverterTypeTable    = {"..."}   -- Array with all available turbine types
local ConverterType         = "vspeak"  -- the turbine type chosen

local TurbineTypeTable      = {"..."}   -- Array with all available turbine types
local TurbineType           = "hornet"  -- the turbine type chosen

local TurbineConfigTable    = {"..."}   -- Array with all available config fields
local TurbineConfig         = "generic"  -- the turbine config file chosen

local BatteryConfigTable    = {"..."}   -- Array with all available config fields
local BatteryConfig         = "life-2s"  -- the battery config file chosen

local function fileJson(filename)
    local structure
    local file = io.readall(filename)

    if(file) then
        local decodeOk
        decodeOk, structure = pcall(json.decode, file)
        if(not decodeOk) then
            print(string.format("Invalid json: %s (%s)", filename, tostring(structure)))
            return nil
        end
        if(structure) then
            collectgarbage()
            print(string.format("fileJson: %s - mem %s ", filename, collectgarbage("count")))
            return structure
        else
            print(string.format("Invalid jsn format: %s", filename))
        end
    else
        print(string.format("File not found: %s", filename))
    end
end 

local function fromDirectory(path, choice)
    local tmpTable = {"..."}
    local tmpIndex = 1

    for name, filetype, size in dir(path) do
        if(filetype == "folder" and string.sub(name, 1, 1) ~= ".") then
            table.insert(tmpTable, name)

            if (choice) then
                if(name == choice) then
                    tmpIndex=#tmpTable
                end
            end
        end
    end
    collectgarbage()
    print(string.format("fromDirectory: %s - mem: %s", path, collectgarbage("count")))

    return tmpTable, tmpIndex
end

--------------------------------------------------------------------
-- Read all files in a folder and put it in a table to be used to create a menu
local function fromFiles(path, choice)
    local tmpTable = {"..."}
    local tmpIndex = 1

    collectgarbage()
    print(string.format("fromFiles: %s - mem: %s", path, collectgarbage("count")))

    for name, filetype, size in dir(path) do
        if(string.sub(name, -3, -1) == "jsn" and string.sub(name, 1, 1) ~= ".") then
            table.insert(tmpTable, string.sub(name, 1, -5))
            
            if (choice) then
                if(string.sub(name, 1, -5) == choice) then
                    tmpIndex=#tmpTable
                end
            end
        end
    end

    return tmpTable, tmpIndex
end

--------------------------------------------------------------------
-- Generates a sensor menu, returns sensor table and index choice for GUI generation
local function getSensorTable(sensorID)
    local tmpSensorTable = {"..."}
    local tmpMenuTable   = {"..."}
    local tmpIndex = 1

    for index,sensor in ipairs(system.getSensors()) do 
        if(sensor.param == 0) then

            tmpSensorTable[#tmpSensorTable+1] = sensor -- global sensor array
            tmpMenuTable[#tmpMenuTable+1]=string.format("%s",sensor.label) -- added param for config purposes

            if(sensor.id==sensorID) then
                tmpIndex=#tmpMenuTable
            end      
        end
    end
    collectgarbage()

    return tmpSensorTable, tmpMenuTable, tmpIndex
end

local function DrawFuelGauge(percentage, ox, oy) 
    
    -- gas station symbol
    lcd.drawRectangle(34+ox,31+oy,5,9)  
    lcd.drawLine(35+ox,34+oy,37+ox,34+oy)
    lcd.drawLine(33+ox,39+oy,39+ox,39+oy)
    lcd.drawLine(40+ox,31+oy,42+ox,33+oy)
    lcd.drawLine(42+ox,33+oy,42+ox,37+oy)
    lcd.drawPoint(40+ox,38+oy)  
    lcd.drawLine(40+ox,38+oy,40+ox,35+oy)  
    lcd.drawPoint(39+ox,35+oy)
    lcd.drawText(34+ox,2+oy, "F", FONT_MINI)  
    lcd.drawText(34+ox,54+oy, "E", FONT_MINI)  
  
    -- fuel bar 
    lcd.drawRectangle (5+ox,53+oy,25,11)  -- lowest bar segment
    lcd.drawRectangle (5+ox,41+oy,25,11)  
    lcd.drawRectangle (5+ox,29+oy,25,11)  
    lcd.drawRectangle (5+ox,17+oy,25,11)  
    lcd.drawRectangle (5+ox,5+oy,25,11)   -- uppermost bar segment
    
    -- calc bar chart values
    local nSolidBar = math.floor( percentage / 20 )
    local nFracBar = (percentage - nSolidBar * 20) / 20  -- 0.0 ... 1.0 for fractional bar
    local i
    -- solid bars
    for i=0, nSolidBar - 1, 1 do 
      lcd.drawFilledRectangle (5+ox,53-i*12+oy,25,11) 
    end  
    --  fractional bar
    local y = math.floor( 53-nSolidBar*12+(1-nFracBar)*11 + 0.5)
    lcd.drawFilledRectangle (5+ox,y+oy,25,11*nFracBar)
end
local function DrawTurbineStatus(status, ox, oy) 
    lcd.drawText(4+ox,2+oy, "Turbine", FONT_MINI)  
    lcd.drawText(4+ox,15+oy, status, FONT_BOLD)  
end
local function DrawBattery(u_pump, u_ecu, ox, oy) 
  lcd.drawText(4+ox,1+oy, "PUMP", FONT_MINI)  
  lcd.drawText(45+ox,1+oy, "ECU", FONT_MINI)  
  lcd.drawText(4+ox,12+oy,  string.format("%.1f%s",u_pump,"V"), FONT_BOLD)
  lcd.drawText(45+ox,12+oy, string.format("%.1f%s",u_ecu,"V"), FONT_BOLD)
end
local function window(width, height)  
    -- field separator lines
    lcd.drawLine(45,2,45,66)  
    lcd.drawLine(45,36,148,36)  

    if(SensorID ~= 0 and configValid) then
        local sensormap = config.converter.sensormap
        local fuel      = SensorT.fuel
        local status    = SensorT.status
        local pump      = SensorT.pumpv
        local ecu       = SensorT.ecuv

        if(sensormap.fuel and fuel and fuel.percent) then
            DrawFuelGauge(fuel.percent, 1, 0)
        end

        -- turbine
        if(sensormap.status) then
            DrawTurbineStatus(status and status.text or "UNKNOWN", 50, 0)
        else
            DrawTurbineStatus("UNCONFIG", 50, 0)
        end

        -- battery
        if(sensormap.pumpv and pump and pump.sensor and ecu and ecu.sensor) then
            DrawBattery(pump.sensor.value, ecu.sensor.value, 50, 37)
        end
    elseif(SensorID ~= 0) then
        DrawTurbineStatus("CONFIG ERR", 50, 0)
        lcd.drawText(50,37, "NOT MONITORED", FONT_MINI)
    else
        DrawTurbineStatus("NO CONFIG", 50, 0)
    end
end

-- True if the converter maps the sensor to a Jeti param number (> 0)
local function mapped(sensorName)
    return type(config.converter) == "table"
        and type(config.converter.sensormap) == "table"
        and (tonumber(config.converter.sensormap[sensorName]) or 0) > 0
end

-- The loop dereferences these fields, so an incomplete config is rejected here instead of
-- failing while the turbine is running.
local function validateConfig()
    if(type(config.converter) ~= "table" or type(config.converter.sensormap) ~= "table") then
        print("ECU-16: missing converter sensormap")
        return false
    end

    for _, sensorName in ipairs({"rpm", "egt", "pumpv", "ecuv"}) do
        if(mapped(sensorName)) then
            local c = config[sensorName]
            if(type(c) ~= "table" or c.sensorname ~= sensorName or type(c.high) ~= "number" or type(c.low) ~= "number") then
                print(string.format("ECU-16: invalid high/low config: %s", sensorName))
                return false
            end
        end
    end

    if(mapped("fuel")) then
        local f = config.fuel
        if(type(f) ~= "table" or f.sensorname ~= "fuel" or type(f.tanksize) ~= "number"
            or type(f.warning) ~= "number" or type(f.critical) ~= "number"
            or type(config.converter.fuel) ~= "table") then
            print("ECU-16: invalid fuel config")
            return false
        end
    end

    if(mapped("status")) then
        if(type(config.converter.statusmap) ~= "table" or type(config.status) ~= "table" or config.status.sensorname ~= "status") then
            print("ECU-16: invalid status config")
            return false
        end
    end

    return true
end

local function readConfig()
    -- Load main turbine config
    local turbine = fileJson(string.format("Apps/ecu/turbine_16/%s/%s.jsn", TurbineType, TurbineConfig))
    collectgarbage()

    if(type(turbine) ~= "table") then
        turbine = {}
    end

    -- Generic config loading adding to default turbine config
    turbine.ecuv      = fileJson(string.format("Apps/ecu/batterypack_16/%s.jsn", BatteryConfig))
    turbine.fuel      = fileJson("Apps/ecu/fuel_16/config.jsn")
    turbine.converter = fileJson(string.format("Apps/ecu/converter/%s/%s/config.jsn", ConverterType, TurbineType))
    config = turbine
    collectgarbage()
end

local function loadConfig()
    local ok, err = pcall(readConfig)

    if(not ok) then
        config = {}
        print(string.format("ECU-16: config load failed: %s", tostring(err)))
    end

    configValid = ok and validateConfig()
    if(not configValid) then
        system.messageBox("ECU: invalid config, NOT monitored", 3)
    end
end

----------------------------------------------------------------------
--
local function ConverterTypeChanged(value)
    local selection = selected(ConverterTypeTable, value)

    if(not selection) then
        return
    end

    ConverterType = selection
    print(string.format("ConverterTypeSave %s = %s", value, ConverterType))
    system.pSave("ConverterType",  ConverterType)
    TurbineTypeTable    = fromDirectory(string.format("Apps/ecu/converter/%s", ConverterType), nil)
    loadConfig() -- reload after config change
end

----------------------------------------------------------------------
--
local function TurbineTypeChanged(value)
    local selection = selected(TurbineTypeTable, value)

    if(not selection) then
        return
    end

    TurbineType = selection
    system.pSave("TurbineType", TurbineType)
    TurbineConfigTable  = fromFiles(string.format("Apps/ecu/turbine_16/%s", TurbineType), nil)
    loadConfig() -- reload after config change
end

----------------------------------------------------------------------
--
local function TurbineConfigChanged(value)
    local selection = selected(TurbineConfigTable, value)

    if(not selection) then
        return
    end

    TurbineConfig = selection
    system.pSave("TurbineConfig", TurbineConfig)
    loadConfig() -- reload after config change
end

----------------------------------------------------------------------
--
local function BatteryConfigChanged(value)
    local selection = selected(BatteryConfigTable, value)

    if(not selection) then
        return
    end

    BatteryConfig = selection
    system.pSave("BatteryConfig", BatteryConfig)
    loadConfig() -- reload after config change
end

--------------------------------------------------------------------
-- Store settings when changed by user
local function SensorChanged(value)
    local sensor = SensorMenuSensors[value]

    -- Index 1 is the "..." placeholder (a string) = no sensor selected.
    -- SensorID 0 disables monitoring instead of leaving a nil id for the loop.
    if(type(sensor) == "table" and type(sensor.id) == "number") then
        SensorID = sensor.id
    else
        SensorID = 0
    end
    system.pSave("SensorID", SensorID)
end

----------------------------------------------------------------------
--
local function initForm(subform)
    -- make all the dynamic menu items
    local ConverterTypeIndex, TurbineTypeIndex, TurbineConfigIndex, BatteryConfigIndex, SensorMenuIndex = 1,1,1,1,1
    local SensorMenuT = {"..."}
    SensorMenuSensors, SensorMenuT, SensorMenuIndex = getSensorTable(SensorID)
    collectgarbage()

    ConverterTypeTable, ConverterTypeIndex  = fromDirectory("Apps/ecu/converter", ConverterType)
    TurbineTypeTable,   TurbineTypeIndex    = fromDirectory(string.format("Apps/ecu/converter/%s", ConverterType), TurbineType)
    TurbineConfigTable, TurbineConfigIndex  = fromFiles(string.format("Apps/ecu/turbine_16/%s", TurbineType), TurbineConfig)
    BatteryConfigTable, BatteryConfigIndex  = fromFiles("Apps/ecu/batterypack_16", BatteryConfig)
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
    form.addLabel({label=lang.selectLeftTurbineSensor, width=200})
    form.addSelectbox(SensorMenuT, SensorMenuIndex, true, SensorChanged)

    form.addRow(2)
    form.addLabel({label=lang.selectBatteryConfig, width=200})
    form.addSelectbox(BatteryConfigTable, BatteryConfigIndex, true, BatteryConfigChanged)

    form.addRow(2)
    form.addLabel({label='Tank size', width=200})
    form.addIntbox(TankSize,0,10000,0,0,50,function(value) TankSize=value; system.pSave("TankSize",value) end )

    form.addRow(2)
    form.addLabel({label=lang.alarmOffSwitch, width=200})
    form.addInputbox(alarmOffSwitch,true, function(value) alarmOffSwitch=value; system.pSave("alarmOffSwitch",value) end ) 

    collectgarbage()
    print("Mem after GUI: ", collectgarbage("count"))
end


----------------------------------------------------------------------
-- Re-init correct form if navigation buttons are pressed
local function keyPressed(key)
    form.reinit(1)
end

local function calcPercent(current, high, low)
    local percent = ((current - low) / (high - low)) * 100
    if(percent < 0) then 
            percent = 0
    end
    return percent
end

----------------------------------------------------------------------
-- Calculates: config.fuellevel.tanksize and config.fuellevel.interval and fuelpercent
local function initFuelStatistics(tmpCfg)

    -- We only enable the low alarms after they have passed the low threshold
    if(SensorT[tmpCfg.sensorname].sensor.value > tmpCfg.warning and not alarmLowValuePassed[tmpCfg.sensorname]) then
        alarmLowValuePassed[tmpCfg.sensorname] = true;
    end

    if(config.fuel.tanksize < 50 and alarmLowValuePassed[tmpCfg.sensorname]) then -- Configure TankSize during first 50 cycles
        if(config.converter.fuel.countingdown) then

            -- Init: Automatic calculations done on the first run after we read the sensor value.
            config.fuel.tanksize = SensorT[tmpCfg.sensorname].sensor.value -- new or max?
            TankSize             = config.fuel.tanksize 
            config.fuel.interval = config.fuel.tanksize / 10 -- Calculate 10 fuel intervals for reporting announcing automatically of remaining tank
            prevFuelLevel        = config.fuel.tanksize - config.fuel.interval -- init full tank reporting, but do not start before next interval
        else
            -- counting up, have to subtract
            config.fuel.tanksize = TankSize -- TankSize read from GUI not from ECU when counting up usage
            config.fuel.interval = config.fuel.tanksize / 10 -- Calculate 10 fuel intervals for reporting announcing automatically of remaining tank
            prevFuelLevel        = config.fuel.tanksize - config.fuel.interval -- init full tank reporting, but do not start before next interval
        end 
    end

    -- Calculate fuel percentage remaining
    if(config.fuel.tanksize > 50 and alarmLowValuePassed[tmpCfg.sensorname]) then
        if(config.converter.fuel.countingdown) then
            SensorT[tmpCfg.sensorname].percent = calcPercent(SensorT[tmpCfg.sensorname].sensor.value, config.fuel.tanksize, 0)
        else
            SensorT[tmpCfg.sensorname].percent = calcPercent(config.fuel.tanksize - SensorT[tmpCfg.sensorname].sensor.value, config.fuel.tanksize, 0)
        end
    else
        SensorT[tmpCfg.sensorname].percent = 0
    end
end

----------------------------------------------------------------------
--
local function processFuel(tmpCfg, tmpSensorID)

    if(SensorT[tmpCfg.sensorname].sensor.valid) then

        initFuelStatistics(tmpCfg) -- Important

        -- We only enable the low alarms after they have passed the low threshold
        if(SensorT[tmpCfg.sensorname].sensor.value > tmpCfg.warning and not alarmLowValuePassed[tmpCfg.sensorname]) then
            alarmLowValuePassed[tmpCfg.sensorname] = true;
        end

        -- Repeat fuel level audio at intervals
        if(SensorT[tmpCfg.sensorname].sensor.value < prevFuelLevel and alarmLowValuePassed[tmpCfg.sensorname]) then
            prevFuelLevel = prevFuelLevel - tmpCfg.interval -- Only work in intervals, should we calculate intervals from tanksize? 10 informations pr tank?    
            system.playNumber(prevFuelLevel / 1000, tmpCfg.decimals, tmpCfg.unit, tmpCfg.label) -- Read out the numbers from the interval, not the value - to get better clearity
        end
        
        -- Check for alarm thresholds
        if(enableAlarm and alarmLowValuePassed[tmpCfg.sensorname]) then
            if(alarmTriggeredTime[tmpCfg.sensorname] < nowSeconds()) then
                if(SensorT[tmpCfg.sensorname].percent < tmpCfg.critical) then

                    alarmTriggeredTime[tmpCfg.sensorname] = nowSeconds() + 20
                    system.messageBox(string.format("%s (%s < %s)", 'fuel critical', SensorT[tmpCfg.sensorname].percent, tmpCfg.critical))
                    system.playFile("/Apps/ecu/audio/fuel_critical.wav",AUDIO_IMMEDIATE)
            
                elseif(SensorT[tmpCfg.sensorname].percent < tmpCfg.warning) then

                    alarmTriggeredTime[tmpCfg.sensorname]  = nowSeconds() + 15
                    system.messageBox(string.format("%s (%s < %s)", 'fuel warning', SensorT[tmpCfg.sensorname].percent, tmpCfg.warning))
                    system.playFile("/Apps/ecu/audio/fuel_warning.wav",AUDIO_IMMEDIATE)
                 end
            end
        end
    else
        SensorT[tmpCfg.sensorname].percent = 0
    end
end

----------------------------------------------------------------------
-- readGenericSensor high/low value alarms
-- ToDo: These alarms will be repeated to often, how to avoid that? Second counter, repeat counter?

local function processGeneric(tmpCfg, tmpSensorID)

    if(tmpCfg) then
        if(SensorT[tmpCfg.sensorname].sensor and SensorT[tmpCfg.sensorname].sensor.valid) then
            --print(string.format("sensorname : %s",tmpCfg.sensorname))
            --print(string.format("low  : %s",tmpCfg.low))

            -- calculate percentage
            SensorT[tmpCfg.sensorname].percent = calcPercent(SensorT[tmpCfg.sensorname].sensor.value, tmpCfg.high, tmpCfg.low)

            if(enableAlarm) then
                if(alarmTriggeredTime[tmpCfg.sensorname] < nowSeconds()) then

                    -- Arm only after grace period so transient startup values cannot pre-arm the flag.
                    local armThreshold = (tmpCfg.sensorname == "ecuv") and 0 or tmpCfg.low
                    if(SensorT[tmpCfg.sensorname].sensor.value > armThreshold and not alarmLowValuePassed[tmpCfg.sensorname]
                        and not (turbineStopped and tmpCfg.sensorname ~= "ecuv")) then
                        alarmLowValuePassed[tmpCfg.sensorname] = true
                    end

                    if(SensorT[tmpCfg.sensorname].sensor.value > tmpCfg.high) then
                        alarmTriggeredTime[tmpCfg.sensorname] = nowSeconds() + 30
                        system.messageBox(string.format("%s high (%s > %s)", tmpCfg.sensorname, SensorT[tmpCfg.sensorname].sensor.value, tmpCfg.high), 5)
                        system.playFile(string.format("/Apps/ecu/audio/%s_high.wav", tmpCfg.sensorname),AUDIO_IMMEDIATE)
                
                    elseif(SensorT[tmpCfg.sensorname].sensor.value < tmpCfg.low and alarmLowValuePassed[tmpCfg.sensorname]) then
                        alarmTriggeredTime[tmpCfg.sensorname] = nowSeconds() + 30
                        system.messageBox(string.format("%s low (%s < %s)", tmpCfg.sensorname, SensorT[tmpCfg.sensorname].sensor.value, tmpCfg.low), 5)
                        system.playFile(string.format("/Apps/ecu/audio/%s_low.wav", tmpCfg.sensorname),AUDIO_IMMEDIATE)
                    end
                end
            end
        end
    end
end

----------------------------------------------------------------------
-- A planned stop must not raise RPM/EGT/pump "low" alarms while the turbine spools down.
-- They are armed again by the next run (a real reading above the low limit).
local function disarmLowAlarms()
    alarmLowValuePassed.rpm   = false
    alarmLowValuePassed.egt   = false
    alarmLowValuePassed.pumpv = false
end

----------------------------------------------------------------------
-- Play the status sound, or the generic error sound if the status has no sound file
local function playStatusAudio(statusText)
    local path = string.format("/Apps/ecu/audio/%s.wav", statusText)
    local file = io.open(path, "r")

    if(file) then
        pcall(io.close, file)
    else
        path = "/Apps/ecu/audio/Error.wav"
    end
    system.playFile(path, AUDIO_IMMEDIATE)
end

----------------------------------------------------------------------
-- Show status changes. Only fault statuses get audio, and the alarm off switch silences everything.
local function processStatus(tmpCfg, tmpSensorID)
    local entry  = SensorT[tmpCfg.sensorname]
    local sensor = entry.sensor
    local statusint
    local text

    if(not sensor.valid) then
        entry.text = "OFFLINE"
        return
    end

    statusint  = string.format("%s", math.floor(sensor.value))
    text       = config.converter.statusmap[statusint] or string.format("Status %s", statusint) -- Fallback label for unknown codes
    entry.text = text

    -- If status hasn't changed since last check, nothing to do
    if(prevStatusID == text) then
        return
    end

    -- Always track the current status, even during startup suppression,
    -- so that the stable at-rest state doesn't trigger an alarm when suppression lifts
    prevStatusID = text

    turbineStopped = hasWord(text, STOPPED_WORDS)
    if(turbineStopped) then
        disarmLowAlarms()
    end

    -- Suppress alarms during the startup cooldown window, or while the alarm off switch is active
    if(alarmTriggeredTime.status >= nowSeconds() or not enableAlarm) then
        return
    end

    system.messageBox(text, 5)
    if(hasWord(text, FAULT_WORDS)) then
        playStatusAudio(text)
    end
end

----------------------------------------------------------------------
-- Check if switch to enable alarms is set, sets global enableAlarm value
local function enableAlarmCheck()
    local switch

    if(not alarmOffSwitch) then
        enableAlarm = true -- no switch assigned, alarms are always on
        return
    end

    switch = system.getSwitchInfo(alarmOffSwitch)
    if(switch and switch.assigned ~= false) then -- an unassigned switch never disables the alarms
        if(switch.value < 0) then  -- turned off by switch, will always override status handling
            enableAlarm      = false
        else
            enableAlarm      = true
        end
    else
        enableAlarm      = true
    end
end

----------------------------------------------------------------------
-- Read and map all sensors to names instead of param values for easier processing
local function readParamsFromSensor(tmpSensorID)

    local countSensorsValid = 0
    local countSensors      = 0
    local countCritical     = 0
    local countCriticalValid = 0
    local online
    local entry
    local sensor
    local param

    for tmpSensorName, tmpSensorParam in pairs(config.converter.sensormap) do
        entry = SensorT[tmpSensorName]
        if(not entry) then
            entry = {percent = 0}
            SensorT[tmpSensorName] = entry
        end

        param  = tonumber(tmpSensorParam) or 0
        sensor = nil
        if(param > 0) then
            --print(string.format("rsensor: %s : %s : %s", tmpSensorID, tmpSensorName, param))
            sensor = system.getSensorByID(tmpSensorID, param) -- nil if the sensor is unknown
        end

        if(sensor) then
            countSensors = countSensors + 1
            if(CRITICAL_SENSORS[tmpSensorName]) then
                countCritical = countCritical + 1
            end

            if(sensor.valid) then
                countSensorsValid = countSensorsValid + 1
                if(CRITICAL_SENSORS[tmpSensorName]) then
                    countCriticalValid = countCriticalValid + 1
                end
            else
                -- The sensor exist, but is not valid yet.
                sensor.value  = 0
                entry.percent = 0
            end
            entry.sensor = sensor
        else
            -- The sensor does not exist, or the param is zero (not provided by this converter).
            -- Use the shared zero sensor so the process functions never see a nil sensor.
            entry.sensor  = EMPTY_SENSOR
            entry.percent = 0
        end
    end

    -- Online means every critical sensor (status, rpm, egt) is valid. Converters without any
    -- of them fall back to requiring all of their sensors.
    if(countCritical > 0) then
        online = (countCriticalValid == countCritical)
    else
        online = (countSensors > 0 and countSensorsValid == countSensors)
    end

    if(online) then
        offlineAlerts = 0
        -- On the first loop where the ECU is online, start a 30-second status-alarm
        -- suppression window so ECU boot states are silently recorded.
        if(not hadFullSignal) then
            hadFullSignal = true
            alarmTriggeredTime.status = nowSeconds() + 30
        end
    elseif((hadFullSignal or offlineAlerts > 0) and offlineAlerts < 5 and nextOfflineAlert < nowSeconds()) then
        -- The ECU was online and stopped reporting. Warn a few times (one announcement is easy to miss),
        -- then stay quiet until it has been online again.
        nextOfflineAlert = nowSeconds() + 15
        offlineAlerts    = offlineAlerts + 1
        hadFullSignal    = false
        print(string.format("ECU-16: ECU offline - critical sensors valid: %s of %s", countCriticalValid, countCritical))

        if(enableAlarm) then
            system.messageBox("ECU offline", 3)
            system.playFile("/Apps/ecu/audio/Ecu offline.wav", AUDIO_IMMEDIATE)
            system.vibration(false, 4)
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
    TurbineType       = realValue(system.pLoad("TurbineType", "hornet"), "hornet")
    TurbineConfig     = realValue(system.pLoad("TurbineConfig", "generic"), "generic")
    BatteryConfig     = realValue(system.pLoad("BatteryConfig", 'lipo-2s'), "lipo-2s")
    TankSize          = system.pLoad("TankSize", 3500)
    alarmOffSwitch    = system.pLoad("alarmOffSwitch")
    -- read all the config files
    loadConfig()
    system.registerTelemetry(1, string.format("%s - 16", lang.window1),2,window)
    collectgarbage()
    print("Init finished: ", collectgarbage("count"))
end
----------------------------------------------------------------------
-- One cycle of sensor reading and alarm processing (called through pcall from loop)
local function loopBody()
    enableAlarmCheck()
    readParamsFromSensor(SensorID) -- Real sensor values

    -- Only process sensors the converter maps, since the availibility varies
    if(mapped("fuel")) then
        processFuel(config.fuel, SensorID)
    end
    if(mapped("rpm")) then
        processGeneric(config.rpm, SensorID)
    end
    if(mapped("egt")) then
        processGeneric(config.egt, SensorID)
    end
    if(mapped("pumpv")) then
        processGeneric(config.pumpv, SensorID)
    end
    if(mapped("ecuv")) then
        processGeneric(config.ecuv, SensorID)
    end
    if(mapped("status")) then
        processStatus(config.status, SensorID)
    end
end

----------------------------------------------------------------------
-- Loop has to be the last function, so every other function is initialized
local function loop()
    local ok
    local err
    local now

    if(not SensorID or SensorID == 0) then
        return
    end

    -- A Lua error must never stop the app silently, and an unusable config must never look like
    -- a working one: warn (throttled) while nothing is being monitored.
    if(configValid) then
        ok, err = pcall(loopBody)
    else
        ok, err = false, "Configuration invalid"
    end

    if(not ok) then
        now = nowSeconds()
        if(now >= nextFaultAlert) then
            nextFaultAlert = now + 30
            print(string.format("ECU-16: monitoring is OFF: %s", tostring(err)))
            system.messageBox(configValid and "ECU: monitoring fault" or "ECU: config invalid, NOT monitored", 3)
            system.playFile("/Apps/ecu/audio/Error.wav", AUDIO_IMMEDIATE)
        end
    end
end

lang = fileJson(string.format("Apps/ecu/locale/%s.jsn", system.getLocale()))
    or fileJson("Apps/ecu/locale/en.jsn")
    or {appName = "ECU", window1 = "ECU", window2 = "ECU"}
return {init=init, loop=loop, author="Thomas Ekdahl - thomas@ekdahl.no", version='3.0', name=string.format("%s -16", lang.appName)}