FROM pihole/pihole:latest

RUN mkdir -p /usr/src/

COPY ./install-cloudflared.sh /usr/src
COPY ./launch-pihole-https.sh /usr/src

RUN chmod +x /usr/src/install-cloudflared.sh \
    && chmod +x /usr/src/launch-pihole-https.sh \
    && /usr/src/install-cloudflared.sh

ENTRYPOINT [ "bin/bash", "-c", "/usr/src/launch-pihole-https.sh" ]