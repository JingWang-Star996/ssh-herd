# -*- coding: utf-8 -*-
"""
Herd / 局域网 HTTP/HTTPS 代理（零依赖）。

用途：入栏期让同一二层网络里的其它机器借用 Shepherd 的网络出口。
  - HTTP  请求：直接转发
  - HTTPS 请求：CONNECT 隧道，端到端加密，代理侧看不到内容

启动：
    python lan_proxy.py --port 8890
其它机器（把 SHEPHERD_IP 换成主控机的局域网 IP）：
    $env:HTTP_PROXY  = "http://SHEPHERD_IP:8890"
    $env:HTTPS_PROXY = "http://SHEPHERD_IP:8890"

注意：本代理不带认证，只在可信局域网内使用，用完即关。
"""

import argparse
import select
import socket
import sys
import threading

BUF = 65536
CONNECT_TIMEOUT = 25
IDLE_TIMEOUT = 120

_state = {"conns": 0, "bytes": 0}
_lock = threading.Lock()


def _recv_request_head(sock):
    """读到完整的请求头（\r\n\r\n）为止，返回 (bytes, leftover)。"""
    data = b""
    while b"\r\n\r\n" not in data:
        try:
            chunk = sock.recv(8192)
        except OSError:
            break
        if not chunk:
            break
        data += chunk
        if len(data) > 65536:
            break
    head, sep, rest = data.partition(b"\r\n\r\n")
    return head, rest


def _pipe(a, b):
    """双向转发两个 socket，任一端关闭即收摊。"""
    try:
        while True:
            readable, _, _ = select.select([a, b], [], [], IDLE_TIMEOUT)
            if not readable:
                break
            for s in readable:
                try:
                    data = s.recv(BUF)
                except OSError:
                    return
                if not data:
                    return
                target = b if s is a else a
                target.sendall(data)
                with _lock:
                    _state["bytes"] += len(data)
    except Exception:
        pass
    finally:
        for s in (a, b):
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                s.close()
            except OSError:
                pass


def _resolve_target(host_raw, default_port):
    host = host_raw.decode("ascii", "replace")
    port = default_port
    if host.startswith("["):  # IPv6 字面量 [::1]:443
        end = host.find("]")
        if end > 0:
            port = int(host[end + 2:] or default_port)
            host = host[1:end]
    elif ":" in host:
        host, _, p = host.rpartition(":")
        if p.isdigit():
            port = int(p)
    return host, port


def _strip_hop_by_hop(lines):
    """去掉 Proxy-Connection / Connection 相关的逐跳头。"""
    drop = {"proxy-connection", "connection", "proxy-authenticate",
            "proxy-authorization", "keep-alive", "upgrade"}
    out = []
    for line in lines[1:]:
        name = line.split(b":", 1)[0].strip().lower().decode("latin-1", "replace")
        if name in drop:
            continue
        out.append(line)
    return out


def handle(client):
    with _lock:
        _state["conns"] += 1
    try:
        head, rest = _recv_request_head(client)
        if not head:
            return
        lines = head.split(b"\r\n")
        parts = lines[0].split()
        if len(parts) < 2:
            return
        method, target = parts[0], parts[1]

        if method.upper() == b"CONNECT":
            host, port = _resolve_target(target, 443)
            try:
                upstream = socket.create_connection((host, port), timeout=CONNECT_TIMEOUT)
            except Exception as exc:
                sys.stderr.write("[proxy] CONNECT %s:%s failed: %r\n" % (host, port, exc))
                sys.stderr.flush()
                client.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
                return
            client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            _pipe(client, upstream)
            return

        # 普通 HTTP：改写为相对路径，补上 Host，转发到目标服务器
        if target.startswith(b"http://"):
            path = target[7:]
            path = b"/" + path.split(b"/", 1)[1] if b"/" in path else b"/"
            scheme_host = target[7:].split(b"/", 1)[0]
            default_port = 80
        else:
            path = target
            scheme_host = None
            default_port = 80
            for line in lines[1:]:
                if line.lower().startswith(b"host:"):
                    scheme_host = line.split(b":", 1)[1].strip()
                    break
        if not scheme_host:
            client.sendall(b"HTTP/1.1 400 Bad Request\r\n\r\n")
            return

        host, port = _resolve_target(scheme_host, default_port)
        req_lines = [b" ".join([method, path, b"HTTP/1.1"])] + _strip_hop_by_hop(lines)
        req_lines.append(b"Connection: close")
        body = b"\r\n".join(req_lines) + b"\r\n\r\n" + rest

        try:
            upstream = socket.create_connection((host, port), timeout=CONNECT_TIMEOUT)
        except Exception as exc:
            sys.stderr.write("[proxy] %s -> %s:%s failed: %r\n" % (method.decode(), host, port, exc))
            sys.stderr.flush()
            client.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
            return
        upstream.sendall(body)
        _pipe(client, upstream)
    except Exception as exc:
        sys.stderr.write("[proxy] handler error: %r\n" % (exc,))
        sys.stderr.flush()
    finally:
        with _lock:
            _state["conns"] -= 1
        try:
            client.close()
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser(description="局域网 HTTP/HTTPS 代理")
    ap.add_argument("--port", type=int, default=8890)
    ap.add_argument("--bind", default="0.0.0.0")
    a = ap.parse_args()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((a.bind, a.port))
    srv.listen(128)
    print("listening on %s:%d" % (a.bind, a.port), flush=True)

    try:
        while True:
            conn, addr = srv.accept()
            threading.Thread(target=handle, args=(conn,), daemon=True).start()
    except KeyboardInterrupt:
        pass
    finally:
        srv.close()


if __name__ == "__main__":
    main()
