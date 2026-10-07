#!/bin/zsh
# Measures the app's CPU on each screen (NN_SELFTEST_PERF), against the test server (8765, music_test), muted.
# Each phase: 1 s to settle, then 10 one-second `top` samples; prints the median and the mean. Build first.
#   mac/Scripts/perf.sh                                   every phase
#   PHASES="main window|Now Playing alone" mac/Scripts/perf.sh
#   MOTION=1 mac/Scripts/perf.sh                          the moving background moves even with the window behind
#   PHASES="act: typing a search" mac/Scripts/perf.sh     one interaction (all of them start with "act: ")
# Extra arguments go to the app (e.g. -animateBackdrop YES).
cd "$(dirname "$0")/.." || exit 1
port=${NN_TEST_PORT:-8765}     # another port when 8765 is taken (NN_TEST_PORT=8766)
# a server already on the test port is not ours: it may be your own app's, holding your library (7 Oct). Refuse.
busy=$(lsof -nP -tiTCP:$port -sTCP:LISTEN 2>/dev/null | head -1)
if [ -n "$busy" ]; then echo "REFUSING: something already listens on $port (pid $busy, $(ps -o comm= -p $busy | xargs basename)). Quit it first; it may be your app's server."; exit 1; fi
log=${TMPDIR:-/tmp}/nononsense-perf.log; : > $log
env ${PHASES:+NN_SELFTEST_PERF_PHASES=$PHASES} ${MOTION:+NN_FORCE_MOTION=1} NN_SELFTEST_PERF="${SONG:-Les Childish Gambino}" NN_SELFTEST_PERF_HOLD=12 \
  DATABASE_URL=postgresql:///music_test perl -e 'alarm 300; exec @ARGV' build/Build/Products/Debug/NoNonsense.app/Contents/MacOS/NoNonsense \
  -serverURL http://127.0.0.1:$port -discordEnabled NO -ApplePersistenceIgnoreState YES "$@" > $log 2>&1 &
for i in $(seq 1 90); do grep -q "perf: phase" $log && break; sleep 1; done
pid=$(pgrep -nx NoNonsense); seen=0
while true; do
  n=$(grep -c "perf: phase" $log); if grep -q "perf: done\|refusing\|needed" $log && [ $n -le $seen ]; then break; fi
  if [ $n -gt $seen ]; then
    seen=$n; name=$(grep "perf: phase" $log | sed -n "${n}p" | sed 's/.*perf: phase //')
    top -l 11 -s 1 -pid $pid -stats pid,cpu 2>/dev/null | awk -v p=$pid '$1==p {print $2}' | tail -10 | sort -n | tr '\n' ' ' \
      | awk -v l="$name" '{s=0; for(i=1;i<=NF;i++) s+=$i; printf "%-36s median %5.1f%%  mean %5.1f%%\n", l, $(int((NF+1)/2)), (NF ? s/NF : 0)}'
  else sleep 0.5; fi
done
grep -E "refusing|needed" $log
grep "time(s)" $log | sed "s/.*perf: /  done: /"          # what each interaction phase really did
wait 2>/dev/null
left=$(lsof -nP -tiTCP:$port -sTCP:LISTEN 2>/dev/null); [ -n "$left" ] && echo "LEAK: a test server is still on $port (pid $left)"
exit 0
