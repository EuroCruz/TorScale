# syntax=docker/dockerfile:1

FROM --platform=$BUILDPLATFORM golang:1.27.3-alpine3.24 AS build

RUN apk add --no-cache git
# Let newer Tailscale releases pull the Go toolchain they require
ENV GOTOOLCHAIN=auto CGO_ENABLED=0

# Versions here are bumped automatically by .github/workflows/update.yml
ARG TS_VERSION="v1.104.2"
RUN git -c advice.detachedHead=false clone --depth 1 --branch "$TS_VERSION" \
      https://github.com/tailscale/tailscale.git /src
WORKDIR /src
RUN go mod download

# Single tailscaled binary with the CLI embedded and only the features an exit
# node needs. Everything else (logtail, SSH, Taildrop, serve, netstack, ...) is
# compiled out.
ARG TS_FEATURES="cli,advertiseexitnode,osrouter,dns,iptables,nattraversal,portmapper,health,ipnbus,oauthkey,bakedroots"
ARG TARGETARCH
ARG TARGETVARIANT
RUN TAGS="$(go run ./cmd/featuretags --min --add="$TS_FEATURES")" \
    GOARCH="$TARGETARCH" GOARM="${TARGETVARIANT#v}" \
    ./build_dist.sh --strip -o /out/tailscaled ./cmd/tailscaled

FROM alpine:3.24.3

ARG TOR_VERSION="0.4.9.14-r0"
RUN apk add --no-cache "tor=$TOR_VERSION" iptables ip6tables

COPY --from=build /out/tailscaled /usr/local/bin/tailscaled
RUN ln -s tailscaled /usr/local/bin/tailscale
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint.sh

VOLUME ["/var/lib/tailscale", "/var/lib/tor"]

HEALTHCHECK --interval=1m --timeout=10s --start-period=5m --retries=3 \
    CMD ["/usr/local/bin/entrypoint.sh", "healthcheck"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
