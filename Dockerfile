FROM quay.io/ceph/ceph:v19.2.4 as go-builder

LABEL org.opencontainers.image.source="https://github.com/r-oswald/rbd-swarm-mount-plugin"
LABEL org.opencontainers.image.description="Docker volume plugin for Ceph RBD"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.version="4.2.1"

ENV GO_VERSION 1.26.3
ENV CEPH_VERSION squid

# The Ceph runtime image ships librbd but not the *-devel headers needed for cgo.
# Add the Squid yum repo and pull them in alongside Go.
RUN printf '%s\n' \
        '[ceph-devel]' \
        'name=Ceph $basearch packages' \
        "baseurl=https://download.ceph.com/rpm-${CEPH_VERSION}/el9/\$basearch" \
        'enabled=1' \
        'gpgcheck=1' \
        'gpgkey=https://download.ceph.com/keys/release.asc' \
        > /etc/yum.repos.d/ceph-devel.repo \
    && dnf install -y git gcc make pkgconfig libcephfs-devel librbd-devel librados-devel \
    && curl -fsSL https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz | tar -xz -C /usr/local \
    && dnf clean all

ENV GOPATH /go
ENV PATH /usr/local/go/bin:$GOPATH/bin:$PATH
RUN mkdir -p "$GOPATH/src" "$GOPATH/bin" && chmod -R 777 "$GOPATH"

COPY go.* main.go /go/src/github.com/wetopi/docker-volume-rbd/
COPY lib /go/src/github.com/wetopi/docker-volume-rbd/lib

WORKDIR /go/src/github.com/wetopi/docker-volume-rbd

RUN set -ex \
 && go mod tidy \
 && go install


FROM quay.io/ceph/ceph:v19.2.4

LABEL org.opencontainers.image.source="https://github.com/r-oswald/rbd-swarm-mount-plugin"
LABEL org.opencontainers.image.description="Docker volume plugin for Ceph RBD"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.version="4.2.1"

RUN mkdir -p /run/docker/plugins /mnt/state /mnt/volumes /etc/ceph

COPY --from=go-builder /go/bin/docker-volume-rbd .
CMD ["docker-volume-rbd"]
