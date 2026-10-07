#!/bin/zsh
# Builds the app, then runs ONE self-test against the test server (port 8765, database music_test), muted, Discord off.
# Your own server (8000) and library are never used: scenarios that write refuse to run against port 8000.
#   mac/Scripts/selftest.sh NN_SELFTEST_QUEUE=1
#   mac/Scripts/selftest.sh NN_SELFTEST_PLAYLISTS=arijit
# Pictures (NN_SELFTEST_SNAP) go to $NN_SNAPS, default $TMPDIR/nononsense-snaps.
# The run starts only if the build succeeded, is stopped after 180 s if it hangs, and a test server left on 8765
# is reported as a LEAK and stopped (never anything on 8000). See docs/mac-app.md › Debug/SelfTest.swift.
cd "$(dirname "$0")/.." || exit 1
port=${NN_TEST_PORT:-8765}     # another port when 8765 is taken (NN_TEST_PORT=8766)
# a server already on the test port is not ours: it may be your own app's, holding your library (7 Oct). Refuse.
busy=$(lsof -nP -tiTCP:$port -sTCP:LISTEN 2>/dev/null | head -1)
if [ -n "$busy" ]; then echo "REFUSING: something already listens on $port (pid $busy, $(ps -o comm= -p $busy | xargs basename)). Quit it first; it may be your app's server."; exit 1; fi
snaps=${NN_SNAPS:-${TMPDIR:-/tmp}/nononsense-snaps}
out=$(xcodebuild -project NoNonsense.xcodeproj -scheme NoNonsense -configuration Debug -derivedDataPath build build 2>&1)
if ! print -r -- "$out" | grep -q "BUILD SUCCEEDED"; then print -r -- "$out" | grep -E "error:" | head -8; echo "BUILD FAILED"; exit 1; fi
echo "BUILD SUCCEEDED"
env "$@" NN_SELFTEST_SNAP=$snaps DATABASE_URL=postgresql:///music_test \
  perl -e 'alarm shift; exec @ARGV' 180 build/Build/Products/Debug/NoNonsense.app/Contents/MacOS/NoNonsense \
  -serverURL http://127.0.0.1:$port -discordEnabled NO -ApplePersistenceIgnoreState YES 2>/dev/null | grep "SELFTEST"
rc=${pipestatus[1]}
leftover=$(lsof -nP -iTCP:$port -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $2}' | sort -u; ps -axo pid,command | grep -E "[f]astapi (dev|run).*--port $port" | awk '{print $1}')
if [ -n "$leftover" ]; then
  echo "SELFTEST LEAK: a test server outlived the app on $port: $(echo $leftover | tr '\n' ' ')"
  for p in ${=leftover}; do kill $p 2>/dev/null; done; perl -e 'select(undef,undef,undef,1.5)'; for p in ${=leftover}; do kill -9 $p 2>/dev/null; done
fi
[ "$rc" = "142" ] && echo "SELFTEST TIMED OUT after 180 s"
exit 0
