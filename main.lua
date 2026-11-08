--[[
一页壁纸 (OnePage) — KOReader 插件
- 每日从 ONE · 一个 v3 接口取当日图文（照片 + 一句话 + 期号 + 日期），
  在设备本地合成灰阶壁纸，并自动接管 KOReader 锁屏屏保。
- 支持「全屏」与「白底圆角卡」两种壁纸，均可离线重绘。
- 下载在后台子进程执行，网络等待期间不阻塞 KOReader 界面。
- 安装即自动配置屏保（随机图模式 + 专用目录 + 拉伸填充，避免两侧黑边）。
- 唤醒后自动更新；Wi-Fi 重连期间退避重试，连上立即下载。
- 仅保留当日图片与元数据，旧文件自动清理。

调度 / 屏保 / 缓存骨架来自 danxiangli.koplugin，中文排版思路来自
yiyan.koplugin，数据源与字段定义见 docs/api-reference.md。
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local InfoMessage     = require("ui/widget/infomessage")
local logger          = require("logger")
local util            = require("util")
local ffiutil         = require("ffi/util")
local time            = require("ui/time")
local NetworkMgr      = require("ui/network/manager")
local gettext         = require("gettext")

local has_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not has_lfs then
    has_lfs, lfs = pcall(require, "lfs")
end

local OnePage = WidgetContainer:extend{ name = "onepage" }
local active_instance
local active_download
local active_worker
local update_startup_checked = false
local update_needs_restart = false
local update_recovery_path
local scheduler_callback
local schedule_next_check
local pending_download_check = false
local pending_download_opts
local http404_cooldown_date
local http404_cooldown_until
local hard_cooldown_date
local hard_cooldown_until

-- Absolute plugin path, also used by the forked downloader to load the API
-- module (a child process cannot rely on KOReader's package.path).
local PLUGIN_DIR = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"
local SAVE_DIR = "/mnt/us/koreader/screenshots/onepage/"
local WALLPAPER_DIR = SAVE_DIR .. "wallpaper/"
local WALLPAPER_DISPLAY_DIR = WALLPAPER_DIR .. "display/"

-- 一页壁纸按北京时间发布；固定偏移，不依赖设备时区
local UTC_OFFSET = 8 * 3600

local INIT_DELAY       = 8        -- 启动后首次检查延迟（秒）
local RESUME_DELAY     = 2        -- 唤醒后检查延迟（秒）
local CHECK_INTERVAL   = 5 * 60   -- 周期兜底检查（秒）
local MAX_RETRIES      = 6        -- Wi-Fi 重连等待的最大轮数
local RETRY_BASE       = 10       -- 退避基数（秒）
local RETRY_MAX        = 120      -- 单次退避上限（秒）
local HTTP_TIMEOUT     = 20       -- 单次请求超时（秒）
-- One day's fetch is 1 idlist + up to 10 detail probes + 1 image, all serial.
-- The 20s that is fine for a single request is far too tight for that chain.
local DOWNLOAD_TIMEOUT = 60       -- 下载子进程总时限（秒），由父进程强制执行
local UPDATE_TIMEOUT   = 60
local WORKER_POLL_INTERVAL = 0.125
local HTTP404_COOLDOWN = 2 * 3600 -- 今日图未发布 (404) 后的冷却（秒）
-- Failures that will not fix themselves in five minutes: a changed response
-- shape, a CDN migration, a missing JSON decoder, a 4xx other than "not
-- published". Retrying them on the 5-minute loop produced ~144 requests per
-- cycle forever; one probe per hour is enough to notice a fix.
local HARD_FAILURE_COOLDOWN = 3600
local HARD_FAILURE_STATUSES = {
    bad_detail = true,
    invalid_host = true,
    nojson = true,
    -- The CDN dropped the imageMogr2 parameters and served something far
    -- bigger than the thumbnail, or answered with a redirect we refuse to
    -- follow: both stay true for the rest of the day.
    file_too_large = true,
    redirect_error = true,
}
local MIN_JPEG_SIZE    = 1024

local SETTING_AUTO_SCREENSAVER = "onepage_auto_screensaver"
local SETTING_SCREENSAVER_BACKUP = "onepage_screensaver_backup"
local SETTING_WALLPAPER_STYLE = "onepage_wallpaper_style"
local SETTING_CONTRAST = "onepage_contrast"
local WALLPAPER_STYLES = {
    { "fullscreen", gettext("全屏") },
    { "card", gettext("白底圆角卡") },
}
local CONTRAST_STYLES = {
    { "high", gettext("高对比白（默认）") },
    { "classic", gettext("经典灰（官方观感）") },
}

----------------------------------------------------------------------
-- 工具
----------------------------------------------------------------------

-- 按北京时间取“今日”，返回 {year,month,day}, 日期串, 目标路径
local function get_today_info()
    local t = os.date("!*t", os.time() + UTC_OFFSET)
    local date_str = string.format("%04d%02d%02d", t.year, t.month, t.day)
    return t, date_str, SAVE_DIR .. date_str .. ".jpg"
end

local function is_http404_cooling(date_str)
    return http404_cooldown_date == date_str
        and http404_cooldown_until ~= nil
        and os.time() < http404_cooldown_until
end

-- "Not published yet" is a scheduled state; a reshaped response or a dead CDN
-- host is a broken state. They need different cooldowns and different copy.
local function is_hard_failure(status)
    if type(status) ~= "string" then return false end
    if HARD_FAILURE_STATUSES[status] then return true end
    return status:match("^http_4") ~= nil and status ~= "http_404"
end

local function is_hard_cooling(date_str)
    return hard_cooldown_date == date_str
        and hard_cooldown_until ~= nil
        and os.time() < hard_cooldown_until
end

local function start_hard_cooldown(date_str)
    hard_cooldown_date, hard_cooldown_until = date_str, os.time() + HARD_FAILURE_COOLDOWN
end

local function queue_download_check(opts)
    pending_download_check = true
    if opts then
        pending_download_opts = pending_download_opts or {}
        pending_download_opts.notify = pending_download_opts.notify or opts.notify
        pending_download_opts.ignore_cooldown = pending_download_opts.ignore_cooldown or opts.ignore_cooldown
    end
end

local function run_pending_download_check()
    if active_worker or active_download or not pending_download_check then return end
    local instance = active_instance
    if not instance or instance._stopped then
        -- The UI that requested this follow-up was closed. A future instance
        -- has its own startup check, so do not carry stale manual options over.
        pending_download_check = false
        pending_download_opts = nil
        return
    end

    local opts = pending_download_opts
    pending_download_check = false
    pending_download_opts = nil
    instance:_run(opts)
end

local function run_pending_work()
    if active_worker or active_download or update_needs_restart then return end
    local instance = active_instance
    if instance and instance._pending_update then
        local task = instance._pending_update
        instance._pending_update = nil
        task()
    end
    run_pending_download_check()
end

local function show_update_restart(message)
    if update_needs_restart == "restore_error" then
        UIManager:show(InfoMessage:new{
            text = gettext("旧版自动恢复失败，请通过 USB 将备份目录改回 onepage.koplugin：\n")
                .. update_recovery_path,
        })
    elseif update_needs_restart == "sync_error" then
        UIManager:askForRestart(gettext("新版文件已替换，但磁盘写入未能确认。旧版备份已保留，请重启 KOReader 后检查。"))
    else
        UIManager:askForRestart(message or gettext("一页壁纸已安装新版，重启 KOReader 后生效。"))
    end
end

local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close(); return true end
    return false
end

local function is_valid_jpeg(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local head = f:read(2)
    local size = f:seek("end")
    if not size or size < MIN_JPEG_SIZE then
        f:close()
        return false
    end
    -- Require a complete JPEG end marker at EOF, not just a plausible header.
    f:seek("end", -2)
    local tail = f:read(2)
    f:close()
    return head == "\255\216" and tail == "\255\217"
end

local function is_network_available()
    if NetworkMgr and NetworkMgr.isConnected then
        local ok, connected = pcall(NetworkMgr.isConnected, NetworkMgr)
        if ok then return connected == true end
    end
    return false -- 无法确认时按未连接处理，避免无谓请求
end

-- 遍历 SAVE_DIR 中的 jpg 文件
local function each_jpg(callback)
    if not has_lfs then return end
    for f in lfs.dir(SAVE_DIR) do
        if f:match("%.jpg$") and lfs.attributes(SAVE_DIR .. f, "mode") == "file" then
            callback(f)
        end
    end
end

local function latest_cached_image()
    local latest
    each_jpg(function(name)
        if name:match("^%d%d%d%d%d%d%d%d%.jpg$")
            and (not latest or name > latest) and is_valid_jpeg(SAVE_DIR .. name) then
            latest = name
        end
    end)
    return latest and SAVE_DIR .. latest
end

-- 只删除非今日的图片与元数据（SAVE_DIR 由本插件独占，安全）
local function cleanup_old_images(keep_date_str)
    if not has_lfs then return end
    local removed = 0
    for f in lfs.dir(SAVE_DIR) do
        local date = f:match("^(%d%d%d%d%d%d%d%d)%.jpg$") or f:match("^(%d%d%d%d%d%d%d%d)%.json$")
        if date and date ~= keep_date_str and lfs.attributes(SAVE_DIR .. f, "mode") == "file" then
            if os.remove(SAVE_DIR .. f) then removed = removed + 1 end
        end
    end
    if removed > 0 then
        logger.info("一页壁纸: 清理旧缓存", removed, "个文件")
    end
end

-- A previous KOReader process may have exited before its cleanup callback ran.
-- Never scan/delete temporary files while any downloader can still write them.
local function cleanup_temporary_files()
    if active_worker or not has_lfs or lfs.attributes(SAVE_DIR, "mode") ~= "directory" then return end
    for name in lfs.dir(SAVE_DIR) do
        if name:match("^%d%d%d%d%d%d%d%d%.jpg%.tmp$")
            or name:match("^%d%d%d%d%d%d%d%d%.json%.tmp$") then
            local path = SAVE_DIR .. name
            if lfs.attributes(path, "mode") == "file" then
                local ok, err = os.remove(path)
                if not ok then logger.warn("一页壁纸: 清理临时文件失败", path, tostring(err)) end
            end
        end
    end
end

----------------------------------------------------------------------
-- 持久化
----------------------------------------------------------------------

local function is_auto_screensaver_enabled()
    if not G_reader_settings then return true end
    local v = G_reader_settings:readSetting(SETTING_AUTO_SCREENSAVER)
    return v == nil or v == true -- 首次安装默认开启
end

local function wallpaper_style()
    if G_reader_settings and G_reader_settings:readSetting(SETTING_WALLPAPER_STYLE) == "card" then
        return "card"
    end
    return "fullscreen"
end

-- Palette is a sub-option, not a third style: the user only chooses between
-- fullscreen and card, and either one can be rendered in high contrast.
local function wallpaper_contrast()
    if G_reader_settings and G_reader_settings:readSetting(SETTING_CONTRAST) == "classic" then
        return "classic"
    end
    return "high"
end

local function set_auto_screensaver_enabled(enabled)
    if G_reader_settings then
        G_reader_settings:saveSetting(SETTING_AUTO_SCREENSAVER, enabled)
        G_reader_settings:flush()
    end
end

----------------------------------------------------------------------
-- 状态 -> 用户可读消息
----------------------------------------------------------------------

local function status_text(status)
    if status == "ok" then return gettext("一页壁纸已更新")
    elseif status == "exists" then return gettext("今日一页壁纸已存在")
    elseif status == "no_network" then return gettext("无网络连接")
    elseif status == "open_error" then return gettext("无法创建文件（权限或空间不足）")
    elseif status == "network_error" then return gettext("网络请求失败")
    elseif status == "timeout" then return gettext("下载超时")
    elseif status == "file_too_large" then return gettext("图片超过下载大小上限")
    elseif status == "invalid_file" then return gettext("下载文件校验失败")
    elseif status == "invalid_host" then return gettext("图片地址不在受信域名内")
    elseif status == "redirect_error" then return gettext("图片跳转地址不受信任")
    elseif status == "rename_error" then return gettext("文件替换失败")
    elseif status == "write_error" then return gettext("元数据写入失败")
    elseif status == "no_today" then return gettext("今日内容尚未发布")
    elseif status == "bad_detail" then return gettext("接口返回内容不完整")
    elseif status == "decode" or status == "nojson" then return gettext("接口返回无法解析")
    elseif type(status) == "string" and status:match("^http_") then
        return gettext("HTTP 错误: ") .. status:sub(6)
    end
    return gettext("错误: ") .. tostring(status)
end

----------------------------------------------------------------------
-- 下载（后台子进程，tmp + 校验 + 替换）
----------------------------------------------------------------------

-- BOOTTIME includes time spent asleep, and is unaffected by clock changes.
local function worker_now()
    return time.to_s(time.boottime_or_monotonic())
end

-- Keep the worker alive only until its deadline or cancellation. Reaping is
-- nonblocking; the same scheduler services both the worker and normal checks.
local function run_request_in_subprocess(task, callback, timeout)
    local pid, read_fd
    local started, start_err = pcall(function()
        pid, read_fd = ffiutil.runInSubProcess(function(_, child_write_fd)
            local ok, status = pcall(task)
            if not ok then
                logger.warn("一页壁纸: 子进程请求异常", tostring(status))
                status = "network_error"
            end
            if type(status) ~= "string" then
                status = "network_error"
            end
            ffiutil.writeToFD(child_write_fd, status, true)
        end, true)
    end)
    if not started or not pid then
        -- On failure the second return value is an error string, not an fd.
        logger.warn("一页壁纸: 无法启动下载子进程", tostring(start_err or read_fd))
        callback("network_error")
        return nil
    end

    local now = worker_now()
    local worker = {
        pid = pid,
        read_fd = read_fd,
        deadline = now + (timeout or HTTP_TIMEOUT),
        poll_at = now + WORKER_POLL_INTERVAL,
    }

    function worker:cancel(status)
        if self.completed or self.stop_status then return end
        self.stop_status = status or "stale_request"
        ffiutil.terminateSubProcess(self.pid)
        self.poll_at = worker_now() + WORKER_POLL_INTERVAL
        schedule_next_check()
    end

    function worker:poll()
        if self.completed then return end
        if not ffiutil.isSubProcessDone(self.pid) then
            if self.stop_status then
                -- Cancellation may race the child's initial setpgid(). Retry
                -- the nonblocking kill until its process group exists/exits.
                ffiutil.terminateSubProcess(self.pid)
            elseif worker_now() >= self.deadline then
                logger.warn("一页壁纸: 下载超过总时限，终止子进程")
                self:cancel("timeout")
            end
            self.poll_at = worker_now() + WORKER_POLL_INTERVAL
            return
        end

        -- Read only after waitpid confirms exit, so this cannot wait on the
        -- still-running downloader. Release the request lock in the callback
        -- only after the old writer has gone away.
        self.completed = true
        active_worker = nil
        local read_ok, status = pcall(ffiutil.readAllFromFD, self.read_fd)
        self.read_fd = nil
        UIManager:allowStandby()
        if not read_ok or type(status) ~= "string" or status == "" then
            logger.warn("一页壁纸: 无法读取下载子进程结果", tostring(status))
            status = "network_error"
        end
        -- Preserve a completed 404 across UI transitions, even if cancellation
        -- arrived just after the child wrote its result.
        if self.stop_status and not (self.stop_status == "stale_request" and status == "http_404") then
            status = self.stop_status
        end
        -- A throwing callback must not skip temp-file cleanup or wedge the
        -- pending queue.
        local called, callback_error = pcall(callback, status)
        if not called then
            logger.warn("一页壁纸: 结果回调异常", tostring(callback_error))
        end
        cleanup_temporary_files()
        run_pending_work()
    end

    active_worker = worker
    UIManager:preventStandby()
    schedule_next_check()
    return worker
end

local function download_image(date_str, is_active, callback)
    local target = SAVE_DIR .. date_str .. ".jpg"
    local tmp = target .. ".tmp"
    local meta_target = SAVE_DIR .. date_str .. ".json"
    local meta_tmp = meta_target .. ".tmp"

    logger.info("一页壁纸: 请求今日图文", date_str)
    os.remove(tmp)
    os.remove(meta_tmp)

    local completed = false
    local function finish(success, status)
        if completed then return end
        completed = true
        if not success then os.remove(meta_tmp) end
        callback(success, status)
    end

    local function process_result(status)
        if completed then return end
        -- ONE publishes at 06:00 Beijing time. Before that, or on a gap day,
        -- treat "no matching date" like a 404 and reuse the 2h cooldown.
        if status == "no_today" then status = "http_404" end
        if not is_active() then
            -- A 404 still applies to the current date even if its original UI
            -- instance was replaced while the request was in flight.
            local _, current_date = get_today_info()
            if current_date == date_str and status == "http_404" then
                finish(false, "http_404")
            else
                os.remove(tmp)
                finish(false, "stale_request")
            end
            return
        end
        local _, current_date = get_today_info()
        if current_date ~= date_str then
            os.remove(tmp)
            finish(false, "stale_date")
            return
        end
        if status ~= "downloaded" then
            os.remove(tmp)
            finish(false, status or "network_error")
            return
        end

        if not is_valid_jpeg(tmp) then
            logger.warn("一页壁纸: 文件校验失败")
            os.remove(tmp)
            finish(false, "invalid_file")
            return
        end

        -- Avoid committing yesterday's response if midnight passed while the
        -- body was being written and validated.
        local _, date_before_replace = get_today_info()
        if not is_active() or date_before_replace ~= date_str then
            os.remove(tmp)
            finish(false, date_before_replace ~= date_str and "stale_date" or "stale_request")
            return
        end

        local renamed, rerr = os.rename(tmp, target)
        if not renamed then
            logger.warn("一页壁纸: 重命名失败", tostring(rerr))
            os.remove(tmp)
            finish(false, "rename_error")
            return
        end

        -- The renderer reads YYYYMMDD.json next to the JPEG for the quote,
        -- VOL number and category. Without it, it still renders a pure photo.
        if not os.rename(meta_tmp, meta_target) then
            logger.warn("一页壁纸: 元数据写入失败，将退化为纯照片壁纸")
        end

        logger.info("一页壁纸: 完成", target)
        finish(true, "ok")
    end

    local function request_to_tmp()
        -- Runs in the forked child. Load by absolute path: the child cannot
        -- rely on KOReader's package.path being populated.
        local loaded, Api = pcall(dofile, PLUGIN_DIR .. "onepage_api.lua")
        if not loaded or type(Api) ~= "table" then
            logger.warn("一页壁纸: 无法加载接口模块", tostring(Api))
            return "network_error"
        end
        local called, status = pcall(Api.fetch_today, {
            date_str = date_str,
            image_tmp = tmp,
            meta_tmp = meta_tmp,
            timeout = HTTP_TIMEOUT,
            -- Stop probing before the parent's hard kill, so the child can still
            -- clean up its temp files and report "timeout" over the pipe.
            deadline = os.time() + DOWNLOAD_TIMEOUT - 8,
        })
        if not called then
            logger.warn("一页壁纸: 接口请求异常", tostring(status))
            os.remove(tmp)
            os.remove(meta_tmp)
            return "network_error"
        end
        if status ~= "downloaded" then
            os.remove(tmp)
            os.remove(meta_tmp)
            return status or "network_error"
        end
        if not is_valid_jpeg(tmp) then
            logger.warn("一页壁纸: 文件校验失败")
            os.remove(tmp)
            os.remove(meta_tmp)
            return "invalid_file"
        end
        -- Decode while the file is still staged. The parent only promotes a
        -- decodable JPEG, so a bad response cannot evict the previous image.
        local loaded_wallpaper, Wallpaper = pcall(dofile, PLUGIN_DIR .. "onepage_wallpaper.lua")
        if not loaded_wallpaper or type(Wallpaper) ~= "table" then
            logger.warn("一页壁纸: 无法加载渲染模块", tostring(Wallpaper))
            os.remove(tmp)
            os.remove(meta_tmp)
            return "network_error"
        end
        local valid, validation_error = Wallpaper.validate_source(tmp)
        if not valid then
            logger.warn("一页壁纸: 下载的 JPEG 无法解码", tostring(validation_error))
            os.remove(tmp)
            os.remove(meta_tmp)
            return "invalid_file"
        end
        return "downloaded"
    end

    return run_request_in_subprocess(request_to_tmp, function(status)
        local ok, err = pcall(process_result, status)
        if not ok then
            logger.warn("一页壁纸: 处理下载结果失败", tostring(err))
            os.remove(tmp)
            finish(false, "network_error")
        end
    end, DOWNLOAD_TIMEOUT)
end

----------------------------------------------------------------------
-- 插件主体
----------------------------------------------------------------------

function OnePage:init()
    if active_instance then
        active_instance:_cancel_scheduled_work()
    end
    active_instance = self

    self.ui.menu:registerToMainMenu(self)
    self._busy = false
    self._stopped = false
    self._request_generation = (self._request_generation or 0) + 1
    self._last_status = nil
    if update_needs_restart then return end

    local inspect_update = self.path and not update_startup_checked
    local Update, update_paths, verify_updated_wallpaper
    if inspect_update then
        local ok, updater, paths, has_backup = pcall(function()
            local module = require("onepage_update")
            local paths = module.paths(self.path)
            return module, paths, paths and module.has_backup(paths)
        end)
        if ok then
            Update, update_paths, verify_updated_wallpaper = updater, paths, has_backup
        else
            logger.warn("一页壁纸: 检查更新备份失败", tostring(updater))
        end
    end

    local wallpaper_dir_ready = util.makePath(WALLPAPER_DIR)
    cleanup_temporary_files()
    -- When an update is pending verification, exercise the new renderer even
    -- if the previous version left a valid PNG in the cache.
    local _, wallpaper_error = self:_refresh_wallpaper(nil, verify_updated_wallpaper)
    if is_auto_screensaver_enabled() then
        self:_ensure_screensaver_settings()
    else
        -- Finish a disable operation interrupted after restoring values.
        self:_restore_screensaver_settings(false)
    end

    local now = os.time()
    self._startup_at = now + INIT_DELAY
    self._resume_at = nil
    self._retry_at = nil
    self._retry_attempt = nil
    self._retry_opts = nil
    self._loop_at = now + CHECK_INTERVAL
    self:_schedule_loop()
    if inspect_update then
        update_startup_checked = true
        if update_paths then
            local ok, err = pcall(Update.clean_after_start, update_paths, wallpaper_dir_ready and not wallpaper_error)
            if not ok then logger.warn("一页壁纸: 清理更新文件失败", tostring(err)) end
        end
    end
end

-- 请求完成回调：网络等待期间不占用 UI 事件循环。
function OnePage:_download_today(today_str, opts, retry_attempt, notify_failure)
    self:_cancel_retry()
    if active_worker or active_download then
        queue_download_check(opts)
        return
    end

    local request_token = {}
    active_download = request_token
    self._busy = true
    local generation = self._request_generation
    local worker = download_image(today_str, function()
        return not self._stopped and generation == self._request_generation
    end, function(success, status)
        if active_download == request_token then
            self._download_worker = nil
            active_download = nil
        end

        local _, current_date = get_today_info()
        if status == "http_404" and current_date == today_str then
            http404_cooldown_date = today_str
            http404_cooldown_until = os.time() + HTTP404_COOLDOWN
        end

        local instance_active = not self._stopped
            and generation == self._request_generation
            and active_instance == self
        if instance_active then
            self._busy = false
        end

        if status == "stale_date" or current_date ~= today_str then
            queue_download_check(nil)
            run_pending_work()
            return
        end

        if not instance_active then
            run_pending_work()
            return
        end

        self._last_status = status

        if success then
            local _, wallpaper_error = self:_refresh_wallpaper(SAVE_DIR .. today_str .. ".jpg", true)
            cleanup_old_images(today_str)
            self:_cancel_retry()
            if opts and opts.notify then
                UIManager:show(InfoMessage:new{
                    text = wallpaper_error and gettext("今日图片已下载，壁纸生成失败") or gettext("一页壁纸已更新"),
                    timeout = 2,
                })
            end
        elseif status == "http_404" then
            self:_cancel_retry()
            if notify_failure and opts and opts.notify then
                UIManager:show(InfoMessage:new{ text = gettext("今日图片未发布 (404)"), timeout = 3 })
            end
        elseif is_hard_failure(status) then
            start_hard_cooldown(today_str)
            self:_cancel_retry()
            logger.warn("一页壁纸: 接口进入冷却", status)
            if notify_failure and opts and opts.notify then
                UIManager:show(InfoMessage:new{
                    text = status_text(status) .. gettext("（1 小时内不再重试）"),
                    timeout = 3,
                })
            end
        else
            self:_schedule_retry(retry_attempt, opts)
            if notify_failure and opts and opts.notify then
                UIManager:show(InfoMessage:new{ text = status_text(status), timeout = 3 })
            end
        end
        run_pending_work()
    end)
    -- Startup failure can invoke the callback synchronously and start another
    -- request after a date change. Do not overwrite that newer worker handle.
    if active_download == request_token then self._download_worker = worker end
end

function OnePage:_refresh_wallpaper(source, refresh, verify_cache)
    local ok, available, failure, invalid_source = pcall(function()
        local Wallpaper = require("onepage_wallpaper")
        source = source or latest_cached_image()
        return Wallpaper.prepare(WALLPAPER_DIR, source, wallpaper_style(), refresh, verify_cache, WALLPAPER_DISPLAY_DIR)
    end)
    if not ok then
        failure, available = available or "Wallpaper preparation failed", false
        logger.warn("一页壁纸: 壁纸更新失败", tostring(failure))
    end
    self._undecodable_source = invalid_source and source or nil
    return available, failure, invalid_source
end

function OnePage:_select_wallpaper_style(style)
    if self._stopped or not G_reader_settings then return end
    if wallpaper_style() == style then return end
    G_reader_settings:saveSetting(SETTING_WALLPAPER_STYLE, style)
    G_reader_settings:flush()
    local available, failure = self:_refresh_wallpaper()
    local message
    if failure then
        message = gettext("壁纸生成失败，稍后会用缓存重试")
    elseif not available then
        message = gettext("已保存壁纸类型，下载图片后生效")
    end
    if message then UIManager:show(InfoMessage:new{ text = message, timeout = 3 }) end
end

function OnePage:_select_contrast(value)
    if self._stopped or not G_reader_settings then return end
    if wallpaper_contrast() == value then return end
    G_reader_settings:saveSetting(SETTING_CONTRAST, value)
    G_reader_settings:flush()
    self:_refresh_wallpaper(nil, true)
end

-- 自动配置屏保；首次配置前保存原值，关闭开关时恢复
function OnePage:_ensure_screensaver_settings(force)
    if not G_reader_settings then return end
    if not force and not is_auto_screensaver_enabled() then return end

    local backup = G_reader_settings:readSetting(SETTING_SCREENSAVER_BACKUP)
    if type(backup) ~= "table" or backup.version ~= 1 then
        local function snapshot(key)
            local value = G_reader_settings:readSetting(key)
            return { is_set = value ~= nil, value = value }
        end
        backup = {
            version = 1,
            type = snapshot("screensaver_type"),
            dir = snapshot("screensaver_dir"),
            stretch = snapshot("screensaver_stretch_images"),
            show_msg = snapshot("screensaver_show_message"),
        }
        -- Persist the original values before changing any screensaver setting.
        G_reader_settings:saveSetting(SETTING_SCREENSAVER_BACKUP, backup)
        G_reader_settings:flush()
    end

    local changed = false
    if G_reader_settings:readSetting("screensaver_type") ~= "random_image" then
        G_reader_settings:saveSetting("screensaver_type", "random_image")
        changed = true
    end
    if G_reader_settings:readSetting("screensaver_dir") ~= WALLPAPER_DISPLAY_DIR then
        G_reader_settings:saveSetting("screensaver_dir", WALLPAPER_DISPLAY_DIR)
        changed = true
    end
    -- 正确键名是 screensaver_stretch_images：不拉伸时图按比例缩放，
    -- 与屏幕宽高比不一致会留下两侧黑边，故必须开启
    if not G_reader_settings:isTrue("screensaver_stretch_images") then
        G_reader_settings:saveSetting("screensaver_stretch_images", true)
        changed = true
    end
    -- 壁纸上不覆盖 “Sleeping” 文字
    if G_reader_settings:isTrue("screensaver_show_message") then
        G_reader_settings:saveSetting("screensaver_show_message", false)
        changed = true
    end

    if changed then
        G_reader_settings:flush()
        logger.info("一页壁纸: 屏保设置已自动配置")
    end
end

function OnePage:_restore_screensaver_settings(disable_auto)
    if not G_reader_settings then return end
    local backup = G_reader_settings:readSetting(SETTING_SCREENSAVER_BACKUP)

    if type(backup) == "table" and backup.version == 1 then
        local function restore(key, saved)
            if type(saved) ~= "table" or not saved.is_set then
                G_reader_settings:delSetting(key)
            else
                G_reader_settings:saveSetting(key, saved.value)
            end
        end
        restore("screensaver_type", backup.type)
        restore("screensaver_dir", backup.dir)
        restore("screensaver_stretch_images", backup.stretch)
        restore("screensaver_show_message", backup.show_msg)
    end

    if disable_auto then
        G_reader_settings:saveSetting(SETTING_AUTO_SCREENSAVER, false)
    end
    -- Save restored values before removing the recovery snapshot.
    G_reader_settings:flush()
    if backup ~= nil then
        G_reader_settings:delSetting(SETTING_SCREENSAVER_BACKUP)
        G_reader_settings:flush()
    end
    logger.info("一页壁纸: 屏保设置已恢复")
end

function OnePage:deletePluginSettings()
    if not G_reader_settings then return end
    self:_restore_screensaver_settings(true)
    G_reader_settings:delSetting(SETTING_AUTO_SCREENSAVER)
    G_reader_settings:delSetting(SETTING_WALLPAPER_STYLE)
    G_reader_settings:delSetting(SETTING_CONTRAST)
    G_reader_settings:delSetting("onepage_last_date")
    G_reader_settings:flush()
end

-- Drop callbacks owned by this UI instance. Do not restore screensaver settings
-- here: closing the file manager or reader does not disable the plugin.
function OnePage:_cancel_scheduled_work()
    self._stopped = true
    self._request_generation = self._request_generation + 1
    self._busy = false
    self._startup_at = nil
    self._resume_at = nil
    self._retry_at = nil
    self._retry_attempt = nil
    self._retry_opts = nil
    self._loop_at = nil
    self._pending_update = nil
    self._update_busy = false
    if self._update_dialog then
        UIManager:close(self._update_dialog)
        self._update_dialog = nil
    end
    if active_instance == self then
        active_instance = nil
        pending_download_check = false
        pending_download_opts = nil
    end
    if self._download_worker then
        self._download_worker:cancel()
    end
    if self._update_worker then
        self._update_worker:cancel()
    end
    -- The shared scheduler remains only long enough to reap a cancelled child.
    schedule_next_check()
end

function OnePage:onCloseWidget()
    self:_cancel_scheduled_work()
end

function OnePage:stopPlugin()
    self:_cancel_scheduled_work()
    -- Disabling the plugin should leave screensaver preferences as they were.
    self:_restore_screensaver_settings(false)
end

function OnePage:onResume()
    if self._stopped or active_instance ~= self or update_needs_restart then return end
    self._resume_at = os.time() + RESUME_DELAY
    self:_schedule_next_check()
end

-- Wi-Fi 是否开启（与“是否已拿到 IP”分开判断）
function OnePage:_wifi_on()
    if NetworkMgr and NetworkMgr.isWifiOn then
        local ok, on = pcall(NetworkMgr.isWifiOn, NetworkMgr)
        if ok then return on == true end
    end
    return true -- 无法确认时按开启处理，交给重试上限兜底
end

function OnePage:_cancel_retry()
    self._retry_at = nil
    self._retry_attempt = nil
    self._retry_opts = nil
    self:_schedule_next_check()
end

-- All timed work, including worker polling/reaping across UI transitions,
-- shares one module-level UIManager callback.
schedule_next_check = function()
    if scheduler_callback then
        UIManager:unschedule(scheduler_callback)
        scheduler_callback = nil
    end
    local delay
    local function consider(wait)
        if wait and (not delay or wait < delay) then
            delay = wait
        end
    end
    local instance = active_instance
    if instance and not instance._stopped and not update_needs_restart then
        local now = os.time()
        for _, key in ipairs({ "_startup_at", "_resume_at", "_retry_at", "_loop_at" }) do
            local deadline = instance[key]
            if deadline then consider(deadline - now) end
        end
    end
    if active_worker then consider(active_worker.poll_at - worker_now()) end
    if not delay then return end

    scheduler_callback = function()
        scheduler_callback = nil
        local worker = active_worker
        if worker and worker.poll_at <= worker_now() then worker:poll() end
        local current = active_instance
        if current and not current._stopped and not update_needs_restart then
            current:_process_scheduled_work()
        end
        schedule_next_check()
    end
    UIManager:scheduleIn(math.max(0, delay), scheduler_callback)
end

function OnePage:_schedule_next_check()
    schedule_next_check()
end

function OnePage:_process_scheduled_work()
    local now = os.time()
    local should_run = false
    if self._startup_at and self._startup_at <= now then
        self._startup_at = nil
        should_run = true
    end
    if self._resume_at and self._resume_at <= now then
        self._resume_at = nil
        should_run = true
    end
    if self._loop_at and self._loop_at <= now then
        self._loop_at = now + CHECK_INTERVAL
        should_run = true
    end
    if self._retry_at and self._retry_at <= now then
        local attempt, opts = self._retry_attempt, self._retry_opts
        self._retry_at = nil
        self._retry_attempt = nil
        self._retry_opts = nil
        self:_retry_round(attempt, opts)
    end
    if should_run and not self._busy then self:_run() end
end

-- Periodic fallback shares the central timer with startup, resume and retries.
function OnePage:_schedule_loop()
    if self._stopped or active_instance ~= self then return end
    if not self._loop_at then self._loop_at = os.time() + CHECK_INTERVAL end
    self:_schedule_next_check()
end

-- 失败后的退避重试：Wi-Fi 关闭即停；正在重连则等比退避等待
function OnePage:_schedule_retry(attempt, opts)
    if self._stopped or active_instance ~= self or self._retry_at then return end
    if attempt >= MAX_RETRIES then
        self._last_status = self._last_status or "network_error"
        logger.warn("一页壁纸: 重试耗尽，放弃")
        return
    end
    local delay = math.min(RETRY_BASE * 2 ^ attempt, RETRY_MAX)
    self._retry_at = os.time() + delay
    self._retry_attempt = attempt + 1
    self._retry_opts = opts
    self:_schedule_next_check()
end

function OnePage:_retry_round(attempt, opts)
    if self._stopped or self._busy then return end
    local _, today_str, today_path = get_today_info()
    if not (opts and opts.ignore_cooldown) and is_http404_cooling(today_str) then return end
    if not (opts and opts.ignore_cooldown) and is_hard_cooling(today_str) then return end
    if is_valid_jpeg(today_path) then
        local _, _, invalid_source = self:_refresh_wallpaper(today_path)
        if not invalid_source then
            cleanup_old_images(today_str)
            self:_cancel_retry()
            return
        end
    end
    if not self:_wifi_on() then
        logger.dbg("一页壁纸: Wi-Fi 关闭，停止重试")
        self._last_status = "no_network"
        return
    end
    if not is_network_available() then
        self:_schedule_retry(attempt, opts) -- 仍在重连，继续等
        return
    end

    self:_download_today(today_str, opts, attempt, false)
end

-- 主入口：图片已存在走快速路径；缺失则下载；失败自动进入重试链
function OnePage:_run(opts)
    if self._stopped or update_needs_restart then return end
    if self._busy then
        if opts and opts.notify then
            UIManager:show(InfoMessage:new{ text = gettext("一页壁纸任务进行中…"), timeout = 2 })
        end
        return
    end

    util.makePath(SAVE_DIR)
    local _, today_str, today_path = get_today_info()
    local today_ready = is_valid_jpeg(today_path)
    local _, wallpaper_error, invalid_source = self:_refresh_wallpaper(today_ready and today_path or nil, nil, opts and opts.notify)

    -- 自动和手动下载均复用有效今日图，避免不必要的重复请求。
    if today_ready and not invalid_source then
        self:_cancel_retry()
        cleanup_old_images(today_str)
        if opts and opts.notify then
            UIManager:show(InfoMessage:new{
                text = wallpaper_error and gettext("今日图片已保存，壁纸生成失败") or gettext("今日一页壁纸已存在"),
                timeout = 2,
            })
        end
        return
    end

    -- 今日图确认未发布后，冷却期内不再打服务器。
    if not (opts and opts.ignore_cooldown) and is_http404_cooling(today_str) then
        logger.dbg("一页壁纸: 今日图未发布，冷却中，跳过")
        return
    end

    -- 接口结构异常或 CDN 换域名后，同样不再每 5 分钟重试一次。
    if not (opts and opts.ignore_cooldown) and is_hard_cooling(today_str) then
        logger.dbg("一页壁纸: 接口不可用，冷却中，跳过")
        return
    end

    if not is_network_available() then
        if self:_wifi_on() then
            self:_schedule_retry(0, opts) -- Wi-Fi 开着但还没拿到 IP：等待重连
        else
            self._last_status = "no_network"
            if opts and opts.notify then
                UIManager:show(InfoMessage:new{ text = gettext("无网络连接"), timeout = 3 })
            end
        end
        return
    end

    self:_download_today(today_str, opts, 0, true)
end

function OnePage:download_today()
    if self._stopped then return end
    if update_needs_restart then
        show_update_restart()
        return
    end
    self:_cancel_retry()
    self:_run{ notify = true, ignore_cooldown = true }
end

----------------------------------------------------------------------
-- 手动检查与安装插件更新
----------------------------------------------------------------------

local function update_message(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 4 })
end

local function update_error(status)
    if status == "missing_asset" then return gettext("正式版缺少安装 ZIP")
    elseif status == "bad_release" then return gettext("无法验证发布信息")
    elseif status == "redirect_error" then return gettext("下载跳转地址不受信任")
    elseif status == "too_large" then return gettext("更新数据超过大小上限")
    elseif status == "bad_digest" then return gettext("安装包校验失败")
    elseif status == "bad_zip" then return gettext("安装包内容无效")
    elseif status == "write_error" then return gettext("无法写入更新文件")
    elseif status == "backup_pending" then return gettext("旧版备份仍在，请先确认当前版本运行正常，重启后再试。")
    elseif status == "install_error" then return gettext("替换失败，旧版已保留")
    end
    return status_text(status)
end

function OnePage:_queue_plugin_update(task)
    self._update_busy = true
    self._pending_update = task
    if active_worker then update_message(gettext("正在等待当前一页壁纸任务结束…")) end
    run_pending_work()
end

function OnePage:_run_plugin_update_worker(task, callback)
    self._update_worker = run_request_in_subprocess(task, function(status)
        self._update_worker = nil
        self._update_busy = false
        callback(status, not self._stopped and active_instance == self)
    end, UPDATE_TIMEOUT)
end

function OnePage:_install_plugin_update(Update, paths, release)
    if self._stopped or active_instance ~= self or self._update_busy or update_needs_restart then return end
    if not is_network_available() then update_message(gettext("无网络连接")); return end
    self:_queue_plugin_update(function()
        local stage, err = Update.make_stage(paths)
        if not stage then
            self._update_busy = false
            update_message(gettext("安装失败：") .. update_error(err))
            return
        end
        update_message(gettext("正在后台下载插件更新…"))
        self:_run_plugin_update_worker(function()
            return Update.prepare(stage, release)
        end, function(status, current)
            if current and status == "prepared" then
                status = Update.install(paths, stage)
                if status == "installed" or status == "restore_error" or status == "sync_error" then
                    update_needs_restart = status
                end
                if status == "restore_error" then update_recovery_path = paths.backup end
            end
            Update.remove_stage(paths, stage)
            if not current then return end
            if status == "installed" then
                show_update_restart(gettext("一页壁纸已安装 ") .. release.version .. gettext("，重启 KOReader 后生效。"))
            elseif update_needs_restart then
                show_update_restart()
            else
                update_message(gettext("安装失败：") .. update_error(status))
            end
        end)
    end)
end

function OnePage:_check_plugin_update()
    if self._stopped or active_instance ~= self then return end
    if update_needs_restart then
        show_update_restart()
        return
    end
    if self._update_busy or self._update_dialog then
        update_message(gettext("插件更新任务进行中…"))
        return
    end
    if not is_network_available() then update_message(gettext("无网络连接")); return end

    -- Loaded lazily: if the module is missing or broken, the menu entry must
    -- say so instead of throwing a traceback out of the menu callback.
    local loaded, Update = pcall(require, "onepage_update")
    if not loaded or type(Update) ~= "table" then
        logger.warn("一页壁纸: 无法加载更新模块", tostring(Update))
        update_message(gettext("无法加载更新模块"))
        return
    end
    local paths = Update.paths(self.path)
    if not paths or type(self.version) ~= "string" then
        update_message(gettext("无法确定插件的安装目录或版本"))
        return
    end
    self:_queue_plugin_update(function()
        update_message(gettext("正在后台检查插件更新…"))
        self:_run_plugin_update_worker(function()
            return Update.check(self.version)
        end, function(status, current)
            if not current then return end
            local release = Update.parse_result(status)
            if release then
                local text = gettext("发现一页壁纸新版本 ") .. release.version
                    .. "\n" .. gettext("当前版本 ") .. self.version
                if release.notes ~= "" then text = text .. "\n\n" .. release.notes end
                local ConfirmBox = require("ui/widget/confirmbox")
                self._update_dialog = ConfirmBox:new{
                    text = text,
                    ok_text = gettext("下载安装"),
                    ok_callback = function()
                        self._update_dialog = nil
                        self:_install_plugin_update(Update, paths, release)
                    end,
                    cancel_callback = function() self._update_dialog = nil end,
                }
                UIManager:show(self._update_dialog)
            elseif status == "current" then
                update_message(gettext("一页壁纸已是最新版 ") .. self.version)
            else
                update_message(gettext("检查更新失败：") .. update_error(status))
            end
        end)
    end)
end

----------------------------------------------------------------------
-- 诊断
----------------------------------------------------------------------

function OnePage:_diagnostics()
    local _, today_str, today_path = get_today_info()
    local lines = {}
    lines[#lines + 1] = gettext("目录: ") .. SAVE_DIR
    if self._undecodable_source ~= today_path and is_valid_jpeg(today_path) then
        lines[#lines + 1] = gettext("今日图片: 已就绪 (") .. today_str .. ")"
    elseif file_exists(today_path) then
        lines[#lines + 1] = gettext("今日图片: 文件损坏")
    else
        lines[#lines + 1] = gettext("今日图片: 未下载")
    end
    lines[#lines + 1] = gettext("最近状态: ") .. tostring(self._last_status or "-")
    local cooldown_reason, cooldown_until
    if is_http404_cooling(today_str) then
        cooldown_reason, cooldown_until = gettext("今日图未发布"), http404_cooldown_until
    elseif is_hard_cooling(today_str) then
        cooldown_reason, cooldown_until = gettext("接口不可用"), hard_cooldown_until
    end
    if cooldown_reason then
        lines[#lines + 1] = gettext("冷却: ") .. cooldown_reason
            .. gettext("，剩余 ") .. tostring(math.ceil((cooldown_until - os.time()) / 60))
            .. gettext(" 分钟")
    end
    lines[#lines + 1] = gettext("网络: ") .. (is_network_available() and gettext("已连接") or gettext("未连接"))
    if G_reader_settings then
        lines[#lines + 1] = gettext("屏保类型: ") .. tostring(G_reader_settings:readSetting("screensaver_type"))
        lines[#lines + 1] = gettext("屏保目录: ") .. tostring(G_reader_settings:readSetting("screensaver_dir"))
        lines[#lines + 1] = gettext("拉伸填充: ") .. tostring(G_reader_settings:isTrue("screensaver_stretch_images"))
    end
    lines[#lines + 1] = gettext("自动配置: ") .. (is_auto_screensaver_enabled() and gettext("开") or gettext("关"))
    lines[#lines + 1] = gettext("壁纸: ")
        .. (wallpaper_style() == "card" and gettext("白底圆角卡") or gettext("全屏"))
        .. " / " .. (wallpaper_contrast() == "high" and gettext("高对比白") or gettext("经典灰"))
    lines[#lines + 1] = gettext("今日文案: ")
        .. (file_exists(SAVE_DIR .. today_str .. ".json") and gettext("已缓存") or gettext("未缓存"))
    return table.concat(lines, "\n")
end

----------------------------------------------------------------------
-- 菜单
----------------------------------------------------------------------

function OnePage:addToMainMenu(menu_items)
    local wallpaper_types = {}
    for _, item in ipairs(WALLPAPER_STYLES) do
        local style, label = item[1], item[2]
        wallpaper_types[#wallpaper_types + 1] = {
            text = label,
            checked_func = function() return wallpaper_style() == style end,
            callback = function() self:_select_wallpaper_style(style) end,
        }
    end
    local contrast_types = {}
    for _, item in ipairs(CONTRAST_STYLES) do
        local value, label = item[1], item[2]
        contrast_types[#contrast_types + 1] = {
            text = label,
            checked_func = function() return wallpaper_contrast() == value end,
            callback = function() self:_select_contrast(value) end,
        }
    end
    menu_items.onepage = {
        text = gettext("一页壁纸"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = gettext("自动配置屏保"),
                checked_func = function() return is_auto_screensaver_enabled() end,
                callback = function()
                    local enabled = not is_auto_screensaver_enabled()
                    if enabled then
                        -- Save the original screensaver settings before enabling.
                        self:_refresh_wallpaper()
                        self:_ensure_screensaver_settings(true)
                        set_auto_screensaver_enabled(true)
                        UIManager:show(InfoMessage:new{
                            text = gettext("已启用自动配置屏保"),
                            timeout = 3,
                        })
                    else
                        self:_restore_screensaver_settings(true)
                        UIManager:show(InfoMessage:new{
                            text = gettext("已停用，屏保设置已恢复"),
                            timeout = 3,
                        })
                    end
                end,
            },
            {
                text = gettext("下载今日一页壁纸"),
                callback = function() self:download_today() end,
            },
            { text = gettext("壁纸类型"), sub_item_table = wallpaper_types },
            { text = gettext("配色"), sub_item_table = contrast_types },
            {
                text = gettext("检查插件更新"),
                callback = function() self:_check_plugin_update() end,
            },
            {
                text = gettext("诊断"),
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = self:_diagnostics(),
                        timeout = 12,
                    })
                end,
            },
        },
    }
    return menu_items
end

return OnePage
