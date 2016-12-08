local skynetgo = require "skynetgo"

skynetgo.start(function()
    local service = skynetgo.newservice("test_base")
    local suc, ret = skynetgo.tell(0, service, os.date())
    print(os.date(), suc, ret)
    local suc, ret = skynetgo.ask(0, service, os.date())
    print(os.date(), suc, ret)
    local suc, ret = skynetgo.ask(300, service, os.date())
    print(os.date(), suc, ret)
end)
