local mp = require('mp')
local utils = require('mp.utils')

local history_path = '~~/danmaku-history.json'
local config_path = mp.find_config_file('script-opts/uosc_danmaku.conf')
local config_file = config_path and io.open(config_path, 'rb')
if config_file then
    for line in config_file:lines() do
        history_path = line:match('^%s*history_path%s*=%s*(.-)%s*$') or history_path
    end
    config_file:close()
end

local menu_type = 'danmaku_settings'
local switch_property = 'user-data/uosc_danmaku/danmaku-switch-on'
-- 保存等待原脚本确认的弹幕开关状态。
local pending_enabled = nil
local menu_actions = {
    { title = '弹幕搜索', message = 'open_search_danmaku_menu' },
    { title = '从源添加弹幕', message = 'open_add_source_menu' },
    { title = '弹幕源延迟设置', message = 'open_source_delay_menu' },
    { title = '弹幕样式', message = 'open_danmaku_style_menu' },
    { title = '弹幕内容', message = 'open_content_danmaku_menu' },
}

-- 读取当前视频在弹幕历史记录中的关联名称。
local function get_association_title()
    local history_file = io.open(mp.command_native({ 'expand-path', history_path }), 'rb')
    if not history_file then return '未关联弹幕' end

    local history = utils.parse_json(history_file:read('*a'))
    history_file:close()
    if type(history) ~= 'table' then return '未关联弹幕' end

    local path = mp.get_property('path')
    if not path then return '未关联弹幕' end
    local directory = utils.split_path(path)
    local association = history[directory]
    if type(association) ~= 'table' or not association.animeTitle or not association.episodeTitle then
        return '未关联弹幕'
    end

    local episode = association.episodeTitle:gsub('%s.-$', '')
    episode = episode:match('^(第.*[话回集]+)%s*') or episode
    return string.format('已关联弹幕：%s-%s', association.animeTitle, episode)
end

-- 构建弹幕设置菜单及其开关状态。
local function build_menu()
    local is_enabled = pending_enabled
    if is_enabled == nil then
        is_enabled = mp.get_property_bool(switch_property, false)
    end
    local items = {
        { title = get_association_title(), bold = true, italic = true, selectable = false },
        {
            title = '弹幕开关',
            hint = is_enabled and 'true' or 'false',
            active = is_enabled,
            keep_open = true,
            value = { 'script-message-to', mp.get_script_name(), 'toggle-danmaku' },
        },
    }

    for _, action in ipairs(menu_actions) do
        items[#items + 1] = {
            title = action.title,
            value = { 'script-message-to', 'uosc_danmaku', action.message },
        }
    end

    return utils.format_json({
        type = menu_type,
        title = '弹幕设置',
        search_style = 'disabled',
        items = items,
    })
end

-- 刷新当前打开的弹幕设置菜单。
local function update_open_menu()
    if mp.get_property_native('user-data/uosc/menu/type') == menu_type then
        mp.commandv('script-message-to', 'uosc', 'update-menu', build_menu())
    end
end

local function open_menu()
    mp.commandv('script-message-to', 'uosc', 'open-menu', build_menu())
end

mp.register_script_message('open', open_menu)

mp.register_script_message('toggle-menu', function()
    if mp.get_property_native('user-data/uosc/menu/type') == menu_type then
        mp.commandv('script-message-to', 'uosc', 'close-menu', menu_type)
    else
        open_menu()
    end
end)

mp.register_script_message('toggle-danmaku', function()
    local is_enabled = pending_enabled
    if is_enabled == nil then
        is_enabled = mp.get_property_bool(switch_property, false)
    end
    pending_enabled = not is_enabled
    update_open_menu()
    local next_value = pending_enabled and 'on' or 'off'
    mp.commandv('script-message-to', 'uosc_danmaku', 'set', 'show_danmaku', next_value)
end)

mp.observe_property(switch_property, 'bool', function(_, is_enabled)
    if pending_enabled == nil or pending_enabled == is_enabled then
        pending_enabled = nil
        update_open_menu()
    end
end)
