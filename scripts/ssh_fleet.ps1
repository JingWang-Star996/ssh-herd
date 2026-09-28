# Herd 机群批量执行工具（Shepherd 侧）
#
# 目标机器列表来源（按优先级）：
#   1. -Hosts 参数：.\ssh_fleet.ps1 "hostname" -Hosts node-a,node-b
#   2. 同目录 hosts.txt：一行一个 ssh config 别名（推荐，配合 ~/.ssh/config 使用）
#
# 用法示例：
#   .\ssh_fleet.ps1 "hostname"                     # 全群顺序执行
#   .\ssh_fleet.ps1 "Get-Process" -Parallel        # 全群并行（RunspacePool）
#   .\ssh_fleet.ps1 "ipconfig" -Hosts node-a       # 只跑某一台
#
# 提示：远端命令里的双引号会被 ssh 剥掉一层。
#       需要过滤/格式化时，让远端裸输出，拿回本地再处理。

param(
    [string]$Command,
    [string[]]$Hosts,
    [switch]$Parallel
)

$ErrorActionPreference = 'Continue'

if ([string]::IsNullOrWhiteSpace($Command)) {
    Write-Host '用法: .\ssh_fleet.ps1 "要执行的命令" [-Hosts a,b] [-Parallel]' -ForegroundColor Yellow
    exit 1
}

if (-not $Hosts -or $Hosts.Count -eq 0) {
    $hostsFile = Join-Path $PSScriptRoot 'hosts.txt'
    if (Test-Path $hostsFile) {
        $Hosts = Get-Content $hostsFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }
    }
}
if (-not $Hosts -or $Hosts.Count -eq 0) {
    Write-Host '未指定目标：用 -Hosts 传入，或在脚本同目录放 hosts.txt（一行一个 ssh 别名）。' -ForegroundColor Yellow
    exit 1
}

Write-Host ('命令: ' + $Command) -ForegroundColor DarkGray
Write-Host ('目标: ' + ($Hosts -join ', ')) -ForegroundColor DarkGray
Write-Host ('-' * 64)

$sw = [System.Diagnostics.Stopwatch]::StartNew()

function Show-Result {
    param($r)
    $color = if ($r.Exit -eq 0) { 'Green' } else { 'Red' }
    Write-Host ('[' + $r.Host + '] exit=' + $r.Exit) -ForegroundColor $color
    foreach ($line in $r.Out) { Write-Host ('  ' + $line) }
}

if ($Parallel) {
    # Start-Job 在部分环境被安全策略拦截，改用 RunspacePool
    $pool = [RunspaceFactory]::CreateRunspacePool(1, $Hosts.Count)
    $pool.Open()
    $pending = @()
    foreach ($h in $Hosts) {
        $ps = [PowerShell]::Create()
        $null = $ps.AddScript({
            param($hh, $cmd)
            $ErrorActionPreference = 'Continue'
            $o = & ssh.exe -o BatchMode=yes -o ConnectTimeout=8 $hh $cmd 2>&1
            [PSCustomObject]@{ Host = $hh; Exit = $LASTEXITCODE; Out = $o }
        }).AddArgument($h).AddArgument($Command)
        $ps.RunspacePool = $pool
        $pending += [PSCustomObject]@{ Pipe = $ps; Handle = $ps.BeginInvoke() }
    }
    foreach ($j in $pending) {
        Show-Result $j.Pipe.EndInvoke($j.Handle)
        $j.Pipe.Dispose()
    }
    $pool.Close()
    $pool.Dispose()
} else {
    foreach ($h in $Hosts) {
        $o = & ssh.exe -o BatchMode=yes -o ConnectTimeout=8 $h $Command 2>&1
        Show-Result ([PSCustomObject]@{ Host = $h; Exit = $LASTEXITCODE; Out = $o })
    }
}

$sw.Stop()
$secs = $sw.Elapsed.TotalSeconds.ToString('0.0')
Write-Host ('-' * 64)
Write-Host ('耗时 ' + $secs + 's') -ForegroundColor DarkGray
