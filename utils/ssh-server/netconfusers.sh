#!/bin/sh
# Lincensed under BSD 3 Clause License
# SPDX-License-Identifier: BSD-3-Clause
# Copyright, 2019 Nokia

( port=''
while [ -z "$port" ]
do
port=$(ss  state established dst 127.0.0.1:18830 |  grep 127.0.0.1:18830 | awk '{print $4}' | sed "s/.*:\([0-9]\+\)/\1/")
done
echo $(whoami) > /tmp/netconfusers/$port ) &
/usr/bin/socat - TCP:127.0.0.1:18830,forever

