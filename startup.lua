local libURL = "https://raw.githubusercontent.com/SkyNetCloud/Draconic-ComputerCraft-Program/main/lib/f.lua"
local libURL2 = "https://raw.githubusercontent.com/SkyNetCloud/Draconic-ComputerCraft-Program/main/lib/button.lua"
local startupURL = "https://raw.githubusercontent.com/SkyNetCloud/Draconic-ComputerCraft-Program/main/reactor.lua"
local lib, lib2, startup
local libFile, lib2File, startupFile
 
fs.makeDir("lib")
 
lib = http.get(libURL)
libFile = lib.readAll()
 
if fs.exists("lib/f") == false then
    local file1 = fs.open("lib/f", "w")
    file1.write(libFile)
    file1.close()
    print("API F downloaded")
else
    local file1 = fs.open("lib/f", "r")
    local f = file1.readAll()
    if libFile ~= f then
        file1.close()
        local file2 = fs.open("lib/f", "w")
        file2.write(libFile)
        file2.close()
        
        print("API F updating...")
    else
        file1.close()
        print("API F up to date")
    end
end
 
lib2 = http.get(libURL2)
lib2File = lib2.readAll()
 
if fs.exists("lib/button") == false then
    local file1 = fs.open("lib/button", "w")
    file1.write(lib2File)
    file1.close()
    print("API Button downloaded")
else
    local file1 = fs.open("lib/button", "r")
    local b = file1.readAll()
    if lib2File ~= b then
        file1.close()
        local file2 = fs.open("lib/button", "w")
        file2.write(lib2File)
        file2.close()
        
        print("API Button updating...")
    else
        file1.close()
        print("API Button up to date")
    end
end
 
startup = http.get(startupURL)
startupFile = startup.readAll()
 
if fs.exists("reactor") == false then
    local file1 = fs.open("reactor", "w")
    file1.write(startupFile)
    file1.close()
    print("Reactor File downloaded")
else
    local file1 = fs.open("reactor", "r")
    local reactor = file1.readAll()
    if startupFile ~= reactor then
        file1.close()
        local file2 = fs.open("reactor", "w")
        file2.write(startupFile)
        file2.close()
        
        print("Reactor File updating...")
    else
        file1.close()
        print("Reactor File up to date")
    end
end
 
print("Finished")
print("Starting Program")
sleep(5)
 
shell.run("reactor")
