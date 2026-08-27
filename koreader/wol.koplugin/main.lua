--[[--
Wake TRMNL Server plugin for KOReader.

Sends a Wake-on-LAN magic packet to wake a sleeping desktop, waits a
configurable lead time for it to resume (S3 sleep resumes Terminus
automatically -- see trmnl-server project notes), then broadcasts the
"TrmnlFetch" event so the TRMNL plugin fetches the latest screen.

Deliberately a separate plugin rather than a change to trmnl.koplugin: it
only depends on that plugin's public dispatcher event ("TrmnlFetch"), never
its internals, so an update to trmnl.koplugin can't break this. Disable
trmnl.koplugin's own "Enable auto-refresh" when using this, so there is one
schedule driving fetches, not two independent ones.
]]

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local socket = require("socket")
local util = require("util")
local _ = require("gettext")

local WolWake = WidgetContainer:extend {
    name = "wol",
    is_doc_only = false,

    settings = nil,
    settings_file = nil,
    wake_task = nil,
    auto_wake_enabled = false,
}

WolWake.default_settings = {
    -- Deliberately no real-looking default here: set via Configure, using
    -- your own server's MAC address and LAN broadcast address.
    mac_address = "",
    broadcast_address = "192.168.1.255",
    port = 9,
    -- How long to wait after sending the magic packet before triggering the
    -- TRMNL fetch. S3 resume was measured to be quick; this is deliberately
    -- generous. Tune down once you've seen how fast the desktop actually
    -- responds on your own network.
    wake_lead_time = 30,
    interval = 1800,
}

function WolWake:init()
    self.settings_file = LuaSettings:open(DataStorage:getSettingsDir() .. "/wol.lua")

    -- Merge saved-over-default rather than using either wholesale: once
    -- *any* settings blob has been saved once, "readSetting or defaults"
    -- would otherwise ignore compiled-in defaults forever, even for fields
    -- that were only ever empty because they hadn't been configured yet.
    self.settings = util.tableDeepCopy(self.default_settings)
    local saved = self.settings_file:readSetting("settings")
    if saved then
        for key, value in pairs(saved) do
            self.settings[key] = value
        end
    end

    -- Deliberately always starts disabled, regardless of what was saved
    -- from a previous session: this plugin sends a real network packet and
    -- wakes another machine, which shouldn't happen on its own just because
    -- KOReader launched. Requires an explicit "Enable auto wake-and-fetch",
    -- "Wake now", or the start-auto gesture each session.
    self.auto_wake_enabled = false

    -- Must be the SAME function reference every time it's scheduled: it's
    -- also what unschedule() is later called with to cancel a pending wake
    -- (on suspend, on stop, on close), and unschedule() only matches by
    -- reference -- a fresh closure per call would silently never cancel.
    self.wake_task = function()
        self:wakeAndFetch()
        self:scheduleNextWake()
    end

    Dispatcher:registerAction("wol_wake_now", {
        category = "none", event = "WolWakeNow", title = _("Wake TRMNL server now"), general = true,
    })
    Dispatcher:registerAction("wol_start_auto", {
        category = "none", event = "WolStartAuto", title = _("Wake TRMNL server: start auto-wake"), general = true,
    })

    self.ui.menu:registerToMainMenu(self)
end

function WolWake:onFlushSettings()
    if self.settings_file then
        self.settings_file:saveSetting("settings", self.settings)
        self.settings_file:saveSetting("auto_wake_enabled", self.auto_wake_enabled)
        self.settings_file:flush()
    end
end

-- Builds and sends a standard 102-byte WoL magic packet: 6x 0xFF, then the
-- target MAC repeated 16 times, over UDP broadcast.
function WolWake:sendMagicPacket()
    local mac = self.settings.mac_address or ""
    local hex = mac:gsub("[^0-9A-Fa-f]", "")
    if #hex ~= 12 then
        return false, "MAC address must have 12 hex digits (got " .. #hex .. ")"
    end

    local mac_bytes = hex:gsub("..", function(byte_hex)
        return string.char(tonumber(byte_hex, 16))
    end)
    local packet = string.rep("\255", 6) .. string.rep(mac_bytes, 16)

    local udp = socket.udp()
    if not udp then
        return false, "could not create UDP socket"
    end

    -- "Permission denied" from sendto() below, on Linux, means the OS
    -- rejected sending to a broadcast address because SO_BROADCAST wasn't
    -- actually in effect on the socket -- checking each step separately
    -- rather than only the final sendto() result, so a failure here says
    -- exactly which call was rejected instead of one generic message.
    local bind_ok, bind_err = udp:setsockname("*", 0)
    if not bind_ok then
        udp:close()
        return false, "could not bind UDP socket: " .. tostring(bind_err)
    end

    local opt_ok, opt_err = udp:setoption("broadcast", true)
    if not opt_ok then
        udp:close()
        return false, "could not enable SO_BROADCAST: " .. tostring(opt_err)
    end

    local ok, err = udp:sendto(packet, self.settings.broadcast_address, self.settings.port)
    udp:close()

    if not ok then
        return false, "sendto " .. tostring(self.settings.broadcast_address) .. ":"
            .. tostring(self.settings.port) .. " failed: " .. tostring(err)
    end
    return true
end

-- Mirrors trmnl.koplugin's own fetchAndDisplay(): the magic packet is itself
-- a network send, so it needs WiFi on too when the device turns it off
-- between fetches to save battery. runWhenConnected turns WiFi on if
-- needed and waits for a connection before running the callback;
-- afterWifiAction() releases it again once we're done with our own send
-- (the later TrmnlFetch event brings WiFi back on itself, independently,
-- for its own fetch -- each plugin manages its own network need).
function WolWake:wakeAndFetch()
    NetworkMgr:runWhenConnected(function()
        self:_doWakeAndFetch()
    end)
end

function WolWake:_doWakeAndFetch()
    local ok, err = self:sendMagicPacket()
    if ok then
        logger.info("WoL: magic packet sent to", self.settings.mac_address)
    else
        logger.warn("WoL: failed to send magic packet:", err)
        UIManager:show(InfoMessage:new{ text = _("Wake-on-LAN failed: ") .. tostring(err) })
    end
    NetworkMgr:afterWifiAction()

    -- Give the server time to resume, then ask the TRMNL plugin to fetch.
    -- Broadcasting its own event rather than calling into it directly, so
    -- this has zero dependency on trmnl.koplugin's internals.
    UIManager:scheduleIn(self.settings.wake_lead_time, function()
        UIManager:broadcastEvent(Event:new("TrmnlFetch"))
    end)
end

function WolWake:startAutoWake()
    self.auto_wake_enabled = true
    -- Run the first cycle now rather than waiting a full interval, matching
    -- trmnl.koplugin's own "enable auto-refresh" behaviour. wake_task
    -- reschedules itself for the next interval once this cycle's send is done.
    UIManager:unschedule(self.wake_task)
    self.wake_task()
end

function WolWake:stopAutoWake()
    self.auto_wake_enabled = false
    UIManager:unschedule(self.wake_task)
end

function WolWake:scheduleNextWake()
    if not self.auto_wake_enabled then return end
    UIManager:unschedule(self.wake_task)
    UIManager:scheduleIn(self.settings.interval, self.wake_task)
end

function WolWake:onWolWakeNow()
    self:wakeAndFetch()
end

-- Bindable to a gesture/key, mirroring trmnl.koplugin's own "Start
-- (interactive)" action: starts the auto wake-and-fetch cycle if it isn't
-- already running, otherwise just does one immediate wake-and-fetch.
function WolWake:onWolStartAuto()
    if not self.auto_wake_enabled then
        self:startAutoWake()
        self:saveSettings()
    else
        self:wakeAndFetch()
    end
end

function WolWake:onSuspend()
    UIManager:unschedule(self.wake_task)
end

-- Run immediately after waking from sleep rather than waiting out whatever's
-- left of the old interval, since the Kindle itself may have been asleep
-- for a while -- mirrors trmnl.koplugin's own onResume reasoning.
function WolWake:onResume()
    if self.auto_wake_enabled then
        UIManager:unschedule(self.wake_task)
        self.wake_task()
    end
end

-- Plugin is being disabled or KOReader is exiting: stop any pending wake,
-- same as trmnl.koplugin's own onCloseWidget. Settings are already flushed
-- separately via onFlushSettings().
function WolWake:onCloseWidget()
    logger.dbg("WoL: Plugin closing")
    UIManager:unschedule(self.wake_task)
end

function WolWake:showConfigDialog()
    local fields = {
        {
            text = self.settings.mac_address or "",
            hint = _("MAC address, e.g. AA:BB:CC:DD:EE:FF"),
        },
        {
            text = self.settings.broadcast_address or "192.168.1.255",
            hint = _("Broadcast address, e.g. 192.168.1.255"),
        },
        {
            text = tostring(self.settings.wake_lead_time or 30),
            hint = _("Wake lead time (seconds)"),
        },
        {
            text = tostring(self.settings.interval or 1800),
            hint = _("Interval between wakes (seconds)"),
        },
    }

    self.config_dialog = MultiInputDialog:new{
        title = _("Configure Wake TRMNL Server"),
        fields = fields,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(self.config_dialog)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local values = self.config_dialog:getFields()
                        self.settings.mac_address = values[1]
                        self.settings.broadcast_address = values[2] ~= "" and values[2] or "192.168.1.255"
                        self.settings.wake_lead_time = tonumber(values[3]) or 30
                        self.settings.interval = tonumber(values[4]) or 1800
                        self:saveSettings()
                        UIManager:close(self.config_dialog)
                        if self.auto_wake_enabled then
                            self:scheduleNextWake()
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(self.config_dialog)
    self.config_dialog:onShowKeyboard()
end

function WolWake:saveSettings()
    self.settings_file:saveSetting("settings", self.settings)
    self.settings_file:saveSetting("auto_wake_enabled", self.auto_wake_enabled)
    self.settings_file:flush()
end

function WolWake:addToMainMenu(menu_items)
    menu_items.wol_wake = {
        text = _("Wake TRMNL Server"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Enable auto wake-and-fetch"),
                checked_func = function() return self.auto_wake_enabled end,
                callback = function()
                    if self.auto_wake_enabled then
                        self:stopAutoWake()
                    else
                        self:startAutoWake()
                    end
                    self:saveSettings()
                end,
            },
            {
                text = _("Wake now"),
                callback = function()
                    self:wakeAndFetch()
                end,
            },
            {
                text = _("Configure"),
                callback = function()
                    self:showConfigDialog()
                end,
            },
        },
    }
end

return WolWake
