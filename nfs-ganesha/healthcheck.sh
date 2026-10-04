#!/bin/bash
# Docker HEALTHCHECK: makes an NFS NULL call (RPC program 100003, version 4,
# procedure 0) to Ganesha on port 2049 and expects a successful reply within
# 5 seconds. Connecting alone isn't enough: with Ganesha hung, the kernel still
# accepts TCP connections.
set -e

exec 3<> /dev/tcp/127.0.0.1/2049

# Record mark (last fragment, 40 bytes), xid 1, CALL, RPC version 2,
# program 100003, version 4, procedure 0, AUTH_NONE credential and verifier.
printf '\x80\x00\x00\x28\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x02\x00\x01\x86\xa3\x00\x00\x00\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' >&3

# Reply after the record mark: xid 1, REPLY, MSG_ACCEPTED, AUTH_NONE verifier
# (flavour 0, length 0), SUCCESS.
reply=$(timeout 5 head -c 28 <&3 | od -An -tx1 | tr -d ' \n')
[ "${reply:8}" = "000000010000000100000000000000000000000000000000" ]
