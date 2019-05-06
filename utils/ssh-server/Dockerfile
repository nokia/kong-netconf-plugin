# Lincensed under BSD 3 Clause License
# SPDX-License-Identifier: BSD-3-Clause
# Copyright, 2019 Nokia

FROM alpine:3.9.2
RUN apk update \
	&& apk add openssh-server \ 
	&& apk add socat \
	&& apk add shadow \
	&& apk add iproute2 \
	&& rm -rf /var/cache/apk/*
RUN ssh-keygen -A
RUN useradd -d /home/netconf -s /bin/sh -p --disabled-password netconf
RUN mkdir -p /home/netconf/.ssh
RUN chown -R netconf:netconf /home/netconf
RUN mkdir -p /tmp/netconfscript
COPY ./netconfusers.sh /tmp/netconfscript/netconfusers.sh
COPY ./startup.sh /usr/local/startup.sh
ENTRYPOINT ["/bin/sh", "/usr/local/startup.sh"]
