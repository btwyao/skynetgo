local c = require "skynet.core"
local skynet = require "skynet"
require "skynet.manager"	-- import manager apis

local M = {}

local worker = nil
local call_session = nil
local wait_news = false

local function yield_call(session)
    call_session = session
	return coroutine.yield()
end

local function yield_tcall(session, time_session)
    call_session = {session, time_session}
	return coroutine.yield()
end

local function yield_get_news()
    wait_news = true
	return coroutine.yield()
end

local proto = {}

local function register_proto(p)
    proto[p.id] = p
    proto[p.name] = p
end

local function resume_call(session, source, msg, sz)
    local session_type = type(call_session)
    if session_type == "number" and session == call_session then
        call_session = nil
        worker(msg, sz)
    elseif session_type == "table" and session == call_session[1] then
        call_session = nil
        worker(true, msg, sz)
    elseif session_type == "table" and session == call_session[2] then
        call_session = nil
        worker(false)
    else
	    skynet.error(string.format("Unknown response message %d from %x: %s", session, source, c.tostring(msg,sz)))
    end
end

register_proto {
    name = "response",
    id = skynet.PTYPE_RESPONSE,
    dispatch = resume_call,
}

local news_queue = {}

local function process_news(session, source, msg, sz, prototype)
	local p = proto[prototype]
    local news = {session = session, source = source, prototype = prototype, p.unpack(msg, sz)}  -- msg在cb后就会free,所以只能存unpack后的数据
    table.insert(news_queue, news)
    if wait_news then
        wait_news = false
        worker()
    end
end

register_proto {
    name = "lua",
    id = skynet.PTYPE_LUA,
    pack = c.pack,
    unpack = c.unpack,
    dispatch = process_news,
}

local function raw_dispatch_message(prototype, msg, sz, session, source)
    local p = proto[prototype]
    if p and p.dispatch then
        p.dispatch(session, source, msg, sz, prototype)
    elseif session ~= 0 then
        c.send(source, skynet.PTYPE_ERROR, session, "")
    else
	    skynet.error(string.format("Unknown request message %d from %x (%s): %s", session, source, prototype, c.tostring(msg,sz)))
    end
end

local function dispatch_message(...)
	local succ, err = pcall(raw_dispatch_message, ...)
    if not succ then
        skynet.error(tostring(err))
        M.exit()
    end
end

function M.start(start_func)
    c.callback(dispatch_message)
    worker = coroutine.wrap(function()
        start_func()
        M.exit()
    end)
    worker()
end

function M.send(addr, typename, ...)
	local p = proto[typename]
	c.send(addr, p.id, 0, p.pack(...))
end

function M.call(addr, typename, ...)
	local p = proto[typename]
	local session = c.send(addr, p.id, nil, p.pack(...))
	if session == nil then
		error("call to invalid address " .. skynet.address(addr))
	end

	local msg, sz = yield_call(session)
	return p.unpack(msg,sz)
end

function M.tcall(ti, addr, typename, ...)
	local p = proto[typename]
	local session = c.send(addr, p.id , nil , p.pack(...))
	if session == nil then
		error("call to invalid address " .. skynet.address(addr))
	end

	local time_session = c.intcommand("TIMEOUT",ti)
	assert(time_session)
    local succ, msg, sz = yield_tcall(session, time_session)
    if succ then
	    return  true, p.unpack(msg,sz)
    end
end

function M.sleep(ti)
	local session = c.intcommand("TIMEOUT",ti)
	assert(session)
	yield_call(session)
end

function M.get_news()
    if #news_queue == 0 then
        yield_get_news()
    end
    return table.remove(news_queue, 1)
end

function M.ret(news, ...)
    local session, source, prototype = news.session, news.source, news.prototype
    if session == 0 then
        return
    end

	local p = proto[prototype]
    local msg, size = p.pack(...)

    local ret = c.send(source, skynet.PTYPE_RESPONSE, session, msg, size) ~= nil
    if not ret then
        -- If the package is too large, returns nil. so we should report error back
        ret = c.send(source, skynet.PTYPE_ERROR, session, "") ~= nil
    end
    if not ret and size ~= nil then
        c.trash(msg, size)
    end
    return ret
end

function M.newservice(...)
	local param = table.concat({...}, " ")
	return skynet.launch("snlua", param)
end

function M.exit()
	c.command("EXIT")
end

return M
