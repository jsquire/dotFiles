# See: https://docs.pi-hole.net/guides/dns-over-https/

FROM pihole/debian-base:latest

RUN mkdir -p /usr/src/

COPY ./install-cloudflared.sh /usr/src

RUN chmod +x /usr/src/install-cloudflared.sh \
    && /usr/src/install-cloudflared.sh

EXPOSE 5053/tcp
EXPOSE 5053/udp

ENTRYPOINT [ "/usr/local/bin/launch-cloudflared.sh" ]