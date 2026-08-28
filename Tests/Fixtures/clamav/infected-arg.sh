#!/bin/sh
# Fake clamscan that reports a FOUND verdict for a REAL file under the scanned
# path, so the orchestrator's quarantine move can be exercised end-to-end. The
# runner appends the volume path as the LAST argument; we echo a finding for
# "<volume>/payload.exe" and exit 1 (findings).
for last in "$@"; do :; done
echo "$last/payload.exe: Eicar-Test-Signature FOUND"
exit 1
