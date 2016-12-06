local skynetgo = require "skynetgo"

skynetgo.start(function()
    local service = skynetgo.newservice("test_base")
    local ret = skynetgo.call(service, "lua", os.date())
    print(os.date(), ret)
    local suc, ret = skynetgo.tcall(300, service, "lua", os.date())
    print(os.date(), suc, ret)
    skynetgo.send(service, "lua", os.date())
end)
