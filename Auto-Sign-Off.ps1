<#
.SYNOPSIS
    Logs off users in a 'Disconnected' state who have been idle longer
    than a configurable threshold (default: 3 hours) and appends each
    sign-off event to a JSON log file. Designed for unattended use
    via Action1 (runs as SYSTEM) - no confirmation prompts.

.PARAMETER ComputerName
    One or more servers to target. Defaults to the local machine.

.PARAMETER MinIdleHours
    Minimum idle time (in hours) before a disconnected session is signed off.

.PARAMETER LogPath
    Path to the JSON log file. Defaults to "C:\temp\Auto Sign off\log.json".

.PARAMETER WhatIf
    Preview mode: lists eligible sessions but does not actually log anyone off
    or write to the log file.
#>

param(
    [string[]]$ComputerName = $env:COMPUTERNAME,
    [int]$MinIdleHours = 3,
    [string]$LogPath = 'C:\temp\Auto Sign off\log.json',
    [switch]$WhatIf
)

function ConvertTo-IdleTimeSpan {
    param([string]$Idle)

    if ([string]::IsNullOrWhiteSpace($Idle)) { return [TimeSpan]::Zero }
    $Idle = $Idle.Trim()
    if ($Idle -eq '.' -or $Idle -ieq 'none') { return [TimeSpan]::Zero }

    # Days+HH:MM  e.g. "1+02:30"
    if ($Idle -match '^(\d+)\+(\d{1,2}):(\d{2})$') {
        return [TimeSpan]::new([int]$matches[1], [int]$matches[2], [int]$matches[3], 0)
    }
    # HH:MM  e.g. "2:15"
    if ($Idle -match '^(\d{1,2}):(\d{2})$') {
        return [TimeSpan]::new([int]$matches[1], [int]$matches[2], 0)
    }
    # Just minutes  e.g. "45"
    if ($Idle -match '^(\d+)$') {
        return [TimeSpan]::FromMinutes([int]$matches[1])
    }
    return [TimeSpan]::Zero
}

function Write-SignOffLog {
    param(
        [string]$UserName,
        [string]$Server,
        [string]$SessionID,
        [string]$IdleTime,
        [string]$Path
    )

    $entry = [PSCustomObject]@{
        username  = $UserName
        text1     = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
        server    = $Server
        sessionId = $SessionID
        idleTime  = $IdleTime
        action    = 'logoff'
    }

    $json = $entry | ConvertTo-Json -Compress -Depth 3

    try {
        $dir = Split-Path -Path $Path -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Add-Content -LiteralPath $Path -Value $json -Encoding utf8
    }
    catch {
        Write-Warning "Failed to write log entry to $Path : $_"
    }
}

function Get-DisconnectedSessions {
    param([string]$Server)

    try {
        $raw = quser /server:$Server 2>$null
        if (-not $raw) { return @() }

        $raw | Select-Object -Skip 1 | ForEach-Object {
            $line  = $_.Trim() -replace '\s{2,}', ','
            $parts = $line -split ','

            if ($parts.Count -eq 5) {
                # Disconnected sessions have no SESSIONNAME column
                [PSCustomObject]@{
                    Server      = $Server
                    UserName    = $parts[0].TrimStart('>')
                    SessionName = ''
                    SessionID   = $parts[1]
                    State       = $parts[2]
                    IdleTime    = $parts[3]
                    LogonTime   = $parts[4]
                }
            }
            elseif ($parts.Count -ge 6) {
                [PSCustomObject]@{
                    Server      = $Server
                    UserName    = $parts[0].TrimStart('>')
                    SessionName = $parts[1]
                    SessionID   = $parts[2]
                    State       = $parts[3]
                    IdleTime    = $parts[4]
                    LogonTime   = $parts[5]
                }
            }
        } | Where-Object { $_.State -eq 'Disc' } |
            ForEach-Object {
                $_ | Add-Member -NotePropertyName IdleSpan `
                                -NotePropertyValue (ConvertTo-IdleTimeSpan $_.IdleTime) `
                                -PassThru
            }
    }
    catch {
        Write-Warning "Could not query sessions on $Server : $_"
    }
}

$threshold = [TimeSpan]::FromHours($MinIdleHours)

foreach ($server in $ComputerName) {
    Write-Host "`n=== Checking $server (threshold: $MinIdleHours hour(s)) ===" -ForegroundColor Cyan

    $disconnected = Get-DisconnectedSessions -Server $server
    if (-not $disconnected) {
        Write-Host "No disconnected sessions found." -ForegroundColor Green
        continue
    }

    $eligible = $disconnected | Where-Object { $_.IdleSpan -ge $threshold }
    $skipped  = $disconnected | Where-Object { $_.IdleSpan -lt $threshold }

    if ($skipped) {
        Write-Host "Skipping $($skipped.Count) session(s) under the $MinIdleHours-hour threshold:" -ForegroundColor DarkYellow
        $skipped | Format-Table UserName, SessionID, IdleTime, LogonTime -AutoSize
    }

    if (-not $eligible) {
        Write-Host "No disconnected sessions exceed the $MinIdleHours-hour threshold." -ForegroundColor Green
        continue
    }

    Write-Host "Found $($eligible.Count) session(s) eligible for sign-off:" -ForegroundColor Yellow
    $eligible | Format-Table UserName, SessionID, IdleTime, LogonTime -AutoSize

    foreach ($session in $eligible) {
        $target = "$($session.UserName) (ID $($session.SessionID), idle $($session.IdleTime)) on $server"

        if ($WhatIf) {
            Write-Host "What if: would log off $target" -ForegroundColor Magenta
            continue
        }

        try {
            logoff $session.SessionID /server:$server
            Write-Host "Logged off $target" -ForegroundColor Green

            Write-SignOffLog -UserName  $session.UserName `
                             -Server    $server `
                             -SessionID $session.SessionID `
                             -IdleTime  $session.IdleTime `
                             -Path      $LogPath
        }
        catch {
            Write-Warning "Failed to log off $target : $_"
        }
    }
}

exit 0
