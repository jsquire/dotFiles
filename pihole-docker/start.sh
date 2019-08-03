#!/bin/bash
IP=$(ifconfig eth0 | grep -v 'inet6' | grep 'inet' | awk '{print $2}')
IP6=$(ifconfig eth0 | grep 'inet6' | awk '{print $2}')

# Pi-Hole was complaining about the double-colon.  The later environment
# complains if its not there.  Deferring IP v6 for now.
#-----------------------------------------------------------------------
#IP6=$(echo "$IP6" | sed 's/::/:/g')

cat << EOF > .env
CLOUDFLARED_OPTS=--port 5053 --upstream https://1.1.1.1/dns-query --upstream https://1.0.0.1/dns-query
SERVER_IP=$IP
SERVER_IP_V6=$IP6
PIHOLEBASE=$HOME/piehole
PIHOLE_ADMIN_PASS=Ilikemilk
TZ=America/New_York
EOF

docker-compose up -d ; docker-compose logs -tf --tail="50" pihole
