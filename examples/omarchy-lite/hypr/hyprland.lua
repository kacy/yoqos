-- the machine's default hyprland config, from examples/omarchy-lite: omarchy's
-- bindings, layout, and tokyo night look, and omarchy's own shell for the
-- bar, panels, notifications, and lock screen. a hyprland.lua of your own in ~/.config/hypr wins,
-- and can start from this one with
-- dofile("/etc/xdg/hypr/hyprland.lua").

local terminal = "foot"
local browser = "chromium --ozone-platform=wayland"
local files = "nautilus --new-window"
local menu = "fuzzel"
local scripts = "/etc/xdg/hypr/scripts/"
local shell = "/etc/xdg/yos-shell/yos-shell"

-- apps start under uwsm, so each gets a unit of its own and the session
-- can stop them.
local function app(command)
  return "uwsm app -- " .. command
end

-- a tui in a small floating terminal.
local function tui(command)
  return app(terminal .. " --app-id=TUI.float -e " .. command)
end

local function bind(keys, dispatcher, options)
  if type(dispatcher) == "string" then
    dispatcher = hl.dsp.exec_cmd(dispatcher)
  end
  hl.bind(keys, dispatcher, options or {})
end

-- monitors: each at its best mode, placed in order, scaled as hyprland sees
-- fit. `hyprctl monitors all` lists what's there.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })

-- wayland everywhere it can be.
hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")
hl.env("GDK_BACKEND", "wayland,x11,*")
hl.env("QT_QPA_PLATFORM", "wayland;xcb")
hl.env("QT_QPA_PLATFORMTHEME", "gtk3")
hl.env("MOZ_ENABLE_WAYLAND", "1")
hl.env("ELECTRON_OZONE_PLATFORM_HINT", "wayland")
hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("XDG_SESSION_TYPE", "wayland")
hl.env("XDG_SESSION_DESKTOP", "Hyprland")

-- tokyo night.
local accent = { colors = { "rgba(33ccffee)", "rgba(00ff99ee)" }, angle = 45 }
local inactive = "rgba(595959aa)"

hl.config({
  general = {
    gaps_in = 5,
    gaps_out = 10,
    border_size = 2,
    col = { active_border = accent, inactive_border = inactive },
    resize_on_border = false,
    allow_tearing = false,
    layout = "dwindle",
  },

  decoration = {
    rounding = 0,
    shadow = { enabled = false },
    blur = { enabled = false },
  },

  group = {
    col = { border_active = accent, border_inactive = inactive },
    groupbar = {
      font_size = 12,
      font_family = "monospace",
      height = 22,
      gradients = true,
      text_color = "rgb(ffffff)",
      col = { active = "rgba(00000040)", inactive = "rgba(00000020)" },
    },
  },

  animations = { enabled = true },

  dwindle = { preserve_split = true, force_split = 2 },
  master = { new_status = "master" },

  input = {
    kb_layout = "us",
    -- caps lock is the compose key; both shifts together are caps lock.
    kb_options = "compose:caps,shift:both_capslock_cancel",
    follow_mouse = 1,
    repeat_rate = 40,
    repeat_delay = 250,
    numlock_by_default = true,
    touchpad = {
      natural_scroll = false,
      clickfinger_behavior = true,
      scroll_factor = 0.4,
    },
  },

  misc = {
    disable_hyprland_logo = true,
    disable_splash_rendering = true,
    focus_on_activate = true,
    key_press_enables_dpms = true,
    mouse_move_enables_dpms = true,
  },

  cursor = { hide_on_key_press = true },
  binds = { hide_special_on_workspace_change = true },
  xwayland = { force_zero_scaling = true },
  ecosystem = { no_update_news = true },
})

hl.curve("easeOutQuint", { type = "bezier", points = { { 0.23, 1 }, { 0.32, 1 } } })
hl.curve("linear", { type = "bezier", points = { { 0, 0 }, { 1, 1 } } })
hl.curve("almostLinear", { type = "bezier", points = { { 0.5, 0.5 }, { 0.75, 1.0 } } })
hl.curve("quick", { type = "bezier", points = { { 0.15, 0 }, { 0.1, 1 } } })

hl.animation({ leaf = "global", enabled = true, speed = 10, bezier = "default" })
hl.animation({ leaf = "border", enabled = true, speed = 5.39, bezier = "easeOutQuint" })
hl.animation({ leaf = "windows", enabled = true, speed = 3.79, bezier = "easeOutQuint" })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 4.1, bezier = "easeOutQuint", style = "popin 87%" })
hl.animation({ leaf = "windowsOut", enabled = true, speed = 1.49, bezier = "linear", style = "popin 87%" })
hl.animation({ leaf = "fadeIn", enabled = true, speed = 1.73, bezier = "almostLinear" })
hl.animation({ leaf = "fadeOut", enabled = true, speed = 1.46, bezier = "almostLinear" })
hl.animation({ leaf = "fade", enabled = true, speed = 3.03, bezier = "quick" })
hl.animation({ leaf = "layers", enabled = true, speed = 3.81, bezier = "easeOutQuint" })
hl.animation({ leaf = "layersIn", enabled = true, speed = 4, bezier = "easeOutQuint", style = "fade" })
hl.animation({ leaf = "layersOut", enabled = true, speed = 1.5, bezier = "linear", style = "fade" })
hl.animation({ leaf = "workspaces", enabled = false })

-- windows.
hl.window_rule({ match = { class = ".*" }, suppress_event = "maximize" })
hl.window_rule({ match = { class = ".*" }, opacity = "0.985 0.96" })
-- terminals carry a tag, so universal copy and paste can tell them apart.
hl.window_rule({ match = { class = "(foot|org\\.codeberg\\.dnkl\\.foot|TUI\\..*)" }, tag = "+terminal" })
-- video, images, and the browser stay opaque.
hl.window_rule({ match = { class = "(mpv|imv|chromium|Chromium)" }, opacity = "1 1" })
-- tuis, viewers, and dialogs float, centered.
for _, class in ipairs({ "TUI.float", "imv", "mpv", "org.gnome.NautilusPreviewer", "org.gnome.Evince", "xdg-desktop-portal-gtk", "com.gabm.satty" }) do
  hl.window_rule({ match = { class = class }, float = true, center = true })
end
hl.window_rule({ match = { class = "TUI.float" }, size = { 875, 600 } })
-- xwayland drag-and-drop ghosts take no focus.
hl.window_rule({ match = { class = "^$", title = "^$", xwayland = true, float = true }, no_focus = true })

-- the session's own programs.
hl.on("hyprland.start", function()
  -- omarchy's shell: the bar, notifications, the on-screen display, the
  -- idle timer and lock screen, and the polkit agent. the first login
  -- sets it up.
  hl.exec_cmd(app(shell))
  hl.exec_cmd(app("swaybg -c '#1a1b26'"))
  hl.exec_cmd(app("wl-paste --watch cliphist store"))
  hl.exec_cmd(app("udiskie --automount --no-notify --no-tray"))
end)

-- settings the shell's commands switch on, like an internal display off
-- with its lid shut. they write these, and reload hyprland.
local toggles = (os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")) .. "/omarchy/toggles/hypr"
local switched = io.popen("ls " .. toggles .. "/*.lua 2>/dev/null")
if switched then
  for file in switched:lines() do dofile(file) end
  switched:close()
end
-- a touchpad or touchscreen switched off stays off. its name is kept as
-- data, never run as code.
for _, kind in ipairs({ "touchpad", "touchscreen" }) do
  local saved = io.open(toggles .. "/" .. kind .. "-disabled-name", "r")
  if saved then
    local name = saved:read("*l")
    saved:close()
    if name and name ~= "" then hl.device({ name = name, enabled = false }) end
  end
end

-- a key that goes straight to the shell, as a global shortcut it
-- registers, so no process starts for it.
local function to_shell(keys, shortcut, options)
  bind(keys, hl.dsp.global("omarchy:" .. shortcut), options)
end

-- one of omarchy's own commands, which the shell sets up.
local function omarchy(command)
  return shell .. " " .. command
end

-- apps.
bind("SUPER + RETURN", app(terminal))
bind("SUPER + SHIFT + RETURN", app(browser))
bind("SUPER + SHIFT + B", app(browser))
bind("SUPER + SHIFT + ALT + B", app(browser .. " --incognito"))
bind("SUPER + SHIFT + F", app(files))
bind("SUPER + SHIFT + N", app(terminal .. " -e nvim"))
bind("SUPER + SHIFT + D", tui("lazydocker"))
bind("SUPER + SHIFT + G", app(terminal .. " -e lazygit"))
bind("SUPER + ALT + RETURN", omarchy("omarchy-launch-terminal-tmux"))
bind("SUPER + ALT + SHIFT + F", omarchy("omarchy-launch-nautilus-cwd"))

-- menus.
bind("SUPER + SPACE", app(menu))
bind("SUPER + ALT + SPACE", app(menu))
bind("SUPER + ESCAPE", scripts .. "menu-power")
bind("XF86PowerOff", scripts .. "menu-power", { locked = true })
bind("SUPER + K", scripts .. "menu-keybindings")

-- the shell's panels: wi-fi, bluetooth, audio, display, power, the ai
-- agents, and the calendar. activity is btop.
to_shell("SUPER + CTRL + W", "panel.omarchy.network")
to_shell("SUPER + CTRL + B", "panel.omarchy.bluetooth")
to_shell("SUPER + CTRL + A", "panel.omarchy.audio")
to_shell("SUPER + CTRL + D", "panel.omarchy.monitor")
to_shell("SUPER + CTRL + P", "panel.omarchy.power")
to_shell("SUPER + CTRL + G", "panel.omarchy.agents")
to_shell("SUPER + CTRL + ALT + D", "panel.omarchy.clock")
bind("SUPER + CTRL + T", tui("btop"))

-- windows.
bind("SUPER + W", hl.dsp.window.close())
bind("SUPER + Q", hl.dsp.window.close())
bind("SUPER + J", hl.dsp.layout("togglesplit"))
bind("SUPER + P", hl.dsp.window.pseudo())
bind("SUPER + T", hl.dsp.window.float({ action = "toggle" }))
bind("SUPER + F", hl.dsp.window.fullscreen({ mode = "fullscreen" }))
bind("SUPER + ALT + F", hl.dsp.window.fullscreen({ mode = "maximized" }))
bind("SUPER + CTRL + F", omarchy("omarchy-hyprland-window-tiled-fullscreen-toggle"))
bind("SUPER + O", omarchy("omarchy-hyprland-window-pop"))
bind("SUPER + ALT + Home", omarchy("omarchy-hyprland-window-width save"))
bind("SUPER + Home", omarchy("omarchy-hyprland-window-width restore"))
bind("SUPER + L", omarchy("omarchy-hyprland-workspace-layout-toggle"))
bind("SUPER + BACKSPACE", omarchy("omarchy-hyprland-window-transparency-toggle"))
bind("SUPER + SHIFT + BACKSPACE", omarchy("omarchy-hyprland-window-gaps-toggle"))
bind("SUPER + CTRL + BACKSPACE", omarchy("omarchy-hyprland-window-single-square-aspect-toggle"))
bind("CTRL + ALT + DELETE", omarchy("omarchy-hyprland-window-close-all"))

for _, d in ipairs({ { "LEFT", "l" }, { "RIGHT", "r" }, { "UP", "u" }, { "DOWN", "d" } }) do
  bind("SUPER + " .. d[1], hl.dsp.focus({ direction = d[2] }))
  bind("SUPER + SHIFT + " .. d[1], hl.dsp.window.swap({ direction = d[2] }))
  bind("SUPER + ALT + " .. d[1], hl.dsp.window.move({ into_group = d[2] }))
  bind("SUPER + SHIFT + ALT + " .. d[1], hl.dsp.workspace.move({ monitor = d[2] }))
end

-- workspaces 1 to 10, on the number row by key code, whatever the layout.
for workspace = 1, 10 do
  local key = "code:" .. tostring(workspace + 9)
  bind("SUPER + " .. key, hl.dsp.focus({ workspace = tostring(workspace) }))
  bind("SUPER + SHIFT + " .. key, hl.dsp.window.move({ workspace = tostring(workspace) }))
  bind("SUPER + SHIFT + ALT + " .. key, hl.dsp.window.move({ workspace = tostring(workspace), follow = false }))
end
bind("SUPER + TAB", hl.dsp.focus({ workspace = "e+1" }))
bind("SUPER + SHIFT + TAB", hl.dsp.focus({ workspace = "e-1" }))
bind("SUPER + CTRL + TAB", hl.dsp.focus({ workspace = "previous" }))
bind("SUPER + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
bind("SUPER + mouse_up", hl.dsp.focus({ workspace = "e-1" }))

bind("SUPER + S", hl.dsp.workspace.toggle_special("scratchpad"))
bind("SUPER + ALT + S", hl.dsp.window.move({ workspace = "special:scratchpad", follow = false }))

-- monitors: focus, scaling, and the laptop's own display.
bind("CTRL + ALT + TAB", hl.dsp.focus({ monitor = "+1" }))
bind("CTRL + ALT + SHIFT + TAB", hl.dsp.focus({ monitor = "-1" }))
bind("SUPER + SLASH", omarchy("omarchy-hyprland-monitor-scaling up"))
bind("SUPER + ALT + SLASH", omarchy("omarchy-hyprland-monitor-scaling down"))
bind("SUPER + CTRL + Delete", omarchy("omarchy-hyprland-monitor-internal toggle"))
bind("SUPER + CTRL + ALT + Delete", omarchy("omarchy-hyprland-monitor-internal-mirror toggle"))

bind("ALT + TAB", hl.dsp.window.cycle_next())
bind("ALT + SHIFT + TAB", hl.dsp.window.cycle_next({ next = false }))

-- resize with - and =, a little with alt, a lot with ctrl.
for _, step in ipairs({ { "", 100 }, { "ALT + ", 25 }, { "CTRL + ", 300 } }) do
  bind("SUPER + " .. step[1] .. "code:20", hl.dsp.window.resize({ x = -step[2], y = 0, relative = true }))
  bind("SUPER + " .. step[1] .. "code:21", hl.dsp.window.resize({ x = step[2], y = 0, relative = true }))
  bind("SUPER + SHIFT + " .. step[1] .. "code:20", hl.dsp.window.resize({ x = 0, y = -step[2], relative = true }))
  bind("SUPER + SHIFT + " .. step[1] .. "code:21", hl.dsp.window.resize({ x = 0, y = step[2], relative = true }))
end

bind("SUPER + mouse:272", hl.dsp.window.drag(), { mouse = true })
bind("SUPER + mouse:273", hl.dsp.window.resize(), { mouse = true })

-- groups.
bind("SUPER + G", hl.dsp.group.toggle())
bind("SUPER + ALT + G", hl.dsp.window.move({ out_of_group = true }))
bind("SUPER + ALT + TAB", hl.dsp.group.next())
bind("SUPER + ALT + SHIFT + TAB", hl.dsp.group.prev())

-- notifications.
to_shell("SUPER + comma", "ipc.notifications.dismissOne")
to_shell("SUPER + SHIFT + comma", "ipc.notifications.dismissAll")
to_shell("SUPER + ALT + comma", "ipc.notifications.invokeLast")
to_shell("SUPER + SHIFT + ALT + comma", "ipc.notifications.showHistory")

-- the bar, the night light, and the lock, all the shell's.
bind("SUPER + SHIFT + SPACE", shell .. " omarchy-toggle-bar")
bind("SUPER + CTRL + N", shell .. " omarchy-toggle-nightlight")
bind("SUPER + CTRL + L", shell .. " omarchy-system-lock")

-- screenshots go to satty, which saves or copies them; the color picker
-- copies a color.
local satty = "satty --filename - --output-filename ~/Pictures/screenshot-$(date +%F-%T).png --early-exit --copy-command wl-copy"
bind("PRINT", "mkdir -p ~/Pictures && grim -g \"$(slurp)\" - | " .. satty)
bind("SHIFT + PRINT", "mkdir -p ~/Pictures && grim - | " .. satty)
bind("SUPER + PRINT", "pkill hyprpicker || hyprpicker -a")

-- copy, paste, cut, and select all with super, in any app. a terminal
-- gets ctrl+shift for copy and paste. the key goes down, then up a moment
-- later, which keeps it from sticking.
local function send(mods, key)
  return function()
    hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "down" }))
    hl.timer(function()
      hl.dispatch(hl.dsp.send_key_state({ mods = mods, key = key, state = "up" }))
    end, { timeout = 50, type = "oneshot" })
  end
end

local function in_terminal()
  local window = hl.get_active_window()
  for _, tag in ipairs(window and window.tags or {}) do
    if tag:gsub("%*$", "") == "terminal" then return true end
  end
  return false
end

local function clipboard(key)
  return function()
    send(in_terminal() and "CTRL SHIFT" or "CTRL", key)()
  end
end

bind("SUPER + A", send("CTRL", "A"))
bind("SUPER + C", clipboard("C"))
bind("SUPER + V", clipboard("V"))
bind("SUPER + X", send("CTRL", "X"))

-- the clipboard's history, through the launcher.
bind("SUPER + CTRL + V", "cliphist list | fuzzel --dmenu --prompt 'clipboard  ' | cliphist decode | wl-copy")

-- volume, brightness, and media, with the shell's on-screen display, on
-- the lock screen too.
local held = { locked = true, repeating = true }
to_shell("XF86AudioRaiseVolume", "audio.raise", held)
to_shell("XF86AudioLowerVolume", "audio.lower", held)
to_shell("XF86AudioMute", "audio.mute-toggle", { locked = true })
bind("XF86AudioMicMute", "wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle", { locked = true })
to_shell("XF86MonBrightnessUp", "brightness.raise", held)
to_shell("XF86MonBrightnessDown", "brightness.lower", held)
to_shell("XF86AudioPlay", "ipc.media.playPause", { locked = true })
to_shell("XF86AudioPause", "ipc.media.playPause", { locked = true })
to_shell("XF86AudioNext", "ipc.media.next", { locked = true })
to_shell("XF86AudioPrev", "ipc.media.previous", { locked = true })

-- finer steps with alt, the ends with shift, and the rest of a laptop's
-- keys.
bind("ALT + XF86AudioRaiseVolume", omarchy("omarchy-audio-output-volume +1"), held)
bind("ALT + XF86AudioLowerVolume", omarchy("omarchy-audio-output-volume -1"), held)
bind("ALT + XF86MonBrightnessUp", omarchy("omarchy-brightness-display +1%"), held)
bind("ALT + XF86MonBrightnessDown", omarchy("omarchy-brightness-display 1%-"), held)
bind("SHIFT + XF86MonBrightnessUp", omarchy("omarchy-brightness-display 100%"), held)
bind("SHIFT + XF86MonBrightnessDown", omarchy("omarchy-brightness-display 1%"), held)
bind("SHIFT + XF86AudioMute", omarchy("omarchy-audio-output-switch"), { locked = true })
bind("SHIFT + XF86AudioPlay", omarchy("omarchy-audio-source-switch"), { locked = true })
bind("SHIFT + XF86AudioPause", omarchy("omarchy-audio-source-switch"), { locked = true })
bind("XF86KbdBrightnessUp", omarchy("omarchy-brightness-keyboard up"), held)
bind("XF86KbdBrightnessDown", omarchy("omarchy-brightness-keyboard down"), held)
bind("XF86KbdLightOnOff", omarchy("omarchy-brightness-keyboard cycle"), { locked = true })
bind("XF86TouchpadToggle", omarchy("omarchy-toggle-touchpad"), { locked = true })
bind("XF86TouchpadOn", omarchy("omarchy-toggle-touchpad on"), { locked = true })
bind("XF86TouchpadOff", omarchy("omarchy-toggle-touchpad off"), { locked = true })
bind("XF86Eject", "eject", { locked = true })
