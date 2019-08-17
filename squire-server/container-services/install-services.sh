#!/bin/bash

CONTAINER_SERVICES_ROOT="$1"

if [ ${#CONTAINER_SERVICES_ROOT} -lt 1 ];
then
  CONTAINER_SERVICES_ROOT=$PWD
  echo "No container services root supplied, using the current directory: ${CONTAINER_SERVICES_ROOT}"
fi

PIHOLE_ROOT="$2"

if [ ${#PIHOLE_ROOT} -lt 1 ];
then
  PIHOLE_ROOT=$PWD
  echo "No pihole root supplied, using the current directory: ${PIHOLE_ROOT}"
fi

# Make the scripts executable.
chmod +x ${CONTAINER_SERVICES_ROOT}/*.sh

# Setup PiHole requirements
mkdir -p ${PIHOLE_ROOT}/log
mkdir -p ${PIHOLE_ROOT}/root

rm -rf ${PIHOLE_ROOT}/log/pihole.log
touch ${PIHOLE_ROOT}/log/pihole.log
chmod 666 ${PIHOLE_ROOT}/log/pihole.log

# Schedule a weekly job to update the containers.
UPDATE_CMD=${CONTAINER_SERVICES_ROOT}/restart-update.sh
UPDATE_JOB="0 03 * * SAT root $UPDATE_CMD"

( crontab -l | grep -v -F "$UPDATE_CMD" ; echo "$UPDATE_JOB" ) | crontab -

# Start the containers if not active.bash
if [ "$(docker ps | grep cloudflared |  awk '{print $2}')" != "squire/cloudflared" ]
then
    ${CONTAINER_SERVICES_ROOT}/start-services.sh
fi