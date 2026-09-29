local assdraw = require('mp.assdraw')
local msg = require('mp.msg')
local options = require('mp.options')
local utils = require('mp.utils')

local o = {
    mode = 'manual',
    timeout = 20,
    history_path = '~~/files/skip_intro_and_outro_history.json',
    button_font_size = 24,
    button_padding_x = 20,
    button_padding_y = 15,
    button_margin = 60,
    button_border = 2,
    button_radius = 13,
    button_progress_color = '2442F4',
    button_progress_hover_color = '2442F4',
    button_remaining_color = 'FFFFFF',
    button_remaining_hover_color = '111111',
    button_text_color = '000000',
    button_text_hover_color = 'FFFFFF',
    button_border_color = 'FFFFFF',
}
options.read_options(o, 'skip_intro_and_outro')
if o.mode ~= 'none' and o.mode ~= 'auto' and o.mode ~= 'manual' then
    msg.warn('无效的 mode：' .. tostring(o.mode) .. '，已使用 manual')
    o.mode = 'manual'
end

local menu_type = 'skip_intro_and_outro'
local history_path = mp.command_native({'expand-path', o.history_path})
local on_windows = package.config:sub(1, 1) == '\\'
local windows_api
if on_windows then
    local ffi = require('ffi')
    ffi.cdef[[ 
        int __stdcall MultiByteToWideChar(unsigned int code_page, unsigned long flags,
            const char *input, int input_length, wchar_t *output, int output_length);
        int __stdcall MoveFileExW(const wchar_t *source, const wchar_t *destination, unsigned long flags);
        unsigned long __stdcall GetLastError(void);
    ]]
    windows_api = {ffi = ffi, kernel32 = ffi.load('kernel32')}
end
-- 缓存以本地目录路径为键。
local cache = {}
local cache_load_failed = false
local video_extensions = {
    'mp4', 'mkv', 'mov', 'avi', 'webm',
}
-- 当前文件路径、所在目录、扩展名及片头片尾的进入状态。
local current = {path = nil, directory = nil,
    extension = nil, entered = {intro = false, outro = false}}
-- 手动跳过按钮的绘制与倒计时状态。
local prompt = {kind = nil, overlay = nil, timer = nil, deadline = nil, rect = nil,
    click_bound = false, last_hover = nil, last_progress = nil, last_width = nil, last_height = nil}
local position_timer = nil
local menu_pause_before = nil
local update_position_timer
local temp_counter = 0

local function finite_number(value)
    return type(value) == 'number' and value == value and value > -math.huge and value < math.huge
end

local function valid_duration(value)
    return finite_number(value) and value > 0
end

local function format_time(value)
    if not finite_number(value) then return '未设置' end
    local hours = math.floor(value / 3600)
    local minutes = math.floor(value % 3600 / 60)
    local seconds = value % 60
    return string.format('%02d:%02d:%06.3f', hours, minutes, seconds)
end

-- 排除协议地址，返回本地文件的目录和扩展名。
local function identify_local_file(path)
    if not path or path == '' then return nil end
    if path:match('^%a[%w.+-]*://') then return nil end

    local file_path = mp.command_native({'normalize-path', path})
    local directory, filename = utils.split_path(file_path)
    local extension = filename:match('%.([^%.]+)$')
    return directory, extension and extension:lower() or nil
end

local function read_cache()
    local file, open_error = io.open(history_path, 'r')
    if not file then
        if not utils.file_info(history_path) then return end
        cache_load_failed = true
        msg.error('无法读取片头片尾缓存：' .. tostring(open_error))
        return
    end
    local contents = file:read('*a')
    local closed, close_error = file:close()
    if not contents or not closed then
        cache_load_failed = true
        msg.error('无法读取片头片尾缓存：' .. tostring(close_error or '读取失败'))
        return
    end
    local parsed = utils.parse_json(contents)
    if type(parsed) ~= 'table' then
        cache_load_failed = true
        msg.error('片头片尾缓存格式无效：' .. history_path)
        return
    end
    for directory, settings in pairs(parsed) do
        if type(directory) ~= 'string' or type(settings) ~= 'table'
            or (directory:sub(-1) ~= '/' and directory:sub(-1) ~= '\\')
            or directory:match('^%a[%w.+-]*://') then
            cache_load_failed = true
            msg.error('片头片尾缓存只接受本地目录键：' .. history_path)
            return
        end
    end
    cache = parsed
end

local function replace_file(source, destination)
    if not on_windows then return os.rename(source, destination) end
    local ffi, kernel32 = windows_api.ffi, windows_api.kernel32
    local function wide_path(path)
        local length = kernel32.MultiByteToWideChar(65001, 0, path, #path, nil, 0)
        if length == 0 then return nil end
        local wide = ffi.new('wchar_t[?]', length + 1)
        if kernel32.MultiByteToWideChar(65001, 0, path, #path, wide, length) == 0 then return nil end
        return wide
    end
    local wide_source, wide_destination = wide_path(source), wide_path(destination)
    if not wide_source or not wide_destination then return nil, '无法转换缓存路径编码' end
    if kernel32.MoveFileExW(wide_source, wide_destination, 0x1 + 0x8) == 0 then
        return nil, 'MoveFileExW 失败，错误码 ' .. tostring(kernel32.GetLastError())
    end
    return true
end

local function write_cache()
    if cache_load_failed then
        mp.osd_message('片头片尾缓存不可用，无法保存设置', 3)
        return false
    end
    local contents = utils.format_json(cache)
    if type(contents) ~= 'string' then
        mp.osd_message('片头片尾设置序列化失败', 3)
        return false
    end
    temp_counter = temp_counter + 1
    local temp_path = history_path .. '.tmp.' .. tostring(mp.get_time()):gsub('%.', '')
        .. '.' .. tostring(temp_counter)
    local file, err = io.open(temp_path, 'wb')
    if not file then
        msg.error('无法写入片头片尾缓存：' .. tostring(err))
        mp.osd_message('片头片尾缓存写入失败', 3)
        return false
    end
    local ok, write_error = file:write(contents)
    local closed, close_error = file:close()
    if not ok or not closed then
        os.remove(temp_path)
        msg.error('无法写入片头片尾缓存：' .. tostring(write_error or close_error))
        mp.osd_message('片头片尾缓存写入失败', 3)
        return false
    end
    local replaced, replace_error = replace_file(temp_path, history_path)
    if not replaced then
        os.remove(temp_path)
        msg.error('无法替换片头片尾缓存：' .. tostring(replace_error))
        mp.osd_message('片头片尾缓存替换失败', 3)
        return false
    end
    return true
end

local function current_settings()
    local settings = current.directory and cache[current.directory]
    return type(settings) == 'table' and settings or nil
end

-- nil 表示选择全部受支持的视频扩展名。
local function selected_extensions()
    local settings = current_settings()
    return settings and type(settings.extensions) == 'table' and settings.extensions or nil
end

local function extension_is_selected(selected, extension)
    if not selected or not extension then return false end
    for _, item in ipairs(selected) do
        if item == extension then return true end
    end
    return false
end

local function is_video_extension(extension)
    for _, item in ipairs(video_extensions) do
        if item == extension then return true end
    end
    return false
end

local function extension_is_allowed()
    local selected = selected_extensions()
    return is_video_extension(current.extension)
        and (not selected or extension_is_selected(selected, current.extension))
end

local function extension_summary(selected)
    if not selected then return '全部' end
    local names = {}
    for _, extension in ipairs(video_extensions) do
        if extension_is_selected(selected, extension) then
            names[#names + 1] = extension:upper()
        end
    end
    return #names > 0 and table.concat(names, '、') or '未选择'
end

local function is_current_directory_enabled()
    local settings = current_settings()
    return settings ~= nil and settings.enabled == true
end

-- 修改当前目录的一项设置，保留同目录的其他设置。
local function set_setting(name, value)
    if not current.directory then
        mp.osd_message(current.path and '仅支持本地视频' or '请先打开视频', 2)
        return false
    end
    local previous_settings = cache[current.directory]
    local updated_settings = {}
    if type(previous_settings) == 'table' then
        for key, item in pairs(previous_settings) do updated_settings[key] = item end
    end
    updated_settings[name] = value
    cache[current.directory] = updated_settings
    if write_cache() then return true end
    cache[current.directory] = previous_settings
    return false
end

local function menu_is_open()
    return mp.get_property_native('user-data/uosc/menu/type') == menu_type
end

local hide_prompt

-- 打开或刷新 uosc 设置菜单，并暂停当前视频。
local function show_menu()
    if current.path and not current.directory then
        if menu_is_open() then
            mp.commandv('script-message-to', 'uosc', 'close-menu', menu_type)
        end
        mp.osd_message('仅支持本地视频', 2)
        return
    end
    if current.path and mp.get_property('path') then
        if menu_pause_before == nil then
            menu_pause_before = mp.get_property_native('pause')
        end
        mp.set_property_native('pause', true)
    end
    hide_prompt()
    local settings = current_settings() or {}
    local enabled = is_current_directory_enabled()
    local selected = selected_extensions()
    local extension_items = {
        {title = '全部', hint = selected and '未选中' or '已选中',
            value = 'extension:all', active = not selected, keep_open = true},
    }
    for _, extension in ipairs(video_extensions) do
        local active = extension_is_selected(selected, extension)
        extension_items[#extension_items + 1] = {
            title = extension:upper(),
            hint = not selected and '由全部包含' or active and '已选中' or '未选中',
            value = 'extension:' .. extension, active = active, keep_open = true,
        }
    end
    local menu = {
        type = menu_type,
        title = '跳过片头片尾',
        search_style = 'disabled',
        footnote = '点击时长记录当前位置；使用 − / + 微调 1 秒',
        callback = {mp.get_script_name(), 'menu-action'},
        items = {
            {title = '开关', hint = enabled and '已开启' or '已关闭', value = 'toggle', keep_open = true},
            {id = 'extensions', title = '配置扩展名', hint = extension_summary(selected),
                footnote = '点击扩展名切换选择；“全部”与手动选择互斥',
                search_style = 'disabled', items = extension_items},
            {title = '片头时长', hint = format_time(settings.intro_duration), value = 'intro', keep_open = true,
                actions_place = 'outside',
                actions = {{name = 'decrease', icon = 'remove', label = '减少 1 秒'},
                    {name = 'increase', icon = 'add', label = '增加 1 秒'}}},
            {title = '片尾时长', hint = format_time(settings.outro_duration), value = 'outro', keep_open = true,
                actions_place = 'outside',
                actions = {{name = 'decrease', icon = 'remove', label = '减少 1 秒'},
                    {name = 'increase', icon = 'add', label = '增加 1 秒'}}},
        },
    }
    mp.commandv('script-message-to', 'uosc', menu_is_open() and 'update-menu' or 'open-menu', utils.format_json(menu))
end

-- 切换片头片尾设置菜单的显示状态。
local function toggle_settings_menu()
    if menu_is_open() then
        mp.commandv('script-message-to', 'uosc', 'close-menu', menu_type)
    else
        show_menu()
    end
end

hide_prompt = function()
    if not prompt.kind then return end
    if prompt.timer then
        prompt.timer:kill()
        prompt.timer = nil
    end
    prompt.kind = nil
    prompt.deadline = nil
    prompt.rect = nil
    prompt.last_hover = nil
    prompt.last_progress = nil
    prompt.last_width = nil
    prompt.last_height = nil
    if prompt.overlay then prompt.overlay:remove() end
    if prompt.click_bound then
        mp.remove_key_binding('skip_intro_and_outro-click')
        prompt.click_bound = false
    end
    mp.remove_key_binding('skip_intro_and_outro-confirm')
    mp.remove_key_binding('skip_intro_and_outro-cancel')
end

local confirm_prompt

local function mouse_inside_button(mouse, rect)
    return mouse and mouse.hover and rect and mouse.x >= rect.x and mouse.x <= rect.x + rect.w
        and mouse.y >= rect.y and mouse.y <= rect.y + rect.h or false
end

-- 绘制带倒计时进度的手动跳过按钮。
local function render_prompt()
    if not prompt.kind then return end
    local dimensions = mp.get_property_native('osd-dimensions')
    local screen_width = dimensions and dimensions.w or 1920
    local screen_height = dimensions and dimensions.h or 1080
    local scale = screen_height / 1080
    local style = o
    local button_padding_x = style.button_padding_x * scale
    local button_padding_y = style.button_padding_y * scale
    local font_size = style.button_font_size * scale
    local hint_font_size = font_size * 0.9
    local message = prompt.kind == 'intro' and '跳过片头' or '跳过片尾'
    local hint_text = '[y/n]'
    local message_width = 4 * font_size -- 两条文案均为四个汉字。
    local hint_width = #hint_text * hint_font_size * 0.6
    local button_width = math.max(message_width, hint_width) + button_padding_x * 2
    local line_spacing = font_size * 0.1
    local button_height = font_size + line_spacing + hint_font_size + button_padding_y * 2
    local margin = style.button_margin * scale
    local button_x = screen_width - button_width - margin
    local button_y = screen_height - button_height - margin - (80 * scale)
    prompt.rect = {x = button_x, y = button_y, w = button_width, h = button_height}

    local mouse = mp.get_property_native('mouse-pos')
    local hover = mouse_inside_button(mouse, prompt.rect)
    if hover ~= prompt.click_bound then
        if hover then
            mp.add_forced_key_binding('MBTN_LEFT', 'skip_intro_and_outro-click', function()
                if mouse_inside_button(mp.get_property_native('mouse-pos'), prompt.rect) then
                    confirm_prompt()
                end
            end)
        else
            mp.remove_key_binding('skip_intro_and_outro-click')
        end
        prompt.click_bound = hover
    end
    local text_color = hover and style.button_text_hover_color or style.button_text_color
    local remaining = o.timeout > 0 and math.max(0, math.ceil(prompt.deadline - mp.get_time())) or 0
    local progress = 0
    if o.timeout > 0 and remaining > 0 then
        progress = 1 - remaining / o.timeout
    elseif remaining == 0 then
        progress = 1
    end
    local progress_color = hover and style.button_progress_hover_color or style.button_progress_color
    local remaining_color = hover and style.button_remaining_hover_color or style.button_remaining_color
    if prompt.last_hover == hover and prompt.last_progress == progress
        and prompt.last_width == screen_width and prompt.last_height == screen_height then return end
    prompt.last_hover = hover
    prompt.last_progress = progress
    prompt.last_width = screen_width
    prompt.last_height = screen_height

    local ass = assdraw.ass_new()
    ass:new_event()
    ass:pos(0, 0)
    ass:append("{\\blur0\\bord0\\1c&HFFFFFF&\\3c&HFFFFFF&}")
    ass:draw_start()
    ass:append("{\\1c&H000000&\\3c&H" .. style.button_border_color .. "&\\bord" .. (style.button_border * scale) .. "}")
    ass:round_rect_cw(button_x, button_y, button_x + button_width, button_y + button_height, style.button_radius * scale)
    ass:draw_stop()

    if progress > 0 then
        local progress_width = button_width * progress
        ass:new_event()
        ass:pos(0, 0)
        ass:append("{\\blur0\\bord0}")
        ass:draw_start()
        ass:append("{\\1c&H" .. progress_color .. "&}")
        if progress >= 1 then
            ass:round_rect_cw(button_x, button_y, button_x + button_width, button_y + button_height, style.button_radius * scale)
        else
            ass:round_rect_cw(button_x, button_y, button_x + progress_width, button_y + button_height, style.button_radius * scale, 0)
        end
        ass:draw_stop()
    end

    if progress < 1 then
        local progress_width = button_width * progress
        ass:new_event()
        ass:pos(0, 0)
        ass:append("{\\blur0\\bord0}")
        ass:draw_start()
        ass:append("{\\1c&H" .. remaining_color .. "&}")
        if progress > 0 then
            ass:round_rect_cw(button_x + progress_width, button_y, button_x + button_width, button_y + button_height, 0, style.button_radius * scale)
        else
            ass:round_rect_cw(button_x, button_y, button_x + button_width, button_y + button_height, style.button_radius * scale)
        end
        ass:draw_stop()
    end

    local text_x = button_x + button_width / 2
    local text_y = button_y + button_height / 2 - (hint_font_size + line_spacing) / 2
    ass:new_event()
    ass:append("{\\an5\\fs" .. font_size .. "\\b1\\bord0\\shad0\\1c&H" .. text_color .. "&}")
    ass:pos(text_x, text_y)
    ass:append(message)
    local hint_y = text_y + font_size / 2 + line_spacing + hint_font_size / 2
    ass:new_event()
    ass:append("{\\an5\\fs" .. hint_font_size .. "\\b0\\bord0\\shad0\\1c&H" .. text_color .. "&\\alpha&H80&}")
    ass:pos(text_x, hint_y)
    ass:append(hint_text)

    if not prompt.overlay then
        prompt.overlay = mp.create_osd_overlay('ass-events')
        prompt.overlay.z = 2000
    end
    prompt.overlay.res_x = screen_width
    prompt.overlay.res_y = screen_height
    prompt.overlay.data = ass.text
    prompt.overlay:update()
end

local function skip_segment(kind)
    if not is_current_directory_enabled() or not extension_is_allowed()
        or current.path ~= mp.get_property('path') then return end
    local settings = current_settings() or {}
    local video_duration = mp.get_property_number('duration')
    local playback_time = mp.get_property_number('time-pos')
    local segment_duration = settings[kind .. '_duration']
    if not valid_duration(segment_duration) or not valid_duration(video_duration)
        or segment_duration >= video_duration or not finite_number(playback_time)
        or playback_time < 0 or playback_time >= video_duration then return end
    if kind == 'intro' and playback_time >= segment_duration then return end
    if kind == 'outro' and playback_time < video_duration - segment_duration then return end
    local target = kind == 'intro' and segment_duration or video_duration
    mp.osd_message(kind == 'intro' and '已跳过片头' or '已跳过片尾', 2)
    mp.set_property_number('time-pos', target)
end

confirm_prompt = function()
    local kind = prompt.kind
    if not kind then return end
    hide_prompt()
    skip_segment(kind)
end

local function show_prompt(kind)
    if prompt.kind then return end
    prompt.kind = kind
    if o.timeout > 0 then
        prompt.deadline = mp.get_time() + o.timeout
        prompt.timer = mp.add_periodic_timer(1, function()
            if not prompt.kind then return end
            if mp.get_time() >= prompt.deadline then
                hide_prompt()
            else
                render_prompt()
            end
        end)
    end
    render_prompt()
    mp.add_forced_key_binding('y', 'skip_intro_and_outro-confirm', confirm_prompt)
    mp.add_forced_key_binding('n', 'skip_intro_and_outro-cancel', hide_prompt)
end

-- 检查片头、片尾区间，处理自动跳过或手动确认。
local function check_skip_position()
    if not current.directory or not is_current_directory_enabled() or not extension_is_allowed() then
        hide_prompt()
        current.entered.intro, current.entered.outro = false, false
        return
    end
    local playback_time = mp.get_property_number('time-pos')
    local video_duration = mp.get_property_number('duration')
    if not finite_number(playback_time) or not valid_duration(video_duration) then
        hide_prompt()
        return
    end
    local settings = current_settings() or {}
    local paused = mp.get_property_native('pause')
    for _, kind in ipairs({'intro', 'outro'}) do
        local segment_duration = settings[kind .. '_duration']
        local valid = valid_duration(segment_duration) and segment_duration < video_duration
        local inside = valid and playback_time >= 0 and playback_time < video_duration
            and (kind == 'intro' and playback_time < segment_duration
                or kind == 'outro' and playback_time >= video_duration - segment_duration)
        if not inside then
            current.entered[kind] = false
            if prompt.kind == kind then hide_prompt() end
        elseif not current.entered[kind] and not paused then
            current.entered[kind] = true
            if o.mode == 'auto' then
                skip_segment(kind)
            else
                show_prompt(kind)
            end
        end
    end
end

-- 仅在可触发跳过且正在播放时轮询位置。
update_position_timer = function()
    local should_run = false
    if o.mode ~= 'none' and current.directory and not mp.get_property_native('pause')
        and is_current_directory_enabled() and extension_is_allowed() then
        local duration = mp.get_property_number('duration')
        local settings = current_settings() or {}
        should_run = valid_duration(duration)
            and ((valid_duration(settings.intro_duration) and settings.intro_duration < duration)
                or (valid_duration(settings.outro_duration) and settings.outro_duration < duration))
    end
    if should_run then
        if not position_timer then
            position_timer = mp.add_periodic_timer(0.25, check_skip_position)
        end
        check_skip_position()
    else
        if position_timer then position_timer:kill(); position_timer = nil end
        if not current.directory or not is_current_directory_enabled() or not extension_is_allowed() then
            hide_prompt()
            current.entered.intro, current.entered.outro = false, false
        end
    end
end

local function refresh_current_file()
    local path = mp.get_property('path')
    local directory, extension = identify_local_file(path)
    if path ~= current.path or directory ~= current.directory
        or extension ~= current.extension then
        hide_prompt()
        current.path = path
        current.directory = directory
        current.extension = extension
        current.entered = {intro = false, outro = false}
        if menu_is_open() then show_menu() end
        update_position_timer()
    end
end

-- 保存片头或片尾时长，暂停并定位到对应时间点。
local function update_segment_duration(kind, segment_duration, video_duration)
    if not finite_number(segment_duration) or segment_duration <= 0
        or segment_duration >= video_duration then
        mp.osd_message('时长需大于 0 秒且小于视频总时长', 2)
        return
    end
    if set_setting(kind .. '_duration', segment_duration) then
        hide_prompt()
        current.entered[kind] = true
        mp.set_property_native('pause', true)
        local target = kind == 'intro' and segment_duration or video_duration - segment_duration
        mp.commandv('seek', target, 'absolute+exact')
        show_menu()
        update_position_timer()
    end
end

-- 按当前位置记录片头或片尾时长，结果向上取整。
local function capture_segment_duration(kind)
    local playback_time = mp.get_property_number('time-pos')
    local video_duration = mp.get_property_number('duration')
    if not finite_number(playback_time) or playback_time < 0 then
        mp.osd_message('无法获取当前播放时间', 2)
        return
    end
    if not valid_duration(video_duration) or playback_time >= video_duration then
        mp.osd_message('无法获取有效的视频总时长', 2)
        return
    end
    local segment_duration = math.ceil(kind == 'intro' and playback_time or video_duration - playback_time)
    update_segment_duration(kind, segment_duration, video_duration)
end

local function adjust_segment_duration(kind, delta)
    local video_duration = mp.get_property_number('duration')
    if not valid_duration(video_duration) then
        mp.osd_message('无法获取有效的视频总时长', 2)
        return
    end
    local settings = current_settings() or {}
    local previous_duration = settings[kind .. '_duration']
    if not finite_number(previous_duration) then previous_duration = 0 end
    update_segment_duration(kind, previous_duration + delta, video_duration)
end

-- “全部”对应 nil；手动选择对应扩展名数组。
local function update_extension_selection(choice)
    local selected = selected_extensions()
    local updated
    if choice ~= 'all' then
        if not is_video_extension(choice) then return end

        local choices = {}
        if selected then
            for _, extension in ipairs(selected) do choices[extension] = true end
            choices[choice] = not choices[choice]
        else
            choices[choice] = true
        end
        updated = {}
        for _, extension in ipairs(video_extensions) do
            if choices[extension] then updated[#updated + 1] = extension end
        end
    end
    if set_setting('extensions', updated) then
        hide_prompt()
        current.entered = {intro = false, outro = false}
        show_menu()
        update_position_timer()
    end
end

read_cache()

mp.register_script_message('open-settings', show_menu)
mp.register_script_message('toggle-settings', toggle_settings_menu)
mp.register_script_message('menu-action', function(json)
    local event = json and utils.parse_json(json)
    if event and event.type == 'close' then
        if mp.get_property('path') and menu_pause_before ~= nil then
            mp.set_property_native('pause', menu_pause_before)
        end
        menu_pause_before = nil
        update_position_timer()
        return
    end
    if not event or event.type ~= 'activate' or not menu_is_open() then return end
    if event.value == 'toggle' then
        if set_setting('enabled', not is_current_directory_enabled()) then
            hide_prompt()
            current.entered = {intro = false, outro = false}
            show_menu()
            update_position_timer()
        end
    elseif type(event.value) == 'string' and not event.action
        and event.value:match('^extension:') then
        update_extension_selection(event.value:sub(#'extension:' + 1))
    elseif event.value == 'intro' or event.value == 'outro' then
        if event.action == 'decrease' then
            adjust_segment_duration(event.value, -1)
        elseif event.action == 'increase' then
            adjust_segment_duration(event.value, 1)
        elseif not event.action then
            capture_segment_duration(event.value)
        end
    end
end)

if o.mode == 'manual' then
    mp.observe_property('mouse-pos', 'native', function()
        if prompt.kind then render_prompt() end
    end)
    mp.observe_property('osd-dimensions', 'native', function()
        if prompt.kind then render_prompt() end
    end)
end
mp.observe_property('pause', 'bool', function()
    update_position_timer()
end)
mp.observe_property('duration', 'number', function()
    update_position_timer()
end)
mp.observe_property('time-pos', 'number', function()
    if mp.get_property_native('pause') and current.directory then check_skip_position() end
end)
mp.register_event('file-loaded', function()
    refresh_current_file()
    update_position_timer()
end)
mp.register_event('end-file', function()
    if position_timer then position_timer:kill(); position_timer = nil end
    hide_prompt()
    current = {path = nil, directory = nil,
        extension = nil, entered = {intro = false, outro = false}}
    if menu_is_open() then
        show_menu()
    else
        menu_pause_before = nil
    end
end)
