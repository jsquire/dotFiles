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
mkdir -p ${PIHOLE_ROOT}/root
mkdir -p ${PIHOLE_ROOT}/log
chmod 0755 ${PIHOLE_Root}/log

rm -rf ${PIHOLE_ROOT}/log/pihole.log
touch ${PIHOLE_ROOT}/log/pihole.log
chmod 0664 ${PIHOLE_ROOT}/log/pihole.log

# Schedule a weekly job to update the containers.
UPDATE_CMD=sh ${CONTAINER_SERVICES_ROOT}/restart-update.sh
UPDATE_JOB="0 1 * * SAT root $UPDATE_CMD"

( crontab -l | grep -v -F "$UPDATE_CMD" ; echo "$UPDATE_JOB" ) | crontab -

# Create a service to ensure that the containers are started on reboot
# without interactive login.
cat << EOF > /etc/systemd/system/squire-server-containers.service
[Unit]
Description=Squire Server Container Services
After=docker.service
Requires=docker.service

[Service]
WorkingDirectory=${CONTAINER_SERVICES_ROOT}
ExecStartPre=/usr/bin/docker-compose -f ${CONTAINER_SERVICES_ROOT}/docker-compose.yml down
ExecStart=${CONTAINER_SERVICES_ROOT}/start-services.sh --force-recreate --build --wait
ExecStop=/usr/bin/docker-compose -f ${CONTAINER_SERVICES_ROOT}/docker-compose.yml down
TimeoutSec=120
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable squire-server-containers
systemctl start squire-server-containers

# Start the containers if not active.
if [ "$(docker ps | grep cloudflared | awk '{print $2}')" != "squire/cloudflared" ]
then
    ${CONTAINER_SERVICES_ROOT}/start-services.sh
fi
