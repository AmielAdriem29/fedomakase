# omarchy-fedora

A port of [Omarchy](https://github.com/basecamp/omarchy) 4.0.6 (the current stable release) to Fedora 43/44. It installs Omarchy's real Hyprland config, keybinds, Quickshell bar, menus, themes and `omarchy-*` commands on top of your existing Fedora install, as an extra session next to KDE.

It does not rewrite Omarchy. It installs upstream Omarchy at a pinned release tag and replaces only the parts that assume Arch: pacman, the AUR, Limine, Plymouth and SDDM. Everything you see and every keybind is upstream Omarchy.

## Install

Run from KDE (not from a TTY inside Hyprland), as your normal user:

```bash
tar xf omarchy-fedora.tar.gz
cd omarchy-fedora
./install.sh
```

Then log out, choose **Omarchy** in the session menu on the login screen, and log in. `SUPER+K` shows every keybind, `SUPER+SPACE` opens the Omarchy menu.

Useful options:

| Option | What it does |
|---|---|
| `--nvidia-driver` | Enables RPM Fusion and installs `akmod-nvidia` (skip if you already have it) |
| `--build-quickshell` | Compiles Quickshell from source instead of using the COPR |
| `--no-tools` | Skips the optional CLI tools (btop, eza, starship, lazygit, ...) |
| `--no-bashrc` | Doesn't hook Omarchy's aliases and prompt into `~/.bashrc` |
| `--ref <tag>` | Installs a different Omarchy release |

## What gets installed

- **Hyprland** from COPR `ashbuk/Hyprland-Fedora` and **Quickshell** from COPR `errornointernet/quickshell`. Fedora dropped Hyprland from its own repos after Fedora 42. The installer refuses a Hyprland older than 0.55, because Omarchy 4 is written in Hyprland's Lua config.
- **Omarchy** into `/usr/share/omarchy`, with its commands linked as `/usr/bin/omarchy-*`, the same layout as the Arch package.
- **Configs** into `~/.config`. Only `hypr/` and `omarchy/` replace existing files. Everything else (git, Chromium profile, tmux, starship) is added only if you don't already have it. Replaced files go to `~/.local/state/omarchy-fedora/backup-*`.
- A **login session** at `/usr/share/wayland-sessions/omarchy.desktop`.

KDE Plasma and its settings are left alone, so it stays available as a fallback session.

## What changed for Fedora

| Omarchy on Arch | This port |
|---|---|
| `omarchy-pkg-add` and friends call pacman/yay | Call dnf, or Flathub for AUR-only apps, through a name map in `/usr/share/omarchy-fedora/pkgmap.tsv` |
| `omarchy-update` runs pacman, AUR, migrations | Runs `dnf upgrade` and `flatpak update`, then makes sure the NVIDIA module is built for the new kernel before offering a reboot |
| Limine, Plymouth, SDDM, mkinitcpio commands | Disabled with a clear message, so they can never touch GRUB or your initramfs |
| Lock screen PAM includes `system-local-login` | Uses Fedora's `system-auth` |
| Fingerprint setup edits PAM files | Uses `authselect enable-feature with-fingerprint` |
| Tensaku screenshot editor | `tensaku-edit` shim that opens Satty |
| omacalc | `omacalc` shim that opens GNOME Calculator |
| Web apps fall back to `chromium.desktop` | Also finds Fedora's `chromium-browser.desktop` or Google Chrome |
| Sets Desktop/Templates/Public to `$HOME`, Chromium as default browser | Left as they are, since those would also change KDE |

## Hybrid graphics (Intel + NVIDIA)

On laptops like the Acer Nitro 5, the installer detects both GPUs, gives them stable names with a udev rule (`/dev/dri/omarchy-igpu`, `/dev/dri/omarchy-dgpu`), and sets:

```bash
export AQ_DRM_DEVICES=/dev/dri/omarchy-igpu:/dev/dri/omarchy-dgpu
```

in `/etc/omarchy-fedora/session.env`. Hyprland then renders on the iGPU, and only uses the NVIDIA card for monitors wired to it. This is set before Hyprland starts, because Hyprland picks its GPU before reading any config.

Omarchy itself already avoids forcing NVIDIA's VA-API driver when the iGPU drives the screen, which is what causes black or broken video in Chromium on hybrid laptops.

## Keeping it stable

- Update with `omarchy-update` (or the update icon in the bar). After a kernel update it waits for `akmods` to build the NVIDIA module and won't prompt for a reboot until `modinfo nvidia` works for the new kernel. Rebooting before that build finishes is the usual cause of "apps won't open after an update."
- If you install `snapper` and configure it for btrfs, `omarchy-update` takes a snapshot before each update, like on Arch.
- `omarchy-fedora-update` re-syncs Omarchy's files at the installed release. Your `~/.config` edits are kept.
- `omarchy-fedora-update --ref <tag>` moves to a newer Omarchy release. Newer releases can require a newer Hyprland or Quickshell, so run `omarchy-update` first.

## Not included

These are Arch-only builds from Omarchy's own repository with no Fedora package: Aether, cliamp, herdr, Omawrite, Omacut, Omasnap, ttfx, the titlebar plugin for floating workspaces, Omarchy's Neovim package (install LazyVim yourself), and the mise bundle of AI CLIs. Their keybinds (for example `SUPER+CTRL+RETURN` for herdr or `SUPER+SHIFT+W` for Omawrite) simply do nothing; rebind them in `~/.config/hypr/bindings.lua` if you want. Screen-share uses the stock picker instead of Omarchy's preview picker. The optional install menus work where `pkgmap.tsv` has a dnf or Flathub equivalent.

## Uninstall

```bash
/usr/share/omarchy-fedora/port/uninstall.sh              # remove Omarchy, keep Hyprland packages
/usr/share/omarchy-fedora/port/uninstall.sh --packages   # also remove Hyprland, Quickshell, COPRs
/usr/share/omarchy-fedora/port/uninstall.sh --configs    # also move Omarchy's ~/.config dirs to a backup
```

## Troubleshooting

- Install log: `~/.cache/omarchy-fedora/install.log`
- Session won't start: log in to KDE and run `journalctl --user -b | grep -iE 'hyprland|omarchy-shell'`
- Bar missing: `omarchy-restart-shell`, then check `journalctl --user -t omarchy-shell`
- Wrong GPU or external monitor dark: edit `/etc/omarchy-fedora/session.env`, log out and back in
- A different Hyprland COPR: `HYPR_COPR=owner/project ./install.sh`
