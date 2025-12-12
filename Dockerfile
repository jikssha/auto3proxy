# ---- build stage: compile 3proxy ----
FROM debian:bookworm AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
    git build-essential ca-certificates && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 https://github.com/3proxy/3proxy.git /src
WORKDIR /src
RUN make -f Makefile.Linux && strip bin/3proxy

# ---- runtime stage ----
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash curl ca-certificates tini && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/bin/3proxy /usr/local/bin/3proxy
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && mkdir -p /data

ENV BIN=/usr/local/bin/3proxy
ENTRYPOINT ["/usr/bin/tini","--","/entrypoint.sh"]
