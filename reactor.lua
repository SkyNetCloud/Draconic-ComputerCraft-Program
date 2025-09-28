-- WebSocket setup
local renderUrl = loadWebSocketUrl() -- or your server URL
local ws = nil

print("Connecting to WebSocket server at:", renderUrl)

function connectWebSocket()
    print("Connecting to WebSocket server...")
    ws, err = http.websocket(renderUrl)
    if not ws then
        print("WebSocket failed: " .. tostring(err))
        return false
    end
    print("Connected to WebSocket!")
    return true
end

connectWebSocket()

-- Utility: send reactor data
function sendReactorData()
    if ws then
        local ri = reactor.getReactorInfo()
        if ri then
            local data = {
                status = ri.status,
                temp = ri.temperature,
                field = math.floor(ri.fieldStrength / ri.maxFieldStrength * 100),
                fuel = math.floor(100 - (ri.fuelConversion / ri.maxFuelConversion * 100)),
                outputGate = fluxgate.getSignalLowFlow(),
                inputGate = inputFluxgate.getSignalLowFlow()
            }
            ws.send(textutils.serializeJSON(data))
        end
    end
end

-- WebSocket receive loop
function listenWebSocket()
    while true do
        if ws then
            local msg = ws.receive()
            if msg then
                local decoded = textutils.unserializeJSON(msg)
                if decoded.command == "start" then
                    reactor.activateReactor()
                elseif decoded.command == "stop" then
                    reactor.stopReactor()
                elseif decoded.command == "setFlow" then
                    inputFluxgate.setSignalLowFlow(decoded.value)
                end
            end
        else
            sleep(5)
            connectWebSocket()
        end
        sleep(0.5)
    end
end

function loadWebSocketUrl()
    local fileName = "websocket_url.txt"
    if not fs.exists(fileName) then
        print("No websocket_url.txt found! Creating default file.")
        local file = fs.open(fileName, "w")
        file.writeLine("ws://localhost:3000") -- default URL
        file.close()
        return "ws://localhost:3000"
    end

    local file = fs.open(fileName, "r")
    local url = file.readLine()
    file.close()
    return url
end

os.loadAPI("lib/f")
os.loadAPI("lib/button")

local targetStrength = 50
local maxTemp = 7750
local safeTemp = 3000
local lowFieldPer = 15

local activateOnCharge = true

local version = 0.3

local autoInputGate = 1
local curInputGate = 222000

local mon, monitor, monX, monY

local reactor
local fluxgate
local inputFluxgate

local ri

local action = "None since reboot"
local actioncolor = colors.gray
local emergencyCharge = false
local emergencyTemp = false

monitor = f.periphSearch("monitor")
-- inputFluxgate = f.periphSearch("flow_gate")
-- fluxgate = f.getPeripheral("flow_gate")
reactor = f.periphSearch("draconic_reactor")

function detectFlowGates()
    local gates = {peripheral.find("flow_gate")}
    if #gates < 2 then
        error("Error: Less than 2 flow gates detected!")
        return nil, nil
    end

    print("Please set input flow gate to **10 RF/t** manually.")

    local inputGate, outputGate, inputName, outputName

    while not inputGate do
        sleep(1)  -- Wait before checking again

        for _, name in pairs(peripheral.getNames()) do
            if peripheral.getType(name) == "flow_gate" then
                local gate = peripheral.wrap(name)
                local setFlow = gate.getSignalLowFlow()

                if setFlow == 10 then
                    inputGate, inputName = gate, name
                    print("Detected input gate:", name)
                else
                    outputGate, outputName = gate, name
                end
            end
        end
    end

    if not outputGate then
        print("Error: Could not identify output gate!")
        return nil, nil
    end

    return inputGate, outputGate, inputName, outputName
end

function saveFlowGateNames(inputName, outputName)
    local file = fs.open("flowgate_names.txt", "w")
    file.writeLine(inputName)
    file.writeLine(outputName)
    file.close()
    print("Saved flow gate names for reboot!")
end

function loadFlowGateNames()
    if not fs.exists("flowgate_names.txt") then
        print("No saved flow gate names found! Running detection again...")
        return nil, nil, nil, nil
    end

    local file = fs.open("flowgate_names.txt", "r")
    local inputName = file.readLine()
    local outputName = file.readLine()
    file.close()

    print("Loaded saved flow gate names:", inputName, outputName)

    if peripheral.isPresent(inputName) and peripheral.isPresent(outputName) then
        return peripheral.wrap(inputName), peripheral.wrap(outputName), inputName, outputName
    else
        print("Saved peripherals not found! Running detection again...")
        return nil, nil, nil, nil
    end
end

function setupFlowGates()
    -- Try to load saved names
    local inputFluxgate, outputFluxgate, inputName, outputName = loadFlowGateNames()

    -- If names don't exist, detect manually
    if not inputFluxgate or not outputFluxgate then
        inputFluxgate, outputFluxgate, inputName, outputName = detectFlowGates()
        if inputFluxgate and outputFluxgate then
            saveFlowGateNames(inputName, outputName)
        else
            error("Flow gate setup failed! Make sure to set the input flow gate to 10 before running the script again!")
            return nil, nil
        end
    end

    return inputFluxgate, outputFluxgate
end

inputFluxgate, fluxgate = setupFlowGates()

if monitor == nil then
	error("No valid monitor was found")
end

if fluxgate == nil then
	error("No valid flow gate was found")
end

if inputFluxgate == nil then
	error("No input flow gate was found. Please put the low signal value to 10")
end

if reactor == nil then
	error("No reactor was found")
end

monX, monY = monitor.getSize()
mon = {}
mon.monitor, mon.X, mon.Y = monitor, monX, monY

f.firstSet(mon)

function mon.clear()
	mon.monitor.setBackgroundColor(colors.black)
	mon.monitor.clear()
	mon.monitor.setCursorPos(1,1)
	button.screen()
end

function save_config()
	sw = fs.open("reactorconfig.txt", "w")
	sw.writeLine(autoInputGate)
	sw.writeLine(curInputGate)
	sw.close()
end

function load_config()
	sr = fs.open("reactorconfig.txt", "r")
	autoInputGate = tonumber(sr.readLine())
	curInputGate = tonumber(sr.readLine())
	sr.close()
end

if fs.exists("reactorconfig.txt") == false then
	save_config()
else
	load_config()
end

function reset()
	term.clear()
	term.setCursorPos(1,1)
end

function reactorStatus(r)
    local statusTable = {
        running = {"Online", colors.green},
        cold = {"Offline", colors.gray},
        warming_up = {"Charging", colors.orange},
        cooling = {"Cooling Down", colors.blue},
        stopping = {"Shutting Down", colors.red} -- Default case
    }

    -- Return status or default to "Shutting Down"
    return statusTable[r] or statusTable["stopping"]
end

local lastTerminalValues = {}

function drawTerminalText(x, y, label, newValue)
    local key = label  -- Use label as key to track changes

    -- Only update if the value changed
    if lastTerminalValues[key] ~= newValue then
        term.setCursorPos(x, y)
        term.clearLine()  -- Clear only the current line
        term.write(label .. ": " .. newValue)
        lastTerminalValues[key] = newValue  -- Store new value
    end
end

function reactorControl()
    reset() -- Clear the terminal once at startup

    while true do
        local ri = reactor.getReactorInfo()
        if not ri then
            print("Reactor not setup correctly. Retrying in 2s...")
            sleep(2)
            goto continue
        end

        -- Update terminal output
        local i = 1
        for k, v in pairs(ri) do
            drawTerminalText(1, i, k, tostring(v))
            i = i + 1
        end
        i = i + 1
        drawTerminalText(1, i, "Output Gate", fluxgate.getSignalLowFlow()) 
        i = i + 1
        drawTerminalText(1, i, "Input Gate", inputFluxgate.getSignalLowFlow())

        -- Reactor Control Logic
        if emergencyCharge then
            reactor.chargeReactor()
        end

        if ri.status == "warming_up" then
            inputFluxgate.setSignalLowFlow(900000)
            emergencyCharge = false
        elseif ri.status == "stopping" and ri.temperature < safeTemp and emergencyTemp then
            reactor.activateReactor()
            emergencyTemp = false
        elseif ri.status == "warming_up" and activateOnCharge then
            reactor.activateReactor()
        end

        -- Auto-adjust power flow
        if ri.status == "running" then
            local fluxval = autoInputGate == 1 
                and ri.fieldDrainRate / (1 - (targetStrength / 100)) 
                or curInputGate

            i = i + 1
            drawTerminalText(1, i, "Target Gate", fluxval)
            inputFluxgate.setSignalLowFlow(fluxval)
        end

        -- Emergency Safeguards
        checkReactorSafety(ri)

        sleep(0.2) -- Keeps CPU usage low while maintaining constant monitoring
        ::continue::
    end
end

function checkReactorSafety(ri)
    local fuelPercent = 100 - math.ceil(ri.fuelConversion / ri.maxFuelConversion * 10000) * 0.01
    local fieldPercent = math.ceil(ri.fieldStrength / ri.maxFieldStrength * 10000) * 0.01

    if fuelPercent <= 10 then
        emergencyShutdown("Fuel Low! Refuel Now!")
    elseif fieldPercent <= lowFieldPer and ri.status == "running" then
        emergencyShutdown("Field Strength Below "..lowFieldPer.."%!")
        reactor.chargeReactor()
        emergencyCharge = true
    elseif ri.temperature > maxTemp then
        emergencyShutdown("Reactor Overheated!")
        emergencyTemp = true
    end
end

function emergencyShutdown(message)
    reactor.stopReactor()
    actioncolor = colors.red
    action = message
    ActionMenu()
end

local MenuText = "Loading..."

function clearMenuArea()
    -- Ensure we clear enough space for buttons
    for i = 26, monY-1 do
        f.draw_line(mon, 2, i, monX-2, colors.black)
    end
    button.clearTable() -- Clear stored button references

	f.draw_line(mon, 2, 26, monX-2, colors.gray)  -- Redraw top of the menu box
	f.draw_line(mon, 2, monY-1, monX-2, colors.gray)  -- Redraw bottom border
	f.draw_line_y(mon, 2, 26, monY-1, colors.gray)  -- Left border
	f.draw_line_y(mon, monX-1, 26, monY-1, colors.gray)  -- Right border
	f.draw_text(mon, 4, 26, " "..MenuText.." ", colors.white, colors.black)
end

function toggleReactor()
	ri = reactor.getReactorInfo()

	if ri.status == "running" then
		reactor.stopReactor()
	elseif ri.status == "stopping" then
		reactor.activateReactor()
	else
		reactor.chargeReactor()
	end
end

function ActionMenu()
	currentMenu = "action"
	
    MenuText = "ATTENTION"

	clearMenuArea()

	button.setButton("action", action, buttonMain, 5, 28, monX-4, 30, 0, 0, colors.red)

	button.screen()
end

function rebootSystem()
	os.reboot()
end

function buttonControls()
    if currentMenu == "controls" then return end
    currentMenu = "controls"
	
    MenuText = "CONTROLS"

    clearMenuArea() -- Clear old buttons

    local sLength = 6+(string.len("Toggle Reactor")+1)
    button.setButton("toggle", "Toggle Reactor", toggleReactor, 6, 28, sLength, 30, 0, 0, colors.blue)

    local sLength2 = (sLength+12+(string.len("Reboot"))+1)
    button.setButton("reboot", "Reboot", rebootSystem, sLength+12, 28, sLength2, 30, 0, 0, colors.blue)

    local sLength3 = 4+(string.len("Back")+1)
    button.setButton("back", "Back", buttonMain, 4, 32, sLength3, 34, 0, 0, colors.blue)

    button.screen()
end

function changeOutputValue(num, val)
	local cFlow = fluxgate.getSignalLowFlow()
	
	if val == 1 then
		cFlow = cFlow+num
	else
		cFlow = cFlow-num
	end
	fluxgate.setSignalLowFlow(cFlow)
	updateReactorInfo()
end


function outputMenu()
    if currentMenu == "output" then return end
    currentMenu = "output"

    MenuText = "OUTPUT"

    clearMenuArea() -- Clear old buttons

    -- Define button data (Label, Value, Change Type)
    local buttonData = {
        {label = ">>>>", value = 1000000, changeType = 1}, -- +1,000,000
        {label = ">>>", value = 100000, changeType = 1},   -- +100,000
        {label = ">>", value = 10000, changeType = 1},     -- +10,000
        {label = ">", value = 1000, changeType = 1},       -- +1,000
        {label = "<", value = 1000, changeType = 0},       -- -1,000
        {label = "<<", value = 10000, changeType = 0},     -- -10,000
        {label = "<<<", value = 100000, changeType = 0},   -- -100,000
        {label = "<<<<", value = 1000000, changeType = 0}, -- -1,000,000
    }

    -- Determine the starting X position dynamically
    local spacing = 2
    local buttonY = 28  -- Button row position

    -- Add buttons dynamically
    local currentX = monX - 7
    for _, data in ipairs(buttonData) do
        local buttonLength = string.len(data.label) + 1
        local startX = currentX - buttonLength
        local endX = startX + buttonLength

        button.setButton(data.label, data.label, changeOutputValue, startX, buttonY, endX, buttonY + 2, data.value, data.changeType, colors.blue)

        currentX = currentX - buttonLength - spacing  -- Move left for the next button
    end

    -- Add "Back" button at the bottom
    local backLength = 4 + string.len("Back") + 1
    button.setButton("back", "Back", buttonMain, 4, 32, backLength, 34, 0, 0, colors.blue)

    -- Refresh screen
    button.screen()
end


function buttonMain()
    if currentMenu == "main" then return end
    currentMenu = "main"

    MenuText = "MAIN MENU"

    clearMenuArea() -- Clear old buttons

    local sLength = 4+(string.len("Controls")+1)
    button.setButton("controls", "Controls", buttonControls, 4, 28, sLength, 30, 0, 0, colors.blue)

    local sLength2 = (sLength+13+(string.len("Output"))+1)
    button.setButton("output", "Output", outputMenu, sLength+13, 28, sLength2, 30, 0, 0, colors.blue)

    button.screen()
end

local lastValues = {}

function reactorInfoScreen()
    mon.clear()

    f.draw_text(mon, 2, 38, "Made by: StormFusions  v"..version, colors.gray, colors.black)

    -- Draw Static UI Elements (Frames, Labels)
    f.draw_line(mon, 2, 22, monX-2, colors.gray)
    f.draw_line(mon, 2, 2, monX-2, colors.gray)
    f.draw_line_y(mon, 2, 2, 22, colors.gray)
    f.draw_line_y(mon, monX-1, 2, 22, colors.gray)
    f.draw_text(mon, 4, 2, " INFO ", colors.white, colors.black)

    f.draw_line(mon, 2, 26, monX-2, colors.gray)
    f.draw_line(mon, 2, monY-1, monX-2, colors.gray)
    f.draw_line_y(mon, 2, 26, monY-1, colors.gray)
    f.draw_line_y(mon, monX-1, 26, monY-1, colors.gray)
    f.draw_text(mon, 4, 26, " "..MenuText.." ", colors.white, colors.black)

    -- Loop to continuously update screen
    while true do
        updateReactorInfo()
        sleep(1)
    end
end


function updateReactorInfo()
    ri = reactor.getReactorInfo()
	
    if not ri then return end

    -- Update only when values change
    drawUpdatedText(4, 4, "Status:", reactorStatus(ri.status)[1], reactorStatus(ri.status)[2])
    drawUpdatedText(4, 5, "Generation:", f.format_int(ri.generationRate).." rf/t", colors.lime)

    local tempColor = getTempColor(ri.temperature)
    drawUpdatedText(4, 7, "Temperature:", f.format_int(ri.temperature).."C", tempColor)

    drawUpdatedText(4, 9, "Output Gate:", f.format_int(fluxgate.getSignalLowFlow()).." rf/t", colors.lightBlue)
    drawUpdatedText(4, 10, "Input Gate:", f.format_int(inputFluxgate.getSignalLowFlow()).." rf/t", colors.lightBlue)

    local satPercent = getPercentage(ri.energySaturation, ri.maxEnergySaturation)
    drawUpdatedText(4, 12, "Energy Saturation:", satPercent.."%", colors.green)
    f.progress_bar(mon, 4, 13, monX-7, satPercent, 100, colors.green, colors.lightGray)

    local fieldPercent = getPercentage(ri.fieldStrength, ri.maxFieldStrength)
    local fieldColor = getFieldColor(fieldPercent)
    drawUpdatedText(4, 15, "Field Strength:", fieldPercent.."%", fieldColor)
    f.progress_bar(mon, 4, 16, monX-7, fieldPercent, 100, fieldColor, colors.lightGray)

    local fuelPercent = 100 - getPercentage(ri.fuelConversion, ri.maxFuelConversion)
    local fuelColor = getFuelColor(fuelPercent)
    drawUpdatedText(4, 18, "Fuel:", fuelPercent.."%", fuelColor)
    f.progress_bar(mon, 4, 19, monX-7, fuelPercent, 100, fuelColor, colors.lightGray)
end

function drawUpdatedText(x, y, label, value, color)
    local key = label
    if lastValues[key] ~= value then
		f.draw_text_lr(mon, x, y, 3, "            ", "                    ", colors.white, color, colors.black)
        f.draw_text_lr(mon, x, y, 3, label, value, colors.white, color, colors.black)
        lastValues[key] = value
    end
end

function getTempColor(temp)
    if temp <= 5000 then return colors.green end
    if temp <= 6500 then return colors.orange end
    return colors.red
end

function getFieldColor(percent)
    if percent >= 50 then return colors.blue end
    if percent > 30 then return colors.orange end
    return colors.red
end

function getFuelColor(percent)
    if percent >= 70 then return colors.green end
    if percent > 30 then return colors.orange end
    return colors.red
end

function getPercentage(value, maxValue)
    return math.ceil(value / maxValue * 10000) * 0.01
end

mon.clear()
mon.monitor.setTextScale(0.5)

buttonMain() -- Initialize buttons before the event listener

parallel.waitForAny(reactorInfoScreen, reactorControl, button.clickEvent)
