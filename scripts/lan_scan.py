"""Herd / 局域网主机发现：ping + ARP + 常见远程端口（22/3389/5985/5900）扫描。

核心价值：Windows 防火墙默认拦 ICMP 和全部入站端口 —— 机器在线照样 ping 不通。
--arp 模式用 TCP 握手触发 ARP（二层协议，不受防火墙影响），能发现 ping 不通的在线主机。

用法:
  python lan_scan.py                          # 自动探测本机所有直连网段
  python lan_scan.py --arp --net 192.168.1.0/24 --ports 22
  python lan_scan.py --ports 22,3389,5985,5900
"""
import argparse
import concurrent.futures as cf
import ipaddress
import platform
import re
import socket
import subprocess
import sys
import time


def local_nets():
    """列出本机直连网段（只在 /20~/30 之间，排除 loopback / link-local）。"""
    nets, seen = [], set()

    def add(ip, mask):
        try:
            n = ipaddress.ip_network(f"{ip}/{mask}", strict=False)
        except ValueError:
            return
        if not (20 <= n.prefixlen < 31):
            return
        if ip.startswith("127.") or n.network_address.is_link_local:
            return
        if str(n) in seen:
            return
        seen.add(str(n))
        nets.append(n)

    if platform.system() == "Windows":
        out = subprocess.run(["ipconfig"], capture_output=True, text=True,
                             encoding="gbk", errors="replace").stdout
        pending = None
        for line in out.splitlines():
            m = re.search(r"IPv4[^\d]*(\d+\.\d+\.\d+\.\d+)", line)
            if m:
                pending = m.group(1)
                continue
            m = re.search(r"子网掩码[^\d]*(\d+\.\d+\.\d+\.\d+)", line)
            if m and pending:
                add(pending, m.group(1))
                pending = None
    else:
        out = subprocess.run(["ip", "-o", "-4", "addr"], capture_output=True, text=True).stdout
        for line in out.splitlines():
            m = re.search(r"inet (\d+\.\d+\.\d+\.\d+)/(\d+)", line)
            if m:
                add(m.group(1), m.group(2))
    return nets


def arp_table():
    """读取系统 ARP 表 → {ip: (mac, type)}。ARP 是二层协议，不受防火墙影响。

    ⚠️ 判定「同网段有没有这台机器」必须用 ARP，不能用 ping：
    Windows 防火墙默认拦 ICMP echo，主机在线照样 ping 不通。
    """
    r = subprocess.run(["arp", "-a"], capture_output=True, text=True,
                       encoding="gbk", errors="replace")
    table = {}
    for line in r.stdout.splitlines():
        m = re.search(r"(\d+\.\d+\.\d+\.\d+)\s+([0-9a-fA-F]{2}(?:-[0-9a-fA-F]{2}){5})\s+(\S+)", line)
        if m:
            ip, mac, t = m.group(1), m.group(2).lower(), m.group(3)
            # 全零 MAC 或 ff-ff-ff 是无应答的垃圾条目，跳过
            if mac.replace("-", "") != "000000000000" and not mac.startswith("ff-"):
                prev = table.get(ip)
                if prev is None or prev[0] == "00-00-00-00-00-00":
                    table[ip] = (mac, t)
    return table


def arp_discover(net, workers=64):
    """ARP 发现：对每个 IP 发一次 TCP 握手尝试（只为触发 ARP 请求），
    再读 ARP 表。能发现 ping 不通但真实在线的主机。
    """
    hosts = list(net.hosts())
    with cf.ThreadPoolExecutor(max_workers=workers) as ex:
        list(ex.map(lambda h: (port_open(h, 137, 0.25), port_open(h, 445, 0.25)), hosts))
    return arp_table()


def ping(ip, timeout_ms=900):
    """返回 (是否通, 平均延迟毫秒 or None)。"""
    if platform.system() == "Windows":
        cmd = ["ping", "-n", "1", "-w", str(timeout_ms), str(ip)]
    else:
        cmd = ["ping", "-c", "1", "-W", str(max(1, timeout_ms // 1000)), str(ip)]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True,
                           encoding="gbk", errors="replace", timeout=timeout_ms / 1000 + 2)
        alive = "TTL=" in r.stdout.upper() or "ttl=" in r.stdout
        if not alive:
            return False, None
        m = re.search(r"(?:平均|Average)\s*=\s*(\d+)ms|time[<=]\s*([\d.]+)\s*ms", r.stdout, re.I)
        if m:
            return True, float(m.group(1) or m.group(2))
        return True, None
    except subprocess.TimeoutExpired:
        return False, None
    except Exception:
        return False, None


def port_open(ip, port, timeout=1.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        return s.connect_ex((str(ip), port)) == 0
    except OSError:
        return False
    finally:
        s.close()


def probe(ip, ports, do_ping=True):
    res = {"ip": str(ip), "alive": True, "rtt": None, "ports": [], "hostname": None}
    if do_ping:
        alive, rtt = ping(ip)
        res["alive"], res["rtt"] = alive, rtt
        if not alive:
            return res
    for p in ports:
        if port_open(ip, p):
            res["ports"].append(p)
    if res["ports"]:
        try:
            res["hostname"] = socket.gethostbyaddr(str(ip))[0]
        except OSError:
            pass
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--net", action="append", help="网段，如 192.168.1.0/24（可多次）")
    ap.add_argument("--ports", default="22,3389,5985,5900")
    ap.add_argument("--workers", type=int, default=64)
    ap.add_argument("--no-ping", action="store_true", help="跳过 ping，直接扫端口")
    ap.add_argument("--arp", action="store_true",
                    help="用 ARP 表发现在线主机（推荐：Windows 防火墙默认拦 ICMP，ping 会漏报在线机器）")
    a = ap.parse_args()

    nets = [ipaddress.ip_network(n, strict=False) for n in a.net] if a.net else local_nets()
    ports = [int(p) for p in a.ports.split(",") if p.strip()]

    if not nets:
        print("[错误] 未识别到可用网段，请用 --net 指定")
        return 2

    t0 = time.time()
    hosts = []
    for n in nets:
        hosts += list(n.hosts())
    print(f"网段: {', '.join(str(n) for n in nets)}")
    print(f"待探测: {len(hosts)} 个地址 / 端口 {ports} / {'TCP only' if a.no_ping else 'ping+TCP'}")
    print("-" * 62)

    arp = arp_discover(nets[0], a.workers) if (a.arp and nets) else {}
    if a.arp and nets:
        for n in nets[1:]:
            arp.update(arp_discover(n, a.workers))
        print(f"ARP 表里有 MAC 的地址: {len(arp)} 个")
        print("-" * 62)

    out = []
    with cf.ThreadPoolExecutor(max_workers=a.workers) as ex:
        futs = {ex.submit(probe, ip, ports, not a.no_ping): ip for ip in hosts}
        done = 0
        for f in cf.as_completed(futs):
            done += 1
            if done % 40 == 0:
                print(f"  ...{done}/{len(hosts)}", flush=True)
            try:
                out.append(f.result())
            except Exception:
                pass

    if a.arp:
        inrange = [ip for ip in arp if any(ipaddress.ip_address(ip) in n for n in nets)]
        print(f"\n=== ARP 发现的主机 {len(inrange)} 台（在扫描网段内，二层可达=同网）===")
        for ip in sorted(inrange, key=lambda x: ipaddress.ip_address(x)):
            mac, t = arp[ip]
            tag = " ".join(f"{p}:OPEN" for p in ports if port_open(ip, p)) or "端口全关(防火墙屏蔽)"
            try:
                hn = socket.gethostbyaddr(ip)[0]
            except OSError:
                hn = ""
            print(f"  {ip:<16} {mac:<18} {t:<10} {tag}  {hn}")

    alive = [r for r in out if r["alive"]]
    print(f"\n=== ping 通的主机 {len(alive)} 台 (耗时 {time.time() - t0:.1f}s) ===")
    if not alive and arp:
        print("  注意：无人响应 ping，但 ARP 里有 MAC → 这些机器在线，只是防火墙拦了 ICMP。")
        print("        ping通 != 在线，本机→对端是否被拦取决于对端防火墙。")
    for r in sorted(alive, key=lambda x: ipaddress.ip_address(x["ip"])):
        rtt = f"{r['rtt']:.0f}ms" if r["rtt"] is not None else "?"
        tag = " ".join(f"{p}:OPEN" for p in r["ports"]) or "无开放端口"
        hn = f"  [{r['hostname']}]" if r["hostname"] else ""
        print(f"  {r['ip']:<16} {rtt:<7} {tag}{hn}")

    ssh = [r for r in alive if 22 in r["ports"]]
    if ssh:
        print(f"\n=== 可直接 SSH 的主机（{len(ssh)}）===")
        for r in ssh:
            print(f"  {r['ip']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
