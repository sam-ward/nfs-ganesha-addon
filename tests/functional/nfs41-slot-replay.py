#!/usr/bin/env python3
"""Checks that a SEQUENCE that fails its reply size check leaves nothing in
its session slot (upstream nfs-ganesha 5ec52b7723).

A raw NFSv4.1 client, as no NFS client lets you choose the channel attributes:
it opens a session whose ca_maxresponsesize_cached is 0, so every SEQUENCE
that asks for its reply to be cached fails with NFS4ERR_REP_TOO_BIG_TO_CACHE.
By then Ganesha has advanced the slot and dropped it, but without the fix it
still stores that failed reply in the slot afterwards, without the slot lock
(a use-after-free if the session is destroyed meanwhile). Retrying the same
sequence id shows which happened: the stored error comes back without the fix,
and NFS4ERR_RETRY_UNCACHED_REP with it.

Prints one "<step> <status>" line per step. Usage: nfs41-slot-replay.py [host]
"""
import os
import socket
import struct
import sys

STATUS = {
    0: "NFS4_OK",
    10052: "NFS4ERR_BADSESSION",
    10063: "NFS4ERR_SEQ_MISORDERED",
    10066: "NFS4ERR_REP_TOO_BIG",
    10067: "NFS4ERR_REP_TOO_BIG_TO_CACHE",
    10068: "NFS4ERR_RETRY_UNCACHED_REP",
}
OP_EXCHANGE_ID, OP_CREATE_SESSION, OP_DESTROY_SESSION = 42, 43, 44
OP_SEQUENCE, OP_DESTROY_CLIENTID = 53, 57


def u32(v):
    return struct.pack(">I", v)


def u64(v):
    return struct.pack(">Q", v)


def opaque(b):
    return u32(len(b)) + b + b"\0" * (-len(b) % 4)


class Reader:
    def __init__(self, data):
        self.data, self.pos = data, 0

    def u32(self):
        (v,) = struct.unpack_from(">I", self.data, self.pos)
        self.pos += 4
        return v

    def u64(self):
        (v,) = struct.unpack_from(">Q", self.data, self.pos)
        self.pos += 8
        return v

    def fixed(self, n):
        b = self.data[self.pos:self.pos + n]
        self.pos += n + (-n % 4)
        return b

    def opaque(self):
        return self.fixed(self.u32())


class Client:
    def __init__(self, host):
        self.sock = socket.create_connection((host, 2049), timeout=10)
        self.xid = 1

    def _recv(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("server closed the connection")
            buf += chunk
        return buf

    def compound(self, ops):
        """Sends one NFSv4.1 COMPOUND; returns a Reader at its first result."""
        self.xid += 1
        cred = u32(0) + opaque(b"slot-test") + u32(0) + u32(0) + u32(0)  # AUTH_SYS root
        call = (u32(self.xid) + u32(0) + u32(2) + u32(100003) + u32(4) + u32(1)
                + u32(1) + opaque(cred) + u32(0) + u32(0)
                + opaque(b"") + u32(1) + u32(len(ops)) + b"".join(ops))
        self.sock.sendall(u32(0x80000000 | len(call)) + call)
        reply = b""
        while True:
            mark = struct.unpack(">I", self._recv(4))[0]
            reply += self._recv(mark & 0x7FFFFFFF)
            if mark & 0x80000000:
                break
        r = Reader(reply)
        if r.u32() != self.xid or r.u32() != 1 or r.u32() != 0:
            raise RuntimeError("not an accepted RPC reply")
        r.u32()
        r.opaque()  # verifier
        if r.u32() != 0:
            raise RuntimeError("RPC call not executed")
        r.u32()      # COMPOUND status
        r.opaque()   # tag
        r.u32()      # result count
        return r


def op_status(r, opnum):
    if r.u32() != opnum:
        raise RuntimeError(f"unexpected reply to op {opnum}")
    return r.u32()


def name(status):
    return STATUS.get(status, str(status))


def sequence(c, sessionid, seqid, cachethis):
    r = c.compound([u32(OP_SEQUENCE) + sessionid + u32(seqid) + u32(0) + u32(0)
                    + u32(1 if cachethis else 0)])
    return op_status(r, OP_SEQUENCE)


def channel(maxreq, maxresp, maxresp_cached, maxops, maxrequests):
    return (u32(0) + u32(maxreq) + u32(maxresp) + u32(maxresp_cached)
            + u32(maxops) + u32(maxrequests) + u32(0))


def main():
    c = Client(sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1")
    # EXCHANGE_ID: a new client owner each run, no state protection.
    r = c.compound([u32(OP_EXCHANGE_ID) + os.urandom(8)
                    + opaque(b"slot-test-" + os.urandom(8).hex().encode())
                    + u32(0) + u32(0) + u32(0)])
    st = op_status(r, OP_EXCHANGE_ID)
    print("exchange_id", name(st))
    if st:
        return 1
    clientid, csa_sequence = r.u64(), r.u32()

    # CREATE_SESSION: replies may be up to 1 MB, but none may be cached.
    r = c.compound([u32(OP_CREATE_SESSION) + u64(clientid) + u32(csa_sequence) + u32(0)
                    + channel(1 << 20, 1 << 20, 0, 16, 4)
                    + channel(4096, 4096, 0, 2, 1)
                    + u32(0x40000000) + u32(1) + u32(0)])
    st = op_status(r, OP_CREATE_SESSION)
    print("create_session", name(st))
    if st:
        return 1
    sessionid = r.fixed(16)

    print("sequence_1", name(sequence(c, sessionid, 1, False)))
    print("sequence_2_cachethis", name(sequence(c, sessionid, 2, True)))
    print("retry_2", name(sequence(c, sessionid, 2, False)))

    c.compound([u32(OP_DESTROY_SESSION) + sessionid])
    c.compound([u32(OP_DESTROY_CLIENTID) + u64(clientid)])
    return 0


if __name__ == "__main__":
    sys.exit(main())
