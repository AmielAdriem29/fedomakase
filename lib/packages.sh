# Fedora package sets for the Omarchy port. Sourced by install.sh.
# Names here are Fedora names. Arch names used by Omarchy's own scripts are
# translated at runtime through pkgmap.tsv.

# From the Hyprland COPR, which also carries uwsm, satty and the hypr* tools below.
# hyprlock and hypridle are not needed: Omarchy 4 locks and idles through Quickshell.
HYPR_PACKAGES=(
  hyprland
  xdg-desktop-portal-hyprland
)

# Needed for the desktop to start and for the keybinds to do anything.
REQUIRED_PACKAGES=(
  foot                      # Omarchy's default terminal (SUPER+RETURN)
  wl-clipboard grim slurp wtype
  brightnessctl pamixer playerctl
  jq socat inotify-tools libnotify gum
  xdg-desktop-portal-gtk xdg-user-dirs xdg-utils
  gnome-keyring libsecret polkit
  nautilus
  git curl unzip tar xz perl perl-JSON-PP perl-Encode perl-open
  fontconfig liberation-sans-fonts google-noto-color-emoji-fonts
  google-noto-sans-fonts
  wireplumber pipewire-utils
  ImageMagick desktop-file-utils
  udiskie
  NetworkManager
  bluez
  upower
  procps-ng psmisc util-linux util-linux-script
  python3-gobject
  qt6-qtwayland qt6-qtsvg qt6-qtimageformats qt6-qtmultimedia qt6-qt5compat
)

# Commands that must exist once the packages above are in. The installer checks
# these instead of package names, since Fedora splits some tools differently.
REQUIRED_COMMANDS=(
  Hyprland hyprctl uwsm-app quickshell foot wl-copy grim slurp wtype brightnessctl
  jq socat gum notify-send nautilus git curl magick udiskie script
)

# Session manager. Omarchy launches every app through uwsm-app; the installer
# adds small shims if uwsm turns out to be unavailable.
SESSION_PACKAGES=(
  uwsm
)

# Desktop pieces that individual features use. Missing ones only disable that
# feature (color picker, nightlight, screen recording, OCR, ...).
DESKTOP_PACKAGES=(
  hyprpicker                # SUPER+PRINT color picker
  hyprsunset                # nightlight toggle
  hyprland-guiutils         # Hyprland's dialogs and share picker
  xdg-terminal-exec         # terminal lookup used by launchers
  satty                     # screenshot annotation (stands in for Tensaku)
  tesseract tesseract-langpack-eng   # SUPER+CTRL+PRINT OCR
  zbar qrencode
  bluez-tools               # bt-agent for Bluetooth pairing
  imv mpv evince sushi nautilus-python
  ffmpegthumbnailer gnome-disk-utility
  yaru-icon-theme
  ddcutil                   # external monitor brightness
  fontawesome-6-free-fonts fontawesome-6-brands-fonts
  gnome-calculator          # SUPER+CTRL+Q (omacalc shim)
  fprintd fprintd-pam
)

# Command-line tools Omarchy's shell config and TUIs expect.
TOOL_PACKAGES=(
  btop bat eza fd-find fzf ripgrep zoxide starship
  fastfetch tmux neovim lazygit tldr
  plocate less man-db whois
  vips yt-dlp ffmpeg-free
  inxi
)

# Build dependencies for compiling Quickshell when no recent enough package exists.
QUICKSHELL_BUILD_DEPS=(
  cmake ninja-build gcc-c++ pkgconf-pkg-config git
  qt6-qtbase-devel qt6-qtbase-private-devel
  qt6-qtdeclarative-devel qt6-qtshadertools-devel
  qt6-qtwayland-devel qt6-qtsvg-devel
  spirv-tools wayland-devel wayland-protocols-devel
  libdrm-devel mesa-libgbm-devel libglvnd-devel
  pipewire-devel pam-devel polkit-devel
  cli11-devel jemalloc-devel libxcb-devel vulkan-headers glib2-devel
)
