-- Exercise actual server event handlers without an MTA server.
local handlers, sent = {}, {}
local player = { kind = 'player' }
local rights = {}
root, resourceRoot, client = {}, {}, player
function addEvent() end
function addEventHandler(name, _, callback) handlers[name] = callback end
function addCommandHandler() end
function isElement(el) return el == player end
function getElementType(el) return el.kind end
function getTickCount() return 10000 end
function pathListDir() return {} end
function fileExists() return false end
function outputServerLog() end
function getPlayerAccount() return {} end
function isGuestAccount() return true end
function getPlayerSerial() return 'offline-test-player' end
function hasObjectPermissionTo(_, right) return rights[right] == true end
function triggerClientEvent(_, name, _, ...)
    sent[#sent + 1] = { name = name, args = { ... } }
end
dofile('config.lua')
dofile('shared.lua')
dofile('server.lua')
local function request()
    sent = {}
    handlers['vmm:requestIndex'](false)
    assert(#sent == 1)
    return sent[1]
end
assert(Config.Permission.publicUse == true)
local response = request()
assert(response.name == 'vmm:index', 'guest cannot open public panel')
assert(response.args[3].canGlobal == false, 'public panel granted global rights')
rights[Config.Permission.global] = true
assert(request().args[3].canGlobal == true, 'explicit global right ignored')
rights = {}
Config.Permission.publicUse = false
response = request()
assert(response.name == 'vmm:notify' and response.args[2] == 'denied', 'private mode let guest through')
rights[Config.Permission.use] = true
response = request()
assert(response.name == 'vmm:index' and not response.args[3].canGlobal)
print('Permission checks passed: public guests, private mode, explicit rights, global isolation.')
