# enable_ssh.ps1 —— Herd 入栏脚本（在被控 Windows 机器上执行）
# 安装/启用 OpenSSH Server，并注入 Shepherd 的公钥。
# 跑完之后 Shepherd 就能 ssh 直连本机。
#
# 用法（管理员 PowerShell）：
#   .\enable_ssh.ps1 -PubKey "ssh-ed25519 AAAA... herd-lan-access"
#   .\enable_ssh.ps1 -PubKeyFile .\herd.pub
#
# 常用参数：
#   -Port 22         监听端口
#   -EnsureRunning   装完立刻启动并设为开机自启（默认开启）
#   -NoFirewallRule  不放通防火墙（默认会放）

param(
    [string]$PubKey,
    [string]$PubKeyFile,
    [int]$Port = 22,
    [switch]$EnsureRunning = $true,
    [switch]$NoFirewallRule
)

$ErrorActionPreference = 'Stop'

function Say([string]$msg, [string]$color = 'Cyan') {
    Write-Host "[ssh-setup] $msg" -ForegroundColor $color
}

# ---------- 0. 管理员权限 ----------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ssh-setup] ERROR: 当前不是管理员会话，无法安装 OpenSSH Server。" -ForegroundColor Red
    Write-Host "            请右键 PowerShell 以管理员身份运行后重试。" -ForegroundColor Yellow
    exit 1
}

# ---------- 1. 取公钥 ----------
if (-not $PubKey -and $PubKeyFile) {
    if (Test-Path $PubKeyFile) {
        $PubKey = (Get-Content $PubKeyFile -Raw).Trim()
        Say "从 $PubKeyFile 读取公钥" 'Gray'
    }
}
if (-not $PubKey) {
    foreach ($candidate in @("$PSScriptRoot\herd.pub", ".\herd.pub")) {
        if (Test-Path $candidate) {
            $PubKey = (Get-Content $candidate -Raw).Trim()
            Say "从 $candidate 读取公钥" 'Gray'
            break
        }
    }
}
if (-not $PubKey) {
    Write-Host "[ssh-setup] ERROR: 没有拿到公钥，请用 -PubKey 或 -PubKeyFile 传入。" -ForegroundColor Red
    exit 1
}
$PubKey = $PubKey.Trim()

# ---------- 2. 找到 / 安装 OpenSSH ----------
function Get-SshdPath {
    foreach ($p in @("$env:SystemRoot\System32\OpenSSH\sshd.exe",
                     "$env:ProgramFiles\OpenSSH\sshd.exe",
                     "${env:ProgramFiles(x86)}\OpenSSH\sshd.exe")) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

$sshd = Get-SshdPath
if ($sshd) {
    Say "已存在 OpenSSH: $sshd" 'Green'
} else {
    Say "未找到 sshd，开始安装..." 'Yellow'

    $installed = $false

    # 路线 A：Windows 可选功能（需要联网 / WSUS 允许；可能卡 CBS，2 分钟无进展就换路线）
    if (-not $installed) {
        try {
            Say "路线A: Add-WindowsCapability OpenSSH.Server"
            $r = Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction Stop
            if ($r -and $r.RestartNeeded) { Say "需要重启才能完成安装" 'Yellow' }
            Start-Sleep -Seconds 2
            $sshd = Get-SshdPath
            if ($sshd) { $installed = $true; Say "路线A 成功" 'Green' }
        } catch {
            Say "路线A 失败: $($_.Exception.Message)" 'DarkYellow'
        }
    }

    # 路线 B：winget
    if (-not $installed -and (Get-Command winget -ErrorAction SilentlyContinue)) {
        try {
            Say "路线B: winget install Microsoft.OpenSSH.Server"
            winget install --id Microsoft.OpenSSH.Server -e --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
            $sshd = Get-SshdPath
            if (-not $sshd) {
                foreach ($p in @("$env:ProgramFiles\OpenSSH\sshd.exe")) { if (Test-Path $p) { $sshd = $p } }
            }
            if ($sshd) { $installed = $true; Say "路线B 成功" 'Green' }
        } catch {
            Say "路线B 失败: $($_.Exception.Message)" 'DarkYellow'
        }
    }

    # 路线 C：GitHub 官方 zip 兜底（也可换成本地/局域网文件源地址）
    if (-not $installed) {
        try {
            Say "路线C: 下载 Win32-OpenSSH 官方包"
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $tmp = "$env:TEMP\openssh.zip"
            $dir = "$env:TEMP\openssh_win"
            Invoke-WebRequest -Uri "https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.8.0.0p1-Preview/OpenSSH-Win64.zip" -OutFile $tmp -UseBasicParsing -TimeoutSec 300
            Expand-Archive -Path $tmp -DestinationPath $dir -Force
            $dest = "${env:ProgramFiles}\OpenSSH"
            New-Item -ItemType Directory -Force -Path $dest | Out-Null
            Copy-Item "$dir\OpenSSH-Win64\*" $dest -Recurse -Force
            & "$dest\install-sshd.ps1" | Out-Null
            $env:Path += ";$dest"
            [Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path', 'Machine') + ";$dest", 'Machine')
            $sshd = "$dest\sshd.exe"
            if (Test-Path $sshd) { $installed = $true; Say "路线C 成功" 'Green' }
        } catch {
            Say "路线C 失败: $($_.Exception.Message)" 'Red'
        }
    }

    if (-not $installed) {
        Write-Host "[ssh-setup] ERROR: 三条安装路线都失败了，请检查网络后重试。" -ForegroundColor Red
        exit 2
    }
}

$sshDir = Split-Path $sshd -Parent

# ---------- 3. sshd_config ----------
$cfg = Join-Path $sshDir 'sshd_config'
if (Test-Path $cfg) {
    Say "调整 sshd_config: $cfg"
    takeown /f $cfg | Out-Null
    icacls $cfg /grant "SYSTEM:(F)" "Administrators:(F)" | Out-Null
    $lines = Get-Content $cfg
    $lines = $lines | Where-Object { $_ -notmatch '^\s*#?\s*(PubkeyAuthentication|PasswordAuthentication|Port)\s' }
    $lines += @(
        "Port $Port",
        "PubkeyAuthentication yes",
        "PasswordAuthentication yes"
    )
    $lines | Set-Content $cfg -Encoding UTF8
} else {
    Say "未找到 sshd_config，跳过配置调整" 'DarkYellow'
}

# ---------- 4. 注入公钥 ----------
$userProfile = [Environment]::GetFolderPath('UserProfile')
$userSshDir = Join-Path $userProfile '.ssh'
New-Item -ItemType Directory -Force -Path $userSshDir | Out-Null
$userKeyFile = Join-Path $userSshDir 'authorized_keys'

if (Test-Path $userKeyFile) {
    $existing = Get-Content $userKeyFile -Raw -ErrorAction SilentlyContinue
} else {
    $existing = ''
}
if ($existing -notmatch [regex]::Escape(($PubKey -split '\s+')[1])) {
    Add-Content -Path $userKeyFile -Value "`n$PubKey`n" -Encoding UTF8
    Say "已写入普通用户 authorized_keys: $userKeyFile" 'Green'
} else {
    Say "公钥已存在于 $userKeyFile" 'Gray'
}

# 回读校验字节数（agent 报告已写入但实际 0 字节的事故发生过，别省这步）
if ((Get-Item $userKeyFile).Length -eq 0) {
    Write-Host "[ssh-setup] ERROR: authorized_keys 写入后为 0 字节！" -ForegroundColor Red
    exit 3
}

# 若当前用户属于 Administrators 组，还要写 administrators_authorized_keys（sshd 强制要求）
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -and
    (Test-Path "$env:ProgramData\ssh")) {
    $adminKeyFile = "$env:ProgramData\ssh\administrators_authorized_keys"
    $existingAdmin = if (Test-Path $adminKeyFile) { Get-Content $adminKeyFile -Raw -ErrorAction SilentlyContinue } else { '' }
    if ($existingAdmin -notmatch [regex]::Escape(($PubKey -split '\s+')[1])) {
        Add-Content -Path $adminKeyFile -Value "`n$PubKey`n" -Encoding UTF8
    }
    # 权限必须是 SYSTEM + Administrators，否则 sshd 静默拒绝公钥（最经典的坑）
    $acl = Get-Acl $adminKeyFile
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($acct in @('SYSTEM', 'BUILTIN\Administrators')) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($acct, 'FullControl', 'Allow')
        $acl.ResetAccessRule($rule)
    }
    $acl.SetOwner([System.Security.Principal.NTAccount]'BUILTIN\Administrators')
    Set-Acl -Path $adminKeyFile -AclObject $acl
    Say "已写入管理员 authorized_keys: $adminKeyFile" 'Green'
}

# ---------- 5. 默认 shell 设为 PowerShell ----------
try {
    New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name 'DefaultShell' `
        -Value "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -PropertyType String -Force | Out-Null
    Say "默认 shell 已设为 PowerShell" 'Gray'
} catch { }

# ---------- 6. 防火墙（Profile=Any，漏了换个网络就失联） ----------
if (-not $NoFirewallRule) {
    if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'Herd OpenSSH Server' `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort $Port -Profile Any | Out-Null
        Say "已创建防火墙入站规则 port=$Port Profile=Any" 'Green'
    } else {
        Enable-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
        Set-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -Profile Any -ErrorAction SilentlyContinue
        Say "防火墙规则已存在，已确保启用且 Profile=Any" 'Gray'
    }
}

# ---------- 7. 启动服务（自启 + 崩溃自愈，防重启断联） ----------
if ($EnsureRunning) {
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
    if (-not $svc) {
        # capability 版装完后服务可能尚未注册（CBS pending），重注册一次
        if (Test-Path "$env:SystemRoot\System32\OpenSSH\sshd.exe") {
            sc.exe create sshd binPath= "$env:SystemRoot\System32\OpenSSH\sshd.exe" start= auto | Out-Null
            $svc = Get-Service sshd -ErrorAction SilentlyContinue
        }
    }
    if (-not $svc) { Say "sshd 服务不存在，可能需要重启机器后重跑本脚本" 'Yellow' }
    else {
        sc.exe failure sshd reset= 86400 actions= restart/60000 | Out-Null
        Set-Service -Name sshd -StartupType Automatic -ErrorAction SilentlyContinue
        Restart-Service sshd -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        $svc = Get-Service sshd
        Say "sshd 状态: $($svc.Status) / 自启: $($svc.StartType)" 'Green'
    }
}

# ---------- 8. 输出连接信息 ----------
Say "========== 结果 ==========" 'White'
$lanIPs = Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -notmatch '^(127|169\.254\.)' -and $_.PrefixLength -ge 8 -and $_.PrefixLength -le 30 } |
    Select-Object -ExpandProperty IPAddress
Write-Host "hostname      : $env:COMPUTERNAME" -ForegroundColor White
Write-Host "username      : $($env:USERDOMAIN)\$($env:USERNAME)" -ForegroundColor White
Write-Host "LAN IP        : $($lanIPs -join ', ')" -ForegroundColor White
Write-Host "sshd listening: $Port" -ForegroundColor White
Write-Host ""
Write-Host "在 Shepherd 上测试： ssh -i <你的私钥> $($env:USERNAME)@<上面的 LAN IP>" -ForegroundColor Yellow
