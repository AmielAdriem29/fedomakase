#!/bin/bash
#
# Fedomakase: install Omarchy's Hyprland desktop on top of an existing
# Fedora system (tested target: Fedora KDE 44 on an Acer Nitro 5 AN515-58).
#
# It installs upstream Omarchy at a pinned release into /usr/share/omarchy,
# swaps the Arch-only pieces (pacman, AUR, Limine, Plymouth, SDDM) for Fedora
# equivalents, and adds a "Fedomakase" session to your login screen. KDE stays
# installed and untouched as a fallback session.
#
# Usage: ./install.sh [options]
#   --ref <tag>          Omarchy release to install (default: v4.0.6)
#   --build-quickshell   Compile Quickshell from source instead of using the COPR
#   --nvidia-driver      Also set up RPM Fusion and install akmod-nvidia
#   --no-tools           Skip the optional CLI tools (btop, eza, fzf, ...)
#   --no-bashrc          Don't hook Omarchy's shell aliases into ~/.bashrc
#   --skip-update-check  Install even if Fedora updates are pending (not recommended)
#   --update             Re-sync Omarchy files and configs only (no package installs)
#   --user-configs       Only (re)apply user configs in $HOME
#   --force-configs      With --user-configs: overwrite configs that already exist
#   -y, --yes            Don't ask for confirmation
#   -h, --help           Show this help

set -Eeuo pipefail

PORT_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
source "$PORT_DIR/lib/common.sh"
source "$PORT_DIR/lib/packages.sh"
source "$PORT_DIR/lib/patch.sh"

OMARCHY_REPO=${OMARCHY_REPO:-https://github.com/basecamp/omarchy.git}
OMARCHY_REF=${OMARCHY_REF:-v4.0.6}
HYPR_COPR=${HYPR_COPR:-nett00n/hyprland}
QS_COPR=${QS_COPR:-errornointernet/quickshell}
QS_REPO=${QS_REPO:-https://git.outfoxxed.me/quickshell/quickshell.git}
QS_COMMIT=${QS_COMMIT:-2b4501a282689792b62e94f3fb30d8f512324fe6}   # what Omarchy builds
HYPR_MIN=0.55.0     # first Hyprland with Lua configs, which Omarchy 4 is written in
HYPR_TESTED=0.56.2  # what Omarchy 4.0.x was tested against
QS_MIN=0.3.2

CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-fedora"
OF_LOG="$CACHE_DIR/install.log"
BACKUP_DIR="$HOME/.local/state/omarchy-fedora/backup-$(date +%Y%m%d-%H%M%S)"

opt_build_qs=0 opt_nvidia=0 opt_tools=1 opt_bashrc=1 opt_yes=0 opt_skip_update_check=0
mode=full force_configs=0

usage() { sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while (($#)); do
  case $1 in
    --ref) OMARCHY_REF=${2:?--ref needs a tag}; shift 2 ;;
    --build-quickshell) opt_build_qs=1; shift ;;
    --nvidia-driver) opt_nvidia=1; shift ;;
    --no-tools) opt_tools=0; shift ;;
    --no-bashrc) opt_bashrc=0; shift ;;
    --skip-update-check) opt_skip_update_check=1; shift ;;
    --update) mode=update; shift ;;
    --user-configs) mode=configs; shift ;;
    --force-configs) force_configs=1; shift ;;
    -y|--yes) opt_yes=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done

mkdir -p "$CACHE_DIR"
: >"$OF_LOG"

trap 'printf "\n%sInstall failed on line %s.%s Details: %s\n" "$c_red" "$LINENO" "$c_off" "$OF_LOG" >&2' ERR

# ---------------------------------------------------------------- preflight --

preflight() {
  step "Checking this system"
  (( EUID != 0 )) || die "Run this as your normal user, not root. It uses sudo when it needs to."
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ ${ID:-} == fedora ]] || die "This port is for Fedora (found: ${ID:-unknown})."
  (( ${VERSION_ID%%.*} >= 43 )) || die "Fedora 43 or newer is required (found $VERSION_ID). Hyprland's Lua configs need it."
  [[ $(uname -m) == x86_64 ]] || die "Only x86_64 is supported."
  ok "Fedora $VERSION_ID ($(uname -m))"

  if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} && $mode == full ]]; then
    warn "You are running this from inside Hyprland. Installing from KDE or a TTY is safer."
  fi

  sudo -v || die "sudo is required"
  ( while true; do sudo -n true; sleep 50; done ) 2>/dev/null &
  SUDO_KEEPALIVE=$!
  trap 'kill $SUDO_KEEPALIVE 2>/dev/null || true' EXIT

  local tool pkg
  for tool in git:git perl:perl-interpreter rsync:rsync curl:curl; do
    have "${tool%%:*}" || sudo dnf install -y "${tool#*:}" >>"$OF_LOG" 2>&1 || die "Could not install ${tool#*:}"
  done
  sudo mkdir -p "$OF_SHARE"
  sudo touch "$OF_SHARE/manifest"

  # The COPR builds of Hyprland and Quickshell target an up-to-date Fedora.
  # On a system that is behind, installing them forces a partial upgrade of Qt
  # and KDE, which can fail on renamed packages (kmime -> kf6-kmime). A full
  # upgrade first avoids that.
  if [[ $mode == full ]] && (( ! opt_skip_update_check )); then
    info "Checking for pending Fedora updates..."
    local pending
    pending=$(dnf check-upgrade --refresh --quiet 2>/dev/null | awk 'NF == 3 && $1 ~ /\./' | wc -l || true)
    if (( pending > 0 )); then
      die "$pending Fedora updates are pending. Update the system first, then re-run this installer:

         sudo dnf upgrade --refresh
         (if it reports a kmime file conflict: sudo dnf upgrade --refresh --allowerasing)

       Before rebooting after that update, if you use the NVIDIA driver, wait until
       this prints a version:   modinfo -F version nvidia
       (if it doesn't after a few minutes: sudo akmods --force)

       To install anyway, add --skip-update-check."
    fi
    ok "System is up to date"
  fi
}

confirm() {
  (( opt_yes )) && return 0
  cat <<EOF

This will install Fedomakase (Omarchy $OMARCHY_REF) as an extra session next to KDE:
  - Hyprland from COPR $HYPR_COPR, Quickshell from COPR $QS_COPR (or a source build)
  - Omarchy itself into /usr/share/omarchy, commands as /usr/bin/omarchy-*
  - Omarchy's configs into ~/.config (existing files are backed up first)
KDE Plasma and its settings are not removed or changed.

EOF
  read -rp "Continue? [y/N] " reply
  [[ $reply =~ ^[Yy] ]] || exit 0
}

# ---------------------------------------------------------------- packages --

setup_repos() {
  step "Enabling repositories"
  sudo dnf install -y dnf-plugins-core >>"$OF_LOG" 2>&1 || true
  copr_enable "$HYPR_COPR"
  copr_enable "$QS_COPR"
}

install_gum_fallback() {
  have gum && return 0
  info "gum is not in your repos; adding Charm's official repo for it"
  sudo tee /etc/yum.repos.d/charm.repo >/dev/null <<'EOF'
[charm]
name=Charm
baseurl=https://repo.charm.sh/yum/
enabled=1
gpgcheck=1
gpgkey=https://repo.charm.sh/yum/gpg.key
EOF
  manifest_add /etc/yum.repos.d/charm.repo
  sudo dnf install -y gum >>"$OF_LOG" 2>&1 || warn "Could not install gum; Omarchy's prompts and menus that use it will fail"
}

install_packages() {
  step "Installing packages (this takes a while; log: $OF_LOG)"
  dnf_required "Hyprland (COPR)" "${HYPR_PACKAGES[@]}"
  dnf_best_effort "Core desktop" "${REQUIRED_PACKAGES[@]}"
  install_gum_fallback
  dnf_best_effort "Session manager" "${SESSION_PACKAGES[@]}"
  dnf_best_effort "Desktop features" "${DESKTOP_PACKAGES[@]}"
  if (( opt_tools )); then
    local tools=() t
    for t in "${TOOL_PACKAGES[@]}"; do
      # Keep RPM Fusion's full ffmpeg if it is already there.
      [[ $t == ffmpeg-free ]] && have ffmpeg && continue
      tools+=("$t")
    done
    dnf_best_effort "CLI tools" "${tools[@]}"
  fi
}

check_hyprland() {
  step "Checking Hyprland version"
  local v
  v=$(rpm -q --qf '%{VERSION}' hyprland 2>/dev/null || true)
  [[ -n $v ]] || die "Hyprland is not installed."
  if ! version_ge "$v" "$HYPR_MIN"; then
    die "Hyprland $v is too old. Omarchy 4 is written in Hyprland's Lua config (needs $HYPR_MIN+).
       Try another COPR, e.g.: HYPR_COPR=<owner/project> ./install.sh"
  fi
  if version_ge "$v" "$HYPR_TESTED"; then
    ok "Hyprland $v"
  else
    warn "Hyprland $v is older than what Omarchy was tested with ($HYPR_TESTED). Some window behavior may differ."
  fi
}

quickshell_version() {
  have quickshell || return 1
  quickshell --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1
}

build_quickshell() {
  step "Building Quickshell from source (commit ${QS_COMMIT:0:7})"
  dnf_best_effort "Quickshell build deps" "${QUICKSHELL_BUILD_DEPS[@]}"
  local src="$CACHE_DIR/quickshell"
  if [[ ! -d $src/.git ]]; then
    git clone --filter=blob:none "$QS_REPO" "$src" >>"$OF_LOG" 2>&1 || die "Could not clone Quickshell"
  fi
  git -C "$src" fetch --quiet origin >>"$OF_LOG" 2>&1 || true
  git -C "$src" checkout --quiet "$QS_COMMIT" || die "Quickshell commit $QS_COMMIT not found"
  cmake -S "$src" -B "$src/build" -GNinja \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DINSTALL_QML_PREFIX=lib64/qt6/qml \
    -DCRASH_REPORTER=OFF \
    -DDISTRIBUTOR="fedomakase" >>"$OF_LOG" 2>&1 || die "Quickshell configure failed (missing -devel package?). See $OF_LOG"
  cmake --build "$src/build" >>"$OF_LOG" 2>&1 || die "Quickshell build failed. See $OF_LOG"
  sudo cmake --install "$src/build" >>"$OF_LOG" 2>&1 || die "Quickshell install failed"
  sudo cp "$src/build/install_manifest.txt" "$OF_SHARE/quickshell-install-manifest.txt"
  ok "Quickshell built and installed"
}

install_quickshell() {
  step "Installing Quickshell"
  local v
  if (( ! opt_build_qs )); then
    if ! have quickshell; then
      sudo dnf install -y quickshell-git >>"$OF_LOG" 2>&1 ||
        sudo dnf install -y quickshell >>"$OF_LOG" 2>&1 || true
    fi
    v=$(quickshell_version || true)
    if [[ -n $v ]] && version_ge "$v" "$QS_MIN"; then
      ok "Quickshell $v"
      return 0
    fi
    [[ -n $v ]] && warn "Quickshell $v from the COPR is older than $QS_MIN; building from source instead."
    [[ -z $v ]] && info "No Quickshell package found; building from source."
    # Don't leave an old packaged copy shadowing the source build.
    sudo dnf remove -y quickshell quickshell-git >>"$OF_LOG" 2>&1 || true
  fi
  build_quickshell
  v=$(quickshell_version || true)
  [[ -n $v ]] || die "Quickshell did not install correctly"
}

install_fonts() {
  step "Installing fonts"
  local dir=/usr/local/share/fonts/omarchy-fedora
  if fc-list | grep -q "JetBrainsMono Nerd Font"; then
    ok "JetBrainsMono Nerd Font already installed"
  else
    local tmp
    tmp=$(mktemp -d)
    curl -fsSL -o "$tmp/jbm.tar.xz" \
      https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz ||
      { warn "Could not download JetBrainsMono Nerd Font"; rm -rf "$tmp"; return 0; }
    tar -xJf "$tmp/jbm.tar.xz" -C "$tmp"
    sudo install -d "$dir"
    sudo install -m644 "$tmp"/JetBrainsMonoNerdFont-*.ttf "$dir/"
    manifest_add "$dir"
    rm -rf "$tmp"
    ok "JetBrainsMono Nerd Font"
  fi
  sudo fc-cache -f >/dev/null 2>&1 || true
}

install_nvidia_driver() {
  (( opt_nvidia )) || return 0
  step "Installing the NVIDIA driver from RPM Fusion"
  local rel
  rel=$(rpm -E %fedora)
  if ! rpm -q rpmfusion-free-release rpmfusion-nonfree-release &>/dev/null; then
    sudo dnf install -y \
      "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$rel.noarch.rpm" \
      "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$rel.noarch.rpm" >>"$OF_LOG" 2>&1 ||
      die "Could not enable RPM Fusion"
  fi
  sudo dnf install -y akmod-nvidia xorg-x11-drv-nvidia-cuda libva-nvidia-driver >>"$OF_LOG" 2>&1 ||
    die "Could not install akmod-nvidia"
  info "Building the kernel module now so the first reboot works"
  sudo akmods --force >>"$OF_LOG" 2>&1 || true
  omarchy_check=$PORT_DIR/overrides/bin/fedomakase-nvidia-check
  bash "$omarchy_check" || warn "The NVIDIA module is not built yet. Don't reboot until 'modinfo nvidia' works."
}

# ------------------------------------------------------------ omarchy tree --

fetch_omarchy() {
  step "Fetching Omarchy $OMARCHY_REF"
  local src="$CACHE_DIR/src-$OMARCHY_REF"
  if [[ ! -d $src/.git ]]; then
    git clone --quiet --depth 1 --branch "$OMARCHY_REF" "$OMARCHY_REPO" "$src" >>"$OF_LOG" 2>&1 ||
      die "Could not clone $OMARCHY_REPO at $OMARCHY_REF"
  fi
  OMARCHY_SRC=$src
  ok "Omarchy $(git -C "$src" describe --tags 2>/dev/null || echo "$OMARCHY_REF") ($(git -C "$src" rev-parse --short HEAD))"
}

install_omarchy_tree() {
  step "Installing Omarchy into $OMARCHY_DEST"
  local stage
  stage=$(mktemp -d)
  # Ship what the omarchy + omarchy-settings packages ship, minus repo-only trees.
  local item
  for item in bin config default install migrations shell themes applications etc version logo.txt logo.svg icon.txt icon.png; do
    [[ -e $OMARCHY_SRC/$item ]] && cp -a "$OMARCHY_SRC/$item" "$stage/"
  done
  rm -rf "$stage"/themes/*/backgrounds/intros

  apply_fedora_patches "$stage"

  # Pause Hyprland's config auto-reload while files change underneath it.
  if [[ -x $OMARCHY_DEST/bin/omarchy-hyprland-reload-guard ]]; then
    sudo "$OMARCHY_DEST/bin/omarchy-hyprland-reload-guard" pause >/dev/null 2>&1 || true
  fi

  sudo mkdir -p "$OMARCHY_DEST" "$OF_SHARE"
  sudo rsync -a --delete "$stage/" "$OMARCHY_DEST/" 2>>"$OF_LOG" ||
    { sudo rm -rf "$OMARCHY_DEST" && sudo cp -a "$stage" "$OMARCHY_DEST"; }
  sudo chown -R root:root "$OMARCHY_DEST"
  sudo chmod -R u=rwX,go=rX "$OMARCHY_DEST"
  rm -rf "$stage"

  # /usr/bin/omarchy-* -> /usr/share/omarchy/bin/*, like the Arch package.
  local bin name
  for bin in "$OMARCHY_DEST"/bin/omarchy* "$OMARCHY_DEST"/bin/fedomakase*; do
    name=$(basename "$bin")
    sudo ln -sfn "$OMARCHY_DEST/bin/$name" "/usr/bin/$name"
  done
  # Drop links for commands that no longer exist in this release.
  for bin in /usr/bin/omarchy-* /usr/bin/fedomakase-*; do
    [[ -L $bin && ! -e $bin ]] && sudo rm -f "$bin"
  done

  # Keep a copy of the port so fedomakase-update can re-run it.
  sudo rsync -a --delete --exclude .git "$PORT_DIR/" "$OF_SHARE/port/" 2>>"$OF_LOG" ||
    { sudo rm -rf "$OF_SHARE/port"; sudo cp -a "$PORT_DIR" "$OF_SHARE/port"; }
  sudo install -m644 "$PORT_DIR/lib/pkgmap.tsv" "$OF_SHARE/pkgmap.tsv"
  local described
  described=$(git -C "$OMARCHY_SRC" describe --tags 2>/dev/null || echo "$OMARCHY_REF")
  echo "${described#v} (fedomakase)" | sudo tee "$OF_SHARE/version" >/dev/null
  echo "$OMARCHY_REF" | sudo tee "$OF_SHARE/ref" >/dev/null
  sudo ln -sfn "$OF_SHARE/port/fedomakase-update" /usr/bin/fedomakase-update
  sudo ln -sfn fedomakase-update /usr/bin/omarchy-fedora-update   # old name

  if [[ -x $OMARCHY_DEST/bin/omarchy-hyprland-reload-guard ]]; then
    sudo "$OMARCHY_DEST/bin/omarchy-hyprland-reload-guard" resume >/dev/null 2>&1 || true
  fi
  ok "$(ls "$OMARCHY_DEST/bin" | wc -l) commands linked into /usr/bin"
}

install_shims() {
  step "Adding Fedora stand-ins for Arch-only tools"
  local shim
  for shim in tensaku-edit omacalc; do
    if ! have "$shim" || grep -q 'Fedora port shim' "$(command -v "$shim")" 2>/dev/null; then
      install_sys 755 "$PORT_DIR/overrides/shims/$shim" "/usr/local/bin/$shim"
      ok "$shim -> $( [[ $shim == tensaku-edit ]] && echo satty || echo gnome-calculator )"
    fi
  done
  if ! have uwsm || grep -q 'Fedora port shim' "$(command -v uwsm)" 2>/dev/null; then
    install_sys 755 "$PORT_DIR/overrides/shims/uwsm" /usr/local/bin/uwsm
    install_sys 755 "$PORT_DIR/overrides/shims/uwsm-app" /usr/local/bin/uwsm-app
    warn "uwsm is not available; using a minimal shim. The session runs Hyprland directly."
  elif ! have uwsm-app || grep -q 'Fedora port' "$(command -v uwsm-app)" 2>/dev/null; then
    # Fedora's uwsm package ships `uwsm` but not the `uwsm-app` client that
    # Arch includes. Omarchy launches every app through uwsm-app, so without
    # it nothing opens. `uwsm app` takes the same arguments.
    sudo tee /usr/local/bin/uwsm-app >/dev/null <<'EOF'
#!/bin/sh
# Fedora port: uwsm-app client (Fedora's uwsm package does not include it).
exec uwsm app "$@"
EOF
    sudo chmod 755 /usr/local/bin/uwsm-app
    manifest_add /usr/local/bin/uwsm-app
    ok "uwsm-app -> uwsm app"
  fi
  if ! have xdg-terminal-exec; then
    # Tiny fallback that honors Omarchy's terminal list (foot first).
    sudo tee /usr/local/bin/xdg-terminal-exec >/dev/null <<'EOF'
#!/bin/bash
# Fedora port shim: minimal xdg-terminal-exec (install the real one with: sudo dnf install xdg-terminal-exec)
for t in foot alacritty kitty ghostty konsole; do
  if command -v "$t" >/dev/null; then
    case $t in
      konsole) exec konsole -e "$@" ;;
      *) (( $# )) && exec "$t" -e "$@" || exec "$t" ;;
    esac
  fi
done
exit 1
EOF
    sudo chmod 755 /usr/local/bin/xdg-terminal-exec
    manifest_add /usr/local/bin/xdg-terminal-exec
    ok "xdg-terminal-exec fallback"
  fi
}

# ------------------------------------------------------------- system files --

install_system_files() {
  step "Installing system integration files"
  local d=$OMARCHY_DEST

  # Session environment and shell bootstrap.
  install_sys 644 "$d/etc/profile.d/omarchy.sh" /etc/profile.d/omarchy.sh
  install_sys 644 "$d/default/uwsm/env.d/10-omarchy" /usr/share/uwsm/env.d/10-omarchy
  [[ -f $d/default/environment.d/10-omarchy-fcitx.conf ]] && have fcitx5 &&
    install_sys 644 "$d/default/environment.d/10-omarchy-fcitx.conf" /usr/lib/environment.d/10-omarchy-fcitx.conf

  # Fonts and font defaults.
  install_sys 644 "$d/default/fonts/omarchy/omarchy.ttf" /usr/share/fonts/omarchy/omarchy.ttf
  install_sys 644 "$d/default/fontconfig/conf.avail/50-omarchy.conf" /usr/share/fontconfig/conf.avail/50-omarchy.conf
  sudo ln -sfn /usr/share/fontconfig/conf.avail/50-omarchy.conf /etc/fonts/conf.d/50-omarchy.conf
  manifest_add /etc/fonts/conf.d/50-omarchy.conf

  # Terminal preference list (foot first) used by xdg-terminal-exec.
  install_sys 644 "$d/default/xdg-terminal-exec/hyprland-xdg-terminals.list" /usr/share/xdg-terminal-exec/hyprland-xdg-terminals.list

  # User services that first-run enables.
  local unit
  for unit in "$d"/default/systemd/user/*.service; do
    install_sys 644 "$unit" "/usr/lib/systemd/user/$(basename "$unit")"
  done
  if [[ -f $d/default/systemd/user/app.slice.d/10-oomd.conf ]]; then
    install_sys 644 "$d/default/systemd/user/app.slice.d/10-oomd.conf" /usr/lib/systemd/user/app.slice.d/10-oomd.conf
  fi
  [[ -f $d/default/systemd/system-sleep/unmount-fuse ]] &&
    install_sys 755 "$d/default/systemd/system-sleep/unmount-fuse" /usr/lib/systemd/system-sleep/unmount-fuse

  # A safe subset of Omarchy's /etc drop-ins. Skipped on purpose: os-release,
  # nsswitch, faillock, cups, Plymouth, SDDM, Limine, mkinitcpio, zram/zswap,
  # docker and resolved tweaks. Fedora already configures those its own way.
  install_sys 644 "$d/etc/NetworkManager/conf.d/omarchy-wifi-powersave.conf" /etc/NetworkManager/conf.d/omarchy-wifi-powersave.conf
  install_sys 644 "$d/etc/systemd/logind.conf.d/20-inhibit-delay.conf" /etc/systemd/logind.conf.d/20-omarchy-inhibit-delay.conf
  install_sys 644 "$d/etc/sysctl.d/90-omarchy-file-watchers.conf" /etc/sysctl.d/90-omarchy-file-watchers.conf
  install_sys 644 "$d/etc/tmpfiles.d/omarchy-nopasswd-sudo.conf" /etc/tmpfiles.d/omarchy-nopasswd-sudo.conf
  [[ -f $d/etc/fastfetch/config.jsonc ]] && install_sys 644 "$d/etc/fastfetch/config.jsonc" /etc/fastfetch/config.jsonc
  [[ -f $d/etc/xdg/kitty/kitty.conf ]] && install_sys 644 "$d/etc/xdg/kitty/kitty.conf" /etc/xdg/kitty/kitty.conf

  # Passwordless helpers the menus call (DNS switch, theme browser accent,
  # timezone). Validated with visudo before they go live.
  local rule tmp
  for rule in "$d"/etc/sudoers.d/omarchy-*; do
    tmp=$(mktemp)
    cp "$rule" "$tmp"
    if sudo visudo -cqf "$tmp"; then
      sudo install -m440 -o root -g root "$tmp" "/etc/sudoers.d/$(basename "$rule")"
      manifest_add "/etc/sudoers.d/$(basename "$rule")"
    else
      warn "Skipped invalid sudoers rule $(basename "$rule")"
    fi
    rm -f "$tmp"
  done

  # Chromium theme policy directory (Omarchy repaints the browser accent per theme).
  sudo install -d -m755 /etc/chromium/policies/managed
  ( export OMARCHY_PATH=$d; source "$d/install/helpers/browser-policy.sh" 2>/dev/null &&
      browser_policy_setup_dir /etc/chromium/policies/managed ) >>"$OF_LOG" 2>&1 || true

  # Icons for Omarchy's launchers.
  local icon base
  for icon in "$d"/applications/icons/*; do
    [[ -f $icon ]] || continue
    base=$(basename "$icon")
    base=$(printf '%s' "${base%.*}" | tr '[:upper:]' '[:lower:]' | sed 's/[^[:alnum:]]\+/-/g; s/^-//; s/-$//')
    case $icon in
      *.svg) install_sys 644 "$icon" "/usr/share/icons/hicolor/scalable/apps/$base.svg" ;;
      *) install_sys 644 "$icon" "/usr/share/icons/hicolor/256x256/apps/$base.png" ;;
    esac
  done
  install_sys 644 "$d/icon.png" /usr/share/icons/hicolor/256x256/apps/omarchy.png
  sudo gtk-update-icon-cache -q /usr/share/icons/hicolor 2>/dev/null || true

  # Lock screen PAM stack (patched for Fedora's system-auth).
  sudo env PATH="$d/bin:$PATH" OMARCHY_PATH="$d" OMARCHY_INSTALL_USER="$USER" "$d/bin/omarchy-apply-lock" >>"$OF_LOG" 2>&1 ||
    warn "Could not configure the lock screen PAM file"

  sudo systemctl daemon-reload 2>/dev/null || true
  sudo sysctl --system >/dev/null 2>&1 || true
  ok "System files installed"
}

install_session() {
  step "Adding the Fedomakase session to the login screen"
  install_sys 755 "$PORT_DIR/overrides/session/start-omarchy" "$OF_SHARE/start-omarchy"
  local session=/usr/share/wayland-sessions/omarchy.desktop
  sudo install -d -m755 /usr/share/wayland-sessions
  sudo tee "$session" >/dev/null <<EOF
[Desktop Entry]
Name=Fedomakase
Comment=Omarchy's Hyprland desktop on Fedora
Exec=$OF_SHARE/start-omarchy
TryExec=Hyprland
Type=Application
DesktopNames=Hyprland
EOF
  manifest_add "$session"
  ok "Pick \"Fedomakase\" in the session menu on the login screen"
}

# -------------------------------------------------------------------- GPU --

setup_gpu() {
  step "Checking graphics hardware"
  local card vendor pci igpu="" dgpu="" nvidia=0
  local intel=() amd=() nv=()
  local drm=${OF_DRM_ROOT:-/sys/class/drm}
  for card in "$drm"/card[0-9] "$drm"/card[0-9][0-9]; do
    [[ -e $card/device/vendor ]] || continue
    vendor=$(<"$card/device/vendor")
    pci=$(basename "$(readlink -f "$card/device")")
    case $vendor in
      0x8086) intel+=("$pci") ;;
      0x1002) amd+=("$pci") ;;
      0x10de) nv+=("$pci") ;;
    esac
  done
  # Integrated: Intel first, else AMD. Discrete: NVIDIA first, else a second AMD.
  if (( ${#intel[@]} )); then
    igpu=${intel[0]}
    (( ${#nv[@]} )) && dgpu=${nv[0]} || dgpu=${amd[0]:-}
  elif (( ${#amd[@]} )); then
    igpu=${amd[0]}
    (( ${#nv[@]} )) && dgpu=${nv[0]} || dgpu=${amd[1]:-}
  else
    dgpu=${nv[0]:-}
  fi
  if (( ${#nv[@]} )); then nvidia=1; fi

  if [[ -z $igpu || -z $dgpu ]]; then
    ok "Single GPU (${igpu:-$dgpu}); no GPU pinning needed"
    return 0
  fi

  info "Hybrid graphics: iGPU $igpu, dGPU $dgpu"
  # Stable, colon-free device names, so AQ_DRM_DEVICES does not depend on the
  # card0/card1 order the kernel happens to pick at boot.
  sudo install -d -m755 /etc/udev/rules.d
  sudo tee /etc/udev/rules.d/61-omarchy-fedora-gpu.rules >/dev/null <<EOF
# Written by omarchy-fedora: stable names for Hyprland's GPU selection.
KERNEL=="card*", SUBSYSTEM=="drm", KERNELS=="$igpu", SYMLINK+="dri/omarchy-igpu"
KERNEL=="card*", SUBSYSTEM=="drm", KERNELS=="$dgpu", SYMLINK+="dri/omarchy-dgpu"
EOF
  manifest_add /etc/udev/rules.d/61-omarchy-fedora-gpu.rules
  sudo udevadm control --reload >/dev/null 2>&1 || true
  sudo udevadm trigger --subsystem-match=drm --action=change >/dev/null 2>&1 || true

  # Render the desktop on the iGPU; keep the dGPU second so monitors wired to
  # it (often the HDMI port on gaming laptops) still work.
  sudo install -d /etc/omarchy-fedora
  sudo tee /etc/omarchy-fedora/session.env >/dev/null <<'EOF'
# Written by omarchy-fedora. Sourced before Hyprland starts.
# Hyprland renders on the first device and only uses the second for outputs
# wired to it, so the NVIDIA card can sleep while you browse.
export AQ_DRM_DEVICES=/dev/dri/omarchy-igpu:/dev/dri/omarchy-dgpu
EOF
  manifest_add /etc/omarchy-fedora/session.env /etc/omarchy-fedora
  ok "Desktop pinned to the iGPU (edit /etc/omarchy-fedora/session.env to change)"

  if (( nvidia )); then
    if modinfo nvidia &>/dev/null; then
      ok "NVIDIA driver: $(modinfo -F version nvidia 2>/dev/null) ($(rpm -q akmod-nvidia &>/dev/null && echo akmod-nvidia || echo 'not from RPM Fusion'))"
    elif (( ! opt_nvidia )); then
      warn "No proprietary NVIDIA driver found (nouveau in use). Re-run with --nvidia-driver to install RPM Fusion's akmod-nvidia."
    fi
  fi
}

# ------------------------------------------------------------- user config --

# Copy a tree into $HOME, backing up any file it would replace.
copy_into_home() {
  local from=$1 to=$2 overwrite=$3
  local rel target
  while IFS= read -r -d '' rel; do
    rel=${rel#./}
    target="$to/$rel"
    if [[ -e $target || -L $target ]]; then
      cmp -s "$from/$rel" "$target" && continue
      if (( overwrite )); then
        mkdir -p "$BACKUP_DIR/$(dirname "${target#"$HOME"/}")"
        cp -a "$target" "$BACKUP_DIR/${target#"$HOME"/}"
        BACKED_UP=$((BACKED_UP + 1))
      else
        continue
      fi
    fi
    mkdir -p "$(dirname "$target")"
    cp -a "$from/$rel" "$target"
  done < <(cd "$from" && find . -type f -print0 -o -type l -print0)
}

install_user_configs() {
  step "Installing Omarchy configs into your home"
  local d=$OMARCHY_DEST overwrite=1
  BACKED_UP=0

  # Updates keep your edits unless you asked for a reset.
  if [[ $mode == update ]]; then overwrite=0; fi
  if [[ $mode == configs ]]; then overwrite=$force_configs; fi

  # A leftover hyprland.conf from an earlier Hyprland setup would compete with
  # Omarchy's hyprland.lua, so move it into the backup.
  if [[ -f $HOME/.config/hypr/hyprland.conf ]]; then
    mkdir -p "$BACKUP_DIR/.config/hypr"
    mv "$HOME/.config/hypr/hyprland.conf" "$BACKUP_DIR/.config/hypr/hyprland.conf"
    BACKED_UP=$((BACKED_UP + 1))
    info "Moved your old ~/.config/hypr/hyprland.conf to the backup"
  fi

  # Only the desktop's own configs (Hyprland, Omarchy) replace what is there.
  # Everything else (git, Chromium profile, tmux, starship, ...) is seeded only
  # when you don't have it yet, so KDE-era settings and your git identity stay.
  # --force-configs resets all of them. config/autostart is skipped: its
  # Hidden=true entries would also disable those apps inside KDE.
  local entry name entry_overwrite
  for entry in "$d"/config/* "$d"/config/.[!.]*; do
    [[ -e $entry ]] || continue
    name=$(basename "$entry")
    [[ $name == autostart ]] && continue
    case $name in
      hypr|omarchy) entry_overwrite=$overwrite ;;
      *) entry_overwrite=$force_configs ;;
    esac
    if [[ -d $entry ]]; then
      copy_into_home "$entry" "$HOME/.config/$name" "$entry_overwrite"
    elif [[ ! -e $HOME/.config/$name ]] || (( entry_overwrite )); then
      if [[ -e $HOME/.config/$name ]] && ! cmp -s "$entry" "$HOME/.config/$name"; then
        mkdir -p "$BACKUP_DIR/.config"
        cp -a "$HOME/.config/$name" "$BACKUP_DIR/.config/$name"
        BACKED_UP=$((BACKED_UP + 1))
      fi
      cp -a "$entry" "$HOME/.config/$name"
    fi
  done

  # Omarchy's git defaults (aliases, rebase on pull, ...) are included rather
  # than copied over an existing git config, so your name and email survive.
  if [[ -f $d/config/git/config ]] && ! cmp -s "$d/config/git/config" "$HOME/.config/git/config" &&
    ! git config --file "$HOME/.config/git/config" --get-all include.path 2>/dev/null | grep -qx "$d/config/git/config"; then
    git config --file "$HOME/.config/git/config" --add include.path "$d/config/git/config"
  fi

  # Your own Fedora tweaks file is never overwritten.
  [[ -f $HOME/.config/hypr/fedora.lua ]] || cp "$d/config/hypr/fedora.lua" "$HOME/.config/hypr/fedora.lua"

  mkdir -p "$HOME/.local/share/applications"
  find "$d/applications" -maxdepth 2 -name '*.desktop' -exec cp -f {} "$HOME/.local/share/applications/" \;

  mkdir -p "$HOME/.config/omarchy/branding" "$HOME/.local/state/omarchy/toggles/hypr" \
    "$HOME/.local/share/nautilus-python/extensions" \
    "$HOME/.local/share/flatpak/exports/share/applications"   # the shell only watches folders that exist at startup
  # Swap in the Fedomakase logo unless you set your own screensaver.
  if [[ ! -f $HOME/.config/omarchy/branding/screensaver.txt ]] || cmp -s "$HOME/.config/omarchy/branding/screensaver.txt" "$d/logo-omarchy.txt"; then
    cp "$d/logo.txt" "$HOME/.config/omarchy/branding/screensaver.txt"
  fi
  # Swap in the Fedora logo unless you set your own About logo.
  if [[ ! -f $HOME/.config/omarchy/branding/about.txt ]] || cmp -s "$HOME/.config/omarchy/branding/about.txt" "$d/icon-omarchy.txt"; then
    cp "$d/icon.txt" "$HOME/.config/omarchy/branding/about.txt"
  fi
  [[ -f $HOME/.local/state/omarchy/toggles/hypr/flags.lua ]] || cp "$d/default/hypr/toggles/flags.lua" "$HOME/.local/state/omarchy/toggles/hypr/flags.lua"
  cp -f "$d"/default/nautilus-python/extensions/*.py "$HOME/.local/share/nautilus-python/extensions/" 2>/dev/null || true

  # Upstream migrations repair Arch installs; mark them done for this release.
  mkdir -p "$HOME/.local/state/omarchy/migrations"
  local m
  for m in "$d"/migrations/*.sh; do
    [[ -f $m ]] && touch "$HOME/.local/state/omarchy/migrations/$(basename "$m")"
  done

  # KDE's Xwayland video bridge autostarts in every session, and Hyprland shows
  # it as a blank window that won't close. Keep it to KDE.
  local bridge=org.kde.xwaylandvideobridge.desktop
  if [[ -f /etc/xdg/autostart/$bridge && ! -e $HOME/.config/autostart/$bridge ]]; then
    mkdir -p "$HOME/.config/autostart"
    sed '0,/^\[Desktop Entry\]$/s//&\nOnlyShowIn=KDE;/' "/etc/xdg/autostart/$bridge" >"$HOME/.config/autostart/$bridge"
  fi

  # uwsm reads compositor-specific env from here; reuse the session env.
  mkdir -p "$HOME/.config/uwsm"
  if [[ ! -f $HOME/.config/uwsm/env-hyprland ]] || grep -q omarchy-fedora "$HOME/.config/uwsm/env-hyprland"; then
    cat >"$HOME/.config/uwsm/env-hyprland" <<'EOF'
# omarchy-fedora: machine-specific session environment (GPU pinning).
[ -r /etc/omarchy-fedora/session.env ] && . /etc/omarchy-fedora/session.env
[ -r "$HOME/.config/omarchy-fedora/session.env" ] && . "$HOME/.config/omarchy-fedora/session.env"
EOF
  fi

  if (( opt_bashrc )) && ! grep -q '>>> omarchy-fedora >>>' "$HOME/.bashrc" 2>/dev/null; then
    [[ -f $HOME/.bashrc ]] && { mkdir -p "$BACKUP_DIR"; cp -a "$HOME/.bashrc" "$BACKUP_DIR/.bashrc"; }
    cat >>"$HOME/.bashrc" <<'EOF'

# >>> omarchy-fedora >>>
# Omarchy's shell aliases, prompt and functions. Remove this block to opt out.
[[ -r /usr/share/omarchy/default/bash/env-bootstrap ]] && source /usr/share/omarchy/default/bash/env-bootstrap
[[ $- == *i* && -r /usr/share/omarchy/default/bash/rc ]] && source /usr/share/omarchy/default/bash/rc
# <<< omarchy-fedora <<<
EOF
    ok "Hooked Omarchy's shell setup into ~/.bashrc"
  fi

  if (( BACKED_UP > 0 )); then
    ok "Configs installed; $BACKED_UP existing file(s) backed up to $BACKUP_DIR"
  else
    ok "Configs installed"
  fi
}

provision_user() {
  step "Running Omarchy's per-user setup (theme, keyring, XCompose)"
  local d=$OMARCHY_DEST
  # A non-"runtime" context makes the theme step work without a running session.
  if env OMARCHY_PATH="$d" PATH="$d/bin:$PATH" OMARCHY_SETUP_CONTEXT=fedora-install \
      OMARCHY_USER_NAME="$(git config --global user.name 2>/dev/null || true)" \
      OMARCHY_USER_EMAIL="$(git config --global user.email 2>/dev/null || true)" \
      "$d/bin/omarchy-provision-user" --force >>"$OF_LOG" 2>&1; then
    ok "Theme set to Tokyo Night (change it later with SUPER+SHIFT+CTRL+SPACE)"
  else
    warn "Per-user setup reported errors (see $OF_LOG). The first login runs it again."
  fi
}

# ----------------------------------------------------------------- checks --

final_checks() {
  step "Checking the result"
  local cmd missing=()
  for cmd in "${REQUIRED_COMMANDS[@]}"; do
    have "$cmd" || missing+=("$cmd")
  done
  if (( ${#missing[@]} )); then
    warn "Missing commands the desktop needs: ${missing[*]}"
  else
    ok "All required commands are present"
  fi
}

summary() {
  printf '\n%sFedomakase (Omarchy %s) is installed.%s\n\n' "$c_grn" "$OMARCHY_REF" "$c_off"
  cat <<EOF
Next:
  1. Log out of KDE.
  2. On the login screen, pick the "Fedomakase" session, then log in.
  3. Press SUPER+K for the keybindings list, SUPER+SPACE for the menu.

Update later with:   omarchy-update            (Fedora packages + NVIDIA check)
Move to a release:   fedomakase-update --ref <tag>
Undo everything:     $OF_SHARE/port/uninstall.sh
EOF
  if (( ${#WARNINGS[@]} )); then
    printf '\n%sNotes (%d):%s\n' "$c_ylw" "${#WARNINGS[@]}" "$c_off"
    printf '  - %s\n' "${WARNINGS[@]}"
  fi
  echo
}

# ------------------------------------------------------------------- main --

case $mode in
  full)
    preflight
    confirm
    setup_repos
    install_packages
    check_hyprland
    install_quickshell
    install_fonts
    install_nvidia_driver
    fetch_omarchy
    install_omarchy_tree
    install_shims
    install_system_files
    install_session
    setup_gpu
    install_user_configs
    provision_user
    final_checks
    summary
    ;;
  update)
    preflight
    check_hyprland
    fetch_omarchy
    install_omarchy_tree
    install_shims
    install_system_files
    install_session
    install_user_configs
    final_checks
    # The shell's QML just changed underneath it; reload it if it is running.
    if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
      omarchy-restart-shell >/dev/null 2>&1 || true
    fi
    summary
    ;;
  configs)
    (( EUID != 0 )) || die "Run as your normal user."
    [[ -d $OMARCHY_DEST/config ]] || die "Omarchy is not installed yet."
    install_user_configs
    ;;
esac
