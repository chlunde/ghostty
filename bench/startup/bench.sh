#!/bin/bash
# usage: bench.sh <ghostty-binary> <label> [tabs] [fake|shell] [extra config lines...]
set -u
B=$1; L=$2; N=${3:-15}; MODE=${4:-fake}; shift 4 2>/dev/null || shift $#
CLASS=com.example.ghosttybench.$L
DIR=/tmp/ghostty-bench/run-$L-$MODE; rm -rf "$DIR"; mkdir -p "$DIR"
cat > "$DIR/config" <<CFG
gtk-single-instance = true
confirm-close-surface = false
quit-after-last-window-closed = true
window-save-state = never
CFG
if [ "$MODE" = fake ]; then
  printf '#!/bin/sh\nprintf "\\033]133;A\\007$ "\nexec sleep infinity\n' > "$DIR/fakesh"; chmod +x "$DIR/fakesh"
  printf 'shell-integration = none\ncommand = %s\n' "$DIR/fakesh" >> "$DIR/config"
fi
for l in "$@"; do echo "$l" >> "$DIR/config"; done
GHOSTTY_LOG=stderr "$B" --config-default-files=false --config-file="$DIR/config" --class="$CLASS" > "$DIR/log" 2>&1 &
pid=$!
sleep 3
for i in $(seq "$N"); do "$B" +new-tab --class="$CLASS" >>"$DIR/newtab.log" 2>&1; echo "rc=$?" >> "$DIR/newtab.log"; sleep 0.8; done
sleep 1
systemd-cgls --user --no-pager 2>/dev/null | grep -c "ghostty-.*scope\|app-.*ghostty.*scope" > "$DIR/scopes" || true
kill $pid; wait $pid 2>/dev/null
python3 -I "$(dirname "$0")/parse.py" "$L/$MODE" "$DIR/log"
