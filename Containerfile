# Runtime image: a drop-in replacement for nginx:1.25-bookworm.
# nginx, nginx-debug and the dynamic modules come from .debs compiled from source
# (build/). Entrypoint scripts, default configuration and static assets are copied
# from the official image, so behaviour, user and paths match it.

# Stage 1: the official image, used only as a source of config, scripts and assets.
FROM nginx:1.25-bookworm AS stock

# Stage 2: the runtime image.
FROM debian:bookworm-slim

# Same environment variables as the official image (values copied from it).
ENV NGINX_VERSION=1.25.5
ENV NJS_VERSION=0.8.4
ENV NJS_RELEASE=3~bookworm
ENV PKG_RELEASE=1~bookworm

# 1) nginx user and group with the same uid/gid as upstream (101:101).
RUN set -eux; \
    groupadd --system --gid 101 nginx; \
    useradd --system --gid nginx --uid 101 --home /nonexistent \
            --no-create-home --shell /bin/false nginx

# 2) Runtime dependencies that the .debs do not pull in.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates tzdata gettext-base \
    && rm -rf /var/lib/apt/lists/*

# 2b) DEPENDENCY VERSION BUMP: upgrade the libraries nginx links against to the
#     latest patched Debian releases (libssl3 3.0.11 -> 3.0.22 closes
#     CVE-2026-31789).
RUN apt-get update \
 && apt-get install -y --only-upgrade libssl3 libpcre2-8-0 zlib1g \
 && rm -rf /var/lib/apt/lists/*

# 3) Install nginx, nginx-debug and the module packages built from source.
#    apt resolves the libraries they declare in Depends (libgd3, libxml2, ...).
COPY dist/*.deb /tmp/debs/
RUN apt-get update \
 && apt-get install -y --no-install-recommends /tmp/debs/*.deb \
 && rm -rf /tmp/debs /var/lib/apt/lists/*

# 4) Configuration, entrypoint scripts and static assets copied from the official
#    image. No binaries are copied (see reports/stock-copy-check.txt).
COPY --from=stock /etc/nginx /etc/nginx
COPY --from=stock /usr/share/nginx /usr/share/nginx
COPY --from=stock /docker-entrypoint.sh /docker-entrypoint.sh
COPY --from=stock /docker-entrypoint.d /docker-entrypoint.d

# 5) Forward logs to stdout/stderr, as the official image does.
RUN ln -sf /dev/stdout /var/log/nginx/access.log \
 && ln -sf /dev/stderr /var/log/nginx/error.log \
 && mkdir -p /var/cache/nginx && chown -R nginx:nginx /var/cache/nginx

EXPOSE 80
STOPSIGNAL SIGQUIT
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
