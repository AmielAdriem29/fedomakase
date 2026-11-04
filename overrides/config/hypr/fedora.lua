-- Fedora port additions, loaded right after Omarchy's defaults.
-- This file is yours: edit it freely. `omarchy-fedora-update` never overwrites it.
--
-- GPU selection for hybrid laptops (Intel iGPU + NVIDIA dGPU) does NOT live
-- here. Aquamarine reads AQ_DRM_DEVICES before this config is parsed, so the
-- installer writes it to ~/.config/omarchy-fedora/session.env instead, which
-- the Omarchy session sources before Hyprland starts.

-- Screenshot editor: Omarchy uses Tensaku, which has no Fedora build. The port
-- ships a tensaku-edit shim that opens Satty, so float Satty like Tensaku.
o.window("com.gabm.satty", { float = true })

-- Add Fedora- or machine-specific Hyprland settings below, for example:
-- hl.config({ misc = { vfr = true } })
o.bind("SUPER + F12", "Rescue terminal (skips uwsm-app)", "foot")
