-- Offline tests of the actual GUI snapshot branch and client upload function.
local handlers, uploads, messages = {}, {}, {}
local failure, allocated, released, serverRequests, cameraMoves
root, resourceRoot = {}, {}
function addEvent() end
function addEventHandler(name, _, fn) handlers[name] = fn end
function setTimer() return {} end
function guiGetScreenSize() return 1920, 1080 end
function getTickCount() return 1000 end
function isElement(el) return type(el) == 'table' end
function dxCreateScreenSource(w, h)
    assert(w == 480 and h == 270)
    if failure == 'create' then return false end
    allocated = allocated + 1
    return {}
end
function dxUpdateScreenSource(_, immediate)
    assert(immediate == true)
    return failure ~= 'capture'
end
function dxGetTexturePixels()
    if failure == 'pixels' then return false end
    return 'pixels'
end
function destroyElement() released = released + 1 end
function dxConvertPixels(pixels, format, quality)
    assert(pixels == 'pixels' and format == 'jpeg' and quality == 85)
    if failure == 'encode' then return false end
    return 'jpeg'
end
function triggerLatentServerEvent(name, bandwidth, _, _, cat, id, data)
    assert(name == 'vmm:uploadPreview' and bandwidth == 1500000)
    uploads[#uploads + 1] = { cat, id, data }
    return failure ~= 'upload'
end
function triggerServerEvent() serverRequests = serverRequests + 1 end
function setCameraMatrix() cameraMoves = cameraMoves + 1 end
local hud, chat
function setPlayerHudComponentVisible(_, visible) hud = visible end
function showChat(visible) chat = visible end
dofile('config.lua')
dofile('client.lua')
VMM.toast = function(text, kind) messages[#messages + 1] = { text, kind } end
dofile('gui.lua')
local function upvalue(fn, wanted)
    for i = 1, 100 do
        local name, value = debug.getupvalue(fn, i)
        if not name then break end
        if name == wanted then return value end
    end
    error('Missing upvalue: ' .. wanted)
end
local render = upvalue(handlers.onClientRender, 'renderPreview')
local pv = upvalue(render, 'pv')
local function reset(step)
    failure, allocated, released, serverRequests, cameraMoves = step, 0, 0, 0, 0
    uploads, messages, hud, chat = {}, {}, false, false
    pv.active, pv.veh, pv.snap, pv.hid, pv.snapWait = true, {}, 1, true, nil
    pv.mod = { cat = 'infernus', id = 'example' }
end
assert(Config.Preview.snapshotMode == 'client')
reset()
handlers.onClientPreRender(16)
assert(cameraMoves == 0, 'camera moved between click and capture')
render(1000)
assert(#uploads == 1 and uploads[1][2] == 'example' and uploads[1][3] == 'jpeg')
assert(serverRequests == 0, 'local capture waits for a server request')
assert(pv.snap == 0 and not pv.snapWait and not pv.hid and hud and chat)
assert(allocated == 1 and released == 1)
assert(messages[1][2] == 'info', 'capture must not claim server save completion')
for _, step in ipairs({ 'create', 'capture', 'pixels', 'encode', 'upload' }) do
    reset(step)
    render(1000)
    assert(pv.snap == 0 and not pv.snapWait and not pv.hid and hud and chat, step .. ' left UI hidden')
    assert(allocated == released, step .. ' leaked screen source')
    assert(messages[1][2] == 'error', step .. ' did not report failure')
end
reset()
Config.Preview.snapshotMode = 'server'
render(1000)
assert(serverRequests == 1 and #uploads == 0 and pv.snapWait)
VMM.onSnapshotDone(true)
assert(not pv.snapWait and hud and chat)
print('Snapshot checks passed: one-frame capture, background upload, cleanup and server fallback.')
