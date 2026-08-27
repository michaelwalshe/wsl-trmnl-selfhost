local _ = require("gettext")
return {
    name = "wol",
    fullname = _("Wake TRMNL Server"),
    description = _([[Sends a Wake-on-LAN magic packet to wake a sleeping server, waits for it to come up, then triggers the TRMNL plugin's fetch. Runs on its own schedule -- disable the TRMNL plugin's own auto-refresh when using this.]]),
}
