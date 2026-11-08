#!/usr/bin/env bash
# Build nginx 1.25.5 from source together with nginx-debug and the dynamic modules
# that the official nginx:1.25-bookworm image ships (njs, geoip, image-filter, xslt).
# Backport patches from build/patches/ are applied to the nginx source first.
# Output: one .deb per package of the official image, written to /out.
# Runs inside debian:bookworm-slim (see build/Dockerfile).
set -euo pipefail

NGINX_VERSION=1.25.5
NJS_VERSION=0.8.4
NGINX_DEB_VERSION="${NGINX_VERSION}-1~bookworm+hardened1"
NJS_DEB_VERSION="${NGINX_VERSION}+${NJS_VERSION}-3~bookworm+hardened1"
# Version bump (CVE-2026-31789): Debian fixed it in libssl3 3.0.19-1~deb12u2.
# Every package that links libssl3 declares this minimum in Depends.
LIBSSL3_MIN="3.0.19-1~deb12u2"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC=/usr/src
OUT=/out
ARCH="$(dpkg --print-architecture)"
mkdir -p "$SRC" "$OUT"
cd "$SRC"

echo "==> Download sources"
curl -fsSL "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" -o "nginx-${NGINX_VERSION}.tar.gz"
curl -fsSL "https://github.com/nginx/njs/archive/refs/tags/${NJS_VERSION}.tar.gz" -o "njs-${NJS_VERSION}.tar.gz"

echo "==> Verify checksums (supply-chain gate, fails closed)"
for f in "nginx-${NGINX_VERSION}.tar.gz" "njs-${NJS_VERSION}.tar.gz"; do
    if ! grep -q "  ${f}\$" "${HERE}/SHA256SUMS" 2>/dev/null; then
        echo "!! No pinned checksum for ${f} in build/SHA256SUMS. Refusing to build." >&2
        exit 1
    fi
done
sha256sum -c "${HERE}/SHA256SUMS"

echo "==> Verify nginx PGP signature (key from https://nginx.org/keys/arut.key)"
# Independent of the SHA-256 pin: the tarball must carry a valid signature from
# the nginx developer key committed in build/keys/. Missing or bad -> build fails.
# njs: GitHub tag archives are unsigned; it is pinned by SHA-256 only (README, section 5).
gpgv --keyring "${HERE}/keys/nginx-arutyunyan.gpg" \
    "${HERE}/nginx-${NGINX_VERSION}.tar.gz.asc" "nginx-${NGINX_VERSION}.tar.gz"

tar xf "nginx-${NGINX_VERSION}.tar.gz"
tar xf "njs-${NJS_VERSION}.tar.gz"

echo "==> Apply backport patches (in filename order)"
shopt -s nullglob
patches=("${HERE}"/patches/*.patch)
if [ ${#patches[@]} -eq 0 ]; then
    echo "!! No patches found in ${HERE}/patches" >&2
    exit 1
fi
for p in "${patches[@]}"; do
    echo "    - $(basename "$p")"
    patch -d "nginx-${NGINX_VERSION}" -p1 < "$p"
done

# Same arguments, in the same order, as `nginx -V` of the official image.
CONFIGURE_ARGS=(
  --prefix=/etc/nginx --sbin-path=/usr/sbin/nginx
  --modules-path=/usr/lib/nginx/modules --conf-path=/etc/nginx/nginx.conf
  --error-log-path=/var/log/nginx/error.log --http-log-path=/var/log/nginx/access.log
  --pid-path=/var/run/nginx.pid --lock-path=/var/run/nginx.lock
  --http-client-body-temp-path=/var/cache/nginx/client_temp
  --http-proxy-temp-path=/var/cache/nginx/proxy_temp
  --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp
  --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp
  --http-scgi-temp-path=/var/cache/nginx/scgi_temp
  --user=nginx --group=nginx
  --with-compat --with-file-aio --with-threads
  --with-http_addition_module --with-http_auth_request_module
  --with-http_dav_module --with-http_flv_module --with-http_gunzip_module
  --with-http_gzip_static_module --with-http_mp4_module
  --with-http_random_index_module --with-http_realip_module
  --with-http_secure_link_module --with-http_slice_module
  --with-http_ssl_module --with-http_stub_status_module
  --with-http_sub_module --with-http_v2_module --with-http_v3_module
  --with-mail --with-mail_ssl_module
  --with-stream --with-stream_realip_module --with-stream_ssl_module
  --with-stream_ssl_preread_module
)
# The official build maps its own build directory with -ffile-prefix-map; we map ours.
CC_OPT="-g -O2 -ffile-prefix-map=${SRC}=. -fstack-protector-strong -Wformat -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2 -fPIC"
LD_OPT="-Wl,-z,relro -Wl,-z,now -Wl,--as-needed -pie"
MODULE_ARGS=(
  --with-http_xslt_module=dynamic --with-http_image_filter_module=dynamic
  --with-http_geoip_module=dynamic --with-stream_geoip_module=dynamic
)

# build_tree <dir> <make target> [extra configure arguments...]
# Each variant is built in its own copy of the patched source tree.
build_tree() {
    local dir="$1" target="$2"
    shift 2
    echo "==> Build ${dir} (make ${target})"
    rm -rf "${SRC:?}/${dir}"
    cp -a "${SRC}/nginx-${NGINX_VERSION}" "${SRC}/${dir}"
    (
        cd "${SRC}/${dir}"
        ./configure "${CONFIGURE_ARGS[@]}" "$@" --with-cc-opt="${CC_OPT}" --with-ld-opt="${LD_OPT}"
        make -j"$(nproc)" "${target}"
    )
}

# njs builds its library inside its own source tree, so each variant gets a copy.
rm -rf "${SRC}/njs-normal" "${SRC}/njs-debug"
cp -a "${SRC}/njs-${NJS_VERSION}" "${SRC}/njs-normal"
cp -a "${SRC}/njs-${NJS_VERSION}" "${SRC}/njs-debug"

# Main binary with exactly the official arguments, so `nginx -V` matches.
build_tree b-nginx         build
build_tree b-nginx-debug   build   --with-debug
# Modules are built separately and only their .so files are kept, as nginx.org does.
build_tree b-modules       modules "${MODULE_ARGS[@]}" --add-dynamic-module="${SRC}/njs-normal/nginx"
build_tree b-modules-debug modules --with-debug "${MODULE_ARGS[@]}" --add-dynamic-module="${SRC}/njs-debug/nginx"

# njs command-line tool, shipped as /usr/bin/njs in nginx-module-njs like the
# official package. configure silently drops line editing if libedit is missing,
# so the build fails unless the binary links libedit.
echo "==> Build njs CLI"
rm -rf "${SRC}/njs-cli"
cp -a "${SRC}/njs-${NJS_VERSION}" "${SRC}/njs-cli"
(
    cd "${SRC}/njs-cli"
    ./configure --cc-opt="${CC_OPT}" --ld-opt="${LD_OPT}"
    make -j"$(nproc)" njs
)
if ldd "${SRC}/njs-cli/build/njs" | grep -q 'libedit\.so'; then
    echo "    njs CLI links libedit"
else
    echo "ERROR: njs CLI was built without libedit" >&2
    exit 1
fi

# deps_for <file>...: the Debian packages providing the shared libraries these
# ELF files link against, as a Depends list.
deps_for() {
    local f l p pkgs=""
    for l in $(for f in "$@"; do ldd "$f" | awk '/=> \//{print $3}'; done | sort -u); do
        p=$(dpkg -S "$l" 2>/dev/null || dpkg -S "${l#/usr}" 2>/dev/null || dpkg -S "/usr${l}" 2>/dev/null || true)
        p=${p%%:*}
        if [ -n "$p" ]; then pkgs="${pkgs} ${p}"; fi
    done
    echo ${pkgs} | tr ' ' '\n' | sort -u | paste -sd, - | sed 's/,/, /g' \
        | sed "s/\blibssl3\b/libssl3 (>= ${LIBSSL3_MIN})/"
}

# make_deb <stage dir> <package> <version> <depends> <description>
make_deb() {
    local stage="$1" pkg="$2" ver="$3" deps="$4" desc="$5"
    mkdir -p "${stage}/DEBIAN"
    cat > "${stage}/DEBIAN/control" <<CTRL
Package: ${pkg}
Version: ${ver}
Architecture: ${ARCH}
Maintainer: Shahar Dalva <shahardalva@gmail.com>
Depends: ${deps}
Section: httpd
Priority: optional
Homepage: https://nginx.org
Description: ${desc}
 Built from source for nginx-hardened, a drop-in replacement for nginx:1.25-bookworm.
CTRL
    echo "    ${pkg} ${ver}"
    echo "      Depends: ${deps}"
    dpkg-deb --root-owner-group --build "${stage}" "${OUT}/${pkg}_${ver}_${ARCH}.deb" >/dev/null
}

rm -f "${OUT}"/*.deb

echo "==> Package nginx (nginx + nginx-debug)"
ST="${SRC}/stage-nginx"
rm -rf "$ST"
make -C "${SRC}/b-nginx" install DESTDIR="$ST"
install -m 0755 "${SRC}/b-nginx-debug/objs/nginx" "$ST/usr/sbin/nginx-debug"
# Strip symbols, as the official packages do.
strip --strip-unneeded "$ST/usr/sbin/nginx" "$ST/usr/sbin/nginx-debug"
rm -rf "$ST/etc/nginx/html"
rm -f "$ST"/etc/nginx/*.default
# Not shipped by the official package.
rm -f "$ST"/etc/nginx/fastcgi.conf "$ST"/etc/nginx/koi-utf "$ST"/etc/nginx/koi-win "$ST"/etc/nginx/win-utf
install -d "$ST/usr/lib/nginx/modules" "$ST/var/cache/nginx" "$ST/var/log/nginx"
ln -sfn /usr/lib/nginx/modules "$ST/etc/nginx/modules"
# The official entrypoint enables IPv6 only if conf.d/default.conf matches the
# md5 that dpkg records for the nginx package, so ship the official file as a conffile.
install -D -m 0644 "${HERE}/files/default.conf" "$ST/etc/nginx/conf.d/default.conf"
mkdir -p "$ST/DEBIAN"
# Service integration files of the official package (init scripts, defaults,
# logrotate, systemd units), copied unmodified from nginx:1.25-bookworm into
# build/files/. Modes are kept from the copied files.
for f in etc/default/nginx etc/default/nginx-debug etc/init.d/nginx etc/init.d/nginx-debug \
         etc/logrotate.d/nginx lib/systemd/system/nginx.service lib/systemd/system/nginx-debug.service; do
    install -D -m "$(stat -c %a "${HERE}/files/${f}")" "${HERE}/files/${f}" "$ST/${f}"
done
install -D -m 0644 "${SRC}/nginx-${NGINX_VERSION}/LICENSE" "$ST/usr/share/doc/nginx/copyright"
# Same conffiles as the official package for the files it owns outside /etc/nginx.
printf '%s\n' /etc/default/nginx /etc/default/nginx-debug /etc/init.d/nginx \
    /etc/init.d/nginx-debug /etc/logrotate.d/nginx /etc/nginx/conf.d/default.conf \
    > "$ST/DEBIAN/conffiles"
cat > "$ST/DEBIAN/postinst" <<'PINST'
#!/bin/sh
set -e
if ! getent group nginx >/dev/null; then groupadd --system --gid 101 nginx; fi
if ! getent passwd nginx >/dev/null; then
    useradd --system --gid nginx --uid 101 --home-dir /nonexistent \
            --no-create-home --shell /bin/false --comment "nginx user" nginx
fi
PINST
chmod 0755 "$ST/DEBIAN/postinst"
make_deb "$ST" nginx "${NGINX_DEB_VERSION}" \
    "$(deps_for "$ST/usr/sbin/nginx" "$ST/usr/sbin/nginx-debug")" \
    "nginx ${NGINX_VERSION} built from source with backported CVE fixes"

# stage_module <package> <version> <description> <module name>...
stage_module() {
    local pkg="$1" ver="$2" desc="$3"
    shift 3
    local st="${SRC}/stage-${pkg}" m files=() deps libdeps
    rm -rf "$st"
    install -d "$st/usr/lib/nginx/modules"
    for m in "$@"; do
        install -m 0644 "${SRC}/b-modules/objs/${m}.so"       "$st/usr/lib/nginx/modules/${m}.so"
        install -m 0644 "${SRC}/b-modules-debug/objs/${m}.so" "$st/usr/lib/nginx/modules/${m}-debug.so"
        files+=("$st/usr/lib/nginx/modules/${m}.so" "$st/usr/lib/nginx/modules/${m}-debug.so")
    done
    if [ "$pkg" = "nginx-module-njs" ]; then
        install -D -m 0755 "${SRC}/njs-cli/build/njs" "$st/usr/bin/njs"
        files+=("$st/usr/bin/njs")
        install -D -m 0644 "${SRC}/njs-${NJS_VERSION}/LICENSE" "$st/usr/share/doc/${pkg}/copyright"
    else
        install -D -m 0644 "${SRC}/nginx-${NGINX_VERSION}/LICENSE" "$st/usr/share/doc/${pkg}/copyright"
    fi
    strip --strip-unneeded "${files[@]}"
    deps="nginx (= ${NGINX_DEB_VERSION})"
    libdeps="$(deps_for "${files[@]}")"
    if [ -n "$libdeps" ]; then deps="${deps}, ${libdeps}"; fi
    make_deb "$st" "$pkg" "$ver" "$deps" "$desc"
}

echo "==> Package dynamic modules"
stage_module nginx-module-geoip        "${NGINX_DEB_VERSION}" "nginx GeoIP dynamic modules" \
    ngx_http_geoip_module ngx_stream_geoip_module
stage_module nginx-module-image-filter "${NGINX_DEB_VERSION}" "nginx image filter dynamic module" \
    ngx_http_image_filter_module
stage_module nginx-module-xslt         "${NGINX_DEB_VERSION}" "nginx xslt dynamic module" \
    ngx_http_xslt_filter_module
stage_module nginx-module-njs          "${NJS_DEB_VERSION}"   "nginx njs dynamic modules (njs ${NJS_VERSION})" \
    ngx_http_js_module ngx_stream_js_module

echo "==> Built packages"
ls -1 "${OUT}"
echo "==> DONE"
