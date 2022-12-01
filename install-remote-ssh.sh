#!/bin/bash
SSHSER=$1
NM=capp_broadcast_detector
ssh $SSHSER \
    sudo curl "https://github.com/hightemp/$NM/releases/latest/download/$NM" \
    -O /usr/local/bin/$NM
ssh $SSHSER \
    sudo /usr/local/bin/$NM install-service