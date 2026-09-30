FROM debian:bookworm-slim

# Install Ganesha, utils, and dependencies
# We also install dbus and rpcbind which are often required by Ganesha
# Recommends kept until functional tests show they're not needed.
# hadolint ignore=DL3015
RUN apt-get update && apt-get install -y \
    nfs-ganesha \
    nfs-ganesha-vfs \
    dbus \
    bash \
    jq \
    && rm -rf /var/lib/apt/lists/*

# Create required directories
RUN mkdir -p /var/run/ganesha \
    && mkdir -p /var/run/dbus

# Copy the run script
COPY run.sh /run.sh
RUN chmod a+x /run.sh

# Run the script directly (We are not using S6 overlay in this base)
CMD [ "/run.sh" ]
