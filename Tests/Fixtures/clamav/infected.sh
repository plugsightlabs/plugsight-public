#!/bin/sh
# Fake clamscan: one infected file among clean ones. Emits a "<path>: <sig> FOUND"
# line in clamscan format and exit 1 (the "findings" contract).
echo "/Volumes/STICK/invoice.pdf: OK"
echo "/Volumes/STICK/payload.exe: Eicar-Test-Signature FOUND"
echo ""
echo "----------- SCAN SUMMARY -----------"
echo "Scanned files: 2"
echo "Infected files: 1"
exit 1
