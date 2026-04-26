#!/bin/sh
# screenadm v2.1 — Big manager for GNU screen (POSIX sh only)
# Features merged & consolidated:
# - Declarative apply (TITLE/DIR/ENV/PRE/CMD/POST/LOG), idempotent
# - Namespace (--ns / NAMESPACE) -> "<ns>__<SESSION>"
# - APPLY_PRE/APPLY_POST (host), per-window PRE/POST (inside) + PRE_HOST/POST_HOST (host)
# - Auto-respawn (WINn_RESPAWN="yes")
# - .env file inject (WINn_ENV_FILE=)
# - Preset alias via normal shell expansion (define PRESET_* and reference them)
# - Healthcheck (WINn_HEALTHCHECK; 0=OK)
# - Notifications (notify-send / osascript / wall auto-detect)
# - Live dashboard `top` (manual refresh with 'r')
# - Window Guard (WINn_PROTECT="yes")
# - Recovery tool (recover), bulk apply (apply-all), dry-run (apply --dry-run)
# - Restart window from cache (restart-window)
# - Remote apply via SSH/SCP (remote user@host cfg)
# - Profiling hook (WINn_PROFILE command)
# - Interactive dashboard `menu` (arrow ↑/↓/←/→ or vim j/k/h/l, ':' filter ns, 'r' refresh, Send multiline),
#   with session list caching (no grep/sed/awk/tput/sleep needed). Uses `dd` for 1-byte input (dash-safe).
set -eu

SCREEN="${SCREEN_BIN:-screen}"
STATE_DIR="${HOME}/.screenadm"
[ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR"

die(){ printf "%s\n" "$*" >&2; exit 1; }
note(){ printf "%s\n" "$*" >&2; }
cmd_exists(){ command -v "$1" >/dev/null 2>&1; }
require_screen(){ cmd_exists "$SCREEN" || die "screen tidak ditemukan."; }

usage(){
cat <<'USAGE'
pakai: screenadm [--ns PREFIX] <perintah> [arg...]

Perintah:
  apply [--dry-run] <config.sh>        Terapkan konfigurasi
  up <session>                         Re-apply dari cache terakhir
  down <session>                       Matikan sesi
  status [session]                     Cek sesi & windows (pakai cache bila ada)
  attach <session>                     Attach (bisa pilih window)
  send <session> <title>               Kirim STDIN (multi-baris) ke window
  log-on <session> <title> [file]      Aktifkan logging window
  log-off <session> <title>            Matikan logging window
  share <session> <user>               Multiuser ON & beri akses user
  unshare <session> <user>             Cabut akses user
  snapshot <session> <title> [file]    Hardcopy buffer window
  export <session>                     Cetak template config dari cache sesi
  template <kind>                      Cetak template (minimal|rest|queue|fullstack)
  menu                                 Dashboard interaktif (arrow/jkhl, ':' filter, r refresh)
  restart-window <session> <title>     Kill & recreate window dari cache
  recover <session>                    Restore sesi dari cache
  apply-all <dir>                      Apply semua *.cfg di folder
  remote <user@host> <config.sh>       Remote apply via ssh/scp
  profile <session> <title>            Jalankan WINn_PROFILE
  top                                  Live status dashboard (manual refresh 'r')

Config contoh:
  NAMESPACE="dev"
  SESSION="fullstack"
  WIN_COUNT=2
  APPLY_PRE='echo "pre-apply..."'
  APPLY_POST='echo "done."'
  PRESET_tail='sh -lc "tail -f logs/app.log || $SHELL"'

  WIN1_TITLE="api"
  WIN1_DIR="$HOME/app"
  WIN1_ENV="PORT=3000"
  WIN1_ENV_FILE="$HOME/app/.env"
  WIN1_PRE_HOST=': '
  WIN1_PRE='echo booting...'
  WIN1_CMD='node server.js'
  WIN1_POST='echo live'
  WIN1_POST_HOST=': '
  WIN1_LOG="$HOME/logs/api.log"
  WIN1_RESPAWN="no"
  WIN1_HEALTHCHECK='sh -lc "pgrep -f \"node server.js\" >/dev/null"'
  WIN1_PROFILE='ps -o pid,pcpu,pmem,comm -C node'
  WIN1_PROTECT="no"

  WIN2_TITLE="logs"
  WIN2_DIR="$HOME/app"
  WIN2_ENV=""
  WIN2_CMD="$PRESET_tail"

USAGE
}

# ---------- namespace & cache ----------
NS_PREFIX=""
set_ns(){ NS_PREFIX="$1"; }
ns_key(){ if [ -n "$NS_PREFIX" ]; then printf "%s__%s" "$NS_PREFIX" "$1"; else printf "%s" "$1"; fi; }
sess_actual(){ ns_key "$1"; }
cache_path(){ printf "%s/%s.last.cfg" "$STATE_DIR" "$(ns_key "$1")"; }
cache_config(){ cp "$2" "$(cache_path "$1")"; }
load_cached_or_die(){ p="$(cache_path "$1")"; [ -f "$p" ] || die "Cache config tidak ada untuk sesi '$1'. Jalankan apply dulu."; printf "%s\n" "$p"; }

# ---------- session/window helpers ----------
sess_exists(){ "$SCREEN" -S "$1" -X echo >/dev/null 2>&1; }
win_exists(){ "$SCREEN" -S "$1" -p "$2" -X echo >/dev/null 2>&1; }

ensure_session(){
  name="$1"
  if ! sess_exists "$name"; then
    shell_bin="${SHELL:-/bin/sh}"
    "$SCREEN" -S "$name" -dm "$shell_bin"
    note "dibuat sesi '$name'"
  fi
}

# ENV injector from .env (KEY=VAL lines only)
inject_env_file(){
  file="$1"; out=""
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ""|"#"* ) continue ;; esac
      case "$line" in *=*)
        key="${line%%=*}"; val="${line#*=}"
        [ -n "$key" ] || continue
        case "$key" in " "*) continue;; esac
        if [ -z "$out" ]; then out="${key}=${val}"; else out="$out ${key}=${val}"; fi
      esac
    done < "$file"
  fi
  printf "%s" "$out"
}

# Build final command chain for a window
build_window_chain(){
  wdir="$1"; wenv="$2"; wenv_file="$3"; wpre="$4"; wcmd="$5"; wpost="$6"; respawn="$7"
  env_inject=""; [ -n "$wenv_file" ] && env_inject="$(inject_env_file "$wenv_file")"
  chain="cd \"${wdir:-$HOME}\"; ${env_inject:+$env_inject ;} ${wenv:+$wenv ;} ${wpre:-:} ; ${wcmd} ; ${wpost:-:}"
  [ "${respawn:-no}" = "yes" ] && chain="while :; do ${chain}; done"
  printf "%s" "$chain"
}

# Guard check (protect windows)
base_from_actual(){ case "$1" in *__*) printf "%s\n" "${1#*__}" ;; *) printf "%s\n" "$1" ;; esac; }
is_protected(){
  sess="$1"; title="$2"; base="$(base_from_actual "$sess")"; cfg="$(cache_path "$base")"
  [ -f "$cfg" ] || return 1
  . "$cfg"
  i=1
  while [ "$i" -le "${WIN_COUNT:-0}" ]; do
    eval "t=\${WIN${i}_TITLE:-}"; eval "p=\${WIN${i}_PROTECT:-no}"
    [ "$t" = "$title" ] && [ "$p" = "yes" ] && return 0
    i=$((i+1))
  done
  return 1
}

create_or_update_window(){
  sess="$1"; title="$2"; wdir="$3"; wenv="$4"; wenvf="$5"; wpre_host="$6"; wpre="$7"; wcmd="$8"; wpost="$9"; wpost_host="${10-}"; wlog="${11-}"; respawn="${12-}"
  [ -n "$title" ] || die "TITLE kosong"
  if win_exists "$sess" "$title"; then note "window '$title' sudah ada — skip"; return 0; fi
  [ -n "$wpre_host" ] && sh -lc "$wpre_host" || true
  chain="$(build_window_chain "$wdir" "$wenv" "$wenvf" "$wpre" "$wcmd" "$wpost" "$respawn")"
  [ -n "$wlog" ] && { "$SCREEN" -S "$sess" -X logfile "$wlog"; "$SCREEN" -S "$sess" -X log on; }
  "$SCREEN" -S "$sess" -X screen -t "$title" sh -lc "$chain"
  [ -n "$wpost_host" ] && sh -lc "$wpost_host" || true
  note "window '$title' dibuat"
}

# ---------- notifications ----------
notify(){
  msg="$1"
  if cmd_exists notify-send; then notify-send "screenadm" "$msg" || true
  elif cmd_exists osascript; then osascript -e "display notification \"$msg\" with title \"screenadm\"" || true
  elif cmd_exists wall; then printf "%s\n" "$msg" | wall >/dev/null 2>&1 || true
  else note "[notify] $msg"
  fi
}

# ---------- apply / up / down / status ----------
cmd_apply(){
  dry="no"; if [ "${1:-}" = "--dry-run" ]; then dry="yes"; shift; fi
  cfg="$1"; [ -f "$cfg" ] || die "config tidak ditemukan: $cfg"
  . "$cfg"
  [ -z "${NS_PREFIX:-}" ] && [ -n "${NAMESPACE:-}" ] && NS_PREFIX="$NAMESPACE"
  [ -n "${SESSION:-}" ] || die "Config: SESSION kosong"
  [ -n "${WIN_COUNT:-}" ] || die "Config: WIN_COUNT kosong"
  require_screen
  sess="$(sess_actual "$SESSION")"
  if [ "$dry" = "yes" ]; then printf "[DRY-RUN] sesi: %s\n" "$sess"; else [ -n "${APPLY_PRE:-}" ] && sh -lc "${APPLY_PRE}" || true; ensure_session "$sess"; fi
  i=1
  while [ "$i" -le "${WIN_COUNT:-0}" ]; do
    eval "title=\${WIN${i}_TITLE:-}"; eval "dir=\${WIN${i}_DIR:-$HOME}"; eval "envs=\${WIN${i}_ENV:-}"; eval "envf=\${WIN${i}_ENV_FILE:-}"
    eval "pre_host=\${WIN${i}_PRE_HOST:-}"; eval "pre=\${WIN${i}_PRE:-}"; eval "cmd=\${WIN${i}_CMD:-}"; eval "post=\${WIN${i}_POST:-}"; eval "post_host=\${WIN${i}_POST_HOST:-}"
    eval "logf=\${WIN${i}_LOG:-}"; eval "respawn=\${WIN${i}_RESPAWN:-no}"
    [ -n "$title" ] || die "WIN${i}_TITLE kosong"
    if [ "$dry" = "yes" ]; then printf "  - %-12s dir=%s respawn=%s log=%s\n" "$title" "$dir" "$respawn" "${logf:-no}"
    else create_or_update_window "$sess" "$title" "$dir" "$envs" "$envf" "$pre_host" "$pre" "$cmd" "$post" "$post_host" "$logf" "$respawn"
    fi
    i=$((i+1))
  done
  if [ "$dry" = "no" ]; then cache_config "$SESSION" "$cfg"; [ -n "${APPLY_POST:-}" ] && sh -lc "${APPLY_POST}" || true; notify "apply selesai: $(sess_actual "$SESSION")"; note "apply selesai untuk sesi '$(sess_actual "$SESSION")'"; fi
}

cmd_up(){ sess_in="$1"; require_screen; cfg="$(load_cached_or_die "$sess_in")"; cmd_apply "$cfg"; }
cmd_down(){ sess_in="$1"; require_screen; sess="$(sess_actual "$sess_in")"; sess_exists "$sess" || die "sesi '$sess' tidak ada"; "$SCREEN" -S "$sess" -X quit || true; __cache_mark_dirty || true; note "sesi '$sess' dimatikan"; }

cmd_status(){
  require_screen
  if [ $# -eq 0 ]; then $SCREEN -ls || true; else
    sess_in="$1"; sess="$(sess_actual "$sess_in")"
    if sess_exists "$sess"; then
      note "sesi '$sess': ADA"; cfg="$(cache_path "$sess_in")"
      if [ -f "$cfg" ]; then . "$cfg"; i=1; while [ "$i" -le "${WIN_COUNT:-0}" ]; do
        eval "t=\${WIN${i}_TITLE:-}"; eval "hc=\${WIN${i}_HEALTHCHECK:-}"
        if [ -n "$t" ]; then
          if win_exists "$sess" "$t"; then [ -n "$hc" ] && { sh -lc "$hc" >/dev/null 2>&1 && h="OK" || h="BAD"; } || h="-"; note "  - '$t': ADA (health: $h)"
          else note "  - '$t': TIDAK ADA"
          fi
        fi
        i=$((i+1))
      done; fi
    else note "sesi '$sess': TIDAK ADA"; exit 1; fi
  fi
}

cmd_attach(){
  require_screen; sess="$(sess_actual "$1")"; sess_exists "$sess" || die "sesi '$sess' tidak ada"
  cfg="$(cache_path "$1")"
  if [ -f "$cfg" ]; then . "$cfg"; count=0; i=1; titles=""; while [ "$i" -le "${WIN_COUNT:-0}" ]; do eval "t=\${WIN${i}_TITLE:-}"; [ -n "$t" ] && { titles="${titles}${titles:+ }$t"; count=$((count+1)); }; i=$((i+1)); done
    if [ "$count" -gt 1 ]; then printf "Pilih window (nama kosong=default):\n  %s\n> " "$titles"; IFS= read -r pick || true; [ -n "$pick" ] && "$SCREEN" -S "$sess" -p "$pick" -X select . || true; fi
  fi
  "$SCREEN" -r "$sess"
}

cmd_send(){
  require_screen; sess="$(sess_actual "$1")"; title="$2"; win_exists "$sess" "$title" || die "window '$title' tidak ada"
  CR="$(printf '\015')"; while IFS= read -r line; do "$SCREEN" -S "$sess" -p "$title" -X stuff "$line"; "$SCREEN" -S "$sess" -p "$title" -X stuff "$CR"; done
}

cmd_log_on(){ require_screen; sess="$(sess_actual "$1")"; title="$2"; file="${3:-}"; win_exists "$sess" "$title" || die "window '$title' tidak ada"; [ -n "$file" ] || file="$HOME/$(ns_key "$1").${title}.log"; "$SCREEN" -S "$sess" -p "$title" -X logfile "$file"; "$SCREEN" -S "$sess" -p "$title" -X log on; note "log ON '$sess/$title' -> $file"; }
cmd_log_off(){ require_screen; sess="$(sess_actual "$1")"; title="$2"; win_exists "$sess" "$title" || die "window '$title' tidak ada"; "$SCREEN" -S "$sess" -p "$title" -X log off; note "log OFF '$sess/$title'"; }
cmd_share(){ require_screen; sess="$(sess_actual "$1")"; user="$2"; "$SCREEN" -S "$sess" -X multiuser on; "$SCREEN" -S "$sess" -X acladd "$user"; note "multiuser ON; akses ke '$user'"; }
cmd_unshare(){ require_screen; sess="$(sess_actual "$1")"; user="$2"; "$SCREEN" -S "$sess" -X acldel "$user" || true; note "akses user '$user' dicabut"; }
cmd_snapshot(){ require_screen; sess="$(sess_actual "$1")"; title="$2"; file="${3:-}"; win_exists "$sess" "$title" || die "window '$title' tidak ada"; [ -n "$file" ] || file="$HOME/$(ns_key "$1").${title}.hardcopy.txt"; "$SCREEN" -S "$sess" -p "$title" -X hardcopy "$file"; note "snapshot buffer -> $file"; }

cmd_export(){
  require_screen; sess_in="$1"; cfg="$(cache_path "$sess_in")"
  if [ -f "$cfg" ]; then cat "$cfg"; else cat <<EOF
# Template minimal (cache tidak ada). Edit sesuai kebutuhan:
SESSION="$sess_in"
WIN_COUNT=1
WIN1_TITLE="shell"
WIN1_DIR="$HOME"
WIN1_ENV=""
WIN1_CMD="\$SHELL"
EOF
  fi
}

cmd_template(){
  kind="$1"
  case "$kind" in
    minimal)
      cat <<'EOF'
# minimal.cfg
SESSION="myapp"
WIN_COUNT=1
WIN1_TITLE="shell"
WIN1_DIR="$HOME"
WIN1_ENV=""
WIN1_CMD="$SHELL"
EOF
    ;;
    rest)
      cat <<'EOF'
# rest.cfg
NAMESPACE="dev"
SESSION="restapi"
WIN_COUNT=2

WIN1_TITLE="api"
WIN1_DIR="$HOME/app"
WIN1_ENV="PORT=3000 NODE_ENV=production"
WIN1_PRE='echo "[api] starting..."'
WIN1_CMD='node server.js'
WIN1_POST='echo "[api] ready"'
WIN1_LOG="$HOME/logs/api.log"

WIN2_TITLE="logs"
WIN2_DIR="$HOME/app"
WIN2_ENV=""
WIN2_CMD='sh -lc "tail -f logs/app.log || $SHELL"'
EOF
    ;;
    queue)
      cat <<'EOF'
# queue.cfg
NAMESPACE="ops"
SESSION="queue"
WIN_COUNT=2

WIN1_TITLE="worker"
WIN1_DIR="$HOME/queue"
WIN1_ENV="CONCURRENCY=4"
WIN1_CMD='sh -lc "./worker.sh --concurrency ${CONCURRENCY:-4}"'
WIN1_LOG="$HOME/logs/worker.log"

WIN2_TITLE="monitor"
WIN2_DIR="$HOME/queue"
WIN2_ENV=""
WIN2_CMD='sh -lc "echo Q depth: $(./qstat || echo N/A); $SHELL"'
EOF
    ;;
    fullstack)
      cat <<'EOF'
# fullstack.cfg
NAMESPACE="prod"
SESSION="fullstack"
WIN_COUNT=4

WIN1_TITLE="api"
WIN1_DIR="$HOME/app"
WIN1_ENV="PORT=8080"
WIN1_CMD='node server.js'
WIN1_LOG="$HOME/logs/api.log"

WIN2_TITLE="worker"
WIN2_DIR="$HOME/app"
WIN2_ENV=""
WIN2_CMD='sh -lc "./worker.sh --concurrency 8"'
WIN2_LOG="$HOME/logs/worker.log"

WIN3_TITLE="dbshell"
WIN3_DIR="$HOME"
WIN3_ENV=""
WIN3_CMD='sh -lc "psql \"$DB_URL\" || $SHELL"'

WIN4_TITLE="shell"
WIN4_DIR="$HOME"
WIN4_ENV=""
WIN4_CMD="$SHELL"
EOF
    ;;
    *) die "unknown template kind: $kind" ;;
  esac
}

# ---------- cache helpers (menu) ----------
CACHE_SESS_FILE="$STATE_DIR/cache.sessions"
CACHE_DIRTY_FILE="$STATE_DIR/cache.sessions.dirty"
__cache_mark_dirty(){ : > "$CACHE_DIRTY_FILE" 2>/dev/null || true; }
__cache_clear_dirty(){ rm -f "$CACHE_DIRTY_FILE" 2>/dev/null || true; }
__cache_is_dirty(){ [ -f "$CACHE_DIRTY_FILE" ]; }
__cache_write_sessions(){ printf "%s\n" "$1" > "$CACHE_SESS_FILE".tmp 2>/dev/null || true; mv -f "$CACHE_SESS_FILE".tmp "$CACHE_SESS_FILE" 2>/dev/null || true; }
__cache_read_sessions(){ if [ -f "$CACHE_SESS_FILE" ]; then SESS_LIST="$(tr '\n' ' ' < "$CACHE_SESS_FILE" 2>/dev/null)"; else SESS_LIST=""; fi }

# ---------- Menu UI helpers ----------
__clrscr(){ printf '\033[2J\033[H'; }
__hide_cursor(){ printf '\033[?25l'; }
__show_cursor(){ printf '\033[?25h'; }
__rev(){ printf '\033[7m'; }
__norm(){ printf '\033[0m'; }
OLD_STTY=""

__term_setup(){ OLD_STTY="$(stty -g 2>/dev/null || printf '')"; stty -echo -icanon min 1 time 0 2>/dev/null || true; __hide_cursor; trap '__term_restore; exit' INT TERM; }
__term_restore(){ if [ -n "${OLD_STTY:-}" ]; then stty "$OLD_STTY" 2>/dev/null || stty sane 2>/dev/null || true; else stty sane 2>/dev/null || true; fi; __show_cursor; }

# portable single-byte key read (dash-safe) using dd
__read_key(){ KEY=""; KEY="$(dd bs=1 count=1 2>/dev/null)"; if [ "$KEY" = "$(printf '\033')" ]; then k1="$(dd bs=1 count=1 2>/dev/null)"; k2="$(dd bs=1 count=1 2>/dev/null)"; KEY="$KEY$k1$k2"; fi; }

# vim-style mapping
is_key_up(){ case "$1" in "$(printf '\033[A')"|j) return 0;; *) return 1;; esac; }
is_key_down(){ case "$1" in "$(printf '\033[B')"|k) return 0;; *) return 1;; esac; }
is_key_right(){ case "$1" in "$(printf '\033[C')"|l) return 0;; *) return 1;; esac; }
is_key_left(){ case "$1" in "$(printf '\033[D')"|h) return 0;; *) return 1;; esac; }

__field(){ s="$1"; n="$2"; i=1; set -- $s; for v do [ $i -eq "$n" ] && { printf "%s" "$v"; return 0; }; i=$((i+1)); done; return 1; }

# Windows loader with health
__load_windows_from_cache(){
  sess_actual="$1"; base="$(base_from_actual "$sess_actual")"; cfg="$(cache_path "$base")"
  WIN_TITLES=""; WIN_HEALTH=""
  if [ -f "$cfg" ]; then . "$cfg"; i=1; while [ "$i" -le "${WIN_COUNT:-0}" ]; do
    eval "t=\${WIN${i}_TITLE:-}"; eval "c=\${WIN${i}_CMD:-}"; eval "hc=\${WIN${i}_HEALTHCHECK:-}"
    if [ -n "$t" ]; then WIN_TITLES="${WIN_TITLES}${WIN_TITLES:+ }$t"; eval "CMD_$i=\$c"; if win_exists "$sess_actual" "$t"; then if [ -n "$hc" ]; then sh -lc "$hc" >/dev/null 2>&1 && h="OK" || h="BAD"; else h="ADA"; fi else h="TIDAK"; fi; WIN_HEALTH="${WIN_HEALTH}${WIN_HEALTH:+ }$h"; fi
    i=$((i+1))
  done; fi
}

# Sessions list (cache + FILTER_NS)
__list_sessions(){
  if [ -z "${FORCE_REFRESH:-}" ] && ! __cache_is_dirty; then __cache_read_sessions; else SESS_LIST=""; fi
  if [ -z "$SESS_LIST" ] || [ -n "${FORCE_REFRESH:-}" ]; then
    tmpf="$STATE_DIR/.ls.$$"; "$SCREEN" -ls 2>/dev/null > "$tmpf" || true
    SESS_LIST=""
    if [ -f "$tmpf" ]; then
      while IFS= read -r line; do
        case "$line" in "$(printf '\t')"*)
          set -- $line; tok="$1"; name="${tok#*.}"
          if [ -n "${FILTER_NS:-}" ]; then case "$name" in "${FILTER_NS}__"*) : ;; *) continue ;; esac; fi
          case " $SESS_LIST " in *" $name "*) : ;; *) SESS_LIST="${SESS_LIST}${SESS_LIST:+ }$name" ;; esac
        esac
      done < "$tmpf"
      rm -f "$tmpf" 2>/dev/null || true
    fi
    __cache_write_sessions "$SESS_LIST"; __cache_clear_dirty
  fi
}

# --------- MENU (sessions) ---------
__menu_sessions(){
  __term_setup; __clrscr; : "${FILTER_NS:=}"; : "${FORCE_REFRESH:=}"
  __list_sessions; [ -n "$SESS_LIST" ] || { __term_restore; die "Tidak ada sesi aktif."; }
  count=0; for _ in $SESS_LIST; do count=$((count+1)); done; idx=1
  while :; do
    __clrscr
    if [ -n "$FILTER_NS" ]; then printf "== Pilih Sesi (↑/↓, Enter) ==  [filter: %s__ | r=refresh]\n\n" "$FILTER_NS"; else printf "== Pilih Sesi (↑/↓, Enter) ==  [: set filter, r refresh]\n\n"; fi
    i=1; for s in $SESS_LIST; do if [ $i -eq $idx ]; then __rev; printf " > %s\n" "$s"; __norm; else printf "   %s\n" "$s"; fi; i=$((i+1)); done
    printf "\nTips: ':' filter namespace, 'r' refresh cache, 'q' keluar\n"
    __read_key
    if is_key_up "$KEY"; then idx=$((idx-1)); [ $idx -lt 1 ] && idx=$count
    elif is_key_down "$KEY"; then idx=$((idx+1)); [ $idx -gt $count ] && idx=1
    else case "$KEY" in
      "")  chosen="$(__field "$SESS_LIST" "$idx")"; __term_restore; __menu_windows_actions "$chosen"; return ;;
      "$(printf 'r')") FORCE_REFRESH=1; __cache_mark_dirty; __list_sessions; count=0; for _ in $SESS_LIST; do count=$((count+1)); done; [ $idx -gt $count ] && idx=$count; FORCE_REFRESH= ;;
      "$(printf ':')") __show_cursor; [ -n "${OLD_STTY:-}" ] && stty "$OLD_STTY" 2>/dev/null || stty sane 2>/dev/null || true; printf "Namespace prefix (blank=ALL): "; IFS= read -r FILTER_NS; __term_setup; __list_sessions; count=0; for _ in $SESS_LIST; do count=$((count+1)); done; idx=1 ;;
      "$(printf 'q')") __term_restore; return ;;
    esac; fi
  done
}

# --------- MENU (windows/actions) ---------
__menu_windows_actions(){
  sess="$1"; __term_setup; __clrscr; __load_windows_from_cache "$sess"
  ACTS="Attach AttachToWindow Up DetachAll Kill LogON LogOFF Snapshot Send Restart Back"
  a_count=0; for _ in $ACTS; do a_count=$((a_count+1)); done; a_idx=1
  w_idx=1; w_count=0; for _ in $WIN_TITLES; do w_count=$((w_count+1)); done; [ $w_count -eq 0 ] && w_idx=0
  while :; do
    __clrscr
    printf "== Sesi: %s ==  (↑/↓ aksi, ←/→ window, Enter run, r refresh) \n\n" "$sess"
    printf "Actions:\n"; i=1; for a in $ACTS; do if [ $i -eq $a_idx ]; then __rev; printf " > %s\n" "$a"; __norm; else printf "   %s\n" "$a"; fi; i=$((i+1)); done
    printf "\nWindows (cache):\n"
    if [ $w_count -eq 0 ]; then printf "  (cache tidak ada) — aksi level sesi saja\n"
    else
      i=1
      for t in $WIN_TITLES; do
        h="$(__field "$WIN_HEALTH" "$i" || printf "")"; [ -z "$h" ] && h="-"
        if [ $i -eq $w_idx ]; then __rev; printf " > %-16s [%s]\n" "$t" "$h"; __norm; else printf "   %-16s [%s]\n" "$t" "$h"; fi
        cmd_var="CMD_$i"; eval cmd_val=\${$cmd_var:-""}; [ -n "$cmd_val" ] && printf "     cmd: %s\n" "$cmd_val"
        i=$((i+1))
      done
    fi
    printf "\nTips: 'r' refresh, 'q' keluar, 'Back' kembali\n"
    __read_key
    if is_key_up "$KEY"; then a_idx=$((a_idx-1)); [ $a_idx -lt 1 ] && a_idx=$a_count
    elif is_key_down "$KEY"; then a_idx=$((a_idx+1)); [ $a_idx -gt $a_count ] && a_idx=1
    elif is_key_right "$KEY"; then [ $w_count -gt 0 ] && { w_idx=$((w_idx+1)); [ $w_idx -gt $w_count ] && w_idx=1; }
    elif is_key_left "$KEY"; then [ $w_count -gt 0 ] && { w_idx=$((w_idx-1)); [ $w_idx -lt 1 ] && w_idx=$w_count; }
    else case "$KEY" in
      "$(printf 'r')") __load_windows_from_cache "$sess"; w_count=0; for _ in $WIN_TITLES; do w_count=$((w_count+1)); done; [ $w_count -eq 0 ] && w_idx=0 || { [ $w_idx -gt $w_count ] && w_idx=$w_count; } ;;
      "") action="$(__field "$ACTS" "$a_idx")"
          case "$action" in
            Attach) __term_restore; "$SCREEN" -r "$sess"; return ;;
            AttachToWindow) if [ $w_count -gt 0 ]; then win="$(__field "$WIN_TITLES" "$w_idx")"; "$SCREEN" -S "$sess" -p "$win" -X select .; __term_restore; "$SCREEN" -r "$sess"; return; fi ;;
            Up) __term_restore; base="$(base_from_actual "$sess")"; "$0" up "$base"; __cache_mark_dirty; return ;;
            DetachAll) "$SCREEN" -S "$sess" -X detach ;;
            Kill) "$SCREEN" -S "$sess" -X quit; __cache_mark_dirty; __term_restore; note "Sesi dimatikan: $sess"; return ;;
            LogON) if [ $w_count -gt 0 ]; then win="$(__field "$WIN_TITLES" "$w_idx")"; file="$HOME/${sess}.${win}.log"; "$SCREEN" -S "$sess" -p "$win" -X logfile "$file"; "$SCREEN" -S "$sess" -p "$win" -X log on; fi ;;
            LogOFF) if [ $w_count -gt 0 ]; then win="$(__field "$WIN_TITLES" "$w_idx")"; "$SCREEN" -S "$sess" -p "$win" -X log off; fi ;;
            Snapshot) if [ $w_count -gt 0 ]; then win="$(__field "$WIN_TITLES" "$w_idx")"; file="$HOME/${sess}.${win}.hardcopy.txt"; "$SCREEN" -S "$sess" -p "$win" -X hardcopy "$file"; fi ;;
            Send) if [ $w_count -gt 0 ]; then win="$(__field "$WIN_TITLES" "$w_idx")"; __show_cursor; [ -n "${OLD_STTY:-}" ] && stty "$OLD_STTY" 2>/dev/null || stty sane 2>/dev/null || true; printf "Paste skrip untuk '%s' (Ctrl+D untuk kirim):\n" "$win"; CR="$(printf '\015')"; while IFS= read -r line; do "$SCREEN" -S "$sess" -p "$win" -X stuff "$line"; "$SCREEN" -S "$sess" -p "$win" -X stuff "$CR"; done; __term_setup; __load_windows_from_cache "$sess"; fi ;;
            Restart) if [ $w_count -gt 0 ]; then win="$(__field "$WIN_TITLES" "$w_idx")"; __term_restore; "$0" restart-window "$(base_from_actual "$sess")" "$win"; return; fi ;;
            Back) __term_restore; __menu_sessions; return ;;
          esac ;;
      "$(printf 'q')") __term_restore; return ;;
    esac; fi
  done
}

cmd_menu(){ require_screen; __menu_sessions; }

# ---------- Live status dashboard (manual refresh) ----------
cmd_top(){
  require_screen
  while :; do
    __clrscr
    printf "SESSION              WINDOW           STATUS    LOG     CMD\n"
    printf "---------------------------------------------------------------\n"
    SESS_LIST=""; __cache_read_sessions
    [ -n "$SESS_LIST" ] || printf "(Cache kosong. Tekan r untuk refresh)\n"
    for s in $SESS_LIST; do
      __load_windows_from_cache "$s"
      i=1; wcount=0; for _ in $WIN_TITLES; do wcount=$((wcount+1)); done
      if [ $wcount -eq 0 ]; then printf "%-20s %-15s %-8s %-7s %s\n" "$s" "-" "-" "-" "-"
      else
        for t in $WIN_TITLES; do h="$(__field "$WIN_HEALTH" "$i" || printf "-")"; eval "cmdv=\${CMD_$i:-}"; printf "%-20s %-15s %-8s %-7s %s\n" "$s" "$t" "$h" "-" "$cmdv"; i=$((i+1)); s=""; done
      fi
    done
    printf "\nPress r=refresh, q=quit\n"
    __read_key
    case "$KEY" in "$(printf 'q')") break ;; "$(printf 'r')") continue ;; *) continue ;; esac
  done
}

# ---------- restart / recover / apply-all / remote / profile ----------
cmd_restart_window(){
  require_screen; sess_in="$1"; title="$2"; sess="$(sess_actual "$sess_in")"; cfg="$(cache_path "$(base_from_actual "$sess")")"
  [ -f "$cfg" ] || die "cache tidak ditemukan untuk sesi '$sess_in'"
  if is_protected "$sess" "$title"; then die "Window '$title' dilindungi (PROTECT=yes)"; fi
  win_exists "$sess" "$title" && "$SCREEN" -S "$sess" -p "$title" -X kill || true
  . "$cfg"
  i=1; found=0
  while [ "$i" -le "${WIN_COUNT:-0}" ]; do
    eval "t=\${WIN${i}_TITLE:-}"
    if [ "$t" = "$title" ]; then
      eval "dir=\${WIN${i}_DIR:-$HOME}"; eval "envs=\${WIN${i}_ENV:-}"; eval "envf=\${WIN${i}_ENV_FILE:-}"
      eval "pre_host=\${WIN${i}_PRE_HOST:-}"; eval "pre=\${WIN${i}_PRE:-}"; eval "cmd=\${WIN${i}_CMD:-}"; eval "post=\${WIN${i}_POST:-}"; eval "post_host=\${WIN${i}_POST_HOST:-}"
      eval "logf=\${WIN${i}_LOG:-}"; eval "respawn=\${WIN${i}_RESPAWN:-no}"
      create_or_update_window "$sess" "$title" "$dir" "$envs" "$envf" "$pre_host" "$pre" "$cmd" "$post" "$post_host" "$logf" "$respawn"
      found=1; break
    fi
    i=$((i+1))
  done
  [ "$found" -eq 1 ] || die "window '$title' tidak ditemukan di cache"
  note "window '$title' direstart"
}

cmd_recover(){ sess_in="$1"; require_screen; cfg="$(load_cached_or_die "$sess_in")"; cmd_apply "$cfg"; note "recover selesai"; }
cmd_apply_all(){ dir="$1"; [ -d "$dir" ] || die "folder tidak ditemukan: $dir"; for f in "$dir"/*.cfg; do [ -f "$f" ] || continue; note "==> apply $f"; cmd_apply "$f"; done; }
cmd_remote(){
  remote="$1"; cfg="$2"; [ -f "$cfg" ] || die "config tidak ditemukan: $cfg"; cmd_exists ssh || die "ssh tidak tersedia"
  if cmd_exists scp; then rpath="/tmp/screenadm.$$.cfg"; scp "$cfg" "${remote}:${rpath}"; else die "scp tidak tersedia"; fi
  ssh "$remote" "bash -lc 'screenadm apply ${rpath} || sh screenadm apply ${rpath} || /bin/sh screenadm apply ${rpath}'" || die "remote apply gagal"
}
cmd_profile(){
  sess_in="$1"; title="$2"; sess="$(sess_actual "$sess_in")"; cfg="$(cache_path "$sess_in")"; [ -f "$cfg" ] || die "cache tidak ditemukan"; . "$cfg"
  i=1; while [ "$i" -le "${WIN_COUNT:-0}" ]; do eval "t=\${WIN${i}_TITLE:-}"; eval "pc=\${WIN${i}_PROFILE:-}"; if [ "$t" = "$title" ]; then [ -n "$pc" ] || die "WIN${i}_PROFILE tidak diset untuk '$title'"; exec sh -lc "$pc"; fi; i=$((i+1)); done
  die "window '$title' tidak ada di cache"
}

# ---------- parse args & main ----------
[ $# -ge 1 ] || { usage; exit 2; }
if [ "${1-}" = "--ns" ]; then [ $# -ge 3 ] || die "pakai: screenadm --ns PREFIX <perintah> ..."; set_ns "$2"; shift 2; fi
sub="$1"; shift

case "$sub" in
  apply)          [ $# -ge 1 ] || die "pakai: screenadm [--ns P] apply [--dry-run] <config.sh>"; cmd_apply "$@" ;;
  up)             [ $# -eq 1 ] || die "pakai: screenadm [--ns P] up <session>"; cmd_up "$1" ;;
  down)           [ $# -eq 1 ] || die "pakai: screenadm [--ns P] down <session>"; cmd_down "$1" ;;
  status)         [ $# -le 1 ] || die "pakai: screenadm [--ns P] status [session]"; cmd_status "${1-}" ;;
  attach)         [ $# -eq 1 ] || die "pakai: screenadm [--ns P] attach <session>"; cmd_attach "$1" ;;
  send)           [ $# -eq 2 ] || die "pakai: screenadm [--ns P] send <session> <title>"; cmd_send "$1" "$2" ;;
  log-on)         [ $# -ge 2 ] || die "pakai: screenadm [--ns P] log-on <session> <title> [file]"; cmd_log_on "$1" "$2" "${3-}" ;;
  log-off)        [ $# -eq 2 ] || die "pakai: screenadm [--ns P] log-off <session> <title>"; cmd_log_off "$1" "$2" ;;
  share)          [ $# -eq 2 ] || die "pakai: screenadm [--ns P] share <session> <user>"; cmd_share "$1" "$2" ;;
  unshare)        [ $# -eq 2 ] || die "pakai: screenadm [--ns P] unshare <session> <user>"; cmd_unshare "$1" "$2" ;;
  snapshot)       [ $# -ge 2 ] || die "pakai: screenadm [--ns P] snapshot <session> <title> [file]"; cmd_snapshot "$1" "$2" "${3-}" ;;
  export)         [ $# -eq 1 ] || die "pakai: screenadm [--ns P] export <session>"; cmd_export "$1" ;;
  template)       [ $# -eq 1 ] || die "pakai: screenadm template <minimal|rest|queue|fullstack>"; cmd_template "$1" ;;
  menu)           cmd_menu ;;
  restart-window) [ $# -eq 2 ] || die "pakai: screenadm restart-window <session> <title>"; cmd_restart_window "$1" "$2" ;;
  recover)        [ $# -eq 1 ] || die "pakai: screenadm recover <session>"; cmd_recover "$1" ;;
  apply-all)      [ $# -eq 1 ] || die "pakai: screenadm apply-all <dir>"; cmd_apply_all "$1" ;;
  remote)         [ $# -eq 2 ] || die "pakai: screenadm remote <user@host> <config.sh>"; cmd_remote "$1" "$2" ;;
  profile)        [ $# -eq 2 ] || die "pakai: screenadm profile <session> <title>"; cmd_profile "$1" "$2" ;;
  top)            cmd_top ;;
  help|-h|--help) usage ;;
  *) die "perintah tidak dikenal: $sub";;
esac
