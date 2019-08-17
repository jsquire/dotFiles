#!/bin/bash

IP=$(ifconfig eth0 | grep -v 'inet6' | grep 'inet' | awk '{print $2}')
IP6=$(ifconfig eth0 | grep 'inet6' | awk '{print $2}')

# Pi-Hole was complaining about the double-colon.  The later environment
# complains if its not there.  Deferring IP v6 for now.
#-----------------------------------------------------------------------
#IP6=$(echo "$IP6" | sed 's/::/:/g')

cat << EOF > .env
# General
SERVER_IP=$IP
SERVER_IP_V6=$IP6
LOCAL_DOMAIN=LAN
TZ=America/New_York

# Cloudflared
CLOUDFLARED_OPTS=--port 5053 --upstream https://1.1.1.1/dns-query --upstream https://1.0.0.1/dns-query

# Pi-Hole
PIHOLE_BASE=$HOME/piehole
PIHOLE_ADMIN_PASS=<< PASS >>

# Plex
PLEX_BASE=$HOME/plex
PLEX_TRANSCODE=/mnt/ramdisk
PLEX_CLAIM=<< CLAIM >>
PLEX_HOSTNAME=Container-Plex
EOF

chmod 755 .env
docker-compose up -d $1