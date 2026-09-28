# Herd 入栏期辅助：一键启动「局域网文件源(8899) + 局域网代理(8890)」。
# 用法：右键 -> 使用 PowerShell 运行。若提示执行策略限制，先运行：
#   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
#
# 用途：新机器还没有 sshd / 下载不了 GitHub 时，从本机拿安装包、借网络出口。
# 入栏完成后建议关闭（代理无认证，仅限可信局域网临时使用）。

$ErrorActionPreference = 'Continue'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path

# 找一个可用的 Python（优先 PATH，其次 py 启动器）
$py = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $py) {
    $py = (Get-Command py -ErrorAction SilentlyContinue).Source
    if ($py) { $py = "$py -3" }
}
if (-not $py) {
    Write-Host "找不到 Python，请先安装 Python 3.8+ 并加入 PATH" -ForegroundColor Red
    pause; exit 1
}

Write-Host "共享目录: $dir" -ForegroundColor Cyan

function Start-Service-OnPort {
    param([int]$Port, [string[]]$PyArgs, [string]$Label)

    $existing = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "[$Label] 端口 $Port 已在监听 (PID $($existing.OwningProcess -join ','))，跳过" -ForegroundColor Yellow
        return
    }
    if ($py -match ' ') {
        $p = Start-Process -FilePath $py -ArgumentList $PyArgs -WorkingDirectory $dir -PassThru -WindowStyle Hidden
    } else {
        $p = Start-Process -FilePath $py -ArgumentList $PyArgs -WorkingDirectory $dir -PassThru -WindowStyle Hidden
    }
    Start-Sleep -Seconds 2
    $ok = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
    if ($ok) { Write-Host "[$Label] 已启动 http://<本机IP>:$Port  (PID $($p.Id))" -ForegroundColor Green }
    else     { Write-Host "[$Label] 启动失败，请检查端口占用" -ForegroundColor Red }
}

# 8899: 静态文件源（放 OpenSSH-Win64.zip 等安装包，给入栏机器拉取）
Start-Service-OnPort -Port 8899 -PyArgs @('-m','http.server','8899','--bind','0.0.0.0') -Label '文件源'

# 8890: HTTP/HTTPS 代理（给入栏机器借用本机网络出口）
Start-Service-OnPort -Port 8890 -PyArgs @('lan_proxy.py','--port','8890') -Label '代理'

# 动态显示本机局域网 IP（不要写死，DHCP 环境会变）
Write-Host ""
Write-Host "本机 LAN IP（把下面地址里的 <本机IP> 换成它）:" -ForegroundColor Cyan
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -like '192.168.*' -or $_.IPAddress -like '10.*' } |
    ForEach-Object { Write-Host "  $($_.IPAddress)  ($($_.InterfaceAlias))" }

Write-Host ""
Write-Host "其它机器上使用方式：" -ForegroundColor Cyan
Write-Host '  $env:HTTP_PROXY="http://<本机IP>:8890"; $env:HTTPS_PROXY="http://<本机IP>:8890"'
Write-Host '  Invoke-WebRequest -Uri "http://<本机IP>:8899/OpenSSH-Win64.zip" -OutFile "$env:TEMP\OpenSSH.zip" -UseBasicParsing'
Write-Host ""
Write-Host "按任意键关闭本窗口（后台服务会继续运行）" -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
