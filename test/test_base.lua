local skynetgo = require "skynetgo"

skynetgo.start(function()
    while true do
        local news = skynetgo.get_news()
        skynetgo.sleep(500)
        print(os.date(), table.unpack(news))
        skynetgo.ret(news, "print ok")
    end
end)
