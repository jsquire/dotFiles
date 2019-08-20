#!/bin/bash

# See: https://docs.pi-hole.net/guides/dns-over-https/

# Prepare the environment.
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get upgrade -y
apt-get install apt-utils debconf-utils build-essential wget net-tools procps -y
apt-get autoremove -y

# Download and install the "cloudflared" package.
wget https://bin.equinox.io/c/VdrWdbjqyF/cloudflared-stable-linux-amd64.deb
DEBIAN_FRONTEND=noninteractive apt-get install ./cloudflared-stable-linux-amd64.deb
cloudflared -v

# Install the startup script.
cat << EOF > launch-cloudflared.sh
#!/bin/bash

exec usr/local/bin/cloudflared proxy-dns --address 0.0.0.0 --port 5053 --upstream https://1.1.1.1/dns-query --upstream https://1.0.0.1/dns-query
EOF

chmod +x launch-cloudflared.sh
mv ./launch-cloudflared.sh /usr/local/bin/launch-cloudflared.sh