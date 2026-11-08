# Runtime image: a drop-in replacement for nginx:1.25-bookworm.
# The nginx binary is ours (hardened .deb); everything else — entrypoint,
# default config, user, ports, signals — is matched to the official image.

# Stage 1: the official image, used only as a source of runtime assets.
FROM nginx:1.25-bookworm AS stock

# Stage 2: our runtime image.
FROM debian:bookworm-slim

# 1) Recreate the nginx user with the SAME uid/gid as upstream (101:101).
RUN set -eux; \
    groupadd --system --gid 101 nginx; \
    useradd --system --gid nginx --uid 101 --home /nonexistent \
            --no-create-home --shell /bin/false nginx

# 2) Runtime dependencies (no nginx from apt — ours comes from the .deb).
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates tzdata gettext-base \
    && rm -rf /var/lib/apt/lists/*

# 3) Install our hardened nginx built from source.
ARG DEB
COPY ${DEB} /tmp/nginx-hardened.deb
RUN dpkg -i /tmp/nginx-hardened.deb && rm /tmp/nginx-hardened.deb

# 4) Copy the official runtime assets verbatim for byte-exact parity.
COPY --from=stock /etc/nginx /etc/nginx
COPY --from=stock /usr/share/nginx /usr/share/nginx
COPY --from=stock /docker-entrypoint.sh /docker-entrypoint.sh
COPY --from=stock /docker-entrypoint.d /docker-entrypoint.d

# 5) Forward logs to stdout/stderr, exactly like the official image.
RUN ln -sf /dev/stdout /var/log/nginx/access.log \
 && ln -sf /dev/stderr /var/log/nginx/error.log \
 && mkdir -p /var/cache/nginx && chown -R nginx:nginx /var/cache/nginx

EXPOSE 80
STOPSIGNAL SIGQUIT
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
