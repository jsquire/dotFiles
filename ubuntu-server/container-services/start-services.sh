#!/bin/bash

IP=$(ifconfig enp0s31f6 | grep -v 'inet6' | grep 'inet' | awk '{print $2}')
IP6=$(ifconfig enp0s31f6 | grep 'inet6' | awk '{print $2}')

# Pi-Hole was complaining about the double-colon.  The later environment
# complains if its not there.  Deferring IP v6 for now.
#-----------------------------------------------------------------------
#IP6=$(echo "$IP6" | sed 's/::/:/g')

# To retrieve a Plex claim, see: https://www.plex.tv/claim/
#-----------------------------------------------------------------------

cat << EOF > .env
# General
SERVER_IP=$IP
SERVER_IP_V6=$IP6
LOCAL_DOMAIN=squire
TZ=America/New_York

# Pi-Hole
PIHOLE_BASE=/virtualization/pihole
PIHOLE_ADMIN_PASS=<< PASSWORD >>

# Plex
PLEX_BASE=/virtualization/plex
PLEX_MEDIA=/storage/media
PLEX_TRANSCODE=/mnt/transcode
PLEX_CLAIM=<< CLAIM VALUE >>
PLEX_HOSTNAME=Squire-Media
EOF

chmod 755 .env
docker-compose up -d $1
