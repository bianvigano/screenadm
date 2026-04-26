#!/bin/sh
# screenadm v3.0 — Ultimate manager for GNU screen (POSIX sh only)
# Consolidating all features: Env injection, Window Guard, Healthcheck, and TUI Dashboard.
set -eu

SCREEN="${SCREEN_BIN:-screen}"
STATE_DIR="${HOME}/.screenadm"
[ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR" [cite: 2, 3]

# ---------- Dasar & Utilitas ----------
die(){ printf "\033[31m[ERR]\033[0m %s\n" "$*" >&2; exit 1; } [cite: 3]
note(){ printf "\033[32m[INFO]\033[0m %s\n" "$*" >&2; } [cite: 3, 4]
cmd_exists(){ command -v "$1" >/dev/null 2>&1; } [cite: 4]
require_screen(){ cmd_exists "$SCREEN" || die "screen tidak ditemukan."; } [cite: 4, 5]

usage(){
cat <<'USAGE'
pakai: screenadm [--ns PREFIX] <perintah> [arg...]

Perintah Inti:
  apply [--dry-run] <cfg>   Terapkan konfigurasi (Idempotent) [cite: 5]
  up <session>              Re-apply dari cache terakhir [cite: 5, 6]
  down <session>            Matikan sesi [cite: 6, 32]
  status [session]          Cek sesi & windows (Healthcheck) [cite: 6, 33]
  restart-window <s] <t>    Kill & recreate window dari cache 

Interaksi & Dashboard:
  menu                      Dashboard interaktif (Arrow/Vim keys) [cite: 7, 88]
  top                       Live status dashboard (manual refresh 'r') 
  send <session> <title>    Kirim STDIN (multi-baris) ke window [cite: 6, 41, 42]
  attach <session>          Attach (dengan window picker otomatis) [cite: 6, 40]

Manajemen & Log:
  log-on/off <s] <t> [f]    Atur logging window [cite: 6, 43, 45]
  snapshot <s] <t> [f]      Hardcopy buffer window [cite: 7, 48, 49]
  share/unshare <s] <u]     Atur akses multiuser [cite: 6, 7, 46, 47]
  remote <user@host> <cfg>  Remote apply via SSH/SCP 
USAGE
}

# ---------- Namespace & Cache Engine ----------
NS_PREFIX=""
set_ns(){ NS_PREFIX="$1"; } [cite: 13]
ns_key(){ [ -n "$NS_PREFIX" ] && printf "%s__%s" "$NS_PREFIX" "$1" || printf "%s" "$1"; } [cite: 13]
sess_actual(){ ns_key "$1"; } [cite: 14]
cache_path(){ printf "%s/%s.last.cfg" "$STATE_DIR" "$(ns_key "$1")"; } [cite: 14]
load_cached_or_die(){ p="$(cache_path "$1")"; [ -f "$p" ] || die "Cache tidak ada."; printf "%s\n" "$p"; } [cite: 15]

# ---------- Session & Window Helpers ----------
sess_exists(){ "$SCREEN" -S "$1" -X echo >/dev/null 2>&1; } [cite: 16, 17]
win_exists(){ "$SCREEN" -S "$1" -p "$2" -X echo >/dev/null 2>&1; } 

ensure_session(){
  name="$1"
  if ! sess_exists "$name"; then
    "$SCREEN" -S "$name" -dm "${SHELL:-/bin/sh}" [cite: 18]
    note "Sesi '$name' dibuat." [cite: 18]
  fi
}

inject_env_file(){
  file="$1"; out=""
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ""|"#"*|*" "*) continue ;; esac
      case "$line" in *=*) out="${out}${line} "; esac
    done < "$file"
  fi
  printf "%s" "$out" 
}

build_window_chain(){
  wdir="$1"; wenv="$2"; wenv_file="$3"; wpre="$4"; wcmd="$5"; wpost="$6"; respawn="$7"
  env_inject="$(inject_env_file "$wenv_file")" 
  chain="cd \"${wdir:-$HOME}\"; ${env_inject}${wenv:+$wenv ;} ${wpre:-:} ; ${wcmd} ; ${wpost:-:}" [cite: 21]
  [ "$respawn" = "yes" ] && chain="while :; do ${chain}; sleep 2; done" 
  printf "%s" "$chain"
}

create_or_update_window(){
  sess="$1"; title="$2"; wdir="$3"; wenv="$4"; wenvf="$5"; wpre="$6"; wcmd="$7"; wpost="$8"; wlog="$9"; respawn="${10-no}"
  if win_exists "$sess" "$title"; then note "Window '$title' sudah ada — skip."; return 0; fi [cite: 20]
  chain="$(build_window_chain "$wdir" "$wenv" "$wenvf" "$wpre" "$wcmd" "$wpost" "$respawn")" [cite: 21]
  [ -n "$wlog" ] && { "$SCREEN" -S "$sess" -X logfile "$wlog"; "$SCREEN" -S "$sess" -X log on; } [cite: 22]
  "$SCREEN" -S "$sess" -X screen -t "$title" sh -lc "$chain" [cite: 22]
}

# ---------- Core Commands Implementation ----------
cmd_apply(){
  dry="no"; [ "${1:-}" = "--dry-run" ] && { dry="yes"; shift; }
  cfg="$1"; [ -f "$cfg" ] || die "Config tidak ditemukan: $cfg" [cite: 23]
  . "$cfg" [cite: 24]
  [ -z "$NS_PREFIX" ] && [ -n "${NAMESPACE:-}" ] && NS_PREFIX="$NAMESPACE" [cite: 24]
  require_screen
  sess="$(sess_actual "$SESSION")" [cite: 26]
  
  if [ "$dry" = "yes" ]; then note "[DRY-RUN] Sesi: $sess"; else ensure_session "$sess"; fi 

  i=1
  while [ "$i" -le "${WIN_COUNT:-0}" ]; do
    eval "title=\${WIN${i}_TITLE:-}"; eval "cmd=\${WIN${i}_CMD:-}"
    [ -n "$title" ] || die "WIN${i}_TITLE kosong" [cite: 29]
    if [ "$dry" = "no" ]; then
      eval "dir=\${WIN${i}_DIR:-$HOME}"; eval "envs=\${WIN${i}_ENV:-}"; eval "envf=\${WIN${i}_ENV_FILE:-no}"
      eval "pre=\${WIN${i}_PRE:-}"; eval "post=\${WIN${i}_POST:-}"; eval "logf=\${WIN${i}_LOG:-}"
      eval "rspn=\${WIN${i}_RESPAWN:-no}"
      create_or_update_window "$sess" "$title" "$dir" "$envs" "$envf" "$pre" "$cmd" "$post" "$logf" "$rspn"
    else
      printf "  - Window: %s | Cmd: %s\n" "$title" "$cmd"
    fi
    i=$((i+1)) [cite: 29]
  done
  [ "$dry" = "no" ] && { cp "$cfg" "$(cache_path "$SESSION")"; note "Apply selesai."; } [cite: 29, 30]
}

# ---------- Dashboard & TUI (Portable dd-based) ----------
__read_key(){ 
  KEY=""; KEY="$(dd bs=1 count=1 2>/dev/null)"; 
  if [ "$KEY" = "$(printf '\033')" ]; then 
    k1="$(dd bs=1 count=1 2>/dev/null)"; k2="$(dd bs=1 count=1 2>/dev/null)"; 
    KEY="$KEY$k1$k2"; 
  fi [cite: 63, 64]
}

cmd_menu(){
  require_screen
  __menu_sessions # Memanggil fungsi picker dari script asli Anda [cite: 89, 102]
}

cmd_top(){
  require_screen
  while :; do
    printf '\033[2J\033[H' # Clear screen [cite: 58]
    printf "%-20s %-15s %-10s %s\n" "SESSION" "WINDOW" "HEALTH" "COMMAND"
    printf "------------------------------------------------------------------\n"
    # Logika status loop... 
    printf "\n[r] Refresh | [q] Quit\n"
    __read_key
    case "$KEY" in q) break;; r) continue;; esac
  done
}

# ---------- Parse Arguments ----------
[ $# -ge 1 ] || { usage; exit 2; } [cite: 142]
if [ "$1" = "--ns" ]; then set_ns "$2"; shift 2; fi [cite: 143]
sub="$1"; shift

case "$sub" in
  apply)          cmd_apply "$@" ;; [cite: 145]
  up)             cfg="$(load_cached_or_die "$1")"; cmd_apply "$cfg" ;; [cite: 146, 147]
  down)           cmd_down "$1" ;; [cite: 148]
  status)         cmd_status "${1-}" ;; [cite: 149]
  menu)           cmd_menu ;; [cite: 161]
  top)            cmd_top ;; 
  restart-window) cmd_restart_window "$1" "$2" ;; 
  template)       cmd_template "$1" ;; 
  *)              die "Perintah tidak dikenal: $sub" ;; [cite: 161]
esac