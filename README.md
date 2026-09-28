# Herd 牧群

**把散装的 Windows 机器，放牧成一群。**

一台主脑（Shepherd）通过局域网 SSH 统一接管同一二层网络里的多台 Windows 机器：
`ssh node-a "hostname"` 一句话执行、scp 传文件、批量并行派发。
无需公网、无需第三方远控、无需在每台机器上装 Agent 服务。

> **术语**：主控机 = **Shepherd（牧羊人）**；受管机 = **node（牛马）**；
> 把新机器纳入管理 = **Roundup（入栏）**。

---

## 这套体系解决什么问题

| 痛点 | Herd 的答案 |
|---|---|
| 向日葵/UU/ToDesk 有会话上限、版本握手、独占 attach | 纯 SSH，无状态无独占，还能 scp |
| 公网穿透有安全暴露面 | 全程局域网二层，不出网关 |
| 每台机器手工装环境慢且易错 | **AI 入栏**：把任务书发给目标机器上的 AI 助手，它自己完成安装配置并回报 |
| 机器下不了 GitHub / 没有网 | Shepherd 临时充当**局域网文件源 + HTTP 代理** |
| ping 不通误判机器不在线 | 内置 ARP 发现工具，专治 Windows 防火墙默认拦 ICMP |

---

## 架构

```
                    局域网（同一二层，如 192.168.1.0/24）
  ┌──────────────────────────────────────────────────────┐
  │                                                      │
  │   ┌──────────────┐    SSH 22 (ed25519 免密)    ┌──────────────┐
  │   │  Shepherd    │◄───────────────────────────►│   node-a     │
  │   │  (你的主控机) │   ssh / scp / 批量并行       │  Windows     │
  │   │              │                             │  (装 sshd)   │
  │   │  ssh_fleet   │◄───────────────────────────►│   node-b     │
  │   │  lan_scan    │        同上                  │   node-c ... │
  │   │  lanshare    │   8899 文件源 / 8890 代理     │              │
  │   └──────────────┘    （入栏期临时提供）         └──────────────┘
  │                                                      │
  └──────────────────────────────────────────────────────┘
```

- **稳定期**：只有 SSH 22 这一条通道，够用。
- **入栏期**（新机器还没有 sshd / 下载不了东西）：Shepherd 临时开放 8899（静态文件源）和 8890（HTTP/HTTPS 代理），目标机器借道装好 sshd 后即关。

---

## 目录结构

```
ssh-herd/
├── scripts/
│   ├── lan_scan.py          # ARP 发现 + 端口探测（判活神器）
│   ├── ssh_fleet.ps1        # 机群批量执行（顺序 / RunspacePool 并行）
│   ├── enable_ssh.ps1       # 在 node 上执行：装 sshd + 注公钥 + 开防火墙
│   └── lanshare/
│       ├── start_lanshare.ps1   # 一键启动文件源(8899) + 代理(8890)
│       └── lan_proxy.py         # 零依赖 HTTP/HTTPS CONNECT 代理
├── prompts/
│   └── enroll_remote_agent.md   # AI 入栏任务书（发给目标机器上的 AI 助手）
└── docs/
    ├── PLAYBOOK.md              # 踩坑手册：基础篇 §1-8 + 实战篇 §9-12
    └── CASE-STUDY.md            # 实战案例：四机分布式编码服务（v0.2.0）
```

---

## 快速开始

### 第 0 步：找机器（不要用 ping！）

Windows 防火墙默认拦 ICMP 和全部入站端口，**机器在线照样 ping 不通**。
用 TCP 握手触发 ARP，再读 ARP 表：

```bash
python scripts/lan_scan.py --arp --net 192.168.1.0/24 --ports 22
```

### 第 1 步：生成密钥对（Shepherd 上）

```powershell
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\id_herd" -C "herd-lan-access"
```

### 第 2 步：给 node 装 sshd（三选一）

- **AI 入栏（推荐）**：把 `prompts/enroll_remote_agent.md` 改好占位符，发给目标机器上运行的
  AI 助手（WorkBuddy / 其它 CLI agent 都行），它会自己装完并按格式回报；
- **脚本**：把 `scripts/enable_ssh.ps1` 拷到 node 上，管理员 PowerShell 执行：
  `.\enable_ssh.ps1 -PubKey "ssh-ed25519 AAAA... herd-lan-access"`;
- **手动**：按 PLAYBOOK 第 2 节一步步来。

### 第 3 步：写 Shepherd 的 ssh config

```
Host node-a
    HostName 192.168.1.101
    User <用户名>
    IdentityFile C:\Users\<你>\.ssh\id_herd
    IdentitiesOnly yes
    ServerAliveInterval 30
```

⚠️ config 里**每行注释必须以 `#` 开头**，漏了会让整个 config 报废。

### 第 4 步：验收 + 批量

```powershell
& ssh.exe node-a "hostname"          # 单台
.\scripts\ssh_fleet.ps1 "hostname" -Parallel   # 全群
```

### 第 5 步：固化

IP 是 DHCP 分的会变。**推荐在路由器按 MAC 绑静态租约**，一劳永逸。

---

## 设计原则（用血换来的，别省）

1. **判活用 ARP，不用 ping** —— 见 PLAYBOOK §1。
2. **能交给目标机器上的 AI 就别人肉粘贴** —— 远程终端粘长命令会被折行拆条。
3. **写完必回读校验** —— agent 报告「已写入」但文件 0 字节的案例真实发生过。
4. **防火墙规则 Profile=Any** —— 只放专用网络 = 换个网络环境就失联。
5. **sshd 必设 `start= auto` + 崩溃自愈** —— 否则重启一次断联一次。
6. **机群开始跑真实负载后，坑的形态会变** —— 从「连不上」变成「改坏 / 误杀 / 数据覆盖」。部署隔离优先、动进程三步核实、滚动升级协议，见 PLAYBOOK 实战篇 §9-12。

详细的坑与排障速查表见 **[docs/PLAYBOOK.md](docs/PLAYBOOK.md)** —— 这份手册比代码更值钱，每一条都是实测事故换来的。

---

## 实战案例：它真的在干活

**[四机分布式编码服务（TE-Split）](docs/CASE-STUDY.md)** —— 入栏完成后 48 小时内，
这套机群被投入真实生产：一台机器常驻 8.7 GiB 的视觉编码器，三台笔记本
远程调用它跑 ComfyUI 出图。网络路径三轮演进（SSH 隧道 → 网关 → 直连）、
三机滚动升级 3/3 成功、部署事故一次（数据库被移名，靠备份哈希救回）——
所有经验已回灌进 PLAYBOOK 实战篇。

---

## 适用与限制

- ✅ 家庭/工作室/实验室里同一路由器下的多台 Windows
- ✅ 主控端是 Windows（Linux/macOS 主控端同样可用，脚本待适配）
- ⚠️ 仅限**你拥有管理权的可信局域网**；`lan_proxy.py` 无认证，勿在不可信网络开启
- ⚠️ 公钥/私钥请自行生成，**不要使用任何示例密钥**

## License

MIT —— 见 [LICENSE](LICENSE)。
