#!/bin/sh
#
# Package the ECU app for the Jeti App Store.
#
# The .lc files are compiled with Jeti Studio (they must match the Jeti Lua build), so this script
# only packages them. It refuses to run when a required .lc file is missing or older than its .lua
# source, because the source files are removed from the package and a stale .lc would silently
# ship old code.

set -eu
cd "$(dirname "$0")"

LIBS="alarmhelper drawhelper fuelhelper loadhelper loghelper sensorhelper tablehelper window1 window2"
problems=0

check() {
    if [ ! -f "$1.lc" ]; then
        echo "ERROR: $1.lc is missing - compile $1.lua with Jeti Studio"
        problems=1
    elif [ "$1.lua" -nt "$1.lc" ]; then
        echo "ERROR: $1.lc is older than $1.lua - recompile it with Jeti Studio"
        problems=1
    fi
}

check ecu
check ecu_16
for lib in $LIBS; do
    check "ecu/lib/$lib"
done

if [ "$problems" -ne 0 ]; then
    echo "Aborting, nothing was packaged."
    exit 1
fi

echo "Package LUA Apps for Jeti App Store"

#Remove old dir and archive
rm -rf ekdahl ekdahl.tar.bz2

#Create new dir
mkdir ekdahl

cp Apps.csv ekdahl/Apps.csv
cp logo.png ekdahl/logo.png

#Make ECU App for Jeti App Store
cp -R ecu ekdahl/ecu
cp ecu.lc ekdahl/ecu.lc
cp ecu_16.lc ekdahl/ecu_16.lc

#Remove unneccessary folders and files
rm -rf ekdahl/ecu/Arduino
rm -rf ekdahl/ecu/docs/screenshots
rm -f ekdahl/ecu/lib/*.lua
rm -f ekdahl/ecu/lib/fakesensor.lc

#Make SpeedWar App for Jeti App Store
#cp -r speedwar ekdahl/speedwar
#cp speedwar.lc ekdahl/speedwar.lc

#Make FullStop App for Jeti App Store
#cp -r fullstopp ekdahl/fullstopp
#cp fullstopp.lc ekdahl/fullstopp.lc

find ekdahl -name '.DS_Store' -type f -delete

tar -jcvf ekdahl.tar.bz2 ekdahl

#Remove temporary dir
rm -rf ekdahl
