<#
  云区域延迟测速（Oracle Cloud / Azure / AWS，从本机出发）

  用法（一般通过网站或 tools\ 下的命令使用，也可以直接运行）：
    测速一次：            powershell -ExecutionPolicy Bypass -File latency.ps1
    测速 + 路径：         ... -File latency.ps1 -Trace
    命令行汇总报告：      ... -File latency.ps1 -Report
    只测部分区域：        ... -File latency.ps1 -Regions ap-osaka-1,azure-southeastasia,aws-ap-northeast-1
    每个区域测更多次：    ... -File latency.ps1 -Rounds 20
    列出全部区域(JSON)：  ... -File latency.ps1 -ListRegions

  区域代码：Oracle 用原生代码（如 ap-tokyo-1）；Azure 加前缀 azure-（如 azure-japaneast）；AWS 加前缀 aws-（如 aws-ap-northeast-1）。
  测量方法：对每个区域的公开服务地址发起 TCP 连接（443 端口），记录"建立连接"的往返时间（含去程和回程）；
           超过 1 秒基本意味着首个数据包丢失后重传。
    Oracle = objectstorage.<区域>.oraclecloud.com
    Azure  = s8<区域>.blob.core.windows.net（azurespeed.com 在各区域部署的测速存储账号）
    AWS    = dynamodb.<区域>.amazonaws.com
  路径（-Trace）：去程 = 本机 tracert，每一跳经 ipinfo.io 换算成"运营商@城市"；
                 回程 = 需在 config 的 ReturnProbes 中配置该区域内你自己服务器的 SSH 登录（服务器需装 mtr）。

  目录：配置 ..\config\config.psd1（可选，参考 config.example.psd1）；数据 ..\data\latency.csv、..\data\ip-cache.json
#>
param(
    [int]$Rounds = 12,
    [string[]]$Regions,
    [switch]$Trace,
    [switch]$Report,
    [switch]$ListRegions,
    [string]$Config
)

$ErrorActionPreference = 'Stop'
$Here      = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root      = Split-Path -Parent $Here
$DataDir   = Join-Path $Root 'data'
$CsvPath   = Join-Path $DataDir 'latency.csv'
$CachePath = Join-Path $DataDir 'ip-cache.json'
$Columns   = '时间','时段','区域','位置','中位ms','最快ms','最慢ms','超时次数','超1秒次数','样本数','地址','去程路径','回程路径'
New-Item -ItemType Directory -Force $DataDir | Out-Null

# ---------- 区域目录 ----------
$OracleRegions = [ordered]@{
    'ap-chuncheon-1'='韩国春川'; 'ap-seoul-1'='韩国首尔'; 'ap-tokyo-1'='日本东京'; 'ap-osaka-1'='日本大阪'
    'ap-singapore-1'='新加坡(1区)'; 'ap-singapore-2'='新加坡(2区)'; 'ap-batam-1'='印尼巴淡岛'
    'ap-mumbai-1'='印度孟买'; 'ap-hyderabad-1'='印度海得拉巴'; 'ap-sydney-1'='澳大利亚悉尼'; 'ap-melbourne-1'='澳大利亚墨尔本'
    'us-sanjose-1'='美国圣何塞'; 'us-phoenix-1'='美国凤凰城'; 'us-ashburn-1'='美国阿什本(弗吉尼亚)'; 'us-chicago-1'='美国芝加哥'
    'ca-toronto-1'='加拿大多伦多'; 'ca-montreal-1'='加拿大蒙特利尔'; 'mx-queretaro-1'='墨西哥克雷塔罗'; 'sa-saopaulo-1'='巴西圣保罗'
    'uk-london-1'='英国伦敦'; 'eu-frankfurt-1'='德国法兰克福'; 'eu-amsterdam-1'='荷兰阿姆斯特丹'; 'eu-zurich-1'='瑞士苏黎世'
    'eu-paris-1'='法国巴黎'; 'eu-marseille-1'='法国马赛'; 'eu-milan-1'='意大利米兰'; 'eu-stockholm-1'='瑞典斯德哥尔摩'
    'eu-madrid-1'='西班牙马德里'; 'il-jerusalem-1'='以色列耶路撒冷'; 'me-dubai-1'='阿联酋迪拜'; 'me-jeddah-1'='沙特吉达'
    'af-johannesburg-1'='南非约翰内斯堡'
}
# Azure：默认只列出亚洲主要区域（其他区域可按 '<区域名>'='<中文名>' 格式自行添加）
$AzureRegions = [ordered]@{
    'southeastasia'='新加坡'; 'malaysiawest'='马来西亚吉隆坡'; 'indonesiacentral'='印尼雅加达'; 'japaneast'='日本东京'
    'japanwest'='日本大阪'; 'eastasia'='中国香港'; 'koreasouth'='韩国釜山'; 'koreacentral'='韩国首尔'
}
$AwsRegions = [ordered]@{
    'ap-northeast-1'='日本东京'; 'ap-northeast-3'='日本大阪'; 'ap-northeast-2'='韩国首尔'; 'ap-east-1'='中国香港'; 'ap-east-2'='中国台北'
    'ap-southeast-1'='新加坡'; 'ap-southeast-3'='印尼雅加达'; 'ap-southeast-5'='马来西亚'; 'ap-southeast-7'='泰国'
    'ap-south-1'='印度孟买'; 'ap-south-2'='印度海得拉巴'; 'ap-southeast-2'='澳大利亚悉尼'; 'ap-southeast-4'='澳大利亚墨尔本'; 'ap-southeast-6'='新西兰'
    'us-west-1'='美国加州北部'; 'us-west-2'='美国俄勒冈'; 'us-east-1'='美国弗吉尼亚北部'; 'us-east-2'='美国俄亥俄'
    'ca-central-1'='加拿大中部'; 'ca-west-1'='加拿大卡尔加里'; 'mx-central-1'='墨西哥'; 'sa-east-1'='巴西圣保罗'
    'eu-central-1'='德国法兰克福'; 'eu-central-2'='瑞士苏黎世'; 'eu-west-1'='爱尔兰'; 'eu-west-2'='英国伦敦'; 'eu-west-3'='法国巴黎'
    'eu-south-1'='意大利米兰'; 'eu-south-2'='西班牙'; 'eu-north-1'='瑞典斯德哥尔摩'
    'il-central-1'='以色列特拉维夫'; 'me-south-1'='巴林'; 'me-central-1'='阿联酋'; 'af-south-1'='南非开普敦'
}
$Catalog = [ordered]@{}   # 代码 -> @{ Name; Host; Provider }
foreach ($k in $OracleRegions.Keys) { $Catalog[$k] = @{ Name = "Oracle $($OracleRegions[$k])"; Host = "objectstorage.$k.oraclecloud.com"; Provider = 'Oracle' } }
foreach ($k in $AzureRegions.Keys)  { $Catalog["azure-$k"] = @{ Name = "Azure $($AzureRegions[$k])"; Host = "s8$k.blob.core.windows.net"; Provider = 'Azure' } }
foreach ($k in $AwsRegions.Keys)    { $Catalog["aws-$k"] = @{ Name = "AWS $($AwsRegions[$k])"; Host = "dynamodb.$k.amazonaws.com"; Provider = 'AWS' } }

# ---------- 读取配置（可选） ----------
$Reference      = [ordered]@{}   # 名称 -> 'host:port'，作为对照组每次都测
$ReferenceNames = @{}            # 名称 -> 位置说明
$ReturnProbes   = @{}            # 区域代码或对照名称 -> 'user@host'
$SshKey         = ''
$IpinfoToken    = ''
$DefaultRegions = @()            # 不指定 -Regions 时测哪些区域；空 = 全部
if (-not $Config) { $Config = Join-Path $Root 'config\config.psd1' }
if (Test-Path $Config) {
    $cfg = Import-PowerShellDataFile $Config
    if ($cfg.Reference)      { foreach ($k in $cfg.Reference.Keys)      { $Reference[$k] = $cfg.Reference[$k] } }
    if ($cfg.ReferenceNames) { foreach ($k in $cfg.ReferenceNames.Keys) { $ReferenceNames[$k] = $cfg.ReferenceNames[$k] } }
    if ($cfg.ReturnProbes)   { foreach ($k in $cfg.ReturnProbes.Keys)   { $ReturnProbes[$k] = $cfg.ReturnProbes[$k] } }
    if ($cfg.SshKey)         { $SshKey = [Environment]::ExpandEnvironmentVariables($cfg.SshKey) }
    if ($cfg.IpinfoToken)    { $IpinfoToken = $cfg.IpinfoToken }
    if ($cfg.Regions)        { $DefaultRegions = @($cfg.Regions) }
}

if ($ListRegions) {
    $list = foreach ($k in $Catalog.Keys) { [pscustomobject]@{ code = $k; name = $Catalog[$k].Name; provider = $Catalog[$k].Provider } }
    [pscustomobject]@{ regions = @($list); references = @($Reference.Keys); referenceNames = $ReferenceNames; defaultRegions = $DefaultRegions } |
        ConvertTo-Json -Depth 4 -Compress
    return
}

# 常见运营商 ASN 的中文简称
$AsnNames = @{
    4134='电信163骨干'; 4809='电信CN2'; 4812='上海电信'; 23764='电信国际CTG'; 4837='联通169'; 9929='联通精品网'
    4808='北京联通'; 17621='上海联通'; 9808='中国移动'; 58453='移动国际CMI'; 56040='广东移动'; 24400='上海移动'
    2914='NTT'; 3491='PCCW'; 6453='Tata'; 3356='Lumen'; 1299='Arelion(Telia)'; 174='Cogent'; 6461='Zayo'; 6939='HE'
    2516='KDDI'; 17676='软银'; 4713='NTT-OCN'; 4766='韩国电信KT'; 3786='LG U+'; 9318='SK宽带'; 7473='新加坡电信'
    4637='Telstra'; 3257='GTT'; 6762='意大利电信Sparkle'; 5511='Orange'; 3320='德国电信'; 1273='Vodafone'
    31898='Oracle'; 16509='Amazon'; 14618='Amazon'; 15169='Google'; 8075='微软'; 13335='Cloudflare'
}

function Get-TimeSlot([datetime]$t) {
    $h = $t.Hour
    if ($h -lt 6)  { return '深夜0-6' }
    if ($h -lt 12) { return '上午6-12' }
    if ($h -lt 18) { return '下午12-18' }
    if ($h -lt 21) { return '傍晚18-21' }
    return '晚高峰21-24'
}

function Measure-Once([string]$ip, [int]$port) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $c = New-Object Net.Sockets.TcpClient
    try {
        $t = $c.ConnectAsync($ip, $port)
        if ($t.Wait(3000)) { return [int]$sw.ElapsedMilliseconds }
        return -1
    } catch { return -1 } finally { $c.Close() }
}

function Get-Median($values) {
    $s = @($values | Sort-Object)
    if ($s.Count -eq 0) { return $null }
    return $s[[math]::Floor($s.Count / 2)]
}

function Get-Location([string]$name) {
    if ($Catalog.Contains($name)) { return $Catalog[$name].Name }
    if ($ReferenceNames.ContainsKey($name)) { return $ReferenceNames[$name] }
    return ''
}

function Resolve-Target([string]$hostPort) {
    $h, $port = $hostPort.Split(':')
    $ip = $h
    if ($h -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        $ip = ([Net.Dns]::GetHostAddresses($h) | Where-Object AddressFamily -eq 'InterNetwork' | Select-Object -First 1).IPAddressToString
    }
    if (-not $ip) { throw "无法解析 $h" }
    return "${ip}:$port"
}

# ---------- CSV ----------
function Write-CsvRows($rows, [switch]$Append) {
    $enc = New-Object System.Text.UTF8Encoding($true)   # 带 BOM，Excel 打开不乱码
    $lines = $rows | Select-Object -Property $Columns | ConvertTo-Csv -NoTypeInformation
    if ($Append) { [IO.File]::AppendAllLines($CsvPath, [string[]]($lines | Select-Object -Skip 1), $enc) }
    else         { [IO.File]::WriteAllLines($CsvPath, [string[]]$lines, $enc) }
}

function Update-CsvSchema {
    if (-not (Test-Path $CsvPath)) { return }
    $old = @(Import-Csv $CsvPath -Encoding UTF8)
    if ($old.Count -eq 0) { return }
    $have = $old[0].PSObject.Properties.Name
    if (@($Columns | Where-Object { $have -notcontains $_ }).Count -eq 0) { return }
    $migrated = foreach ($r in $old) {
        $o = [ordered]@{}
        foreach ($c in $Columns) { $o[$c] = if ($have -contains $c) { $r.$c } else { '' } }
        if (-not $o['位置']) { $o['位置'] = Get-Location $o['区域'] }
        [pscustomobject]$o
    }
    Copy-Item $CsvPath "$CsvPath.bak" -Force
    Write-CsvRows $migrated
    Write-Host "已把旧数据升级为新格式（原文件备份为 latency.csv.bak）"
}

# ---------- IP 归属查询（带本地缓存） ----------
$script:IpCache = @{}
if (Test-Path $CachePath) {
    try { (Get-Content $CachePath -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $script:IpCache[$_.Name] = $_.Value } } catch {}
}
function Test-PrivateIp([string]$ip) {
    return $ip -match '^(10\.|127\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.|169\.254\.)'
}
function Get-IpInfo([string]$ip) {
    if ($script:IpCache.ContainsKey($ip)) { return $script:IpCache[$ip] }
    $info = [pscustomobject]@{ asn = 0; org = '?'; city = ''; country = '' }
    try {
        $wc = New-Object Net.WebClient; $wc.Encoding = [Text.Encoding]::UTF8
        $url = "https://ipinfo.io/$ip/json"; if ($IpinfoToken) { $url += "?token=$IpinfoToken" }
        $j = $wc.DownloadString($url) | ConvertFrom-Json
        $asn = 0; $org = "$($j.org)"
        if ($org -match '^AS(\d+)\s*(.*)$') { $asn = [int]$matches[1]; $org = $matches[2] }
        $info = [pscustomobject]@{ asn = $asn; org = $org; city = "$($j.city)"; country = "$($j.country)" }
    } catch {}
    $script:IpCache[$ip] = $info
    return $info
}
function Save-IpCache {
    try { $script:IpCache | ConvertTo-Json -Depth 3 | Set-Content $CachePath -Encoding UTF8 } catch {}
}

# 把一串跳点 IP 汇总成 "运营商@城市 → ..."，并标记亚欧等区域的路径是否绕经美国
function Format-Path([string[]]$hopIps, [string]$regionName) {
    $parts = New-Object System.Collections.ArrayList
    $countries = New-Object System.Collections.ArrayList
    $last = ''
    foreach ($ip in $hopIps) {
        if ($ip -eq '*') { $label = '*' }
        elseif (Test-PrivateIp $ip) { continue }
        else {
            $i = Get-IpInfo $ip
            $carrier = if ($AsnNames.ContainsKey([int]$i.asn)) { $AsnNames[[int]$i.asn] } elseif ($i.asn) { ($i.org -split '\s')[0..1] -join ' ' } else { '未知' }
            $label = if ($i.city) { "$carrier@$($i.city)" } else { $carrier }
            if ($i.country) { [void]$countries.Add($i.country) }
        }
        if ($label -eq '*' -and $last -eq '*') { continue }
        # 同一节点中间夹着不响应（A → * → A）时合并为一个 A
        if ($label -ne '*' -and $parts.Count -ge 2 -and $parts[$parts.Count - 1] -eq '*' -and $parts[$parts.Count - 2] -eq $label) { $parts.RemoveAt($parts.Count - 1); $last = $label; continue }
        if ($label -ne $last) { [void]$parts.Add($label); $last = $label }
    }
    while ($parts.Count -gt 0 -and $parts[$parts.Count - 1] -eq '*') { $parts.RemoveAt($parts.Count - 1) }
    while ($parts.Count -gt 0 -and $parts[0] -eq '*') { $parts.RemoveAt(0) }
    $text = ($parts -join ' → ')
    $isAmericas = $regionName -match '^(aws-)?(us-|ca-|mx-|sa-)'
    if (-not $isAmericas -and ($countries -contains 'US')) { $text = "[经美国] $text" }
    if (-not $text) { $text = '(无响应)' }
    return $text
}

if ($Report) {
    if (-not (Test-Path $CsvPath)) { Write-Host "还没有数据：$CsvPath 不存在，请先测速一次。"; return }
    Update-CsvSchema
    $data  = @(Import-Csv $CsvPath -Encoding UTF8)
    $slots = @('深夜0-6','上午6-12','下午12-18','傍晚18-21','晚高峰21-24')
    $runs  = @($data | Select-Object -ExpandProperty 时间 -Unique).Count
    Write-Host ("共 {0} 次测速，{1} 条记录。单元格格式：中位延迟ms(异常率%)，异常 = 超时 + 超过1秒；'-' 表示该时段无数据。" -f $runs, $data.Count)
    Write-Host "排序依据：所有时段中最差的中位延迟（越小越好）。更直观的图表请用测速网站。`n"
    $rows = foreach ($g in ($data | Group-Object 区域)) {
        $loc = Get-Location $g.Name
        if (-not $loc) { $loc = ($g.Group | Select-Object -First 1).位置 }
        $row = [ordered]@{ '区域' = $g.Name; '位置' = $loc }
        $worst = 0
        foreach ($s in $slots) {
            $recs = @($g.Group | Where-Object { $_.时段 -eq $s -and $_.中位ms -ne '' })
            if ($recs.Count -eq 0) { $row[$s] = '-'; continue }
            $med = Get-Median ($recs | ForEach-Object { [int]$_.中位ms })
            $n   = ($recs | Measure-Object -Property 样本数 -Sum).Sum
            $bad = ($recs | ForEach-Object { [int]$_.超时次数 + [int]$_.超1秒次数 } | Measure-Object -Sum).Sum
            $pct = if ($n) { [math]::Round(100 * $bad / $n) } else { 0 }
            $row[$s] = "{0}({1}%)" -f $med, $pct
            if ($med -gt $worst) { $worst = $med }
        }
        $row['_worst'] = $worst
        [pscustomobject]$row
    }
    $rows | Sort-Object _worst | Select-Object -Property (@('区域','位置') + $slots) | Format-Table -AutoSize | Out-String -Width 250 | Write-Host
    return
}

# ---------- 测速 ----------
Update-CsvSchema
$targets = [ordered]@{}
foreach ($k in $Reference.Keys) {
    try { $targets[$k] = Resolve-Target $Reference[$k] } catch { Write-Warning "对照 $k 解析失败，跳过" }
}
# 经 -File 启动时 "a,b" 会作为一个字符串传入，这里统一按逗号拆分
$list = if ($Regions) { $Regions -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
        elseif ($DefaultRegions.Count) { $DefaultRegions }
        else { @($Catalog.Keys) }
foreach ($r in $list) {
    if (-not $Catalog.Contains($r)) { Write-Warning "未知区域代码 $r，跳过"; continue }
    try { $targets[$r] = Resolve-Target "$($Catalog[$r].Host):443" } catch { Write-Warning "$r 解析失败，跳过" }
}

$start = Get-Date
Write-Host ("{0:yyyy-MM-dd HH:mm} 开始测速：{1} 个目标 × {2} 轮，约 {3} 分钟..." -f $start, $targets.Count, $Rounds, [math]::Ceiling($targets.Count * $Rounds * 0.4 / 60))

$samples = @{}
foreach ($k in $targets.Keys) { $samples[$k] = New-Object System.Collections.ArrayList }
for ($i = 1; $i -le $Rounds; $i++) {
    foreach ($k in $targets.Keys) {
        $ip, $port = $targets[$k].Split(':')
        [void]$samples[$k].Add((Measure-Once $ip ([int]$port)))
    }
    Write-Progress -Activity '测速中' -Status "第 $i / $Rounds 轮" -PercentComplete (100 * $i / $Rounds)
    if ($env:LATENCY_PROGRESS) { Write-Host "[进度] 第 $i / $Rounds 轮" }   # 供测速网站显示进度
}
Write-Progress -Activity '测速中' -Completed

$forward = @{}; $return = @{}
if ($Trace) {
    # 延迟测量全部完成后再启动 tracert（并发 tracert 的探测包会干扰测速、把丢包率测高）
    $traceProcs = @{}
    $traceDir = Join-Path $env:TEMP ("latency-trace-" + $start.ToString('yyyyMMddHHmmss'))
    New-Item -ItemType Directory -Force $traceDir | Out-Null
    foreach ($k in $targets.Keys) {
        $ip = $targets[$k].Split(':')[0]
        $out = Join-Path $traceDir ("{0}.txt" -f ($k -replace '[^\w\-]', '_'))
        $traceProcs[$k] = @{ Out = $out; Proc = (Start-Process tracert -ArgumentList "-d -h 25 -w 800 $ip" -RedirectStandardOutput $out -NoNewWindow -PassThru) }
    }
    Write-Host "等待路由追踪完成并查询沿途 IP 的归属..."
    foreach ($k in $traceProcs.Keys) {
        $p = $traceProcs[$k].Proc
        if (-not $p.WaitForExit(90000)) { try { $p.Kill() } catch {} }
        $hops = @()
        foreach ($line in (Get-Content $traceProcs[$k].Out -ErrorAction SilentlyContinue)) {
            if ($line -match '^\s*\d+\s') {
                if ($line -match '(\d{1,3}(\.\d{1,3}){3})\s*$') { $hops += $matches[1] } else { $hops += '*' }
            }
        }
        $forward[$k] = Format-Path $hops $k
    }

    # 回程：从配置的服务器往回 mtr 到本机公网 IP（直连获取，不走系统代理）
    $needReturn = @($targets.Keys | Where-Object { $ReturnProbes.ContainsKey($_) })
    if ($needReturn.Count) {
        $myIp = $null
        foreach ($u in 'https://myip.ipip.net/', 'https://4.ipw.cn/', 'https://ip.3322.net/', 'https://api.ipify.org/') {
            try {
                $wc = New-Object Net.WebClient; $wc.Proxy = $null; $wc.Encoding = [Text.Encoding]::UTF8
                $wc.Headers.Add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) curl/8.0')
                if ($wc.DownloadString($u) -match '(\d{1,3}(\.\d{1,3}){3})') { $myIp = $matches[1]; break }
            } catch {}
        }
        $sshBase = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', '-o', 'StrictHostKeyChecking=accept-new')
        if ($SshKey) { $sshBase = @('-i', $SshKey) + $sshBase }
        $probeResults = @{}
        foreach ($k in $needReturn) {
            $login = $ReturnProbes[$k]
            if (-not $myIp) { $return[$k] = '(未能获取本机公网IP)'; continue }
            if (-not $probeResults.ContainsKey($login)) {
                # 优先 TCP 模式（需 sudo 免密），失败则退回普通模式
                $cmd = "sudo -n mtr -n -r -c 5 -T -P 443 $myIp 2>/dev/null || mtr -n -r -c 5 $myIp 2>/dev/null"
                $raw = & ssh @sshBase $login $cmd 2>$null
                $hops = @()
                foreach ($line in $raw) { if ($line -match '^\s*\d+\.\|--\s+(\S+)') { $hops += $(if ($matches[1] -eq '???') { '*' } else { $matches[1] }) } }
                $probeResults[$login] = if ($hops.Count) { Format-Path $hops $k } else { '(SSH 登录或 mtr 执行失败)' }
            }
            $return[$k] = $probeResults[$login]
        }
    }
    Save-IpCache
    Remove-Item -Recurse -Force $traceDir -ErrorAction SilentlyContinue
}

$stamp = $start.ToString('yyyy-MM-dd HH:mm')
$slot  = Get-TimeSlot $start
$rows = foreach ($k in $targets.Keys) {
    $ok   = @($samples[$k] | Where-Object { $_ -ge 0 } | Sort-Object)
    $fail = @($samples[$k] | Where-Object { $_ -lt 0 }).Count
    [pscustomobject]@{
        '时间'      = $stamp
        '时段'      = $slot
        '区域'      = $k
        '位置'      = Get-Location $k
        '中位ms'    = Get-Median $ok
        '最快ms'    = if ($ok.Count) { $ok[0] } else { $null }
        '最慢ms'    = if ($ok.Count) { $ok[-1] } else { $null }
        '超时次数'  = $fail
        '超1秒次数' = @($ok | Where-Object { $_ -gt 1000 }).Count
        '样本数'    = $samples[$k].Count
        '地址'      = $targets[$k]
        '去程路径'  = if ($forward.ContainsKey($k)) { $forward[$k] } else { '' }
        '回程路径'  = if ($return.ContainsKey($k)) { $return[$k] } else { '' }
    }
}

Write-CsvRows $rows -Append:(Test-Path $CsvPath)

$sorted = $rows | Sort-Object { if ($_.中位ms -ne $null) { [int]$_.中位ms } else { 99999 } }
$sorted | Format-Table 区域, 位置, 中位ms, 最快ms, 最慢ms, 超时次数, 超1秒次数 -AutoSize | Out-String -Width 220 | Write-Host
if ($Trace) {
    Write-Host "路径（按延迟从低到高；'@'后为 IP 地理库给出的城市，骨干网节点可能不准；'*' 表示该段节点不响应）："
    foreach ($r in $sorted) {
        Write-Host ("[{0} {1}] {2} ms" -f $r.区域, $r.位置, $r.中位ms)
        Write-Host ("   去程: {0}" -f $r.去程路径)
        Write-Host ("   回程: {0}" -f $(if ($r.回程路径) { $r.回程路径 } else { '未测(该区域未配置回程探测服务器)' }))
    }
}
Write-Host "`n本次时段：$slot。结果已追加到 $CsvPath"
