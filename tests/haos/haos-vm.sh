#!/usr/bin/env bash
# A Home Assistant OS VM for release testing, run with QEMU/KVM inside a
# container (tests/haos/Dockerfile), so the host only needs Docker and
# /dev/kvm. State (disk image, credentials, logs) lives in .test-haos/.
#
#   haos-vm.sh start            download HAOS (first run) and boot the VM
#   haos-vm.sh wait             wait until Home Assistant's API answers
#   haos-vm.sh onboard          create the test user; saves a refresh token
#   haos-vm.sh repo [BRANCH]    serve this git repo to the VM over HTTP, with
#                               BRANCH (default: current) as branch haos-test;
#                               prints the repository URL to add in HAOS
#   haos-vm.sh api METHOD PATH [JSON]
#                               call the Supervisor API through Home Assistant
#                               (/api/hassio/PATH)
#   haos-vm.sh console CMD      run a command on the HAOS console (as root,
#                               in the "ha" CLI's shell) and print its output
#   haos-vm.sh stop             shut the VM down cleanly
#
# Ports on 127.0.0.1: Home Assistant 18123 (to the VM's port 80: new installs
# of HA 2026.9+ serve there, and 8123 only redirects), NFS 12049 (to 2049),
# observer 14357, repo server 18080 (the VM reaches it as 10.0.2.2:18080).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
STATE="$REPO/.test-haos"
IMAGE=nfs-ganesha-addon-haos
VM=nfs-ganesha-haos
HAOS_VERSION=${HAOS_VERSION:-18.3}
HA="http://127.0.0.1:18123"
CLIENT_ID="$HA/"

# Runs a command in the tools image, as the invoking user, on the host network.
tool() {
    docker run --rm -i --network host --user "$(id -u):$(id -g)" \
        -v "$STATE:/vm" -v "$REPO:/repo:ro" -w /vm -e HOME=/vm "$IMAGE" "$@"
}

start() {
    docker build -q -t "$IMAGE" "$REPO/tests/haos" > /dev/null
    mkdir -p "$STATE"
    if [ ! -f "$STATE/haos.qcow2" ]; then
        echo "Downloading HAOS $HAOS_VERSION..."
        tool sh -c "curl -fsSL -o haos.qcow2.xz \
            https://github.com/home-assistant/operating-system/releases/download/$HAOS_VERSION/haos_ova-$HAOS_VERSION.qcow2.xz \
            && xz -d haos.qcow2.xz && qemu-img resize -q haos.qcow2 64G \
            && cp /usr/share/OVMF/OVMF_VARS_4M.fd vars.fd"
    fi
    docker run -d --name "$VM" --network host --device /dev/kvm \
        --user "$(id -u):$(id -g)" --group-add "$(stat -c %g /dev/kvm)" \
        -v "$STATE:/vm" "$IMAGE" \
        qemu-system-x86_64 -machine q35,accel=kvm -cpu host -smp 4 -m 8192 \
        -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd \
        -drive if=pflash,format=raw,file=/vm/vars.fd \
        -drive file=/vm/haos.qcow2,if=virtio,cache=writeback \
        -netdev user,id=n0,hostfwd=tcp:127.0.0.1:18123-:80,hostfwd=tcp:127.0.0.1:12049-:2049,hostfwd=tcp:127.0.0.1:14357-:4357 \
        -device virtio-net-pci,netdev=n0 \
        -display none \
        -chardev socket,id=s0,path=/vm/serial.sock,server=on,wait=off,logfile=/vm/serial.log \
        -serial chardev:s0 \
        -monitor unix:/vm/monitor.sock,server,nowait > /dev/null
    echo "VM started (serial console: $STATE/serial.log)"
}

wait_ha() {
    echo -n "Waiting for Home Assistant"
    # Until Core is installed, a landing page answers every path with a
    # redirect. Core's API answers /api/ with 401 (or 200), onboarded or not.
    until [[ "$(tool curl -s -o /dev/null -w '%{http_code}' "$HA/api/" 2>/dev/null)" =~ ^(200|401)$ ]]; do
        echo -n .; sleep 10
    done
    echo " up"
}

onboard() {
    local password code
    password=$(tool python3 -c 'import secrets; print(secrets.token_urlsafe(16))')
    code=$(tool curl -fsS -X POST "$HA/api/onboarding/users" -H 'Content-Type: application/json' \
        -d "{\"client_id\":\"$CLIENT_ID\",\"name\":\"Test\",\"username\":\"test\",\"password\":\"$password\",\"language\":\"en\"}" \
        | tool jq -r .auth_code)
    tool curl -fsS -X POST "$HA/auth/token" -d grant_type=authorization_code \
        -d "code=$code" -d "client_id=$CLIENT_ID" | tool jq -r .refresh_token > "$STATE/refresh_token"
    printf 'username: test\npassword: %s\n' "$password" > "$STATE/credentials"
    local t; t=$(token)
    for step in core_config analytics; do
        tool curl -fsS -X POST "$HA/api/onboarding/$step" -H "Authorization: Bearer $t" \
            -H 'Content-Type: application/json' -d '{}' > /dev/null
    done
    tool curl -fsS -X POST "$HA/api/onboarding/integration" -H "Authorization: Bearer $t" \
        -H 'Content-Type: application/json' \
        -d "{\"client_id\":\"$CLIENT_ID\",\"redirect_uri\":\"$CLIENT_ID\"}" > /dev/null
    echo "Onboarded; login in $STATE/credentials"
}

token() {
    tool curl -fsS -X POST "$HA/auth/token" -d grant_type=refresh_token \
        -d "refresh_token=$(cat "$STATE/refresh_token")" -d "client_id=$CLIENT_ID" | tool jq -r .access_token
}

# Home Assistant's REST proxy (/api/hassio) only allows a few paths, so this
# goes through its WebSocket API's "supervisor/api" command (admin only).
api() {
    tool python3 - "$1" "$2" "${3:-}" "$(token)" <<'PY'
import base64, json, os, socket, struct, sys
method, path, data, tok = sys.argv[1:5]
s = socket.create_connection(("127.0.0.1", 18123), timeout=600)
key = base64.b64encode(os.urandom(16)).decode()
s.sendall(("GET /api/websocket HTTP/1.1\r\nHost: 127.0.0.1:18123\r\nUpgrade: websocket\r\n"
           "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % key).encode())
buf = b""
while b"\r\n\r\n" not in buf:
    buf += s.recv(4096)
buf = buf.split(b"\r\n\r\n", 1)[1]
def recv_exact(n):
    global buf
    while len(buf) < n:
        chunk = s.recv(65536)
        if not chunk: raise SystemExit("connection closed")
        buf += chunk
    out, buf = buf[:n], buf[n:]
    return out
def recv():
    msg = b""
    while True:
        b0, b1 = recv_exact(2)
        n = b1 & 0x7F
        if n == 126: n = struct.unpack(">H", recv_exact(2))[0]
        elif n == 127: n = struct.unpack(">Q", recv_exact(8))[0]
        payload, op = recv_exact(n), b0 & 0x0F
        if op == 0x9: send_frame(0xA, payload); continue   # ping -> pong
        if op == 0x8: raise SystemExit("server closed the connection")
        if op == 0xA: continue
        msg += payload
        if b0 & 0x80: return json.loads(msg)
def send_frame(op, payload):
    mask = os.urandom(4); n = len(payload)
    head = bytes([0x80 | op]) + (bytes([0x80 | n]) if n < 126 else
           bytes([0xFE]) + struct.pack(">H", n) if n < 65536 else bytes([0xFF]) + struct.pack(">Q", n))
    s.sendall(head + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))
def send(obj):
    send_frame(0x1, json.dumps(obj).encode())
recv(); send({"type": "auth", "access_token": tok})
if recv().get("type") != "auth_ok": raise SystemExit("auth failed")
req = {"id": 1, "type": "supervisor/api", "endpoint": "/" + path.lstrip("/"), "method": method.lower(), "timeout": None}
if data: req["data"] = json.loads(data)
send(req)
while True:
    r = recv()
    if r.get("id") == 1: break
if not r.get("success"):
    print(json.dumps(r.get("error")), file=sys.stderr); raise SystemExit(1)
print(json.dumps(r.get("result")))
PY
}

repo() {
    local branch=${1:-$(git -C "$REPO" rev-parse --abbrev-ref HEAD)}
    [ -d "$STATE/repo.git" ] || tool git init -q --bare repo.git
    # Publish BRANCH as haos-test: the VM's repository always tracks one name.
    tool git -C repo.git fetch -q --force /repo "+refs/heads/$branch:refs/heads/haos-test"
    tool git -C repo.git update-server-info
    if ! docker ps -q -f "name=^$VM-repo$" | grep -q .; then
        docker rm -f "$VM-repo" > /dev/null 2>&1 || true
        # Smart HTTP (git http-backend): the Supervisor clones with --depth=1,
        # which the dumb (plain file) protocol can't serve.
        docker run -d --name "$VM-repo" --network host --user "$(id -u):$(id -g)" \
            -v "$STATE:/vm:ro" "$IMAGE" python3 -c '
import http.server, os, subprocess
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self): self.cgi()
    def do_POST(self): self.cgi()
    def cgi(self):
        path, _, query = self.path.partition("?")
        n = int(self.headers.get("Content-Length") or 0)
        env = dict(os.environ, GIT_PROJECT_ROOT="/vm", GIT_HTTP_EXPORT_ALL="1",
                   PATH_INFO=path, QUERY_STRING=query, REQUEST_METHOD=self.command,
                   CONTENT_TYPE=self.headers.get("Content-Type", ""), CONTENT_LENGTH=str(n),
                   HTTP_GIT_PROTOCOL=self.headers.get("Git-Protocol", ""))
        out = subprocess.run(["git", "http-backend"], input=self.rfile.read(n), env=env,
                             capture_output=True).stdout
        head, _, body = out.partition(b"\r\n\r\n")
        status = 200
        lines = head.decode().split("\r\n")
        for l in lines:
            if l.lower().startswith("status:"): status = int(l.split()[1])
        self.send_response(status)
        for l in lines:
            k, _, v = l.partition(":")
            if k and k.lower() != "status": self.send_header(k, v.strip())
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
http.server.ThreadingHTTPServer(("127.0.0.1", 18080), H).serve_forever()' > /dev/null
    fi
    echo "http://10.0.2.2:18080/repo.git#haos-test"
}

# Types CMD on the serial console and prints what comes back until a quiet
# second. The console starts at a "login:" prompt; "root" needs no password.
console() {
    tool python3 - "$*" <<'PY'
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect("/vm/serial.sock"); s.settimeout(1)
def drain(wait):
    out, end = b"", time.time() + wait
    while time.time() < end:
        try:
            chunk = s.recv(65536)
            if chunk: out += chunk; end = max(end, time.time() + 1)
        except socket.timeout: pass
    return out.decode(errors="replace")
s.sendall(b"\r"); prompt = drain(2)
if "login:" in prompt:
    s.sendall(b"root\r"); drain(3)
if "ha >" in prompt or "ha >" in drain(1):
    s.sendall(b"login\r"); drain(2)   # from the ha CLI into a root shell
s.sendall(sys.argv[1].encode() + b"\r")
print(drain(int(__import__("os").environ.get("WAIT", "5"))))
PY
}

stop() {
    tool python3 -c 'import socket; s = socket.socket(socket.AF_UNIX); s.connect("/vm/monitor.sock"); s.sendall(b"system_powerdown\n")' || true
    timeout 180 docker wait "$VM" > /dev/null || true
    docker rm -f "$VM" "$VM-repo" > /dev/null 2>&1 || true
    echo "VM stopped"
}

case "${1:-}" in
    start) start ;;
    wait) wait_ha ;;
    onboard) onboard ;;
    repo) shift; repo "$@" ;;
    console) shift; console "$@" ;;
    api) shift; api "$@" ;;
    stop) stop ;;
    *) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 1 ;;
esac
