# Auto Sign Off – Disconnected RDS Sessions

A PowerShell script that automatically signs off users who have been in a **Disconnected** state on a Windows Server for longer than a configurable threshold (default: **3 hours**), and appends each sign-off event to an NDJSON log file for downstream ingestion into any log-analytics platform.

Designed for unattended execution as `SYSTEM` (via any RMM, scheduler, or endpoint management tool that runs PowerShell).

---

## 📋 Table of contents

- [Why this script exists](#-why-this-script-exists)
- [How it works](#-how-it-works)
- [Parameters](#-parameters)
- [Log output](#-log-output)
- [Deployment](#-deployment)
- [Manual / interactive use](#-manual--interactive-use)
- [Troubleshooting](#-troubleshooting)
- [Requirements](#-requirements)

---

## 🎯 Why this script exists

Disconnected RDS sessions accumulate over time, tying up:

- **CAL licences** (Per User CALs are consumed while sessions linger)
- **Memory & CPU** on session hosts
- **Application locks** (open files, database connections, etc.)

Manually reviewing `quser` output on every server is tedious. This script does it automatically, safely (only sessions idle **≥ 3 hours**), and leaves a clean JSON audit trail so activity can be tracked centrally.

---

## ⚙️ How it works

At a high level, the script does this on each target server:

```
┌────────────────────┐     ┌──────────────────────┐     ┌────────────────────┐
│ Enumerate sessions │ ──► │ Filter State = Disc  │ ──► │ Parse IDLE TIME    │
│    via `quser`     │     │   (disconnected)     │     │  into a TimeSpan   │
└────────────────────┘     └──────────────────────┘     └─────────┬──────────┘
                                                                  │
                                                                  ▼
                                                        ┌────────────────────┐
                                                        │ Idle ≥ threshold ? │
                                                        └────┬───────────┬───┘
                                                             │ Yes       │ No
                                                             ▼           ▼
                                                     ┌───────────────┐  Skip
                                                     │ `logoff <id>` │  (logged
                                                     │ + append to   │   to
                                                     │   log.json    │   console)
                                                     └───────────────┘
```

### Key design decisions

- **`quser` + `logoff`** rather than WMI/CIM — both are built into every modern Windows Server SKU, no modules to install, and they run cleanly as `SYSTEM`.
- **Custom `quser` parser** — `quser` output is fixed-width text with a quirk: disconnected sessions have a *blank* `SESSIONNAME` column, which throws off simple splits. The parser detects the column count and pads accordingly.
- **`ConvertTo-IdleTimeSpan` helper** — `quser`'s IDLE TIME column has several possible formats (`.`, `none`, `45`, `2:15`, `1+02:30`). The helper normalises all of them into a real `[TimeSpan]` for reliable comparison.
- **NDJSON log format** — one compact JSON object per line, the format expected by most log-tailing agents and easy to parse with any JSON tool.
- **`text1` field for the timestamp** — deliberately named as a generic string field so log-analytics agents don't auto-parse it as the log's official `@timestamp`. This keeps the timestamp under the ingestion agent's control and avoids timezone conflicts.
- **No `[CmdletBinding]` / `ShouldProcess`** — some hosted PowerShell environments don't populate `$PSCmdlet` correctly, which can cause null-reference errors. A manual `-WhatIf` switch is used instead for portability.
- **Explicit `exit 0`** — ensures unattended runners report success even when `quser` sets `$LASTEXITCODE` non-zero on servers with no sessions.

---

## 🔧 Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `-ComputerName` | `string[]` | Local machine | One or more servers to target. |
| `-MinIdleHours` | `int` | `3` | Minimum idle time (hours) before a disconnected session is signed off. |
| `-LogPath` | `string` | `C:\Auto Sign off\log.json` | Path to the NDJSON log file. Parent folder is auto-created. |
| `-WhatIf` | `switch` | Off | Preview only — lists eligible sessions but does not sign off or log. |

---

## 📝 Log output

Each successful sign-off appends one line to `log.json`:

```json
{"username":"Buffy Summers","text1":"2026-06-26T16:45:12+10:00","server":"Desktop-Office","sessionId":"6","idleTime":"1+00:18","action":"logoff"}
```

| Field | Purpose |
|---|---|
| `username` | The signed-off user (from `quser`'s USERNAME column). |
| `text1` | ISO-8601 timestamp with offset, stored as a **plain string** so log agents treat it as text rather than the record's timestamp. |
| `server` | Which server the sign-off happened on. |
| `sessionId` | RDS session ID passed to `logoff`. |
| `idleTime` | Original `quser` idle string (preserved for auditability). |
| `action` | Always `logoff` (leaves room to add `skipped`, `error`, etc. later). |

---

## 🚀 Deployment

The script is designed to run as `SYSTEM` with zero interactive input, making it suitable for any unattended runner (RMM tool, scheduled task, endpoint management platform, etc.).

1. Place `signoff.ps1` on the target server (or push it via your deployment tool).
2. Invoke it with PowerShell — no arguments needed. The defaults cover:
   - ✅ Target = local server
   - ✅ Threshold = 3 hours
   - ✅ Log path = `C:\Auto Sign off\log.json`
3. Schedule it to run **hourly** (recommended) — pairs well with the 3-hour threshold so the worst-case lifetime of a stale session is ~4 hours.



### Testing safely before going live

Before the first real run, change this line at the top of the script:

```powershell
[switch]$WhatIf = $true
```

Push, review the console output, then flip back to `$false` for production.

---

## 💻 Manual / interactive use

For ad-hoc testing on a single server:

```powershell
# Preview only — safe, no sign-offs
.\signoff.ps1 -WhatIf

# Real run against the local server
.\signoff.ps1

# Target a remote server with a 4-hour threshold
.\signoff.ps1 -ComputerName SRV-RDS01 -MinIdleHours 4

# Override the log location (note the quotes for the space in the path)
.\signoff.ps1 -LogPath "\\fileserver\logs\Auto Sign off\log.json"
```

Run from an **elevated** PowerShell session — `logoff` requires an admin token.

---

## 🩹 Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Could not query sessions on <server>` | Missing **Query Information** RDS right, or RPC (TCP 135 + dynamic) blocked. | Run as `SYSTEM`, or grant the account rights via `tsconfig.msc`. |
| No `log.json` created | Script ran but found no eligible sessions. | Check console output — file is only written when a sign-off actually occurs. |
| Runner reports failure but sign-offs succeeded | `quser` occasionally sets `$LASTEXITCODE` non-zero on no-session servers. | Already handled — `exit 0` at the end forces a clean return code. |
| `$PSCmdlet` null reference errors | Older version with `[CmdletBinding()]` + `ShouldProcess`. | Use the current version — `[CmdletBinding()]` has been removed. |
| Log written to `C:\Windows\System32\log.json` | Older version relied on `$PSScriptRoot`, which is empty when run as SYSTEM. | Current version hard-codes the log path — upgrade to the latest `signoff.ps1`. |

---

## 📦 Requirements

- **OS:** Windows Server 2016 or later (session host role or standalone).
- **PowerShell:** 5.1+ (Windows PowerShell) or 7.x.
- **Rights:** Administrator on the target server (or `SYSTEM` via an unattended runner).
- **Modules:** None — uses only built-in `quser` and `logoff`.

---

## 📄 License

Internal use. Adapt freely for your environment.
