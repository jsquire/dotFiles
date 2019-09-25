#!/bin/bash

# Capture the current IP addresses.
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
LOCAL_DOMAIN=local
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

# Determine the arguments to use when starting.  If a "--wait" flag was passed,
# then do not assume detached mode.  Otherwise, detatch as the default.
ARGS="$@"

if [ $(echo "$ARGS" | grep -e "--wait" | wc -l) -lt 1 ]
then
    ARGS="-d $ARGS"
fi

# The "--wait" flag is not an actual docker-compose argument; be sure to
# strip it from the arguments when passing them.
docker-compose up ${ARGS//--wait/''}
