# ============================================================================
# Stage 0: nginx 1.31.1 を nginx 公式 apt repo から自前で組み立てる
# (Docker Hub `library/nginx` の official image 反映を待たずに最新版を使うため。
#  nginx-base/ の内容は nginx/docker-nginx の mainline/debian/ をそのまま取込)
# ============================================================================
FROM debian:trixie-slim AS nginx

LABEL maintainer="NGINX Docker Maintainers <docker-maint@nginx.com>"

ENV NGINX_VERSION   1.31.1
ENV NJS_VERSION     0.9.9
ENV NJS_RELEASE     1~trixie
ENV ACME_VERSION    0.4.1
ENV PKG_RELEASE     1~trixie
ENV DYNPKG_RELEASE  1~trixie

RUN set -x \
# create nginx user/group first, to be consistent throughout docker variants
    && groupadd --system --gid 101 nginx \
    && useradd --system --gid nginx --no-create-home --home /nonexistent --comment "nginx user" --shell /bin/false --uid 101 nginx \
    && apt-get update \
    && apt-get install --no-install-recommends --no-install-suggests -y gnupg1 ca-certificates \
    && \
    NGINX_GPGKEYS="573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62 8540A6F18833A80E9C1653A42FD21310B49F6B46 9E9BE90EACBCDE69FE9B204CBCDCD8A38D88A2B3"; \
    NGINX_GPGKEY_PATH=/etc/apt/keyrings/nginx-archive-keyring.gpg; \
    export GNUPGHOME="$(mktemp -d)"; \
    found=''; \
    for NGINX_GPGKEY in $NGINX_GPGKEYS; do \
    for server in \
        hkp://keyserver.ubuntu.com:80 \
        pgp.mit.edu \
    ; do \
        echo "Fetching GPG key $NGINX_GPGKEY from $server"; \
        gpg1 --batch --keyserver "$server" --keyserver-options timeout=10 --recv-keys "$NGINX_GPGKEY" && found=yes && break; \
    done; \
    test -z "$found" && echo >&2 "error: failed to fetch GPG key $NGINX_GPGKEY" && exit 1; \
    done; \
    gpg1 --batch --export $NGINX_GPGKEYS > "$NGINX_GPGKEY_PATH" ; \
    rm -rf "$GNUPGHOME"; \
    apt-get remove --purge --auto-remove -y gnupg1 && rm -rf /var/lib/apt/lists/* \
    && dpkgArch="$(dpkg --print-architecture)" \
    && nginxPackages=" \
        nginx=${NGINX_VERSION}-${PKG_RELEASE} \
        nginx-module-xslt=${NGINX_VERSION}-${DYNPKG_RELEASE} \
        nginx-module-geoip=${NGINX_VERSION}-${DYNPKG_RELEASE} \
        nginx-module-image-filter=${NGINX_VERSION}-${DYNPKG_RELEASE} \
        nginx-module-njs=${NGINX_VERSION}+${NJS_VERSION}-${NJS_RELEASE} \
        nginx-module-acme=${NGINX_VERSION}+${ACME_VERSION}-${PKG_RELEASE} \
    " \
    && case "$dpkgArch" in \
        amd64|arm64) \
# arches officialy built by upstream
            echo "deb [signed-by=$NGINX_GPGKEY_PATH] https://nginx.org/packages/mainline/debian/ trixie nginx" >> /etc/apt/sources.list.d/nginx.list \
            && apt-get update \
            ;; \
        *) \
            echo >&2 "error: this image only supports amd64 / arm64 (got: $dpkgArch)" \
            && exit 1 \
            ;; \
    esac \
    \
    && apt-get install --no-install-recommends --no-install-suggests -y \
                        $nginxPackages \
                        gettext-base \
                        curl \
    && apt-get remove --purge --auto-remove -y && rm -rf /var/lib/apt/lists/* /etc/apt/sources.list.d/nginx.list \
# forward request and error logs to docker log collector
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log \
# create a docker-entrypoint.d directory
    && mkdir /docker-entrypoint.d

COPY nginx-base/docker-entrypoint.sh /
COPY nginx-base/10-listen-on-ipv6-by-default.sh /docker-entrypoint.d/
COPY nginx-base/15-local-resolvers.envsh /docker-entrypoint.d/
COPY nginx-base/20-envsubst-on-templates.sh /docker-entrypoint.d/
COPY nginx-base/30-tune-worker-processes.sh /docker-entrypoint.d/

EXPOSE 80
STOPSIGNAL SIGQUIT
CMD ["nginx", "-g", "daemon off;"]


# ============================================================================
# Stage 1: https-portal レイヤー (既存ビルド手順)
# ============================================================================
FROM nginx

# Set by `docker buildx build`
ARG  TARGETPLATFORM

# Delete sym links from nginx image, install logrotate
RUN rm /var/log/nginx/access.log && \
    rm /var/log/nginx/error.log

WORKDIR /root

RUN apt-get clean && \
    apt-get update && \
    apt-get install -y python3 ruby cron iproute2 apache2-utils logrotate wget inotify-tools xz-utils && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Need this already now, but cannot copy remainder of fs_overlay yet
COPY ./fs_overlay/usr/bin/archname /usr/bin/

ENV S6_OVERLAY_VERSION=v3.2.0.0
ENV DOCKER_GEN_VERSION=0.14.0
ENV ACME_TINY_VERSION=5.0.1

RUN sh -c "wget -q https://github.com/just-containers/s6-overlay/releases/download/${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz -O /tmp/s6-overlay-noarch.tar.xz" && \
    tar -xf /tmp/s6-overlay-noarch.tar.xz -C / && \
    rm -rf /tmp/s6-overlay-noarch.tar.xz

RUN sh -c "wget -q https://github.com/just-containers/s6-overlay/releases/download/$S6_OVERLAY_VERSION/s6-overlay-`archname s6-overlay`.tar.xz -O /tmp/s6-overlay.tar.xz" && \
    tar -xf /tmp/s6-overlay.tar.xz -C / && \
    rm -rf /tmp/s6-overlay.tar.xz
RUN sh -c "wget -q https://github.com/nginx-proxy/docker-gen/releases/download/$DOCKER_GEN_VERSION/docker-gen-linux-`archname docker-gen`-$DOCKER_GEN_VERSION.tar.gz -O /tmp/docker-gen.tar.gz" && \
    tar xzf /tmp/docker-gen.tar.gz -C /bin && \
    rm -rf /tmp/docker-gen.tar.gz

# Bring the container down if stage fails
ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2

RUN wget -q https://raw.githubusercontent.com/diafygi/acme-tiny/$ACME_TINY_VERSION/acme_tiny.py -O /bin/acme_tiny

RUN rm /etc/nginx/conf.d/default.conf /etc/crontab

COPY ./fs_overlay /

RUN chmod a+x /bin/* && \
    chmod 0644 /etc/logrotate.d/nginx && \
    chmod a+x /etc/cont-init.d/* && \
    chmod a+x /etc/services.d/**/*

VOLUME /var/lib/https-portal
VOLUME /var/log/nginx


# HEALTHCHECK --interval=5s --timeout=3s --start-period=10s --retries=3 CMD wget -q -O /dev/null http://localhost:80/ || exit 1

# HEALTHCHECK --interval=5s --timeout=1s --start-period=2s --retries=20 CMD   service nginx status || exit 1

ENTRYPOINT ["/init"]
