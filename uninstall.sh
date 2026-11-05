#!/bin/bash
#
# Remove the Omarchy Fedora port. KDE and your Fedora packages stay.
#
# Usage: ./uninstall.sh [--packages] [--configs]
#   --packages   also remove Hyprland, Quickshell and the two COPRs
#   --configs    also delete Omarchy's files in ~/.config (they are moved to a backup)

set -uo pipefail

SHARE=/usr/share/omarchy-fedora
remove_packages=0
remove_configs=0
while (($#)); do
  case $1 in
    --packages) remove_packages=1 ;;
    --configs) remove_configs=1 ;;
    -h|--help) sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

(( EUID != 0 )) || { echo "Run as your normal user." >&2; exit 1; }

echo "This removes Fedomakase from /usr/share/omarchy, its /usr/bin commands, the login"
echo "session and the system files the port installed."
read -rp "Continue? [y/N] " reply
[[ $reply =~ ^[Yy] ]] || exit 0
sudo -v || exit 1

# Commands: only symlinks that point into Omarchy's tree.
for link in /usr/bin/omarchy* /usr/bin/fedomakase*; do
  [[ -L $link ]] || continue
  case $(readlink "$link") in
    /usr/share/omarchy/*|/usr/share/omarchy-fedora/*) sudo rm -f "$link" ;;
  esac
done

# Every file and directory the installer recorded, deepest paths first.
if [[ -f $SHARE/manifest ]]; then
  sort -ru "$SHARE/manifest" | while IFS= read -r path; do
    [[ -n $path && $path == /* ]] || continue
    case $path in
      /|/etc|/usr|/usr/share|/usr/lib|/usr/local|/usr/local/bin|/etc/sudoers.d) continue ;;
    esac
    sudo rm -rf -- "$path"
  done
fi

# A source-built Quickshell.
if [[ -f $SHARE/quickshell-install-manifest.txt ]]; then
  while IFS= read -r path; do
    [[ -n $path ]] && sudo rm -f -- "$path"
  done <"$SHARE/quickshell-install-manifest.txt"
fi

sudo rm -f /etc/pam.d/omarchy-lock-password /etc/pam.d/omarchy-lock-fingerprint
sudo rm -rf /usr/share/omarchy "$SHARE"
sudo udevadm control --reload 2>/dev/null || true
sudo systemctl daemon-reload

if (( remove_packages )); then
  sudo dnf remove -y hyprland xdg-desktop-portal-hyprland quickshell quickshell-git 2>/dev/null
  sudo dnf copr disable -y nett00n/hyprland 2>/dev/null
  sudo dnf copr disable -y ashbuk/Hyprland-Fedora 2>/dev/null
  sudo dnf copr disable -y errornointernet/quickshell 2>/dev/null
fi

# Let KDE's video bridge follow the system autostart again.
rm -f ~/.config/autostart/org.kde.xwaylandvideobridge.desktop

# ~/.bashrc hook.
if grep -q '>>> omarchy-fedora >>>' ~/.bashrc 2>/dev/null; then
  sed -i '/^# >>> omarchy-fedora >>>$/,/^# <<< omarchy-fedora <<<$/d' ~/.bashrc
fi

# Stop the Omarchy user services so they don't fail in KDE sessions.
systemctl --user disable --now bt-agent.service omarchy-recover-internal-monitor.service \
  omarchy-sleep-lock.service omarchy-migrate-notify.service omarchy-fcitx5.service \
  omarchy-crash-watch.service 2>/dev/null || true

if (( remove_configs )); then
  backup=~/.local/state/omarchy-fedora/removed-$(date +%Y%m%d-%H%M%S)
  mkdir -p "$backup"
  for dir in hypr omarchy uwsm; do
    [[ -e ~/.config/$dir ]] && mv ~/.config/$dir "$backup/"
  done
  [[ -d ~/.local/state/omarchy ]] && mv ~/.local/state/omarchy "$backup/state-omarchy"
  echo "Moved Omarchy configs to $backup"
fi

echo "Fedomakase has been removed. Log out and pick Plasma on the login screen."
