# Shared helpers for the Fedomakase installer. Sourced, not executed.

OF_NAME="fedomakase"
OF_SHARE="${OF_SHARE:-/usr/share/omarchy-fedora}"   # port metadata: manifest, pkgmap, version
OMARCHY_DEST="${OMARCHY_DEST:-/usr/share/omarchy}"      # where upstream Omarchy expects to live

c_red=$'\e[31m'; c_grn=$'\e[32m'; c_ylw=$'\e[33m'; c_blu=$'\e[34m'; c_dim=$'\e[2m'; c_off=$'\e[0m'

step() { printf '\n%s==>%s %s\n' "$c_blu" "$c_off" "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✓%s %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '    %s!%s %s\n' "$c_ylw" "$c_off" "$*" >&2; WARNINGS+=("$*"); }
die()  { printf '\n%sError:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

declare -ga WARNINGS=()

# Returns 0 when version $1 >= version $2 (dotted numeric compare).
version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

have() { command -v "$1" >/dev/null 2>&1; }

rpm_installed() { rpm -q --whatprovides "$1" >/dev/null 2>&1; }

# Install packages one at a time so a single wrong or missing name never
# aborts the whole group. Prints what could not be installed.
dnf_best_effort() {
  local group=$1; shift
  local missing=() pkg
  local todo=()
  for pkg in "$@"; do
    rpm_installed "$pkg" || todo+=("$pkg")
  done
  if (( ${#todo[@]} == 0 )); then
    ok "$group: already installed"
    return 0
  fi
  # Fast path: the whole batch in one transaction. If one package conflicts with
  # something already installed (say ffmpeg-free vs RPM Fusion's ffmpeg), the
  # batch fails as a whole, so retry the leftovers one by one.
  sudo dnf install -y --setopt=install_weak_deps=False --skip-unavailable "${todo[@]}" >>"$OF_LOG" 2>&1 || true
  for pkg in "${todo[@]}"; do
    rpm_installed "$pkg" && continue
    sudo dnf install -y --setopt=install_weak_deps=False "$pkg" >>"$OF_LOG" 2>&1 || true
    rpm_installed "$pkg" || missing+=("$pkg")
  done
  if (( ${#missing[@]} )); then
    warn "$group: not available from your repos: ${missing[*]}"
  else
    ok "$group: installed"
  fi
}

# Install packages that must all succeed.
dnf_required() {
  local group=$1; shift
  local todo=() pkg
  for pkg in "$@"; do
    rpm_installed "$pkg" || todo+=("$pkg")
  done
  if (( ${#todo[@]} == 0 )); then
    ok "$group: already installed"
    return 0
  fi
  sudo dnf install -y "${todo[@]}" || die "Could not install required packages ($group): ${todo[*]}"
  ok "$group: installed"
}

copr_enable() {
  local repo=$1
  if dnf copr list 2>/dev/null | grep -qi "^copr.fedorainfracloud.org/${repo}\b"; then
    ok "COPR $repo already enabled"
    return 0
  fi
  sudo dnf copr enable -y "$repo" >>"$OF_LOG" 2>&1 || die "Could not enable COPR $repo"
  ok "Enabled COPR $repo"
}

# Record a path the installer created so uninstall.sh can remove it.
manifest_add() {
  printf '%s\n' "$@" | sudo tee -a "$OF_SHARE/manifest" >/dev/null
}

# Install a file as root and record it.
install_sys() {
  local mode=$1 src=$2 dst=$3
  sudo install -Dm"$mode" "$src" "$dst"
  manifest_add "$dst"
}
