#!/bin/bash

CONTAINER_SERVICES_ROOT="$1"

if [ ${#CONTAINER_SERVICES_ROOT} -lt 1 ];
then
  CONTAINER_SERVICES_ROOT=$PWD
fi

# Make the scripts executable.
chmod +x ${CONTAINER_SERVICES_ROOT}/*.sh

# Schedule a weekly job to update the containers.
UPDATE_CMD=${CONTAINER_SERVICES_ROOT}/restart-update.sh
UPDATE_JOB="0 03 * * SAT root $UPDATE_CMD"

( crontab -l | grep -v -F "$UPDATE_CMD" ; echo "$UPDATE_JOB" ) | crontab -

# Start the containers if not active.bash 
if [ "$(docker ps | grep cloudflared |  awk '{print $2}')" != "squire/cloudflared" ]
then
    ${CONTAINER_SERVICES_ROOT}/start-services.sh
fi 