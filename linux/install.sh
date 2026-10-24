#!/usr/bin/env bash
set -u
set -o pipefail

APP_NAME="Horizon AI"
APP_TAGLINE="Multi-Agent Glassbox Refactoring Studio"
MIN_VRAM_MB=4096
DEFAULT_DOCKER="docker"
DEFAULT_NVIDIA_SMI="nvidia-smi"
BACKEND_IMAGE_GPU="ghcr.io/horizon-ai-code/horizon-backend:latest"
BACKEND_IMAGE_CPU="ghcr.io/horizon-ai-code/horizon-backend:cpu"
FRONTEND_IMAGE_DEFAULT="ghcr.io/horizon-ai-code/horizon-frontend:latest"
NETWORK_NAME="horizon_default"
CONTAINER_BACKEND="horizon-backend"
CONTAINER_FRONTEND="horizon-frontend"
VOLUME_NAME="horizon_data"

MODE="auto"
YES=0
DRY_RUN=0
NO_OPEN=0
NO_COLOR_FLAG=0
NO_TUI=0
NO_ANIMATION=0
FORCE_GPU=0
HORIZON_HOME="${HORIZON_HOME:-}"
HORIZON_DOCKER="${HORIZON_DOCKER:-$DEFAULT_DOCKER}"
HORIZON_NVIDIA_SMI="${HORIZON_NVIDIA_SMI:-$DEFAULT_NVIDIA_SMI}"

OS_NAME=""
IS_MACOS=0
IS_WSL=0
BACKEND_IMAGE=""
FRONTEND_IMAGE=""
LOG_FILE=""
HTTP_TOOL=""
BROWSE_AVAILABLE=0
EXISTING_CONTAINERS=""

DOCKER_BIN=""
DOCKER_OK=0
DOCKER_STATE="missing"
DOCKER_VERSION=""
DOCKER_DETAIL=""

GPU_PRESENT=0
GPU_NAME=""
GPU_VRAM_MB=0
GPU_LIST=""
GPU_RUNTIME_OK=0
GPU_RUNTIME_DETAIL=""
GPU_AVAILABLE=0
GPU_REASON=""
RECOMMENDED_MODE="cpu"
FORCE_GPU_WARNING=0

TUI_ACTIVE=0
TTY_FD=""
SAVED_STTY=""
WIDTH=80
HEIGHT=24
COLOR_MODE="none"
UNICODE=0
BODY=()
CARD=()
SPINNER_INDEX=0
CHILD_PID=""
INSTALL_ERROR=""
FAILED_STEP=""
CURRENT_MODE_INDEX=0
CURRENT_MENU_INDEX=0
SUCCESS_MENU_INDEX=0
STEP_PULL=0
STEP_RESOURCES=0
STEP_START=0
STEP_HEALTH=0

FG_TEXT=""
FG_MUTED=""
FG_BLUE=""
FG_CYAN=""
FG_GREEN=""
FG_AMBER=""
FG_RED=""
FG_WHITE=""
FG_BORDER=""
BG_MAIN=""
BG_PANEL=""
BG_BLUE=""
BOLD=""
BOLD_OFF=""
FG_RESET=""
ALL_RESET=""
SYM_OK=""
SYM_WARN=""
SYM_FAIL=""
SYM_DOT=""
SYM_CIRCLE=""
SYM_ARROW=""
SYM_GPU=""
SYM_CPU=""
SYM_H=""
SYM_V=""
BOX_TL=""
BOX_TR=""
BOX_BL=""
BOX_BR=""
BOX_H=""
BOX_V=""
KEY_UP_DOWN=""
SPINNER=()

usage() {
  cat <<'USAGE'
Usage: install.sh [options]

Options:
  --mode auto|cpu|gpu   Select the runtime mode
  --cpu                 Shortcut for --mode cpu
  --gpu                 Shortcut for --mode gpu
  --yes                 Skip confirmation prompts
  --dry-run             Run checks and print the plan without installing
  --no-open             Do not open the browser after installation
  --no-color            Disable ANSI colors
  --no-tui              Use plain terminal prompts
  --no-animation        Disable spinner animation
  --force-gpu           Allow GPU mode below the 4 GB recommendation
  --help                Show this help

Requirements:
  Docker Engine or Docker Desktop must be installed and running with Linux containers.
  Internet access is required for the first install; images are pulled from GHCR.

Environment:
  HORIZON_HOME          Install log directory
USAGE
}

die() {
  printf '%s\n' "$1" >&2
  exit "${2:-1}"
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

detect_os() {
  OS_NAME="$(uname -s 2>/dev/null || printf 'unknown')"
  if [ "$OS_NAME" = "Darwin" ]; then
    IS_MACOS=1
  fi
  if [ -r /proc/version ] && grep -qi microsoft /proc/version 2>/dev/null; then
    IS_WSL=1
  fi
}

set_default_home() {
  if [ -n "$HORIZON_HOME" ]; then
    return
  fi
  if [ "$IS_MACOS" -eq 1 ]; then
    HORIZON_HOME="$HOME/Library/Application Support/Horizon"
  else
    HORIZON_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/horizon"
  fi
}

visible_width() {
  local text="$1"
  local esc
  esc="$(printf '\033')"
  printf '%s' "$text" | sed "s/${esc}\\[[0-9;]*m//g" | wc -m | tr -d '[:space:]'
}

fit_plain() {
  local text="$1"
  local max="$2"
  local width
  width="$(printf '%s' "$text" | wc -m | tr -d '[:space:]')"
  if [ "$width" -gt "$max" ]; then
    printf '%s' "${text:0:$max}"
  else
    printf '%s' "$text"
  fi
}

pad_plain() {
  local text="$1"
  local width="$2"
  local current
  local padding
  current="$(printf '%s' "$text" | wc -m | tr -d '[:space:]')"
  if [ "$current" -gt "$width" ]; then
    text="${text:0:$width}"
    current="$width"
  fi
  padding=$((width - current))
  printf '%s' "$text"
  if [ "$padding" -gt 0 ]; then
    printf '%*s' "$padding" ''
  fi
}

repeat_char() {
  local char="$1"
  local count="$2"
  local out=""
  local i=0
  while [ "$i" -lt "$count" ]; do
    out="${out}${char}"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

set_symbols() {
  if [ "$UNICODE" -eq 1 ]; then
    SYM_OK="✓"
    SYM_WARN="!"
    SYM_FAIL="×"
    SYM_DOT="●"
    SYM_CIRCLE="○"
    SYM_ARROW="▸"
    SYM_GPU="◈"
    SYM_CPU="▤"
    SYM_H="━"
    SYM_V="┃"
    BOX_TL="╭"
    BOX_TR="╮"
    BOX_BL="╰"
    BOX_BR="╯"
    BOX_H="─"
    BOX_V="│"
    KEY_UP_DOWN="↑↓"
    SPINNER=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  else
    SYM_OK="[OK]"
    SYM_WARN="[!]"
    SYM_FAIL="[X]"
    SYM_DOT="*"
    SYM_CIRCLE="o"
    SYM_ARROW=">"
    SYM_GPU="[G]"
    SYM_CPU="[C]"
    SYM_H="="
    SYM_V="|"
    BOX_TL="+"
    BOX_TR="+"
    BOX_BL="+"
    BOX_BR="+"
    BOX_H="-"
    BOX_V="|"
    KEY_UP_DOWN="Up/Down"
    SPINNER=("|" "/" "-" "\\")
  fi
}

set_colors() {
  FG_TEXT=""
  FG_MUTED=""
  FG_BLUE=""
  FG_CYAN=""
  FG_GREEN=""
  FG_AMBER=""
  FG_RED=""
  FG_WHITE=""
  FG_BORDER=""
  BG_MAIN=""
  BG_PANEL=""
  BG_BLUE=""
  BOLD=""
  BOLD_OFF=""
  FG_RESET=""
  ALL_RESET=""

  case "$COLOR_MODE" in
    truecolor)
      FG_TEXT=$'\033[38;2;223;225;229m'
      FG_MUTED=$'\033[38;2;111;115;122m'
      FG_BLUE=$'\033[38;2;84;138;247m'
      FG_CYAN=$'\033[38;2;61;214;200m'
      FG_GREEN=$'\033[38;2;97;197;84m'
      FG_AMBER=$'\033[38;2;244;191;79m'
      FG_RED=$'\033[38;2;249;62;62m'
      FG_WHITE=$'\033[38;2;255;255;255m'
      FG_BORDER=$'\033[38;2;57;59;64m'
      BG_MAIN=$'\033[48;2;30;31;34m'
      BG_PANEL=$'\033[48;2;43;45;48m'
      BG_BLUE=$'\033[48;2;84;138;247m'
      BOLD=$'\033[1m'
      BOLD_OFF=$'\033[22m'
      FG_RESET=$'\033[39m'
      ALL_RESET=$'\033[0m'
      ;;
    256)
      FG_TEXT=$'\033[38;5;253m'
      FG_MUTED=$'\033[38;5;243m'
      FG_BLUE=$'\033[38;5;69m'
      FG_CYAN=$'\033[38;5;80m'
      FG_GREEN=$'\033[38;5;77m'
      FG_AMBER=$'\033[38;5;221m'
      FG_RED=$'\033[38;5;203m'
      FG_WHITE=$'\033[38;5;231m'
      FG_BORDER=$'\033[38;5;238m'
      BG_MAIN=$'\033[48;5;234m'
      BG_PANEL=$'\033[48;5;236m'
      BG_BLUE=$'\033[48;5;69m'
      BOLD=$'\033[1m'
      BOLD_OFF=$'\033[22m'
      FG_RESET=$'\033[39m'
      ALL_RESET=$'\033[0m'
      ;;
    16)
      FG_TEXT=$'\033[37m'
      FG_MUTED=$'\033[90m'
      FG_BLUE=$'\033[94m'
      FG_CYAN=$'\033[96m'
      FG_GREEN=$'\033[92m'
      FG_AMBER=$'\033[93m'
      FG_RED=$'\033[91m'
      FG_WHITE=$'\033[97m'
      FG_BORDER=$'\033[90m'
      BG_MAIN=""
      BG_PANEL=""
      BG_BLUE=$'\033[44m'
      BOLD=$'\033[1m'
      BOLD_OFF=$'\033[22m'
      FG_RESET=$'\033[39m'
      ALL_RESET=$'\033[0m'
      ;;
  esac
}

detect_terminal_caps() {
  if [ "$NO_COLOR_FLAG" -eq 1 ] || [ -n "${NO_COLOR:-}" ] || [ "${TERM:-}" = "dumb" ]; then
    COLOR_MODE="none"
  elif [ "${COLORTERM:-}" = "truecolor" ] || [ "${COLORTERM:-}" = "24bit" ] || [ -n "${WT_SESSION:-}" ] || [ "${TERM_PROGRAM:-}" = "WezTerm" ] || [ "${TERM_PROGRAM:-}" = "iTerm.app" ]; then
    COLOR_MODE="truecolor"
  else
    local colors
    colors="$(tput colors 2>/dev/null || printf '0')"
    if [ "${colors:-0}" -ge 256 ] 2>/dev/null; then
      COLOR_MODE="256"
    elif [ "${colors:-0}" -ge 8 ] 2>/dev/null; then
      COLOR_MODE="16"
    else
      COLOR_MODE="none"
    fi
  fi

  set_colors

  UNICODE=0
  if locale charmap 2>/dev/null | grep -qi 'utf-8'; then
    UNICODE=1
  elif printf '%s' "${LC_ALL:-${LANG:-}}" | grep -qi 'utf-8'; then
    UNICODE=1
  fi
  set_symbols
}

terminal_size() {
  local cols
  local lines
  cols="$(tput cols 2>/dev/null || true)"
  lines="$(tput lines 2>/dev/null || true)"
  case "$cols" in
    ''|*[!0-9]*) cols=80 ;;
  esac
  case "$lines" in
    ''|*[!0-9]*) lines=24 ;;
  esac
  WIDTH="$cols"
  HEIGHT="$lines"
  if [ "$WIDTH" -lt 60 ] || [ "$HEIGHT" -lt 18 ]; then
    NO_TUI=1
  fi
}

clear_screen() {
  if [ "$COLOR_MODE" = "none" ]; then
    printf '\033[2J\033[H'
  else
    printf '%s\033[2J\033[H' "$BG_MAIN"
  fi
}

cleanup() {
  if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
    kill "$CHILD_PID" 2>/dev/null || true
  fi
  if [ "$TUI_ACTIVE" -eq 1 ]; then
    printf '\033[?25h\033[?1049l'
    if [ -n "$SAVED_STTY" ] && [ -n "$TTY_FD" ]; then
      stty "$SAVED_STTY" <&"$TTY_FD" 2>/dev/null || true
    fi
    if [ "$TTY_FD" = "3" ]; then
      exec 3>&- 2>/dev/null || true
    fi
    TUI_ACTIVE=0
  fi
}

init_tui() {
  if [ "$NO_TUI" -eq 1 ] || [ ! -t 1 ]; then
    TUI_ACTIVE=0
    return
  fi
  if [ -t 0 ]; then
    TTY_FD=0
  elif exec 3<>/dev/tty 2>/dev/null; then
    TTY_FD=3
  else
    TUI_ACTIVE=0
    return
  fi
  SAVED_STTY="$(stty -g <&"$TTY_FD" 2>/dev/null || true)"
  if [ -z "$SAVED_STTY" ]; then
    TUI_ACTIVE=0
    return
  fi
  stty -echo -icanon min 1 time 0 <&"$TTY_FD" 2>/dev/null || true
  TUI_ACTIVE=1
  printf '\033]0;Horizon AI Setup\007'
  printf '\033[?1049h\033[?25l'
  clear_screen
}

read_key() {
  if [ -z "$TTY_FD" ]; then
    return 1
  fi
  local key
  local seq
  IFS= read -rsn1 -u "$TTY_FD" key || return 1
  if [ "$key" = $'\033' ]; then
    IFS= read -rsn2 -u "$TTY_FD" seq || seq=""
    case "$seq" in
      "[A") printf 'UP' ;;
      "[B") printf 'DOWN' ;;
      "[C") printf 'RIGHT' ;;
      "[D") printf 'LEFT' ;;
      *) printf 'ESC' ;;
    esac
    return 0
  fi
  if [ -z "$key" ] || [ "$key" = $'\r' ] || [ "$key" = $'\n' ]; then
    printf 'ENTER'
  else
    printf '%s' "$key"
  fi
}

paint_line() {
  local line="${1:-}"
  local width
  local padding
  width="$(visible_width "$line")"
  if [ "$width" -gt "$WIDTH" ]; then
    printf '%s%s%s\n' "$BG_MAIN" "$line" "$ALL_RESET"
    return
  fi
  padding=$((WIDTH - width))
  printf '%s%s%s' "$BG_MAIN" "$line" "$BG_MAIN"
  if [ "$padding" -gt 0 ]; then
    printf '%*s' "$padding" ''
  fi
  printf '%s\n' "$ALL_RESET"
}

draw_horizon_line() {
  local left
  local right
  left=$((WIDTH / 2))
  right=$((WIDTH - left))
  paint_line "${FG_BLUE}$(repeat_char "$SYM_H" "$left")${FG_CYAN}$(repeat_char "$SYM_H" "$right")${FG_RESET}"
}

draw_header() {
  local mark1
  local mark2
  local mark3
  local word
  local tagline
  local status
  local left
  local right
  local left_width
  local right_width
  local spaces

  mark1="${FG_BLUE}${SYM_V}${FG_RESET}   ${FG_BLUE}${SYM_V}${FG_RESET}"
  mark2="${FG_BLUE}${SYM_V}${FG_CYAN}${SYM_H}${SYM_H}${SYM_H}${FG_BLUE}${SYM_V}${FG_RESET}"
  mark3="${FG_BLUE}${SYM_V}${FG_RESET}   ${FG_BLUE}${SYM_V}${FG_RESET}"
  word="${BOLD}${FG_TEXT}Horizon${FG_RESET}${BOLD_OFF} ${BOLD}${FG_CYAN}AI${FG_RESET}${BOLD_OFF}"
  tagline="${FG_MUTED}${APP_TAGLINE}${FG_RESET}"
  status="${FG_GREEN}${SYM_DOT}${FG_RESET} ${FG_MUTED}LOCAL${FG_RESET}"
  left="  ${mark1}  ${word}"
  right="$status"
  left_width="$(visible_width "$left")"
  right_width="$(visible_width "$right")"
  spaces=$((WIDTH - left_width - right_width - 2))
  if [ "$spaces" -lt 1 ]; then
    spaces=1
  fi
  paint_line "${BG_PANEL}${left}$(repeat_char ' ' "$spaces")${right}"
  paint_line "${BG_PANEL}  ${mark2}  ${tagline}"
  paint_line "${BG_PANEL}  ${mark3}"
  draw_horizon_line
}

draw_steps() {
  local current="$1"
  local labels=("SYSTEM" "MODE" "INSTALL" "READY")
  local line=""
  local i
  local symbol
  local color
  local label
  for i in 0 1 2 3; do
    if [ "$i" -lt "$current" ]; then
      symbol="$SYM_OK"
      color="$FG_GREEN"
    elif [ "$i" -eq "$current" ]; then
      symbol="$SYM_DOT"
      color="$FG_CYAN"
    else
      symbol="$SYM_CIRCLE"
      color="$FG_MUTED"
    fi
    label="0$((i + 1)) ${labels[$i]}"
    line="${line}${color}${symbol}${FG_RESET} ${FG_MUTED}${label}${FG_RESET}"
    if [ "$i" -lt 3 ]; then
      line="${line}  ${FG_BORDER}──${FG_RESET}  "
    fi
  done
  paint_line "$line"
}

draw_footer() {
  local hints="$1"
  paint_line "${FG_BORDER}$(repeat_char "$SYM_H" "$WIDTH")${FG_RESET}"
  paint_line "${FG_MUTED}${hints}${FG_RESET}"
}

draw_frame() {
  local current="$1"
  local title="$2"
  local subtitle="$3"
  local footer="$4"
  local i
  printf '\033[H'
  draw_header
  draw_steps "$current"
  paint_line ""
  if [ -n "$title" ]; then
    paint_line "${BOLD}${FG_TEXT}${title}${FG_RESET}${BOLD_OFF}"
  fi
  if [ -n "$subtitle" ]; then
    paint_line "${FG_MUTED}${subtitle}${FG_RESET}"
  fi
  paint_line ""
  for i in "${!BODY[@]}"; do
    paint_line "${BODY[$i]}"
  done
  paint_line ""
  draw_footer "$footer"
  printf '\033[J'
}

spinner_char() {
  local count
  if [ "$NO_ANIMATION" -eq 1 ]; then
    printf '%s' "$SYM_CIRCLE"
    return
  fi
  count=${#SPINNER[@]}
  if [ "$count" -eq 0 ]; then
    printf '%s' "$SYM_CIRCLE"
    return
  fi
  printf '%s' "${SPINNER[$((SPINNER_INDEX % count))]}"
  SPINNER_INDEX=$((SPINNER_INDEX + 1))
}

status_row() {
  local label="$1"
  local value="$2"
  local detail="$3"
  local state="$4"
  local symbol
  local color
  local detail_width
  case "$state" in
    ok)
      symbol="$SYM_OK"
      color="$FG_GREEN"
      ;;
    warn)
      symbol="$SYM_WARN"
      color="$FG_AMBER"
      ;;
    fail)
      symbol="$SYM_FAIL"
      color="$FG_RED"
      ;;
    *)
      symbol="$SYM_CIRCLE"
      color="$FG_MUTED"
      ;;
  esac
  detail_width=$((WIDTH - 44))
  if [ "$detail_width" -lt 8 ]; then
    detail_width=8
  fi
  printf '%s%s%s  %-20s %-16s %s%s%s' "$color" "$symbol" "$FG_RESET" "$label" "$value" "$FG_MUTED" "$(fit_plain "$detail" "$detail_width")" "$FG_RESET"
}

card_top() {
  local width="$1"
  local border="$2"
  printf '%s%s%s%s%s%s' "$BG_PANEL" "$border" "$BOX_TL" "$(repeat_char "$BOX_H" $((width - 2)))" "$BOX_TR" "$ALL_RESET"
}

card_bottom() {
  local width="$1"
  local border="$2"
  printf '%s%s%s%s%s%s' "$BG_PANEL" "$border" "$BOX_BL" "$(repeat_char "$BOX_H" $((width - 2)))" "$BOX_BR" "$ALL_RESET"
}

card_mid() {
  local width="$1"
  local border="$2"
  local content="$3"
  local text_color="$4"
  local inner
  local padded
  inner=$((width - 4))
  padded="$(pad_plain "$content" "$inner")"
  printf '%s%s%s %s%s%s %s%s' "$BG_PANEL" "$border" "$BOX_V" "$text_color" "$padded" "$border" "$BOX_V" "$ALL_RESET"
}

build_card() {
  local width="$1"
  local border="$2"
  local title="$3"
  local subtitle="$4"
  local line_one="$5"
  local line_two="$6"
  local badge="$7"
  local badge_color="$8"
  local text_color="$9"
  CARD=()
  CARD+=("$(card_top "$width" "$border")")
  CARD+=("$(card_mid "$width" "$border" "$title" "$text_color")")
  CARD+=("$(card_mid "$width" "$border" "$subtitle" "$FG_MUTED")")
  CARD+=("$(card_mid "$width" "$border" "" "$text_color")")
  CARD+=("$(card_mid "$width" "$border" "$line_one" "$text_color")")
  CARD+=("$(card_mid "$width" "$border" "$line_two" "$FG_MUTED")")
  CARD+=("$(card_mid "$width" "$border" "$badge" "$badge_color")")
  CARD+=("$(card_bottom "$width" "$border")")
}

menu_line() {
  local label="$1"
  local selected="$2"
  local text
  if [ "$selected" -eq 1 ]; then
    text="  ${SYM_ARROW} ${label}"
    printf '%s%s%s%s' "$BG_BLUE" "$FG_WHITE" "$(pad_plain "$text" "$WIDTH")" "$ALL_RESET"
  else
    printf '%s  %s %s%s' "$BG_MAIN" " " "$label" "$ALL_RESET"
  fi
}

kv_line() {
  local key="$1"
  local value="$2"
  printf '%s%-12s%s%s%s' "$FG_MUTED" "$key" "$FG_RESET" "$value" "$FG_RESET"
}

progress_bar() {
  local done="$1"
  local total="$2"
  local width="$3"
  local fill
  local empty
  fill=$((width * done / total))
  empty=$((width - fill))
  if [ "$fill" -lt 0 ]; then fill=0; fi
  if [ "$empty" -lt 0 ]; then empty=0; fi
  printf '%s%s%s%s%s' "$FG_BLUE" "$(repeat_char "$SYM_H" "$fill")" "$FG_BORDER" "$(repeat_char "$SYM_H" "$empty")" "$FG_RESET"
}

step_row() {
  local state="$1"
  local label="$2"
  local detail="$3"
  local symbol
  local color
  case "$state" in
    done)
      symbol="$SYM_OK"
      color="$FG_GREEN"
      ;;
    active)
      symbol="$(spinner_char)"
      color="$FG_CYAN"
      ;;
    fail)
      symbol="$SYM_FAIL"
      color="$FG_RED"
      ;;
    *)
      symbol="$SYM_CIRCLE"
      color="$FG_MUTED"
      ;;
  esac
  printf '%s%s%s  %s%s%s' "$color" "$symbol" "$FG_RESET" "$FG_TEXT" "$label" "$FG_RESET"
  if [ -n "$detail" ]; then
    printf '  %s%s%s' "$FG_MUTED" "$detail" "$FG_RESET"
  fi
}

log_tail() {
  local count="$1"
  local max_width
  local line
  max_width=$((WIDTH - 6))
  if [ "$max_width" -lt 10 ]; then
    max_width=10
  fi
  if [ -s "$LOG_FILE" ]; then
    tail -n "$count" "$LOG_FILE" | while IFS= read -r line; do
      printf '%s\n' "$(fit_plain "$line" "$max_width")"
    done
  else
    printf '%s\n' "Waiting for output..."
  fi
}

detect_docker() {
  DOCKER_BIN="${HORIZON_DOCKER:-$DEFAULT_DOCKER}"
  DOCKER_OK=0
  DOCKER_STATE="missing"
  DOCKER_VERSION=""
  DOCKER_DETAIL=""

  if [ "$DOCKER_BIN" = "none" ] || ! command_exists "$DOCKER_BIN"; then
    DOCKER_STATE="missing"
    DOCKER_DETAIL="Install Docker Engine or Docker Desktop."
    return
  fi

  local version_raw
  version_raw="$("$DOCKER_BIN" --version 2>/dev/null | head -n 1 || true)"
  if [ -z "$version_raw" ]; then
    DOCKER_STATE="error"
    DOCKER_DETAIL="Docker is installed but not responding."
    return
  fi
  DOCKER_VERSION="$(printf '%s' "$version_raw" | sed -n 's/^Docker version \([^,]*\).*/\1/p')"
  if [ -z "$DOCKER_VERSION" ]; then
    DOCKER_VERSION="$version_raw"
  fi

  local info_output
  local info_rc
  info_output="$("$DOCKER_BIN" info 2>&1)"
  info_rc=$?
  if [ "$info_rc" -ne 0 ]; then
    DOCKER_STATE="down"
    case "$info_output" in
      *"permission denied"*|*"Permission denied"*)
        DOCKER_STATE="permission"
        DOCKER_DETAIL="Add your user to the docker group or run with the right permissions."
        ;;
      *"Cannot connect"*|*"Is the docker daemon running"*|*"is the docker daemon running"*)
        DOCKER_DETAIL="Start Docker Desktop or the Docker daemon, then re-check."
        ;;
      *)
        DOCKER_DETAIL="Docker is installed but the daemon is not reachable."
        ;;
    esac
    return
  fi

  local os_type
  os_type="$("$DOCKER_BIN" info --format '{{.OSType}}' 2>/dev/null | head -n 1 || true)"
  os_type="$(trim "$os_type")"
  if [ -n "$os_type" ] && [ "$os_type" != "linux" ]; then
    DOCKER_STATE="windows-containers"
    DOCKER_OK=0
    DOCKER_DETAIL="Docker Desktop is using Windows containers. Switch to Linux containers."
    return
  fi

  DOCKER_STATE="running"
  DOCKER_OK=1
  DOCKER_DETAIL="linux containers"
}

detect_gpu() {
  GPU_PRESENT=0
  GPU_NAME=""
  GPU_VRAM_MB=0
  GPU_LIST=""
  GPU_RUNTIME_OK=0
  GPU_RUNTIME_DETAIL=""
  GPU_AVAILABLE=0
  GPU_REASON=""

  if [ "$IS_MACOS" -eq 1 ]; then
    GPU_REASON="NVIDIA GPU acceleration is not supported on macOS."
    return
  fi

  local nvidia_bin
  nvidia_bin="${HORIZON_NVIDIA_SMI:-$DEFAULT_NVIDIA_SMI}"
  if [ "$nvidia_bin" = "none" ] || ! command_exists "$nvidia_bin"; then
    GPU_REASON="No NVIDIA GPU detected."
    return
  fi

  local gpu_output
  local gpu_rc
  gpu_output="$("$nvidia_bin" --query-gpu=name,memory.total --format=csv,noheader,nounits 2>/dev/null)"
  gpu_rc=$?
  if [ "$gpu_rc" -ne 0 ] || [ -z "$gpu_output" ]; then
    if command_exists lspci && lspci 2>/dev/null | grep -qi nvidia; then
      GPU_PRESENT=1
      GPU_NAME="NVIDIA GPU"
      GPU_VRAM_MB=0
      GPU_LIST="NVIDIA GPU (VRAM unavailable)"
      GPU_REASON="NVIDIA GPU detected, but VRAM could not be read."
    else
      GPU_REASON="No NVIDIA GPU detected."
    fi
    return
  fi

  local line
  local name
  local memory
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    name="$(trim "${line%%,*}")"
    memory="$(trim "${line##*,}")"
    case "$memory" in
      ''|*[!0-9]*) continue ;;
    esac
    GPU_PRESENT=1
    if [ -n "$GPU_LIST" ]; then
      GPU_LIST="${GPU_LIST}, "
    fi
    GPU_LIST="${GPU_LIST}${name} (${memory} MB)"
    if [ "$memory" -gt "$GPU_VRAM_MB" ]; then
      GPU_VRAM_MB="$memory"
      GPU_NAME="$name"
    fi
  done <<< "$gpu_output"

  if [ "$GPU_PRESENT" -eq 0 ]; then
    GPU_REASON="No NVIDIA GPU detected."
    return
  fi

  if [ "$DOCKER_OK" -eq 1 ]; then
    local runtimes
    runtimes="$("$DOCKER_BIN" info --format '{{json .Runtimes}}' 2>/dev/null || true)"
    if printf '%s' "$runtimes" | grep -q '"nvidia"'; then
      GPU_RUNTIME_OK=1
      GPU_RUNTIME_DETAIL="nvidia"
    else
      GPU_RUNTIME_OK=0
      GPU_RUNTIME_DETAIL="missing"
    fi
  else
    GPU_RUNTIME_DETAIL="Docker is not running"
  fi

  if [ "$GPU_VRAM_MB" -lt "$MIN_VRAM_MB" ]; then
    GPU_REASON="GPU has ${GPU_VRAM_MB} MB VRAM; ${MIN_VRAM_MB} MB minimum."
  elif [ "$GPU_RUNTIME_OK" -eq 0 ]; then
    GPU_REASON="NVIDIA Container Toolkit is required for GPU mode."
  else
    GPU_REASON="GPU acceleration is ready."
    GPU_AVAILABLE=1
  fi
}

evaluate_recommendation() {
  if [ "$GPU_AVAILABLE" -eq 1 ]; then
    RECOMMENDED_MODE="gpu"
  else
    RECOMMENDED_MODE="cpu"
  fi
}

validate_mode() {
  if [ "$MODE" = "auto" ]; then
    MODE="$RECOMMENDED_MODE"
  fi
  if [ "$MODE" = "cpu" ]; then
    return 0
  fi
  if [ "$MODE" = "gpu" ]; then
    if [ "$GPU_PRESENT" -eq 0 ]; then
      printf '%s\n' "No NVIDIA GPU detected. CPU mode works on this machine." >&2
      return 4
    fi
    if [ "$GPU_VRAM_MB" -lt "$MIN_VRAM_MB" ] && [ "$FORCE_GPU" -eq 0 ]; then
      printf '%s\n' "GPU has ${GPU_VRAM_MB} MB VRAM; ${MIN_VRAM_MB} MB minimum. Use --force-gpu to override." >&2
      return 4
    fi
    if [ "$GPU_RUNTIME_OK" -eq 0 ]; then
      printf '%s\n' "NVIDIA Container Toolkit is required for GPU mode." >&2
      return 4
    fi
    if [ "$GPU_VRAM_MB" -lt "$MIN_VRAM_MB" ] && [ "$FORCE_GPU" -eq 1 ]; then
      FORCE_GPU_WARNING=1
    fi
    return 0
  fi
  printf '%s\n' "Unknown mode: $MODE" >&2
  return 2
}

run_preflight() {
  detect_docker
  detect_gpu
  evaluate_recommendation

  if command_exists curl; then
    HTTP_TOOL="curl"
  elif command_exists wget; then
    HTTP_TOOL="wget"
  else
    HTTP_TOOL="none"
  fi

  BROWSE_AVAILABLE=0
  if [ "$NO_OPEN" -eq 0 ]; then
    if [ "$IS_MACOS" -eq 1 ] && command_exists open; then
      BROWSE_AVAILABLE=1
    elif [ "$IS_WSL" -eq 1 ] && command_exists cmd.exe; then
      BROWSE_AVAILABLE=1
    elif [ -n "${DISPLAY:-}" ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
      if command_exists xdg-open; then
        BROWSE_AVAILABLE=1
      fi
    fi
  fi
}

print_preflight_plain() {
  printf '%s\n' "${APP_NAME} Setup"
  printf '%s\n' "Docker: ${DOCKER_STATE}${DOCKER_VERSION:+ ($DOCKER_VERSION)}"
  if [ "$GPU_PRESENT" -eq 1 ]; then
    printf '%s\n' "NVIDIA GPU: ${GPU_NAME} (${GPU_VRAM_MB} MB VRAM)"
    if [ "$GPU_RUNTIME_OK" -eq 1 ]; then
      printf '%s\n' "GPU container support: ready"
    else
      printf '%s\n' "GPU container support: missing"
    fi
  else
    printf '%s\n' "NVIDIA GPU: none"
    printf '%s\n' "GPU container support: unavailable"
  fi
  printf '%s\n' "Recommended: $(printf '%s' "$RECOMMENDED_MODE" | tr '[:lower:]' '[:upper:]')"
  if [ "$GPU_PRESENT" -eq 1 ] && [ "$GPU_AVAILABLE" -eq 0 ]; then
    printf '%s\n' "GPU mode is unavailable: ${GPU_REASON}"
  fi
}

print_preflight_error() {
  case "$DOCKER_STATE" in
    missing)
      printf '%s\n' "Docker is not installed. Install Docker Engine or Docker Desktop, then re-run."
      ;;
    down)
      printf '%s\n' "Docker is installed but not running. Start Docker Desktop or the Docker daemon, then re-run."
      ;;
    permission)
      printf '%s\n' "Docker is running, but this user cannot access it. Add your user to the docker group or run with the right permissions."
      ;;
    windows-containers)
      printf '%s\n' "Docker Desktop is using Windows containers. Switch it to Linux containers, then re-run."
      ;;
    *)
      printf '%s\n' "Docker is not ready. ${DOCKER_DETAIL}"
      ;;
  esac
}

ensure_directory() {
  mkdir -p "$1" 2>/dev/null || die "Could not create $1" 1
}

resolve_images() {
  if [ "$MODE" = "gpu" ]; then
    BACKEND_IMAGE="$BACKEND_IMAGE_GPU"
  else
    BACKEND_IMAGE="$BACKEND_IMAGE_CPU"
  fi
  FRONTEND_IMAGE="$FRONTEND_IMAGE_DEFAULT"
}

find_volume() {
  local volumes
  local match
  volumes="$("$DOCKER_BIN" volume ls --format '{{.Name}}' 2>/dev/null || true)"
  if printf '%s\n' "$volumes" | grep -qx 'horizon_data'; then
    VOLUME_NAME="horizon_data"
    return
  fi
  if printf '%s\n' "$volumes" | grep -qx 'horizon_horizon_data'; then
    VOLUME_NAME="horizon_horizon_data"
    return
  fi
  match="$(printf '%s\n' "$volumes" | grep -E '(^|_)horizon_data$' | head -n 1 || true)"
  if [ -n "$match" ]; then
    VOLUME_NAME="$match"
  else
    VOLUME_NAME="horizon_data"
  fi
}

detect_existing_state() {
  local names
  names="$("$DOCKER_BIN" ps -a --format '{{.Names}}|{{.Image}}' 2>/dev/null || true)"
  EXISTING_CONTAINERS="$(printf '%s\n' "$names" | awk -F'|' '$1 ~ /^horizon-(backend|frontend)(-1)?$/ || $2 ~ /horizon-(backend|frontend)(:|-)/ { print $1 }' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
  find_volume
}

prepare_state() {
  resolve_images
  detect_existing_state
  LOG_FILE="$HORIZON_HOME/install.log"
  ensure_directory "$HORIZON_HOME"
}

pull_images() {
  "$DOCKER_BIN" pull "$BACKEND_IMAGE" || return 1
  "$DOCKER_BIN" pull "$FRONTEND_IMAGE" || return 1
  return 0
}

prepare_resources() {
  local container
  detect_existing_state
  if [ -n "$EXISTING_CONTAINERS" ]; then
    for container in $EXISTING_CONTAINERS; do
      "$DOCKER_BIN" rm -f "$container" >>"$LOG_FILE" 2>&1 || true
    done
  fi
  if ! "$DOCKER_BIN" network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    "$DOCKER_BIN" network create "$NETWORK_NAME" >>"$LOG_FILE" 2>&1 || return 1
  fi
  if ! "$DOCKER_BIN" volume inspect "$VOLUME_NAME" >/dev/null 2>&1; then
    "$DOCKER_BIN" volume create "$VOLUME_NAME" >>"$LOG_FILE" 2>&1 || return 1
  fi
  return 0
}

start_containers() {
  if [ "$MODE" = "gpu" ]; then
    "$DOCKER_BIN" run -d --name "$CONTAINER_BACKEND" --restart unless-stopped --network "$NETWORK_NAME" -p 8000:8000 -v "${VOLUME_NAME}:/app/db" --gpus all "$BACKEND_IMAGE" >>"$LOG_FILE" 2>&1 || return 1
  else
    "$DOCKER_BIN" run -d --name "$CONTAINER_BACKEND" --restart unless-stopped --network "$NETWORK_NAME" -p 8000:8000 -v "${VOLUME_NAME}:/app/db" "$BACKEND_IMAGE" >>"$LOG_FILE" 2>&1 || return 1
  fi
  "$DOCKER_BIN" run -d --name "$CONTAINER_FRONTEND" --restart unless-stopped --network "$NETWORK_NAME" -p 3000:3000 "$FRONTEND_IMAGE" >>"$LOG_FILE" 2>&1 || return 1
  return 0
}

http_ok() {
  local url="$1"
  if [ "$HTTP_TOOL" = "curl" ]; then
    curl -fsS --max-time 2 "$url" >/dev/null 2>&1
  elif [ "$HTTP_TOOL" = "wget" ]; then
    wget -q -O /dev/null --timeout=2 "$url" >/dev/null 2>&1
  else
    return 0
  fi
}

wait_api() {
  local i=0
  if [ "${HORIZON_SKIP_HEALTH:-0}" = "1" ]; then
    sleep 1
    return 0
  fi
  if [ "$HTTP_TOOL" = "none" ]; then
    sleep 3
    return 0
  fi
  while [ "$i" -lt 90 ]; do
    if http_ok "http://127.0.0.1:8000/health"; then
      return 0
    fi
    if [ "$TUI_ACTIVE" -eq 1 ]; then
      render_progress
    fi
    sleep 2
    i=$((i + 1))
  done
  return 1
}

wait_ui() {
  local i=0
  if [ "${HORIZON_SKIP_HEALTH:-0}" = "1" ]; then
    sleep 1
    return 0
  fi
  if [ "$HTTP_TOOL" = "none" ]; then
    sleep 3
    return 0
  fi
  while [ "$i" -lt 90 ]; do
    if http_ok "http://127.0.0.1:3000"; then
      return 0
    fi
    if [ "$TUI_ACTIVE" -eq 1 ]; then
      render_progress
    fi
    sleep 2
    i=$((i + 1))
  done
  return 1
}

run_with_progress() {
  local step_name="$1"
  shift
  if [ "$TUI_ACTIVE" -eq 0 ]; then
    printf '%s\n' "$step_name"
    "$@" >>"$LOG_FILE" 2>&1
    return $?
  fi
  "$@" >>"$LOG_FILE" 2>&1 &
  CHILD_PID=$!
  while kill -0 "$CHILD_PID" 2>/dev/null; do
    render_progress
    sleep 0.2
  done
  wait "$CHILD_PID"
  local rc=$?
  CHILD_PID=""
  return "$rc"
}

run_install() {
  STEP_PULL=1
  STEP_RESOURCES=0
  STEP_START=0
  STEP_HEALTH=0
  INSTALL_ERROR=""
  FAILED_STEP=""
  ensure_directory "$HORIZON_HOME"
  : > "$LOG_FILE"

  if ! run_with_progress "Pulling prebuilt images..." pull_images; then
    STEP_PULL=3
    FAILED_STEP="Pull prebuilt images"
    INSTALL_ERROR="Could not pull the prebuilt images. Check your internet connection."
    return 1
  fi
  STEP_PULL=2
  STEP_RESOURCES=1

  if ! run_with_progress "Preparing Docker resources..." prepare_resources; then
    STEP_RESOURCES=3
    FAILED_STEP="Prepare Docker resources"
    INSTALL_ERROR="Could not create the Horizon AI Docker network or volume."
    return 1
  fi
  STEP_RESOURCES=2
  STEP_START=1

  if ! run_with_progress "Starting containers..." start_containers; then
    STEP_START=3
    FAILED_STEP="Start containers"
    INSTALL_ERROR="Docker could not start the Horizon AI containers."
    return 1
  fi
  STEP_START=2
  STEP_HEALTH=1

  if ! wait_api; then
    STEP_HEALTH=3
    FAILED_STEP="Wait for the API"
    INSTALL_ERROR="The Horizon AI API did not become healthy in time."
    return 1
  fi
  if ! wait_ui; then
    STEP_HEALTH=3
    FAILED_STEP="Wait for the UI"
    INSTALL_ERROR="The Horizon AI UI did not become reachable in time."
    return 1
  fi
  STEP_HEALTH=2
  return 0
}

open_browser() {
  local url="http://localhost:3000"
  if [ "$BROWSE_AVAILABLE" -eq 0 ] || [ "$NO_OPEN" -eq 1 ]; then
    printf 'Open %s in your browser.\n' "$url"
    return 0
  fi
  if [ "$IS_MACOS" -eq 1 ]; then
    open "$url" >/dev/null 2>&1 &
  elif [ "$IS_WSL" -eq 1 ]; then
    cmd.exe /c start "" "$url" >/dev/null 2>&1 &
  else
    xdg-open "$url" >/dev/null 2>&1 &
  fi
}

print_summary_plain() {
  printf '%s\n' "Mode: $(printf '%s' "$MODE" | tr '[:lower:]' '[:upper:]')"
  printf '%s\n' "Backend image: $BACKEND_IMAGE"
  printf '%s\n' "Frontend image: $FRONTEND_IMAGE"
  printf '%s\n' "Ports: 3000 (UI), 8000 (API)"
  printf '%s\n' "Data: $VOLUME_NAME (persisted)"
  printf '%s\n' "Network: $NETWORK_NAME"
  printf '%s\n' "Internet: required for the first install"
  if [ -n "$EXISTING_CONTAINERS" ]; then
    printf '%s\n' "Existing containers will be recreated: $EXISTING_CONTAINERS"
  fi
  if [ "$FORCE_GPU_WARNING" -eq 1 ]; then
    printf '%s\n' "Warning: GPU mode forced below the ${MIN_VRAM_MB} MB recommendation."
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' "Dry run: no changes made."
  fi
}

print_success_plain() {
  printf '%s\n' "Horizon AI is ready."
  printf '%s\n' "Open: http://localhost:3000"
  printf '%s\n' "API: http://localhost:8000"
  printf '%s\n' "Mode: $(printf '%s' "$MODE" | tr '[:lower:]' '[:upper:]')"
  printf '%s\n' "Logs: docker logs -f $CONTAINER_BACKEND"
  printf '%s\n' "Logs: docker logs -f $CONTAINER_FRONTEND"
  printf '%s\n' "Stop: docker stop $CONTAINER_FRONTEND $CONTAINER_BACKEND"
  printf '%s\n' "Start: docker start $CONTAINER_BACKEND $CONTAINER_FRONTEND"
}

wrap_text() {
  local text="$1"
  local width="$2"
  printf '%s\n' "$text" | fold -s -w "$width" 2>/dev/null || printf '%s\n' "$text"
}

render_preflight() {
  BODY=()
  local docker_state="fail"
  local docker_value="not found"
  local docker_detail="install Docker Engine or Docker Desktop"
  local gpu_state="info"
  local gpu_value="none"
  local gpu_detail="CPU mode works everywhere"
  local runtime_state="info"
  local runtime_value="not needed"
  local runtime_detail=""
  local footer="Enter Continue   R Re-check   D Guide   Q Quit"

  if [ "$DOCKER_OK" -eq 1 ]; then
    docker_state="ok"
    docker_value="$DOCKER_VERSION"
    docker_detail="linux containers"
  elif [ "$DOCKER_STATE" = "missing" ]; then
    docker_value="not found"
    docker_detail="install Docker Engine or Docker Desktop"
  else
    docker_value="not ready"
    docker_detail="$DOCKER_DETAIL"
  fi

  if [ "$GPU_PRESENT" -eq 1 ]; then
    if [ "$GPU_AVAILABLE" -eq 1 ]; then
      gpu_state="ok"
    else
      gpu_state="warn"
    fi
    gpu_value="${GPU_VRAM_MB} MB"
    gpu_detail="$GPU_NAME"
    if [ "$GPU_RUNTIME_OK" -eq 1 ]; then
      runtime_state="ok"
      runtime_value="$GPU_RUNTIME_DETAIL"
      runtime_detail="ready"
    else
      runtime_state="warn"
      runtime_value="missing"
      runtime_detail="NVIDIA Container Toolkit required"
    fi
  fi

  BODY+=("$(status_row "Docker Engine" "$docker_value" "$docker_detail" "$docker_state")")
  BODY+=("$(status_row "NVIDIA GPU" "$gpu_value" "$gpu_detail" "$gpu_state")")
  BODY+=("$(status_row "GPU container" "$runtime_value" "$runtime_detail" "$runtime_state")")
  BODY+=("")
  BODY+=("${FG_MUTED}Recommended${FG_RESET}  ${BOLD}${FG_BLUE}$(printf '%s' "$RECOMMENDED_MODE" | tr '[:lower:]' '[:upper:]')${FG_RESET}${BOLD_OFF}")
  if [ "$GPU_PRESENT" -eq 1 ] && [ "$GPU_AVAILABLE" -eq 0 ]; then
    BODY+=("${FG_AMBER}${GPU_REASON}${FG_RESET}")
  fi
  if [ "$DOCKER_OK" -eq 0 ]; then
    BODY+=("")
    BODY+=("${FG_RED}Docker must be installed and running before installation can continue.${FG_RESET}")
  fi

  draw_frame 0 "System check" "Horizon AI pulls the prebuilt stack from GitHub Container Registry." "$footer"
}

render_mode() {
  BODY=()
  local card_width
  local gpu_border
  local cpu_border
  local gpu_title="GPU ${SYM_GPU}"
  local cpu_title="CPU ${SYM_CPU}"
  local gpu_badge=""
  local cpu_badge=""
  local gpu_text="$FG_TEXT"
  local cpu_text="$FG_TEXT"
  local gpu_line_one
  local gpu_line_two
  local cpu_line_one="No GPU required"
  local cpu_line_two="Slower on large refactors"
  local side_by_side=0
  local i

  if [ "$WIDTH" -ge 92 ]; then
    side_by_side=1
    card_width=$(((WIDTH - 8) / 2))
    if [ "$card_width" -gt 48 ]; then card_width=48; fi
    if [ "$card_width" -lt 34 ]; then card_width=34; fi
  else
    card_width=$((WIDTH - 6))
    if [ "$card_width" -gt 72 ]; then card_width=72; fi
    if [ "$card_width" -lt 40 ]; then card_width=40; fi
  fi

  if [ "$GPU_PRESENT" -eq 1 ]; then
    gpu_line_one="$GPU_NAME"
    gpu_line_two="${GPU_VRAM_MB} MB VRAM"
  else
    gpu_line_one="No NVIDIA GPU detected"
    gpu_line_two=""
  fi

  if [ "$GPU_AVAILABLE" -eq 1 ]; then
    if [ "$RECOMMENDED_MODE" = "gpu" ]; then
      gpu_badge="[ RECOMMENDED ]"
    fi
  else
    gpu_text="$FG_MUTED"
    if [ "$GPU_PRESENT" -eq 1 ]; then
      gpu_badge="[ UNAVAILABLE ]"
    fi
  fi
  if [ "$RECOMMENDED_MODE" = "cpu" ]; then
    cpu_badge="[ RECOMMENDED ]"
  fi

  if [ "$CURRENT_MODE_INDEX" -eq 0 ]; then
    gpu_title="${SYM_ARROW} GPU ${SYM_GPU}"
    gpu_border="$FG_BLUE"
  else
    gpu_border="$FG_BORDER"
  fi
  if [ "$CURRENT_MODE_INDEX" -eq 1 ]; then
    cpu_title="${SYM_ARROW} CPU ${SYM_CPU}"
    cpu_border="$FG_BLUE"
  else
    cpu_border="$FG_BORDER"
  fi

  build_card "$card_width" "$gpu_border" "$gpu_title" "NVIDIA acceleration" "$gpu_line_one" "$gpu_line_two" "$gpu_badge" "$FG_BLUE" "$gpu_text"
  local -a gpu_card
  gpu_card=("${CARD[@]}")
  build_card "$card_width" "$cpu_border" "$cpu_title" "Runs on any machine" "$cpu_line_one" "$cpu_line_two" "$cpu_badge" "$FG_BLUE" "$cpu_text"
  local -a cpu_card
  cpu_card=("${CARD[@]}")

  if [ "$side_by_side" -eq 1 ]; then
    for i in "${!gpu_card[@]}"; do
      BODY+=("${gpu_card[$i]}${BG_MAIN}  ${cpu_card[$i]}")
    done
  else
    for i in "${!gpu_card[@]}"; do
      BODY+=("${gpu_card[$i]}")
    done
    BODY+=("")
    for i in "${!cpu_card[@]}"; do
      BODY+=("${cpu_card[$i]}")
    done
  fi

  BODY+=("")
  BODY+=("${FG_MUTED}ENVIRONMENT${FG_RESET}")
  BODY+=("${FG_GREEN}${SYM_DOT}${FG_RESET} Docker ${DOCKER_VERSION}   ${FG_GREEN}${SYM_DOT}${FG_RESET} GPU runtime ${GPU_RUNTIME_DETAIL:-n/a}   ${FG_MUTED}GHCR images${FG_RESET}")
  if [ "$GPU_PRESENT" -eq 1 ]; then
    BODY+=("${FG_MUTED}GPU${FG_RESET} ${GPU_NAME}   ${FG_MUTED}VRAM${FG_RESET} ${GPU_VRAM_MB} MB")
  else
    BODY+=("${FG_MUTED}GPU${FG_RESET} none")
  fi
  if [ "$GPU_PRESENT" -eq 1 ] && [ "$GPU_AVAILABLE" -eq 0 ]; then
    BODY+=("${FG_AMBER}${GPU_REASON}${FG_RESET}")
  fi

  draw_frame 1 "Choose how Horizon AI runs" "GPU is recommended when supported. CPU works everywhere." "${KEY_UP_DOWN} Move   Enter Select   B Back   Q Quit"
}

render_summary() {
  BODY=()
  BODY+=("$(kv_line "Mode" "$(printf '%s' "$MODE" | tr '[:lower:]' '[:upper:]')")")
  BODY+=("$(kv_line "Backend" "$BACKEND_IMAGE")")
  BODY+=("$(kv_line "Frontend" "$FRONTEND_IMAGE")")
  BODY+=("$(kv_line "Ports" "3000 (UI) · 8000 (API)")")
  BODY+=("$(kv_line "Data" "$VOLUME_NAME (persisted)")")
  BODY+=("$(kv_line "Network" "$NETWORK_NAME")")
  BODY+=("")
  BODY+=("${FG_MUTED}Internet is required for the first install. Images are pulled from GHCR.${FG_RESET}")
  if [ -n "$EXISTING_CONTAINERS" ]; then
    BODY+=("${FG_AMBER}Existing containers will be recreated: ${EXISTING_CONTAINERS}${FG_RESET}")
  fi
  if [ "$FORCE_GPU_WARNING" -eq 1 ]; then
    BODY+=("${FG_AMBER}GPU mode is forced below the ${MIN_VRAM_MB} MB recommendation.${FG_RESET}")
  fi
  BODY+=("")
  BODY+=("$(menu_line "Install Horizon AI" "$([ "$CURRENT_MENU_INDEX" -eq 0 ] && printf 1 || printf 0)")")
  BODY+=("$(menu_line "Back" "$([ "$CURRENT_MENU_INDEX" -eq 1 ] && printf 1 || printf 0)")")
  BODY+=("$(menu_line "Cancel" "$([ "$CURRENT_MENU_INDEX" -eq 2 ] && printf 1 || printf 0)")")

  draw_frame 2 "Ready to install" "" "${KEY_UP_DOWN} Move   Enter Select   Q Quit"
}

render_progress() {
  BODY=()
  local done_count=0
  local bar_width
  local log_width
  local log_lines
  local line
  local pull_state="pending"
  local resources_state="pending"
  local start_state="pending"
  local health_state="pending"

  if [ "$STEP_PULL" -eq 2 ]; then done_count=$((done_count + 1)); fi
  if [ "$STEP_RESOURCES" -eq 2 ]; then done_count=$((done_count + 1)); fi
  if [ "$STEP_START" -eq 2 ]; then done_count=$((done_count + 1)); fi
  if [ "$STEP_HEALTH" -eq 2 ]; then done_count=$((done_count + 1)); fi

  case "$STEP_PULL" in
    1) pull_state="active" ;;
    2) pull_state="done" ;;
    3) pull_state="fail" ;;
  esac
  case "$STEP_RESOURCES" in
    1) resources_state="active" ;;
    2) resources_state="done" ;;
    3) resources_state="fail" ;;
  esac
  case "$STEP_START" in
    1) start_state="active" ;;
    2) start_state="done" ;;
    3) start_state="fail" ;;
  esac
  case "$STEP_HEALTH" in
    1) health_state="active" ;;
    2) health_state="done" ;;
    3) health_state="fail" ;;
  esac

  bar_width=$((WIDTH - 6))
  if [ "$bar_width" -lt 20 ]; then bar_width=20; fi
  BODY+=("$(progress_bar "$done_count" 4 "$bar_width")")
  BODY+=("")
  BODY+=("$(step_row "$pull_state" "Pull prebuilt images" "")")
  BODY+=("$(step_row "$resources_state" "Prepare Docker resources" "")")
  BODY+=("$(step_row "$start_state" "Start containers" "")")
  BODY+=("$(step_row "$health_state" "Wait for Horizon AI" "")")
  BODY+=("")
  log_width=$((WIDTH - 2))
  if [ "$log_width" -lt 30 ]; then log_width=30; fi
  BODY+=("$(card_top "$log_width" "$FG_BORDER")")
  log_lines="$(log_tail 4)"
  while IFS= read -r line; do
    BODY+=("$(card_mid "$log_width" "$FG_BORDER" "$line" "$FG_MUTED")")
  done <<< "$log_lines"
  BODY+=("$(card_bottom "$log_width" "$FG_BORDER")")

  draw_frame 2 "Installing Horizon AI" "" "Pulling images and starting containers. This can take a few minutes."
}

render_failure() {
  BODY=()
  local log_width
  local log_lines
  local line
  local switch_label="Switch to CPU"
  local menu_index=0
  local switch_selected=0
  local logs_selected=0
  local quit_selected=0

  BODY+=("${FG_RED}${INSTALL_ERROR}${FG_RESET}")
  BODY+=("${FG_MUTED}Failed step: ${FAILED_STEP}${FG_RESET}")
  BODY+=("")
  log_width=$((WIDTH - 2))
  if [ "$log_width" -lt 30 ]; then log_width=30; fi
  BODY+=("$(card_top "$log_width" "$FG_BORDER")")
  log_lines="$(log_tail 8)"
  while IFS= read -r line; do
    BODY+=("$(card_mid "$log_width" "$FG_BORDER" "$line" "$FG_MUTED")")
  done <<< "$log_lines"
  BODY+=("$(card_bottom "$log_width" "$FG_BORDER")")
  BODY+=("")

  if [ "$CURRENT_MENU_INDEX" -eq 0 ]; then
    BODY+=("$(menu_line "Retry" 1)")
  else
    BODY+=("$(menu_line "Retry" 0)")
  fi
  if [ "$MODE" = "gpu" ]; then
    menu_index=1
    if [ "$CURRENT_MENU_INDEX" -eq "$menu_index" ]; then switch_selected=1; fi
    BODY+=("$(menu_line "$switch_label" "$switch_selected")")
  fi
  menu_index=$((menu_index + 1))
  if [ "$CURRENT_MENU_INDEX" -eq "$menu_index" ]; then logs_selected=1; fi
  BODY+=("$(menu_line "View logs" "$logs_selected")")
  menu_index=$((menu_index + 1))
  if [ "$CURRENT_MENU_INDEX" -eq "$menu_index" ]; then quit_selected=1; fi
  BODY+=("$(menu_line "Quit" "$quit_selected")")

  draw_frame 2 "Installation failed" "Containers and data were left in place for inspection." "${KEY_UP_DOWN} Move   Enter Select   Q Quit"
}

render_success() {
  BODY=()
  local line
  local logs_command
  local stop_command
  local start_command
  local open_selected=0
  local logs_selected=0
  local exit_selected=0
  local command_width

  BODY+=("$(kv_line "Open" "http://localhost:3000")")
  BODY+=("$(kv_line "API" "http://localhost:8000")")
  BODY+=("$(kv_line "Mode" "$(printf '%s' "$MODE" | tr '[:lower:]' '[:upper:]')")")
  if [ "$GPU_PRESENT" -eq 1 ] && [ "$MODE" = "gpu" ]; then
    BODY+=("$(kv_line "GPU" "$GPU_NAME · ${GPU_VRAM_MB} MB VRAM")")
  fi
  BODY+=("")
  command_width=$((WIDTH - 2))
  if [ "$command_width" -lt 30 ]; then command_width=30; fi
  logs_command="docker logs -f $CONTAINER_BACKEND · docker logs -f $CONTAINER_FRONTEND"
  stop_command="docker stop $CONTAINER_FRONTEND $CONTAINER_BACKEND"
  start_command="docker start $CONTAINER_BACKEND $CONTAINER_FRONTEND"
  BODY+=("${FG_MUTED}Logs${FG_RESET}")
  while IFS= read -r line; do
    BODY+=("${FG_TEXT}${line}${FG_RESET}")
  done <<< "$(wrap_text "$logs_command" "$command_width")"
  BODY+=("${FG_MUTED}Stop${FG_RESET}")
  while IFS= read -r line; do
    BODY+=("${FG_TEXT}${line}${FG_RESET}")
  done <<< "$(wrap_text "$stop_command" "$command_width")"
  BODY+=("${FG_MUTED}Start${FG_RESET}")
  while IFS= read -r line; do
    BODY+=("${FG_TEXT}${line}${FG_RESET}")
  done <<< "$(wrap_text "$start_command" "$command_width")"
  BODY+=("")

  if [ "$SUCCESS_MENU_INDEX" -eq 0 ]; then open_selected=1; fi
  if [ "$SUCCESS_MENU_INDEX" -eq 1 ]; then logs_selected=1; fi
  if [ "$SUCCESS_MENU_INDEX" -eq 2 ]; then exit_selected=1; fi
  BODY+=("$(menu_line "Open Horizon AI" "$open_selected")")
  BODY+=("$(menu_line "View recent logs" "$logs_selected")")
  BODY+=("$(menu_line "Exit" "$exit_selected")")

  draw_frame 3 "Horizon AI is ready" "Your local refactoring studio is running." "${KEY_UP_DOWN} Move   Enter Select   Q Quit"
}

render_help() {
  BODY=()
  BODY+=("${BOLD}${FG_TEXT}Docker${FG_RESET}${BOLD_OFF}")
  BODY+=("Install Docker Engine or Docker Desktop, start it, then press R on the system check screen.")
  BODY+=("")
  BODY+=("${BOLD}${FG_TEXT}GPU mode${FG_RESET}${BOLD_OFF}")
  BODY+=("GPU mode needs an NVIDIA GPU with at least ${MIN_VRAM_MB} MB VRAM and the NVIDIA Container Toolkit.")
  BODY+=("On Windows, enable GPU support in Docker Desktop with the WSL2 backend.")
  BODY+=("")
  BODY+=("${BOLD}${FG_TEXT}CPU mode${FG_RESET}${BOLD_OFF}")
  BODY+=("CPU mode works on any machine and does not need an NVIDIA GPU.")
  draw_frame 0 "Setup help" "" "B Back   Q Quit"
}

render_logs() {
  BODY=()
  local line
  local max_width
  local count=18
  max_width=$((WIDTH - 2))
  if [ "$max_width" -lt 20 ]; then max_width=20; fi
  BODY+=("${FG_MUTED}${LOG_FILE}${FG_RESET}")
  BODY+=("")
  if [ -s "$LOG_FILE" ]; then
    while IFS= read -r line; do
      BODY+=("${FG_TEXT}$(fit_plain "$line" "$max_width")${FG_RESET}")
    done <<< "$(tail -n "$count" "$LOG_FILE")"
  else
    BODY+=("${FG_MUTED}No log output yet.${FG_RESET}")
  fi
  draw_frame 2 "Recent logs" "" "B Back   Q Quit"
}

tui_help() {
  local key
  while :; do
    render_help
    key="$(read_key)" || return 1
    case "$key" in
      B|b|Q|q|ENTER) return 0 ;;
    esac
  done
}

tui_logs() {
  local key
  while :; do
    render_logs
    key="$(read_key)" || return 1
    case "$key" in
      B|b|Q|q|ENTER) return 0 ;;
    esac
  done
}

tui_preflight() {
  local key
  while :; do
    render_preflight
    key="$(read_key)" || return 1
    case "$key" in
      R|r)
        run_preflight
        ;;
      D|d)
        tui_help
        ;;
      ENTER)
        if [ "$DOCKER_OK" -eq 1 ]; then
          return 0
        fi
        ;;
      Q|q)
        return 130
        ;;
    esac
  done
}

tui_mode() {
  local key
  local count=2
  if [ "$RECOMMENDED_MODE" = "cpu" ]; then
    CURRENT_MODE_INDEX=1
  else
    CURRENT_MODE_INDEX=0
  fi
  while :; do
    render_mode
    key="$(read_key)" || return 1
    case "$key" in
      UP)
        CURRENT_MODE_INDEX=$((CURRENT_MODE_INDEX - 1))
        if [ "$CURRENT_MODE_INDEX" -lt 0 ]; then CURRENT_MODE_INDEX=$((count - 1)); fi
        ;;
      DOWN)
        CURRENT_MODE_INDEX=$((CURRENT_MODE_INDEX + 1))
        if [ "$CURRENT_MODE_INDEX" -ge "$count" ]; then CURRENT_MODE_INDEX=0; fi
        ;;
      ENTER)
        if [ "$CURRENT_MODE_INDEX" -eq 1 ]; then
          MODE="cpu"
          return 0
        fi
        if [ "$GPU_AVAILABLE" -eq 1 ]; then
          MODE="gpu"
          return 0
        fi
        if [ "$GPU_PRESENT" -eq 1 ] && [ "$GPU_RUNTIME_OK" -eq 1 ] && [ "$FORCE_GPU" -eq 1 ]; then
          MODE="gpu"
          FORCE_GPU_WARNING=1
          return 0
        fi
        ;;
      B|b)
        return 10
        ;;
      Q|q)
        return 130
        ;;
    esac
  done
}

tui_summary() {
  local key
  CURRENT_MENU_INDEX=0
  while :; do
    render_summary
    key="$(read_key)" || return 1
    case "$key" in
      UP)
        CURRENT_MENU_INDEX=$((CURRENT_MENU_INDEX - 1))
        if [ "$CURRENT_MENU_INDEX" -lt 0 ]; then CURRENT_MENU_INDEX=2; fi
        ;;
      DOWN)
        CURRENT_MENU_INDEX=$((CURRENT_MENU_INDEX + 1))
        if [ "$CURRENT_MENU_INDEX" -gt 2 ]; then CURRENT_MENU_INDEX=0; fi
        ;;
      ENTER)
        case "$CURRENT_MENU_INDEX" in
          0) return 0 ;;
          1) return 10 ;;
          2) return 130 ;;
        esac
        ;;
      B|b) return 10 ;;
      Q|q) return 130 ;;
    esac
  done
}

tui_failure() {
  local key
  local count=3
  local logs_index=1
  local quit_index=2
  if [ "$MODE" = "gpu" ]; then
    count=4
    logs_index=2
    quit_index=3
  fi
  CURRENT_MENU_INDEX=0
  while :; do
    render_failure
    key="$(read_key)" || return 1
    case "$key" in
      UP)
        CURRENT_MENU_INDEX=$((CURRENT_MENU_INDEX - 1))
        if [ "$CURRENT_MENU_INDEX" -lt 0 ]; then CURRENT_MENU_INDEX=$((count - 1)); fi
        ;;
      DOWN)
        CURRENT_MENU_INDEX=$((CURRENT_MENU_INDEX + 1))
        if [ "$CURRENT_MENU_INDEX" -ge "$count" ]; then CURRENT_MENU_INDEX=0; fi
        ;;
      ENTER)
        if [ "$CURRENT_MENU_INDEX" -eq 0 ]; then
          return 0
        fi
        if [ "$MODE" = "gpu" ] && [ "$CURRENT_MENU_INDEX" -eq 1 ]; then
          return 10
        fi
        if [ "$CURRENT_MENU_INDEX" -eq "$logs_index" ]; then
          tui_logs
        fi
        if [ "$CURRENT_MENU_INDEX" -eq "$quit_index" ]; then
          return 130
        fi
        ;;
      Q|q) return 130 ;;
    esac
  done
}

tui_success() {
  local key
  SUCCESS_MENU_INDEX=0
  while :; do
    render_success
    key="$(read_key)" || return 1
    case "$key" in
      UP)
        SUCCESS_MENU_INDEX=$((SUCCESS_MENU_INDEX - 1))
        if [ "$SUCCESS_MENU_INDEX" -lt 0 ]; then SUCCESS_MENU_INDEX=2; fi
        ;;
      DOWN)
        SUCCESS_MENU_INDEX=$((SUCCESS_MENU_INDEX + 1))
        if [ "$SUCCESS_MENU_INDEX" -gt 2 ]; then SUCCESS_MENU_INDEX=0; fi
        ;;
      ENTER)
        case "$SUCCESS_MENU_INDEX" in
          0) open_browser ;;
          1) tui_logs ;;
          2) return 0 ;;
        esac
        ;;
      Q|q) return 0 ;;
    esac
  done
}

tui_install() {
  local rc
  while :; do
    if run_install; then
      tui_success
      return 0
    fi
    tui_failure
    rc=$?
    if [ "$rc" -eq 0 ]; then
      continue
    fi
    if [ "$rc" -eq 10 ]; then
      MODE="cpu"
      prepare_state
      continue
    fi
    return "$rc"
  done
}

plain_mode() {
  local answer
  local rc
  print_preflight_plain
  if [ "$DOCKER_OK" -eq 0 ]; then
    print_preflight_error
    return 3
  fi
  if [ "$MODE" = "auto" ]; then
    MODE="$RECOMMENDED_MODE"
  fi
  validate_mode
  rc=$?
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  prepare_state
  if [ "$DRY_RUN" -eq 1 ]; then
    print_summary_plain
    return 0
  fi
  if [ "$YES" -eq 0 ]; then
    if [ ! -t 0 ]; then
      printf '%s\n' "No TTY available. Re-run with --mode and --yes for non-interactive use." >&2
      return 2
    fi
    printf 'Install Horizon AI? [Y/n] '
    read -r answer
    case "$answer" in
      n|N|no|NO) return 1 ;;
    esac
  fi
  if ! run_install; then
    printf '%s\n' "$INSTALL_ERROR" >&2
    if [ -s "$LOG_FILE" ]; then
      tail -n 12 "$LOG_FILE" >&2
    fi
    return 1
  fi
  print_success_plain
  open_browser
  return 0
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --mode)
        if [ "$#" -lt 2 ]; then
          printf '%s\n' "--mode requires auto, cpu, or gpu." >&2
          exit 2
        fi
        MODE="$2"
        shift 2
        ;;
      --mode=*)
        MODE="${1#*=}"
        shift
        ;;
      --cpu)
        MODE="cpu"
        shift
        ;;
      --gpu)
        MODE="gpu"
        shift
        ;;
      --yes)
        YES=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --no-open)
        NO_OPEN=1
        shift
        ;;
      --no-color)
        NO_COLOR_FLAG=1
        shift
        ;;
      --no-tui)
        NO_TUI=1
        shift
        ;;
      --no-animation)
        NO_ANIMATION=1
        shift
        ;;
      --force-gpu)
        FORCE_GPU=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        printf 'Unknown option: %s\n\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
  done

  case "$MODE" in
    auto|cpu|gpu) ;;
    *)
      printf '%s\n' "--mode must be auto, cpu, or gpu." >&2
      exit 2
      ;;
  esac
}

main() {
  local rc

  parse_args "$@"
  detect_os
  set_default_home
  detect_terminal_caps
  terminal_size
  trap cleanup EXIT
  trap 'cleanup; exit 130' INT TERM

  run_preflight

  if [ "$DRY_RUN" -eq 1 ] || [ "$NO_TUI" -eq 1 ]; then
    plain_mode
    exit $?
  fi

  init_tui
  if [ "$TUI_ACTIVE" -eq 0 ]; then
    plain_mode
    exit $?
  fi

  while :; do
    tui_preflight
    rc=$?
    if [ "$rc" -eq 130 ]; then
      exit 0
    fi

    if [ "$MODE" = "auto" ]; then
      tui_mode
      rc=$?
      if [ "$rc" -eq 130 ]; then
        exit 0
      fi
      if [ "$rc" -eq 10 ]; then
        continue
      fi
    else
      validate_mode
      rc=$?
      if [ "$rc" -ne 0 ]; then
        cleanup
        exit "$rc"
      fi
    fi

    prepare_state

    if [ "$YES" -eq 0 ]; then
      tui_summary
      rc=$?
      if [ "$rc" -eq 130 ]; then
        exit 0
      fi
      if [ "$rc" -eq 10 ]; then
        if [ "$MODE" = "cpu" ] || [ "$MODE" = "gpu" ]; then
          MODE="auto"
        fi
        continue
      fi
    fi

    tui_install
    rc=$?
    if [ "$rc" -eq 130 ]; then
      exit 0
    fi
    exit 0
  done
}

main "$@"

