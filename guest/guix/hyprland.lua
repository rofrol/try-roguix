-- A small native Guix session, using Hyprland's standard interaction patterns.
-- QEMU publishes the display's preferred mode through Virtio GPU EDID.
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })

-- Foot uses Wayland buffers, avoiding Kitty's separate OpenGL-context issue
-- on this VirGL path. Do not force software rendering for the compositor.
hl.on("hyprland.start", function()
    -- Follows QEMU window resizes; exits with the session.
    hl.exec_cmd("try-guix-display-sync")
    hl.exec_cmd("foot")
end)

hl.bind("SUPER + Q", hl.dsp.exec_cmd("foot"))
hl.bind("SUPER + R", hl.dsp.exec_cmd("wofi --show drun"))
hl.bind("SUPER + C", hl.dsp.window.close())
hl.bind("SUPER + M", hl.dsp.exit())
hl.bind("SUPER + V", hl.dsp.window.float({ action = "toggle" }))

for _, direction in ipairs({ "left", "right", "up", "down" }) do
    hl.bind("SUPER + " .. direction, hl.dsp.focus({ direction = direction }))
end
for workspace = 1, 10 do
    local key = tostring(workspace % 10)
    hl.bind("SUPER + " .. key, hl.dsp.focus({ workspace = workspace }))
    hl.bind("SUPER + SHIFT + " .. key, hl.dsp.window.move({ workspace = workspace }))
end
hl.bind("SUPER + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind("SUPER + mouse:273", hl.dsp.window.resize(), { mouse = true })
