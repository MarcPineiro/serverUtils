#!/bin/sh
sudo rm -f /tmp/bootstrap.sh
sudo rm -f log.log
sudo ./autoprov-run.sh 2>&1 | sudo tee -a log.log
echo "------------------------------------------------------------------"
cat log.log