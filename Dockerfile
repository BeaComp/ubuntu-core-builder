FROM ubuntu:24.04

ENV container=docker
ENV LC_ALL=C
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    systemd \
    systemd-sysv \
    snapd \
    apparmor \
    sudo \
    git \
    curl \
    jq \
    squashfs-tools \
    dosfstools \
    mtools \
    build-essential \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

RUN curl -L https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
    -o /usr/bin/yq && chmod +x /usr/bin/yq

RUN systemctl mask \
    systemd-udevd.service \
    systemd-udevd-kernel.socket \
    systemd-udevd-control.socket \
    systemd-modules-load.service \
    systemd-networkd.service \
    systemd-resolved.service \
    sys-kernel-debug.mount \
    sys-kernel-tracing.mount \
    sys-kernel-config.mount \
    dev-hugepages.mount \
    dev-mqueue.mount \
    apparmor.service

WORKDIR /workspace
STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd", "--system", "--unit=multi-user.target"]