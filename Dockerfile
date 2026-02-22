FROM ubuntu:22.04
ENV WARP_LICENSE=
ENV FAMILIES_MODE=off
EXPOSE 1080/tcp
RUN apt-get update && \
  apt-get install curl gpg socat lsb-release supervisor logrotate strace dnsutils procps -y && \
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg && \
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list && \
  apt-get update && \
  apt-get install cloudflare-warp -y && \
  rm -rf /var/lib/apt/lists/* && \
  apt-get clean && \
  rm -rf /tmp/* /var/tmp/*
COPY --chmod=755 scripts /scripts
COPY --chmod=644 configs/logrotate.conf /etc/logrotate.conf
COPY --chmod=644 configs/supervisord.conf /etc/supervisor/supervisord.conf
VOLUME ["/var/lib/cloudflare-warp"]
# Extended healthcheck for QNAP: higher timeout and longer initial grace period
HEALTHCHECK --interval=180s --timeout=40s --start-period=60s --retries=3 \
  CMD curl -m 30 -x socks5h://127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace/ | grep -q warp=on || exit 1
CMD ["/usr/bin/supervisord"]