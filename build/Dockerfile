# Builder image: compiles nginx from source and emits a .deb.
# Separate from the runtime image so the toolchain never ships to production.
FROM debian:bookworm-slim

# Build toolchain + the -dev headers nginx links against (dynamic linking,
# same as the official image: system OpenSSL, PCRE2 and zlib).
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        libssl-dev \
        libpcre2-dev \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

COPY . /build
RUN chmod +x /build/build.sh

# The .deb is written to /out (bind-mounted by `make deb`).
ENTRYPOINT ["/build/build.sh"]
