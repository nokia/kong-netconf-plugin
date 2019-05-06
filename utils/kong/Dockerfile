# Lincensed under BSD 3 Clause License
# SPDX-License-Identifier: BSD-3-Clause
# Copyright, 2019 Nokia

FROM kong:1.1.1-alpine
RUN apk update \
	&& apk add musl-dev \
	&& apk add gcc \
	&& apk add make \
	&& apk add openssh-client \
	&&  rm -rf /var/cache/apk/* 
RUN luarocks install lpty \
	&& luarocks install luaxml
