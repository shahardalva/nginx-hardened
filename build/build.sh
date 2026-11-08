#!/usr/bin/env bash
# Build nginx 1.25.5 from source with backported security patches, and
# package the result as a .deb. Runs inside debian:bookworm-slim.
set -euo pipefail

NGINX_VERSION=1.25.5
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC=/usr/src
OUT=/out
mkdir -p "$SRC" "$OUT" && cd "$SRC"

echo "==> Download nginx ${NGINX_VERSION} source"
curl -fSL "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" -o nginx.tar.gz

echo "==> Verify checksum (supply-chain gate)"
if [ -f "${HERE}/nginx.sha256" ]; then
    echo "$(cat "${HERE}/nginx.sha256")  nginx.tar.gz" | sha256sum -c -
else
    echo "!! No pinned checksum found. Recording current hash to build/nginx.sha256."
    echo "!! REVIEW it against nginx.org before trusting this build."
    sha256sum nginx.tar.gz | awk '{print $1}' > "${HERE}/nginx.sha256"
fi

tar xf nginx.tar.gz
cd "nginx-${NGINX_VERSION}"

echo "==> Apply backport patches"
for p in "${HERE}"/patches/*.patch; do
    echo "    - $(basename "$p")"
    patch -p1 < "$p"
done

echo "==> Configure (flags aligned with the official nginx:1.25-bookworm image)"
./configure \
  --prefix=/etc/nginx --sbin-path=/usr/sbin/nginx \
  --modules-path=/usr/lib/nginx/modules --conf-path=/etc/nginx/nginx.conf \
  --error-log-path=/var/log/nginx/error.log --http-log-path=/var/log/nginx/access.log \
  --pid-path=/var/run/nginx.pid --lock-path=/var/run/nginx.lock \
  --http-client-body-temp-path=/var/cache/nginx/client_temp \
  --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
  --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
  --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
  --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
  --user=nginx --group=nginx \
  --with-compat --with-file-aio --with-threads \
  --with-http_addition_module --with-http_auth_request_module \
  --with-http_dav_module --with-http_flv_module --with-http_gunzip_module \
  --with-http_gzip_static_module --with-http_mp4_module \
  --with-http_random_index_module --with-http_realip_module \
  --with-http_secure_link_module --with-http_slice_module \
  --with-http_ssl_module --with-http_stub_status_module \
  --with-http_sub_module --with-http_v2_module \
  --with-mail --with-mail_ssl_module \
  --with-stream --with-stream_realip_module --with-stream_ssl_module \
  --with-stream_ssl_preread_module \
  --with-cc-opt='-g -O2 -fstack-protector-strong -Wformat -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2 -fPIC' \
  --with-ld-opt='-Wl,-z,relro -Wl,-z,now -Wl,--as-needed -pie'

echo "==> Compile"
make -j"$(nproc)"

echo "==> Stage install"
DEST="$SRC/stage"
rm -rf "$DEST"
make install DESTDIR="$DEST"
install -d "$DEST/var/cache/nginx" "$DEST/var/log/nginx"

echo "==> Build .deb"
ARCH="$(dpkg --print-architecture)"
DEB_VER="${NGINX_VERSION}-hardened1"
mkdir -p "$DEST/DEBIAN"
cat > "$DEST/DEBIAN/control" <<CTRL
Package: nginx-hardened
Version: ${DEB_VER}
Architecture: ${ARCH}
Maintainer: Shahar Dalva <shahardalva@gmail.com>
Depends: libc6, libssl3, libpcre2-8-0, zlib1g
Provides: nginx
Conflicts: nginx
Replaces: nginx
Section: httpd
Priority: optional
Homepage: https://nginx.org
Description: nginx ${NGINX_VERSION} built from source with backported CVE fixes
 Drop-in replacement for nginx:1.25-bookworm. Backports CVE-2026-15176.
CTRL
cat > "$DEST/DEBIAN/postinst" <<'PINST'
#!/bin/sh
set -e
if ! getent group nginx >/dev/null; then addgroup --system --gid 101 nginx; fi
if ! getent passwd nginx >/dev/null; then
  adduser --system --disabled-login --ingroup nginx --no-create-home \
          --home /nonexistent --gecos "nginx user" --shell /bin/false --uid 101 nginx
fi
PINST
chmod 0755 "$DEST/DEBIAN/postinst"

dpkg-deb --root-owner-group --build "$DEST" "$OUT/nginx-hardened_${DEB_VER}_${ARCH}.deb"
dpkg-deb --info "$OUT/nginx-hardened_${DEB_VER}_${ARCH}.deb"
echo "==> DONE"
