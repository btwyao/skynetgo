local c = require "skynet.core"
local skynet = require "skynet"
require "skynet.manager"	-- import manager apis

local M = {
    PTYPE_TELL = 100,
    PTYPE_ASK = 101,
}

local worker = nil
local call_session = nil
local call_out_session = nil
local wait_news = false

local function yield_call(session, time_session)
    call_session, call_out_session = session, time_session
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
    if call_session and session == call_session then
        call_session, call_out_session = nil
        worker(true, msg, sz)
    elseif call_out_session and session == call_out_session then
        call_session, call_out_session = nil
        worker(false)
    end
end

register_proto {
    name = "response",
    id = skynet.PTYPE_RESPONSE,
    dispatch = resume_call,
}

local news_queue = {}

local function push_news(session, source, msg, sz, prototype)
	local p = proto[prototype]
    local news = {session = session, source = source, prototype = prototype, p.unpack(msg, sz)}  -- msg在cb后就会free,所以只能存unpack后的数据
    table.insert(news_queue, news)
    if wait_news then
        wait_news = false
        worker()
    end
end

local function lua_dispatch(session, source, msg, sz)
    push_news(session, source, msg, sz, skynet.PTYPE_LUA)
end

register_proto {
    name = "lua",
    id = skynet.PTYPE_LUA,
    pack = c.pack,
    unpack = c.unpack,
    dispatch = lua_dispatch,
}

local function tell_dispatch(session, source, msg, sz)
    push_news(session, source, msg, sz, M.PTYPE_TELL)
end

register_proto {
    name = "tell",
    id = M.PTYPE_TELL,
    pack = c.pack,
    unpack = c.unpack,
    dispatch = tell_dispatch,
}

local function ask_dispatch(session, source, msg, sz)
    push_news(session, source, msg, sz, M.PTYPE_ASK)
end

register_proto {
    name = "ask",
    id = M.PTYPE_ASK,
    pack = c.pack,
    unpack = c.unpack,
    dispatch = ask_dispatch,
}

local function error_dispatch(session, source, msg, sz)
    local session_type = type(call_session)
    if session_type == "number" and session == call_session then
        call_session = nil
        worker(false)
    elseif session_type == "table" and session == call_session[1] then
        call_session = nil
        worker(false)
    end
end

register_proto {
    name = "error",
    id = skynet.PTYPE_ERROR,
    dispatch = error_dispatch,
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
    local succ, err = pcall(worker)
    if not succ then
        skynet.error(tostring(err))
        M.exit()
    end
end

local function call(ti, addr, typename, ...)
    local p = proto[typename]
	local session = c.send(addr, p.id , nil , p.pack(...))
	if session == nil then
        return
	end

    local time_session
    if ti and ti > 0 then
        time_session = c.intcommand("TIMEOUT",ti)
        assert(time_session)
    end
    local succ, msg, sz = yield_call(session, time_session)
    if succ then
        return true, p.unpack(msg,sz)
    end
end

function M.tell(ti, addr, ...)
    return call(ti, addr, "tell", ...)
end

function M.ask(ti, addr, ...)
    return call(ti, addr, "ask", ...)
end

function M.sleep(ti)
	local session = c.intcommand("TIMEOUT",ti)
	assert(session)
	yield_call(session)
end

local ret_session_map = {}

function M.get_news()
    if #news_queue == 0 then
        yield_get_news()
    end
    local news = table.remove(news_queue, 1)
    local session, source, prototype = news.session, news.source, news.prototype

    if news.session ~= 0 then
        if prototype ~= M.PTYPE_TELL then
            ret_session_map[session] = source
        else
            c.send(source, skynet.PTYPE_RESPONSE, session, "")
        end
    end
    return news
end

function M.ret(news, ...)
    if not ret_session_map[news.session] then
        return
    end

    local session, source, prototype = news.session, news.source, news.prototype
    ret_session_map[session] = nil
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
    for session, source in pairs(ret_session_map) do
        c.send(source, skynet.PTYPE_ERROR, session, "")
    end
    ret_session_map = {}
	c.command("EXIT")
end

return M
