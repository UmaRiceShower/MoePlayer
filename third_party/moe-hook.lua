-- MoePlayer 播放列表钩子:占位条目(moe://ep/<id>)经 on_load hook 交回
-- MoePlayer 实时协商真实流地址后重定向(官方 on_load + stream-open-filename
-- 契约,见 mpv DOCS/man/input.rst "Hooks" 与 "stream-open-filename")。
-- 真实 URL 的条目(起播/已就绪)直接放行,不经过协商。
-- 脚本名默认 = 文件名去扩展("moe-hook",与 mp.get_script_name 一致;
-- mpv 0.41 Lua 无 mp.set_script_name)。
local pending = {}   -- itemId -> hook 对象(defer 后保持)

mp.add_hook("on_load", 50, function(hook)
    local f = mp.get_property("stream-open-filename", "")
    if not f:match("^moe://ep/") then
        return -- 真实地址:正常加载
    end
    local id = f:match("^moe://ep/(.+)")
    if not id or id == "" then
        return
    end
    pending[id] = hook
    hook:defer()
    mp.msg.info("moe-hook: defer " .. id)
    -- 交给 MoePlayer(MpvClient 收 script-message moe-url 事件)
    mp.commandv("script-message", "moe-url", id)
end)

-- MoePlayer 应答:moe-url-ready <id> <url> [subUrl]
-- 同时设置该文件本地选项(外挂字幕),再重定向并继续 hook。
mp.register_script_message("moe-url-ready", function(id, url, subUrl)
    local hook = pending[id]
    if not hook then
        return
    end
    pending[id] = nil
    mp.msg.info("moe-hook: ready " .. id .. " <- " .. url)
    if url and url ~= "" then
        if subUrl and subUrl ~= "" then
            mp.set_property("file-local-options/sub-file", subUrl)
        end
        mp.set_property("stream-open-filename", url)
    end
    -- url 为空 = 协商失败:继续走占位(加载失败,mpv 会跳过该条)。
    hook:cont()
end)
