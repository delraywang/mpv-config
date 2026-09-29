local msg = require('mp.msg')
local options = require('mp.options')
local utils = require('mp.utils')

local settings = {
    enabled = true,
    cache_path = '~~/files/folder-speed-lock.json',
}
options.read_options(settings, 'folder-speed-lock')
if not settings.enabled then return end

local cache_path = mp.command_native({'expand-path', settings.cache_path})
-- 目录与播放速度的缓存映射。
local speed_by_folder = {}
local cache_read_failed = false

-- 当前本地文件的目录、速度和播放状态。
local current_folder = nil
local current_speed = nil
local local_file_active = false

local temp_file_counter = 0

local is_windows = package.config:sub(1, 1) == '\\'
local windows_file_api
if is_windows then
    -- Windows 文件替换接口。
    local ffi = require('ffi')
    ffi.cdef[[
        int __stdcall MultiByteToWideChar(unsigned int code_page, unsigned long flags,
            const char *input, int input_length, wchar_t *output, int output_length);
        int __stdcall MoveFileExW(const wchar_t *source, const wchar_t *destination, unsigned long flags);
        unsigned long __stdcall GetLastError(void);
    ]]
    windows_file_api = {ffi = ffi, kernel32 = ffi.load('kernel32')}
end

local function is_valid_speed(speed)
    return type(speed) == 'number' and speed == speed and speed > 0 and speed < math.huge
end

-- 获取本地视频所在目录。
local function get_local_folder(path)
    if type(path) ~= 'string' or path == '' or path:match('^%a[%w.+-]*://') then return nil end
    local normalized = mp.command_native({'normalize-path', path})
    if type(normalized) ~= 'string' then return nil end
    local folder = utils.split_path(normalized)
    return folder ~= '' and folder or nil
end

-- 读取并验证目录速度缓存。
local function load_speed_cache()
    local file, open_error = io.open(cache_path, 'rb')
    if not file then
        if not utils.file_info(cache_path) then return end
        cache_read_failed = true
        msg.error('无法读取目录速度缓存：' .. tostring(open_error))
        return
    end
    local contents = file:read('*a')
    local closed, close_error = file:close()
    if not contents or not closed then
        cache_read_failed = true
        msg.error('无法读取目录速度缓存：' .. tostring(close_error or '读取失败'))
        return
    end
    local parsed = utils.parse_json(contents)
    if type(parsed) ~= 'table' then
        cache_read_failed = true
        msg.error('目录速度缓存格式无效：' .. cache_path)
        return
    end
    for folder, speed in pairs(parsed) do
        if type(folder) ~= 'string' or not is_valid_speed(speed)
            or (folder:sub(-1) ~= '/' and folder:sub(-1) ~= '\\')
            or folder:match('^%a[%w.+-]*://') then
            cache_read_failed = true
            msg.error('目录速度缓存只接受本地目录和正数速度：' .. cache_path)
            return
        end
    end
    speed_by_folder = parsed
end

-- 替换缓存文件。
local function replace_cache_file(source, destination)
    if not is_windows then return os.rename(source, destination) end
    local ffi, kernel32 = windows_file_api.ffi, windows_file_api.kernel32
    -- 将 UTF-8 路径转换为 Windows 宽字符路径。
    local function to_wide_path(path)
        local length = kernel32.MultiByteToWideChar(65001, 0, path, #path, nil, 0)
        if length == 0 then return nil end
        local wide = ffi.new('wchar_t[?]', length + 1)
        if kernel32.MultiByteToWideChar(65001, 0, path, #path, wide, length) == 0 then return nil end
        return wide
    end
    local wide_source, wide_destination = to_wide_path(source), to_wide_path(destination)
    if not wide_source or not wide_destination then return nil, '无法转换缓存路径编码' end
    if kernel32.MoveFileExW(wide_source, wide_destination, 0x1 + 0x8) == 0 then
        return nil, 'MoveFileExW 失败，错误码 ' .. tostring(kernel32.GetLastError())
    end
    return true
end

-- 将目录速度缓存写入文件。
local function write_speed_cache()
    if cache_read_failed then return false end
    local contents = utils.format_json(speed_by_folder)
    if type(contents) ~= 'string' then
        msg.error('目录速度缓存序列化失败')
        return false
    end
    temp_file_counter = temp_file_counter + 1
    local temp_path = cache_path .. '.tmp.' .. tostring(mp.get_time()):gsub('%.', '')
        .. '.' .. tostring(temp_file_counter)
    local file, open_error = io.open(temp_path, 'wb')
    if not file then
        msg.error('无法写入目录速度缓存：' .. tostring(open_error))
        return false
    end
    local written, write_error = file:write(contents)
    local closed, close_error = file:close()
    if not written or not closed then
        os.remove(temp_path)
        msg.error('无法写入目录速度缓存：' .. tostring(write_error or close_error))
        return false
    end
    local replaced, replace_error = replace_cache_file(temp_path, cache_path)
    if not replaced then
        os.remove(temp_path)
        msg.error('无法替换目录速度缓存：' .. tostring(replace_error))
        return false
    end
    return true
end

-- 保存当前目录的播放速度。
local function save_current_folder_speed()
    if not current_folder or not is_valid_speed(current_speed) or cache_read_failed then return end
    if speed_by_folder[current_folder] == current_speed then return end
    local previous_speed = speed_by_folder[current_folder]
    speed_by_folder[current_folder] = current_speed
    if not write_speed_cache() then speed_by_folder[current_folder] = previous_speed end
end

load_speed_cache()

-- 跟踪当前文件的播放速度。
mp.observe_property('speed', 'number', function(_, speed)
    if local_file_active and is_valid_speed(speed) then current_speed = speed end
end)

-- 记录文件卸载时的播放速度。
mp.add_hook('on_unload', 50, function()
    if local_file_active then
        local speed = mp.get_property_number('speed')
        if is_valid_speed(speed) then current_speed = speed end
    end
    local_file_active = false
end)

-- 清除当前文件的播放状态。
mp.register_event('end-file', function()
    local_file_active = false
end)

-- 下一个文件开始加载时保存前一个目录的播放速度。
mp.register_event('start-file', function()
    save_current_folder_speed()
    current_folder, current_speed, local_file_active = nil, nil, false
end)

-- 应用当前目录的缓存速度。
mp.register_event('file-loaded', function()
    local folder = get_local_folder(mp.get_property('path'))
    if not folder then return end
    local speed = speed_by_folder[folder] or 1
    current_folder, current_speed, local_file_active = folder, speed, true
    mp.set_property_number('speed', speed)
    msg.info('恢复播放速度：' .. tostring(speed) .. 'x')
end)

-- 退出播放器时保存当前目录的播放速度。
mp.register_event('shutdown', function()
    if local_file_active then
        local speed = mp.get_property_number('speed')
        if is_valid_speed(speed) then current_speed = speed end
    end
    save_current_folder_speed()
end)
