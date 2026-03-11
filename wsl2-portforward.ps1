# ============================================================
# WSL2 端口转发脚本
# 用途：将 WSL2 内运行的实验室服务暴露给局域网其他电脑访问
# 用法：右键 -> 以管理员身份运行（每次重启 WSL 后需重新执行）
# ============================================================

# ── 检查管理员权限 ────────────────────────────────────────
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]"Administrator")) {
    Write-Host "请以管理员身份运行此脚本！" -ForegroundColor Red
    Start-Sleep 3
    exit 1
}

# ── 自动获取 WSL2 IP ──────────────────────────────────────
$wslIp = (wsl hostname -I).Trim().Split(" ")[0]
if (-not $wslIp) {
    Write-Host "未检测到 WSL2 IP，请确保 WSL 已启动" -ForegroundColor Red
    exit 1
}
Write-Host "WSL2 IP: $wslIp" -ForegroundColor Green

# ── 获取 Windows 主机局域网 IP ────────────────────────────
$winIp = (Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.InterfaceAlias -notmatch "Loopback|vEthernet|WSL" } |
    Select-Object -First 1).IPAddress
Write-Host "Windows 主机 IP: $winIp" -ForegroundColor Green

# ── 需要转发的端口列表 ────────────────────────────────────
# 格式：端口号 = "说明"
$ports = @{
    80    = "Nginx HTTP（统一入口）"
    443   = "Nginx HTTPS"
    8929  = "GitLab Web"
    2224  = "GitLab SSH"
    8080  = "Jenkins"
    3306  = "MySQL"
    6379  = "Redis"
    27017 = "MongoDB"
    9200  = "Elasticsearch"
    5601  = "Kibana"
    9000  = "MinIO S3 API"
    9001  = "MinIO 控制台"
    5672  = "RabbitMQ AMQP"
    15672 = "RabbitMQ 管理界面"
    9090  = "Prometheus"
    3000  = "Grafana"
    5050  = "Allure 报告"
    5252  = "Allure UI"
    8086  = "InfluxDB"
    11434 = "Ollama API"
    3001  = "Open WebUI"
    4000  = "LiteLLM API"
    19530 = "Milvus"
    8000  = "Milvus Attu"
}

# ── 清除旧的端口转发规则 ──────────────────────────────────
Write-Host "`n清除旧的端口转发规则..." -ForegroundColor Yellow
netsh interface portproxy reset | Out-Null

# ── 批量添加端口转发 ──────────────────────────────────────
Write-Host "添加端口转发规则..." -ForegroundColor Yellow
foreach ($port in $ports.Keys) {
    $desc = $ports[$port]
    netsh interface portproxy add v4tov4 `
        listenaddress=0.0.0.0 `
        listenport=$port `
        connectaddress=$wslIp `
        connectport=$port | Out-Null
    Write-Host "  ✅ $port  →  WSL2:$port  ($desc)"
}

# ── 添加 Windows 防火墙规则 ───────────────────────────────
Write-Host "`n配置 Windows 防火墙..." -ForegroundColor Yellow
$portList = $ports.Keys -join ","

# 删除旧规则（避免重复）
Remove-NetFirewallRule -DisplayName "WSL2 Lab Ports" -ErrorAction SilentlyContinue

# 新增允许规则（入站）
New-NetFirewallRule `
    -DisplayName "WSL2 Lab Ports" `
    -Direction Inbound `
    -Protocol TCP `
    -LocalPort $portList `
    -Action Allow | Out-Null

Write-Host "  ✅ 防火墙已放行：$portList" -ForegroundColor Green

# ── 输出访问信息 ──────────────────────────────────────────
Write-Host "`n============================================" -ForegroundColor Cyan
Write-Host " 局域网其他电脑可通过以下地址访问：" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " 导航首页    http://$winIp"
Write-Host " GitLab     http://$winIp`:8929  (或配置 hosts 后: http://git.lab.internal)"
Write-Host " Jenkins    http://$winIp`:8080"
Write-Host " Grafana    http://$winIp`:3000"
Write-Host " Kibana     http://$winIp`:5601"
Write-Host " MinIO      http://$winIp`:9001"
Write-Host " Allure     http://$winIp`:5050"
Write-Host " RabbitMQ   http://$winIp`:15672"
Write-Host " Open WebUI http://$winIp`:3001"
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "`n提示：局域网内其他电脑访问时，只需在 hosts 文件中将" -ForegroundColor Yellow
Write-Host "上述 $winIp 对应到 *.lab.internal 域名即可" -ForegroundColor Yellow

# ── 查看当前转发规则（可选验证）─────────────────────────
Write-Host "`n当前端口转发规则：" -ForegroundColor Gray
netsh interface portproxy show v4tov4

Read-Host "`n按回车键退出"
