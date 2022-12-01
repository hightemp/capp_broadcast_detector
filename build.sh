#!/bin/bash

nim c -f capp_broadcast_detector.nim

if [ "$?" != "0" ]; then
    echo "====================================================="
    echo "ERROR"
    echo
    exit 1
fi
