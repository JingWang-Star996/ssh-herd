# AI 入栏任务书（Roundup Prompt）

把下面「两条横线之间」的内容，替换掉 `<SHEPHERD_IP>` 和 `<YOUR_PUBLIC_KEY>` 两个占位符后，
整段发给**目标机器上正在运行的 AI 助手**（WorkBuddy / 任意 CLI agent 均可）。
一段话适用于**所有机器，一字不改**——任务书不写死主机名，对方会自检身份并回报。

发之前在 Shepherd 上准备好：
1. 已生成密钥对：`ssh-keygen -t ed25519 -f ~/.ssh/id_herd -C herd-lan-access`
2. `<YOUR_PUBLIC_KEY>` = `~/.ssh/id_herd.pub` 的完整内容（一行）
3. `<SHEPHERD_IP>` = Shepherd 的局域网 IP（`ipconfig` 查，别抄记忆）
4. （可选）lanshare 已启动：8899 文件源放了 OpenSSH-Win64.zip，8890 是代理

---

你是运行在这台 Windows 机器上的 AI 助手。**我事先不知道你是哪一台**，所以第一步请先执行
`hostname` 查清自己的身份，并在最后回报里写明。

请在本机完成以下操作。所有步骤都要实际执行，不要只给建议。执行完按指定格式回报。

## 第 1 步：确认身份 + 权限自检（必须放在最前面）

先执行 `hostname` 并记下结果，后面回报要用。

判断你当前的执行环境是否具备**管理员权限**。
- 如果**不具备**：先尝试提权再继续（例如用 `Start-Process -Verb RunAs` 启动一个提权的
  PowerShell 实例，在其中完成后续命令）。
- 如果提权失败，**不要停下**，继续做能力范围内的事，并在回报里明确写 `ADMIN=False`。

## 第 0 步（可选）：配代理

我在与你同一个二层网络的 `<SHEPHERD_IP>` 上架了 HTTP/HTTPS 代理，端口 `8890`：

```powershell
$env:HTTP_PROXY='http://<SHEPHERD_IP>:8890'
$env:HTTPS_PROXY='http://<SHEPHERD_IP>:8890'
```

验证（任选一条）：

```powershell
curl.exe -s https://api.ipify.org
```
```powershell
Invoke-WebRequest -Uri 'https://api.ipify.org' -Proxy 'http://<SHEPHERD_IP>:8890' -UseBasicParsing
```

> Windows PowerShell 5.1 的 `Invoke-WebRequest` **不读** HTTP_PROXY 环境变量，必须显式加 `-Proxy`
> （curl.exe 则认环境变量，优先用 curl）。
> 还要让 winget / Windows Update 走代理的话：`netsh winhttp set proxy <SHEPHERD_IP>:8890`（用完记得 reset）。

两条都超时就别卡着——跳过本步看第 2 步，那里有**完全不需要互联网**的装法。

## 第 2 步：部署 OpenSSH Server

目标端口 `22`。**首选离线路径，不依赖外网。**

### 路径 A（首选）：从 Shepherd 的局域网文件源离线安装

Shepherd 已在 `http://<SHEPHERD_IP>:8899/OpenSSH-Win64.zip` 提供官方安装包
（来自 PowerShell/Win32-OpenSSH 官方 release）：

```powershell
$ProgressPreference='SilentlyContinue'
Invoke-WebRequest -Uri 'http://<SHEPHERD_IP>:8899/OpenSSH-Win64.zip' -OutFile "$env:TEMP\OpenSSH.zip" -UseBasicParsing
```
```powershell
Expand-Archive -Path "$env:TEMP\OpenSSH.zip" -DestinationPath "$env:TEMP\oss" -Force
New-Item -ItemType Directory -Force -Path 'C:\Program Files\OpenSSH' | Out-Null
Copy-Item "$env:TEMP\oss\OpenSSH-Win64\*" 'C:\Program Files\OpenSSH' -Recurse -Force
```
```powershell
& 'C:\Program Files\OpenSSH\install-sshd.ps1'
```
```powershell
Set-Service sshd -StartupType Automatic; Start-Service sshd
```

> 注意 zip 解压后会多一层 `OpenSSH-Win64\` 目录，别直接把它当安装目录用，
> 否则 sshd.exe 会落到 `C:\Program Files\OpenSSH\OpenSSH-Win64\`，服务路径对不上。

### 路径 B（备用）：联网安装

路径 A 拿不到包时才走这里，按顺序尝试，成功即停止。需要代理先回第 0 步。

- `Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0`
  （超过 2 分钟无进展就放弃，有卡 CBS 12 分钟的前科）
- `winget install --id Microsoft.OpenSSH.Server -e --accept-package-agreements --accept-source-agreements --disable-interactivity`

装完同样执行 `Set-Service sshd -StartupType Automatic` 和 `Start-Service sshd`。

## 第 3 步：放行防火墙（漏了这步一定连不上）

放行 **TCP 22 入站**，且必须覆盖**全部网络配置文件**（`-Profile Any`，只放专用网络=换个环境就失联）。
同时**放行 ICMPv4 type 8 echo 入站**，否则对方连 ping 诊断都做不了。

## 第 4 步：写入 Shepherd 的公钥

把下面这行完整写入（整行，不截断、不换行）：

```
<YOUR_PUBLIC_KEY>
```

写入位置：
1. `%USERPROFILE%\.ssh\authorized_keys`（不存在就创建）
2. 若当前用户属于管理员组，还必须写 `C:\ProgramData\ssh\administrators_authorized_keys`，
   并且**必须修正 ACL**，否则 sshd 会**静默拒绝公钥**（配对了还要密码）：
   ```
   icacls "C:\ProgramData\ssh\administrators_authorized_keys" /inheritance:r /grant "SYSTEM:(F)" "Administrators:(F)"
   ```

**写完必须回读校验字节数**——报告「已写入」但文件 0 字节的事故真实发生过。

## 第 5 步：服务固化（防重启断联）

```powershell
sc.exe config sshd start= auto
sc.exe failure sshd reset= 86400 actions= restart/60000
```

（若第 2 步装的是 Windows capability 版且重启后服务消失：`sc.exe create sshd binPath= "C:\Windows\System32\OpenSSH\sshd.exe" start= auto` 重新注册即可，公钥和 host key 都会幸存。）

## 第 6 步：自检

在本机自己验证一遍，别只信命令返回值：
- `Get-Service sshd` → 应为 Running 且 StartType=Automatic
- 22 端口应处于 Listen 状态（`netstat -ano | findstr :22`）
- 本机自连一次（`ssh -o StrictHostKeyChecking=no <你的用户名>@localhost hostname`），
  确认**无需密码即可登录**。密钥登录真跑通了才算完成。

## 第 7 步：按此格式回报

```
ADMIN=<True/False>
HOST=<主机名>
USER=<当前用户名>
IP=<本机所有 IPv4 地址，逗号分隔>
MAC=<所有网卡 MAC，逗号分隔>
SSHD=<Running/Stopped>
SSHD_AUTOSTART=<Automatic/Manual/Unknown>
PORT22=<Listening/NotListening>
FIREWALL=<OK/FAIL>
KEY=<已写入/失败>
SELFTEST=<本机 ssh 登录成功/失败>
```

任何失败步骤请附**完整报错原文**，不要只概括。最后把回报整理成一段可以直接复制粘走的纯文本。

---

## 附：排障速查（给执行任务的 AI 自己看）

- **Add-WindowsCapability 报 `0x800f0954`** → 被 WSUS/组策略禁了，直接走路径 A
- **拿不到 `http://<SHEPHERD_IP>:8899`** → 确认自己 IP 是不是同网段；用
  `Test-NetConnection <SHEPHERD_IP> -Port 8899` 测可达性并回报
- **公钥写对了但仍要密码** → 九成是 administrators_authorized_keys 的 ACL，重跑第 4 步 icacls
- **22 Listen 了但对方仍连不上** → 防火墙规则没覆盖当前网络 Profile，
  查 `Get-NetConnectionProfile` 的 NetworkCategory
- **服务起不来、日志缺 host key** → `ssh-keygen -A`
- **默认 shell 建议**：`New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String -Force`
