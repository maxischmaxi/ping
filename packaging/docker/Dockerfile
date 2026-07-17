# flurfunk-server image. The binary comes from the release pipeline (same
# artifact as the GitHub release, built on ubuntu-22.04 → needs glibc >= 2.35,
# bookworm has 2.36). Build context: this directory with flurfunk-server
# placed next to the Dockerfile.
FROM debian:bookworm-slim

ARG VERSION=dev
LABEL org.opencontainers.image.title="flurfunk-server" \
      org.opencontainers.image.description="Selbst gehosteter Team-Chat mit Voice-Calls — Server" \
      org.opencontainers.image.source="https://github.com/maxischmaxi/flurfunk" \
      org.opencontainers.image.version="$VERSION" \
      org.opencontainers.image.licenses="MIT"

COPY flurfunk-server /usr/local/bin/flurfunk-server

# Chat state lives here (encrypted message logs, keys, users).
# Mount a volume; add `-key /keys/master.key` to keep the master key elsewhere.
VOLUME /data

# One port for everything: TCP carries chat, UDP carries voice.
EXPOSE 7788/tcp 7788/udp

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s \
  CMD bash -c '</dev/tcp/127.0.0.1/7788' || exit 1

ENTRYPOINT ["/usr/local/bin/flurfunk-server"]
CMD ["-port", "7788", "-data", "/data"]
