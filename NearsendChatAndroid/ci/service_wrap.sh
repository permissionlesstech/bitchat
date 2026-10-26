#!/bin/bash
# Runs the service check and reports its whole output as ONE annotation (GitHub shows only 10 per step).
bash ci/service_check.sh > service.log 2>&1; c=$?
msg=$(head -c 7000 service.log | sed 's/%/%25/g' | awk '{printf "%s%%0A", $0}')
echo "::warning title=service check::$msg"
exit $c
