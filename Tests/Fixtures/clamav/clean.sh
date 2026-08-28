#!/bin/sh
# Fake clamscan: a clean volume. Emits clamscan-format "OK" verdict lines and a
# summary, then exit 0 (the "no findings" contract). Arguments are ignored; the
# ScanProcessRunner points at this script and reads its canned stdout.
echo "/Volumes/STICK/readme.txt: OK"
echo "/Volumes/STICK/photo.jpg: OK"
echo ""
echo "----------- SCAN SUMMARY -----------"
echo "Scanned files: 2"
echo "Infected files: 0"
exit 0
