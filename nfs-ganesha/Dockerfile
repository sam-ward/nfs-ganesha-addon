# Ganesha comes from trixie-backports (9.x); trixie's own 6.5 returns
# "Remote I/O error" on the mount root after writes. Debian's 9.14 reads one
# byte past NFS owner/group strings, which breaks numeric group changes, so
# this stage rebuilds Debian's own source package with the upstream fix in
# patches/. Drop it once trixie-backports ships the fix.
FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a AS ganesha
ARG GANESHA_VERSION=9.14-1~bpo13+1
RUN printf '%s\n' 'deb http://deb.debian.org/debian trixie-backports main' \
        'deb-src http://deb.debian.org/debian trixie main' \
        'deb-src http://deb.debian.org/debian trixie-backports main' \
        > /etc/apt/sources.list.d/backports.list \
    && apt-get update \
    && apt-get build-dep -y -t trixie-backports "nfs-ganesha=${GANESHA_VERSION}" \
    && apt-get install -y --no-install-recommends quilt
WORKDIR /build
RUN apt-get source "nfs-ganesha=${GANESHA_VERSION}" && mv nfs-ganesha-*/ src
COPY patches/ /build/src/debian/patches/addon/
WORKDIR /build/src
# apt-get source has already applied Debian's series, so quilt applies ours.
# The +addon1 version suffix marks the packages as rebuilt here.
RUN for p in debian/patches/addon/*.patch; do echo "addon/${p##*/}" >> debian/patches/series; done \
    && QUILT_PATCHES=debian/patches quilt push -a \
    && sed -i '1s/(\([^)]*\))/(\1+addon1)/' debian/changelog \
    && if ! DEB_BUILD_OPTIONS="nocheck nodoc parallel=$(nproc)" \
            dpkg-buildpackage -B -uc -us > /build/build.log 2>&1; then \
        tail -50 /build/build.log; exit 1; \
    fi

FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a

# Install Ganesha (the packages built above; libntirpc from trixie-backports),
# utils, and dependencies. Everything else is trixie.
COPY --from=ganesha /build/nfs-ganesha_*.deb /build/nfs-ganesha-vfs_*.deb /tmp/debs/
RUN echo 'deb http://deb.debian.org/debian trixie-backports main' > /etc/apt/sources.list.d/backports.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends -t trixie-backports /tmp/debs/*.deb \
    && apt-get install -y --no-install-recommends \
        dbus \
        bash \
        jq \
        curl \
        iproute2 \
    && rm -rf /var/lib/apt/lists/* /tmp/debs

# The Supervisor (and HA's image builder) pass the app version; run.sh logs it.
ARG BUILD_VERSION=unknown
ENV ADDON_VERSION=${BUILD_VERSION}

# Create required directories
RUN mkdir -p /var/run/ganesha \
    && mkdir -p /var/run/dbus

# Copy the run script
COPY run.sh gen-config.sh migrate-options.sh healthcheck.sh /
RUN chmod a+x /run.sh /gen-config.sh /migrate-options.sh /healthcheck.sh

# With the Watchdog switch on, the Supervisor restarts the app when it turns
# unhealthy (NFS stops answering) or stops unexpectedly. The start period
# covers waiting for the network for authorized_ips "auto".
HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --start-interval=5s --retries=3 \
    CMD ["/healthcheck.sh"]

# Run the script directly (We are not using S6 overlay in this base)
CMD [ "/run.sh" ]
