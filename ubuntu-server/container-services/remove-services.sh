#!/bin/bash

CONTAINER_SERVICES_ROOT="$1"

if [ ${#CONTAINER_SERVICES_ROOT} -lt 1 ];
then
  CONTAINER_SERVICES_ROOT=$PWD
fi

# Stop the containers if active
if [ "$(docker ps | grep cloudflared |  awk '{print $2}')" == "squire/cloudflared" ]
then
    /usr/bin/docker-compose -f ${CONTAINER_SERVICES_ROOT}/docker-compose.yml down
fi 

# Unschedule the weekly job to update the containers.
UPDATE_CMD=${CONTAINER_SERVICES_ROOT}/restart-update.sh

( crontab -l | grep -v -F "$UPDATE_CMD" ) | crontab -