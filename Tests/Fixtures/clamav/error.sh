#!/bin/sh
# Fake clamscan: an engine error. Writes to stderr and exits 2. Per the exit-code
# contract this MUST render as `failed`, NEVER as clean, even though no findings
# were printed on stdout.
echo "ERROR: Can't access file /Volumes/STICK" 1>&2
echo "LibClamAV Error: cli_loaddbdir(): No supported database files found" 1>&2
exit 2
