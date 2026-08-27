# trmnl-selfhost

Turns a Windows desktop into a self-hosted [TRMNL](https://usetrmnl.com) BYOS
(Bring Your Own Server) instance, driving an old jailbroken Kindle 4 running
[KOReader](https://github.com/koreader/koreader) as an e-ink calendar +
weather dashboard. No `trmnl.com` subscription, no cloud dependency, LAN-only.

Built for and tested with a Kindle 4 (800x600, 2-bit), but the server side is
device-agnostic.

## Why this exists

[`trmnl-calendar-weather`](https://github.com/michaelwalshe/trmnl-calendar-weather) is
a private TRMNL plugin -- a rolling week/weather dashboard -- built to run on
TRMNL's own cloud (`trmnl.com`). This repo replaces that cloud entirely: the
same Liquid template runs against [Terminus](https://github.com/usetrmnl/terminus),
an official self-hosted BYOS server, on a machine on your own network, with
the calendar and weather data supplied by a small companion service instead
of TRMNL's own hosted plugins.

## Architecture

```
Kindle 4 (KOReader)                       Desktop, in WSL2/Podman

  wol.koplugin                            
    │ sends a WoL magic packet before                
    │ each fetch (desktop sleeps when idle)           
    ▼                                                 
  [ desktop wakes ]                                   
                                                       
  trmnl.koplugin  ── GET /api/display ──────────▶  Terminus (:2300)
                                                       │
                                                       │ polls on a schedule
                                                       ▼
                                                   data service (:8090)
                                                       │
                                                       ├─▶ Google Calendar API
                                                       └─▶ Open-Meteo
```

Everything server-side runs in Podman inside WSL2 on the desktop:

- **Terminus** -- the BYOS server itself. Renders the dashboard's Liquid
  template into an image and serves it to the Kindle.
- **The data service** (`app/`) -- a small Flask app that fetches your
  Google Calendar events and Open-Meteo weather, shapes them into the JSON
  the Liquid template expects, and exposes it at `GET /data`. Terminus polls
  this on a schedule (its "Exchange" mechanism).
- **`wol.koplugin`** -- a KOReader plugin that wakes the desktop over
  Wake-on-LAN before each fetch, since the desktop sleeps when idle.

## Prerequisites

- Windows 11 with WSL2 (`wsl --version` >= 2.0.0, for mirrored networking)
- A jailbroken Kindle running KOReader -- see
  [usetrmnl/trmnl-kindle](https://github.com/usetrmnl/trmnl-kindle) for the
  jailbreak itself (KOReader is their recommended method as of writing)
- The [`trmnl.koplugin`](https://github.com/usetrmnl/trmnl-koreader) KOReader
  plugin installed and able to reach `https://trmnl.app` (you'll repoint it
  at your own server below)
- A Liquid dashboard template designed for TRMNL's framework (e.g.
  [`trmnl-calendar-weather`](https://github.com/michaelwalshe/trmnl-calendar-weather))
- A Google account for calendar access (works with Google Calendar API
  regardless of what your actual calendar events come from -- an M365 work
  calendar subscribed into Google Calendar shows up the same way a native
  Google event does)
- A router you can set a DHCP reservation on

## Setup

### 1. WSL2 + Podman

```powershell
wsl --install -d Ubuntu   # if you don't already have a distro
```

Copy the config templates, adjusting the placeholders:

- [`wsl/wsl.conf.example`](wsl/wsl.conf.example) → `/etc/wsl.conf` *inside*
  WSL (needs root)
- [`wsl/wslconfig.example`](wsl/wslconfig.example) → `%UserProfile%\.wslconfig`
  on the Windows side

Then `wsl --shutdown` and reopen a WSL terminal for both to take effect.

Run the bootstrap script to install Podman and Docker Compose v2 (path is
this repo's location as WSL sees it -- a Windows path like
`C:\Users\you\source\trmnl-selfhost` is `/mnt/c/Users/you/source/trmnl-selfhost`
from inside WSL):

```powershell
wsl -d Ubuntu -u root -- bash /mnt/c/path/to/this/repo/wsl/bootstrap.sh
```

> **Why Podman, and why a manually-installed Compose v2 binary:** see the
> comments in `wsl/bootstrap.sh` and `wsl.conf.example` -- short version,
> Podman avoids running Docker Desktop's Windows service/GUI layer, and the
> Ubuntu-packaged `docker-compose` is an old v1 release that can't parse a
> modern Compose file.

### 2. Networking

Mirrored networking (from step 1) makes WSL2 share the desktop's real LAN
IP, so the Kindle can reach containers running inside it directly. That
traffic still needs a firewall opening on the Windows side:

```powershell
# elevated PowerShell
.\windows\setup-network.ps1
```

This opens TCP 2300 (Terminus) and 8090 (the data service) through both the
Hyper-V firewall (specific to mirrored-mode WSL traffic) and the standard
Windows Firewall, and makes sure your network adapter is categorised
Private rather than Public.

Then set a **DHCP reservation** on your router for the desktop's MAC
address, so its LAN IP never changes -- the Kindle needs a fixed address to
poll. Find the MAC with `Get-NetAdapter`.

### 3. Terminus

```bash
git clone https://github.com/usetrmnl/terminus ~/terminus
cd ~/terminus
bash bin/setup docker   # generates .env with DB/session secrets
```

Terminus auto-detects your machine's IP for `API_URI` in `.env` -- open it
and confirm the port matches (`2300` by default), fixing it if the value
came out malformed (some versions leave a literal `$HANAMI_PORT` in there
instead of expanding it).

Copy [`terminus/compose.override.yml`](terminus/compose.override.yml) and
[`terminus/sanitize.yml`](terminus/sanitize.yml) from this repo into
`~/terminus/`, then:

```bash
docker compose up -d
```

Open `http://<desktop-lan-ip>:2300` and complete the first-run setup
(create your own admin login).

> **Why `sanitize.yml` needs overriding:** Terminus runs extension content
> through an HTML sanitizer that only allowlists 6 CSS custom properties by
> default. A Liquid template that styles itself with a plain `<style>`
> block (rather than only inline `style=""` attributes using framework
> utility classes) gets almost all of its CSS silently stripped --
> `display`, `position`, `grid-template-columns` and friends are fine
> (already covered by the sanitizer's `RELAXED` base config, confirmed by
> checking `Sanitize::Config::RELAXED` directly), but CSS custom properties
> and the `place-content` shorthand are not. This override widens the
> allowlist by exactly the properties `trmnl-calendar-weather`'s template
> needs, checked against the base config rather than guessed -- see the
> comments in `terminus/sanitize.yml` for the reasoning. TRMNL's own cloud
> doesn't sanitize private-plugin content this way, so this isn't Terminus
> matching an intentional trust boundary -- just filling a gap between the
> two.
>
> This is a config override layered on top via a Docker bind mount
> (`terminus/compose.override.yml`), not a patch to Terminus's own image or
> code -- it survives `git pull`/image upgrades on the Terminus side
> cleanly.

### 4. Data service

```bash
cd app
uv sync
```

**Google Calendar**, one-time, interactive:

1. [Google Cloud Console](https://console.cloud.google.com) → new project →
   enable the Calendar API → OAuth consent screen (External, add yourself
   as a test user) → Credentials → OAuth client ID, type **Desktop app**.
2. Download the client secret JSON, save it as `secrets/client_secret.json`
   (relative to the repo root, `secrets/` is gitignored).
3. Authorise (from the `app/` directory, per the `cd app` above):
   ```bash
   uv run authorize_google.py
   ```
   Opens (or prints) a Google consent URL; approving it writes
   `secrets/google_token.json`, a refresh token used indefinitely from then
   on. Scope is `calendar.readonly` -- this can never modify your calendar.

**Weather**: no API key needed (Open-Meteo is free/keyless). Copy
[`.env.example`](.env.example) to `.env` and fill in your coordinates --
resolve a place name with Open-Meteo's own geocoding API:

```bash
curl "https://geocoding-api.open-meteo.com/v1/search?name=<your town>&count=1"
```

Then bring it up (from the repo root, where `compose.yml` lives):

```bash
cd ..
docker compose up -d
```

`GET http://localhost:8090/data` should return calendar + weather JSON.
`GET /health` is the container healthcheck endpoint.

> **On duplicate calendar events:** if the same meeting exists on more than
> one calendar you have access to (common when a work calendar is synced
> into a personal Google account), `app/gcal.py` deduplicates by
> `(summary, start, end)`, preferring your primary calendar's copy. Without
> this, the dashboard's day grid draws real but visually-confusing overlaps
> for what's actually one meeting.
>
> **On event descriptions:** deliberately never fetched from Google (the
> API `fields` parameter excludes them) -- they routinely carry Teams/Zoom
> dial-in PINs and attendee email lists, which is more than a dashboard
> needs to request over the network even before considering whether to
> display it.

### 5. The Liquid template

This repo doesn't vendor a copy of the dashboard's `full.liquid` -- that
lives in its own template repo and would just go stale here. Instead:

```powershell
.\liquid\build.ps1 -UpstreamPath C:\path\to\trmnl-calendar-weather
```

This concatenates [`_terminus_header.liquid`](liquid/_terminus_header.liquid)
+ the upstream `full.liquid` + [`_terminus_footer.liquid`](liquid/_terminus_footer.liquid)
into `full.terminus.liquid`. The header/footer do two things the original
template doesn't need to worry about, since they're specific to how
Terminus's rendering model differs from TRMNL cloud's:

1. **Alias `source_1.*` to the variable names the template expects.**
   TRMNL cloud's "Plugin Merge" strategy resolves `calendar_source` /
   `weather_source` / `hourly_source` as top-level variables directly.
   Terminus's Extension "Poll" mechanism instead lands whatever an Exchange
   URL returns under `source_1` (`source_2` for a second exchange, etc.) --
   since the data service returns one JSON object with all three keys under
   a single exchange, the header just aliases them back.
2. **Supply the `.screen`/`.view` wrapper div.** TRMNL cloud's renderer
   wraps plugin content in this automatically; Terminus's extension
   renderer drops your HTML straight into `<body>` with no wrapper at all.
   Without it, the framework CSS driving the day-grid's sizing has nothing
   to attach to and the whole layout collapses to unstyled block flow.

In Terminus:

1. **Extensions → New.** Label anything, **Kind: Poll**.
2. **Model**: create a custom model matching your device's real resolution
   and **Rotation: 0** (landscape). Don't reuse one of Terminus's seeded
   device models unless you've checked its Rotation value first -- several
   ship with `Rotation: 90` baked in for portrait-native e-readers, which
   silently rotates an otherwise-correct 800x600 landscape render.
   Custom models also need their **CSS** field populated with something
   valid (e.g. `{"classes": {}, "variables": []}`) -- Terminus's
   `Model#css_classes` throws on a `nil` CSS field for a custom model,
   which surfaces as a 500 error when building/previewing.
3. Paste `full.terminus.liquid`'s contents into the **Template** field.
4. **Exchanges → New**: Verb `GET`, **Template** field (yes, that's the URL
   field, despite the name -- it supports Liquid templating for dynamic
   URLs, a plain URL works fine) = `http://<desktop-lan-ip>:8090/data`.
   Leave Headers/Body as `{}` if empty ones error.
5. **Build** the extension for your model, then add its screen to a
   **Playlist**. You'll assign that playlist to your Device in the next
   step, once the Kindle has registered itself and created one.

### 6. Autostart

```powershell
# elevated PowerShell
.\windows\setup-autostart-task.ps1
```

Registers a Task Scheduler task that boots the WSL distro at both Windows
startup and logon (S4U logon type -- no password stored, and works even
if nobody actually logs into Windows after a remote wake). Once WSL boots,
enable the systemd unit that brings the containers up:

```bash
cp wsl/trmnl-stack.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now trmnl-stack.service
```

> **Two things this specifically works around**, both confirmed the hard
> way rather than assumed:
>
> - Podman's rootless `restart: unless-stopped` policy needs a
>   per-container supervisor process that's still alive to act on it. That
>   does not survive a full WSL VM cold-boot (unlike Docker Engine's
>   persistent daemon) -- after a real restart, containers were found
>   sitting in "Created" but never started. `trmnl-stack.service` explicitly
>   runs `docker compose up -d` on boot instead of relying on the restart
>   policy alone.
> - WSL has its own idle-shutdown feature (`instanceIdleTimeout` /
>   `vmIdleTimeout`, ~60 seconds by default) that stops the whole VM when
>   no `wsl.exe` process is attached -- regardless of systemd or containers
>   actively running inside. This silently killed the server repeatedly and
>   looked exactly like a crash. `wslconfig.example` disables both.

### 7. Kindle: KOReader plugins

**`trmnl.koplugin`** (the display client -- install per its own
[README](https://github.com/usetrmnl/trmnl-koreader) if you haven't
already):

1. Register the Kindle against Terminus (not `trmnl.com`) to get its API
   key, using its MAC address (**Menu → Network → Info** in KOReader):
   ```bash
   curl -H "ID: <kindle-mac-address>" http://<desktop-lan-ip>:2300/api/setup
   ```
   Returns JSON including `api_key`. This auto-creates the device in
   Terminus with a default model -- open **Devices** in Terminus's UI
   afterwards and set its Model to the one you created in step 5, and
   assign it the Playlist containing your dashboard's screen.
2. **Tools → TRMNL Display → Configure TRMNL**: **Base URL** =
   `http://<desktop-lan-ip>:2300`, **API Key** = the one from step 1.
3. **Tools → TRMNL Display → Fetch screen now** to test.

**`wol.koplugin`** (this repo's own plugin -- wakes the server before each
fetch, since the desktop sleeps when idle):

Deploy it with the included script (auto-detects the Kindle's USB drive
letter):

```powershell
.\koreader\deploy-to-kindle.ps1
```

Then on the Kindle:

1. **Tools → Wake TRMNL Server → Configure**: your desktop's MAC address,
   broadcast address (your subnet's `.255`, e.g. `192.168.1.255`), wake
   lead time (how long to wait after sending the packet before fetching --
   start around 30s, tune down once you've seen how fast your desktop
   actually responds), and interval.
2. **Tools → Wake TRMNL Server → Enable auto wake-and-fetch**.
3. Go back into **Tools → TRMNL Display** and disable **its** own
   auto-refresh -- `wol.koplugin` now drives the whole cycle (wake, wait,
   trigger `trmnl.koplugin`'s fetch via KOReader's own event system), so
   you don't want two independent schedules running.

If something silently fails, `crash.log` on the Kindle (root of the drive
it mounts as, inside `/koreader/`) is the actual place to look -- KOReader
keeps running other plugins even if one errors, so failures don't surface
in the UI on their own.

### 8. Power management

Wake-on-LAN is very likely your only remote-wake option (few consumer
motherboards expose a scheduled/RTC wake setting in BIOS, and if yours
doesn't either, WoL is the fallback either way):

1. **BIOS**: enable Wake-on-LAN (often labelled `S4/S5 Wake on LAN` or
   similar, under Power/Advanced settings).
2. **Windows**: confirm the NIC is armed for wake --
   `powercfg -devicequery wake_armed` should list it. If not, Device
   Manager → the adapter → Power Management tab → allow it to wake the
   computer.
3. **Use S3 standby as the normal "off" state, not a full shutdown.**
   Confirmed by testing both: S3 sleep reliably resumes via WoL *and*
   Terminus resumes automatically with zero manual intervention once
   Windows is back. A full shutdown (S4/S5) did not reliably wake via WoL
   on the hardware this was built against, even with the BIOS setting
   enabled -- worth checking on your own hardware, but don't assume it
   works without testing.

## Repo layout

```
app/                Data service (Google Calendar + Open-Meteo -> JSON)
terminus/           Config overrides applied on top of a Terminus checkout
liquid/             Adapts a TRMNL Liquid template to run as a Terminus extension
koreader/           wol.koplugin, plus a deploy script
wsl/                WSL2/Podman setup: bootstrap script + config templates
windows/            Windows-side PowerShell setup scripts
```

## License

MIT, see [LICENSE](LICENSE).
