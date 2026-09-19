FROM ubuntu:24.04@sha256:224a1869083a311ef3f13648a154ba79832fbef6364d31493642ca03082da254

ENV DEBIAN_FRONTEND=noninteractive
ARG UBUNTU_PORTS_MIRROR=http://ports.ubuntu.com/ubuntu-ports/

RUN sed -i \
	-e '/^## Ubuntu security updates/,$d' \
	-e "s|^URIs:.*|URIs: ${UBUNTU_PORTS_MIRROR}|" \
	-e 's/^Suites:.*/Suites: noble/' \
	-e 's/^Components:.*/Components: main/' \
	/etc/apt/sources.list.d/ubuntu.sources \
	&& apt-get \
		-o Acquire::Retries=5 \
		-o Acquire::http::Timeout=30 \
		update \
	&& apt-get \
		-o Acquire::Retries=5 \
		-o Acquire::http::Timeout=30 \
		install -y --no-install-recommends \
	ca-certificates \
	device-tree-compiler \
	file \
	python3 \
	rsync \
	squashfs-tools \
	u-boot-tools \
	xz-utils \
	&& rm -rf /var/lib/apt/lists/*

COPY docker/assemble-rootfs.sh /usr/local/bin/assemble-rootfs
RUN chmod 0755 /usr/local/bin/assemble-rootfs

ENTRYPOINT ["/usr/local/bin/assemble-rootfs"]
