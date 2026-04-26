#!/bin/sh
# screenadm — Big manager untuk GNU screen (POSIX sh only)
# Fitur:
# - Declarative apply via config (multi-window, TITLE/DIR/ENV/PRE/CMD/POST/LOG)
# - Idempotent (cek sesi/window sebelum buat)
# - Namespace (--ns atau NAMESPACE= di config) → sesi nyata: "<ns>__<SESSION>"
# - Hooks APPLY_PRE/APPLY_POST (luar screen)
# - Perintah: apply, up, down, status, attach, send, log-on/off, share/unshare, snapshot, export, template
# - Dashboard interaktif: menu (arrow ↑/↓/←/→, Enter), filter namespace (":"), Send multiline, refresh "r"
# Batasan: tidak gunakan grep/sed/awk/tput/sleep/md5sum, dsb. Hanya /bin/sh, screen, stty, cp, cat, rm, printf, read.

set -eu

SCREEN="${SCREEN_BIN:-screen}"
STATE_DIR="${HOME}/.screenadm"
[ -d "$STATE_DIR" ] || mkdir -p "$STATE_DIR"

# ========== util dasar ==========
die(){ printf "%s\n" "$*" >&2; exit 1; }
note(){ printf "%s\n" "$*" >&2; }
require_screen(){ command -v "$SCREEN" >/dev/null 2>&1 || die "screen tidak ditemukan."; }

usage(){
cat <<'USAGE'
pakai: screenadm [--ns PREFIX] <perintah> [arg...]

Perintah:
  apply <config.sh>        Terapkan konfigurasi (buat/isi sesi & windows)
  up <session>             Pastikan sesi aktif; pakai cache apply terakhir
  down <session>           Matikan sesi (quit)
  status [session]         Cek sesi & windows (pakai cache bila ada)
  attach <session>         Attach ke sesi
  send <session> <title>   Kirim STDIN (multi-baris) ke window bertitle
  log-on <session> <title> [file]  Aktifkan logging window
  log-off <session> <title>        Matikan logging window
  share <session> <user>   Multiuser ON & beri akses user
  unshare <session> <user> Cabut akses user
  snapshot <session> <title> [file] Hardcopy buffer window ke file
  export <session>         Cetak template config dari cache sesi
  template <kind>          Cetak template config bawaan (minimal|rest|queue|fullstack)
  menu                     Dashboard interaktif (panah, filter ":", refresh "r")

Opsi global:
  --ns PREFIX              Namespacing nama sesi (prefix otomatis)

Konfigurasi (shell, di-source):
  NAMESPACE="dev"          # opsional; override --ns jika diset di config
  SESSION="appstack"
  WIN_COUNT=2
  APPLY_PRE='echo "pre-apply..."'     # opsional (luar screen)
  APPLY_POST='echo "post-apply"'      # opsional (luar screen)

  # Window 1
  WIN1_TITLE="api"
  WIN1_DIR="$HOME/app"
  WIN1_ENV="PORT=3000 NODE_ENV=production"
  WIN1_PRE='echo "[api] boot..."'     # opsional (di dalam window)
  WIN1_CMD='node server.js'
  WIN1_POST='echo "[api] up"; date'   # opsional (di dalam window)
  WIN1_LOG="$HOME/logs/api.log"       # opsional

  # Window 2
  WIN2_TITLE="worker"
  WIN2_DIR="$HOME/app"
  WIN2_ENV=""
  WIN2_CMD='sh -lc "./worker.sh --concurrency 4"'

Catatan:
- PRE/CMD/POST dieksekusi berurutan di DALAM window: cd; ENV; PRE; CMD; POST.
- Idempotent: window TITLE sama tidak diduplikasi.
- Namespace: nama sesi aktual = "<ns>__<SESSION>" bila ns ada.
USAGE
}

# ========== namespace & cache ==========
NS_PREFIX=""
set_ns(){ NS_PREFIX="$1"; }
ns_key(){ if [ -n "$NS_PREFIX" ]; then printf "%s__%s" "$NS_PREFIX" "$1"; else printf "%s" "$1"; fi; }
sess_actual(){ ns_key "$1"; }
cache_path(){ printf "%s/%s.last.cfg" "$STATE_DIR" "$(ns_key "$1")"; }
cache_config(){ cp "$2" "$(cache_path "$1")"; }
load_cached_or_die(){ p="$(cache_path "$1")"; [ -f "$p" ] || die "Cache config tidak ada untuk sesi '$1'. Jalankan apply dulu."; printf "%s\n" "$p"; }

# ========== screen helpers ==========
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

create_or_update_window(){
  sess="$1"; title="$2"; wdir="$3"; wenv="$4"; wpre="${5-}"; wcmd="$6"; wpost="${7-}"; wlog="${8-}"
  [ -n "$wdir" ] || wdir="$HOME"

  if win_exists "$sess" "$title"; then
    note "window '$title' sudah ada — skip buat"
    return 0
  fi

  [ -n "$wcmd" ] || die "CMD kosong untuk window '$title'"

  chain="cd \"${wdir}\"; ${wenv} ; ${wpre:-:} ; ${wcmd} ; ${wpost:-:}"

  if [ -n "$wlog" ]; then
    "$SCREEN" -S "$sess" -X logfile "$wlog"
    "$SCREEN" -S "$sess" -X log on
  fi

  "$SCREEN" -S "$sess" -X screen -t "$title" sh -lc "$chain"
  note "window '$title' dibuat"
}

# ========== commands ==========
cmd_apply(){
  cfg="$1"; [ -f "$cfg" ] || die "config tidak ditemukan: $cfg"
  # shellcheck source=/dev/null
  . "$cfg"

  if [ -z "$NS_PREFIX" ] && [ -n "${NAMESPACE:-}" ]; then NS_PREFIX="$NAMESPACE"; fi
  [ -n "${SESSION:-}" ] || die "Config: SESSION kosong"
  [ -n "${WIN_COUNT:-}" ] || die "Config: WIN_COUNT kosong"

  require_screen
  sess="$(sess_actual "$SESSION")"

  [ -n "${APPLY_PRE:-}" ] && sh -lc "${APPLY_PRE}" || true
  ensure_session "$sess"

  i=1
  while [ "$i" -le "${WIN_COUNT:-0}" ]; do
    eval "title=\${WIN${i}_TITLE:-}"
    eval "dir=\${WIN${i}_DIR:-$HOME}"
    eval "envs=\${WIN${i}_ENV:-}"
    eval "pre=\${WIN${i}_PRE:-}"
    eval "cmd=\${WIN${i}_CMD:-}"
    eval "post=\${WIN${i}_POST:-}"
    eval "logf=\${WIN${i}_LOG:-}"

    [ -n "$title" ] || die "WIN${i}_TITLE kosong"
    create_or_update_window "$sess" "$title" "$dir" "$envs" "$pre" "$cmd" "$post" "$logf"
    i=$((i+1))
  done

  cache_config "$SESSION" "$cfg"
  [ -n "${APPLY_POST:-}" ] && sh -lc "${APPLY_POST}" || true

  note "apply selesai untuk sesi '$(sess_actual "$SESSION")'"
}

cmd_up(){
  sess_in="$1"
  require_screen
  cfg="$(load_cached_or_die "$sess_in")"
  cmd_apply "$cfg"
}

cmd_down(){
  sess_in="$1"; require_screen
  sess="$(sess_actual "$sess_in")"
  sess_exists "$sess" || die "sesi '$sess' tidak ada"
  "$SCREEN" -S "$sess" -X quit || true
  __cache_mark_dirty
  note "sesi '$sess' dimatikan"
}

cmd_status(){
  require_screen
  if [ $# -eq 0 ]; then
    $SCREEN -ls || true
  else
    sess_in="$1"; sess="$(sess_actual "$sess_in")"
    if sess_exists "$sess"; then
      note "sesi '$sess': ADA"
      cfg="$(cache_path "$sess_in")"
      if [ -f "$cfg" ]; then
        . "$cfg"
        i=1
        while [ "$i" -le "${WIN_COUNT:-0}" ]; do
          eval "t=\${WIN${i}_TITLE:-}"
          if [ -n "$t" ]; then
            if win_exists "$sess" "$t"; then note "  - '$t': ADA"; else note "  - '$t': TIDAK ADA"; fi
          fi
          i=$((i+1))
        done
      fi
    else
      note "sesi '$sess': TIDAK ADA"; exit 1
    fi
  fi
}

cmd_attach(){ require_screen; "$SCREEN" -r "$(sess_actual "$1")"; }

cmd_send(){
  require_screen
  sess="$(sess_actual "$1")"; title="$2"
  win_exists "$sess" "$title" || die "window '$title' tidak ada di sesi '$sess'"
  CR="$(printf '\015')"
  while IFS= read -r line; do
    "$SCREEN" -S "$sess" -p "$title" -X stuff "$line"
    "$SCREEN" -S "$sess" -p "$title" -X stuff "$CR"
  done
}

cmd_log_on(){
  require_screen
  sess="$(sess_actual "$1")"; title="$2"; file="${3:-}"
  win_exists "$sess" "$title" || die "window '$title' tidak ada"
  [ -n "$file" ] || file="$HOME/$(ns_key "$1").${title}.log"
  "$SCREEN" -S "$sess" -p "$title" -X logfile "$file"
  "$SCREEN" -S "$sess" -p "$title" -X log on
  note "log ON '$sess/$title' -> $file"
}

cmd_log_off(){
  require_screen
  sess="$(sess_actual "$1")"; title="$2"
  win_exists "$sess" "$title" || die "window '$title' tidak ada"
  "$SCREEN" -S "$sess" -p "$title" -X log off
  note "log OFF '$sess/$title'"
}

cmd_share(){
  require_screen
  sess="$(sess_actual "$1")"; user="$2"
  "$SCREEN" -S "$sess" -X multiuser on
  "$SCREEN" -S "$sess" -X acladd "$user"
  note "multiuser ON; akses diberikan ke '$user'"
}

cmd_unshare(){
  require_screen
  sess="$(sess_actual "$1")"; user="$2"
  "$SCREEN" -S "$sess" -X acldel "$user" || true
  note "akses user '$user' dicabut"
}

cmd_snapshot(){
  require_screen
  sess="$(sess_actual "$1")"; title="$2"; file="${3:-}"
  win_exists "$sess" "$title" || die "window '$title' tidak ada"
  [ -n "$file" ] || file="$HOME/$(ns_key "$1").${title}.hardcopy.txt"
  "$SCREEN" -S "$sess" -p "$title" -X hardcopy "$file"
  note "snapshot buffer -> $file"
}

cmd_export(){
  require_screen
  sess_in="$1"; cfg="$(cache_path "$sess_in")"
  if [ -f "$cfg" ]; then cat "$cfg"; else
    cat <<EOF
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
# NAMESPACE opsional
# NAMESPACE="dev"
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
    *)
      die "unknown template kind: $kind (pilih: minimal|rest|queue|fullstack)"
    ;;
  esac
}

# ========== helper umum untuk menu ==========
__clrscr(){ printf '\033[2J\033[H'; }          # clear + home
__hide_cursor(){ printf '\033[?25l'; }
__show_cursor(){ printf '\033[?25h'; }
__rev(){ printf '\033[7m'; }                   # reverse video
__norm(){ printf '\033[0m'; }                  # reset attrs

OLD_STTY=""

__term_setup(){
  OLD_STTY="$(stty -g 2>/dev/null || printf '')"
  stty -echo -icanon min 1 time 0 2>/dev/null || true
  __hide_cursor
  trap '__term_restore; exit' INT TERM
}
__term_restore(){
  if [ -n "${OLD_STTY:-}" ]; then
    stty "$OLD_STTY" 2>/dev/null || stty sane 2>/dev/null || true
  else
    stty sane 2>/dev/null || true
  fi
  __show_cursor
}

# baca 1 key; kalau ESC, baca 2 byte lanjutan (arrow: ESC [ A/B/C/D)
__read_key() {
  KEY=""
  KEY="$(dd bs=1 count=1 2>/dev/null)"
  if [ "$KEY" = "$(printf '\033')" ]; then
    k1="$(dd bs=1 count=1 2>/dev/null)"
    k2="$(dd bs=1 count=1 2>/dev/null)"
    KEY="$KEY$k1$k2"
  fi
}

# ambil field ke-n dari string spasi
__field(){
  s="$1"; n="$2"; i=1
  set -- $s
  for v do
    [ $i -eq "$n" ] && { printf "%s" "$v"; return 0; }
    i=$((i+1))
  done
  return 1
}

# base name dari sesi aktual "ns__base" -> "base"
__base_from_actual(){
  case "$1" in
    *__*) printf "%s\n" "${1#*__}" ;;
    *)    printf "%s\n" "$1" ;;
  esac
}

# muat windows dari cache; set WIN_TITLES & CMD_i & STAT_i
__load_windows_from_cache(){
  sess_actual="$1"
  base="$(__base_from_actual "$sess_actual")"
  cfg="$(cache_path "$base")"

  WIN_TITLES=""
  if [ -f "$cfg" ]; then
    # shellcheck source=/dev/null
    . "$cfg"
    i=1
    while [ "$i" -le "${WIN_COUNT:-0}" ]; do
      eval "t=\${WIN${i}_TITLE:-}"
      eval "c=\${WIN${i}_CMD:-}"
      if [ -n "$t" ]; then
        WIN_TITLES="${WIN_TITLES}${WIN_TITLES:+ }$t"
        eval "CMD_$i=\$c"
      fi
      i=$((i+1))
    done
  fi

  idx=1
  for t in $WIN_TITLES; do
    if win_exists "$sess_actual" "$t"; then
      eval "STAT_$idx=ADA"
    else
      eval "STAT_$idx=TIDAK"
    fi
    idx=$((idx+1))
  done
}

# daftar sesi aktif dengan filter namespace opsional FILTER_NS (prefix)
# (tanpa pipeline subshell agar variabel tetap di parent)
# ===== Cache helpers =====
CACHE_SESS_FILE="$STATE_DIR/cache.sessions"
CACHE_DIRTY_FILE="$STATE_DIR/cache.sessions.dirty"

__cache_mark_dirty(){ : > "$CACHE_DIRTY_FILE" 2>/dev/null || true; }
__cache_clear_dirty(){ rm -f "$CACHE_DIRTY_FILE" 2>/dev/null || true; }
__cache_is_dirty(){ [ -f "$CACHE_DIRTY_FILE" ]; }

# Tulis daftar sesi ke cache file
__cache_write_sessions(){
  # Arg1: SESS_LIST (spasi)
  printf "%s\n" "$1" > "$CACHE_SESS_FILE".tmp 2>/dev/null || true
  mv -f "$CACHE_SESS_FILE".tmp "$CACHE_SESS_FILE" 2>/dev/null || true
}

# Baca cache sesi → set SESS_LIST (spasi)
__cache_read_sessions(){
  if [ -f "$CACHE_SESS_FILE" ]; then
    SESS_LIST="$(tr '\n' ' ' < "$CACHE_SESS_FILE" 2>/dev/null | sed 's/[[:space:]]\+$//' 2>/dev/null || true)"
  else
    SESS_LIST=""
  fi
}
# Ambil daftar sesi aktif dengan cache. Respect FILTER_NS (prefix).
# Output global: SESS_LIST="sess1 sess2 ..."
__list_sessions(){
  # Jika cache ada & tidak dirty & tidak ganti filter → pakai cache
  if [ -z "${FORCE_REFRESH:-}" ] && ! __cache_is_dirty; then
    __cache_read_sessions
  else
    SESS_LIST=""
  fi

  # Kalau cache kosong atau FORCE_REFRESH, query sekali ke screen -ls
  if [ -z "$SESS_LIST" ] || [ -n "${FORCE_REFRESH:-}" ]; then
    tmpf="$STATE_DIR/.ls.$$"
    "$SCREEN" -ls 2>/dev/null > "$tmpf" || true

    SESS_LIST=""
    if [ -f "$tmpf" ]; then
      while IFS= read -r line; do
        case "$line" in
          "$(printf '\t')"*)
            set -- $line
            tok="$1"               # "PID.name"
            name="${tok#*.}"
            if [ -n "${FILTER_NS:-}" ]; then
              case "$name" in
                "${FILTER_NS}__"*) : ;;
                *) continue ;;
              esac
            fi
            case " $SESS_LIST " in
              *" $name "*) : ;;
              *) SESS_LIST="${SESS_LIST}${SESS_LIST:+ }$name" ;;
            esac
            ;;
        esac
      done < "$tmpf"
      rm -f "$tmpf" 2>/dev/null || true
    fi

    # Simpan ke cache & clear dirty flag
    __cache_write_sessions "$SESS_LIST"
    __cache_clear_dirty
  fi
}


# ---- View: Session Picker ----
__menu_sessions(){
  __term_setup
  __clrscr
  : "${FILTER_NS:=}"
  : "${FORCE_REFRESH:=}"  # kosong = pakai cache

  __list_sessions
  [ -n "$SESS_LIST" ] || { __term_restore; die "Tidak ada sesi aktif."; }

  count=0; for _ in $SESS_LIST; do count=$((count+1)); done
  idx=1

  while :; do
    __clrscr
    if [ -n "$FILTER_NS" ]; then
      printf "== Pilih Sesi (↑/↓, Enter) ==  [filter: %s__ | r=refresh cache]\n\n" "$FILTER_NS"
    else
      printf "== Pilih Sesi (↑/↓, Enter) ==  [: set filter, r refresh cache]\n\n"
    fi

    i=1
    for s in $SESS_LIST; do
      if [ $i -eq $idx ]; then __rev; printf " > %s\n" "$s"; __norm
      else printf "   %s\n" "$s"
      fi
      i=$((i+1))
    done

    printf "\nTips: ':' filter namespace, 'r' refresh cache, 'q' keluar\n"

    __read_key
    case "$KEY" in
      "$(printf '\033[A')") idx=$((idx-1)); [ $idx -lt 1 ] && idx=$count ;;
      "$(printf '\033[B')") idx=$((idx+1)); [ $idx -gt $count ] && idx=1 ;;
      "")  # Enter
        chosen="$(__field "$SESS_LIST" "$idx")"
        __term_restore
        __menu_windows_actions "$chosen"
        return
        ;;
      "$(printf 'r')")  # refresh cache: paksa rebuild & tandai dirty
        FORCE_REFRESH=1
        __cache_mark_dirty
        __list_sessions
        count=0; for _ in $SESS_LIST; do count=$((count+1)); done
        [ $idx -gt $count ] && idx=$count
        FORCE_REFRESH=
        ;;
      "$(printf ':')")  # set filter namespace
        __show_cursor
        if [ -n "${OLD_STTY:-}" ]; then stty "$OLD_STTY" 2>/dev/null || stty sane 2>/dev/null || true; fi
        printf "Namespace prefix (kosongkan untuk ALL): "
        IFS= read -r FILTER_NS
        __term_setup
        # ganti filter → jangan paksakan query kalau cache baru masih valid
        __list_sessions
        count=0; for _ in $SESS_LIST; do count=$((count+1)); done
        idx=1
        ;;
      "$(printf 'q')") __term_restore; return ;;
    esac
  done
}


# ---- View: Windows + Actions ----
__menu_windows_actions(){
  sess="$1"
  __term_setup
  __clrscr

  __load_windows_from_cache "$sess"

  ACTS="Attach AttachToWindow Up DetachAll Kill LogON LogOFF Snapshot Send Back"
  a_count=0; for _ in $ACTS; do a_count=$((a_count+1)); done
  a_idx=1

  w_idx=1
  w_count=0; for _ in $WIN_TITLES; do w_count=$((w_count+1)); done
  [ $w_count -eq 0 ] && w_idx=0

  while :; do
    __clrscr
    printf "== Sesi: %s ==  (↑/↓ aksi, ←/→ window, Enter run, r refresh) \n\n" "$sess"

    printf "Actions:\n"
    i=1
    for a in $ACTS; do
      if [ $i -eq $a_idx ]; then __rev; printf " > %s\n" "$a"; __norm
      else printf "   %s\n" "$a"
      fi
      i=$((i+1))
    done

    printf "\nWindows (cache):\n"
    if [ $w_count -eq 0 ]; then
      printf "  (cache tidak ada) — hanya aksi level sesi tersedia\n"
    else
      i=1
      for t in $WIN_TITLES; do
        stat_var="STAT_$i"; eval stat_val=\${$stat_var:-"?"}
        if [ $i -eq $w_idx ]; then __rev; printf " > %-16s [%s]\n" "$t" "$stat_val"; __norm
        else printf "   %-16s [%s]\n" "$t" "$stat_val"
        fi
        cmd_var="CMD_$i"; eval cmd_val=\${$cmd_var:-""}
        [ -n "$cmd_val" ] && printf "     cmd: %s\n" "$cmd_val"
        i=$((i+1))
      done
    fi

    printf "\nTips: 'r' refresh, 'q' keluar, 'Back' kembali\n"

    __read_key
    case "$KEY" in
      "$(printf '\033[A')") a_idx=$((a_idx-1)); [ $a_idx -lt 1 ] && a_idx=$a_count ;;
      "$(printf '\033[B')") a_idx=$((a_idx+1)); [ $a_idx -gt $a_count ] && a_idx=1 ;;
      "$(printf '\033[C')") [ $w_count -gt 0 ] && { w_idx=$((w_idx+1)); [ $w_idx -gt $w_count ] && w_idx=1; } ;;
      "$(printf '\033[D')") [ $w_count -gt 0 ] && { w_idx=$((w_idx-1)); [ $w_idx -lt 1 ] && w_idx=$w_count; } ;;
      "$(printf 'r')")      __load_windows_from_cache "$sess"; w_count=0; for _ in $WIN_TITLES; do w_count=$((w_count+1)); done; [ $w_count -eq 0 ] && w_idx=0 || { [ $w_idx -gt $w_count ] && w_idx=$w_count; } ;;
      "") # Enter
        action="$(__field "$ACTS" "$a_idx")"
        case "$action" in
          Attach)
            __term_restore; printf "Attach ke sesi: %s\n" "$sess"; "$SCREEN" -r "$sess"; return ;;
          AttachToWindow)
            if [ $w_count -gt 0 ]; then
              win="$(__field "$WIN_TITLES" "$w_idx")"
              "$SCREEN" -S "$sess" -p "$win" -X select .
              __term_restore; printf "Attach ke %s / window %s\n" "$sess" "$win"; "$SCREEN" -r "$sess"; return
            fi
            ;;
          Up)
            __term_restore; printf "Re-apply cache untuk sesi: %s\n" "$sess"
            base="$(__base_from_actual "$sess")"
            "$0" up "$base"
            __cache_mark_dirty   # sesi bisa berubah → tandai cache kotor
            return
            ;;
          DetachAll)
            "$SCREEN" -S "$sess" -X detach
            ;;
          Kill)
            "$SCREEN" -S "$sess" -X quit
            __cache_mark_dirty   # daftar sesi berubah
            __term_restore; printf "Sesi dimatikan: %s\n" "$sess"; return ;;
          LogON)
            if [ $w_count -gt 0 ]; then
              win="$(__field "$WIN_TITLES" "$w_idx")"
              file="$HOME/${sess}.${win}.log"
              "$SCREEN" -S "$sess" -p "$win" -X logfile "$file"
              "$SCREEN" -S "$sess" -p "$win" -X log on
            fi
            ;;
          LogOFF)
            if [ $w_count -gt 0 ]; then
              win="$(__field "$WIN_TITLES" "$w_idx")"
              "$SCREEN" -S "$sess" -p "$win" -X log off
            fi
            ;;
          Snapshot)
            if [ $w_count -gt 0 ]; then
              win="$(__field "$WIN_TITLES" "$w_idx")"
              file="$HOME/${sess}.${win}.hardcopy.txt"
              "$SCREEN" -S "$sess" -p "$win" -X hardcopy "$file"
            fi
            ;;
          Send)
            if [ $w_count -gt 0 ]; then
              win="$(__field "$WIN_TITLES" "$w_idx")"
              __show_cursor
              if [ -n "${OLD_STTY:-}" ] ; then stty "$OLD_STTY" 2>/dev/null || stty sane 2>/dev/null || true; fi
              printf "Paste skrip untuk dikirim ke window '%s' (Ctrl+D untuk kirim):\n" "$win"
              CR="$(printf '\015')"
              while IFS= read -r line; do
                "$SCREEN" -S "$sess" -p "$win" -X stuff "$line"
                "$SCREEN" -S "$sess" -p "$win" -X stuff "$CR"
              done
              __term_setup
              __load_windows_from_cache "$sess"
            fi
            ;;
          Back)
            __term_restore; __menu_sessions; return ;;
        esac
        ;;
      "$(printf 'q')") __term_restore; return ;;
    esac
  done
}


cmd_menu(){
  require_screen
  __menu_sessions
}

# ========== parse args & main ==========
[ $# -ge 1 ] || { usage; exit 2; }

if [ "${1-}" = "--ns" ]; then
  [ $# -ge 3 ] || die "pakai: screenadm --ns PREFIX <perintah> ..."
  set_ns "$2"
  shift 2
fi

sub="$1"; shift

case "$sub" in
  apply)    [ $# -eq 1 ] || die "pakai: screenadm [--ns P] apply <config.sh>"; cmd_apply "$1" ;;
  up)       [ $# -eq 1 ] || die "pakai: screenadm [--ns P] up <session>"; cmd_up "$1" ;;
  down)     [ $# -eq 1 ] || die "pakai: screenadm [--ns P] down <session>"; cmd_down "$1" ;;
  status)   [ $# -le 1 ] || die "pakai: screenadm [--ns P] status [session]"; cmd_status "${1-}" ;;
  attach)   [ $# -eq 1 ] || die "pakai: screenadm [--ns P] attach <session>"; cmd_attach "$1" ;;
  send)     [ $# -eq 2 ] || die "pakai: screenadm [--ns P] send <session> <title>"; cmd_send "$1" "$2" ;;
  log-on)   [ $# -ge 2 ] || die "pakai: screenadm [--ns P] log-on <session> <title> [file]"; cmd_log_on "$1" "$2" "${3-}" ;;
  log-off)  [ $# -eq 2 ] || die "pakai: screenadm [--ns P] log-off <session> <title>"; cmd_log_off "$1" "$2" ;;
  share)    [ $# -eq 2 ] || die "pakai: screenadm [--ns P] share <session> <user>"; cmd_share "$1" "$2" ;;
  unshare)  [ $# -eq 2 ] || die "pakai: screenadm [--ns P] unshare <session> <user>"; cmd_unshare "$1" "$2" ;;
  snapshot) [ $# -ge 2 ] || die "pakai: screenadm [--ns P] snapshot <session> <title> [file]"; cmd_snapshot "$1" "$2" "${3-}" ;;
  export)   [ $# -eq 1 ] || die "pakai: screenadm [--ns P] export <session>"; cmd_export "$1" ;;
  template) [ $# -eq 1 ] || die "pakai: screenadm template <minimal|rest|queue|fullstack>"; cmd_template "$1" ;;
  menu)     cmd_menu ;;
  help|-h|--help) usage ;;
  *) die "perintah tidak dikenal: $sub";;
esac
