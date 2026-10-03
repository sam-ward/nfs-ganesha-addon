FROM debian:trixie-slim

# Install Ganesha, utils, and dependencies.
# Ganesha comes from trixie-backports (9.x); trixie's own 6.5 returns
# "Remote I/O error" on the mount root after writes. Everything else is trixie.
RUN echo 'deb http://deb.debian.org/debian trixie-backports main' > /etc/apt/sources.list.d/backports.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends -t trixie-backports \
        nfs-ganesha \
        nfs-ganesha-vfs \
    && apt-get install -y --no-install-recommends \
        dbus \
        bash \
        jq \
    && rm -rf /var/lib/apt/lists/*

# Create required directories
RUN mkdir -p /var/run/ganesha \
    && mkdir -p /var/run/dbus

# Copy the run script
COPY run.sh gen-config.sh /
RUN chmod a+x /run.sh /gen-config.sh

# Run the script directly (We are not using S6 overlay in this base)
CMD [ "/run.sh" ]
