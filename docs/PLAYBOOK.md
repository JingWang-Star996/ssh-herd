# Herd 踩坑手册（PLAYBOOK）

> 每一条都是真实事故换来的，发布时已脱敏（原环境：中文用户名主控端 + 多台中文区 Windows 10/11）。
> 适用环境假设：PowerShell 5.1（Windows 自带版本）、OpenSSH for Windows、同一二层局域网。

---

## §1 判活：用 ARP，不用 ping

Windows 防火墙默认拦 ICMP echo **和全部入站端口**——机器明明在线，ping 全丢、端口全关。
用 ping 判活会把所有目标机器误判为「不存在」，进而得出「不在同一网络」的错误结论。

正确做法：TCP 握手触发 ARP（二层协议，不受防火墙影响），再读 ARP 表：

```bash
python scripts/lan_scan.py --arp --net 192.168.1.0/24 --ports 22
```

拿到 MAC 后与目标机器 `Get-NetAdapter` 的报告比对即可确认身份。
另：别急着怀疑 VPN 劫持路由——用 `Get-NetRoute` 看 `0.0.0.0/0` 走哪个接口，实测常见代理/VPN 只接管自己的网段，不碰 LAN。

## §2 node 侧装 OpenSSH：安装方式优先级

```
GitHub 官方 msi 静默安装 > 局域网离线 zip > Add-WindowsCapability > winget
```

- **msi 静默安装最可靠**：`msiexec /i OpenSSH-Win64.msi /quiet`
- `Add-WindowsCapability` 有实测案例挂起 12 分钟无进展（DISM 卡 CBS finalize，TiWorker CPU=0）——**超过 2 分钟没动静就换路线**；报 `0x800f0954` 是被 WSUS/组策略禁了
- zip 版解压会多一层 `OpenSSH-Win64\` 目录，**内容必须提到 `C:\Program Files\OpenSSH\` 根下**，否则服务路径对不上
- winget 在部分机器上 `InternetOpenUrl() failed 0x80072efd`（GitHub 链路不通），需配代理

装完必做：

```powershell
Set-Service sshd -StartupType Automatic          # 自启（漏了 = 重启断联）
Set-NetFirewallRule -Name OpenSSH-Server-In-TCP -Profile Any   # 规则覆盖所有网络类型
```

## §3 公钥与 ACL（最经典的坑）

公钥写两处：`%USERPROFILE%\.ssh\authorized_keys` 和（管理员组用户必须）
`C:\ProgramData\ssh\administrators_authorized_keys`。

后者 **ACL 必须只有 SYSTEM + Administrators**，否则 sshd **静默拒绝公钥**（密钥配对了却一直要密码）：

```
icacls "C:\ProgramData\ssh\administrators_authorized_keys" /inheritance:r /grant "SYSTEM:(F)" "Administrators:(F)"
```

**写完必须回读校验字节数**——agent 报告「已写入」但实际 0 字节的事故发生过。

## §4 Shepherd 侧：中文用户名下的坑

账户目录含非 ASCII 字符（如 `C:\Users\<中文名>`）时：

1. **别用 Git Bash 调 ssh**：Win32 ssh.exe 按 ANSI 解释 UTF-8 路径，用户名里的非 ASCII 字符（中文用户名必踩）会变 `\276\250`。
   一律用 PowerShell 调 `& ssh.exe`。
2. **ssh 会剥掉远端命令里的双层引号**（sshd 重组命令行所致）。
   稳妥写法：远端裸输出（`Select-Object -ExpandProperty`），拉回本地再过滤。
3. **scp 目标路径不能用环境变量**：scp 不是 PowerShell，不认 `$env:TEMP`，写真实绝对路径。
4. **`.ps1` 必须存成 UTF-8 带 BOM**：否则 PS5.1 按 GBK 读取，中文注释全乱码。
5. **ssh config 每行注释必须 `#` 开头**：漏了整个 config 报废（`Bad configuration option`），所有别名失效。

## §5 sshd 服务在重启后整个消失（SERVICE_NOT_FOUND）

实测事故：机器重启后 CBS pending 事务完成，Windows capability 版 sshd 落盘但**服务注册被注销**——ping 通、但 `net start sshd` 报服务不存在。

修复（node 上管理员执行）：

```powershell
sc create sshd binPath= "C:\Windows\System32\OpenSSH\sshd.exe" start= auto
sc failure sshd reset= 86400 actions= restart/60000   # 崩溃自愈
```

公钥文件 / host key / sshd_config 会幸存，无需补写。
预防：`start= auto` + failure 自愈，从根上杜绝「每次重启断联」。

## §6 防火墙规则的名称陷阱

MSI 版自带规则显示名是 `OpenSSH SSH Server (sshd)`（**带 "SSH" 二字**），
按 `OpenSSH Server (sshd)` 查重会漏判，随后创建同名规则报 183（Name 冲突）。
脚本查重请用规则 **Name**（`OpenSSH-Server-In-TCP`）而不是 DisplayName，并直接 `Set-NetFirewallRule -Profile Any` 兜底。

## §7 AI 入栏模式的注意事项

把任务书发给**目标机器上运行**的 AI 助手（比人肉远程终端粘贴可靠得多）：

- 任务书**不写死主机名**：让对方先 `hostname` 自检并在回报里声明身份
- 让 AI **先做权限自检**：远端 AI 尝试 `Start-Process -Verb RunAs` 提权时常被宿主安全层硬拦
  （连 UAC 弹窗都不弹）。退路：Windows 自带 `sudo`（开发者选项 inline 模式）→ 用户手动开提权 PowerShell → `schtasks /RL HIGHEST`（部分机器拒绝访问）
- **回报格式化**：规定 `KEY=已写入` 式的键值回报 + 失败步骤贴完整报错原文
- **长命令别走远程终端粘贴**：会被折行并从 `>>` 处拆成多条执行（`MissingExpressionAfterOperator`）
- **代理注意**：PS5.1 的 `Invoke-WebRequest` **不读** `HTTP_PROXY` 环境变量，要显式 `-Proxy`；
  `curl.exe` 认环境变量；winget / Windows Update 走代理要 `netsh winhttp set proxy`

## §8 PowerShell 杂项

- `Start-Job` 在部分环境被安全策略拦截 → 并发用 `[RunspaceFactory]::CreateRunspacePool`（见 ssh_fleet.ps1）
- 测端口别用 `Test-NetConnection`（自带 ICMP 探测，对禁 ping 机器会卡到超时），用 socket connect
- 服务起不来、日志说缺 host key → `ssh-keygen -A`
- `.ps1` 输出中文乱码 → 先查文件有没有 UTF-8 BOM

---

## 排障速查表

| 现象 | 原因 / 处理 |
|---|---|
| ping 全丢、端口全关 | 正常，防火墙默认策略。**改用 ARP 判活（§1）** |
| 公钥配对仍要求输密码 | `administrators_authorized_keys` ACL 不对，重跑 §3 的 icacls |
| 22 在 Listen 但连不上 | 防火墙规则没覆盖当前网络 Profile，查 `Get-NetConnectionProfile` |
| 重启后 sshd 消失 | §5 重注册服务 |
| `0x800f0954` | WSUS/组策略禁了 capability，走 msi/离线包 |
| 服务起不来缺 host key | `ssh-keygen -A` |
| 远程终端粘命令报 `MissingExpressionAfterOperator` | 折行拆条，改走 AI 入栏或写脚本投递 |
| 换了个 Wi-Fi/网络就失联 | 防火墙规则 Profile 不含当前网络，§2 兜底 |
| IP 变了连不上 | 路由器按 MAC 绑静态租约；或 `lan_scan.py` 重新发现后改 config |

## 巡检一行命令

```powershell
.\scripts\ssh_fleet.ps1 "(Get-Service sshd).Status; hostname" -Parallel
```

每台都应返回 `Running` + 各自主机名。
