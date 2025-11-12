#!/data/data/com.termux/files/usr/bin/bash
# Roblox reconnect script for Termux (uses join link format /games/start?placeId=GAMEID)
# Updated by: copilot (for derdevil1232)
# - Adds cooldowns: opens the Roblox app first, waits a configurable "app warmup" cooldown,
#   then opens the join link inside the Roblox app.
# - Adds a simple Termux UI that clears the console and shows a RoFarmManager logo,
#   monitored user(s) (id + username), and the single current action.
# - Uses presence API, restart interval, and optional Delta auto-update as before.
#
# Usage: ./reconnect.sh
# Requires: curl, jq, am, pm, monkey (monkey is part of Android platform tools),
#           termux environment (Termux on Android).
#
# Notes:
# - Termux must have storage permission for APK downloads: run `termux-setup-storage` if needed.
# - The script still tries various join link formats but will use the requested /games/start?placeId=GAMEID as primary.
# - The UI intentionally clears previous output and only displays the current action.

set -euo pipefail

ROBLOX_PKG="com.roblox.client"
WEAO_UA="WEAO-3PService"
DL_DIR="/sdcard/Download"
SLEEP_SHORT=5

# Default cooldowns (seconds) - you will be asked to confirm/change these when starting the script.
DEFAULT_APP_WARMUP=10    # time to wait after launching the Roblox app before opening the join link
DEFAULT_LINK_COOLDOWN=3  # extra wait between open-intent attempts
DEFAULT_JOIN_WAIT=25     # wait after opening join link to allow joining

# ensure required commands exist (attempt pkg install if missing)
require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command '$1' not found. Attempting to install via pkg..."
    pkg install -y "$1" >/dev/null 2>&1 || {
      echo "Please install '$1' and re-run the script."
      exit 1
    }
  fi
}

require_cmd curl
require_cmd jq

# helper: trim whitespace
trim() {
  local var="$*"
  var="${var#"${var%%[![:space:]]*}"}"
  var="${var%"${var##*[![:space:]]}"}"
  printf '%s' "$var"
}

# UI: clear screen and display a simple interface showing logo, users, and current action
ui_update() {
  local action="$1"
  # full reset/clear
  printf "\033c"
  # Logo (simple)
  cat <<'LOGO'
    ____        ______                     __  ___                                 
   / __ \____  / ____/___ __________ ___  /  |/  /___ _____  ____ _____ ____  _____
  / /_/ / __ \/ /_  / __ `/ ___/ __ `__ \/ /|_/ / __ `/ __ \/ __ `/ __ `/ _ \/ ___/
 / _, _/ /_/ / __/ / /_/ / /  / / / / / / /  / / /_/ / / / / /_/ / /_/ /  __/ /    
/_/ |_|\____/_/    \__,_/_/  /_/ /_/ /_/_/  /_/\__,_/_/ /_/\__,_/\__, /\___/_/     
                                                                /____/             
                         RoFarmManager
LOGO

  echo "-----------------------------------------------------------------"
  # Show monitored users (id + username cached)
  if [ "${#USER_IDS[@]}" -gt 0 ]; then
    printf "Monitored accounts:\n"
    for uid in "${USER_IDS[@]}"; do
      uname="${USERNAMES[$uid]:-unknown}"
      printf "  • %s — %s\n" "$uid" "$uname"
    done
  else
    echo "No monitored accounts configured."
  fi
  echo "-----------------------------------------------------------------"
  printf "Current action: %s\n" "$action"
  echo "-----------------------------------------------------------------"
}

# prompt yes/no
prompt_yesno() {
  local prompt="$1"
  while true; do
    read -rp "$prompt [y/n]: " yn
    yn=$(echo "$yn" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    case "$yn" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

# Build primary join link and fallback
build_links_from_gameid() {
  local gid="$1"
  links=()
  links+=("https://www.roblox.com/games/start?placeId=${gid}")
  # fallback deep link style that Roblox sometimes handles
  links+=("roblox://experiences/start?placeId=${gid}")
  # fallback to main game page
  links+=("https://www.roblox.com/games/${gid}")
}

# open a URL via Android intent, preferring Roblox app
open_in_roblox() {
  local url="$1"
  # Use am start with package; if that silently fails, try without package
  am start -a android.intent.action.VIEW -d "$url" "$ROBLOX_PKG" >/dev/null 2>&1 || true
  sleep 0.7
  am start -a android.intent.action.VIEW -d "$url" >/dev/null 2>&1 || true
}

# Launch the Roblox app (without opening a link) to warm it up.
# We use monkey to send a single launch event (works on many Android devices).
launch_roblox_app() {
  # Update UI
  ui_update "Launching Roblox app..."
  if command -v monkey >/dev/null 2>&1; then
    monkey -p "$ROBLOX_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
  else
    # fallback: try am start with MAIN action and category LAUNCHER
    am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n "$ROBLOX_PKG"/.MainActivity >/dev/null 2>&1 || true
    am start -a android.intent.action.MAIN -n "$ROBLOX_PKG" >/dev/null 2>&1 || true
  fi
}

# fully stop Roblox app
force_stop_roblox() {
  ui_update "Force-stopping Roblox app..."
  if command -v am >/dev/null 2>&1; then
    am force-stop "$ROBLOX_PKG" >/dev/null 2>&1 || true
  fi
}

# get installed Roblox Android version name (versionName)
get_installed_roblox_version() {
  local ver=""
  if command -v dumpsys >/dev/null 2>&1; then
    ver=$(dumpsys package "$ROBLOX_PKG" 2>/dev/null | grep -m1 versionName || true)
  fi
  if [ -z "$ver" ] && command -v pm >/dev/null 2>&1; then
    ver=$(pm dump "$ROBLOX_PKG" 2>/dev/null | grep -m1 versionName || true)
  fi
  ver=$(echo "$ver" | sed -n 's/.*versionName=\(.*\)/\1/p' || true)
  ver=$(trim "$ver")
  printf '%s' "$ver"
}

# query WEAO current versions (Android)
get_weao_android_version() {
  local resp
  resp=$(curl -s -H "User-Agent: $WEAO_UA" "https://weao.xyz/api/versions/current")
  if [ -z "$resp" ]; then
    echo ""
    return
  fi
  echo "$resp" | jq -r '.Android // empty'
}

# query exploit status for a given exploit
get_exploit_status() {
  local exploit="$1"
  curl -s -H "User-Agent: $WEAO_UA" "https://weao.xyz/api/status/exploits/${exploit}" || echo ""
}

# download and install Delta APK for a given version string
download_and_install_delta() {
  local version="$1"
  local url="https://delta.filenetwork.vip/file/Delta-${version}.apk"
  local out="${DL_DIR}/Delta-${version}.apk"
  ui_update "Preparing to download Delta-${version}.apk"
  mkdir -p "$DL_DIR"
  force_stop_roblox
  ui_update "Downloading Delta APK..."
  curl -L -A "$WEAO_UA" -o "$out" "$url" || {
    ui_update "Delta download failed."
    return 1
  }
  ui_update "Installing Delta APK..."
  if command -v pm >/dev/null 2>&1; then
    pm install -r "$out" >/dev/null 2>&1 || {
      ui_update "pm install failed. APK at: $out"
      return 1
    }
    ui_update "Delta installed successfully."
    return 0
  else
    ui_update "pm not found. APK at: $out"
    return 1
  fi
}

# check presence for a list of user IDs (CSV)
# returns 0 if ANY user is online, 1 if ALL offline
check_presence_any_online() {
  local ids_csv="$1"
  local url="https://presence.roblox.com/v1/presence/users?userIds=${ids_csv}"
  local resp
  resp=$(curl -s -H "Accept: application/json" "$url" || echo "")
  if [ -z "$resp" ]; then
    ui_update "Presence API empty response — treating as offline"
    return 1
  fi
  local any_online
  any_online=$(echo "$resp" | jq -r '.userPresences[]?.userPresenceType // 0' | awk '{ if ($1 != 0) {print "1"; exit} }' || true)
  if [ "$any_online" = "1" ]; then
    return 0
  fi
  return 1
}

# Fetch Roblox username for a user id and cache it
fetch_username_for_id() {
  local uid="$1"
  local resp
  resp=$(curl -s "https://users.roblox.com/v1/users/${uid}" || echo "")
  if [ -z "$resp" ]; then
    USERNAMES[$uid]="unknown"
    return
  fi
  local name
  name=$(echo "$resp" | jq -r '.name // empty' || echo "")
  if [ -z "$name" ]; then
    USERNAMES[$uid]="unknown"
  else
    USERNAMES[$uid]="$name"
  fi
}

# ----------------- MAIN INTERACTIVE SETUP -----------------
# Arrays to hold users
declare -a USER_IDS=()
declare -A USERNAMES=()
links=()

ui_update "Welcome — configuration"

# Multiple accounts?
if prompt_yesno "Are there multiple accounts to monitor?"; then
  read -rp "Enter user IDs for all accounts (separated by spaces or commas): " user_input
  user_input=$(echo "$user_input" | tr ',' ' ')
  read -r -a tmp_arr <<< "$user_input"
  for id in "${tmp_arr[@]}"; do
    id=$(trim "$id")
    [ -n "$id" ] && USER_IDS+=("$id")
  done
else
  read -rp "Enter the single user ID: " single_id
  single_id=$(trim "$single_id")
  USER_IDS+=("$single_id")
fi

# Build CSV for presence API
user_ids_csv=$(printf "%s," "${USER_IDS[@]}")
user_ids_csv=${user_ids_csv%,}

# Game id or private server link
read -rp "Enter GAME ID or a Private Server link (paste exactly): " game_or_link
game_or_link=$(trim "$game_or_link")

is_numeric='^[0-9]+$'
if [[ $game_or_link =~ $is_numeric ]]; then
  GAMEID="$game_or_link"
  build_links_from_gameid "$GAMEID"
else
  # if a full private server link is provided, use as-is as primary, still add /games/start fallback if user embedded a numeric placeId param
  links=("$game_or_link")
  place=$(echo "$game_or_link" | sed -n 's/.*placeId=\([0-9]\+\).*/\1/p' || true)
  if [ -n "$place" ]; then
    build_links_from_gameid "$place"
  fi
fi

# Prompt for cooldown values (allow default)
read -rp "App warmup cooldown after launching app before opening link (seconds) [${DEFAULT_APP_WARMUP}]: " input
input=$(trim "$input")
if [[ -z "$input" ]]; then
  APP_WARMUP=${DEFAULT_APP_WARMUP}
else
  APP_WARMUP="$input"
fi

read -rp "Cooldown between intent open attempts (seconds) [${DEFAULT_LINK_COOLDOWN}]: " input
input=$(trim "$input")
if [[ -z "$input" ]]; then
  LINK_COOLDOWN=${DEFAULT_LINK_COOLDOWN}
else
  LINK_COOLDOWN="$input"
fi

read -rp "Join wait after opening join link (seconds) [${DEFAULT_JOIN_WAIT}]: " input
input=$(trim "$input")
if [[ -z "$input" ]]; then
  JOIN_WAIT=${DEFAULT_JOIN_WAIT}
else
  JOIN_WAIT="$input"
fi

# Restart interval minutes (integer)
while true; do
  read -rp "Enter restart interval for Roblox app (minutes, integer, 0=disabled): " restart_minutes
  restart_minutes=$(trim "$restart_minutes")
  if [[ "$restart_minutes" =~ ^[0-9]+$ ]] && [ "$restart_minutes" -ge 0 ]; then
    break
  fi
  echo "Please enter a non-negative integer."
done
restart_interval_seconds=$((restart_minutes * 60))

# Ask whether to enable automatic executor (Delta) updates
if prompt_yesno "Enable auto-check and install of Delta executor APK when Roblox Android version updates?"; then
  enable_delta_update=1
else
  enable_delta_update=0
fi

# Fetch usernames (best-effort) for UI display
ui_update "Fetching usernames..."
for id in "${USER_IDS[@]}"; do
  fetch_username_for_id "$id" &
  # small spacing between username fetches to be gentle
  sleep 0.15
done
wait

# Show a final config summary in the UI then wait 2 seconds before starting loop
ui_update "Configuration loaded — starting in 2s"
sleep 2

# runtime variable
last_restart_ts=$(date +%s)

# function to attempt to open the game using the cooldown flow:
# 1) Launch app (warmup)
# 2) Wait APP_WARMUP
# 3) Open join links in sequence with LINK_COOLDOWN between attempts
open_game_cooldown_flow() {
  launch_roblox_app
  sleep "$APP_WARMUP"

  ui_update "Opening join link(s) in Roblox app..."
  for l in "${links[@]}"; do
    open_in_roblox "$l"
    sleep "$LINK_COOLDOWN"
  done
  ui_update "Waiting ${JOIN_WAIT}s to allow time to join..."
  sleep "$JOIN_WAIT"
}

# Trap CTRL+C to clear screen and exit gracefully
trap 'printf "\033c"; echo "Stopped by user."; exit 0' INT TERM

# ----------------- MAIN LOOP -----------------
ui_update "Starting reconnect loop"
sleep 1

while true; do
  # Open game with cooldown flow
  open_game_cooldown_flow

  # Optional: Delta auto-update checks
  if [ "${enable_delta_update:-0}" -eq 1 ]; then
    ui_update "Checking WEAO for current Roblox Android version..."
    weao_android_ver=$(get_weao_android_version || echo "")
    if [ -n "$weao_android_ver" ]; then
      installed_ver=$(get_installed_roblox_version || echo "")
      ui_update "WEAO Android latest: ${weao_android_ver} — Installed: ${installed_ver:-unknown}"
      if [ -z "$installed_ver" ] || [ "$installed_ver" != "$weao_android_ver" ]; then
        ui_update "Installed Roblox differs from WEAO latest. Checking Delta exploit status..."
        explo=$(get_exploit_status "delta")
        if [ -n "$explo" ]; then
          rbxver=$(echo "$explo" | jq -r '.rbxversion // empty' || echo "")
          explo_version_field=$(echo "$explo" | jq -r '.version // empty' || echo "")
          ui_update "Delta status: rbxversion='${rbxver}' version='${explo_version_field}'"
          matched=0
          if [ -n "$rbxver" ] && [[ "$rbxver" == *"$weao_android_ver"* ]]; then
            matched=1
          fi
          if [ "$matched" -eq 0 ]; then
            if echo "$explo" | grep -q "$weao_android_ver"; then
              matched=1
            fi
          fi
          if [ "$matched" -eq 1 ]; then
            download_and_install_delta "$weao_android_ver" || ui_update "Delta download/install failed."
          else
            ui_update "Delta does not report support for the WEAO Android version. Skipping auto-download."
            sleep 2
          fi
        else
          ui_update "Could not retrieve Delta exploit status from WEAO."
          sleep 2
        fi
      else
        ui_update "Installed Roblox already matches WEAO current Android version. No Delta update required."
        sleep 1
      fi
    else
      ui_update "Could not get WEAO Android version. Skipping Delta checks."
      sleep 1
    fi
  fi

  # Monitoring loop: presence checks and scheduled restart handling
  while true; do
    now_ts=$(date +%s)
    elapsed=$((now_ts - last_restart_ts))

    # If restart interval configured and exceeded, fully restart Roblox
    if [ "$restart_interval_seconds" -gt 0 ] && [ "$elapsed" -ge "$restart_interval_seconds" ]; then
      ui_update "Restart interval reached (${restart_minutes} min) — restarting Roblox app..."
      force_stop_roblox
      sleep 1
      open_game_cooldown_flow
      last_restart_ts=$(date +%s)
      continue
    fi

    ui_update "Checking presence for users..."
    if check_presence_any_online "${user_ids_csv}"; then
      ui_update "User(s) online — rechecking in 30s"
      sleep 30
    else
      ui_update "Users offline — restarting Roblox and attempting to reopen game..."
      force_stop_roblox
      sleep 1
      open_game_cooldown_flow
      last_restart_ts=$(date +%s)
    fi

    sleep "$SLEEP_SHORT"
  done
done
