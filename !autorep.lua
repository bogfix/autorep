script_author('White_Gasparov (bogfix)')
script_name("AutoRep")
script_properties('work-in-pause')
script_version('2.1')
-- Базовые зависимости
require "moonloader"
local inicfg = require 'inicfg'

-- Проверка и загрузка дополнительных библиотек
local imgui_check, imgui = pcall(require, 'mimgui')
local samp_check, sampev = pcall(require, 'samp.events')
local fawesome_check, faicons = pcall(require, 'fAwesome6')
local req_check, requests = pcall(require, 'requests')
local ev = require "moonloader".audiostream_state
local vk = require "vkeys"
local encoding = require 'encoding'
encoding.default = 'CP1251'
u8 = encoding.UTF8

-- Конфигурация
local sw, sh = getScreenResolution()
local cfg = inicfg.load({
    main = {
        posx = sw / 2,
        posy = sh / 2,
        dialog = false,
        sound = nil,
        valuesound = 0.5,
        killafk = false,
        killesc = false,
        flash = false,
        showwin = false,
        winmsg = false,
        bind = '[81]', -- Q по умолчанию
    },
    color = {0.2, 0.3, 0.4, 1.00},
}, "autorep")

if not doesFileExist('moonloader/config/autorep.ini') then 
    inicfg.save(cfg, 'autorep.ini') 
end

-- FFI определения
local ffi = require 'ffi'
local shell32 = ffi.load('shell32')
local comdlg32 = ffi.load("comdlg32")
local kernel32 = ffi.load("kernel32")

ffi.cdef([[
    // Константы для FileDialog
    static const int OFN_FILEMUSTEXIST  = 0x1000;
    static const int OFN_NOCHANGEDIR    = 8;
    static const int OFN_PATHMUSTEXIST  = 0x800;

    // Базовые типы
    typedef int BOOL;
    typedef char CHAR;
    typedef unsigned short WORD;
    typedef unsigned long DWORD;
    typedef void* HANDLE;
    typedef HANDLE HWND;
    typedef HANDLE HINSTANCE;
    typedef const char* LPCSTR;
    typedef char* LPSTR;
    typedef long LPARAM;
    typedef void* LPOFNHOOKPROC;

    // Структура OPENFILENAME
    typedef struct {
        DWORD         lStructSize;
        HWND          hwndOwner;
        HINSTANCE     hInstance;
        LPCSTR        lpstrFilter;
        LPSTR         lpstrCustomFilter;
        DWORD         nMaxCustFilter;
        DWORD         nFilterIndex;
        LPSTR         lpstrFile;
        DWORD         nMaxFile;
        LPSTR         lpstrFileTitle;
        DWORD         nMaxFileTitle;
        LPCSTR        lpstrInitialDir;
        LPCSTR        lpstrTitle;
        DWORD         flags;
        WORD          nFileOffset;
        WORD          nFileExtension;
        LPCSTR        lpstrDefExt;
        LPARAM        lCustData;
        LPOFNHOOKPROC lpfnHook;
        LPCSTR        lpTemplateName;
        void*         pvReserved;
        DWORD         dwReserved;
        DWORD         flagsEx;
    } OPENFILENAME;

    // Функции для FileDialog
    BOOL GetSaveFileNameA(OPENFILENAME *lpofn);
    BOOL GetOpenFileNameA(OPENFILENAME *lpofn);
    DWORD GetLastError(void);

    // Функции для управления окном и мигания
    HWND GetActiveWindow(void);
    BOOL ShowWindow(HWND hWnd, int nCmdShow);
    BOOL FlashWindow(HWND hWnd, BOOL bInvert);

    // Типы и функции для уведомлений
    typedef void* HICON;
    typedef struct {
        DWORD Data[4]; // Определение GUID как массив из 4 DWORD
    } GUID;

    typedef struct {
        DWORD cbSize;
        HWND  hWnd;
        UINT  uID;
        UINT  uFlags;
        UINT  uCallbackMessage;
        HICON hIcon;
        CHAR  szTip[128];
        DWORD dwState;
        DWORD dwStateMask;
        CHAR  szInfo[256];
        union {
            UINT uTimeout;
            UINT uVersion;
        };
        CHAR  szInfoTitle[64];
        DWORD dwInfoFlags;
        GUID  guidItem;
        HICON hBalloonIcon;
    } NOTIFYICONDATAA;

    BOOL Shell_NotifyIconA(DWORD dwMessage, NOTIFYICONDATAA *lpData);
    HICON LoadIconA(HINSTANCE hInstance, LPCSTR lpIconName);
    BOOL DestroyIcon(HICON hIcon);
    HINSTANCE GetModuleHandleA(LPCSTR lpModuleName);
]])

-- Встроенная библиотека HotkeyManager
local HotkeyManager = {
    Config = {
        DebounceTime = 0.2,
        CancelKey = 0x1B, -- ESC
        RemoveKey = 0x08, -- Backspace
    },
    Text = {
        WaitForKey = "Press any key...",
        NoKey = "< None >"
    },
    Hotkeys = {},
    ActiveKeys = {},
    Editing = nil,
    LastTriggerTime = {},
}

local specialKeys = {
    [vk.VK_SHIFT] = true,
    [vk.VK_CONTROL] = true,
    [vk.VK_MENU] = true,
    [vk.VK_LMENU] = true,
    [vk.VK_RMENU] = true
}

local function tableContains(tbl, value)
    for _, v in ipairs(tbl) do
        if v == value then return true end
    end
    return false
end

local function getKeyComboString(keys)
    if not keys or #keys == 0 then return HotkeyManager.Text.NoKey end
    local names = {}
    for _, key in ipairs(keys) do
        table.insert(names, vk.id_to_name(key))
    end
    return table.concat(names, " + ")
end

function HotkeyManager:Register(name, defaultKeys, callback)
    if not self.Hotkeys[name] then
        self.Hotkeys[name] = {
            keys = defaultKeys or {},
            callback = callback,
            soloKey = defaultKeys and #defaultKeys == 1,
            lastTriggered = 0,
            triggered = false
        }
        return {
            name = name,
            Set = function(_, newKeys) return HotkeyManager:SetKeys(name, newKeys) end,
            Get = function() return HotkeyManager:GetKeys(name) end,
            Show = function(_, size) return HotkeyManager:ShowButton(name, size) end,
            Remove = function() return HotkeyManager:Remove(name) end
        }
    end
    return nil
end

function HotkeyManager:SetKeys(name, keys)
    if self.Hotkeys[name] then
        self.Hotkeys[name].keys = keys
        self.Hotkeys[name].soloKey = #keys == 1
        self.Hotkeys[name].lastTriggered = 0 -- Сбрасываем время последнего срабатывания
        self.Hotkeys[name].triggered = false -- Сбрасываем состояние
        -- Сбрасываем ActiveKeys, чтобы избежать конфликтов
        for _, key in ipairs(self.Hotkeys[name].keys) do
            for i, activeKey in ipairs(HotkeyManager.ActiveKeys) do
                if activeKey == key then
                    table.remove(HotkeyManager.ActiveKeys, i)
                    break
                end
            end
        end
        return true
    end
    return false
end

function HotkeyManager:GetKeys(name)
    return self.Hotkeys[name] and self.Hotkeys[name].keys or nil
end

function HotkeyManager:Remove(name)
    self.Hotkeys[name] = nil
    return true
end

function HotkeyManager:ShowButton(name, size)
    local hotkey = self.Hotkeys[name]
    if not hotkey then
        imgui.Button("Hotkey not found", size)
        return false
    end

    local isEditing = self.Editing and self.Editing.name == name
    local label = isEditing and self.Text.WaitForKey or getKeyComboString(hotkey.keys)
    
    if imgui.Button(label .. "##" .. name, size) then
        self.Editing = {
            name = name,
            originalKeys = hotkey.keys,
            tempKeys = {},
            pressedKeys = {}
        }
        hotkey.keys = {}
    end
    
    return isEditing and not self.Editing
end

local function checkCombo(combo, activeKeys)
    if #combo ~= #activeKeys then return false end
    local sortedCombo = {table.unpack(combo)}
    local sortedActive = {table.unpack(activeKeys)}
    table.sort(sortedCombo)
    table.sort(sortedActive)
    
    for i = 1, #combo do
        if sortedCombo[i] ~= sortedActive[i] then return false end
    end
    return true
end

-- Уведомления Windows
local WindowsNotificationIcon = {
    None = 0,
    Application = 32512,
    Error = 32513,
    Question = 32514,
    Warning = 32515,
    Information = 32516,
    Security = 32518
}

function showWindowsNotification(iconType, title, text)
    local noIcon = iconType == nil
    local hInstance = noIcon and ffi.C.GetModuleHandleA(nil) or nil
    local iconTypeValue = noIcon and 100 or (iconType or 0)

    local function copy_string(dest_array_ptr, str)
        ffi.copy(dest_array_ptr, (str or ""):sub(1, ffi.sizeof(dest_array_ptr) - 1))
    end

    local tray_icon_handle = ffi.C.LoadIconA(hInstance, ffi.cast("LPCSTR", iconTypeValue))
    local balloon_icon_handle = ffi.C.LoadIconA(hInstance, ffi.cast("LPCSTR", iconTypeValue))

    local notify_icon_data = ffi.new('NOTIFYICONDATAA')
    notify_icon_data.cbSize = ffi.sizeof(notify_icon_data)
    notify_icon_data.hWnd = ffi.cast('HWND', readMemory(0x00C8CF88, 4, false))
    notify_icon_data.uFlags = 1 + 2
    notify_icon_data.hIcon = tray_icon_handle
    notify_icon_data.uVersion = 4
    notify_icon_data.hBalloonIcon = balloon_icon_handle

    shell32.Shell_NotifyIconA(0, notify_icon_data)
    shell32.Shell_NotifyIconA(4, notify_icon_data)

    notify_icon_data.uFlags = 1 + 2 + 16
    notify_icon_data.dwInfoFlags = iconTypeValue == 0 and 0 or 4 + 32
    copy_string(notify_icon_data.szInfoTitle, title)
    copy_string(notify_icon_data.szInfo, text)
    
    shell32.Shell_NotifyIconA(1, notify_icon_data)
    lua_thread.create(function()
        wait(5000)
        shell32.Shell_NotifyIconA(2, notify_icon_data)
        ffi.C.DestroyIcon(balloon_icon_handle)
        ffi.C.DestroyIcon(tray_icon_handle)
    end)
end

function FileDialog(saveDialog, fileTypes, defaultDir)
    local ofn = ffi.new("OPENFILENAME")
    local fileBuffer = ffi.new("char[260]", "\0")

    -- Формируем строку фильтра
    local filterStr = ""
    if fileTypes == "audio" then
        filterStr = "Аудио Файлы\0*.mp3;*.wav;*.ogg\0Все файлы\0*.*\0\0"
    elseif fileTypes == "image" then
        filterStr = "Картинки\0*.png;*.jpg;*.jpeg;*.bmp\0Все файлы\0*.*\0\0"
    elseif fileTypes == "audio_image" then
        filterStr = "Аудио и Картинки\0*.mp3;*.wav;*.ogg;*.png;*.jpg;*.jpeg;*.bmp\0Все файлы\0*.*\0\0"
    else
        filterStr = "Все файлы\0*.*\0\0" -- По умолчанию все файлы
    end

    ofn.lStructSize = ffi.sizeof(ofn)
    ofn.hwndOwner = nil
    ofn.lpstrFile = fileBuffer
    ofn.nMaxFile = ffi.sizeof(fileBuffer)
    ofn.lpstrFilter = filterStr
    ofn.nFilterIndex = 1 -- Индекс выбранного фильтра (1 - первый в списке)
    ofn.lpstrInitialDir = defaultDir or getWorkingDirectory()
    ofn.flags = bit.bor(comdlg32.OFN_PATHMUSTEXIST, comdlg32.OFN_FILEMUSTEXIST, comdlg32.OFN_NOCHANGEDIR)

    local result = saveDialog and comdlg32.GetSaveFileNameA(ofn) or comdlg32.GetOpenFileNameA(ofn)
    if result ~= 0 then
        return true, ffi.string(ofn.lpstrFile)
    else
        local errorCode = kernel32.GetLastError()
        return false, errorCode == 0 and "Отмена пользователем" or ("Ошибка: " .. errorCode)
    end
end

-- Глобальные переменные
local mainWin = imgui.new.bool()
local repWin = imgui.new.bool()
local killafk = imgui.new.bool(cfg.main.killafk)
local killesc = imgui.new.bool(cfg.main.killesc)
local flash = imgui.new.bool(cfg.main.flash)
local showwin = imgui.new.bool(cfg.main.showwin)
local winmsg = imgui.new.bool(cfg.main.winmsg)
local count = 0
local startTime = nil
local dialog = imgui.new.bool(cfg.main.dialog)
local active = false
local block = false
local valuesound = imgui.new.float(cfg.main.valuesound)
local color = imgui.new.float[4](cfg.color)
local bind

-- Автообновления
function update()
    local raw = "https://raw.githubusercontent.com/bogfix/autorep/main/version.json"
    local dlstatus = require('moonloader').download_status
    local requests = require('requests')
    local f = {}
    function f:getLastVersion()
        local response = requests.get(raw)
        if response.status_code == 200 then
            return decodeJson(response.text)['last']
        else
            return 'UNKNOWN'
        end
    end
    function f:download()
        local response = requests.get(raw)
        if response.status_code == 200 then
            downloadUrlToFile(decodeJson(response.text)['url'], thisScript().path, function (id, status, p1, p2)
                print('Скачиваю '..decodeJson(response.text)['url']..' в '..thisScript().path)
                if status == dlstatus.STATUSEX_ENDDOWNLOAD then
                    sms('Скрипт обновлен, перезагрузка...', -1)
                    thisScript():reload()
                end
            end)
        else
            err('Ошибка, невозможно установить обновление, код: '..response.status_code, -1)
        end
    end
    return f
end

-- Основная функция
function main()
    if not isSampLoaded() or not isSampfuncsLoaded() then return end
    while not isSampAvailable() do wait(100) end
    local lastver = update():getLastVersion()
    hwin = ffi.C.GetActiveWindow()
    -- Проверка библиотек
    local libs = {
        ['Mimgui'] = imgui_check,
        ['SAMP.Lua'] = samp_check,
        ['fAwesome6'] = fawesome_check,
        ['requests'] = req_check,
    }
    local libs_no_found = {}
    for k, v in pairs(libs) do
        if not v then 
            table.insert(libs_no_found, k)
            sampAddChatMessage('« AutoRep » {FFFFFF}У Вас отсутствует библиотека {34EBE8}' .. k .. '{FFFFFF}. Без неё скрипт {34EBE8}не будет {FFFFFF}работать!', 0x7172ee)
        end
    end
    if #libs_no_found > 0 then
        sampShowDialog(18364, '{34EBE8}AutoRep', string.format('{FFFFFF}В Вашей сборке {34EBE8}нету необходимых библиотек{FFFFFF} для работы скрипта.\nБез них он {34EBE8}не будет{FFFFFF} работать!\n\nБиблиотеки, которые Вам нужны:\n{FFFFFF}- {34EBE8}%s\n\n{FFFFFF}Обратитесь к автору скрипта (White_Gasparov) для получения библиотек.', table.concat(libs_no_found, '\n{FFFFFF}- {34EBE8}')), 'Принять', '', 0)
        thisScript():unload()
        return
    end

    -- Регистрация горячей клавиши
    bind = HotkeyManager:Register('bind', decodeJson(cfg.main.bind), function()
        if not block and not sampIsCursorActive() then
            active = not active
            if active then 
                sampSendChat('/ot')
            end
            repWin[0] = not repWin[0]
            sms('Статус: '..(active and '{39fc03}ON.' or '{fc0303}OFF.'))
            startTime = nil 
            count = 0
        end
    end)

    -- Регистрация команд
    sampRegisterChatCommand("autorep", function()
        mainWin[0] = not mainWin[0]
    end)

    sampRegisterChatCommand("aunblock", function()
        if block then   
            block = false
            sms('Блокировка скрипта отключена')
        else 
            err('У вас нет активного блокиратора!')
        end
    end)

    -- Инициализация
    while not sampIsLocalPlayerSpawned() do wait(0) end
    sms('Автор - bogfix | Запущен | Активация: {E5261A}/autorep')
    sms('Активация ловли: {fa3737}'..showbutton(bind))
    if doesFileExist(cfg.main.sound) then
        sms('Установлен звук: {f2e600}' .. cfg.main.sound)
    end
    if thisScript().version ~= lastver then
        sampRegisterChatCommand('autorep_upd', function()
            update():download()
        end)
        sms('Вышло обновление скрипта ('..thisScript().version..' -> '..lastver..'), введите /autorep_upd для обновления!')
    end
    -- Основной цикл
    while true do
        wait(0)
        if isPauseMenuActive() and active and killesc[0] then
            err('Вы встали в АФК! Ловля отключена!')
            active = false
            repWin[0] = false
        end
    end
end

-- Обновим обработчик событий
addEventHandler('onWindowMessage', function(msg, key, lparam)
    local isKeyDown = msg == 0x100 or msg == 260
    local isKeyUp = msg == 0x101 or msg == 261
    local currentTime = os.clock()

    if HotkeyManager.Editing then
        if isKeyDown then
            if not tableContains(HotkeyManager.Editing.pressedKeys, key) then
                table.insert(HotkeyManager.Editing.pressedKeys, key)
                table.insert(HotkeyManager.Editing.tempKeys, key)
            end
            if key == HotkeyManager.Config.CancelKey then
                HotkeyManager.Hotkeys[HotkeyManager.Editing.name].keys = HotkeyManager.Editing.originalKeys
                HotkeyManager.Editing = nil
            elseif key == HotkeyManager.Config.RemoveKey then
                HotkeyManager.Hotkeys[HotkeyManager.Editing.name].keys = {}
                HotkeyManager.Editing = nil
            end
            consumeWindowMessage(true, true)
        elseif isKeyUp then
            for i, v in ipairs(HotkeyManager.Editing.pressedKeys) do
                if v == key then
                    table.remove(HotkeyManager.Editing.pressedKeys, i)
                    break
                end
            end
            if #HotkeyManager.Editing.pressedKeys == 0 then
                HotkeyManager.Hotkeys[HotkeyManager.Editing.name].keys = HotkeyManager.Editing.tempKeys
                HotkeyManager.Editing = nil
            end
            consumeWindowMessage(true, true)
        end
        return
    end

    if isKeyDown and not tableContains(HotkeyManager.ActiveKeys, key) then
        table.insert(HotkeyManager.ActiveKeys, key)
    elseif isKeyUp and tableContains(HotkeyManager.ActiveKeys, key) then
        for i, v in ipairs(HotkeyManager.ActiveKeys) do
            if v == key then
                table.remove(HotkeyManager.ActiveKeys, i)
                break
            end
        end
        for name, hotkey in pairs(HotkeyManager.Hotkeys) do
            if tableContains(hotkey.keys, key) then
                hotkey.triggered = false
            end
        end
    end

    if isKeyDown and not HotkeyManager.Editing then
        for name, hotkey in pairs(HotkeyManager.Hotkeys) do
            if checkCombo(hotkey.keys, HotkeyManager.ActiveKeys) then
                local timeSinceLast = currentTime - (hotkey.lastTriggered or 0)
                if timeSinceLast >= HotkeyManager.Config.DebounceTime and not hotkey.triggered then
                    hotkey.lastTriggered = currentTime
                    hotkey.triggered = true
                    hotkey.callback()
                end
            end
        end
    end

    -- Обрабатываем сворачивание окна (WM_ACTIVATE, msg == 0x0006)
    if msg == 0x0006 then
        local isMinimized = lparam == 0 -- Окно свернуто
        if isMinimized then
            -- Сбрасываем ActiveKeys при сворачивании
            HotkeyManager.ActiveKeys = {}
            -- Сбрасываем triggered для всех хоткеев
            for name, hotkey in pairs(HotkeyManager.Hotkeys) do
                hotkey.triggered = false
            end
            -- Останавливаем звук, если он воспроизводится
            if currentSound and isPlaying then
                setAudioStreamState(currentSound, ev.STOP)
                isPlaying = false
            end
        end
    end

    if killafk[0] and active and msg == 0x0008 then
        active = false
        repWin[0] = false
        err('Вы свернули игру! Ловля отключена!')
    end
end)

-- Интерфейс
local posX, posY = cfg.main.posx, cfg.main.posy
local lastkeys = nil
local isPlaying = false
local currentSound = nil
local mainWinFrame = imgui.OnFrame(
    function() return mainWin[0] end,
    function(player)
        player.HideCursor = false
        imgui.SetNextWindowSize(imgui.ImVec2(800, 600), imgui.Cond.FirstUseEver)
        imgui.SetNextWindowPos(imgui.ImVec2(sw / 2, sh / 2), imgui.Cond.FirstUseEver, imgui.ImVec2(0.5, 0.5))
        imgui.Begin(u8'« AutoRep » Автор bogfix [Special for 18]', mainWin, imgui.WindowFlags.NoResize + imgui.WindowFlags.NoCollapse + imgui.WindowFlags.AlwaysUseWindowPadding)
        
        if imgui.Link(faicons.BUG.. u8"Нашёл баг или хочешь предложить идею? Напиши разработчику!", u8'Нажми на ссылку и тебе откроет ТГ') then
            os.execute(('explorer.exe "%s"'):format("https://t.me/bogfix"))
        end
        
        imgui.Text(faicons.KEYBOARD ..u8' Активация скрипта:')
        imgui.SameLine()
        bind:Show(imgui.ImVec2(150, 25))

        local currentKeys = bind:Get()
        if currentKeys and lastKeys and encodeJson(currentKeys) ~= encodeJson(lastKeys) then
            cfg.main.bind = encodeJson(currentKeys)
            if inicfg.save(cfg, 'autorep.ini') then
                sms('Горячая клавиша сохранена: ' .. showbutton(bind))
            else
                err('Не удалось сохранить конфиг!')
            end
        end
        lastKeys = currentKeys

        imgui.Text(faicons.TABLE.. u8" Положение индикатора репорта")
        imgui.SameLine()
        if imgui.Button(u8"Изменить") then
            move()
        end

        imgui.Separator()
        local sound = cfg.main.sound
        local soundtext = doesFileExist(sound) and faicons.FOLDER.. u8(' Установлено: ' .. sound) or faicons.VOLUME_XMARK.. u8(' Отсутствует звуковое уведомление')
        local button_text = doesFileExist(sound) and u8(" Выбрать другой звук") or u8(" Нажми чтобы выбрать звук")

        if doesFileExist(sound) then
            local buttonIcon = isPlaying and faicons.PAUSE or faicons.PLAY
            if imgui.Button(buttonIcon .. "##playPauseButton") then
                if not isPlaying then
                    if currentSound then
                        setAudioStreamState(currentSound, ev.STOP)
                        currentSound = nil
                    end
                    currentSound = loadAudioStream(cfg.main.sound)
                    if currentSound then
                        setAudioStreamVolume(currentSound, valuesound[0])
                        setAudioStreamState(currentSound, ev.PLAY)
                        isPlaying = true
        
                        lua_thread.create(function()
                            while isPlaying do
                                wait(100)
                                if currentSound then
                                    local state = getAudioStreamState(currentSound)
                                    if state == ev.STOP then
                                        isPlaying = false
                                        currentSound = nil
                                        break
                                    end
                                else
                                    isPlaying = false
                                    break
                                end
                            end
                        end)
                    end
                else
                    if currentSound then
                        setAudioStreamState(currentSound, ev.STOP) -- Используем STOP вместо PAUSE
                        isPlaying = false
                    end
                end
            end
            imgui.SameLine()
            imgui.Text(soundtext)
        end
        
        if imgui.Button(faicons.FILE_AUDIO.. button_text) then
            local status, sound = FileDialog(false, "audio", defaultDir)
            if status then
                cfg.main.sound = sound
                inicfg.save(cfg, 'autorep.ini')
                if doesFileExist(sound) then
                    sms('Установлен звук: {f2e600}' .. sound)
                else
                    err('Вы не выбрали звук!')
                end
            end
        end
        
        if doesFileExist(sound) then
            imgui.PushItemWidth(147.5)
            if imgui.SliderFloat(faicons.CODE_COMMIT..u8' Громкость звуков', valuesound, 0.0, 1.0) then
                cfg.main.valuesound = valuesound[0]
                inicfg.save(cfg, 'autorep.ini')
            end
            imgui.TextQuestion(u8"Что за звук?", u8'Если нажать на кнопку и указать звуковой файл то при получении репорта включится указанный звук.')
            if cfg.main.sound and imgui.Button(faicons.TRASH.. u8" Убрать звук из конфига") then
                cfg.main.sound = nil
                inicfg.save(cfg, 'autorep.ini')
                sms('Звук был успешно очищен')
            end
        end
        
        imgui.Separator()
        imgui.Text(faicons.GEARS.. u8' Настройка отключений')
        if imgui.Checkbox(u8"Выключать при получении диалога", dialog) then
            cfg.main.dialog = dialog[0]
            inicfg.save(cfg, 'autorep.ini')
        end
        if imgui.Checkbox(u8"Выключать при сворачивании", killafk) then
            cfg.main.killafk = killafk[0]
            inicfg.save(cfg, 'autorep.ini')
        end
        if imgui.Checkbox(u8"Выключать при ESC", killesc) then
            cfg.main.killesc = killesc[0]
            inicfg.save(cfg, 'autorep.ini')
        end
        
        imgui.Separator()
        imgui.Text(faicons.GEARS.. u8' Другие настройки')
        if imgui.Checkbox(u8"Уведомление от Windows", winmsg) then
            cfg.main.winmsg = winmsg[0]
            inicfg.save(cfg, 'autorep.ini')
        end
        if imgui.Checkbox(u8"Мигать окном", flash) then
            cfg.main.flash = flash[0]
            inicfg.save(cfg, 'autorep.ini')
        end
        if imgui.Checkbox(u8"Разворачивать игру", showwin) then
            cfg.main.showwin = showwin[0]
            inicfg.save(cfg, 'autorep.ini')
        end
        imgui.TextQuestion(faicons.CIRCLE_INFO.. u8"Что за отключения?", u8'Если включена ловля и какое либо событие то она выключается.')
        
        imgui.Separator()
        imgui.Text(faicons.PALETTE.. u8' Цвета ловли:')
        if imgui.ColorEdit4('', color, imgui.ColorEditFlags.NoInputs + imgui.ColorEditFlags.NoAlpha) then
            cfg.color = {color[0], color[1], color[2], color[3]}
            inicfg.save(cfg, 'autorep.ini')
            imgui.Theme()
        end
        imgui.End()
    end
)

local repWinFrame = imgui.OnFrame(
    function() return repWin[0] end,
    function(player)
        player.HideCursor = true
        if not startTime then startTime = os.time() end
        local elapsedTime = os.time() - startTime
        imgui.SetNextWindowSize(imgui.ImVec2(110, 50), imgui.Cond.FirstUseEver)
        imgui.SetNextWindowPos(imgui.ImVec2(posX, posY), imgui.Cond.Always, imgui.ImVec2(0.5, 0.5))
        imgui.Begin('##Report', nil, imgui.WindowFlags.NoResize + imgui.WindowFlags.NoMove + imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoTitleBar)
        imgui.Text(faicons.EYE .. u8' Попытки:'..(count or 0))
        imgui.Separator()
        imgui.Text(faicons.CLOCK .. u8(string.format(" Время: %02d:%02d", math.floor(elapsedTime / 60) % 60, elapsedTime % 60)))
        imgui.End()
    end
)


-- SAMP события
function sampev.onServerMessage(clr, text)
    local type, rep, id, report, warning = text:match('%[(%W+)%] от (%w+_%w+)%[(%d+)%]:(.+) Уже (%d+) жалоб!!!')
    local hex = intToHex(join_rgb(color[0] * 255, color[1] * 255, color[2] * 255))
    local hexColor = tonumber('0x' .. hex)
    
    if active and rep and report then
        sampAddChatMessage('[Репорт] от '..rep..'['..id..']:{FFFFFF}'..report..' {E5261A}['..warning..']', hexColor)
        sampSendChat('/ot')
    end
    
    if text:find('Сейчас нет вопросов в репорт!') and repWin[0] then
        count = count + 1
    end
    
    if text:find('У Вас нет доступа') and active then
        block = true
        active = false
        repWin[0] = false
        err('Скрипт посчитал что вы не администратор, если это не так введите /aunblock')
    end
end

function sampev.onShowDialog(dialogId, style, title, button1, button2, text)
    if dialogId == 1334 and active then
        active = false
        repWin[0] = false
        sms('Статус: {fc0303}OFF. {FFFFFF}Был пойман репорт!')

        if winmsg[0] then 
            showWindowsNotification(WindowsNotificationIcon.Warning, 'AutoRep', 'Вы словили репорт! Свернитесь в игру!')
        end

        if flash[0] then
            local hwnd = ffi.cast('HWND**', 0xC17054)[0][0]
            ffi.C.FlashWindow(hwnd, true)
        end
        if showwin[0] then
            ffi.C.ShowWindow(hwin, 3)
        end
        if cfg.main.sound then
            local sound = loadAudioStream(cfg.main.sound)
            if sound then 
                setAudioStreamVolume(sound, valuesound[0])
                setAudioStreamState(sound, ev.PLAY)
            end
        end
    end
    
    if dialog[0] and active then 
        err("Активен диалог. Ловля отключена!")
        active = false
        repWin[0] = false
    end
end

-- Вспомогательные функции
function sms(text)
    local hex = intToHex(join_rgb(color[0] * 255, color[1] * 255, color[2] * 255))
    local hexColor = tonumber('0x' .. hex)
    text = tostring(text):gsub('{mc}', '{' .. hexColor .. '}'):gsub('{%-1}', '{FFFFFF}')
    sampAddChatMessage(string.format('« %s » {FFFFFF}%s', thisScript().name, text), hexColor)
end

function err(text)
    local hex = intToHex(join_rgb(color[0] * 255, color[1] * 255, color[2] * 255))
    local hexColor = tonumber('0x' .. hex)
    text = tostring(text):gsub('{mc}', '{' .. hexColor .. '}'):gsub('{%-1}', '{FFFFFF}')
    sampAddChatMessage(string.format('« %s » {FFFFFF}%s', thisScript().name, '{fa3737}[Ошибка]: {ffffff}' .. text), hexColor)
end

function showbutton(bind_arg)
    local hotkey = bind_arg:Get()
    if not hotkey or #hotkey == 0 then return 'Нет клавиш' end
    local hotkeyText = ''
    for i, key in ipairs(hotkey) do
        hotkeyText = hotkeyText .. vk.id_to_name(key)
        if i < #hotkey then hotkeyText = hotkeyText .. ' + ' end
    end
    return hotkeyText
end

function move()
    lua_thread.create(function()
        repWin[0] = true
        mainWin[0] = false
        local blocker = true
        sampSetCursorMode(4)
        sms('Нажмите {32CD32}SPACE{FFFFFF} что-бы сохранить позицию')
        
        while blocker do
            local cX, cY = getCursorPos()
            posX, posY = cX, cY
            if isKeyJustPressed(32) then
                sampSetCursorMode(0)
                blocker = false
                cfg.main.posx, cfg.main.posy = posX, posY
                if inicfg.save(cfg, 'autorep.ini') then
                    sms('Позиция успешно сохранена! Координаты: x - '.. posX..' y - '.. posY..'!')
                    repWin[0] = false
                    mainWin[0] = true
                end
            end
            wait(0)
        end
    end)
end

function imgui.Link(label, description)
    local size = imgui.CalcTextSize(label)
    local width = imgui.GetWindowWidth()
    local p2 = imgui.GetCursorPos()
    imgui.SetCursorPos(imgui.ImVec2(width / 2 - size.x / 2, p2.y))
    local result = imgui.InvisibleButton(label, size)
    imgui.SetCursorPos(imgui.ImVec2(width / 2 - size.x / 2, p2.y))
    local p = imgui.GetCursorScreenPos()

    if imgui.IsItemHovered() then
        if description then
            imgui.BeginTooltip()
            imgui.PushTextWrapPos(600)
            imgui.TextUnformatted(description)
            imgui.PopTextWrapPos()
            imgui.EndTooltip()
        end
        imgui.TextColored(imgui.GetStyle().Colors[imgui.Col.CheckMark], label)
        imgui.GetWindowDrawList():AddLine(imgui.ImVec2(p.x, p.y + size.y), imgui.ImVec2(p.x + size.x, p.y + size.y), imgui.GetColorU32Vec4(imgui.GetStyle().Colors[imgui.Col.CheckMark]))
    else
        imgui.TextColored(imgui.GetStyle().Colors[imgui.Col.CheckMark], label)
    end
    return result
end

function imgui.TextQuestion(label, description)
    imgui.TextDisabled(label)
    if imgui.IsItemHovered() then
        imgui.BeginTooltip()
        imgui.PushTextWrapPos(600)
        imgui.TextUnformatted(description)
        imgui.PopTextWrapPos()
        imgui.EndTooltip()
    end
end

-- Инициализация и стилизация ImGui
imgui.OnInitialize(function()
    imgui.Theme()
    imgui.GetIO().IniFilename = nil
    local config = imgui.ImFontConfig()
    config.MergeMode = true
    config.PixelSnapH = true
    local iconRanges = imgui.new.ImWchar[3](faicons.min_range, faicons.max_range, 0)
    imgui.GetIO().Fonts:AddFontFromMemoryCompressedBase85TTF(faicons.get_font_data_base85('solid'), 14, config, iconRanges)
end)

function imgui.Theme()
    imgui.SwitchContext()
    local style = imgui.GetStyle()
    style.WindowPadding = imgui.ImVec2(5, 5)
    style.FramePadding = imgui.ImVec2(5, 5)
    style.ItemSpacing = imgui.ImVec2(5, 5)
    style.ItemInnerSpacing = imgui.ImVec2(2, 2)
    style.TouchExtraPadding = imgui.ImVec2(0, 0)
    style.IndentSpacing = 0
    style.ScrollbarSize = 10
    style.GrabMinSize = 10

    style.WindowBorderSize = 1
    style.ChildBorderSize = 1
    style.PopupBorderSize = 1
    style.FrameBorderSize = 1
    style.TabBorderSize = 1

    style.WindowRounding = 5
    style.ChildRounding = 5
    style.FrameRounding = 5
    style.PopupRounding = 5
    style.ScrollbarRounding = 5
    style.GrabRounding = 5
    style.TabRounding = 5

    style.WindowTitleAlign = imgui.ImVec2(0.5, 0.5)
    style.ButtonTextAlign = imgui.ImVec2(0.5, 0.5)
    style.SelectableTextAlign = imgui.ImVec2(0.5, 0.5)

    local colors = style.Colors
    colors[imgui.Col.Text] = imgui.ImVec4(1.00, 1.00, 1.00, 1.00)
    colors[imgui.Col.TextDisabled] = imgui.ImVec4(0.50, 0.50, 0.50, 1.00)
    colors[imgui.Col.WindowBg] = imgui.ImVec4(color[0] - 0.2, color[1], color[2], 1.00)
    colors[imgui.Col.ChildBg] = imgui.ImVec4(0.07, 0.07, 0.07, 1.00)
    colors[imgui.Col.PopupBg] = imgui.ImVec4(0.07, 0.07, 0.07, 1.00)
    colors[imgui.Col.Border] = imgui.ImVec4(0.25, 0.25, 0.26, 0.54)
    colors[imgui.Col.FrameBg] = imgui.ImVec4(0.12, 0.12, 0.12, 1.00)
    colors[imgui.Col.FrameBgHovered] = imgui.ImVec4(0.25, 0.25, 0.26, 1.00)
    colors[imgui.Col.FrameBgActive] = imgui.ImVec4(0.25, 0.25, 0.26, 1.00)
    colors[imgui.Col.TitleBg] = imgui.ImVec4(0.12, 0.12, 0.12, 1.00)
    colors[imgui.Col.TitleBgActive] = imgui.ImVec4(0.12, 0.12, 0.12, 1.00)
    colors[imgui.Col.Button] = imgui.ImVec4(0.12, 0.12, 0.12, 1.00)
    colors[imgui.Col.ButtonHovered] = imgui.ImVec4(0.21, 0.20, 0.20, 1.00)
    colors[imgui.Col.ButtonActive] = imgui.ImVec4(0.41, 0.41, 0.41, 1.00)
end

-- Утилитарные функций
function join_rgb(r, g, b)
    return bit.bor(bit.bor(b, bit.lshift(g, 8)), bit.lshift(r, 16))
end

function intToHex(int)
    return string.sub(bit.tohex(int), 3, 8)
end