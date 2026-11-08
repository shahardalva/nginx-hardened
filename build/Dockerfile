# Builder image: compiles nginx, nginx-debug and the dynamic modules from source
# and emits .debs. Separate from the runtime image so the toolchain never ships.
FROM debian:bookworm-slim

# Toolchain + headers. nginx links dynamically against the system libraries,
# like the official image (OpenSSL, PCRE2, zlib; libxml2/libxslt, libgd and
# libGeoIP for the modules).
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl pkg-config \
        libssl-dev libpcre2-dev zlib1g-dev \
        libxml2-dev libxslt1-dev libgd-dev libgeoip-dev \
    && rm -rf /var/lib/apt/lists/*

COPY . /build
RUN chmod +x /build/build.sh

# The .debs are written to /out (bind-mounted by `make deb`).
ENTRYPOINT ["/build/build.sh"]
