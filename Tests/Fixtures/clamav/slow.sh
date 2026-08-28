#!/bin/sh
# Fake clamscan: hangs well beyond any short test timeout, so the runner must
# time it out. It BACKGROUNDS a `sleep` child and records both its own PID and
# the child's PID to the file named by $1. The test reads that file and asserts
# BOTH processes are dead afterwards — which is only true if the whole process
# GROUP was killed, not merely the parent. If the runner killed only the direct
# child, the backgrounded sleep would outlive the timeout and the test fails.
sleep 30 &
child=$!
if [ -n "$1" ]; then
  echo "$$ $child" > "$1"
fi
echo "scanning..."
wait "$child"
exit 0
