# 🏗️ Auto DNS Optimizer v2 - Architecture & Technical Specifications

This document outlines the internal architecture, network socket lifecycle, scoring formulas, and Windows event integration for **Auto DNS Optimizer v2**.

---

## 1. Multi-Probe Non-Blocking UDP Engine

Instead of relying on high-level Windows PowerShell cmdlets (e.g. `Resolve-DnsName`), which suffer from cold-start module overhead and sequential serialization, Model v2 implements a direct `.NET` raw socket layer via `System.Net.Sockets.UdpClient`.

### Packet Structure (RFC 1035 Standard DNS Query)
For each benchmarked domain ($D$) and candidate resolver IP ($S$):
```
0                   1                   2                   3
0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|          Query ID             |QR|   Opcode  |AA|TC|RD|RA|Z |RCODE|
|         (0x4000+)             | 0|   0 0 0 0 | 0| 0| 1| 0|0 | 0 0 | (0x0100)
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|          QDCOUNT (1)          |          ANCOUNT (0)          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|          NSCOUNT (0)          |          ARCOUNT (0)          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                     QNAME (e.g., google.com)                  |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|         QTYPE (0x0001 = A)    |        QCLASS (0x0001 = IN)   |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

### Asynchronous Parallel Dispatch
1. **Parallel Dispatch:** Sockets for all candidates ($N$) $\times$ domains ($M$) are instantiated with `Blocking = $false`.
2. **Synchronous Broadcast:** All $N \times M$ queries fire in $< 2\text{ ms}$.
3. **Non-Blocking Polling Loop:** A tight poll loop checks `Udp.Available > 0` with $2\text{ ms}$ sleeps, recording elapsed time via `System.Diagnostics.Stopwatch`.
4. **Completion:** When all probes return or timeout ($1,200\text{ ms}$) expires, sockets close immediately.

---

## 2. Composite Reliability Score Formula

Model v2 does not pick a DNS server based purely on a single lucky ping. It calculates a composite stability score:

$$\text{Score} = \text{MedianMs} + (0.2 \times \text{JitterMs}) + (5 \times \text{LossPct})$$

Where:
* **$\text{MedianMs}$:** Median round-trip latency across all test domains.
* **$\text{JitterMs}$:** $\text{MaxLatency} - \text{MinLatency}$. Penalizes unstable routing or route-flapping.
* **$\text{LossPct}$:** Percentage of dropped packets. Heavily penalizes unreliable resolvers.
* **Lowest Score Wins.**

---

## 3. Anti-Flapping Hysteresis Logic

To prevent constant DNS changes when two providers have similar latency (e.g., Google at 22 ms vs ControlD at 25 ms):

$$\text{Switch Condition} = (\text{ActiveScore} - \text{WinnerScore} \ge \Delta_{\text{min}}) \land \left(\frac{\text{WinnerScore}}{\text{ActiveScore}} \le R_{\text{thresh}}\right)$$

* $\Delta_{\text{min}} = 10.0\text{ ms}$ (Configurable via `HysteresisDeltaMs`)
* $R_{\text{thresh}} = 0.85$ (Configurable via `HysteresisRatio`, requires 15% improvement)
* If the active DNS fails or drops packets, hysteresis is bypassed and failover is instantaneous.

---

## 4. Windows Event Triggers

Model v2 hooks into Windows Event Viewer:
* **Log Channel:** `Microsoft-Windows-NetworkProfile/Operational`
* **Event ID `10000`:** Fired when a network interface successfully establishes network connectivity (e.g., switching Wi-Fi, waking from sleep, plugging Ethernet).
* **Debounce Guard:** Guarded by `Global\AutoDnsOptimizer_v2_Running` and a 45-second cooldown timestamp in `.last_run`.
