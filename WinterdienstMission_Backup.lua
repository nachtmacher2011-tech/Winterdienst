--[[
    WinterdienstMission.lua (Version 3 - Ruhezustand-Kreislauf)

    Kompletter Kreislauf:
    Ruhezustand an "WD Nachfüllen" (Depot, Motor/Streuer aus) -> alle 15 Minuten Schnee-Check
    -> bei Schnee: passive Meldung "Winterdienstauftrag verfügbar" -> Spieler steigt ein/springt
    per Tab rein -> Taste -> Annahme-Dialog -> Fahrt zu "WD Start" (Netzeinstieg) -> ab dort
    zufälliges Ziel über das bestehende Straßennetz (kürzeste Route) -> Auszahlung -> automatische
    Rückfahrt zu "WD Nachfüllen" -> Füllstand prüfen, bei Bedarf nachladen -> alles aus -> zurück
    in den Ruhezustand.
]]

WinterdienstMission = {}
local WinterdienstMission_mt = Class(WinterdienstMission)

-- 2026-08-01: g_currentModDirectory ist nur WAEHREND des Ladens DIESES Mods gueltig - deshalb
-- sofort beim Einlesen der Datei (top-level, nicht in einer Funktion) sichern, sonst zeigt es
-- spaeter auf den zuletzt geladenen Mod. Wird fuer den eigenen Signalton gebraucht (siehe unten,
-- getOwnNotificationSample) - AutoDrives eigene Sound-Samples (notificationSample/
-- notificationWarningSample) waren die GANZE Session ueber durchgaengig nil, ganz unabhaengig
-- vom Fahrzeug/Mod-Setup, daher jetzt eine eigene, mitgelieferte Sounddatei statt weiter auf
-- AutoDrive zu warten.
local MOD_DIRECTORY = g_currentModDirectory

-- ===================== KONFIGURATION =====================

local VEHICLE_NAME = "U400 Tuning"
local EMPLOYER_NAME = "Die Stadt"
-- Namensausschnitte (klein geschrieben) zur eindeutigen Identifikation des Streuers in
-- getVehicleFillInfo -- bewusst per Name, nicht per Faehigkeit: eine Faehigkeit wie
-- getAllowsLowering kann auch am Streuer vorhanden, aber ungenutzt sein (siehe FRICTION-LOG
-- 2026-07-30: dadurch faelschlich BEIDE Geraete ausgefiltert, Fuellstand 0/0). ACHTUNG: anders
-- als der Name nahelegt, ist das NICHT stabil -- wechselt der Streuer selbst (nicht nur das
-- Frontgeraet), muss hier der neue Modellname ergaenzt werden, sonst liefert
-- getVehicleFillInfo wieder 0/0 (siehe Test 2026-07-31: Streuer war auf Kahlbacher Agrys 150
-- gewechselt, configFileName "Agrys150.xml" enthielt "salzstreuer" nicht -> 0/0 dauerhaft,
-- deshalb hielt die Mission den Streuer permanent fuer leer und "Nachfuellen" wurde nie als
-- abgeschlossen erkannt).
local SPREADER_NAME_HINTS = { "salzstreuer", "agrys" }

-- Drei getrennte Punkte: "WD Missionsende" ist der Park-/Ruhepunkt (Motor aus, hier läuft
-- auch der 15-Minuten-Schnee-Check), "WD Nachfüllen" ist NUR der Nachfüll-Silo (wird nur bei
-- Bedarf angefahren), "WD Start" ist der gut angebundene Einstieg ins Hauptstraßennetz.
local MISSION_END_NAME = "WD Missionsende"
local MISSION_END_X = 156.180
local MISSION_END_Z = 192.897

local HOME_NAME = "WD Nachfüllen"
local HOME_X = 201.064
local HOME_Z = 209.018

local WORK_START_NAME = "WD Start"
local WORK_START_X = 223.625
local WORK_START_Z = 226.191

-- Ab diesem Füllstand-Anteil bei Auftragsannahme reicht es, direkt über WD Start loszufahren;
-- darunter wird zuerst der Nachfüllpunkt angefahren.
local MIN_FILL_RATIO_TO_START_DIRECTLY = 0.5

-- Zufällige Arbeitsziele aus dem vorhandenen Straßennetz (kuratierte Auswahl).
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
local STOP_TICKS_REQUIRED = 20 -- Sekunden Toleranz - AutoDrive braucht nach einem Richtungswechsel manchmal einen kurzen Moment, um sich neu zu orientieren (siehe "Ehrenrunde"), das darf nicht sofort als Stillstand gewertet werden
local ROUTE_START_GRACE_TICKS = 30 -- Sekunden nach jedem Richtungswechsel, in denen die Stillstand-Erkennung komplett pausiert (die Neuorientierung dauerte in Tests bis zu ~19-20s, zu nah an der alten Schwelle)
local MIN_FILL_LEVEL_AUTO_REFUEL = 500 -- Sicherheitsnetz: automatisches Nachfüllen auch mitten auf der Arbeitsroute

local SNOW_CHECK_INTERVAL_MS = 10 * 60 * 1000 -- während der Arbeit: alle 10 Minuten
local IDLE_SNOW_CHECK_INTERVAL_MS = 15 * 60 * 1000 -- im Ruhezustand: alle 15 Minuten
local MISSION_COOLDOWN_MS = 5 * 60 * 1000 -- Nutzer-Vorschlag: neuer Auftrag erst 5 Minuten nach Rückkehr zu WD Missionsende möglich
local DEPARTURE_DELAY_MS = 10 * 1000 -- Nutzer-Vorschlag: Meldung ist nicht-blockierend, nach dieser Zeit automatische Weiterfahrt ohne Bestätigungs-Zwang
local STUCK_NOTIFY_INITIAL_S = 10 -- Nutzer-Vorschlag: informative Meldung, falls das Fahrzeug auf Strecken ohne eigene Stillstand-Erkennung (WD Start, WD Missionsende) feststeckt
local STUCK_NOTIFY_REPEAT_S = 30 -- danach alle 30s erneut, solange der Stillstand anhält
local PAYOUT_PER_KM = 1.32
local PENALTY_MULTIPLIER = 2

local WORK_SPEED_KMH = 10
local TRANSIT_SPEED_KMH = 25 -- Nutzer-Wunsch 2026-08-01: winterliche Verhältnisse (Schild dauerhaft gesenkt), 30 war noch zu schnell

local CHECK_INTERVAL = 1000
local START_DELAY_MS = 5000
local REFUEL_STOP_DELAY_MS = 5000 -- Zwangsstopp vor der Nachfüll-Route, damit AutoDrive die kürzeste Route sauber neu berechnen kann
local CANCEL_DIALOG_DELAY_MS = 5000 -- Nutzer-Vorschlag: nach automatischem Fahrzeugwechsel wegen Standzeit-Überschreitung so lange warten, bevor der Abbruch-Dialog erscheint
local DEBUG = true

-- ===================== ZUSTÄNDE =====================

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

-- ===================== HILFSFUNKTIONEN =====================

local function debugLog(message)
    if DEBUG then
        print("[Winterdienst] " .. message)
    end
end

local function formatEuroAmount(amount)
    local intPart = math.floor(math.abs(amount) + 0.5)
    local digits = tostring(intPart)
    local withDots = digits:reverse():gsub("(%d%d%d)", "%1."):reverse():gsub("^%.", "")
    return withDots .. ",00 €"
end

local function findVehicleByName(name)
    if g_currentMission == nil or g_currentMission.vehicleSystem == nil then
        return nil
    end
    for _, vehicle in pairs(g_currentMission.vehicleSystem.vehicles) do
        if vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil then
            if vehicle.ad.stateModule:getName() == name then
                return vehicle
            end
        end
    end
    return nil
end

-- Füllstand NUR des Streuers, bewusst OHNE das Zugfahrzeug selbst (dessen Diesel-/AdBlue-Tank
-- würde die Summe verfälschen) UND OHNE das Frontgerät (Fräse/Schild). Das Frontgerät hat
-- laut Speicherstand selbst eine Füllzelle (z.B. fillType="UNKNOWN"), die vom Silo nie befüllt
-- wird -- zaehlte sie mit, erreichte die Gesamtsumme nie die 95%-Schwelle, obwohl der Streuer
-- laengst voll war (Test 2026-07-30). Identifikation NUR per Name (SPREADER_NAME_HINTS), nicht
-- per Faehigkeit -- eine Faehigkeitspruefung (z.B. getAllowsLowering) filterte einmal
-- faelschlich BEIDE Geraete aus, weil der Streuer die Methode ebenfalls (ungenutzt) hat.
local function getVehicleFillInfo(vehicle)
    local totalFillLevel, totalCapacity = 0, 0
    local function processObject(obj)
        local isSpreader = false
        if obj.configFileName ~= nil then
            local lowerName = tostring(obj.configFileName):lower()
            for _, hint in ipairs(SPREADER_NAME_HINTS) do
                if lowerName:find(hint) ~= nil then
                    isSpreader = true
                    break
                end
            end
        end
        if isSpreader and obj.spec_fillUnit ~= nil and obj.spec_fillUnit.fillUnits ~= nil then
            for _, fillUnit in pairs(obj.spec_fillUnit.fillUnits) do
                totalFillLevel = totalFillLevel + (fillUnit.fillLevel or 0)
                totalCapacity = totalCapacity + (fillUnit.capacity or 0)
            end
        end
        if obj.getAttachedImplements ~= nil then
            for _, implement in pairs(obj:getAttachedImplements()) do
                if implement.object ~= nil then
                    processObject(implement.object)
                end
            end
        end
    end
    if vehicle ~= nil and vehicle.getAttachedImplements ~= nil then
        for _, implement in pairs(vehicle:getAttachedImplements()) do
            if implement.object ~= nil then
                processObject(implement.object)
            end
        end
    end
    return totalFillLevel, totalCapacity
end

-- Liest einen Getter defensiv aus; gibt nil zurueck, wenn er fehlt, fehlschlaegt, oder selbst
-- nil liefert (z.B. beim Streuer, der kein Senk-Konzept hat) -- nil heisst hier "unbekannt",
-- nicht "false".
local function readBoolState(object, getterName)
    if object == nil or object[getterName] == nil then
        return nil
    end
    local ok, v = pcall(function() return object[getterName](object) end)
    if not ok or type(v) ~= "boolean" then
        return nil
    end
    return v
end

-- Schaltet angehängte Geräte ein/aus UND versucht sie abzusenken (viele Streuer/Sämaschinen
-- arbeiten erst im abgesenkten Zustand, "eingeschaltet" allein reicht oft nicht). Kein
-- Falten noetig (bestaetigt) - Standardtaste V senkt normal ganz ohne Entfalten.
--
-- WICHTIG: Der U400-Frontanbaupunkt senkt animiert über moveTime=2.5s (siehe U400.xml). Ruft
-- man setLoweredAll() waehrend dieser Animation erneut auf, reisst das die Animation
-- vermutlich immer wieder von vorne an, statt sie einmal durchlaufen zu lassen -- deshalb NUR
-- aufrufen, wenn der gemeldete Zustand (falls bekannt) noch nicht passt, nicht mehr
-- bedingungslos bei jedem Tick.
-- 2026-07-31: fand nur DIREKT angehaengte Anbaugeraete (eine Ebene) - getVehicleFillInfo weiter
-- unten rekursiert dagegen schon laenger bewusst durch die ganze Anbau-Kette (Kommentar dort:
-- "durchsucht auch Anbaugeraete AN Anbaugeraeten"). Beim Umbau auf Streuer-vorne/Fraese-hinten
-- kam heraus, dass die hintere Fraese ueberhaupt nicht angeschaltet/gesenkt wurde - Verdacht:
-- sie haengt ueber eine Zwischenkupplung (Deichsel/Dolly) und war dadurch fuer diese
-- nicht-rekursive Version unsichtbar. Jetzt rekursiv wie getVehicleFillInfo.
local function setImplementsTurnedOn(vehicle, turnedOn)
    if vehicle == nil or vehicle.getAttachedImplements == nil then
        return 0
    end
    local count = 0
    local function processObject(object)
        if object == nil then
            return
        end
        local didSomething = false
        local isOn = readBoolState(object, "getIsTurnedOn")
        if object.setIsTurnedOn ~= nil and isOn ~= turnedOn then
            object:setIsTurnedOn(turnedOn)
            didSomething = true
        end
        local isLowered = readBoolState(object, "getIsLowered")
        if object.setLoweredAll ~= nil and isLowered ~= turnedOn then
            object:setLoweredAll(turnedOn, false)
            didSomething = true
        end
        if didSomething then
            count = count + 1
        end
        if object.getAttachedImplements ~= nil then
            for _, subImplement in pairs(object:getAttachedImplements()) do
                processObject(subImplement.object)
            end
        end
    end
    for _, implement in pairs(vehicle:getAttachedImplements()) do
        processObject(implement.object)
    end
    return count
end

local function getModeDriveTo()
    if AutoDrive ~= nil and AutoDrive.MODE_DRIVETO ~= nil then
        return AutoDrive.MODE_DRIVETO
    end
    return 1
end

local function getModeLoad()
    if AutoDrive ~= nil and AutoDrive.MODE_LOAD ~= nil then
        return AutoDrive.MODE_LOAD
    end
    return 4
end

local function trySetSpeedLimit(vehicle, kmh)
    if vehicle == nil then
        return "kein Fahrzeug"
    end
    if vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil then
        local stateModule = vehicle.ad.stateModule
        -- Falls eine kuenftige AutoDrive-Version doch einen echten Setter mitbringt, den
        -- bevorzugen.
        if stateModule.setSpeedLimit ~= nil then
            local ok = pcall(function() stateModule:setSpeedLimit(kmh) end)
            if ok then return "stateModule:setSpeedLimit" end
        end
        -- In der aktuell installierten Version (scripts/Modules/StateModule.lua) gibt es
        -- dafuer KEINEN Setter -- nur getSpeedLimit()/increaseSpeedLimit()/decreaseSpeedLimit(),
        -- die self.speedLimit je um 1 veraendern. Direkt ins Feld schreiben ist derselbe Weg,
        -- den AutoDrives eigenes readFromXML/streamRead dafuer benutzt.
        if stateModule.speedLimit ~= nil then
            local target = kmh
            if AutoDrive ~= nil and AutoDrive.getVehicleMaxSpeed ~= nil then
                local okMax, vehicleMax = pcall(function() return AutoDrive.getVehicleMaxSpeed(vehicle) end)
                if okMax and vehicleMax ~= nil then
                    target = math.min(target, vehicleMax)
                end
            end
            stateModule.speedLimit = math.max(2, target)
            if stateModule.raiseDirtyFlag ~= nil then
                pcall(function() stateModule:raiseDirtyFlag() end)
            end
            return "stateModule.speedLimit (direkt gesetzt)"
        end
    end
    -- Letzter Rueckfallweg -- ACHTUNG: das ist der Basisspiel-Tempomat, den AutoDrive beim
    -- automatischen Fahren nachweislich NICHT liest (siehe stopAndResetVehicle-Kommentar).
    -- Wird nur erreicht, wenn kein AutoDrive-stateModule vorhanden ist.
    if vehicle.setCruiseControlMaxSpeed ~= nil then
        local ok = pcall(function() vehicle:setCruiseControlMaxSpeed(kmh) end)
        if ok then return "vehicle:setCruiseControlMaxSpeed (Basisspiel-Tempomat, KEINE Wirkung waehrend AutoDrive faehrt)" end
    end
    return "keine bekannte API verfügbar"
end

-- Mehrere Kandidaten-APIs zum Anhalten einer laufenden AutoDrive-Fahrt - bestätigt hat sich
-- zuletzt stateModule:setActive(false) als wirksam gezeigt.
-- YesNoDialog.show ruft den Callback in dieser Version offenbar nicht mit einem reinen
-- Boolean auf, sondern mindestens ein Parameter ist eine Tabelle (Ziel-/Dialog-Objekt) -
-- eine Tabelle ist in Lua immer "wahr", das führte dazu, dass jede Dialog-Antwort als "Ja"
-- ausgewertet wurde, unabhängig vom tatsächlichen Klick. Diese Funktion sucht in allen
-- übergebenen Werten nach dem ersten echten Boolean und nutzt nur den; wird keiner
-- gefunden, ist der sichere Standardwert "false" (nicht einfach "Ja" annehmen).
local function extractYesNo(...)
    for _, v in ipairs({ ... }) do
        if type(v) == "boolean" then
            return v
        end
    end
    return false
end

-- Startet den Motor explizit per Skript, statt uns auf die (evtl. spielerabhängige)
-- automatische Motorstart-Einstellung zu verlassen. Verdacht: Ohne Fahrer im Fahrzeug
-- startet der Motor manchmal nicht automatisch, wodurch sich das Fahrzeug trotz korrekt
-- gesetztem AutoDrive-Ziel nicht bewegt (siehe AutoDrive-Änderungsprotokoll: "AD drivers
-- now ignore the FS automatic engine start setting").
-- 2026-07-31: AutoDrive.requestToEnterVehicle existiert laut Log NICHT zur Laufzeit, obwohl die
-- Funktion im Quellcode der installierten FS25_AutoDrive.zip vorhanden UND in deren register.lua
-- unbedingt (kein Feature-Flag) eingebunden ist -- Ursache ungeklaert, kein passender Lua-Fehler
-- im Log auffindbar. AutoDrive.requestToEnterVehicle ist ohnehin nur ein duenner Wrapper um
-- Basisspiel-API (g_currentMission.playerSystem:getLocalPlayer():requestToEnterVehicle(vehicle),
-- siehe AutoDriveUtilFuncs.lua). Daher direkt die Basisspiel-API nutzen statt von AutoDrive
-- abhaengig zu sein -- funktioniert unabhaengig davon, ob/warum AutoDrive diesen einen Wrapper
-- gerade nicht bereitstellt.
-- 2026-08-01: eigenes, mitgeliefertes Signalton-Sample (sounds/notification.ogg, vom Nutzer als
-- frei nutzbare Datei bereitgestellt) - laedt sich
-- selbst lazy beim ersten Gebrauch, unabhaengig von AutoDrives (nachweislich immer nil)
-- notificationSample/notificationWarningSample. ok/err wird gecacht, damit nicht bei jedem
-- Aufruf erneut pcall+createSample+loadSample laeuft.
local ownNotificationSample = nil
local ownNotificationSampleLoadAttempted = false
local ownNotificationSampleLoadError = nil

local function getOwnNotificationSample()
    if ownNotificationSampleLoadAttempted then
        return ownNotificationSample, ownNotificationSampleLoadError
    end
    ownNotificationSampleLoadAttempted = true
    if createSample == nil or loadSample == nil or MOD_DIRECTORY == nil or Utils == nil or Utils.getFilename == nil then
        ownNotificationSampleLoadError = "createSample/loadSample/MOD_DIRECTORY/Utils.getFilename nicht verfügbar"
        return nil, ownNotificationSampleLoadError
    end
    local ok, result = pcall(function()
        local fileName = Utils.getFilename("sounds/notification.ogg", MOD_DIRECTORY)
        local sample = createSample("Winterdienst_Notification")
        loadSample(sample, fileName, false)
        return sample
    end)
    if ok then
        ownNotificationSample = result
    else
        ownNotificationSampleLoadError = tostring(result)
    end
    return ownNotificationSample, ownNotificationSampleLoadError
end

local function tryEnterVehicle(vehicle)
    if vehicle == nil then
        return false, "kein Fahrzeug"
    end
    if g_currentMission == nil or g_currentMission.playerSystem == nil
        or g_currentMission.playerSystem.getLocalPlayer == nil then
        return false, "g_currentMission.playerSystem nicht verfügbar"
    end
    local ok, player = pcall(function() return g_currentMission.playerSystem:getLocalPlayer() end)
    if not ok or player == nil then
        return false, "kein lokaler Spieler gefunden"
    end
    if player.requestToEnterVehicle == nil then
        return false, "player:requestToEnterVehicle nicht vorhanden"
    end
    local callOk, err = pcall(function() player:requestToEnterVehicle(vehicle) end)
    if not callOk then
        return false, tostring(err)
    end
    return true, "g_currentMission.playerSystem:getLocalPlayer():requestToEnterVehicle()"
end

local function tryStartMotor(vehicle)
    if vehicle == nil then
        return "kein Fahrzeug"
    end
    if vehicle.startMotor ~= nil then
        local ok = pcall(function() vehicle:startMotor() end)
        if ok then return "vehicle:startMotor()" end
    end
    if vehicle.spec_motorized ~= nil and vehicle.setMotorStarted ~= nil then
        local ok = pcall(function() vehicle:setMotorStarted(true, true, true) end)
        if ok then return "vehicle:setMotorStarted(true)" end
    end
    return "keine bekannte Motorstart-API verfügbar"
end

-- 2026-08-01: Nutzer-Wunsch - Motor beim endgueltigen Parken an WD Missionsende abstellen
-- (Diesel sparen), statt ihn einfach laufen zu lassen.
local function tryStopMotor(vehicle)
    if vehicle == nil then
        return "kein Fahrzeug"
    end
    if vehicle.stopMotor ~= nil then
        local ok = pcall(function() vehicle:stopMotor() end)
        if ok then return "vehicle:stopMotor()" end
    end
    if vehicle.spec_motorized ~= nil and vehicle.setMotorStarted ~= nil then
        local ok = pcall(function() vehicle:setMotorStarted(false, true, true) end)
        if ok then return "vehicle:setMotorStarted(false)" end
    end
    return "keine bekannte Motorstopp-API verfügbar"
end

local function stopAndResetVehicle(vehicle)
    if vehicle == nil then
        return "kein Fahrzeug"
    end
    setImplementsTurnedOn(vehicle, false)

    -- Tempomat explizit ausschalten (nicht nur AutoDrive stoppen) - Verdacht: der Traktor
    -- fuhr trotz "AutoDrive inaktiv" unvermindert weiter, vermutlich weil der über
    -- setCruiseControlMaxSpeed gesetzte Basisspiel-Tempomat unabhängig von AutoDrives
    -- eigenem Zustand weiterläuft, bis er explizit abgeschaltet wird.
    if vehicle.setCruiseControlState ~= nil and Drivable ~= nil and Drivable.CRUISECONTROL_STATE_OFF ~= nil then
        pcall(function() vehicle:setCruiseControlState(Drivable.CRUISECONTROL_STATE_OFF) end)
    end
    pcall(function() trySetSpeedLimit(vehicle, 0) end)

    if vehicle.ad == nil or vehicle.ad.stateModule == nil then
        return "kein AutoDrive"
    end

    local stateModule = vehicle.ad.stateModule
    local result = "keine bekannte Stopp-API verfügbar"

    local currentMode = stateModule:getCurrentMode()
    if currentMode ~= nil and currentMode.stop ~= nil then
        local ok = pcall(function() currentMode:stop() end)
        if ok then result = "currentMode:stop()" end
    end
    if stateModule.stopAD ~= nil then
        local ok = pcall(function() stateModule:stopAD() end)
        if ok then result = "stateModule:stopAD()" end
    end
    if stateModule.stop ~= nil then
        local ok = pcall(function() stateModule:stop() end)
        if ok then result = "stateModule:stop()" end
    end
    if stateModule.setActive ~= nil then
        local ok = pcall(function() stateModule:setActive(false) end)
        if ok then result = "stateModule:setActive(false)" end
    end

    stateModule:setMode(getModeDriveTo())
    return result
end

-- Schnee-Erkennung (unverändert bewährt).
local debugForceSnow = false

-- Eigene, niedrige Schwelle statt der Engine-eigenen SnowSystem.MIN_LAYER_HEIGHT (unbekannter
-- Wert, hat sich in der Praxis als zu streng erwiesen - 0.0235 physicalHeight wurde trotz
-- sichtbar liegendem Schnee als "kein Schnee" gewertet).
local SNOW_HEIGHT_THRESHOLD = 0.01

local function isSnowLying()
    if debugForceSnow then
        return true
    end
    if g_currentMission == nil or g_currentMission.snowSystem == nil then
        return false
    end
    return g_currentMission.snowSystem.height ~= nil and g_currentMission.snowSystem.height >= SNOW_HEIGHT_THRESHOLD
end

function WinterdienstMission:consoleForceSnow(value)
    if value == nil or value == "" then
        debugForceSnow = not debugForceSnow
    else
        debugForceSnow = (value == "1" or value == "true")
    end
    print("[Winterdienst] debugForceSnow = " .. tostring(debugForceSnow))
    return "debugForceSnow = " .. tostring(debugForceSnow)
end

-- Zuverlässiger Ersatzweg zur Tastenbelegung (die wiederholt und ohne erkennbaren Grund
-- keine Reaktion zeigte, obwohl "Aktion registriert" korrekt geloggt wurde). Löst exakt
-- dieselbe Prüfung aus wie ein Tastendruck - wie die Taste jetzt fahrzeugunabhängig nutzbar.
function WinterdienstMission:consoleTriggerAccept()
    print("[Winterdienst] Auftragsprüfung über Konsolenbefehl ausgelöst")
    self:onOpenDialogInput(nil, nil, nil, false)
    return "Auftragsprüfung ausgelöst"
end

-- Diagnose fuer die Schneefraese (Basisspiel-"Tornado 252", Typ turnOnShovel): GIANTS liefert
-- die Shovel/TurnOnVehicle-Spezialisierung nur kompiliert aus, deshalb kann hier NICHT einfach
-- die richtige Senk-Funktion nachgelesen werden. Statt eine falsche API zu raten (die dann wie
-- setLoweredAll() still gar nichts tut), fragt dieser Befehl das angehaengte Objekt zur Laufzeit
-- direkt, welche Methoden es tatsaechlich hat, und schreibt das ins Log.
function WinterdienstMission:consoleInspectImplements()
    local vehicle = findVehicleByName(VEHICLE_NAME)
    if vehicle == nil or vehicle.getAttachedImplements == nil then
        print("[Winterdienst] Inspektion: Fahrzeug oder Anbaugeraete nicht gefunden")
        return "Fahrzeug nicht gefunden"
    end

    local function scanMethods(t, label, checked)
        if t == nil then
            return
        end
        for k, v in pairs(t) do
            if type(k) == "string" and type(v) == "function" and not checked[k] then
                local lk = k:lower()
                if lk:find("shovel") or lk:find("lower") or lk:find("raise") or lk:find("dig")
                    or lk:find("fold") or lk:find("turnedon") or lk:find("dump")
                    or lk:find("leveler") or lk:find("height") or lk:find("offset") then
                    checked[k] = true
                    print(string.format("[Winterdienst]   moegliche Methode (%s): %s", label, k))
                end
            end
        end
    end

    for _, implement in pairs(vehicle:getAttachedImplements()) do
        local object = implement.object
        if object ~= nil then
            print("[Winterdienst] === Anbaugeraet: " .. tostring(object.configFileName) .. " ===")
            for k, v in pairs(object) do
                if type(k) == "string" and k:find("^spec_") and type(v) == "table" then
                    print("[Winterdienst]   hat Spezialisierung: " .. k)
                end
            end
            local checked = {}
            scanMethods(object, "object", checked)
            local mt = getmetatable(object)
            if mt ~= nil and type(mt.__index) == "table" then
                scanMethods(mt.__index, "class", checked)
            end
        end
    end
    return "Inspektion abgeschlossen - siehe Log"
end

-- 2026-07-31: Nutzer-Test beweist eindeutig - manuelles Ein/Ausschalten (Taste B) und
-- Heben/Senken (Taste V) funktionieren am angehaengten Geraet EINWANDFREI, waehrend KEINE der
-- 6 Skript-Methoden (setIsTurnedOn, setLoweredAll, setLowered, handleLowerImplementEvent,
-- handleLowerImplementByAttacherJointIndex, setFoldState) je eine Wirkung zeigte. Das schliesst
-- "Geraet/Anbaustelle kann das grundsaetzlich nicht" aus - es muss also einen Unterschied
-- zwischen Tastendruck und unseren Methodenaufrufen geben. Vermutung: die Taste loest ein bei
-- g_inputBinding REGISTRIERTES Action-Event mit eigener Callback-Funktion aus, nicht einen der
-- generischen Setter, die wir bisher probiert haben. Dieser Befehl sucht nach "actionEvents"-
-- Tabellen (Standard-Giants-Muster: spec.actionEvents[InputAction] = eventId) am Geraet, all
-- seinen spec_*-Untertabellen UND am Fahrzeug selbst (falls die Taste eigentlich am Fahrzeug
-- registriert ist, nicht am Geraet) - rein lesend, keine Aenderung, nur Log-Ausgabe.
function WinterdienstMission:consoleInspectActions()
    local vehicle = findVehicleByName(VEHICLE_NAME)
    if vehicle == nil or vehicle.getAttachedImplements == nil then
        print("[Winterdienst] wdInspectActions: Fahrzeug nicht gefunden")
        return "Fahrzeug nicht gefunden"
    end

    local function dumpActionEvents(actionEvents, label)
        print(string.format("[Winterdienst]   actionEvents-Tabelle gefunden (%s):", label))
        for key, value in pairs(actionEvents) do
            if type(value) == "table" then
                local parts = {}
                for vk, vv in pairs(value) do
                    if type(vv) ~= "function" and type(vv) ~= "table" then
                        table.insert(parts, tostring(vk) .. "=" .. tostring(vv))
                    end
                end
                print(string.format("[Winterdienst]     [%s] -> {%s}", tostring(key), table.concat(parts, ", ")))
            else
                print(string.format("[Winterdienst]     [%s] -> %s", tostring(key), tostring(value)))
            end
        end
    end

    local function scanForActionEvents(obj, label)
        if obj == nil then
            return
        end
        if type(obj.actionEvents) == "table" then
            dumpActionEvents(obj.actionEvents, label .. ".actionEvents")
        end
        for k, v in pairs(obj) do
            if type(k) == "string" and k:find("^spec_") and type(v) == "table" and type(v.actionEvents) == "table" then
                dumpActionEvents(v.actionEvents, label .. "." .. k .. ".actionEvents")
            end
        end
    end

    for _, implement in pairs(vehicle:getAttachedImplements()) do
        local object = implement.object
        if object ~= nil then
            print("[Winterdienst] === Anbaugeraet: " .. tostring(object.configFileName) .. " ===")
            scanForActionEvents(object, "object")
        end
    end
    print("[Winterdienst] === Fahrzeug: " .. tostring(vehicle.configFileName) .. " ===")
    scanForActionEvents(vehicle, "vehicle")

    return "Inspektion abgeschlossen - siehe Log"
end

-- 2026-08-02: Nutzer-Beobachtung - der U400 kommt ohne Frontschild ueberall gut rum, bleibt mit
-- Schild aber oefter an Hindernissen haengen. Verdacht: AutoDrive berechnet die Fahrzeuglaenge
-- fuer Kurven-/Hindernisplanung (AutoDrive.getTractorTrainLength, siehe TrailerUtil.lua, genutzt
-- u.a. in PathFinderModule.lua) nur ueber ladungsfaehige Anhaenger/Geraete - ob das Frontschild
-- (hat spec_fillUnit, aber ist kein "typeDesc_frontloaderTool") da mitgezaehlt wird, laesst sich
-- aus dem AutoDrive-Quellcode allein nicht sicher sagen. Dieser Befehl liest den tatsaechlichen
-- Wert direkt aus dem laufenden Spiel aus, statt weiter zu raten. Rein lesend, keine Aenderung.
function WinterdienstMission:consoleInspectLength()
    local vehicle = findVehicleByName(VEHICLE_NAME)
    if vehicle == nil then
        print("[Winterdienst] wdInspectLength: Fahrzeug nicht gefunden")
        return "Fahrzeug nicht gefunden"
    end
    print(string.format("[Winterdienst] wdInspectLength: eigene Fahrzeuggroesse (U400) laut Basisspiel-API: %s",
        tostring(vehicle.size and string.format("width=%.2f length=%.2f", vehicle.size.width or -1, vehicle.size.length or -1) or "unbekannt")))
    if AutoDrive ~= nil and AutoDrive.getTractorTrainLength ~= nil then
        local ok, result = pcall(function() return AutoDrive.getTractorTrainLength(vehicle, true, false) end)
        print(string.format("[Winterdienst] wdInspectLength: AutoDrive.getTractorTrainLength(inkl. Fahrzeug): ok=%s, Ergebnis=%s",
            tostring(ok), ok and tostring(result) or tostring(result)))
    else
        print("[Winterdienst] wdInspectLength: AutoDrive.getTractorTrainLength nicht verfügbar")
    end
    if AutoDrive ~= nil and AutoDrive.getAllUnits ~= nil then
        local ok, units = pcall(function() return AutoDrive.getAllUnits(vehicle) end)
        if ok and units ~= nil then
            print(string.format("[Winterdienst] wdInspectLength: AutoDrive.getAllUnits fand %d Einheit(en):", #units))
            for i, unit in pairs(units) do
                local len = unit.size and unit.size.length or nil
                print(string.format("[Winterdienst]   [%d] %s - Laenge=%s", i, tostring(unit.configFileName), tostring(len)))
            end
        else
            print(string.format("[Winterdienst] wdInspectLength: AutoDrive.getAllUnits fehlgeschlagen: %s", tostring(units)))
        end
    end
    -- Zum Vergleich: alle angehaengten Geraete UNABHAENGIG von AutoDrive auflisten, samt eigener
    -- deklarierter Groesse und typeDesc (fuer die Ausschlussregel "frontloaderTool"/"wheelLoaderTool"
    -- relevant, die AutoDrive.getTrailersOfImplement() nutzt).
    if vehicle.getAttachedImplements ~= nil then
        for _, implement in pairs(vehicle:getAttachedImplements()) do
            local object = implement.object
            if object ~= nil then
                local len = object.size and object.size.length or nil
                print(string.format("[Winterdienst] wdInspectLength: Anbaugeraet %s - Laenge=%s, typeDesc=%s, hat getFillUnits=%s",
                    tostring(object.configFileName), tostring(len), tostring(object.typeDesc), tostring(object.getFillUnits ~= nil)))
            end
        end
    end
    return "Inspektion abgeschlossen - siehe Log"
end

-- 2026-08-02: Nutzer-Wunsch fuer den Giants-Editor-Umbau (Schild fest an den U400 modellieren,
-- statt es als Anbaugeraet zu senken) - liest die Welt-Position/-Rotation des aktuell
-- angehaengten Schilds UND des U400-Fahrzeugs selbst aus, waehrend beide im Spiel stehen. Damit
-- laesst sich im Editor die relative Lage (Versatz von U400-Ursprung zu Schild) nachvollziehen -
-- am besten aufrufen, waehrend das Schild manuell (Taste V) abgesenkt ist, damit die Werte der
-- gewuenschten Endposition entsprechen. Rein lesend, keine Aenderung.
function WinterdienstMission:consoleInspectBladeTransform()
    local vehicle = findVehicleByName(VEHICLE_NAME)
    if vehicle == nil then
        print("[Winterdienst] wdInspectBladeTransform: Fahrzeug nicht gefunden")
        return "Fahrzeug nicht gefunden"
    end
    if vehicle.rootNode == nil then
        print("[Winterdienst] wdInspectBladeTransform: Fahrzeug hat keinen rootNode")
        return "kein rootNode"
    end
    local vx, vy, vz = getWorldTranslation(vehicle.rootNode)
    local vrx, vry, vrz = getWorldRotation(vehicle.rootNode)
    print(string.format("[Winterdienst] wdInspectBladeTransform: U400 rootNode Welt-Position: x=%.3f y=%.3f z=%.3f", vx, vy, vz))
    print(string.format("[Winterdienst] wdInspectBladeTransform: U400 rootNode Welt-Rotation (Grad): x=%.2f y=%.2f z=%.2f", math.deg(vrx), math.deg(vry), math.deg(vrz)))

    if vehicle.getAttachedImplements == nil then
        return "Inspektion abgeschlossen - siehe Log"
    end
    for _, implement in pairs(vehicle:getAttachedImplements()) do
        local object = implement.object
        if object ~= nil and object.rootNode ~= nil then
            local ok, lowered = true, "?"
            if object.getIsLowered ~= nil then
                ok, lowered = pcall(function() return object:getIsLowered() end)
                lowered = ok and tostring(lowered) or "Fehler"
            end
            local ix, iy, iz = getWorldTranslation(object.rootNode)
            local irx, iry, irz = getWorldRotation(object.rootNode)
            print(string.format("[Winterdienst] wdInspectBladeTransform: Anbaugeraet %s (Senkzustand=%s)", tostring(object.configFileName), lowered))
            print(string.format("[Winterdienst]   Welt-Position: x=%.3f y=%.3f z=%.3f (Versatz zum U400: dx=%.3f dy=%.3f dz=%.3f)",
                ix, iy, iz, ix - vx, iy - vy, iz - vz))
            print(string.format("[Winterdienst]   Welt-Rotation (Grad): x=%.2f y=%.2f z=%.2f", math.deg(irx), math.deg(iry), math.deg(irz)))
            local len = object.size and object.size.length or nil
            local wid = object.size and object.size.width or nil
            local hei = object.size and object.size.height or nil
            print(string.format("[Winterdienst]   Eigene Groesse (aus XML): Breite=%s Laenge=%s Hoehe=%s", tostring(wid), tostring(len), tostring(hei)))
        end
    end
    return "Inspektion abgeschlossen - siehe Log"
end

-- setLoweredAll() zeigt bei der Fraese laut Test KEINE Wirkung (getIsLowered bleibt konstant
-- "false", auch bei laufender Neudurchsetzung). Statt weiter zu raten, probiert dieser Befehl
-- mehrere Kandidaten-Methoden NACHEINANDER direkt an der Fraese und loggt vorher/nachher --
-- ein einziger Aufruf zeigt, ob irgendeine davon tatsaechlich etwas bewirkt.
function WinterdienstMission:consoleTryLowerPlow()
    local vehicle = findVehicleByName(VEHICLE_NAME)
    if vehicle == nil or vehicle.getAttachedImplements == nil then
        print("[Winterdienst] wdTryLower: Fahrzeug nicht gefunden")
        return "Fahrzeug nicht gefunden"
    end

    -- Nach FAEHIGKEIT statt Namen suchen (getAllowsLowering/getIsLowered) -- so funktioniert
    -- der Befehl unveraendert, egal welches Anbaugeraet gerade vorne haengt (Tornado 252,
    -- KFS 1050, STS-300, ...), ohne den Namen im Skript nachpflegen zu muessen.
    -- BUG gefunden 2026-07-31: der Streuer hat laut FRICTION-LOG (siehe getVehicleFillInfo
    -- oben) diese Methoden EBENFALLS (ungenutzt) - die alte Version hier ueberschrieb "target"
    -- bei JEDEM Treffer statt beim ersten zu stoppen, landete also je nach pairs()-Reihenfolge
    -- zufaellig beim Streuer statt beim Schild. Alle vier `wdTryLower`-Laeufe im Test vom
    -- 2026-07-31 haben dadurch nachweislich den Streuer (Agrys150.xml) getestet, nie das
    -- eigentlich fragliche Frontgeraet (VP3203P_pro.xml) - die Schild-Frage war also bisher
    -- nie wirklich getestet. Fix: Streuer per SPREADER_NAME_HINTS explizit ausschliessen.
    local target = nil
    for _, implement in pairs(vehicle:getAttachedImplements()) do
        local object = implement.object
        local isSpreader = false
        if object ~= nil and object.configFileName ~= nil then
            local lowerName = tostring(object.configFileName):lower()
            for _, hint in ipairs(SPREADER_NAME_HINTS) do
                if lowerName:find(hint) ~= nil then
                    isSpreader = true
                    break
                end
            end
        end
        if object ~= nil and not isSpreader and (object.getAllowsLowering ~= nil or object.getIsLowered ~= nil) then
            target = object
        end
    end
    if target == nil then
        print("[Winterdienst] wdTryLower: kein Anbaugeraet mit Senk-Faehigkeit gefunden")
        return "kein passendes Anbaugeraet gefunden"
    end
    print("[Winterdienst] wdTryLower: Ziel = " .. tostring(target.configFileName))

    -- 2026-07-31: Nutzer-Beobachtung beim Streuer-vorne/Fraese-hinten-Umbau - die Fraese ging
    -- laut Log-Zaehler "1" zwar an (irgendwas wurde versucht), lief aber sichtbar nicht an.
    -- Gleiche Verdachtsklasse wie beim Senken (Aufruf ok, aber wirkungslos) - deshalb jetzt
    -- auch getIsTurnedOn/setIsTurnedOn mit vorher/nachher ins Protokoll aufnehmen.
    local function report(label)
        local allows, lowered, turnedOn = "?", "?", "?"
        if target.getAllowsLowering ~= nil then
            local ok, v = pcall(function() return target:getAllowsLowering() end)
            if ok then allows = tostring(v) end
        end
        if target.getIsLowered ~= nil then
            local ok, v = pcall(function() return target:getIsLowered() end)
            if ok then lowered = tostring(v) end
        end
        if target.getIsTurnedOn ~= nil then
            local ok, v = pcall(function() return target:getIsTurnedOn() end)
            if ok then turnedOn = tostring(v) end
        end
        print(string.format("[Winterdienst] wdTryLower [%s]: getAllowsLowering=%s getIsLowered=%s getIsTurnedOn=%s", label, allows, lowered, turnedOn))
    end

    report("vorher")

    if target.setIsTurnedOn ~= nil then
        local ok = pcall(function() target:setIsTurnedOn(true) end)
        print("[Winterdienst] wdTryLower: setIsTurnedOn(true) aufgerufen, ok=" .. tostring(ok))
        report("nach setIsTurnedOn")
    else
        print("[Winterdienst] wdTryLower: setIsTurnedOn nicht vorhanden")
    end

    if target.setLoweredAll ~= nil then
        local ok = pcall(function() target:setLoweredAll(true, false) end)
        print("[Winterdienst] wdTryLower: setLoweredAll(true) aufgerufen, ok=" .. tostring(ok))
        report("nach setLoweredAll")
    else
        print("[Winterdienst] wdTryLower: setLoweredAll nicht vorhanden")
    end

    if target.setLowered ~= nil then
        local ok = pcall(function() target:setLowered(true, false) end)
        print("[Winterdienst] wdTryLower: setLowered(true) aufgerufen, ok=" .. tostring(ok))
        report("nach setLowered")
    else
        print("[Winterdienst] wdTryLower: setLowered nicht vorhanden")
    end

    if target.handleLowerImplementEvent ~= nil then
        local ok = pcall(function() target:handleLowerImplementEvent() end)
        print("[Winterdienst] wdTryLower: handleLowerImplementEvent() aufgerufen, ok=" .. tostring(ok))
        report("nach handleLowerImplementEvent")
    else
        print("[Winterdienst] wdTryLower: handleLowerImplementEvent nicht vorhanden")
    end

    -- 2026-07-31: die drei obigen Methoden sind jetzt NACHWEISLICH am richtigen Geraet
    -- (VP3203P_pro, dem Schild) wirkungslos geblieben (getIsLowered bleibt false, obwohl
    -- alle drei Aufrufe ok=true melden) - das ist also kein Diagnose-Fehler mehr, sondern ein
    -- echter Befund. wdInspect zeigte zusaetzlich handleLowerImplementByAttacherJointIndex und
    -- setFoldState als moegliche Kandidaten (spec_attacherJointControl/spec_foldable) -
    -- Parameter geraten, da GIANTS' Kern-Spezialisierungen nicht im Modquellcode einsehbar
    -- sind. Rein diagnostisch (pcall-abgesichert), kein Risiko.
    if target.handleLowerImplementByAttacherJointIndex ~= nil then
        local ok = pcall(function() target:handleLowerImplementByAttacherJointIndex(1, true) end)
        print("[Winterdienst] wdTryLower: handleLowerImplementByAttacherJointIndex(1, true) aufgerufen, ok=" .. tostring(ok))
        report("nach handleLowerImplementByAttacherJointIndex")
    else
        print("[Winterdienst] wdTryLower: handleLowerImplementByAttacherJointIndex nicht vorhanden")
    end

    if target.setFoldState ~= nil then
        local ok = pcall(function() target:setFoldState(-1, false) end)
        print("[Winterdienst] wdTryLower: setFoldState(-1, false) aufgerufen, ok=" .. tostring(ok))
        report("nach setFoldState")
    else
        print("[Winterdienst] wdTryLower: setFoldState nicht vorhanden")
    end

    return "wdTryLower abgeschlossen - siehe Log"
end

-- ===================== KLASSE =====================

function WinterdienstMission.new()
    local self = setmetatable({}, WinterdienstMission_mt)
    self.state = STATE_IDLE
    self.timeSinceCheck = 0
    self.pendingStartTimer = 0
    self.pendingRefuelTimer = 0
    self.pendingDepartureTimer = 0
    self.autoDepartAfterStop = false
    self.vehicle = nil
    self.missionActive = false
    self.actionEventId = nil
    self.lastCheckX = nil
    self.lastCheckZ = nil
    self.stoppedTicks = 0
    self.routeStartGraceTicks = 0
    self.stopDialogOpen = false
    self.cancelDialogPendingTimer = nil
    self.pendingActivationX = nil
    self.pendingActivationZ = nil
    self.stopVerifyAttempts = 0
    self.stopVerifyLastX = nil
    self.stopVerifyLastZ = nil
    self.stopVerifyStationaryTicks = 0
    self.totalDistanceDriven = 0
    self.timeSinceSnowCheck = 0
    self.timeSinceIdleSnowCheck = 0
    self.missionCooldownRemaining = 0
    self.timeSinceCooldownPrint = 0
    self.stuckSeconds = 0
    self.idleSnowNotified = false
    self.targetName = nil
    self.targetX = nil
    self.targetZ = nil
    return self
end

function WinterdienstMission:update(dt)
    self:updateActionEvent()

    if self.state == STATE_IDLE then
        local wasOnCooldown = self.missionCooldownRemaining > 0
        self.missionCooldownRemaining = math.max(0, self.missionCooldownRemaining - dt)
        if self.missionCooldownRemaining > 0 then
            self.timeSinceCooldownPrint = (self.timeSinceCooldownPrint or 0) + dt
            if self.timeSinceCooldownPrint >= CHECK_INTERVAL then
                self.timeSinceCooldownPrint = 0
                debugLog("Neuer Auftrag noch gesperrt - " .. math.ceil(self.missionCooldownRemaining / 1000) .. " Sekunden verbleiben")
            end
        elseif wasOnCooldown then
            debugLog("Sperrzeit abgelaufen - neuer Auftrag wieder möglich")
            self:showCenteredMessage(EMPLOYER_NAME, "Winterdienst wieder einsatzbereit - neuer Auftrag möglich.")
        end
        self.timeSinceIdleSnowCheck = self.timeSinceIdleSnowCheck + dt
        if self.timeSinceIdleSnowCheck >= IDLE_SNOW_CHECK_INTERVAL_MS then
            self.timeSinceIdleSnowCheck = 0
            if isSnowLying() then
                if not self.idleSnowNotified then
                    self.idleSnowNotified = true
                    debugLog("Ruhezustand: Schnee erkannt - Auftrag verfügbar")
                    self:showCenteredMessage(EMPLOYER_NAME, "Winterdienstauftrag verfügbar")
                end
            else
                self.idleSnowNotified = false
            end
        end
        return
    end

    if self.state == STATE_PENDING_START then
        if g_currentMission == nil or not g_currentMission:getIsServer() then
            return
        end
        self.pendingStartTimer = self.pendingStartTimer - dt
        if self.pendingStartTimer <= 0 then
            self:startAfterPendingWait()
        end
        return
    end

    if self.state == STATE_PENDING_REFUEL then
        if g_currentMission == nil or not g_currentMission:getIsServer() then
            return
        end
        self.pendingRefuelTimer = self.pendingRefuelTimer - dt
        if self.pendingRefuelTimer <= 0 then
            self:startRefuel()
        end
        return
    end

    if self.state == STATE_PENDING_DEPARTURE then
        if g_currentMission == nil or not g_currentMission:getIsServer() then
            return
        end
        self.pendingDepartureTimer = self.pendingDepartureTimer - dt
        if self.pendingDepartureTimer <= 0 then
            self:startDriveToMissionEnd()
        end
        return
    end

    self.timeSinceCheck = self.timeSinceCheck + dt
    if self.timeSinceCheck < CHECK_INTERVAL then
        return
    end
    self.timeSinceCheck = 0

    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return
    end

    if self.state == STATE_DRIVING_TO_WORKSTART then
        self:checkArrivalAtWorkStart()
    elseif self.state == STATE_DRIVING_ROUTE then
        self:checkArrival()
    elseif self.state == STATE_DRIVING_TO_REFUEL then
        self:checkArrivalAtRefuel()
    elseif self.state == STATE_REFUELING then
        self:checkRefuelComplete()
    elseif self.state == STATE_DRIVING_TO_MISSION_END then
        self:checkArrivalAtMissionEnd()
    elseif self.state == STATE_VERIFYING_STOP then
        self:checkStopVerified()
    end
end

-- Registriert die Taste einmalig, sobald der Spieler existiert - bewusst NICHT mehr an
-- Fahrzeug-Insassenschaft gebunden (Nutzer-Wunsch: Aufträge auch von überall auf der Karte
-- auslösen können, nicht nur während man im Winterdienst-Fahrzeug sitzt).
function WinterdienstMission:updateActionEvent()
    if g_localPlayer == nil then
        return
    end
    if self.actionEventId == nil and not self.actionEventAttempted then
        self.actionEventAttempted = true
        local ok, eventId = g_inputBinding:registerActionEvent(
            "WINTERDIENST_ACCEPT_DIALOG", self, WinterdienstMission.onOpenDialogInput,
            false, true, false, true
        )
        if ok then
            self.actionEventId = eventId
            g_inputBinding:setActionEventTextVisibility(eventId, true)
            g_inputBinding:setActionEventText(eventId, "Winterdienst-Auftrag")
            debugLog("Aktion registriert (fahrzeugunabhängig)")
        else
            debugLog("FEHLER: registerActionEvent fehlgeschlagen")
        end
    end
end

function WinterdienstMission:onOpenDialogInput(actionName, inputValue, callbackState, isAnalog)
    debugLog("Taste gedrückt (onOpenDialogInput ausgelöst)")
    -- Nutzer-Entscheidung 2026-07-31: der Abbruch soll NUR noch automatisch bei Standzeit-
    -- Ueberschreitung erfolgen (siehe checkArrival()), nicht mehr manuell per Taste waehrend
    -- eines laufenden Auftrags erzwingbar sein - diese Taste zeigt hier deshalb nur noch einen
    -- Hinweis statt des Abbruch-Dialogs.
    if self.state ~= STATE_IDLE then
        self:showNotification(EMPLOYER_NAME, "Sie führen schon einen Stadtauftrag durch.")
        return
    end
    if self.missionCooldownRemaining > 0 then
        local secondsLeft = math.ceil(self.missionCooldownRemaining / 1000)
        debugLog("Neuer Auftrag noch gesperrt - " .. secondsLeft .. "s verbleibend")
        self:showCenteredMessage("Winterdienst-Auftrag", "Neuer Winterdienstauftrag erst in " .. secondsLeft .. " Sekunden möglich.")
        return
    end
    if not isSnowLying() then
        local height = "unbekannt"
        if g_currentMission ~= nil and g_currentMission.snowSystem ~= nil then
            height = tostring(g_currentMission.snowSystem.height)
        end
        debugLog("Kein Schnee - Auftrag aktuell nicht verfügbar (Schneehöhe: " .. height .. ")")
        self:showNotification(EMPLOYER_NAME, "Kein Winterdienst nötig - es liegt kein Schnee.")
        return
    end
    self:showAcceptDialog()
end

function WinterdienstMission:showAcceptDialog()
    local text = string.format(
        "Auftraggeber: %s\nAuftrag: Winterdienst - Straßen streuen\n\n" ..
        "Bezahlung: %.2f € je gefahrenem Kilometer (Ziel wird erst nach Annahme festgelegt).\n\n" ..
        "Auftrag annehmen?",
        EMPLOYER_NAME, PAYOUT_PER_KM
    )
    YesNoDialog.show(function(a, b)
        local accepted = extractYesNo(a, b)
        debugLog("Annahme-Dialog-Antwort: " .. tostring(accepted))
        self:onAcceptDialogClosed(accepted)
    end, self, text, "Winterdienst-Auftrag")
end

function WinterdienstMission:onAcceptDialogClosed(accepted)
    if not accepted then
        debugLog("Auftrag abgelehnt")
        return
    end

    local vehicle = findVehicleByName(VEHICLE_NAME)
    if vehicle == nil then
        self:showNotification("Fehler", "Winterdienst-Traktor nicht gefunden!")
        return
    end
    if vehicle.ad == nil or vehicle.ad.stateModule == nil then
        self:showNotification("Fehler", "Fahrzeug ist nicht AutoDrive-fähig!")
        return
    end
    if vehicle.ad.stateModule:isActive() then
        self:showNotification("Info", "Fahrzeug fährt bereits eine Route!")
        return
    end

    local destination = WORK_DESTINATIONS[math.random(#WORK_DESTINATIONS)]
    self.targetName = destination.name
    self.targetX = destination.x
    self.targetZ = destination.z

    debugLog("Auftrag angenommen - Ziel: " .. self.targetName)
    self.vehicle = vehicle
    self.missionActive = true
    self.totalDistanceDriven = 0
    self.timeSinceSnowCheck = 0
    self.idleSnowNotified = false
    self:startPendingDeparture()
end

function WinterdienstMission:startPendingDeparture()
    debugLog(string.format("Warte %.0f Sekunden vor der Abfahrt", START_DELAY_MS / 1000))
    self.pendingStartTimer = START_DELAY_MS
    self.state = STATE_PENDING_START
end

-- Nach der Bedenkzeit: Füllstand prüfen. Ab 50% direkt über WD Start losfahren, darunter
-- erst zum Nachfüllpunkt (startRefuel() führt danach ohnehin automatisch zu WD Start weiter).
function WinterdienstMission:startAfterPendingWait()
    local fillLevel, fillCapacity = getVehicleFillInfo(self.vehicle)
    debugLog(string.format("Füllstand-Check bei Auftragsstart: %.0f / %.0f", fillLevel or -1, fillCapacity or -1))
    if fillLevel ~= nil and fillCapacity ~= nil and fillCapacity > 0
        and fillLevel < fillCapacity * MIN_FILL_RATIO_TO_START_DIRECTLY then
        debugLog(string.format("Füllstand unter %.0f%% - erst zum Nachfüllen fahren", MIN_FILL_RATIO_TO_START_DIRECTLY * 100))
        self:startRefuel()
    else
        self:startDriveToWorkStart()
    end
end

-- Erste Etappe: vom aktuellen Standort (i.d.R. das Depot) zu "WD Start" fahren.
function WinterdienstMission:startDriveToWorkStart()
    if self.vehicle == nil or self.vehicle.ad == nil then
        self:finishMissionWithError("Fahrzeug nicht mehr verfügbar")
        return
    end

    debugLog("Fahre zu: " .. WORK_START_NAME)
    local motorResult = tryStartMotor(self.vehicle)
    debugLog("Motorstart über: " .. motorResult)
    -- TRANSIT, nicht WORK: das ist die Anfahrt zum Netzeinstieg, keine Arbeitsetappe.
    local speedResult = trySetSpeedLimit(self.vehicle, TRANSIT_SPEED_KMH)
    debugLog(string.format("Tempolimit (%d km/h) über: %s", TRANSIT_SPEED_KMH, speedResult))
    self.lastCheckX, self.lastCheckZ = nil, nil
    self.stoppedTicks = 0
    self.vehicle.ad.stateModule:setMode(getModeDriveTo())
    self.vehicle.ad.stateModule:setFirstMarkerByName(WORK_START_NAME)
    local currentMode = self.vehicle.ad.stateModule:getCurrentMode()
    if currentMode ~= nil then
        currentMode:start()
        self.state = STATE_DRIVING_TO_WORKSTART
        -- Tempolimit NACH dem Routenstart erneut setzen -- setMode()/start() setzen
        -- AutoDrives eigenes Limit offenbar mitunter zurück.
        speedResult = trySetSpeedLimit(self.vehicle, TRANSIT_SPEED_KMH)
        debugLog(string.format("Tempolimit (%d km/h) nach Routenstart erneut über: %s", TRANSIT_SPEED_KMH, speedResult))
    else
        self:finishMissionWithError("Fahrmodus konnte nicht gestartet werden")
    end
end

-- Nutzer-Vorschlag: informative (nicht blockierende) Meldung auf Strecken, die bisher keine
-- eigene Stillstand-Erkennung hatten (WD Start, WD Missionsende) - damit ein Feststecken
-- nicht unbemerkt bleibt, nur weil gerade niemand hinschaut.
-- Nutzer-Vorschlag 2026-07-31: AutoDrive bekommt ein noetiges Wende-/Rangiermanoever aus dem
-- Stand mitunter selbst nicht hin und bleibt dann einfach stehen (kein Mod-Bug, Grenze von
-- AutoDrive selbst) - hier zaehlt Reaktionszeit, also beim ERSTEN Stuck-Signal (nicht bei
-- jeder Wiederholung) automatisch in JEDEM Zustand ins Fahrzeug wechseln, nicht nur an WD
-- Missionsende (siehe dortiger gleichartiger Fix). stuckAutoEntered verhindert Mehrfachversuche
-- waehrend derselben Stecken-Episode und wird zurueckgesetzt, sobald sich das Fahrzeug wieder
-- bewegt.
function WinterdienstMission:trackStuckNotification(moved)
    if moved ~= nil and moved < STOP_MOVE_THRESHOLD then
        self.stuckSeconds = (self.stuckSeconds or 0) + 1
        if self.stuckSeconds == STUCK_NOTIFY_INITIAL_S
            or (self.stuckSeconds > STUCK_NOTIFY_INITIAL_S and (self.stuckSeconds - STUCK_NOTIFY_INITIAL_S) % STUCK_NOTIFY_REPEAT_S == 0) then
            debugLog("Fahrzeug steckt seit " .. self.stuckSeconds .. " Sekunden fest")
        end
        -- Nutzer-Vorschlag 2026-07-31: der Auto-Einstieg funktioniert jetzt zuverlässig (siehe
        -- tryEnterVehicle), daher reicht eine einzelne nicht-blockierende Meldung mit
        -- Signalton statt der alten wiederholten blockierenden showCenteredMessage-Abfrage.
        if self.stuckSeconds == STUCK_NOTIFY_INITIAL_S and not self.stuckAutoEntered then
            self.stuckAutoEntered = true
            local ok, info = tryEnterVehicle(self.vehicle)
            debugLog(string.format("Automatischer Fahrzeugwechsel wegen Stillstand: ok=%s, %s", tostring(ok), info))
            self:showNotification(EMPLOYER_NAME, "Wegen einer Funktionsstörung wurden Sie in das Einsatzfahrzeug versetzt.")
        end
    else
        self.stuckSeconds = 0
        self.stuckAutoEntered = false
    end
end

function WinterdienstMission:checkArrivalAtWorkStart()
    if self.vehicle == nil or self.vehicle.ad == nil then
        self:finishMissionWithError("Fahrzeug nicht mehr verfügbar")
        return
    end
    -- Tempolimit laufend erneut durchsetzen -- AutoDrive hat sich als nicht zuverlässig
    -- darin gezeigt, ein einmal gesetztes Limit über die ganze Fahrt zu behalten.
    trySetSpeedLimit(self.vehicle, TRANSIT_SPEED_KMH)
    local vx, _, vz = getWorldTranslation(self.vehicle.rootNode)
    local dist = MathUtil.vector2Length(vx - WORK_START_X, vz - WORK_START_Z)
    debugLog(string.format("Abstand zu %s: %.0f m", WORK_START_NAME, dist))

    local moved = nil
    if self.lastCheckX ~= nil then
        moved = MathUtil.vector2Length(vx - self.lastCheckX, vz - self.lastCheckZ)
        self.totalDistanceDriven = self.totalDistanceDriven + moved
    end
    self.lastCheckX, self.lastCheckZ = vx, vz
    self:trackStuckNotification(moved)

    if dist <= ARRIVAL_RADIUS then
        self:startRoute()
    end
end

-- Zweite Etappe: von "WD Start" zum zufälligen Ziel.
-- 2026-08-01: Nutzer-Wunsch - die fruehere Zwei-Phasen-Version (erst Motor starten + Senken
-- versuchen, WAEHREND DAS FAHRZEUG STEHT, per STATE_PENDING_LOWER 4s warten, DANN erst
-- losfahren) ist obsolet: das Absenken per Skript wirkt nachweislich nie (siehe wdTryLower-
-- Historie), der Nutzer haelt das Schild jetzt dauerhaft manuell unten. Der Wartezustand
-- brachte also nur eine unnoetige 4-Sekunden-Verzoegerung bei jeder Abfahrt. Direkt losfahren
-- -- setImplementsTurnedOn() (fuer den Streuer/die Fraese, die das TATSAECHLICH brauchen) laeuft
-- weiterhin, nur ohne die separate Warte-Phase.
function WinterdienstMission:startRoute()
    if self.vehicle == nil or self.vehicle.ad == nil then
        self:finishMissionWithError("Fahrzeug nicht mehr verfügbar")
        return
    end

    local motorResult = tryStartMotor(self.vehicle)
    debugLog("Motorstart vor Abfahrt über: " .. motorResult)

    if self.pendingActivationX == nil then
        local count = setImplementsTurnedOn(self.vehicle, true)
        debugLog(string.format("Anbaugeraete eingeschaltet/gesenkt: %d", count))
    end

    debugLog("Fahre zu: " .. self.targetName)
    local speedResult = trySetSpeedLimit(self.vehicle, WORK_SPEED_KMH)
    debugLog(string.format("Tempolimit (%d km/h) über: %s", WORK_SPEED_KMH, speedResult))
    self.lastCheckX, self.lastCheckZ = nil, nil
    self.stoppedTicks = 0
    self.routeStartGraceTicks = 0
    self.vehicle.ad.stateModule:setMode(getModeDriveTo())
    self.vehicle.ad.stateModule:setFirstMarkerByName(self.targetName)
    local currentMode = self.vehicle.ad.stateModule:getCurrentMode()
    if currentMode ~= nil then
        currentMode:start()
        self.state = STATE_DRIVING_ROUTE
        -- Tempolimit NACH dem Routenstart erneut setzen -- setMode()/start() setzen
        -- AutoDrives eigenes Limit offenbar mitunter zurück.
        speedResult = trySetSpeedLimit(self.vehicle, WORK_SPEED_KMH)
        debugLog(string.format("Tempolimit (%d km/h) nach Routenstart erneut über: %s", WORK_SPEED_KMH, speedResult))
    else
        self:finishMissionWithError("Fahrmodus konnte nicht gestartet werden")
    end
end

function WinterdienstMission:checkArrival()
    if self.vehicle == nil or self.vehicle.ad == nil then
        self:finishMissionWithError("Fahrzeug nicht mehr verfügbar")
        return
    end

    -- Tempolimit laufend erneut durchsetzen -- AutoDrive hat sich als nicht zuverlässig
    -- darin gezeigt, ein einmal gesetztes Limit über die ganze Route zu behalten.
    trySetSpeedLimit(self.vehicle, WORK_SPEED_KMH)

    local vx, _, vz = getWorldTranslation(self.vehicle.rootNode)
    local dist = MathUtil.vector2Length(vx - self.targetX, vz - self.targetZ)
    -- Diagnose fuer den Fall "faehrt einfach nicht los": isActive() UND das tatsaechlich
    -- ausgelesene speedLimit mitloggen, um zu sehen, ob AutoDrive sich selbst als fahrend
    -- betrachtet und welchen Wert es wirklich fuehrt (nicht nur, was wir gesetzt haben).
    local isActive, readSpeedLimit = "?", "?"
    if self.vehicle.ad.stateModule ~= nil then
        if self.vehicle.ad.stateModule.isActive ~= nil then
            local ok, v = pcall(function() return self.vehicle.ad.stateModule:isActive() end)
            if ok then isActive = tostring(v) end
        end
        if self.vehicle.ad.stateModule.getSpeedLimit ~= nil then
            local ok, v = pcall(function() return self.vehicle.ad.stateModule:getSpeedLimit() end)
            if ok then readSpeedLimit = tostring(v) end
        end
    end
    debugLog(string.format("Abstand zu %s: %.0f m (isActive=%s, speedLimit=%s)", self.targetName, dist, isActive, readSpeedLimit))

    -- Anbaugeraete laufend erneut einschalten/senken -- derselbe Verdacht wie beim Tempolimit:
    -- der Zustand kann kurz nach Routenstart zurueckgesetzt werden (Fraese blieb laut Test
    -- manchmal doch oben, obwohl beim Start eingeschaltet wurde). Nur wenn nicht gerade wegen
    -- Nachfuellens bewusst ausgeschaltet (pendingActivationX).
    if self.pendingActivationX == nil then
        setImplementsTurnedOn(self.vehicle, true)
    end

    if dist <= ARRIVAL_RADIUS then
        self:finishMission("arrived")
        return
    end

    local moved = nil
    if self.lastCheckX ~= nil then
        moved = MathUtil.vector2Length(vx - self.lastCheckX, vz - self.lastCheckZ)
        self.totalDistanceDriven = self.totalDistanceDriven + moved
        self.stoppedTicks = (moved < STOP_MOVE_THRESHOLD) and (self.stoppedTicks + 1) or 0
    end
    self.lastCheckX, self.lastCheckZ = vx, vz
    self.routeStartGraceTicks = self.routeStartGraceTicks + 1
    self:trackStuckNotification(moved)
    -- 2026-07-31: Nutzer stand 70s bewusst still, der auto. Abbruch/Nachfuellen-Dialog kam
    -- trotzdem nicht (nur manuell per Taste erzwingbar) - Zaehler mitloggen, um beim naechsten
    -- Mal zu sehen ob stoppedTicks staendig durch Positionsrauschen zurueckgesetzt wird, ob die
    -- Kulanzzeit nie erreicht ist, oder ob stopDialogOpen faelschlich haengen bleibt.
    debugLog(string.format("Stillstand-Zaehler: stoppedTicks=%d/%d, routeStartGraceTicks=%d/%d, stopDialogOpen=%s",
        self.stoppedTicks, STOP_TICKS_REQUIRED, self.routeStartGraceTicks, ROUTE_START_GRACE_TICKS, tostring(self.stopDialogOpen)))

    if self.pendingActivationX ~= nil then
        local reactivateDist = MathUtil.vector2Length(vx - self.pendingActivationX, vz - self.pendingActivationZ)
        if reactivateDist <= REACTIVATION_RADIUS then
            setImplementsTurnedOn(self.vehicle, true)
            debugLog("Unterbrechungsstelle wieder erreicht - Streuer eingeschaltet")
            self.pendingActivationX, self.pendingActivationZ = nil, nil
        end
    end

    self.timeSinceSnowCheck = self.timeSinceSnowCheck + CHECK_INTERVAL
    if self.timeSinceSnowCheck >= SNOW_CHECK_INTERVAL_MS then
        self.timeSinceSnowCheck = 0
        if not isSnowLying() then
            self:finishMission("no_snow")
            return
        end
    end

    local fillLevel, fillCapacity = getVehicleFillInfo(self.vehicle)
    debugLog(string.format("Füllstand Streuer: %.0f / %.0f", fillLevel or -1, fillCapacity or -1))
    if fillLevel ~= nil and fillLevel < MIN_FILL_LEVEL_AUTO_REFUEL then
        debugLog("Füllstand niedrig - Zwangsstopp, dann automatisch zum Nachfüllen (Sicherheitsnetz)")
        self:showNotification(EMPLOYER_NAME, "Streuer fast leer - fahre automatisch zum Nachfüllen.")
        self:beginRefuelStop()
        return
    end

    -- Nutzer-Klarstellung 2026-07-31: hier ist der Fuellstand laengst geprueft (siehe oben) -
    -- steht das Fahrzeug trotz ausreichendem Fuellstand fest, geht's um ein Routenproblem
    -- (Hindernis, gescheitertes Wendemanoever), nicht ums Nachfuellen. Einfacher
    -- Abbruch-Dialog statt der alten Ja=Nachfuellen/Nein=Abbruch-Wahl.
    -- Nutzer-Vorschlag 2026-07-31: erst automatisch ins Fahrzeug wechseln (der Automatismus
    -- funktioniert jetzt, siehe tryEnterVehicle) + kurze Meldung mit Signalton, DANACH -
    -- CANCEL_DIALOG_DELAY_MS spaeter - erst den Abbruch-Dialog zeigen. Gibt dem Spieler die
    -- Chance, das Fahrzeug einfach selbst weiterzufahren, bevor die Abbruch-Frage kommt.
    if self.stoppedTicks >= STOP_TICKS_REQUIRED and self.routeStartGraceTicks >= ROUTE_START_GRACE_TICKS
        and not self.stopDialogOpen and self.cancelDialogPendingTimer == nil then
        self.cancelDialogPendingTimer = CANCEL_DIALOG_DELAY_MS
        local ok, info = tryEnterVehicle(self.vehicle)
        debugLog(string.format("Automatischer Fahrzeugwechsel wegen Standzeit-Ueberschreitung: ok=%s, %s", tostring(ok), info))
        self:showNotification(EMPLOYER_NAME, "Wegen einer massiven Störung wurden Sie in das Einsatzfahrzeug versetzt.")
    end

    if self.cancelDialogPendingTimer ~= nil then
        self.cancelDialogPendingTimer = self.cancelDialogPendingTimer - CHECK_INTERVAL
        if self.cancelDialogPendingTimer <= 0 then
            self.cancelDialogPendingTimer = nil
            self.stopDialogOpen = true
            self:showCancelDialog()
        end
    end
end

-- Sicherheitsnetz: falls der Streuer schon MITTEN auf der Arbeitsroute leer wird (z.B. bei
-- sehr weit entfernten Zielen), zum Depot fahren, nachladen, dann zum ORIGINAL-Ziel weiter.
-- Zwangsstopp vor der eigentlichen Nachfüll-Route (Nutzer-Vorschlag): hält das Fahrzeug
-- kurz an, damit AutoDrive aus dem Stillstand heraus die tatsächlich kürzeste Route neu
-- berechnen kann, statt aus voller Fahrt heraus umzulenken (das führte wiederholt zu
-- unnötigen Umwegen über den alten Zielpunkt).
function WinterdienstMission:beginRefuelStop()
    local stopResult = stopAndResetVehicle(self.vehicle)
    debugLog(string.format("Zwangsstopp vor Nachfüll-Route (%.0fs) über: %s", REFUEL_STOP_DELAY_MS / 1000, stopResult))
    self.pendingRefuelTimer = REFUEL_STOP_DELAY_MS
    self.state = STATE_PENDING_REFUEL
end

function WinterdienstMission:startRefuel()
    if self.vehicle == nil or self.vehicle.ad == nil then
        self:finishMissionWithError("Fahrzeug nicht mehr verfügbar")
        return
    end

    local vx, _, vz = getWorldTranslation(self.vehicle.rootNode)
    self.pendingActivationX, self.pendingActivationZ = vx, vz
    setImplementsTurnedOn(self.vehicle, false)
    debugLog(string.format("Streuer aus, Unterbrechungsposition gemerkt: %.0f/%.0f - fahre zum Nachfüllen", vx, vz))

    local speedResult = trySetSpeedLimit(self.vehicle, TRANSIT_SPEED_KMH)
    debugLog(string.format("Tempolimit (%d km/h) über: %s", TRANSIT_SPEED_KMH, speedResult))
    local motorResult = tryStartMotor(self.vehicle)
    debugLog("Motorstart über: " .. motorResult)
    self.lastCheckX, self.lastCheckZ = nil, nil
    self.stoppedTicks = 0
    self.routeStartGraceTicks = 0
    self.vehicle.ad.stateModule:setMode(getModeLoad())
    self.vehicle.ad.stateModule:setFirstMarkerByName(HOME_NAME)
    local currentMode = self.vehicle.ad.stateModule:getCurrentMode()
    if currentMode ~= nil then
        currentMode:start()
        self.state = STATE_DRIVING_TO_REFUEL
        -- Tempolimit NACH dem Routenstart erneut setzen -- setMode()/start() setzen
        -- AutoDrives eigenes Limit offenbar mitunter zurück.
        speedResult = trySetSpeedLimit(self.vehicle, TRANSIT_SPEED_KMH)
        debugLog(string.format("Tempolimit (%d km/h) nach Routenstart erneut über: %s", TRANSIT_SPEED_KMH, speedResult))
    else
        self:finishMissionWithError("Fahrmodus konnte nicht gestartet werden")
    end
end

function WinterdienstMission:checkArrivalAtRefuel()
    if self.vehicle == nil or self.vehicle.ad == nil then
        self:finishMissionWithError("Fahrzeug nicht mehr verfügbar")
        return
    end
    -- Tempolimit laufend erneut durchsetzen -- AutoDrive hat sich als nicht zuverlässig
    -- darin gezeigt, ein einmal gesetztes Limit über die ganze Fahrt zu behalten.
    trySetSpeedLimit(self.vehicle, TRANSIT_SPEED_KMH)
    local vx, _, vz = getWorldTranslation(self.vehicle.rootNode)
    local dist = MathUtil.vector2Length(vx - HOME_X, vz - HOME_Z)
    debugLog(string.format("Abstand zu %s: %.0f m", HOME_NAME, dist))
    if dist <= ARRIVAL_RADIUS then
        debugLog("Nachfüllpunkt erreicht")
        self.state = STATE_REFUELING
        return
    end

    -- Bisher fehlte auf dieser Etappe jede Stillstand-Erkennung - ein Fahrzeug, das hier
    -- feststeckt, blieb ohne jede Reaktionsmöglichkeit für den Spieler einfach stehen.
    local moved = nil
    if self.lastCheckX ~= nil then
        moved = MathUtil.vector2Length(vx - self.lastCheckX, vz - self.lastCheckZ)
        self.stoppedTicks = (moved < STOP_MOVE_THRESHOLD) and (self.stoppedTicks + 1) or 0
    end
    self.lastCheckX, self.lastCheckZ = vx, vz
    self.routeStartGraceTicks = self.routeStartGraceTicks + 1
    self:trackStuckNotification(moved)

    if self.stoppedTicks >= STOP_TICKS_REQUIRED and self.routeStartGraceTicks >= ROUTE_START_GRACE_TICKS
        and not self.stopDialogOpen then
        self.stopDialogOpen = true
        self:showCancelDialog()
    end
end

function WinterdienstMission:checkRefuelComplete()
    if self.vehicle == nil or self.vehicle.ad == nil then
        self:finishMissionWithError("Fahrzeug nicht mehr verfügbar")
        return
    end
    local fillLevel, fillCapacity = getVehicleFillInfo(self.vehicle)
    debugLog(string.format("Nachfüllen läuft - Füllstand: %.0f / %.0f", fillLevel or -1, fillCapacity or -1))
    if fillLevel ~= nil and fillCapacity ~= nil and fillCapacity > 0 and fillLevel >= fillCapacity * 0.95 then
        debugLog("Streuer wieder voll, fahre über " .. WORK_START_NAME .. " weiter Richtung " .. self.targetName)
        self:startDriveToWorkStart()
    end
end

-- Nach erfolgreichem Abschluss (oder Schnee-Ende): automatisch zu "WD Missionsende" fahren,
-- dort parken und alles ausschalten. Der Füllstand wird nicht mehr hier geprüft, sondern
-- bereits bei der nächsten Auftragsannahme (siehe startAfterPendingWait).
function WinterdienstMission:startDriveToMissionEnd()
    if self.vehicle == nil or self.vehicle.ad == nil then
        return
    end
    debugLog("Fahre zu: " .. MISSION_END_NAME)
    local motorResult = tryStartMotor(self.vehicle)
    debugLog("Motorstart über: " .. motorResult)
    local speedResult = trySetSpeedLimit(self.vehicle, TRANSIT_SPEED_KMH)
    debugLog(string.format("Tempolimit (%d km/h) über: %s", TRANSIT_SPEED_KMH, speedResult))
    setImplementsTurnedOn(self.vehicle, false)
    self.lastCheckX, self.lastCheckZ = nil, nil
    self.vehicle.ad.stateModule:setMode(getModeDriveTo())
    self.vehicle.ad.stateModule:setFirstMarkerByName(MISSION_END_NAME)
    local currentMode = self.vehicle.ad.stateModule:getCurrentMode()
    if currentMode ~= nil then
        currentMode:start()
        self.state = STATE_DRIVING_TO_MISSION_END
        -- Tempolimit NACH dem Routenstart erneut setzen -- setMode()/start() setzen
        -- AutoDrives eigenes Limit offenbar mitunter zurück.
        speedResult = trySetSpeedLimit(self.vehicle, TRANSIT_SPEED_KMH)
        debugLog(string.format("Tempolimit (%d km/h) nach Routenstart erneut über: %s", TRANSIT_SPEED_KMH, speedResult))
    end
end

function WinterdienstMission:beginStopVerification()
    self.stopVerifyAttempts = 0
    self.stopVerifyLastX = nil
    self.stopVerifyLastZ = nil
    self.stopVerifyStationaryTicks = 0
    self.state = STATE_VERIFYING_STOP
end

function WinterdienstMission:checkArrivalAtMissionEnd()
    if self.vehicle == nil or self.vehicle.ad == nil then
        return
    end
    -- Tempolimit laufend erneut durchsetzen -- AutoDrive hat sich als nicht zuverlässig
    -- darin gezeigt, ein einmal gesetztes Limit über die ganze Fahrt zu behalten.
    trySetSpeedLimit(self.vehicle, TRANSIT_SPEED_KMH)
    local vx, _, vz = getWorldTranslation(self.vehicle.rootNode)
    local dist = MathUtil.vector2Length(vx - MISSION_END_X, vz - MISSION_END_Z)
    debugLog(string.format("Abstand zu %s: %.0f m", MISSION_END_NAME, dist))

    local moved = nil
    if self.lastCheckX ~= nil then
        moved = MathUtil.vector2Length(vx - self.lastCheckX, vz - self.lastCheckZ)
    end
    self.lastCheckX, self.lastCheckZ = vx, vz
    self:trackStuckNotification(moved)

    if dist <= ARRIVAL_RADIUS then
        debugLog("Missionsende erreicht - versuche zu stoppen")
        local stopResult = stopAndResetVehicle(self.vehicle)
        debugLog("Fahrzeug gestoppt/zurückgesetzt über: " .. stopResult)
        self:beginStopVerification()
    end
end

-- Vertraut NICHT auf isActive() allein (das spiegelt nur AutoDrives eigenen Zustand wider -
-- übernimmt ein ANDERES System wie der interne FS-Helfer das Fahrzeug, kann isActive()
-- ehrlich "false" melden, während das Fahrzeug trotzdem weiterfährt - genau das ist beim
-- Helfer-Test passiert). Prüft stattdessen direkt per Position, ob sich das Fahrzeug
-- tatsächlich nicht mehr bewegt - das lässt sich nicht durch ein falsches Zustands-Flag
-- vortäuschen.
function WinterdienstMission:enterIdleOrDepartAfterStop()
    if self.autoDepartAfterStop then
        debugLog(string.format("Stopp verifiziert - automatische Weiterfahrt in %.0fs", DEPARTURE_DELAY_MS / 1000))
        self.autoDepartAfterStop = false
        self.pendingDepartureTimer = DEPARTURE_DELAY_MS
        self.state = STATE_PENDING_DEPARTURE
    else
        -- Nutzer-Wunsch 2026-08-01: beim endgueltigen Parken (nicht bei automatischer
        -- Weiterfahrt, siehe autoDepartAfterStop oben) den Motor abstellen statt ihn laufen zu
        -- lassen - "wir wollen doch Diesel sparen".
        if self.vehicle ~= nil then
            local stopResult = tryStopMotor(self.vehicle)
            debugLog("Motor beim Parken gestoppt über: " .. stopResult)
        end
        self.state = STATE_IDLE
        self.timeSinceIdleSnowCheck = 0
        self.missionCooldownRemaining = MISSION_COOLDOWN_MS
        self.idleSnowNotified = false
    end
end

function WinterdienstMission:checkStopVerified()
    if self.vehicle == nil then
        self:enterIdleOrDepartAfterStop()
        return
    end

    local vx, _, vz = getWorldTranslation(self.vehicle.rootNode)
    local isActive = false
    if self.vehicle.ad ~= nil and self.vehicle.ad.stateModule ~= nil then
        isActive = self.vehicle.ad.stateModule:isActive()
    end

    local moved = 0
    local hadPrevious = self.stopVerifyLastX ~= nil
    if hadPrevious then
        moved = MathUtil.vector2Length(vx - self.stopVerifyLastX, vz - self.stopVerifyLastZ)
    end
    self.stopVerifyLastX, self.stopVerifyLastZ = vx, vz

    if hadPrevious and moved < STOP_MOVE_THRESHOLD then
        self.stopVerifyStationaryTicks = self.stopVerifyStationaryTicks + 1
    else
        self.stopVerifyStationaryTicks = 0
    end

    debugLog(string.format("Stopp-Verifikation: bewegt %.2fm seit letzter Sekunde, isActive=%s, stationär seit %d Sekunden",
        moved, tostring(isActive), self.stopVerifyStationaryTicks))

    if self.stopVerifyStationaryTicks >= 2 then
        debugLog("Stopp verifiziert - Fahrzeug bewegt sich tatsächlich nicht mehr")
        self:enterIdleOrDepartAfterStop()
        return
    end

    self.stopVerifyAttempts = self.stopVerifyAttempts + 1
    debugLog("WARNUNG: Fahrzeug bewegt sich trotz Stopp-Versuch weiterhin (Versuch " .. self.stopVerifyAttempts .. ") - erneuter Versuch")
    local stopResult = stopAndResetVehicle(self.vehicle)
    debugLog("Erneuter Stopp-Versuch über: " .. stopResult)

    if self.stopVerifyAttempts == 3 then
        -- 2026-07-31: war eine blockierende showCenteredMessage (OK-Klick noetig) - ausgerechnet
        -- in einer Situation mit Kollisionsgefahr kontraproduktiv. showNotification (nicht
        -- blockierend, mit Signalton) passt hier besser, gleiche Begruendung wie beim
        -- allgemeinen Stillstand-Fall.
        self:showNotification("WARNUNG", "Fahrzeug bewegt sich trotz Stopp-Versuchen weiter - bitte SOFORT manuell übernehmen!")
        -- Nutzer-Vorschlag 2026-07-31: in dieser Situation zaehlt jede Sekunde (Kollisionsgefahr),
        -- daher NICHT nur die Meldung zeigen, sondern den Spieler direkt ins Fahrzeug versetzen,
        -- statt ihn erst manuell per Tab wechseln zu lassen (siehe tryEnterVehicle oben fuer
        -- die Begruendung, warum das ueber Basisspiel-API statt AutoDrive.requestToEnterVehicle
        -- laeuft).
        local ok, info = tryEnterVehicle(self.vehicle)
        debugLog(string.format("Automatischer Fahrzeugwechsel wegen Stopp-Versuchen: ok=%s, %s", tostring(ok), info))
    end
end

function WinterdienstMission:showCancelDialog()
    local text = "Laufenden Winterdienst-Auftrag abbrechen?\n\n" ..
        "Es wird eine Vertragsstrafe fällig (doppelte Kilometerpauschale für die bisher gefahrene Strecke)."
    YesNoDialog.show(function(a, b)
        local confirmed = extractYesNo(a, b)
        debugLog("Abbruch-Dialog-Antwort: " .. tostring(confirmed))
        self.stopDialogOpen = false
        self.stoppedTicks = 0
        if confirmed then self:cancelMission() end
    end, self, text, "Winterdienst-Auftrag")
end

function WinterdienstMission:showCenteredMessage(title, text, onConfirmed)
    local ok = false
    if g_gui ~= nil and g_gui.showInfoDialog ~= nil then
        ok = pcall(function()
            g_gui:showInfoDialog({
                text = text,
                title = title,
                callback = onConfirmed,
                target = self,
            })
        end)
    end
    if not ok then
        if YesNoDialog ~= nil and YesNoDialog.show ~= nil then
            YesNoDialog.show(function()
                if onConfirmed ~= nil then
                    onConfirmed()
                end
            end, self, text, title)
        else
            self:showNotification(title, text)
            if onConfirmed ~= nil then
                onConfirmed()
            end
        end
    end
end

-- Bezahlung ist distanzbasiert - reason unterscheidet nur den Meldungstext. Nach Erfolg oder
-- Schnee-Ende fährt das Fahrzeug automatisch zurück zum Depot (nicht bei manuellem Abbruch).
function WinterdienstMission:finishMission(reason)
    local km = self.totalDistanceDriven / 1000
    local payout = km * PAYOUT_PER_KM

    debugLog(string.format("Auftrag beendet (%s) - %.1f km gefahren, Auszahlung %s", reason, km, formatEuroAmount(payout)))

    self.state = STATE_FINISHED
    self.missionActive = false
    self.pendingActivationX, self.pendingActivationZ = nil, nil

    if g_currentMission ~= nil and g_currentMission.addMoney ~= nil then
        g_currentMission:addMoney(payout, g_currentMission:getFarmId(), MoneyType.OTHER, true, true)
    end

    local text
    if reason == "arrived" then
        text = string.format(
            "Auftrag ordnungsgemäß abgeschlossen (%s erreicht). Die Stadt zahlt Dir %s (%.1f km à %.2f €/km).",
            self.targetName, formatEuroAmount(payout), km, PAYOUT_PER_KM
        )
    else
        text = string.format(
            "Winterdienst nicht mehr benötigt. Die Stadt zahlt Dir für verbrauchtes Material und verbrauchten Kraftstoff " ..
                "folgende Summe: %s (%.1f km à %.2f €/km).",
            formatEuroAmount(payout), km, PAYOUT_PER_KM
        )
    end
    self:showNotification("Winterdienst-Auftrag", text)
    self.pendingDepartureTimer = DEPARTURE_DELAY_MS
    self.state = STATE_PENDING_DEPARTURE
end

function WinterdienstMission:cancelMission()
    local km = self.totalDistanceDriven / 1000
    local penalty = km * PAYOUT_PER_KM * PENALTY_MULTIPLIER

    debugLog(string.format("Auftrag abgebrochen - %.1f km gefahren, Vertragsstrafe %s", km, formatEuroAmount(penalty)))

    self.missionActive = false
    self.pendingActivationX, self.pendingActivationZ = nil, nil
    local stopResult = stopAndResetVehicle(self.vehicle)
    debugLog("Fahrzeug gestoppt/zurückgesetzt über: " .. stopResult)
    self:beginStopVerification()

    if g_currentMission ~= nil and g_currentMission.addMoney ~= nil then
        g_currentMission:addMoney(-penalty, g_currentMission:getFarmId(), MoneyType.OTHER, true, true)
    end

    self:showNotification(
        "Winterdienst-Auftrag",
        string.format(
            "Der Auftrag wurde abgebrochen. Die Stadt verlangt eine Vertragsstrafe in Höhe der doppelten Kilometerpauschale " ..
                "für die bisher gefahrene Strecke: %s (%.1f km).",
            formatEuroAmount(penalty), km
        )
    )
    self.autoDepartAfterStop = true
end

function WinterdienstMission:finishMissionWithError(errorMessage)
    debugLog("Fehler: " .. errorMessage)
    self.missionActive = false
    self.pendingActivationX, self.pendingActivationZ = nil, nil
    self.autoDepartAfterStop = false
    local stopResult = stopAndResetVehicle(self.vehicle)
    debugLog("Fahrzeug gestoppt/zurückgesetzt über: " .. stopResult)
    self:beginStopVerification()
    self:showNotification("Fehler", errorMessage)
end

function WinterdienstMission:showNotification(title, message)
    local fullText = title .. ": " .. message
    local ok = false
    -- addIngameNotification zuerst versuchen - laut einem dokumentierten FS25-Bugreport die
    -- korrekte API (im Gegensatz zu showBlinkingWarning, das nachweislich abstürzen kann und
    -- deshalb hier bewusst nicht verwendet wird).
    if g_currentMission ~= nil and g_currentMission.addIngameNotification ~= nil then
        ok = pcall(function()
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK, fullText)
        end)
    end
    if not ok and g_currentMission ~= nil and g_currentMission.hud ~= nil and g_currentMission.hud.addSideNotification ~= nil then
        g_currentMission.hud:addSideNotification(FSBaseMission.INGAME_NOTIFICATION_OK, fullText)
    end

    -- 2026-07-31: GuiSoundPlayer:playSample() war die falsche API - das ist ein Mixin fuer
    -- GUI-Elemente (Klicksounds bei OFFENEM Menü), kein globaler "spiel irgendwann einen Ton"-
    -- Mechanismus. Deshalb kam nie ein Ton, wenn der Spieler kein Menü offen hatte (also praktisch
    -- immer waehrend der Fahrt/Arbeit - genau der Fall, in dem der Ton gebraucht wird). AutoDrive
    -- selbst laedt beim eigenen Init zwei .ogg-Dateien (notification_ok/notification_warning,
    -- siehe deren AutoDrive.lua/AutoDrive:init) und spielt sie ueber die eigene
    -- AutoDrive.playSample(sample, volume, forced)-Hilfsfunktion ab (siehe deren
    -- Manager/MessagesManager.lua) - diese bereits geladenen Samples werden hier wiederverwendet,
    -- statt eigene Audiodateien mitliefern zu muessen. forced=true, damit der Ton auch kommt,
    -- wenn der Spieler AutoDrives eigene Sound-Einstellung deaktiviert hat - das hier ist eine
    -- sicherheitsrelevante Meldung (Kollisionsgefahr), keine AutoDrive-Kosmetik.
    -- 2026-08-01: notificationSample UND notificationWarningSample waren die GANZE Session ueber
    -- (mehrfach, ueber eine Stunde, verschiedene Fahrzeuge/Mods) durchgaengig nil - AutoDrive:init()
    -- laedt seine Sounds hier offenbar nie erfolgreich, unabhaengig vom restlichen Setup. Statt
    -- laenger auf AutoDrive zu warten: eigenes mitgeliefertes Sample (sounds/notification.ogg,
    -- via getOwnNotificationSample() oben) direkt ueber die Basisspiel-Funktion playSample()
    -- abspielen - genau dieselbe globale Funktion, die AutoDrive.playSample() intern nutzt.
    -- AutoDrives Samples bleiben als zweite Option, falls sie doch mal verfuegbar werden.
    local ownSample, ownErr = getOwnNotificationSample()
    if ownSample ~= nil and playSample ~= nil then
        local ok, err = pcall(function() playSample(ownSample, 1, 0.9, 0, 0, 0) end)
        debugLog(string.format("Signalton über eigenes Sample (sounds/notification.ogg): ok=%s, %s", tostring(ok), ok and "-" or tostring(err)))
        return
    end
    local adSample = AutoDrive ~= nil and (AutoDrive.notificationSample or AutoDrive.notificationWarningSample) or nil
    if AutoDrive ~= nil and AutoDrive.playSample ~= nil and adSample ~= nil then
        local ok, err = pcall(function() AutoDrive.playSample(adSample, 0.9, true) end)
        debugLog(string.format("Signalton über AutoDrive.playSample (Fallback): ok=%s, %s", tostring(ok), ok and "-" or tostring(err)))
    else
        debugLog("Signalton NICHT möglich - weder eigenes Sample (" .. tostring(ownErr) .. ") noch AutoDrive-Samples verfügbar")
    end
end

-- ===================== INITIALISIERUNG =====================

local winterdienstMissionInstance = nil

local function initWinterdienstMission(mission)
    winterdienstMissionInstance = WinterdienstMission.new()
    addModEventListener(winterdienstMissionInstance)
    addConsoleCommand("wdForceSnow", "Schnee-Erkennung für Winterdienst-Tests erzwingen/aufheben (1/0, ohne Parameter = umschalten)", "consoleForceSnow", winterdienstMissionInstance)
    addConsoleCommand("wdAccept", "Winterdienst-Auftragsprüfung auslösen (Ersatz zur Tastenbelegung, funktioniert nur im Winterdienst-Fahrzeug)", "consoleTriggerAccept", winterdienstMissionInstance)
    addConsoleCommand("wdInspect", "Anbaugeraete am Winterdienst-Fahrzeug auf moegliche Senk-/Hebe-Methoden untersuchen (Diagnose, schreibt ins Log)", "consoleInspectImplements", winterdienstMissionInstance)
    addConsoleCommand("wdInspectActions", "Sucht nach registrierten Tasten-Aktionen (actionEvents) fuer Heben/Senken/Ein-Aus am Geraet und Fahrzeug (Diagnose, schreibt ins Log)", "consoleInspectActions", winterdienstMissionInstance)
    addConsoleCommand("wdInspectLength", "Liest AutoDrives tatsaechlich berechnete Fahrzeug-/Zug-Laenge aus, um zu pruefen ob das Frontgeraet mitgezaehlt wird (Diagnose, schreibt ins Log)", "consoleInspectLength", winterdienstMissionInstance)
    addConsoleCommand("wdInspectBladeTransform", "Liest Welt-Position/-Rotation des U400 und des angehaengten Schilds aus (fuer Giants-Editor-Umbau, schreibt ins Log)", "consoleInspectBladeTransform", winterdienstMissionInstance)
    addConsoleCommand("wdTryLower", "Mehrere Kandidaten-Senkmethoden nacheinander an der Schneefraese ausprobieren (Diagnose, schreibt ins Log)", "consoleTryLowerPlow", winterdienstMissionInstance)
    print("[Winterdienst] Mod geladen (Ruhezustand-Kreislauf-Version)")
end

FSBaseMission.onStartMission = Utils.appendedFunction(FSBaseMission.onStartMission, initWinterdienstMission)
