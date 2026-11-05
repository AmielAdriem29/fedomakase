# Fedora patches applied to a staged copy of the Omarchy source tree.
# Sourced by install.sh. Each patch checks that its target still matches so a
# newer Omarchy release that changed the file is reported instead of silently
# half-patched.

# Commands that would rewrite the bootloader, initramfs, pacman setup or the
# login manager. They are replaced with fedomakase-unsupported.
UNSUPPORTED_BINS=(
  omarchy-apply-pacman
  omarchy-channel-set
  omarchy-dev-pkg-test
  omarchy-hibernation-available
  omarchy-hibernation-remove
  omarchy-hibernation-setup
  omarchy-plymouth-set
  omarchy-provision-hardware
  omarchy-provision-owner
  omarchy-refresh-limine
  omarchy-refresh-pacman
  omarchy-refresh-plymouth
  omarchy-refresh-sddm
  omarchy-reinstall
  omarchy-reinstall-pkgs
  omarchy-setup-direct-boot
  omarchy-system-factory-reset
  omarchy-system-factory-reset-finish
  omarchy-update-boot
  omarchy-update-keyring
  omarchy-update-pacman
  omarchy-update-system-pkgs-when-conflicted
  omarchy-upgrade-to-quattro
  omarchy-version-channel
)

# Commands whose Arch steps simply have nothing to do on Fedora.
NOOP_BINS=(
  omarchy-update-pacman-guard
  omarchy-update-pkg-prune
  omarchy-update-dev
  omarchy-update-requires-free-space
)

# Replace a literal string in a file, warning if it is not found.
patch_literal() {
  local file=$1 old=$2 new=$3 label=$4
  if [[ ! -f $file ]]; then
    warn "patch '$label': $(basename "$file") is missing in this Omarchy release"
    return 0
  fi
  if ! grep -qF -- "$old" "$file"; then
    warn "patch '$label': target text not found in $(basename "$file"), skipped"
    return 0
  fi
  OLD="$old" NEW="$new" perl -0pi -e 's/\Q$ENV{OLD}\E/$ENV{NEW}/g' "$file"
}

# Delete every line containing a literal string.
patch_drop_line() {
  local file=$1 needle=$2 label=$3
  if [[ -f $file ]] && grep -qF -- "$needle" "$file"; then
    NEEDLE="$needle" perl -ni -e 'print unless index($_, $ENV{NEEDLE}) >= 0' "$file"
  else
    warn "patch '$label': nothing to drop in $(basename "$file")"
  fi
}

apply_fedora_patches() {
  local src=$1

  # 1. Port overrides: dnf/flatpak package shims, update flow, version info.
  cp -f "$PORT_DIR"/overrides/bin/* "$src/bin/"
  chmod 755 "$src"/bin/omarchy-* "$src"/bin/fedomakase-*

  # Old command names keep working after the rename to Fedomakase.
  local old
  for old in pkg nvidia-check unsupported; do
    ln -sfn "fedomakase-$old" "$src/bin/omarchy-fedora-$old"
  done

  local bin
  for bin in "${UNSUPPORTED_BINS[@]}"; do
    rm -f "$src/bin/$bin"
    ln -s fedomakase-unsupported "$src/bin/$bin"
  done
  for bin in "${NOOP_BINS[@]}"; do
    printf '#!/bin/bash\n# omarchy:hidden=true\n# Fedora port: nothing to do here.\nexit 0\n' >"$src/bin/$bin"
    chmod 755 "$src/bin/$bin"
  done

  # 2. Lock screen PAM: Arch's system-local-login does not exist on Fedora.
  patch_literal "$src/bin/omarchy-apply-lock" \
    "account    include                     system-local-login" \
    "account    include                     system-auth" \
    "lock screen PAM account stack"

  # 3. Screen sharing: Omarchy's preview picker is not packaged for Fedora, so
  #    fall back to xdg-desktop-portal-hyprland's stock picker.
  patch_drop_line "$src/config/hypr/xdph.conf" "custom_picker_binary" "screen share picker"

  # 4. Keep the user's existing default browser and mail client.
  patch_literal "$src/bin/omarchy-provision-user" \
    "env -u BROWSER XDG_CURRENT_DESKTOP= xdg-settings set default-web-browser chromium.desktop" \
    'if [[ -z $(env -u BROWSER XDG_CURRENT_DESKTOP= xdg-settings get default-web-browser 2>/dev/null) ]] && [[ -f /usr/share/applications/chromium-browser.desktop ]]; then env -u BROWSER XDG_CURRENT_DESKTOP= xdg-settings set default-web-browser chromium-browser.desktop; fi' \
    "default browser"
  patch_drop_line "$src/bin/omarchy-provision-user" \
    "xdg-mime default HEY.desktop x-scheme-handler/mailto" "mailto handler"

  # 4b. Fedora names Chromium's launcher chromium-browser.desktop. Web apps
  #     fall back to Chromium when the default browser is not Chromium-based
  #     (Fedora defaults to Firefox), so let them find whichever exists.
  patch_literal "$src/bin/omarchy-launch-webapp" \
    '*) browser="chromium.desktop" ;;' \
    '*) browser=$(for d in chromium.desktop chromium-browser.desktop google-chrome.desktop; do for dir in ~/.local/share/applications /usr/share/applications; do [[ -f $dir/$d ]] && { echo "$d"; break 2; }; done; done) ;;' \
    "webapp browser fallback"
  patch_literal "$src/bin/omarchy-default-browser" \
    'chromium) desktop_id="chromium.desktop"' \
    'chromium) desktop_id="chromium-browser.desktop"' \
    "default browser id"
  patch_literal "$src/bin/omarchy-default-browser" \
    '  chromium.desktop) echo "chromium" ;;' \
    '  chromium.desktop | chromium-browser.desktop) echo "chromium" ;;' \
    "default browser name"

  # 4c. Leave the user's XDG folders alone. Omarchy points Desktop, Templates
  #     and Public at $HOME, which would also change them inside KDE.
  patch_drop_line "$src/bin/omarchy-provision-user" 'xdg-user-dirs-update --set TEMPLATES "$HOME"' "xdg templates dir"
  patch_drop_line "$src/bin/omarchy-provision-user" 'xdg-user-dirs-update --set PUBLICSHARE "$HOME"' "xdg public dir"
  patch_drop_line "$src/bin/omarchy-provision-user" 'xdg-user-dirs-update --set DESKTOP "$HOME"' "xdg desktop dir"
  patch_drop_line "$src/bin/omarchy-provision-user" 'rmdir ~/Templates ~/Public ~/Desktop' "xdg dir cleanup"

  # 4d. Refreshing launchers must not pull in the mise AI-CLI bundle.
  patch_literal "$src/bin/omarchy-refresh-applications" \
    $'if [[ -f "$OMARCHY_PATH/install/user/mise.sh" ]]; then\n  bash "$OMARCHY_PATH/install/user/mise.sh"\nfi' \
    '# Fedora port: mise tool bundle skipped (install tools with mise yourself).' \
    "skip mise bundle on refresh"

  # 4e. "Uninstall app" from the launcher: find the owning RPM instead of pacman.
  patch_literal "$src/bin/omarchy-remove-launcher-entry" \
    'pacman -Qqo "$desktop_file" 2>/dev/null | head -1' \
    "rpm -qf --qf '%{NAME}\\n' \"\$desktop_file\" 2>/dev/null | head -1" \
    "launcher owner lookup"
  patch_literal "$src/bin/omarchy-remove-launcher-entry" \
    'sudo pacman -Rns $quoted_package' \
    'sudo dnf remove $quoted_package' \
    "launcher package removal"

  # 5. Per-user setup: keep the portable steps, skip the mise/AI CLI bundle and
  #    the vendor-specific hardware fixes that target other laptops.
  cat >"$src/install/user/all.sh" <<'EOF'
# Fedora port: portable per-user setup steps only.
run_logged "$OMARCHY_INSTALL/user/theme.sh"
run_logged "$OMARCHY_INSTALL/user/chromium.sh"
run_logged "$OMARCHY_INSTALL/user/git.sh"
run_logged "$OMARCHY_INSTALL/user/xcompose.sh"
run_logged "$OMARCHY_INSTALL/user/default-keyring.sh"
EOF

  # 6. Enable each user unit on its own, so one missing helper (for example
  #    bt-agent from bluez-tools) does not stop the rest.
  cat >"$src/install/user/first-run/enable-user-units.sh" <<'EOF'
set -uo pipefail

systemctl --user daemon-reload
for unit in bt-agent.service omarchy-recover-internal-monitor.service \
  omarchy-sleep-lock.service omarchy-migrate-notify.service \
  omarchy-fcitx5.service omarchy-crash-watch.service; do
  if [[ $unit == omarchy-fcitx5.service ]] && ! command -v fcitx5 >/dev/null; then
    continue
  fi
  if [[ $unit == bt-agent.service ]] && ! command -v bt-agent >/dev/null; then
    continue
  fi
  systemctl --user enable --now "$unit" || echo "Could not enable $unit" >&2
done
exit 0
EOF

  # 7. Firmware updates: Fedora's fwupd handles its EFI binary itself.
  patch_drop_line "$src/bin/omarchy-update-firmware" \
    "sudo install -D /usr/lib/fwupd/efi/fwupdx64.efi" "fwupd EFI copy"

  # 8. Load the Fedora port's Hyprland module right after Omarchy's defaults.
  patch_literal "$src/config/hypr/hyprland.lua" \
    'require("default.hypr.omarchy")' \
    $'require("default.hypr.omarchy")\n\n-- Fedora port: hardware and fallback settings (see ~/.config/hypr/fedora.lua).\npcall(require, "hypr.fedora")' \
    "hyprland.lua fedora module"
  install -Dm644 "$PORT_DIR/overrides/config/hypr/fedora.lua" "$src/config/hypr/fedora.lua"

  # 9. Point "Reset to default" config actions at the Fedora installer.
  cat >"$src/bin/omarchy-reinstall-configs" <<'EOF'
#!/bin/bash

# omarchy:summary=Reset Omarchy user configs in $HOME to shipped defaults (Fedora port; backs up what it replaces)

set -euo pipefail
exec /usr/share/omarchy-fedora/port/install.sh --user-configs --force-configs "$@"
EOF
  chmod 755 "$src/bin/omarchy-reinstall-configs"

  # 10. Lutris runs with set -e, and umu-launcher has no Fedora package.
  patch_literal "$src/bin/omarchy-install-gaming-lutris" \
    "omarchy-pkg-add lutris umu-launcher wine-staging" \
    "omarchy-pkg-add lutris wine-staging" \
    "lutris without umu-launcher"

  # 10b. Snapshots: Fedora boots with GRUB, so there is no snapshot boot menu
  #      and no limine-snapper-restore.
  patch_literal "$src/bin/omarchy-snapshot" \
    'echo "Snapshots can be selected during boot."' \
    'echo "List snapshots with: sudo snapper -c root list"' \
    "snapshot message"
  patch_literal "$src/bin/omarchy-snapshot" \
    '  sudo limine-snapper-restore' \
    '  echo "Fedora has no snapshot boot menu. Restore files with: sudo snapper -c root undochange <id>..0" >&2; exit 1' \
    "snapshot restore"

  # 10b. The bar's update icon covers all of Fedora, not just Omarchy.
  patch_literal "$src/shell/plugins/bar/widgets/SystemUpdate.qml" \
    'tooltipText: "Pending Omarchy Updates"' \
    'tooltipText: "Pending Fedora Updates"' \
    "update icon tooltip"

  # 10c. Show the Fedomakase name on the desktop. The Learn menu keeps "Omarchy"
  #      because it links to Omarchy's manual.
  patch_literal "$src/etc/fastfetch/config.jsonc" \
    'echo \"Omarchy $version\"' \
    'echo \"Fedomakase ${version%% *}\"' \
    "fastfetch version label"
  patch_literal "$src/default/hypr/bindings/utilities.lua" \
    '"Omarchy menu"' \
    '"Fedomakase menu"' \
    "keybinding label"
  patch_literal "$src/default/omarchy/omarchy-menu.jsonc" \
    '"label":"Omarchy","action":"omarchy-launch-floating-terminal-with-presentation omarchy-update"' \
    '"label":"Fedomakase","action":"omarchy-launch-floating-terminal-with-presentation omarchy-update"' \
    "update menu label"

  # 10d. Fedomakase banner above the update terminal, and its window title.
  cp "$src/logo.txt" "$src/logo-omarchy.txt"   # lets the installer spot an untouched screensaver
  cp "$PORT_DIR/overrides/branding/logo.txt" "$src/logo.txt"
  patch_literal "$src/bin/omarchy-launch-floating-terminal-with-presentation" \
    '--title=Omarchy' \
    '--title=Fedomakase' \
    "floating terminal title"

  # 11. Fedora logo in fastfetch and the Omarchy menu. Icons are spelled as
  #     UTF-8 bytes so they survive editors and don't depend on the locale.
  local arch_icon=$'\xf3\xb0\xa3\x87' omarchy_icon=$'\xee\xa4\x80' fedora_icon=$'\xef\x8c\x8a' package_icon=$'\xf3\xb0\x8f\x96'
  local menu="$src/default/omarchy/omarchy-menu.jsonc"
  cp "$src/icon.txt" "$src/icon-omarchy.txt"   # lets the installer spot an untouched logo
  cp "$PORT_DIR/overrides/branding/about.txt" "$src/icon.txt"
  patch_literal "$src/etc/fastfetch/config.jsonc" \
    '"color": { "1": "green" }' \
    '"color": { "1": "blue" }' \
    "fastfetch logo color"
  patch_literal "$src/etc/fastfetch/config.jsonc" \
    '"key": "\ue900 OS"' \
    '"key": "\uf30a OS"' \
    "fastfetch OS icon"
  patch_literal "$src/shell/plugins/menu/BarWidget.qml" \
    'text: "\ue900"' \
    'text: "\uf30a"' \
    "menu button icon"
  patch_literal "$src/shell/plugins/menu/BarWidget.qml" \
    'fontFamily: "omarchy"' \
    'fontFamily: "JetBrainsMono Nerd Font"' \
    "menu button font"
  patch_literal "$menu" \
    "\"learn.arch\": {\"icon\":\"$arch_icon\",\"label\":\"Arch\",\"action\":\"omarchy-launch-webapp 'https://wiki.archlinux.org/title/Main_page'\"}" \
    "\"learn.arch\": {\"icon\":\"$fedora_icon\",\"label\":\"Fedora\",\"action\":\"omarchy-launch-webapp 'https://docs.fedoraproject.org/'\"}" \
    "learn menu entry"
  patch_literal "$menu" "\"icon\":\"$arch_icon\"" "\"icon\":\"$fedora_icon\"" "menu package icons"
  # The AUR entry opens a Flathub picker here (see omarchy-pkg-aur-install).
  patch_literal "$menu" \
    "\"install.aur\": {\"icon\":\"$fedora_icon\",\"label\":\"AUR\"," \
    "\"install.aur\": {\"icon\":\"$package_icon\",\"label\":\"Flathub\"," \
    "menu Flathub label"
  patch_literal "$menu" \
    "\"update.omarchy\": {\"icon\":\"$omarchy_icon\",\"iconFont\":\"omarchy\"," \
    "\"update.omarchy\": {\"icon\":\"$fedora_icon\"," \
    "menu update icon"
}
