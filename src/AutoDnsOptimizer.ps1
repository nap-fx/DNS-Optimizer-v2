<#
.SYNOPSIS
    AutoDnsOptimizer v2 - Next-Gen Native Windows Dynamic DNS Optimizer
.DESCRIPTION
    Model v2 features an asynchronous multi-probe parallel UDP benchmark engine
    that evaluates Median Latency, Jitter, and Packet Loss % across top Anycast DNS
    providers in < 250 ms. Features captive portal detection, config.json overrides,
    anti-flapping hysteresis, Windows 11 DoH auto-registration, and native desktop toasts.
.PARAMETER BenchmarkOnly
    Runs the multi-probe benchmark and displays results in a formatted console table without modifying settings.
.PARAMETER AsJson
    Outputs benchmark or execution results as structured JSON (ideal for scripts, widgets, and dashboards).
.PARAMETER Reset
    Reverts the active network adapter back to standard DHCP (automatic DNS) and flushes DNS cache.
.PARAMETER Force
    Bypasses debounce cooldown and hysteresis thresholds, forcing immediate DNS re-evaluation.
.PARAMETER Toast
    Displays a native Windows toast notification upon successful DNS re-optimization.
.PARAMETER Config
    Specifies a custom JSON configuration file path (defaults to config.json in script directory).
.PARAMETER Profile
    Selects DNS provider profile: Speed (default), Privacy, Security, All, or Custom.
.PARAMETER Quiet
    Suppresses console output (used by background scheduled tasks).
#>
[CmdletBinding()]
param(
    [switch]$BenchmarkOnly,
    [switch]$AsJson,
    [switch]$Reset,
    [switch]$Force,
    [switch]$Toast,
    [string]$Config,
    [ValidateSet("Speed", "Privacy", "Security", "All", "Custom")][string]$Profile,
    [switch]$Quiet
)

$ErrorActionPreference = "SilentlyContinue"

# -------------------------------------------------------------------------
# Path and Configuration Setup
# -------------------------------------------------------------------------
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$LogFile = Join-Path $ScriptDir "AutoDnsOptimizer.log"
$StateFile = Join-Path $ScriptDir ".last_run"
$RootDir = Split-Path -Parent $ScriptDir
$ConfigFile = if ($Config -and (Test-Path $Config)) {
    $Config
} elseif (Test-Path (Join-Path $ScriptDir "config.json")) {
    Join-Path $ScriptDir "config.json"
} elseif (Test-Path (Join-Path $RootDir "config\config.json")) {
    Join-Path $RootDir "config\config.json"
} else {
    Join-Path $ScriptDir "config.json"
}

# Default Configuration
$Cfg = @{
    DefaultProfile           = "Speed"
    EnableToastNotifications = $false
    HysteresisDeltaMs        = 10.0
    HysteresisRatio          = 0.85
    DebounceSeconds          = 45
    TestDomains              = @("google.com", "cloudflare.com")
    TimeoutMs                = 1200
    AutoEnableWindows11DoH   = $true
    CustomResolvers          = @()
}

# Load custom config.json if present
if (Test-Path $ConfigFile) {
    try {
        $jsonContent = Get-Content $ConfigFile -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
        if ($jsonContent.DefaultProfile) { $Cfg.DefaultProfile = [string]$jsonContent.DefaultProfile }
        if ($jsonContent.EnableToastNotifications -ne $null) { $Cfg.EnableToastNotifications = [bool]$jsonContent.EnableToastNotifications }
        if ($jsonContent.HysteresisDeltaMs) { $Cfg.HysteresisDeltaMs = [double]$jsonContent.HysteresisDeltaMs }
        if ($jsonContent.HysteresisRatio) { $Cfg.HysteresisRatio = [double]$jsonContent.HysteresisRatio }
        if ($jsonContent.DebounceSeconds) { $Cfg.DebounceSeconds = [int]$jsonContent.DebounceSeconds }
        if ($jsonContent.TestDomains) { $Cfg.TestDomains = @($jsonContent.TestDomains) }
        if ($jsonContent.TimeoutMs) { $Cfg.TimeoutMs = [int]$jsonContent.TimeoutMs }
        if ($jsonContent.AutoEnableWindows11DoH -ne $null) { $Cfg.AutoEnableWindows11DoH = [bool]$jsonContent.AutoEnableWindows11DoH }
        if ($jsonContent.CustomResolvers) { $Cfg.CustomResolvers = $jsonContent.CustomResolvers }
    } catch {}
}

# Resolve active profile
$activeProfile = if ($Profile) { $Profile } else { $Cfg.DefaultProfile }
$enableToast = if ($Toast) { $true } else { $Cfg.EnableToastNotifications }

function Log-Message([string]$msg, [string]$color = "White") {
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] $msg"
    
    if (-not $Quiet -and -not $AsJson) {
        Write-Host $logLine -ForegroundColor $color
    }

    try {
        Add-Content -Path $LogFile -Value $logLine -ErrorAction SilentlyContinue
        if ((Get-Item $LogFile -ErrorAction SilentlyContinue).Length -gt 1048576) {
            $recent = Get-Content $LogFile | Select-Object -Last 500
            $recent | Set-Content $LogFile -ErrorAction SilentlyContinue
        }
    } catch {}
}

# -------------------------------------------------------------------------
# Toast Notification Function (WinRT + Forms Fallback)
# -------------------------------------------------------------------------
function Show-DesktopToast([string]$title, [string]$body) {
    try {
        $template = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $xml = [xml]$template.GetXml()
        $nodes = $xml.GetElementsByTagName("text")
        $nodes[0].AppendChild($xml.CreateTextNode($title)) | Out-Null
        $nodes[1].AppendChild($xml.CreateTextNode($body)) | Out-Null
        $toastXml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $toastXml.LoadXml($xml.OuterXml)
        $toast = [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime]::new($toastXml)
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]::CreateToastNotifier("AutoDnsOptimizer_v2").Show($toast)
    } catch {
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
            $notify = New-Object System.Windows.Forms.NotifyIcon
            $notify.Icon = [System.Drawing.SystemIcons]::Information
            $notify.BalloonTipTitle = $title
            $notify.BalloonTipText = $body
            $notify.Visible = $true
            $notify.ShowBalloonTip(3000)
            Start-Sleep -Milliseconds 300
            $notify.Dispose()
        } catch {}
    }
}

# -------------------------------------------------------------------------
# Elevation Check (Required for changing adapter settings)
# -------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $BenchmarkOnly -and -not $AsJson -and -not $isAdmin) {
    if (-not $Quiet) {
        Write-Host "[*] Administrative privileges required to configure network adapter." -ForegroundColor Yellow
        Write-Host "[*] Requesting elevation..." -ForegroundColor Cyan
    }
    try {
        $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
        if ($Reset) { $argList += "-Reset" }
        if ($Force) { $argList += "-Force" }
        if ($Toast) { $argList += "-Toast" }
        if ($Profile) { $argList += @("-Profile", $Profile) }
        if ($Quiet) { $argList += "-Quiet" }
        if ($Config) { $argList += @("-Config", "`"$Config`"") }
        
        Start-Process powershell.exe -Verb RunAs -ArgumentList ($argList -join ' ')
        exit 0
    } catch {
        Log-Message "[-] Elevation request was cancelled or failed: $_" "Red"
        exit 1
    }
}

# -------------------------------------------------------------------------
# DNS Resolvers Catalog (Built-in + Custom Resolvers)
# -------------------------------------------------------------------------
$DnsCatalog = @{
    # Speed Presets
    "Google" = @{
        Name        = "Google"
        IPv4        = @("8.8.8.8", "8.8.4.4")
        IPv6        = @("2001:4860:4860::8888", "2001:4860:4860::8844")
        DoHTemplate = "https://dns.google/dns-query"
        Profiles    = @("Speed", "All")
    }
    "Cloudflare" = @{
        Name        = "Cloudflare"
        IPv4        = @("1.1.1.1", "1.0.0.1")
        IPv6        = @("2606:4700:4700::1111", "2606:4700:4700::1001")
        DoHTemplate = "https://cloudflare-dns.com/dns-query"
        Profiles    = @("Speed", "All")
    }
    "Quad9" = @{
        Name        = "Quad9 (Malware Block)"
        IPv4        = @("9.9.9.9", "149.112.112.112")
        IPv6        = @("2620:fe::fe", "2620:fe::9")
        DoHTemplate = "https://dns.quad9.net/dns-query"
        Profiles    = @("Speed", "Privacy", "Security", "All")
    }
    "ControlD" = @{
        Name        = "ControlD"
        IPv4        = @("76.76.2.0", "76.76.10.0")
        IPv6        = @("2606:1a40::0", "2606:1a40:1::0")
        DoHTemplate = "https://freedns.controld.com/p0"
        Profiles    = @("Speed", "All")
    }
    "OpenDNS" = @{
        Name        = "OpenDNS"
        IPv4        = @("208.67.222.222", "208.67.220.220")
        IPv6        = @("2620:119:35::35", "2620:119:53::53")
        DoHTemplate = "https://doh.opendns.com/dns-query"
        Profiles    = @("Speed", "All")
    }
    
    # Privacy & AdBlock Presets
    "AdGuard" = @{
        Name        = "AdGuard (AdBlock)"
        IPv4        = @("94.140.14.14", "94.140.15.15")
        IPv6        = @("2a10:50c0::ad1:ff", "2a10:50c0::ad2:ff")
        DoHTemplate = "https://dns.adguard-dns.com/dns-query"
        Profiles    = @("Privacy", "All")
    }
    "ControlD-AdBlock" = @{
        Name        = "ControlD (AdBlock)"
        IPv4        = @("76.76.2.2", "76.76.10.2")
        IPv6        = @("2606:1a40::2", "2606:1a40:1::2")
        DoHTemplate = "https://freedns.controld.com/p2"
        Profiles    = @("Privacy", "All")
    }

    # Security & Family Presets
    "Cloudflare-Family" = @{
        Name        = "Cloudflare (Family/Malware)"
        IPv4        = @("1.1.1.3", "1.0.0.3")
        IPv6        = @("2606:4700:4700::1113", "2606:4700:4700::1003")
        DoHTemplate = "https://family.cloudflare-dns.com/dns-query"
        Profiles    = @("Security", "All")
    }
    "CleanBrowsing" = @{
        Name        = "CleanBrowsing (Family)"
        IPv4        = @("185.228.168.168", "185.228.169.168")
        IPv6        = @("2a0d:2a00:1::", "2a0d:2a00:2::")
        DoHTemplate = "https://doh.cleanbrowsing.org/doh/family-filter/"
        Profiles    = @("Security", "All")
    }
}

# Merge custom resolvers from config.json
if ($Cfg.CustomResolvers) {
    foreach ($cr in $Cfg.CustomResolvers) {
        if ($cr.Enabled -ne $false -and $cr.IPv4 -and $cr.IPv4.Count -gt 0) {
            $DnsCatalog[$cr.Name] = @{
                Name        = $cr.Name
                IPv4        = @($cr.IPv4)
                IPv6        = if ($cr.IPv6) { @($cr.IPv6) } else { @() }
                DoHTemplate = if ($cr.DoHTemplate) { $cr.DoHTemplate } else { $null }
                Profiles    = if ($cr.Profiles) { @($cr.Profiles) } else { @("Custom", "All") }
            }
        }
    }
}

# -------------------------------------------------------------------------
# Network Adapter Discovery & Captive Portal Detection
# -------------------------------------------------------------------------
function Get-ActiveInternetAdapter {
    # Check default IPv4 route
    $defaultRoute = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric | Select-Object -First 1

    $adapter = $null
    if ($defaultRoute) {
        $adapter = Get-NetAdapter -InterfaceIndex $defaultRoute.InterfaceIndex -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Up' -and $_.Virtual -eq $false }
    }
    if (-not $adapter) {
        $adapter = Get-NetAdapter | Where-Object {
            $_.Status -eq 'Up' -and $_.Virtual -eq $false -and $_.InterfaceAlias -notmatch 'vEthernet|Virtual|Loopback|Bluetooth'
        } | Select-Object -First 1
    }

    if (-not $adapter) { return $null }

    # Validate active internet connectivity (skip captive portals / isolated nets)
    $netProfile = Get-NetConnectionProfile -InterfaceIndex $adapter.InterfaceIndex -ErrorAction SilentlyContinue
    $hasInternet = ($netProfile -and $netProfile.IPv4Connectivity -eq 'Internet')

    return @{
        Adapter     = $adapter
        HasInternet = $hasInternet
        ProfileName = if ($netProfile) { $netProfile.Name } else { "Unknown" }
    }
}

$netInfo = Get-ActiveInternetAdapter
$activeAdapter = if ($netInfo) { $netInfo.Adapter } else { $null }

# -------------------------------------------------------------------------
# Handle -Reset Flag (Revert to DHCP)
# -------------------------------------------------------------------------
if ($Reset) {
    if (-not $activeAdapter) {
        Log-Message "[-] No active network adapter found to reset." "Red"
        exit 1
    }
    Log-Message "[*] Reverting $($activeAdapter.InterfaceAlias) DNS to automatic (DHCP)..." "Yellow"
    try {
        Set-DnsClientServerAddress -InterfaceIndex $activeAdapter.InterfaceIndex -ResetServerAddresses -ErrorAction Stop
        Clear-DnsClientCache
        Log-Message "[OK] DNS successfully reset to DHCP on $($activeAdapter.InterfaceAlias)." "Green"
        if ($enableToast) {
            Show-DesktopToast "DNS Reset to Automatic" "Adapter $($activeAdapter.InterfaceAlias) is now using standard DHCP."
        }
        exit 0
    } catch {
        Log-Message "[-] Failed to reset DNS: $_" "Red"
        exit 1
    }
}

# -------------------------------------------------------------------------
# Mutex Lock & Debounce Protection (Anti-Spam / Race-Condition Guard)
# -------------------------------------------------------------------------
if (-not $BenchmarkOnly -and -not $AsJson) {
    $mutexName = "Global\AutoDnsOptimizer_v2_Running"
    $mutexCreated = $false
    $mutex = New-Object System.Threading.Mutex($false, $mutexName, [ref]$mutexCreated)
    $hasHandle = $false
    try {
        $hasHandle = $mutex.WaitOne(500, $false)
    } catch {
        $hasHandle = $false
    }

    if (-not $hasHandle) {
        Log-Message "[*] Another instance of AutoDnsOptimizer v2 is currently executing. Exiting." "DarkGray"
        exit 0
    }

    # Cooldown Debounce
    if (-not $Force -and (Test-Path $StateFile)) {
        try {
            $lastRun = [DateTime](Get-Content $StateFile -Raw -ErrorAction SilentlyContinue).Trim()
            $elapsedSeconds = ((Get-Date) - $lastRun).TotalSeconds
            if ($elapsedSeconds -lt $Cfg.DebounceSeconds) {
                Log-Message "[*] Debounce active (last run was $([math]::Round($elapsedSeconds))s ago). Skipping redundant event." "DarkGray"
                if ($hasHandle) { [void]$mutex.ReleaseMutex() }
                exit 0
            }
        } catch {}
    }
}

# -------------------------------------------------------------------------
# Pre-Flight Network Checks
# -------------------------------------------------------------------------
if (-not $activeAdapter) {
    Log-Message "[-] No active network adapter found. Skipping optimization." "Red"
    if ($hasHandle) { [void]$mutex.ReleaseMutex() }
    exit 0
}

if (-not $BenchmarkOnly -and -not $netInfo.HasInternet -and -not $Force) {
    Log-Message "[!] $($activeAdapter.InterfaceAlias) has no active Internet route or is behind a Captive Portal. Skipping DNS optimization." "Yellow"
    if ($hasHandle) { [void]$mutex.ReleaseMutex() }
    exit 0
}

# -------------------------------------------------------------------------
# Multi-Probe Asynchronous Parallel UDP Benchmark Engine
# -------------------------------------------------------------------------
function Invoke-MultiProbeParallelDnsBenchmark {
    param(
        [hashtable[]]$Candidates,
        [string[]]$Domains,
        [int]$TimeoutMs = 1200
    )

    # Encode query packets for each domain
    $encodedDomains = @{}
    foreach ($d in $Domains) {
        $qname = New-Object System.IO.MemoryStream
        foreach ($part in $d.Split('.')) {
            $bytes = [System.Text.Encoding]::ASCII.GetBytes($part)
            $qname.WriteByte([byte]$bytes.Length)
            $qname.Write($bytes, 0, $bytes.Length)
        }
        $qname.WriteByte(0)
        $encodedDomains[$d] = @{
            QnameBytes = $qname.ToArray()
            QtypeQclass = [byte[]]@(0x00, 0x01, 0x00, 0x01)
        }
    }

    $sockets = @{}
    $swBenchmark = [System.Diagnostics.Stopwatch]::StartNew()
    $idCounter = 0x4000

    # Dispatch probes across all candidate primary IPs and domains concurrently
    foreach ($candidate in $Candidates) {
        $serverIp = $candidate.IPv4[0]
        $sockets[$serverIp] = @{
            Candidate = $candidate
            Probes    = @{}
        }

        foreach ($d in $Domains) {
            try {
                $idBytes = [System.BitConverter]::GetBytes([uint16]$idCounter)
                if ([System.BitConverter]::IsLittleEndian) { [Array]::Reverse($idBytes) }
                $flags = [byte[]]@(0x01, 0x00)
                $counts = [byte[]]@(0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
                $packet = $idBytes + $flags + $counts + $encodedDomains[$d].QnameBytes + $encodedDomains[$d].QtypeQclass

                $udp = New-Object System.Net.Sockets.UdpClient
                $udp.Client.Blocking = $false
                $endpoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($serverIp), 53)

                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                [void]$udp.Send($packet, $packet.Length, $endpoint)

                $sockets[$serverIp].Probes[$d] = @{
                    Udp        = $udp
                    ExpectedId = $idCounter
                    Stopwatch  = $sw
                    Latency    = $null
                    Done       = $false
                }
                $idCounter++
            } catch {
                $sockets[$serverIp].Probes[$d] = @{
                    Udp     = $null
                    Latency = $null
                    Done    = $true
                }
            }
        }
    }

    # Non-blocking poll loop
    $deadline = $swBenchmark.ElapsedMilliseconds + $TimeoutMs
    $totalProbes = $Candidates.Count * $Domains.Count
    $completedProbes = 0

    while ($completedProbes -lt $totalProbes -and $swBenchmark.ElapsedMilliseconds -lt $deadline) {
        foreach ($serverIp in $sockets.Keys) {
            foreach ($d in $sockets[$serverIp].Probes.Keys) {
                $probe = $sockets[$serverIp].Probes[$d]
                if ($probe.Done) { continue }

                if ($probe.Udp -and $probe.Udp.Available -gt 0) {
                    $probe.Stopwatch.Stop()
                    $remoteEP = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                    try {
                        $resp = $probe.Udp.Receive([ref]$remoteEP)
                        $rcode = if ($resp.Length -ge 12) { $resp[3] -band 0x0F } else { -1 }
                        if ($rcode -eq 0) {
                            $probe.Latency = [math]::Round($probe.Stopwatch.Elapsed.TotalMilliseconds, 1)
                        }
                    } catch {}
                    $probe.Done = $true
                    $completedProbes++
                }
            }
        }
        Start-Sleep -Milliseconds 2
    }

    # Compile results & score
    $results = @()
    foreach ($serverIp in $sockets.Keys) {
        $entry = $sockets[$serverIp]
        $cand = $entry.Candidate
        $validLatencies = @()
        $failedCount = 0

        foreach ($d in $entry.Probes.Keys) {
            $probe = $entry.Probes[$d]
            if ($probe.Udp) { $probe.Udp.Close() }
            if ($probe.Latency -ne $null) {
                $validLatencies += $probe.Latency
            } else {
                $failedCount++
            }
        }

        $probeCount = $Domains.Count
        $lossPct = [math]::Round(($failedCount / $probeCount) * 100, 0)

        if ($validLatencies.Count -gt 0) {
            $sorted = $validLatencies | Sort-Object
            $count = $sorted.Count
            $median = if ($count % 2 -eq 1) {
                $sorted[[math]::Floor($count / 2)]
            } else {
                [math]::Round(($sorted[($count/2) - 1] + $sorted[$count/2]) / 2, 1)
            }
            $jitter = if ($count -gt 1) { [math]::Round($sorted[-1] - $sorted[0], 1) } else { 0.0 }
            $score = [math]::Round($median + ($jitter * 0.2) + ($lossPct * 5), 1)

            $results += [PSCustomObject]@{
                Name      = $cand.Name
                Server    = $serverIp
                MedianMs  = $median
                JitterMs  = $jitter
                LossPct   = $lossPct
                Score     = $score
                Success   = ($lossPct -lt 100)
                Candidate = $cand
            }
        } else {
            $results += [PSCustomObject]@{
                Name      = $cand.Name
                Server    = $serverIp
                MedianMs  = 9999
                JitterMs  = 0
                LossPct   = 100
                Score     = 9999
                Success   = $false
                Candidate = $cand
            }
        }
    }

    $swBenchmark.Stop()
    return @{
        TotalElapsedMs = [math]::Round($swBenchmark.Elapsed.TotalMilliseconds, 1)
        Results        = ($results | Sort-Object Score)
    }
}

# -------------------------------------------------------------------------
# Execution Flow
# -------------------------------------------------------------------------
# Select candidates by Profile
$selectedCandidates = @()
foreach ($key in $DnsCatalog.Keys) {
    $c = $DnsCatalog[$key]
    if ($c.Profiles -contains $activeProfile) {
        $selectedCandidates += $c
    }
}

if ($selectedCandidates.Count -eq 0) {
    Log-Message "[-] No resolvers found matching profile: $activeProfile" "Red"
    if ($hasHandle) { [void]$mutex.ReleaseMutex() }
    exit 1
}

Log-Message "Starting Multi-Probe DNS benchmark (Profile: $activeProfile, Adapter: $($activeAdapter.InterfaceAlias))..." "Cyan"

$benchmark = Invoke-MultiProbeParallelDnsBenchmark -Candidates $selectedCandidates -Domains $Cfg.TestDomains -TimeoutMs $Cfg.TimeoutMs
$results = $benchmark.Results
$totalMs = $benchmark.TotalElapsedMs

Log-Message "Benchmark completed in ${totalMs} ms across $($results.Count) resolvers ($($Cfg.TestDomains.Count) probes each)." "Green"

# Output JSON if requested
if ($AsJson) {
    $jsonOutput = [PSCustomObject]@{
        Timestamp       = Get-Date -Format "o"
        Adapter         = $activeAdapter.InterfaceAlias
        Profile         = $activeProfile
        BenchmarkTimeMs = $totalMs
        Resolvers       = ($results | Select-Object Name, Server, MedianMs, JitterMs, LossPct, Score, Success)
    }
    $jsonOutput | ConvertTo-Json -Depth 4
    if ($hasHandle) { [void]$mutex.ReleaseMutex() }
    exit 0
}

# Display Formatted Table in Console
if (-not $Quiet) {
    Write-Host ""
    Write-Host ("  {0,-28} {1,-16} {2,-11} {3,-10} {4,-8} {5}" -f "RESOLVER", "PRIMARY IP", "MEDIAN", "JITTER", "LOSS", "STATUS") -ForegroundColor Gray
    Write-Host ("  {0,-28} {1,-16} {2,-11} {3,-10} {4,-8} {5}" -f "--------", "----------", "------", "------", "----", "------") -ForegroundColor Gray

    foreach ($r in $results) {
        $medianStr = if ($r.Success) { "$($r.MedianMs) ms" } else { "TIMEOUT" }
        $jitterStr = if ($r.Success) { "$($r.JitterMs) ms" } else { "-" }
        $lossStr = "$($r.LossPct)%"
        $statusStr = if ($r.Success) { "[OK]" } else { "[FAIL]" }
        $color = if (-not $r.Success) { "DarkRed" } elseif ($r.Score -lt 40) { "Green" } elseif ($r.Score -lt 85) { "Yellow" } else { "DarkYellow" }
        Write-Host ("  {0,-28} {1,-16} {2,-11} {3,-10} {4,-8} {5}" -f $r.Name, $r.Server, $medianStr, $jitterStr, $lossStr, $statusStr) -ForegroundColor $color
    }
    Write-Host ""
}

# If BenchmarkOnly requested, exit cleanly
if ($BenchmarkOnly) {
    exit 0
}

# Determine Winner
$winner = $results | Where-Object { $_.Success -eq $true } | Select-Object -First 1

if (-not $winner) {
    Log-Message "[-] All DNS resolvers timed out or failed. Retaining existing configuration." "Red"
    if ($hasHandle) { [void]$mutex.ReleaseMutex() }
    exit 0
}

Log-Message "Winner: $($winner.Name) ($($winner.Server)) with Score: $($winner.Score) (Median: $($winner.MedianMs) ms, Jitter: $($winner.JitterMs) ms)." "Green"

# -------------------------------------------------------------------------
# Anti-Flapping Hysteresis Check (Score-based)
# -------------------------------------------------------------------------
$currentDnsV4 = (Get-DnsClientServerAddress -InterfaceIndex $activeAdapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
$activePrimary = if ($currentDnsV4 -and $currentDnsV4.Count -gt 0) { $currentDnsV4[0] } else { $null }

# If active DNS is already winner
if ($activePrimary -eq $winner.Server -and -not $Force) {
    Log-Message "Adapter is already using the best DNS ($($winner.Name)). No update needed." "Green"
    Get-Date -Format "o" | Set-Content $StateFile -ErrorAction SilentlyContinue
    if ($hasHandle) { [void]$mutex.ReleaseMutex() }
    exit 0
}

# Check if active DNS is in candidate set and within hysteresis threshold
if ($activePrimary -and -not $Force) {
    $activeResult = $results | Where-Object { $_.Server -eq $activePrimary -and $_.Success -eq $true } | Select-Object -First 1
    if ($activeResult) {
        $scoreDelta = $activeResult.Score - $winner.Score
        if ($scoreDelta -lt $Cfg.HysteresisDeltaMs -or ($winner.Score / $activeResult.Score) -gt $Cfg.HysteresisRatio) {
            Log-Message "Active DNS ($($activeResult.Name) @ Score $($activeResult.Score)) is within hysteresis threshold of winner ($($winner.Name) @ Score $($winner.Score), delta: ${scoreDelta}). Retaining active configuration." "Yellow"
            Get-Date -Format "o" | Set-Content $StateFile -ErrorAction SilentlyContinue
            if ($hasHandle) { [void]$mutex.ReleaseMutex() }
            exit 0
        }
    }
}

# -------------------------------------------------------------------------
# Apply Winning DNS to Active Adapter
# -------------------------------------------------------------------------
try {
    $cand = $winner.Candidate
    Log-Message "Applying $($winner.Name) DNS to $($activeAdapter.InterfaceAlias)..." "Cyan"

    # Set IPv4 addresses
    Set-DnsClientServerAddress -InterfaceIndex $activeAdapter.InterfaceIndex -ServerAddresses $cand.IPv4 -ErrorAction Stop

    # Set IPv6 addresses
    if ($cand.IPv6) {
        Set-DnsClientServerAddress -InterfaceIndex $activeAdapter.InterfaceIndex -ServerAddresses $cand.IPv6 -ErrorAction SilentlyContinue
    }

    # Windows 11 Native DoH (DNS-over-HTTPS) Auto-Registration
    if ($Cfg.AutoEnableWindows11DoH -and [Environment]::OSVersion.Version.Build -ge 22000 -and $cand.DoHTemplate) {
        try {
            foreach ($ip in $cand.IPv4) {
                if (-not (Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue)) {
                    Add-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $cand.DoHTemplate -AllowFallbackToUdp $true -AutoUpgrade $true -ErrorAction SilentlyContinue
                }
            }
        } catch {}
    }

    # Flush DNS cache
    Clear-DnsClientCache

    # Update state file timestamp
    Get-Date -Format "o" | Set-Content $StateFile -ErrorAction SilentlyContinue

    Log-Message "Successfully applied $($winner.Name) DNS (IPv4: $($cand.IPv4 -join ', ') | IPv6: $($cand.IPv6 -join ', '))." "Green"

    # Trigger desktop toast if enabled
    if ($enableToast) {
        Show-DesktopToast "⚡ DNS Optimized ($($winner.Name))" "Connected to $($winner.Name) on $($activeAdapter.InterfaceAlias) (Latency: $($winner.MedianMs) ms)."
    }
} catch {
    Log-Message "[-] Error applying DNS configuration: $_" "Red"
} finally {
    if ($hasHandle) { [void]$mutex.ReleaseMutex() }
}
