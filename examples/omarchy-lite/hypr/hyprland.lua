-- the machine's default hyprland config, from examples/omarchy-lite: omarchy's
-- bindings, layout, and tokyo night look, with the tools arch ships in place
-- of omarchy's scripts. a hyprland.lua of your own in ~/.config/hypr wins,
-- and can start from this one with
-- dofile("/etc/xdg/hypr/hyprland.lua").

local terminal = "foot"
local browser = "chromium --ozone-platform=wayland"
local files = "nautilus --new-window"
local menu = "fuzzel"
local scripts = "/etc/xdg/hypr/scripts/"

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
-- video, images, and the browser stay opaque.
hl.window_rule({ match = { class = "(mpv|imv|chromium|Chromium)" }, opacity = "1 1" })
-- tuis, viewers, and dialogs float, centered.
for _, class in ipairs({ "TUI.float", "imv", "mpv", "org.gnome.NautilusPreviewer", "org.gnome.Evince", "xdg-desktop-portal-gtk", "hyprpolkitagent", "com.gabm.satty" }) do
  hl.window_rule({ match = { class = class }, float = true, center = true })
end
hl.window_rule({ match = { class = "TUI.float" }, size = { 875, 600 } })
-- xwayland drag-and-drop ghosts take no focus.
hl.window_rule({ match = { class = "^$", title = "^$", xwayland = true, float = true }, no_focus = true })

-- the session's own programs.
hl.on("hyprland.start", function()
  hl.exec_cmd(app("waybar -c /etc/xdg/waybar/config.jsonc -s /etc/xdg/waybar/style.css"))
  hl.exec_cmd(app("mako -c /etc/xdg/mako/config"))
  hl.exec_cmd(app("hypridle -c /etc/xdg/hypr/hypridle.conf"))
  hl.exec_cmd(app("hyprsunset -c /etc/xdg/hypr/hyprsunset.conf"))
  hl.exec_cmd(app("swayosd-server -s /etc/xdg/swayosd/style.css"))
  hl.exec_cmd(app("swaybg -c '#1a1b26'"))
  hl.exec_cmd(app("wl-paste --watch cliphist store"))
  hl.exec_cmd(app("udiskie --automount --no-notify --no-tray"))
  hl.exec_cmd("systemctl --user start hyprpolkitagent")
end)

-- apps.
bind("SUPER + RETURN", app(terminal))
bind("SUPER + SHIFT + RETURN", app(browser))
bind("SUPER + SHIFT + B", app(browser))
bind("SUPER + SHIFT + ALT + B", app(browser .. " --incognito"))
bind("SUPER + SHIFT + F", app(files))
bind("SUPER + SHIFT + N", app(terminal .. " -e nvim"))
bind("SUPER + SHIFT + D", tui("lazydocker"))
bind("SUPER + SHIFT + G", app(terminal .. " -e lazygit"))

-- menus.
bind("SUPER + SPACE", app(menu))
bind("SUPER + ALT + SPACE", app(menu))
bind("SUPER + ESCAPE", scripts .. "menu-power")
bind("XF86PowerOff", scripts .. "menu-power", { locked = true })
bind("SUPER + K", scripts .. "menu-keybindings")

-- settings, in terminals: wi-fi, bluetooth, audio, activity.
bind("SUPER + CTRL + W", tui("nmtui"))
bind("SUPER + CTRL + B", tui("bluetui"))
bind("SUPER + CTRL + A", tui("wiremix"))
bind("SUPER + CTRL + T", tui("btop"))

-- windows.
bind("SUPER + W", hl.dsp.window.close())
bind("SUPER + Q", hl.dsp.window.close())
bind("SUPER + J", hl.dsp.layout("togglesplit"))
bind("SUPER + P", hl.dsp.window.pseudo())
bind("SUPER + T", hl.dsp.window.float({ action = "toggle" }))
bind("SUPER + F", hl.dsp.window.fullscreen({ mode = "fullscreen" }))
bind("SUPER + ALT + F", hl.dsp.window.fullscreen({ mode = "maximized" }))

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
bind("SUPER + comma", "makoctl dismiss")
bind("SUPER + SHIFT + comma", "makoctl dismiss --all")
bind("SUPER + ALT + comma", "makoctl invoke")
bind("SUPER + CTRL + comma", "makoctl mode -t do-not-disturb")

-- the bar, the night light, and the lock.
bind("SUPER + SHIFT + SPACE", "pkill -SIGUSR1 waybar")
bind("SUPER + CTRL + N", "hyprctl hyprsunset temperature 4000 || true")
bind("SUPER + CTRL + ALT + N", "hyprctl hyprsunset identity")
bind("SUPER + CTRL + L", "loginctl lock-session")

-- screenshots go to satty, which saves or copies them; the color picker
-- copies a color.
local satty = "satty --filename - --output-filename ~/Pictures/screenshot-$(date +%F-%T).png --early-exit --copy-command wl-copy"
bind("PRINT", "mkdir -p ~/Pictures && grim -g \"$(slurp)\" - | " .. satty)
bind("SHIFT + PRINT", "mkdir -p ~/Pictures && grim - | " .. satty)
bind("SUPER + PRINT", "pkill hyprpicker || hyprpicker -a")

-- the clipboard's history, through the launcher.
bind("SUPER + CTRL + V", "cliphist list | fuzzel --dmenu --prompt 'clipboard  ' | cliphist decode | wl-copy")

-- volume and brightness, with an on-screen display, and media keys, also on
-- the lock screen.
local held = { locked = true, repeating = true }
bind("XF86AudioRaiseVolume", "swayosd-client --output-volume raise", held)
bind("XF86AudioLowerVolume", "swayosd-client --output-volume lower", held)
bind("XF86AudioMute", "swayosd-client --output-volume mute-toggle", { locked = true })
bind("XF86AudioMicMute", "swayosd-client --input-volume mute-toggle", { locked = true })
bind("XF86MonBrightnessUp", "swayosd-client --brightness raise", held)
bind("XF86MonBrightnessDown", "swayosd-client --brightness lower", held)
bind("XF86AudioNext", "playerctl next", { locked = true })
bind("XF86AudioPrev", "playerctl previous", { locked = true })
bind("XF86AudioPlay", "playerctl play-pause", { locked = true })
bind("XF86AudioPause", "playerctl play-pause", { locked = true })
