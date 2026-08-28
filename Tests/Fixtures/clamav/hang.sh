#!/bin/sh
# Fake clamscan that HANGS with no output and no file writes, so a scan can be
# canceled mid-run. It ignores all arguments and sleeps well past any short test
# timeout; the ScanProcessRunner kills the process group on cancel, ending the
# scan `canceled`. (slow.sh is the process-GROUP-kill fixture; this one is for
# the plain cancel-a-running-scan path where argument handling must not matter.)
sleep 30
exit 0
