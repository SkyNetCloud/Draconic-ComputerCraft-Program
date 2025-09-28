-- Load APIs
os.loadAPI("lib/f")
os.loadAPI("lib/button")

-- Modifiable variables
local targetStrength = 50
local maxTemp = 7750
local safeTemp = 3000
local lowFieldPer = 15
local activateOnCharge = true
local version = 0.3
local autoInputGate = 1
local curInputGate = 222000

-- Peripheral references
local mon, monitor, monX, monY
local reactor
local fluxgate
local inputFluxgate
local ri

local action = "None since reboot"
local actioncolor = colors.gray
local emergencyCharge = false
local emergencyTemp = false

-- WebSocket
local ws = nil

-- Load peripherals
monitor = f.periphSearch("monitor")
reactor = f.periphSearch("draconic_reactor")

-- Flow gate detection functions
function detectFlowGates()
    local gates = {peripheral.find("flow_gate")}
    if #gates < 2 then
        error("Error: Less than 2 flow gates detected!")
        return nil, nil, nil, nil
    end

    print("Please set input flow gate to **10 RF/t** manually.")

    local inputGate, outputGate, inputName, outputName
    while not inputGate do
        sleep(1)
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
        return nil, nil, nil, nil
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
    if not fs.exists("flowgate_names.txt") then return nil, nil, nil, nil end
    local file = fs.open("flowgate_names.txt", "r")
    local inputName = file.readLine()
    local outputName = file.readLine()
    file.close()
    if peripheral.isPresent(inputName) and peripheral.isPresent(outputName) then
        return peripheral.wrap(inputName), peripheral.wrap(outputName), inputName, outputName
    end
    return nil, nil, nil, nil
end

function setupFlowGates()
    local inputFluxgate, outputFluxgate, inputName, outputName = loadFlowGateNames()
    if not inputFluxgate or not outputFluxgate then
        inputFluxgate, outputFluxgate, inputName, outputName = detectFlowGates()
        if inputFluxgate and outputFluxgate then
            saveFlowGateNames(inputName, outputName)
        else
            error("Flow gate setup failed! Set input to 10 RF/t before running again!")
        end
    end
    return inputFluxgate, outputFluxgate
end

inputFluxgate, fluxgate = setupFlowGates()

if not monitor then error("No monitor found") end
if not fluxgate then error("No flow gate found") end
if not inputFluxgate then error("No input flow gate found") end
if not reactor then error("No reactor found") end

monX, monY = monitor.getSize()
mon = {monitor=monitor, X=monX, Y=monY}
f.firstSet(mon)

-- Monitor clear function
function mon.clear()
    mon.monitor.setBackgroundColor(colors.black)
    mon.monitor.clear()
    mon.monitor.setCursorPos(1,1)
    button.screen()
end

-- Save/load config
function save_config()
    local sw = fs.open("reactorconfig.txt","w")
    sw.writeLine(autoInputGate)
    sw.writeLine(curInputGate)
    sw.close()
end

function load_config()
    if not fs.exists("reactorconfig.txt") then
        save_config()
    else
        local sr = fs.open("reactorconfig.txt","r")
        autoInputGate = tonumber(sr.readLine())
        curInputGate = tonumber(sr.readLine())
        sr.close()
    end
end
load_config()

-- Terminal drawing functions
local lastTerminalValues = {}
function drawTerminalText(x, y, label, newValue)
    local key = label
    if lastTerminalValues[key] ~= newValue then
        term.setCursorPos(x, y)
        term.clearLine()
        term.write(label .. ": " .. newValue)
        lastTerminalValues[key] = newValue
    end
end

-- Status mapping
function reactorStatus(r)
    local statusTable = {
        running = {"Online", colors.green},
        cold = {"Offline", colors.gray},
        warming_up = {"Charging", colors.orange},
        cooling = {"Cooling Down", colors.blue},
        stopping = {"Shutting Down", colors.red}
    }
    return statusTable[r] or statusTable["stopping"]
end

-- Reactor safety
function checkReactorSafety(ri)
    local fuelPercent = 100 - math.ceil(ri.fuelConversion / ri.maxFuelConversion * 10000) * 0.01
    local fieldPercent = math.ceil(ri.fieldStrength / ri.maxFieldStrength * 10000) * 0.01

    if fuelPercent <= 10 then emergencyShutdown("Fuel Low! Refuel Now!") end
    if fieldPercent <= lowFieldPer and ri.status == "running" then
        emergencyShutdown("Field Strength Below "..lowFieldPer.."%!")
        reactor.chargeReactor()
        emergencyCharge = true
    end
    if ri.temperature > maxTemp then
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

-- Menu/UI functions
local MenuText = "Loading..."
function clearMenuArea()
    for i = 26, monY-1 do f.draw_line(mon, 2, i, monX-2, colors.black) end
    button.clearTable()
    f.draw_line(mon, 2, 26, monX-2, colors.gray)
    f.draw_line(mon, 2, monY-1, monX-2, colors.gray)
    f.draw_line_y(mon, 2, 26, monY-1, colors.gray)
    f.draw_line_y(mon, monX-1, 26, monY-1, colors.gray)
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

function rebootSystem() os.reboot() end

function buttonControls()
    if currentMenu == "controls" then return end
    currentMenu = "controls"
    MenuText = "CONTROLS"
    clearMenuArea()
    local sLength = 6+(string.len("Toggle Reactor")+1)
    button.setButton("toggle", "Toggle Reactor", toggleReactor, 6, 28, sLength, 30, 0, 0, colors.blue)
    local sLength2 = (sLength+12+(string.len("Reboot"))+1)
    button.setButton("reboot", "Reboot", rebootSystem, sLength+12, 28, sLength2, 30, 0, 0, colors.blue)
    local sLength3 = 4+(string.len("Back")+1)
    button.setButton("back", "Back", buttonMain, 4, 32, sLength3, 34, 0, 0, colors.blue)
    button.screen()
end

-- Output adjustment buttons
function changeOutputValue(num, val)
    local cFlow = fluxgate.getSignalLowFlow()
    if val == 1 then cFlow = cFlow+num else cFlow = cFlow-num end
    fluxgate.setSignalLowFlow(cFlow)
    updateReactorInfo()
end

function outputMenu()
    if currentMenu == "output" then return end
    currentMenu = "output"
    MenuText = "OUTPUT"
    clearMenuArea()
    local buttonData = {
        {label=">>>>", value=1000000, changeType=1},
        {label=">>>", value=100000, changeType=1},
        {label=">>", value=10000, changeType=1},
        {label=">", value=1000, changeType=1},
        {label="<", value=1000, changeType=0},
        {label="<<", value=10000, changeType=0},
        {label="<<<", value=100000, changeType=0},
        {label="<<<<", value=1000000, changeType=0},
    }
    local spacing = 2
    local buttonY = 28
    local currentX = monX - 7
    for _, data in ipairs(buttonData) do
        local len = string.len(data.label)+1
        local startX = currentX - len
        local endX = startX + len
        button.setButton(data.label, data.label, changeOutputValue, startX, buttonY, endX, buttonY+2, data.value, data.changeType, colors.blue)
        currentX = currentX - len - spacing
    end
    local backLength = 4 + string.len("Back")+1
    button.setButton("back", "Back", buttonMain, 4, 32, backLength, 34, 0, 0, colors.blue)
    button.screen()
end

function buttonMain()
    if currentMenu == "main" then return end
    currentMenu = "main"
    MenuText = "MAIN MENU"
    clearMenuArea()
    local sLength = 4+(string.len("Controls")+1)
    button.setButton("controls", "Controls", buttonControls, 4, 28, sLength, 30, 0, 0, colors.blue)
    local sLength2 = (sLength+13+(string.len("Output")+1))
    button.setButton("output", "Output", outputMenu, sLength+13, 28, sLength2, 30, 0, 0, colors.blue)
    button.screen()
end

-- Reactor display screen
local lastValues = {}
function reactorInfoScreen()
    mon.clear()
    f.draw_text(mon, 2, 38, "Made by: StormFusions  v"..version, colors.gray, colors.black)
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

    while true do
        updateReactorInfo()
        sendReactorData() -- <-- Send data to WebSocket
        sleep(1)
    end
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

function updateReactorInfo()
    ri = reactor.getReactorInfo()
    if not ri then return end
    drawUpdatedText(4, 4, "Status:", reactorStatus(ri.status)[1], reactorStatus(ri.status)[2])
    drawUpdatedText(4, 5, "Generation:", f.format_int(ri.generationRate).." rf/t", colors.lime)
    drawUpdatedText(4, 7, "Temperature:", f.format_int(ri.temperature).."C", getTempColor(ri.temperature))
    drawUpdatedText(4, 9, "Output Gate:", f.format_int(fluxgate.getSignalLowFlow()).." rf/t", colors.lightBlue)
    drawUpdatedText(4, 10, "Input Gate:", f.format_int(inputFluxgate.getSignalLowFlow()).." rf/t", colors.lightBlue)
    drawUpdatedText(4, 12, "Energy Saturation:", getPercentage(ri.energySaturation, ri.maxEnergySaturation).."%", colors.green)
    f.progress_bar(mon, 4, 13, monX-7, getPercentage(ri.energySaturation, ri.maxEnergySaturation), 100, colors.green, colors.lightGray)
    drawUpdatedText(4, 15, "Field Strength:", getPercentage(ri.fieldStrength, ri.maxFieldStrength).."%", getFieldColor(getPercentage(ri.fieldStrength, ri.maxFieldStrength)))
    f.progress_bar(mon, 4, 16, monX-7, getPercentage(ri.fieldStrength, ri.maxFieldStrength), 100, getFieldColor(getPercentage(ri.fieldStrength, ri.maxFieldStrength)), colors.lightGray)
    drawUpdatedText(4, 18, "Fuel:", 100 - getPercentage(ri.fuelConversion, ri.maxFuelConversion).."%", getFuelColor(100 - getPercentage(ri.fuelConversion, ri.maxFuelConversion)))
    f.progress_bar(mon, 4, 19, monX-7, 100 - getPercentage(ri.fuelConversion, ri.maxFuelConversion), 100, getFuelColor(100 - getPercentage(ri.fuelConversion, ri.maxFuelConversion)), colors.lightGray)
    checkReactorSafety(ri)
end

-- Reactor control loop
function reactorControl()
    while true do
        local ri = reactor.getReactorInfo()
        if not ri then sleep(1) goto continue end

        local i = 1
        for k,v in pairs(ri) do
            drawTerminalText(1, i, k, tostring(v))
            i = i+1
        end
        i = i+1
        drawTerminalText(1, i, "Output Gate", fluxgate.getSignalLowFlow()) 
        i = i+1
        drawTerminalText(1, i, "Input Gate", inputFluxgate.getSignalLowFlow())

        -- Reactor control logic
        if emergencyCharge then reactor.chargeReactor() end
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
            local fluxval = autoInputGate == 1 and ri.fieldDrainRate / (1 - (targetStrength/100)) or curInputGate
            i = i+1
            drawTerminalText(1, i, "Target Gate", fluxval)
            inputFluxgate.setSignalLowFlow(fluxval)
        end

        sleep(0.2)
        ::continue::
    end
end

-- WebSocket functions
function loadWebSocketUrl()
    local fileName = "websocket_url.txt"
    if not fs.exists(fileName) then
        local file = fs.open(fileName, "w")
        file.writeLine("ws://localhost:3000")
        file.close()
        return "ws://localhost:3000"
    end
    local file = fs.open(fileName, "r")
    local url = file.readLine()
    file.close()
    return url
end

local renderUrl = loadWebSocketUrl()

function connectWebSocket()
    ws, err = http.websocket(renderUrl)
    if not ws then
        print("WebSocket failed: " .. tostring(err))
        return false
    end
    print("Connected to WebSocket!")
    return true
end

connectWebSocket()

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

function listenWebSocket()
    while true do
        if ws then
            local msg = ws.receive()
            if msg then
                local ok, decoded = pcall(textutils.unserializeJSON, msg)
                if ok and type(decoded) == "table" then
                    if decoded.command == "start" then
                        reactor.activateReactor()
                    elseif decoded.command == "stop" then
                        reactor.stopReactor()
                    elseif decoded.command == "setFlow" and decoded.value then
                        inputFluxgate.setSignalLowFlow(decoded.value)
                    end
                end
            end
        else
            sleep(5)
            connectWebSocket()
        end
        sleep(0.5)
    end
end

-- Start everything in parallel
mon.clear()
mon.monitor.setTextScale(0.5)
buttonMain()
parallel.waitForAny(reactorInfoScreen,reactorControl, button.clickEvent,listenWebSocket)
