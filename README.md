# ⚡ Auto DNS Optimizer v2 for Windows

> **Next-generation, multi-probe, zero-RAM dynamic DNS optimizer for Windows.**  
> Automatically benchmarks top Anycast DNS providers using multi-domain jitter and packet loss analysis over asynchronous non-blocking UDP sockets, dynamically auto-tuning your connection to the fastest, most reliable DNS resolver in milliseconds.

---


## 📁 Repository Structure

```text
DNS-Optimizer-v2/
├── bin/                          # CLI executable wrappers for PATH
│   ├── dns-optimizer.cmd         # Primary CLI launcher
│   └── autodns.cmd               # Short alias launcher
├── config/                       # Custom configuration files
│   └── config.json               # Resolver definitions & user thresholds
├── docs/                         # In-depth technical documentation
│   └── ARCHITECTURE.md           # Network socket specs & scoring formulas
├── src/                          # Core PowerShell engine & installers
│   ├── AutoDnsOptimizer.ps1      # Asynchronous multi-probe UDP engine
│   ├── Install-AutoDnsTask.ps1   # Automated background service installer
│   └── Uninstall-AutoDnsTask.ps1 # Clean removal & DHCP restoration
├── .gitignore                    # Git tracking exclusions
├── autodns.cmd                   # Root short alias launcher
├── dns-optimizer.cmd             # Root CLI launcher
├── Install.bat                   # 1-Click admin installer
├── LICENSE                       # MIT License
├── README.md                     # Project documentation
└── Uninstall.bat                 # 1-Click admin uninstaller
```

## 🚀 What's New in Model v2

* **🔬 Multi-Probe Jitter & Packet Loss Engine:** Evaluates both **Median Latency** and **Jitter (Variance)** across multiple target domains simultaneously. Resolvers that drop packets or have unstable spikes are automatically penalized.
* **⚙️ External `config.json` Customization:** Add local Pi-hole or AdGuard Home resolvers, tweak hysteresis deltas, or add custom test domains without editing code.
* **🌐 Captive Portal & Isolated Network Guard:** Automatically inspects `Get-NetConnectionProfile.IPv4Connectivity`. Prevents DNS switching on hotel, airport, or captive Wi-Fi portals that require a web login page.
* **🔔 Native Windows Desktop Toast Notifications:** Optional Windows Action Center toast alert when DNS is dynamically switched upon changing Wi-Fi networks.
* **📊 `-AsJson` Output Support:** Allows terminal dashboards, monitoring tools, or Rainmeter skins to pull real-time DNS benchmarks as structured JSON.
* **🔒 Named Global Mutex & 45s Debounce Cooldown:** Prevents race conditions during rapid Wi-Fi reconnection bursts.
* **⚖️ Score-Based Anti-Flapping Hysteresis:** Prevents connection jitter from flipping adapters back and forth.
* **🔐 Windows 11 Native Encrypted DNS (DoH):** Automatically configures native Windows 11 DNS-over-HTTPS templates.

---

## 📊 Benchmark Comparison

| Feature / Metric | Model v1 | **Model v2** |
| :--- | :--- | :--- |
| **Benchmark Metrics** | Single packet round-trip time | **Median Latency + Jitter + Packet Loss %** |
| **Configuration** | Hardcoded script settings | **`config.json` with custom resolver support** |
| **Captive Portal Detection** | ❌ Blind test | **✅ Checks active IPv4 Internet connectivity** |
| **Desktop Notifications** | ❌ Log file only | **✅ Native Windows Desktop Toasts (WinRT)** |
| **CLI Output Formats** | Formatted table | **Formatted Table + `-AsJson` structured output** |
| **Stability Scoring** | Simple latency check | **Composite Score = Median + 0.2*Jitter + 5*Loss** |
| **RAM Footprint** | **0 MB** (Terminates after run) | **0 MB** (Terminates after run) |

---


## 🌐 Directory Independence & Global CLI Access

When installed via `Install.bat`:
1. **Permanent System Location:** Files are safely deployed to `C:\ProgramData\AutoDnsOptimizer\`. You can move, rename, or delete the original cloned folder without breaking scheduled background tasks.
2. **Global CMD / Terminal Access:** `AutoDnsOptimizer` is added to your Windows system PATH. You can run it from **any folder** in Command Prompt or PowerShell:
   ```cmd
   dns-optimizer -BenchmarkOnly
   autodns
   ```

## 🚀 Quick Start

### 1-Click Installation (Recommended)
1. Clone or download this directory:
   ```cmd
   git clone https://github.com/nap-fx/DNS-Optimizer-v2.git
   cd DNS-Optimizer-v2
   ```
2. Double-click or right-click **`Install.bat`** and choose **Run as administrator**.
3. Done! The optimizer will benchmark and apply the optimal DNS immediately, then continue running silently on startup, every 30 minutes, and whenever you change networks.

### Command Line (PowerShell)
You can run the optimizer directly from PowerShell:

```powershell
# Run multi-probe benchmark and apply optimal DNS
.\AutoDnsOptimizer.ps1

# Run benchmark only (prints table without modifying network adapter)
.\AutoDnsOptimizer.ps1 -BenchmarkOnly

# Output benchmark results as structured JSON
.\AutoDnsOptimizer.ps1 -BenchmarkOnly -AsJson

# Benchmark Ad-Blocking / Privacy profile
.\AutoDnsOptimizer.ps1 -BenchmarkOnly -Profile Privacy

# Force re-benchmark (bypasses debounce cooldown & hysteresis)
.\AutoDnsOptimizer.ps1 -Force

# Show desktop toast notification on switch
.\AutoDnsOptimizer.ps1 -Toast

# Revert adapter back to automatic DHCP
.\AutoDnsOptimizer.ps1 -Reset
```

---

## ⚙️ Configuration (`config.json`)

You can customize behavior by modifying `config.json`:

```json
{
  "DefaultProfile": "Speed",
  "EnableToastNotifications": false,
  "HysteresisDeltaMs": 10.0,
  "HysteresisRatio": 0.85,
  "DebounceSeconds": 45,
  "TestDomains": ["google.com", "cloudflare.com"],
  "TimeoutMs": 1200,
  "AutoEnableWindows11DoH": true,
  "CustomResolvers": [
    {
      "Name": "Home Pi-hole",
      "IPv4": ["192.168.1.100"],
      "IPv6": [],
      "DoHTemplate": "",
      "Profiles": ["Custom", "All"],
      "Enabled": true
    }
  ]
}
```

---

## 📋 DNS Profiles & Supported Resolvers

| Profile | Included Resolvers | Primary Focus |
| :--- | :--- | :--- |
| **`Speed`** *(Default)* | **Google**, **Cloudflare**, **ControlD**, **OpenDNS**, **Quad9** | Lowest gaming latency, fastest web browsing. |
| **`Privacy`** | **AdGuard** (AdBlock), **ControlD** (AdBlock), **Quad9** (Malware), **Mullvad** | System-wide ad and tracker blocking without browser extensions. |
| **`Security`** | **Cloudflare Family** (1.1.1.3), **CleanBrowsing**, **Quad9** | Phishing protection, malware blocking, adult content filtering. |
| **`Custom`** | Your custom resolvers from `config.json` | Local Pi-hole, AdGuard Home, or corporate resolvers. |
| **`All`** | All candidate resolvers | Diagnostic benchmark across all available providers. |

---

## 🗑️ Uninstallation

To remove background scheduled tasks and revert your adapter back to default automatic DHCP:
* Right-click **`Uninstall.bat`** and run as administrator, or run:
  ```powershell
  .\Uninstall-AutoDnsTask.ps1
  ```

---

## 📄 License

Distributed under the **MIT License**. See [`LICENSE`](LICENSE) for more information.
