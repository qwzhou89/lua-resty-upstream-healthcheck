local wss_client = require "resty.websocket.client"
local log = ngx.log
local ERR = ngx.ERR
local WARN = ngx.WARN
local DEBUG = ngx.DEBUG
local sub = string.sub
local re_find = ngx.re.find
local new_timer = ngx.timer.at
local shared = ngx.shared
local debug_mode = ngx.config.debug
local concat = table.concat
local tonumber = tonumber
local tostring = tostring
local ipairs = ipairs
local ceil = math.ceil
local spawn = ngx.thread.spawn
local wait = ngx.thread.wait
local pcall = pcall

local _M = {
    _VERSION = '0.05'
}

if not ngx.config
   or not ngx.config.ngx_lua_version
   or ngx.config.ngx_lua_version < 9005
then
    error("ngx_lua 0.9.5+ required")
end

local ok, upstream = pcall(require, "ngx.upstream")
if not ok then
    error("ngx_upstream_lua module required")
end

local ok, new_tab = pcall(require, "table.new")
if not ok or type(new_tab) ~= "function" then
    new_tab = function (narr, nrec) return {} end
end

local set_peer_down = upstream.set_peer_down
local get_primary_peers = upstream.get_primary_peers
local get_backup_peers = upstream.get_backup_peers
local get_upstreams = upstream.get_upstreams

local upstream_checker_statuses = {}
local upstream_types = {}

local function warn(...)
    log(WARN, "healthcheck: ", ...)
end

local function errlog(...)
    log(ERR, "healthcheck: ", ...)
end

local function debug(...)
    -- print("debug mode: ", debug_mode)
    if debug_mode then
        log(DEBUG, "healthcheck: ", ...)
    end
end

local function gen_peer_key(prefix, u, is_backup, id)
    if is_backup then
        return prefix .. u .. ":b" .. id
    end
    return prefix .. u .. ":p" .. id
end

local function set_peer_down_globally(ctx, is_backup, id, value)
    local u = ctx.upstream
    local dict = ctx.dict
    local ok, err = set_peer_down(u, is_backup, id, value)
    if not ok then
        errlog("failed to set peer down: ", err)
    end

    if not ctx.new_version then
        ctx.new_version = true
    end

    local key = gen_peer_key("d:", u, is_backup, id)
    local ok, err = dict:set(key, value)
    if not ok then
        errlog("failed to set peer down state: ", err)
    end
end

local function peer_fail(ctx, is_backup, id, peer)
    debug("peer ", peer.name, " was checked to be not ok")

    local u = ctx.upstream
    local dict = ctx.dict

    local key = gen_peer_key("nok:", u, is_backup, id)
    local fails, err = dict:get(key)
    if not fails then
        if err then
            errlog("failed to get peer nok key: ", err)
            return
        end
        fails = 1

        -- below may have a race condition, but it is fine for our
        -- purpose here.
        local ok, err = dict:set(key, 1)
        if not ok then
            errlog("failed to set peer nok key: ", err)
        end
    else
        fails = fails + 1
        local ok, err = dict:incr(key, 1)
        if not ok then
            errlog("failed to incr peer nok key: ", err)
        end
    end

    if fails == 1 then
        key = gen_peer_key("ok:", u, is_backup, id)
        local succ, err = dict:get(key)
        if not succ or succ == 0 then
            if err then
                errlog("failed to get peer ok key: ", err)
                return
            end
        else
            local ok, err = dict:set(key, 0)
            if not ok then
                errlog("failed to set peer ok key: ", err)
            end
        end
    end

    -- print("ctx fall: ", ctx.fall, ", peer down: ", peer.down,
          -- ", fails: ", fails)

    if not peer.down and fails >= ctx.fall then
        warn("peer ", peer.name, " is turned down after ", fails,
                " failure(s)")
        peer.down = true
        set_peer_down_globally(ctx, is_backup, id, true)
    end
end

local function peer_ok(ctx, is_backup, id, peer)
    debug("peer ", peer.name, " was checked to be ok")

    local u = ctx.upstream
    local dict = ctx.dict

    local key = gen_peer_key("ok:", u, is_backup, id)
    local succ, err = dict:get(key)
    if not succ then
        if err then
            errlog("failed to get peer ok key: ", err)
            return
        end
        succ = 1

        -- below may have a race condition, but it is fine for our
        -- purpose here.
        local ok, err = dict:set(key, 1)
        if not ok then
            errlog("failed to set peer ok key: ", err)
        end
    else
        succ = succ + 1
        local ok, err = dict:incr(key, 1)
        if not ok then
            errlog("failed to incr peer ok key: ", err)
        end
    end

    if succ == 1 then
        key = gen_peer_key("nok:", u, is_backup, id)
        local fails, err = dict:get(key)
        if not fails or fails == 0 then
            if err then
                errlog("failed to get peer nok key: ", err)
                return
            end
        else
            local ok, err = dict:set(key, 0)
            if not ok then
                errlog("failed to set peer nok key: ", err)
            end
        end
    end

    if peer.down and succ >= ctx.rise then
        warn("peer ", peer.name, " is turned up after ", succ,
                " success(es)")
        peer.down = nil
        set_peer_down_globally(ctx, is_backup, id, nil)
    end
end

-- shortcut error function for check_peer()
local function peer_error(ctx, is_backup, id, peer, ...)
    if not peer.down then
        errlog(...)
    end
    peer_fail(ctx, is_backup, id, peer)
end

local function check_peer(ctx, id, peer, is_backup)
    local ok
    local name = peer.name
    local ws_cmd_checks = ctx.ws_cmd_checks

    local wb, err = wss_client:new()
    if not wb then
        errlog("failed to create websocket client: ", err)
        return
    end

    wb:set_timeout(ctx.timeout)

    if peer.host then
        -- print("peer port: ", peer.port)
        ok, err = wb:connect(ctx.type .. "://" .. peer.host .. ":" .. peer.port)
    else
        ok, err = wb:connect(ctx.type .. "://" .. name)
    end

    if not ok then
        if not peer.down then
            errlog("failed to connect to ", name, ": ", err)
        end
        return peer_fail(ctx, is_backup, id, peer)
    end

    math.randomseed(os.time()) 
    local ws_cmd_check = ws_cmd_checks[math.random(#ws_cmd_checks)]    
    local bytes, err = wb:send_text(ws_cmd_check[1])
    if not bytes then
        return peer_error(ctx, is_backup, id, peer,
                          "failed to send command to ", name, ": ", err)
    end

    local cmd_resp, typ, err = wb:recv_frame()
    if not cmd_resp then
        peer_error(ctx, is_backup, id, peer,
                   "failed to receive command response from ", name, ": ", err)
            wb:close()  -- timeout errors and close the websocket.
        return
    end

    local white_words = ws_cmd_check[2]
    if white_words then
        local from, to, err = re_find(cmd_resp, white_words, "joi")
        if err then
            errlog("failed to find white word(s) in command response: ", err)
        end

        if not from then
            peer_error(ctx, is_backup, id, peer,
                       "white words is not found in ", name, "'s command response : ",
                       cmd_resp)
            wb:close()
            return
        end
    end

    local black_words = ws_cmd_check[3]
    if black_words then
        local from, to, err = re_find(cmd_resp, black_words, "joi")
        if err then
            errlog("failed to find black word(s) in command response: ", err)
        end

        if from then
            peer_error(ctx, is_backup, id, peer,
                       "black words is found in ", name, "'s command response : ",
                       cmd_resp)
            wb:close()
            return
        end
    end

    local resp_file, err = io.open("/tmp/wscmd_response.log", "a")
    if resp_file then
        local from, to, err = re_find(cmd_resp, [[\042status\042:\042success\042]], "joi") 
        if err then
            errlog("failed to find white word(s) in command response: ", err)
        end

        if not from then
            resp_file:write("received response from " .. name .. ": " .. cmd_resp)
        end
        resp_file:close()
    else
        errlog("failed to open file in append mode. error message: ",  err)
    end

    peer_ok(ctx, is_backup, id, peer)
    wb:close()
end

local function check_peer_range(ctx, from, to, peers, is_backup)
    for i = from, to do
        check_peer(ctx, i - 1, peers[i], is_backup)
    end
end

local function check_peers(ctx, peers, is_backup)
    local n = #peers
    if n == 0 then
        return
    end

    local concur = ctx.concurrency
    if concur <= 1 then
        for i = 1, n do
            check_peer(ctx, i - 1, peers[i], is_backup)
        end
    else
        local threads
        local nthr

        if n <= concur then
            nthr = n - 1
            threads = new_tab(nthr, 0)
            for i = 1, nthr do

                if debug_mode then
                    debug("spawn a thread checking ",
                          is_backup and "backup" or "primary", " peer ", i - 1)
                end

                threads[i] = spawn(check_peer, ctx, i - 1, peers[i], is_backup)
            end
            -- use the current "light thread" to run the last task
            if debug_mode then
                debug("check ", is_backup and "backup" or "primary", " peer ",
                      n - 1)
            end
            check_peer(ctx, n - 1, peers[n], is_backup)

        else
            local group_size = ceil(n / concur)
            nthr = ceil(n / group_size) - 1

            threads = new_tab(nthr, 0)
            local from = 1
            local rest = n
            for i = 1, nthr do
                local to
                if rest >= group_size then
                    rest = rest - group_size
                    to = from + group_size - 1
                else
                    rest = 0
                    to = from + rest - 1
                end

                if debug_mode then
                    debug("spawn a thread checking ",
                          is_backup and "backup" or "primary", " peers ",
                          from - 1, " to ", to - 1)
                end

                threads[i] = spawn(check_peer_range, ctx, from, to, peers,
                                   is_backup)
                from = from + group_size
                if rest == 0 then
                    break
                end
            end
            if rest > 0 then
                local to = from + rest - 1

                if debug_mode then
                    debug("check ", is_backup and "backup" or "primary",
                          " peers ", from - 1, " to ", to - 1)
                end

                check_peer_range(ctx, from, to, peers, is_backup)
            end
        end

        if nthr and nthr > 0 then
            for i = 1, nthr do
                local t = threads[i]
                if t then
                    wait(t)
                end
            end
        end
    end
end

local function upgrade_peers_version(ctx, peers, is_backup)
    local dict = ctx.dict
    local u = ctx.upstream
    local n = #peers
    for i = 1, n do
        local peer = peers[i]
        local id = i - 1
        local key = gen_peer_key("d:", u, is_backup, id)
        local down = false
        local res, err = dict:get(key)
        if not res then
            if err then
                errlog("failed to get peer down state: ", err)
            end
        else
            down = true
        end
        if (peer.down and not down) or (not peer.down and down) then
            local ok, err = set_peer_down(u, is_backup, id, down)
            if not ok then
                errlog("failed to set peer down: ", err)
            else
                -- update our cache too
                peer.down = down
            end
        end
    end
end

local function check_peers_updates(ctx)
    local dict = ctx.dict
    local u = ctx.upstream
    local key = "v:" .. u
    local ver, err = dict:get(key)
    if not ver then
        if err then
            errlog("failed to get peers version: ", err)
            return
        end

        if ctx.version > 0 then
            ctx.new_version = true
        end

    elseif ctx.version < ver then
        debug("upgrading peers version to ", ver)
        upgrade_peers_version(ctx, ctx.primary_peers, false);
        upgrade_peers_version(ctx, ctx.backup_peers, true);
        ctx.version = ver
    end
end

local function get_lock(ctx)
    local dict = ctx.dict
    local key = "l:" .. ctx.upstream

    -- the lock is held for the whole interval to prevent multiple
    -- worker processes from sending the test request simultaneously.
    -- here we substract the lock expiration time by 1ms to prevent
    -- a race condition with the next timer event.
    local ok, err = dict:add(key, true, ctx.interval - 0.001)
    if not ok then
        if err == "exists" then
            return nil
        end
        errlog("failed to add key \"", key, "\": ", err)
        return nil
    end
    return true
end

local function do_check(ctx)
    debug("healthcheck: run a check cycle")

    check_peers_updates(ctx)

    if get_lock(ctx) then
        check_peers(ctx, ctx.primary_peers, false)
        check_peers(ctx, ctx.backup_peers, true)
    end

    if ctx.new_version then
        local key = "v:" .. ctx.upstream
        local dict = ctx.dict

        if debug_mode then
            debug("publishing peers version ", ctx.version + 1)
        end

        dict:add(key, 0)
        local new_ver, err = dict:incr(key, 1)
        if not new_ver then
            errlog("failed to publish new peers version: ", err)
        end

        ctx.version = new_ver
        ctx.new_version = nil
    end
end

local function update_upstream_checker_status(upstream, success)
    local cnt = upstream_checker_statuses[upstream]
    if not cnt then
        cnt = 0
    end

    if success then
        cnt = cnt + 1
    else
        cnt = cnt - 1
    end

    upstream_checker_statuses[upstream] = cnt
end

local check
check = function (premature, ctx)
    if premature then
        return
    end

    local ok, err = pcall(do_check, ctx)
    if not ok then
        errlog("failed to run healthcheck cycle: ", err)
    end

    local ok, err = new_timer(ctx.interval, check, ctx)
    if not ok then
        if err ~= "process exiting" then
            errlog("failed to create timer: ", err)
        end

        update_upstream_checker_status(ctx.upstream, false)
        return
    end
end

local function preprocess_peers(peers)
    local n = #peers
    for i = 1, n do
        local p = peers[i]
        local name = p.name

        if name then
            local from, to, err = re_find(name, [[^(.*):\d+$]], "jo", nil, 1)
            if from then
                p.host = sub(name, 1, to)
                p.port = tonumber(sub(name, to + 2))
            end
        end
    end
    return peers
end

function _M.spawn_checker(opts)
    local typ = opts.type
    if not typ then
        return nil, "\"type\" option required"
    end

    if typ ~= "ws" and typ ~= "wss" then
        return nil, "only \"ws/wss\" type is supported right now"
    end

    local ws_cmd_checks = opts.ws_cmd_checks
    if not ws_cmd_checks then
        return nil, "\"ws_cmd_checks\" option required"
    end

    local timeout = opts.timeout
    if not timeout then
        timeout = 1000
    end

    local interval = opts.interval
    if not interval then
        interval = 1
    else
        interval = interval / 1000
        if interval < 0.002 then  -- minimum 2ms
            interval = 0.002
        end
    end
    -- debug("interval: ", interval)

    local concur = opts.concurrency
    if not concur then
        concur = 1
    end

    local fall = opts.fall
    if not fall then
        fall = 5
    end

    local rise = opts.rise
    if not rise then
        rise = 2
    end

    local shm = opts.shm
    if not shm then
        return nil, "\"shm\" option required"
    end

    local dict = shared[shm]
    if not dict then
        return nil, "shm \"" .. tostring(shm) .. "\" not found"
    end

    local u = opts.upstream
    if not u then
        return nil, "no upstream specified"
    end

    local ppeers, err = get_primary_peers(u)
    if not ppeers then
        return nil, "failed to get primary peers: " .. err
    end

    local bpeers, err = get_backup_peers(u)
    if not bpeers then
        return nil, "failed to get backup peers: " .. err
    end

    local ctx = {
        upstream = u,
        type = typ,
        primary_peers = preprocess_peers(ppeers),
        backup_peers = preprocess_peers(bpeers),
        ws_cmd_checks = ws_cmd_checks,
        timeout = timeout,
        interval = interval,
        dict = dict,
        fall = fall,
        rise = rise,
        version = 0,
        concurrency = concur,
    }

    upstream_types[upstream] = typ

    if debug_mode and opts.no_timer then
        check(nil, ctx)

    else
        local ok, err = new_timer(0, check, ctx)
        if not ok then
            return nil, "failed to create timer: " .. err
        end
    end

    update_upstream_checker_status(u, true)

    return true
end

local function gen_peers_status_info(peers, bits, idx)
    local npeers = #peers
    for i = 1, npeers do
        local peer = peers[i]
        bits[idx] = "        "
        bits[idx + 1] = peer.id .. " "
        bits[idx + 2] = peer.name
        if peer.down then
            bits[idx + 3] = " DOWN\n"
        else
            bits[idx + 3] = " up\n"
        end
        idx = idx + 4
    end
    return idx
end

function _M.status_page()
    -- generate an HTML page
    local us, err = get_upstreams()
    if not us then
        return "failed to get upstream names: " .. err
    end

    local n = #us
    local bits = new_tab(n * 20, 0)
    local idx = 1
    for i = 1, n do
        if i > 1 then
            bits[idx] = "\n"
            idx = idx + 1
        end

        local u = us[i]

        bits[idx] = "Upstream "
        bits[idx + 1] = u
        idx = idx + 2

        local ncheckers = upstream_checker_statuses[u]
        if not ncheckers or ncheckers == 0 then
            bits[idx] = " (NO checkers)"
            idx = idx + 1
        end

        bits[idx] = "\n    Primary Peers\n"
        idx = idx + 1

        local peers, err = get_primary_peers(u)
        if not peers then
            return "failed to get primary peers in upstream " .. u .. ": "
                   .. err
        end

        idx = gen_peers_status_info(peers, bits, idx)

        bits[idx] = "    Backup Peers\n"
        idx = idx + 1

        peers, err = get_backup_peers(u)
        if not peers then
            return "failed to get backup peers in upstream " .. u .. ": "
                   .. err
        end

        idx = gen_peers_status_info(peers, bits, idx)
    end
    return concat(bits)
end

function _M.available_servers()
    -- generate an list for available servers
    local us, err = get_upstreams()
    if not us then
        return "failed to get upstream names: " .. err
    end

    local n = #us
    local peers = new_tab(n * 50, 0)
    local idx = 1
    for i = 1, n do
        local u = us[i]
        
        local type = upstream_types[u]
        if not type then
            type = "ws://"
        end

        -- Primary peers
        local peers, err = get_primary_peers(u)
        if not peers then
            return "failed to get primary peers in upstream " .. u .. ": "
                   .. err
        end

        for i = 1, #peers do
            local peer = peers[i]
            if not peer.down then
                peers[idx] = type .. peer.name
                idx = idx + 1
            end
        end

        -- Backup peers
        peers, err = get_backup_peers(u)
        if not peers then
            return "failed to get backup peers in upstream " .. u .. ": "
                   .. err
        end

        for i = 1, #peers do
            local peer = peers[i]
            if not peer.down then
                peers[idx] = "ws://" .. peer.name
                idx = idx + 1
            end
        end
    end
    return peers
end

return _M
