-- Offline lifecycle regression checks. Real MTA rendering still needs an ingame test.
local handlers, calls, elements = {}, {}, {}
local failure, serial = nil, 0
resourceRoot = {}
Config = { CachePrefix = 'cache_' }
function addEvent() end
function addEventHandler(name, _, fn) handlers[name] = fn end
function getTickCount() return 1 end
function outputDebugString(message) calls[#calls + 1] = 'log:' .. message end
local function operation(name, mid)
    calls[#calls + 1] = name .. (mid and (':' .. mid) or '')
    return failure ~= name
end
local function element(kind)
    if not operation('load' .. kind) then return false end
    serial = serial + 1
    local el = { kind = kind, serial = serial }
    elements[el] = true
    return el
end
function isElement(el) return elements[el] == true end
function destroyElement(el)
    assert(elements[el], 'double destroy')
    calls[#calls + 1] = 'destroy' .. el.kind
    elements[el] = nil
    return true
end
function engineLoadTXD() return element('TXD') end
function engineLoadDFF() return element('DFF') end
function engineLoadCOL() return element('COL') end
function engineImportTXD(_, mid) return operation('importTXD', mid) end
function engineReplaceCOL(_, mid)
    assert(mid > 611 or (mid >= 321 and mid <= 399), 'COL applied to vehicle/ped')
    return operation('replaceCOL', mid)
end
function engineReplaceModel(_, mid) return operation('replaceDFF', mid) end
function engineRestoreModel(mid) return operation('restoreDFF', mid) end
function engineRestoreCOL(mid)
    assert(mid > 611 or (mid >= 321 and mid <= 399), 'COL restored on vehicle/ped')
    return operation('restoreCOL', mid)
end
function dxCreateTexture() return element('Texture') end
function dxCreateShader() return element('Shader') end
function dxSetShaderValue() return operation('setShader') end
function engineApplyShaderToWorldTexture() return operation('applyShader') end
dofile('client.lua')

local function info(entries)
    return { entries = entries, files = {
        ['car.txd'] = { hash = 'txd', ext = 'txd' },
        ['car.dff'] = { hash = 'dff', ext = 'dff' },
        ['car.col'] = { hash = 'col', ext = 'col' },
        ['light.png'] = { hash = 'png', ext = 'png' },
    } }
end
local function model(mid)
    return { kind = 'model', models = { mid }, txd = 'car.txd', dff = 'car.dff', col = 'car.col' }
end
local function texture()
    return { kind = 'texture', image = 'light.png', names = { 'vehiclelights128' } }
end
local car = info({ model(411) })
local function position(call)
    for i, name in ipairs(calls) do if name == call then return i end end
end
local function noLeaks()
    assert(next(elements) == nil, 'engine elements leaked')
end
assert(VMM.loadIntoGame('infernus', 'good', car))
assert(position('importTXD:411') < position('loadDFF'), 'DFF loaded before TXD import')
assert(not position('loadCOL'), 'standalone vehicle COL loaded')
assert(VMM.loadedKey('infernus') == 'infernus/good')
VMM.unloadCategory('infernus')
assert(position('restoreDFF:411') < position('destroyDFF'))
assert(position('destroyDFF') < position('destroyTXD'))
noLeaks()

for _, step in ipairs({ 'loadTXD', 'importTXD', 'loadDFF', 'replaceDFF' }) do
    calls, failure = {}, step
    assert(not VMM.loadIntoGame('infernus', 'broken', car), step .. ' accepted')
    assert(VMM.loadedKey('infernus') == nil, 'failed mod marked loaded')
    if step == 'loadTXD' then assert(not position('loadDFF')) end
    noLeaks()
end
failure, calls = nil, {}
assert(VMM.loadIntoGame('objects', 'good', info({ model(1337) })))
assert(position('replaceCOL:1337') < position('importTXD:1337'))
assert(position('importTXD:1337') < position('loadDFF'))
VMM.unloadCategory('objects')
noLeaks()
for _, step in ipairs({ 'loadCOL', 'replaceCOL' }) do
    failure = step
    assert(not VMM.loadIntoGame('objects', 'bad', info({ model(1337) })))
    noLeaks()
end
failure, calls = nil, {}
assert(VMM.loadIntoGame('wheels', 'pack', info({ model(1073), model(1074) })))
local txdLoads = 0
for _, call in ipairs(calls) do if call == 'loadTXD' then txdLoads = txdLoads + 1 end end
assert(txdLoads == 1, 'shared TXD loaded more than once')
VMM.unloadCategory('wheels')
noLeaks()

-- Texture-preview failure must preserve an existing vehicle model in that category.
assert(VMM.loadIntoGame('infernus', 'good', car))
for _, step in ipairs({ 'loadTexture', 'loadShader', 'setShader', 'applyShader' }) do
    failure = step
    assert(not VMM.loadIntoGame('infernus', 'preview', info({ texture() }), { texTarget = {}, skipModels = true }))
    assert(VMM.loadedKey('infernus') == 'infernus/good')
    local count = 0
    for _ in pairs(elements) do count = count + 1 end
    assert(count == 2, 'preview failure leaked elements or removed active model')
end
failure = nil
VMM.unloadCategory('infernus')
noLeaks()

local mixed = info({ model(411), texture() })
assert(VMM.loadIntoGame('infernus', 'mixed', mixed, { skipTextures = true }))
assert(not VMM.loadedKey('infernus'), 'partial preview marked fully activated')
VMM.unloadCategory('infernus')
noLeaks()

-- Failed activation restores the previous committed mod, without committing the failure.
VMM.fetchMod = function(_, id, cb)
    failure = id == 'broken' and 'replaceDFF' or nil
    cb(true, car)
end
handlers['vmm:apply']('infernus', 'good', 'local')
assert(VMM.committed('infernus') == 'good')
handlers['vmm:apply']('infernus', 'broken', 'local')
assert(VMM.committed('infernus') == 'good')
assert(VMM.loadedKey('infernus') == 'infernus/good')
handlers['vmm:unapply']('infernus')
noLeaks()
print('Loader regression checks passed: ordering, failures, cleanup, previews, shared TXD, rollback.')
