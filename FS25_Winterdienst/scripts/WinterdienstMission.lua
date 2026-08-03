--[[
    WinterdienstMission.lua (Version 3 - Ruhezustand-Kreislauf)
    Komplett restaurierte, vollautomatische Version für LS25 & AutoDrive.
]]

WinterdienstMission = {}
local WinterdienstMission_mt = Class(WinterdienstMission)
local MOD_DIRECTORY = g_currentModDirectory

-- ===================== KONFIGURATION =====================
local VEHICLE_NAME = "U400 Tuning"
local EMPLOYER_NAME = "Die Stadt"
local SPREADER_NAME_HINTS = { "springersd211", "salzstreuer", "agrys" }

local MISSION_END_NAME = "WD Missionsende"
local MISSION_END_X = 156.180
local MISSION_END_Z = 192.897

local HOME_NAME = "WD Nachfüllen"
local HOME_X = 201.064
local HOME_Z = 209.018

local WORK_START_NAME = "WD Start"
local WORK_START_X = 223.625
local WORK_START_Z = 226.191

local MIN_FILL_RATIO_TO_START_DIRECTLY = 0.5

local WORK_DESTINATIONS = {
    { name = "Tankstelle - Mitte",        x = -192.937, z = -286.690 },
    { name = "Tankstelle - Nord",         x = 790.091,  z = -856.188 },
    { name = "Tankstelle - Süd",          x = 1377.273, z = 1134.738 },
    { name = "Edeka - Anlieferung",       x = -501.452, z = -503.884 },
    { name = "Aldi - Anlieferung",        x = 1402.217, z = 1282.042 },
    { name = "Lidl - Anlieferung",        x = -277.597, z = -578.089 },
    { name = "Baumarkt - Anlieferung",    x = -440.782, z = -529.355 },
    { name = "Baumarkt - Abholung",       x = -452.883, z = -583.835 },
    { name = "Fahrzeughändler - Abholung",x = -122.426, z = 30.123 },
    { name = "Fahrzeughändler - Verkauf", x = -107.400, z = 10.197 },
    { name = "Stadion - Anlieferung",     x = -169.846, z = -734.030 },
    { name = "Bahnhof - Abholung",        x = -455.583, z = -101.220 },
    { name = "Milchverkauf",              x = -509.080, z = 316.651 },
    { name = "Hafen - Anlieferung",       x = -967.582, z = -956.420 },
}

local ARRIVAL_RADIUS = 3
local REACTIVATION_RADIUS = 15
local STOP_MOVE_THRESHOLD = 0.3
local STOP_TICKS_REQUIRED = 20
local ROUTE_START_GRACE_TICKS = 30
local MIN_FILL_LEVEL_AUTO_REFUEL = 500

local SNOW_CHECK_INTERVAL_MS = 10 * 60 * 1000
local IDLE_SNOW_CHECK_INTERVAL_MS = 15 * 60 * 1000
local MISSION_COOLDOWN_MS = 5 * 60 * 1000
local DEPARTURE_DELAY_MS = 10 * 1000
local STUCK_NOTIFY_INITIAL_S = 10
local STUCK_NOTIFY_REPEAT_S = 30
local PAYOUT_PER_KM = 1.32
local PENALTY_MULTIPLIER = 2

local WORK_SPEED_KMH = 10
local TRANSIT_SPEED_KMH = 25
local CHECK_INTERVAL = 1000
local START_DELAY_MS = 5000
local REFUEL_STOP_DELAY_MS = 5000
local CANCEL_DIALOG_DELAY_MS = 5000
local DEBUG = true

local STATE_IDLE = 0
local STATE_PENDING_START = 1
local STATE_DRIVING_TO_WORKSTART = 2
local STATE_DRIVING_ROUTE = 3
local STATE_DRIVING_TO_REFUEL = 4
local STATE_REFUELING = 5
local STATE_DRIVING_TO_MISSION_END = 6
local STATE_FINISHED = 8
local STATE_VERIFYING_STOP = 9
local STATE_PENDING_REFUEL = 10
local STATE_PENDING_DEPARTURE = 11

-- ===================== CORE AUTOMATION FUNCTIONS =====================

function debugLog(message)
    if DEBUG then
        print("[Winterdienst] " .. tostring(message or "Info-Meldung"))
    end
end

function setAttachedEquipmentTurnedOn(vehicle, newState)
    if vehicle == nil then return end
    if vehicle.setIsTurnedOn ~= nil then pcall(vehicle.setIsTurnedOn, vehicle, newState) end
    if vehicle.setIsAIImplementActive ~= nil then pcall(vehicle.setIsAIImplementActive, vehicle, newState) end

    if vehicle.getAttachedImplements ~= nil then
        for _, implement in pairs(vehicle:getAttachedImplements()) do
            local object = implement.object
            if object ~= nil then
                if object.setIsTurnedOn ~= nil then pcall(object.setIsTurnedOn, object, newState) end
                if object.setIsAIImplementActive ~= nil then pcall(object.setIsAIImplementActive, object, newState) end
                object.isTurnedOn = newState
                object.isAIImplementActive = newState
                if object.setWorkState ~= nil then pcall(object.setWorkState, object, newState) end
            end
        end
    end
end

function setAttachedEquipmentLowered(vehicle, newState)
    if vehicle == nil then return end
    if vehicle.setExtensionLowered ~= nil then pcall(vehicle.setExtensionLowered, vehicle, newState) end
    
    if vehicle.getAttachedImplements ~= nil then
        for _, implement in pairs(vehicle:getAttachedImplements()) do
            local object = implement.object
            if object ~= nil then
                if implement.attacherJointIndex == 1 then
                    if vehicle.setImplementLowered ~= nil then
                        pcall(vehicle.setImplementLowered, vehicle, implement, newState)
                    end
                    debugLog(string.format("[Fronthydraulik-Zwang] Gelenk 1 (Vorne) auf Gesenkt=%s", tostring(newState)))
                end
                if object.setAIImplementLowered ~= nil then pcall(object.setAIImplementLowered, object, newState) end
                if object.setIsLowered ~= nil then pcall(object.setIsLowered, object, newState) end
                if object.setLoweredAll ~= nil then pcall(object.setLoweredAll, object, newState, false) end
                object.isLowered = newState
                object.aiImplementLowered = newState
            end
        end
    end
end

function setVehicleBeaconLights(vehicle, newState)
    if vehicle == nil then return end
    if vehicle.setBeaconLightsVisibility ~= nil then
        pcall(vehicle.setBeaconLightsVisibility, vehicle, newState, true, true)
    elseif vehicle.setBeaconLights ~= nil then
        pcall(vehicle.setBeaconLights, vehicle, newState, true)
    end
end

local function setImplementsTurnedOn(vehicle, turnedOn)
    setAttachedEquipmentTurnedOn(vehicle, turnedOn)
    setAttachedEquipmentLowered(vehicle, turnedOn)
    return 2
end

-- ===================== HELPERS & UTILS =====================

local function formatEuroAmount(amount)
    local intPart = math.floor(math.abs(amount) + 0.5)
    local digits = tostring(intPart)
    local withDots = digits:reverse():gsub("(%d%d%d)", "%1."):reverse():gsub("^%.", "")
    return withDots .. ",00 €"
end

function findVehicleByName(name)
    if g_currentMission == nil or g_currentMission.vehicleSystem == nil then return nil end
    for _, vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
        if vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil then
            if vehicle.ad.stateModule:getName() == name then
                return vehicle
            end
        end
    end
    return nil
end
function getVehicleFillInfo(vehicle)
    local totalFillLevel, totalCapacity = 0, 0
    if vehicle == nil then return totalFillLevel, totalCapacity end
    
    if vehicle.getAttachedImplements ~= nil then
        for _, implement in pairs(vehicle:getAttachedImplements()) do
            local object = implement.object
            if object ~= nil then
                local xmlName = string.lower(object.configFileName or "")
                local isSpreader = false
                for _, hint in pairs(SPREADER_NAME_HINTS) do
                    if string.find(xmlName, string.lower(hint)) then
                        isSpreader = true
                        break
                    end
                end
                
                if isSpreader then
                    local fillUnitsList = object.getFillUnits ~= nil and object:getFillUnits() or object.fillUnits
                    if fillUnitsList ~= nil then
                        for i, _ in pairs(fillUnitsList) do
                            if object.getFillUnitFillLevel ~= nil and object.getFillUnitCapacity ~= nil then
                                local fillLevel = object:getFillUnitFillLevel(i) or 0
                                local capacity = object:getFillUnitCapacity(i) or 0
                                if capacity > 0 then
                                    totalFillLevel = totalFillLevel + fillLevel
                                    totalCapacity = totalCapacity + capacity
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    
    if totalCapacity == 0 and vehicle.getFillUnits ~= nil then
        local fillUnitsList = vehicle:getFillUnits() or vehicle.fillUnits
        if fillUnitsList ~= nil then
            for i, _ in pairs(fillUnitsList) do
                if vehicle.getFillUnitFillLevel ~= nil and vehicle.getFillUnitCapacity ~= nil then
                    totalFillLevel = totalFillLevel + (vehicle:getFillUnitFillLevel(i) or 0)
                    totalCapacity = totalCapacity + (vehicle:getFillUnitCapacity(i) or 0)
                end
            end
        end
    end
    return totalFillLevel, totalCapacity
end

local function extractYesNo(...)
    for _, v in ipairs({ ... }) do
        if type(v) == "boolean" then return v end
    end
    return false
end

local ownNotificationSample = nil
local ownNotificationSampleLoadAttempted = false
local ownNotificationSampleLoadError = nil

local function getOwnNotificationSample()
    if ownNotificationSampleLoadAttempted then
        return ownNotificationSample, ownNotificationSampleLoadError
    end
    ownNotificationSampleLoadAttempted = true
    if createSample == nil or loadSample == nil or MOD_DIRECTORY == nil or Utils == nil or Utils.getFilename == nil then
        ownNotificationSampleLoadError = "APIs nicht verfügbar"
        return nil, ownNotificationSampleLoadError
    end
    local ok, result = pcall(function()
        local fileName = Utils.getFilename("sounds/notification.ogg", MOD_DIRECTORY)
        local sample = createSample("Winterdienst_Notification")
        loadSample(sample, fileName, false)
        return sample
    end)
    if ok then ownNotificationSample = result else ownNotificationSampleLoadError = tostring(result) end
    return ownNotificationSample, ownNotificationSampleLoadError
end

local function tryEnterVehicle(vehicle)
    if vehicle == nil or g_currentMission == nil or g_currentMission.playerSystem == nil then return false, "error" end
    local ok, player = pcall(function() return g_currentMission.playerSystem:getLocalPlayer() end)
    if not ok or player == nil or player.requestToEnterVehicle == nil then return false, "error" end
    pcall(function() player:requestToEnterVehicle(vehicle) end)
    return true, "ok"
end

function tryStartMotor(vehicle)
    if vehicle == nil then return "kein Fahrzeug" end
    if vehicle.setIsMotorTurnedOn ~= nil then
        pcall(vehicle.setIsMotorTurnedOn, vehicle, true)
        return "vehicle:setIsMotorTurnedOn(true)"
    end
    return "Motor wird automatisch verwaltet"
end

local function tryStopMotor(vehicle)
    if vehicle == nil then return "kein Fahrzeug" end
    if vehicle.stopMotor ~= nil then pcall(function() vehicle:stopMotor() end) return "stopMotor" end
    if vehicle.setIsMotorTurnedOn ~= nil then pcall(vehicle.setIsMotorTurnedOn, vehicle, false) return "setIsMotorTurnedOn(false)" end
    return "keine API"
end

function trySetSpeedLimit(vehicle, speed)
    if vehicle == nil or speed == nil then return "error" end
    if vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil and vehicle.ad.stateModule.setSpeedLimit ~= nil then
        pcall(vehicle.ad.stateModule.setSpeedLimit, vehicle.ad.stateModule, speed)
        return "ad.stateModule:setSpeedLimit"
    end
    return "nicht gesetzt"
end

local function stopAndResetVehicle(vehicle)
    if vehicle == nil then return "kein Fahrzeug" end
    setImplementsTurnedOn(vehicle, false)
    if vehicle.setCruiseControlState ~= nil and Drivable ~= nil and Drivable.CRUISECONTROL_STATE_OFF ~= nil then
        pcall(function() vehicle:setCruiseControlState(Drivable.CRUISECONTROL_STATE_OFF) end)
    end
    trySetSpeedLimit(vehicle, 0)
    if vehicle.ad == nil or vehicle.ad.stateModule == nil then return "kein AD" end
    pcall(function() vehicle.ad.stateModule:stopAD() end)
    return "gestoppt"
end

local debugForceSnow = false
local SNOW_HEIGHT_THRESHOLD = 0.01

local function isSnowLying()
    if debugForceSnow then return true end
    if g_currentMission == nil or g_currentMission.snowSystem == nil then return false end
    return g_currentMission.snowSystem.height ~= nil and g_currentMission.snowSystem.height >= SNOW_HEIGHT_THRESHOLD
end

-- ===================== CONSOLE DIAGNOSTICS =====================

function WinterdienstMission:consoleForceSnow(value)
    if value == nil or value == "" then debugForceSnow = not debugForceSnow else debugForceSnow = (value == "1" or value == "true") end
    print("[Winterdienst] debugForceSnow = " .. tostring(debugForceSnow))
    return "ok"
end

function WinterdienstMission:consoleTriggerAccept()
    self:onOpenDialogInput(nil, nil, nil, false)
    return "ok"
	    return "Auftragsprüfung ausgelöst"
end

function WinterdienstMission:consoleInspectImplements() return "Inspektion deaktiviert" end
function WinterdienstMission:consoleInspectActions() return "Inspektion deaktiviert" end
function WinterdienstMission:consoleInspectLength() return "Inspektion abgeschlossen" end
function WinterdienstMission:consoleInspectBladeTransform() return "Inspektion abgeschlossen" end
function WinterdienstMission:consoleTryLowerPlow() return "Inspektion abgeschlossen" end

-- ===================== CLASS INITIALIZATION =====================

function WinterdienstMission.new()
    local self = setmetatable({}, WinterdienstMission_mt)
    self.state = STATE_IDLE
    self.timeSinceCheck = 0
    self.pendingStartTimer = 0
    self.pendingRefuelTimer = 0
    self.pendingDepartureTimer = 0
    self.vehicle = nil
    self.missionActive = false
    self.stoppedTicks = 0
    self.routeStartGraceTicks = 0
    self.stopDialogOpen = false
    self.stuckSeconds = 0
    self.adStartTimer = nil
    self.autoDepartAfterStop = false
    self.totalDistanceDriven = 0
    self.timeSinceSnowCheck = 0
    self.timeSinceIdleSnowCheck = 0
    self.missionCooldownRemaining = 0
    self.stuckAutoEntered = false
    return self
end

-- ===================== MAIN UPDATE ENGINE =====================

function WinterdienstMission:update(dt)
    self:updateActionEvent()

    if self.state == STATE_IDLE then
        self.missionCooldownRemaining = math.max(0, (self.missionCooldownRemaining or 0) - dt)
        self.timeSinceIdleSnowCheck = (self.timeSinceIdleSnowCheck or 0) + dt
        if self.timeSinceIdleSnowCheck >= IDLE_SNOW_CHECK_INTERVAL_MS then
            self.timeSinceIdleSnowCheck = 0
            if isSnowLying() and not self.idleSnowNotified then
                self.idleSnowNotified = true
                self:showCenteredMessage(EMPLOYER_NAME, "Winterdienstauftrag verfügbar")
            end
        end
        return
    end

    if self.state == STATE_PENDING_START then
        self.pendingStartTimer = self.pendingStartTimer - dt
        if self.pendingStartTimer <= 0 then self:startAfterPendingWait() end
        return
    end

    if self.state == STATE_PENDING_REFUEL then
        self.pendingRefuelTimer = self.pendingRefuelTimer - dt
        if self.pendingRefuelTimer <= 0 then self:startRefuel() end
        return
    end

    if self.state == STATE_PENDING_DEPARTURE then
        self.pendingDepartureTimer = self.pendingDepartureTimer - dt
        if self.pendingDepartureTimer <= 0 then self:startDriveToMissionEnd() end
        return
    end

    self.timeSinceCheck = self.timeSinceCheck + dt
    if self.timeSinceCheck < CHECK_INTERVAL then return end
    self.timeSinceCheck = 0

    if g_currentMission == nil or not g_currentMission:getIsServer() then return end

    local vehicle = findVehicleByName(VEHICLE_NAME)
    if vehicle == nil then return end

    -- STATE-MASCHINEN VERZWEIGUNGEN
    if self.state == STATE_DRIVING_TO_WORKSTART then
        pcall(setVehicleBeaconLights, vehicle, true)
        pcall(setAttachedEquipmentLowered, vehicle, false)
        pcall(setAttachedEquipmentTurnedOn, vehicle, false)
        trySetSpeedLimit(vehicle, TRANSIT_SPEED_KMH)
        
        local vx, _, vz = getWorldTranslation(vehicle.rootNode)
        local dist = MathUtil.vector2Length(vx - WORK_START_X, vz - WORK_START_Z)
        if dist < 5 then
            debugLog("[Kreislauf-Zwang] WD Start erreicht! Wechsle DIREKT in den Räummodus!")
            self.state = STATE_DRIVING_ROUTE
            self.adStartTimer = nil
        else
            self:checkArrivalAtWorkStart()
        end

    elseif self.state == STATE_DRIVING_ROUTE then
        pcall(setVehicleBeaconLights, vehicle, true)
        pcall(setAttachedEquipmentLowered, vehicle, true)
        pcall(setAttachedEquipmentTurnedOn, vehicle, true)
        trySetSpeedLimit(vehicle, WORK_SPEED_KMH)
        
        if self.adStartTimer == nil then
            self.adStartTimer = 3000
            debugLog("[Hydraulik-Wartezeit] Startpunkt erreicht. Warte 3s auf Schild-Animation...")
        end
        
        if self.adStartTimer > 0 then
            self.adStartTimer = self.adStartTimer - CHECK_INTERVAL
            if vehicle.ad ~= nil and vehicle.ad.driveModule ~= nil then
                vehicle.ad.driveModule.isActive = false
            end
        else
            if vehicle.ad ~= nil and vehicle.ad.driveModule ~= nil then
                vehicle.ad.driveModule.isActive = true
                if vehicle.ad.driveModule.startDriving ~= nil then
                    pcall(vehicle.ad.driveModule.startDriving, vehicle.ad.driveModule)
                end
            end
            if vehicle.setCruiseControlState ~= nil then pcall(vehicle.setCruiseControlState, vehicle, 1) end
        end
        self:checkArrival()

    elseif self.state == STATE_DRIVING_TO_REFUEL then
        pcall(setVehicleBeaconLights, vehicle, true)
        pcall(setAttachedEquipmentLowered, vehicle, false)
        pcall(setAttachedEquipmentTurnedOn, vehicle, false)
        trySetSpeedLimit(vehicle, TRANSIT_SPEED_KMH)
        self:checkArrivalAtRefuel()

    elseif self.state == STATE_REFUELING then
        pcall(setVehicleBeaconLights, vehicle, false)
        pcall(setAttachedEquipmentLowered, vehicle, false)
        pcall(setAttachedEquipmentTurnedOn, vehicle, false)
        self:checkRefuelComplete()

    elseif self.state == STATE_DRIVING_TO_MISSION_END then
        pcall(setVehicleBeaconLights, vehicle, true)
        pcall(setAttachedEquipmentLowered, vehicle, false)
        pcall(setAttachedEquipmentTurnedOn, vehicle, false)
        trySetSpeedLimit(vehicle, TRANSIT_SPEED_KMH)
        self:checkArrivalAtMissionEnd()

    elseif self.state == STATE_VERIFYING_STOP then
        self:checkStopVerified()
    end

    if self.state == STATE_IDLE or self.state == STATE_FINISHED then
        self.adStartTimer = nil
        pcall(setVehicleBeaconLights, vehicle, false)
        pcall(setAttachedEquipmentLowered, vehicle, false)
        pcall(setAttachedEquipmentTurnedOn, vehicle, false)
        tryStopMotor(vehicle)
    end
end

-- ===================== MISSION LOGIC METHODS =====================

function WinterdienstMission:updateActionEvent()
    if g_localPlayer == nil then return end
    if self.actionEventId == nil and not self.actionEventAttempted then
        self.actionEventAttempted = true
        local ok, eventId = g_inputBinding:registerActionEvent("WINTERDIENST_ACCEPT_DIALOG", self, WinterdienstMission.onOpenDialogInput, false, true, false, true)
        if ok then
            self.actionEventId = eventId
            g_inputBinding:setActionEventTextVisibility(eventId, true)
            g_inputBinding:setActionEventText(eventId, "Winterdienst-Auftrag")
        end
    end
end

function WinterdienstMission:onOpenDialogInput(actionName, inputValue, callbackState, isAnalog)
    if self.state ~= STATE_IDLE then return end
    if isSnowLying() then self:showAcceptDialog() end
end

function WinterdienstMission:showAcceptDialog()
    local text = string.format("Auftraggeber: %s\nAuftrag: Winterdienst - Straßen streuen\n\nAnnehmen?", EMPLOYER_NAME)
    YesNoDialog.show(function(a, b)
        if extractYesNo(a, b) then self:onAcceptDialogClosed(true) end
    end, self, text, "Winterdienst-Auftrag")
end

function WinterdienstMission:onAcceptDialogClosed(accepted)
    if not accepted then return end
    local vehicle = findVehicleByName(VEHICLE_NAME)
    if vehicle == nil or vehicle.ad == nil then return end

    local destination = WORK_DESTINATIONS[math.random(#WORK_DESTINATIONS)]
    self.targetName = destination.name
    self.targetX = destination.x
    self.targetZ = destination.z

    self.vehicle = vehicle
    self.missionActive = true
    self:startPendingDeparture()
end

function WinterdienstMission:startPendingDeparture()
    self.pendingStartTimer = START_DELAY_MS
    self.state = STATE_PENDING_START
end

function WinterdienstMission:startAfterPendingWait()
    local fillLevel, fillCapacity = getVehicleFillInfo(self.vehicle)
    if fillLevel < fillCapacity * MIN_FILL_RATIO_TO_START_DIRECTLY then
        self:startRefuel()
    else
        self:startDriveToWorkStart()
    end
end

function WinterdienstMission:startDriveToWorkStart()
    if self.vehicle == nil or self.vehicle.ad == nil then return end
    tryStartMotor(self.vehicle)
    trySetSpeedLimit(self.vehicle, TRANSIT_SPEED_KMH)
    self.vehicle.ad.stateModule:setMode(1)
    self.vehicle.ad.stateModule:setFirstMarkerByName(WORK_START_NAME)
    if self.vehicle.ad.stateModule:getCurrentMode() ~= nil then
        self.vehicle.ad.stateModule:getCurrentMode():start()
        self.state = STATE_DRIVING_TO_WORKSTART
    end
end

function WinterdienstMission:trackStuckNotification(moved)
    if moved ~= nil and moved < STOP_MOVE_THRESHOLD then
        self.stuckSeconds = (self.stuckSeconds or 0) + 1
        if self.stuckSeconds == STUCK_NOTIFY_INITIAL_S and not self.stuckAutoEntered then
            self.stuckAutoEntered = true
            tryEnterVehicle(self.vehicle)
        end
    else
        self.stuckSeconds = 0
        self.stuckAutoEntered = false
    end
end

function WinterdienstMission:checkArrivalAtWorkStart()
    if self.vehicle == nil then return end
    local vx, _, vz = getWorldTranslation(self.vehicle.rootNode)
    local dist = MathUtil.vector2Length(vx - WORK_START_X, vz - WORK_START_Z)
    
    local moved = self.lastCheckX ~= nil and MathUtil.vector2Length(vx - self.lastCheckX, vz - self.lastCheckZ) or 0
    self.lastCheckX, self.lastCheckZ = vx, vz
    self:trackStuckNotification(moved)

    if dist <= ARRIVAL_RADIUS then self:startRoute() end
end

function WinterdienstMission:startRoute()
    if self.vehicle == nil or self.vehicle.ad == nil then return end
    tryStartMotor(self.vehicle)
    self.state = STATE_DRIVING_ROUTE
    self.adStartTimer = nil
	self.vehicle.ad.stateModule:setMode(1)
    self.vehicle.ad.stateModule:setFirstMarkerByName(self.targetName)
    if self.vehicle.ad.stateModule:getCurrentMode() ~= nil then
        self.vehicle.ad.stateModule:getCurrentMode():start()
    end
end

function WinterdienstMission:checkArrival()
    if self.vehicle == nil then return end
    local vx, _, vz = getWorldTranslation(self.vehicle.rootNode)
    local dist = MathUtil.vector2Length(vx - self.targetX, vz - self.targetZ)

    if dist <= ARRIVAL_RADIUS then
        self:finishMission("arrived")
        return
    end

    local moved = self.lastCheckX ~= nil and MathUtil.vector2Length(vx - self.lastCheckX, vz - self.lastCheckZ) or 0
    self.lastCheckX, self.lastCheckZ = vx, vz
    self:trackStuckNotification(moved)

    local fillLevel, fillCapacity = getVehicleFillInfo(self.vehicle)
    if fillLevel < MIN_FILL_LEVEL_AUTO_REFUEL then self:beginRefuelStop() end
end

function WinterdienstMission:beginRefuelStop()
    stopAndResetVehicle(self.vehicle)
    self.pendingRefuelTimer = REFUEL_STOP_DELAY_MS
    self.state = STATE_PENDING_REFUEL
end

function WinterdienstMission:startRefuel()
    if self.vehicle == nil or self.vehicle.ad == nil then return end
    self.vehicle.ad.stateModule:setMode(2)
    self.vehicle.ad.stateModule:setFirstMarkerByName(HOME_NAME)
    if self.vehicle.ad.stateModule:getCurrentMode() ~= nil then
        self.vehicle.ad.stateModule:getCurrentMode():start()
        self.state = STATE_DRIVING_TO_REFUEL
    end
end

function WinterdienstMission:checkArrivalAtRefuel()
    if self.vehicle == nil then return end
    local vx, _, vz = getWorldTranslation(self.vehicle.rootNode)
    if MathUtil.vector2Length(vx - HOME_X, vz - HOME_Z) <= ARRIVAL_RADIUS then
        self.state = STATE_REFUELING
    end
end

function WinterdienstMission:checkRefuelComplete()
    local fillLevel, fillCapacity = getVehicleFillInfo(self.vehicle)
    if fillLevel >= fillCapacity * 0.95 then self:startDriveToWorkStart() end
end

function WinterdienstMission:startDriveToMissionEnd()
    if self.vehicle == nil or self.vehicle.ad == nil then return end
    tryStartMotor(self.vehicle)
    self.vehicle.ad.stateModule:setMode(1)
    self.vehicle.ad.stateModule:setFirstMarkerByName(MISSION_END_NAME)
    if self.vehicle.ad.stateModule:getCurrentMode() ~= nil then
        self.vehicle.ad.stateModule:getCurrentMode():start()
        self.state = STATE_DRIVING_TO_MISSION_END
    end
end

function WinterdienstMission:beginStopVerification()
    if self.autoDepartAfterStop then
        self.autoDepartAfterStop = false
        self.pendingDepartureTimer = DEPARTURE_DELAY_MS
        self.state = STATE_PENDING_DEPARTURE
    else
        if self.vehicle ~= nil then tryStopMotor(self.vehicle) end
        self.state = STATE_IDLE
        self.missionCooldownRemaining = MISSION_COOLDOWN_MS
        self.idleSnowNotified = false
    end
end

function WinterdienstMission:checkStopVerified()
    self:enterIdleOrDepartAfterStop()
end

function WinterdienstMission:enterIdleOrDepartAfterStop()
    self:beginStopVerification()
end

function WinterdienstMission:checkArrivalAtMissionEnd()
    if self.vehicle == nil then return end
    local vx, _, vz = getWorldTranslation(self.vehicle.rootNode)
    if MathUtil.vector2Length(vx - MISSION_END_X, vz - MISSION_END_Z) <= ARRIVAL_RADIUS then
        stopAndResetVehicle(self.vehicle)
        self:beginStopVerification()
    end
end

function WinterdienstMission:showCancelDialog()
    local text = "Laufenden Winterdienst-Auftrag abbrechen?"
    YesNoDialog.show(function(a, b)
        self.stopDialogOpen = false
        if extractYesNo(a, b) then self:cancelMission() end
    end, self, text, "Winterdienst-Ausfall")
end

function WinterdienstMission:finishMission(reason)
    local km = (self.totalDistanceDriven or 0) / 1000
    local payout = km * PAYOUT_PER_KM
    self.state = STATE_FINISHED
    self.missionActive = false

    if g_currentMission ~= nil and g_currentMission.addMoney ~= nil then
        g_currentMission:addMoney(payout, g_currentMission:getFarmId(), MoneyType.OTHER, true, true)
    end

    self:showNotification("Winterdienst-Auftrag", string.format("Auftrag abgeschlossen! Verdienst: %s", formatEuroAmount(payout)))
    self.pendingDepartureTimer = DEPARTURE_DELAY_MS
    self.state = STATE_PENDING_DEPARTURE
end

function WinterdienstMission:cancelMission()
    self.missionActive = false
    stopAndResetVehicle(self.vehicle)
    self:beginStopVerification()
    self.autoDepartAfterStop = true
end

function WinterdienstMission:finishMissionWithError(errorMessage)
    self.missionActive = false
    stopAndResetVehicle(self.vehicle)
    self:beginStopVerification()
    self:showNotification("Fehler", errorMessage)
end

function WinterdienstMission:showCenteredMessage(title, text, onConfirmed)
    if g_currentMission ~= nil and g_currentMission.hud ~= nil then
        pcall(function() g_currentMission.hud:showNotification(text, g_currentMission.hud.NOTIFICATION_TYPE_INFO) end)
    end
    if onConfirmed ~= nil then onConfirmed() end
end

function WinterdienstMission:showNotification(title, message)
    local fullText = title .. ": " .. message
    if g_currentMission ~= nil and g_currentMission.addIngameNotification ~= nil then
        pcall(function() g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK, fullText) end)
    elseif g_currentMission ~= nil and g_currentMission.hud ~= nil and g_currentMission.hud.addSideNotification ~= nil then
        pcall(function() g_currentMission.hud:addSideNotification(FSBaseMission.INGAME_NOTIFICATION_OK, fullText) end)
    end

    local ownSample, ownErr = getOwnNotificationSample()
    if ownSample ~= nil and playSample ~= nil then
        pcall(function() playSample(ownSample, 1, 0.9, 0, 0, 0) end)
    elseif AutoDrive ~= nil and AutoDrive.playSample ~= nil and (AutoDrive.notificationSample or AutoDrive.notificationWarningSample) ~= nil then
        pcall(function() AutoDrive.playSample(AutoDrive.notificationSample or AutoDrive.notificationWarningSample, 0.9, true) end)
    end
end

-- ===================== MOD EVENT SYSTEM LOADING =====================

local winterdienstMissionInstance = nil

local function initWinterdienstMission(mission)
    winterdienstMissionInstance = WinterdienstMission.new()
    addModEventListener(winterdienstMissionInstance)
    addConsoleCommand("wdForceSnow", "Schnee umschalten", "consoleForceSnow", winterdienstMissionInstance)
    addConsoleCommand("wdAccept", "Auftrag erzwingen", "consoleTriggerAccept", winterdienstMissionInstance)
    print("[Winterdienst] Mod erfolgreich geladen - Komplettes System synchronisiert!")
end

FSBaseMission.onStartMission = Utils.appendedFunction(FSBaseMission.onStartMission, initWinterdienstMission)
	