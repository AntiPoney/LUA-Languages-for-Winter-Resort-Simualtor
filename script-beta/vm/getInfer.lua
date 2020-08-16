local vm      = require 'vm.vm'
local util    = require 'utility'
local guide   = require 'parser.guide'
local library = require 'library'
local select  = select

local typeSort = {
    ['boolean']  = 1,
    ['string']   = 2,
    ['integer']  = 3,
    ['number']   = 4,
    ['table']    = 5,
    ['function'] = 6,
    ['nil']      = math.maxinteger,
}

NIL = setmetatable({'<nil>'}, { __tostring = function () return 'nil' end })

local function merge(t, b)
    if not t then
        t = {}
    end
    if not b then
        return t
    end
    for i = 1, #b do
        local o = b[i]
        if not t[o] then
            t[o] = true
            t[#t+1] = o
        end
    end
    return t
end

local function alloc(o)
    -- TODO
    assert(o.type)
    if type(o.type) == 'table' then
        local values = {}
        for i = 1, #o.type do
            local sub = {
                type   = o.type[i],
                value  = o.value,
                source = o.source,
            }
            values[i] = sub
            values[sub] = true
        end
        return values
    else
        return {
            [1] = o,
            [o] = true,
        }
    end
end

local function insert(t, o)
    if not o then
        return
    end
    if not t[o] then
        t[o] = true
        t[#t+1] = o
    end
    return t
end

local function checkLiteral(source)
    if source.type == 'string' then
        return alloc {
            type   = 'string',
            value  = source[1],
            source = source,
        }
    elseif source.type == 'nil' then
        return alloc {
            type   = 'nil',
            value  = NIL,
            source = source,
        }
    elseif source.type == 'boolean' then
        return alloc {
            type   = 'boolean',
            value  = source[1],
            source = source,
        }
    elseif source.type == 'number' then
        if math.type(source[1]) == 'integer' then
            return alloc {
                type   = 'integer',
                value  = source[1],
                source = source,
            }
        else
            return alloc {
                type   = 'number',
                value  = source[1],
                source = source,
            }
        end
    elseif source.type == 'integer' then
        return alloc {
            type   = 'integer',
            source = source,
        }
    elseif source.type == 'table' then
        return alloc {
            type   = 'table',
            source = source,
        }
    elseif source.type == 'function' then
        return alloc {
            type   = 'function',
            source = source,
        }
    elseif source.type == '...' then
        return alloc {
            type   = '...',
            source = source,
        }
    end
end

local function inferByCall(results, source)
    if #results ~= 0 then
        return
    end
    if not source.parent then
        return
    end
    if source.parent.type ~= 'call' then
        return
    end
    if source.parent.node == source then
        insert(results, {
            type   = 'function',
            source = source,
        })
        return
    end
end

local function inferByGetTable(results, source)
    if #results ~= 0 then
        return
    end
    local next = source.next
    if not next then
        return
    end
    if next.type == 'getfield'
    or next.type == 'getindex'
    or next.type == 'getmethod'
    or next.type == 'setfield'
    or next.type == 'setindex'
    or next.type == 'setmethod' then
        insert(results, {
            type   = 'table',
            source = source,
        })
    end
end

local function inferByDef(results, source)
    local defs = vm.getDefs(source)
    for _, src in ipairs(defs) do
        local tp = vm.inferValue(src, false)
        if tp then
            merge(results, tp)
        end
    end
end

local function checkLibraryTypes(source)
    if type(source.type) ~= 'table' then
        return nil
    end
    local results = {}
    for i = 1, #source.type do
        insert(results, {
            type = source.type[i],
            source = source,
        })
    end
    return results
end

local function checkLibrary(source)
    local lib = vm.getLibrary(source)
    if not lib then
        return nil
    end
    return alloc {
        type   = lib.type,
        value  = lib.value,
        source = lib,
    }
end

local function checkSpecialReturn(source)
    if source.type ~= 'select' then
        return nil
    end
    local index = source.index
    local call = source.vararg
    if call.type ~= 'call' then
        return nil
    end
    local func = call.node
    local lib = vm.getLibrary(func)
    if not lib then
        return nil
    end
    if lib.special == 'require' then
        local modName = call.args[1]
        if modName and modName.type == 'string' then
            lib = library.library[modName[1]]
            if lib then
                return alloc {
                    type   = lib.type,
                    value  = lib.value,
                    source = lib,
                }
            end
        end
    end
    return nil
end

local function checkLibraryReturn(source)
    if source.type ~= 'select' then
        return nil
    end
    local index = source.index
    local call = source.vararg
    if call.type ~= 'call' then
        return nil
    end
    local func = call.node
    local lib = vm.getLibrary(func)
    if not lib then
        return nil
    end
    if lib.type ~= 'function' then
        return nil
    end
    if not lib.returns then
        return nil
    end
    local rtn = lib.returns[index]
    if not rtn then
        return nil
    end
    if not rtn.type then
        return nil
    end
    if rtn.type == '...' or rtn.type == 'any' then
        return
    end
    return alloc {
        type   = rtn.type,
        value  = rtn.value,
        source = rtn,
    }
end

local function inferByLibraryArg(results, source)
    local args = source.parent
    if not args then
        return
    end
    if args.type ~= 'callargs' then
        return
    end
    local call = args.parent
    if not call then
        return
    end
    local func = call.node
    local index
    for i = 1, #args do
        if args[i] == source then
            index = i
            break
        end
    end
    if not index then
        return
    end
    local lib = vm.getLibrary(func)
    local arg = lib and lib.args and lib.args[index]
    if not arg then
        return
    end
    if not arg.type then
        return
    end
    if arg.type == '...' or arg.type == 'any' then
        return
    end
    return insert(results, {
        type   = arg.type,
        value  = arg.value,
        source = arg,
    })
end

local function hasTypeInResults(results, type)
    for i = 1, #results do
        if results[i].type == 'type' then
            return true
        end
    end
    return false
end

local function inferByUnary(results, source)
    if #results ~= 0 then
        return
    end
    local parent = source.parent
    if not parent or parent.type ~= 'unary' then
        return
    end
    local op = parent.op
    if op.type == '#' then
        -- 会受顺序影响，不检查了
        --if hasTypeInResults(results, 'string')
        --or hasTypeInResults(results, 'integer') then
        --    return
        --end
        insert(results, {
            type   = 'string',
            source = source
        })
        insert(results, {
            type   = 'table',
            source = source
        })
    elseif op.type == '~' then
        insert(results, {
            type   = 'integer',
            source = source
        })
    elseif op.type == '-' then
        insert(results, {
            type   = 'number',
            source = source
        })
    end
end

local function inferByBinary(results, source)
    if #results ~= 0 then
        return
    end
    local parent = source.parent
    if not parent or parent.type ~= 'binary' then
        return
    end
    local op = parent.op
    if op.type == '<='
    or op.type == '>='
    or op.type == '<'
    or op.type == '>'
    or op.type == '^'
    or op.type == '/'
    or op.type == '+'
    or op.type == '-'
    or op.type == '*'
    or op.type == '%' then
        insert(results, {
            type   = 'number',
            source = source
        })
    elseif op.type == '|'
    or     op.type == '~'
    or     op.type == '&'
    or     op.type == '<<'
    or     op.type == '>>'
    -- 整数的可能性比较高
    or     op.type == '//' then
        insert(results, {
            type   = 'integer',
            source = source
        })
    elseif op.type == '..' then
        insert(results, {
            type   = 'string',
            source = source
        })
    end
end

local function inferBySetOfLocal(results, source)
    if source.ref then
        for i = 1, math.min(#source.ref, 100) do
            local ref = source.ref[i]
            if ref.type == 'setlocal' then
                break
            end
            merge(results, vm.getInfers(ref))
        end
    end
end

local function inferBySet(results, source)
    if #results ~= 0 then
        return
    end
    if source.type == 'local' then
        inferBySetOfLocal(results, source)
    elseif source.type == 'setlocal'
    or     source.type == 'getlocal' then
        merge(results, vm.getInfers(source.node))
    end
end

local function mergeFunctionReturns(results, source, index)
    local returns = source.returns
    if not returns then
        return
    end
    for i = 1, #returns do
        local rtn = returns[i]
        if rtn[index] then
            merge(results, vm.getInfers(rtn[index]))
        end
    end
end

local function inferByCallReturn(results, source)
    if source.type ~= 'select' then
        return
    end
    if not source.vararg or source.vararg.type ~= 'call' then
        return
    end
    local node = source.vararg.node
    local nodeValues = vm.getInfers(node)
    if not nodeValues then
        return
    end
    local index = source.index
    for i = 1, #nodeValues do
        local value = nodeValues[i]
        local src = value.source
        if src.type == 'function' then
            mergeFunctionReturns(results, src, index)
        end
    end
end

local function inferByPCallReturn(results, source)
    if source.type ~= 'select' then
        return
    end
    local call = source.vararg
    if not call or call.type ~= 'call' then
        return
    end
    local node = call.node
    local lib = vm.getLibrary(node)
    if not lib then
        return
    end
    local func, index
    if lib.name == 'pcall' then
        func = call.args[1]
        index = source.index - 1
    elseif lib.name == 'xpcall' then
        func = call.args[1]
        index = source.index - 2
    else
        return
    end
    local funcValues = vm.getInfers(func)
    if not funcValues then
        return
    end
    for i = 1, #funcValues do
        local value = funcValues[i]
        local src = value.source
        if src.type == 'function' then
            mergeFunctionReturns(results, src, index)
        end
    end
end

function vm.inferValue(source, infer)
    source = guide.getObjectValue(source) or source
    local results = checkLiteral(source)
                 or checkUnary(source)
                 or checkBinary(source)
                 or checkLibraryTypes(source)
                 or checkLibrary(source)
                 or checkSpecialReturn(source)
                 or checkLibraryReturn(source)
    if results then
        return results
    end
    if not infer then
        return
    end

    results = {}
    inferByLibraryArg(results, source)
    inferByDef(results, source)
    inferBySet(results, source)
    inferByCall(results, source)
    inferByGetTable(results, source)
    inferByUnary(results, source)
    inferByBinary(results, source)
    inferByCallReturn(results, source)
    inferByPCallReturn(results, source)

    if #results == 0 then
        return nil
    end

    return results
end

function vm.checkTrue(source)
    local values = vm.getInfers(source)
    if not values then
        return
    end
    -- 当前认为的结果
    local current
    for i = 1, #values do
        -- 新的结果
        local new
        local v = values[i]
        if v.type == 'nil' then
            new = false
        elseif v.type == 'boolean' then
            if v.value == true then
                new = true
            elseif v.value == false then
                new = false
            end
        end
        if new ~= nil then
            if current == nil then
                current = new
            else
                -- 如果2个结果完全相反，则返回 nil 表示不确定
                if new ~= current then
                    return nil
                end
            end
        end
    end
    return current
end

--- 获取特定类型的字面量值
function vm.getLiteral(source, type)
    local values = vm.getInfers(source)
    if not values then
        return nil
    end
    for i = 1, #values do
        local v = values[i]
        if v.value ~= nil then
            if type == nil or v.type == type then
                return v.value
            end
        end
    end
    return nil
end

function vm.isSameValue(a, b)
    local valuesA = vm.getInfers(a)
    local valuesB = vm.getInfers(b)
    if not valuesA or not valuesB then
        return false
    end
    if valuesA == valuesB then
        return true
    end
    local values = {}
    for i = 1, #valuesA do
        local value = valuesA[i]
        local literal = value.value
        if literal then
            values[literal] = false
        end
    end
    for i = 1, #valuesB do
        local value = valuesA[i]
        local literal = value.value
        if literal then
            if values[literal] == nil then
                return false
            end
            values[literal] = true
        end
    end
    for k, v in pairs(values) do
        if v == false then
            return false
        end
    end
    return true
end

--- 是否包含某种类型
function vm.hasType(source, type)
    local infers = vm.getInfers(source)
    if not infers then
        return false
    end
    for i = 1, #infers do
        local infer = infers[i]
        if infer.type == type then
            return true
        end
    end
    return false
end

function vm.getType(source)
    local infers = vm.getInfers(source)
    return guide.viewInfer(infers)
end

--- 获取对象的值
--- 会尝试穿透函数调用
function vm.getInfers(source)
    if not source then
        return
    end
    return guide.requestInfer(source, vm.interface)
end