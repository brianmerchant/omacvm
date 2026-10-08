# omacvm features' checklist on the terminal (sourced; macOS's bash 3.2).
# It draws on the alternate screen, the whole screen from the top on every key
# and when the window changes size, one line per row: a row longer than the
# window is cut, never wrapped (a wrapped row moved every later redraw down a
# line, #292). A list taller than the window scrolls with the cursor.
#   cl_run N    N rows; the caller defines
#     cl_item I     sets CL_MARK ("[✓]", colours allowed, 3 columns) and
#                   CL_TEXT (the row, colours allowed) for row I
#     cl_detail I   the line under the list for the row under the cursor
#     cl_switch I   space on row I
#   CL_HEAD: lines above the list (the first one bold). CL_CUR: the row under
#   the cursor. Returns 0 for Return, 1 for q, 2 when the terminal is gone.
TTY=${TTY:-/dev/tty}
CL_HEAD=(); CL_CUR=0; CL_HH=0

# cl_fit TEXT WIDTH -> CL_OUT: TEXT, or its first WIDTH-1 characters and "…"
# without its colours when it is longer (WIDTH counts what shows, not the
# colour codes).
cl_fit() {
  local s=$1 w=$2 plain="" rest
  rest=$s
  while [[ $rest == *$'\033['* ]]; do
    plain+=${rest%%$'\033['*}; rest=${rest#*$'\033['}; rest=${rest#*m}
  done
  plain+=$rest
  if (( w < 2 )); then CL_OUT=""
  elif (( ${#plain} > w )); then CL_OUT="${plain:0:w-1}…"
  else CL_OUT=$s; fi
  return 0
}

cl_size() {   # -> CL_ROWS CL_COLS
  local sz
  sz=$(stty size < "$TTY" 2>/dev/null) || sz=""
  CL_ROWS=${sz% *}; CL_COLS=${sz#* }
  [[ $CL_ROWS =~ ^[0-9]+$ && $CL_ROWS -gt 0 ]] || CL_ROWS=24
  [[ $CL_COLS =~ ^[0-9]+$ && $CL_COLS -gt 0 ]] || CL_COLS=80
  return 0
}

cl_end() { trap - EXIT INT WINCH; eval "$CL_TRAPS"; cl_leave; }
cl_leave() { { printf '\033[?25h\033[?1049l' > "$TTY"; stty echo < "$TTY"; } 2>/dev/null || true; }

cl_draw() {
  local n=$1 top=$2 h=$3 i buf=$'\033[H' l ptr
  for ((i = 0; i < CL_HH; i++)); do
    cl_fit "${CL_HEAD[$i]}" $((CL_COLS - 1))
    if (( i == 0 )); then buf+=$'\033[1m'"$CL_OUT"$'\033[0m\033[K\r\n'; else buf+="$CL_OUT"$'\033[K\r\n'; fi
  done
  buf+=$'\033[K\r\n'
  for ((i = top; i < top + h && i < n; i++)); do
    cl_item "$i"
    ptr=" "; (( i == CL_CUR )) && ptr=$'\033[1m❯\033[0m'
    cl_fit "$CL_TEXT" $((CL_COLS - 9))
    buf+="  $ptr $CL_MARK $CL_OUT"$'\033[0m\033[K\r\n'
  done
  cl_fit "$(cl_detail "$CL_CUR")" $((CL_COLS - 5))
  buf+=$'    \033[2m'"$CL_OUT"$'\033[0m\033[K\r\n'
  l="↑/↓ move · space switch · Return apply · q quit"
  (( h < n )) && l="$((CL_CUR + 1))/$n · $l"
  cl_fit "$l" $((CL_COLS - 3))
  buf+="  $CL_OUT"$'\033[K\033[J'   # no newline after the last line: the screen must not scroll
  printf '%s' "$buf" > "$TTY"
}

cl_run() {
  local n=$1 k top=0 h fixed seen=""
  CL_WINCH=0
  # Back to the normal screen also on Ctrl-C or an error; the caller's traps
  # come back after.
  CL_TRAPS=$(trap -p EXIT INT WINCH)
  trap 'cl_leave' EXIT
  trap 'cl_leave; exit 130' INT
  trap 'CL_WINCH=1' WINCH
  printf '\033[?1049h\033[?25l\033[H\033[2J' > "$TTY"
  stty -echo < "$TTY" 2>/dev/null || true
  while :; do
    cl_size
    # The head (as much as leaves one row), a blank line, the detail and the
    # key line: never more lines than the window has, or it scrolls.
    CL_HH=${#CL_HEAD[@]}; (( CL_HH <= CL_ROWS - 4 )) || CL_HH=$(( CL_ROWS > 4 ? CL_ROWS - 4 : 0 ))
    fixed=$(( CL_HH + 3 ))
    h=$(( CL_ROWS - fixed )); (( h >= 1 )) || h=1
    (( CL_CUR < top )) && top=$CL_CUR
    (( CL_CUR >= top + h )) && top=$(( CL_CUR - h + 1 ))
    (( top > n - h )) && top=$(( n - h ))
    (( top >= 0 )) || top=0
    cl_draw "$n" "$top" "$h"
    seen="$CL_ROWS $CL_COLS"
    while :; do
      IFS= read -rsn1 -t 1 k < "$TTY" && break
      # A second without a key (bash 3.2 says 1 for that too, as for a
      # terminal that is gone): drawn again when the window changed size.
      { : < "$TTY"; } 2>/dev/null || { cl_end; return 2; }
      cl_size
      if (( CL_WINCH )) || [[ "$CL_ROWS $CL_COLS" != "$seen" ]]; then CL_WINCH=0; continue 2; fi
    done
    case $k in
      $'\033') IFS= read -rsn2 -t 1 k < "$TTY" || k=""
               case $k in '[A') (( CL_CUR > 0 )) && CL_CUR=$((CL_CUR - 1)) ;; '[B') (( CL_CUR < n - 1 )) && CL_CUR=$((CL_CUR + 1)) ;; esac ;;
      k) (( CL_CUR > 0 )) && CL_CUR=$((CL_CUR - 1)) ;;
      j) (( CL_CUR < n - 1 )) && CL_CUR=$((CL_CUR + 1)) ;;
      " ") cl_switch "$CL_CUR" ;;
      "") cl_end; return 0 ;;
      q) cl_end; return 1 ;;
    esac
  done
}
