param(
    [switch]$NoStartup
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot = Split-Path -Parent $ScriptDir
$DaemonJs = Join-Path $RepoRoot 'daemon\theme_daemon.js'
$PayloadJs = Join-Path $RepoRoot 'dist\theme_payload.js'
$BuildPy = Join-Path $RepoRoot 'scripts\build_payload.py'
$PidFile = Join-Path $RepoRoot 'daemon.pid'
$VbsPath = Join-Path $RepoRoot 'silent-start.vbs'

$NodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $NodeCmd) {
    Write-Error "Node.js not found in PATH. Install Node.js >= 22 first."
}
$NodeExe = $NodeCmd.Source
$NodeMajor = [int]((& $NodeExe -p "process.versions.node.split('.')[0]").Trim())
if ($NodeMajor -lt 22) {
    Write-Error "Node.js >= 22 is required (found v$NodeMajor at $NodeExe)."
}

if (-not (Test-Path $PayloadJs)) {
    $PyCmd = Get-Command python -ErrorAction SilentlyContinue
    if (-not $PyCmd) {
        $PyCmd = Get-Command python3 -ErrorAction SilentlyContinue
    }
    if (-not $PyCmd) {
        Write-Error "dist/theme_payload.js is missing and Python was not found to build it."
    }
    Write-Host "[install-win] Building dist/theme_payload.js..."
    & $PyCmd.Source $BuildPy
    if ($LASTEXITCODE -ne 0) {
        Write-Error "build_payload.py failed with exit code $LASTEXITCODE."
    }
}

if (Test-Path $PidFile) {
    $OldPidText = (Get-Content $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    $OldPid = 0
    if ([int]::TryParse(($OldPidText -as [string]), [ref]$OldPid) -and $OldPid -gt 0) {
        $ExistingProc = Get-Process -Id $OldPid -ErrorAction SilentlyContinue
        if ($ExistingProc -and $ExistingProc.ProcessName -eq 'node') {
            Write-Host "[install-win] Stopping existing daemon (PID $OldPid)..."
            Stop-Process -Id $OldPid -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 350
        }
    }
    Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
}

# Generate silent-start.vbs dynamically without hardcoding user or Node paths.
$EscapedNode = $NodeExe.Replace('"', '""')
$EscapedDaemon = $DaemonJs.Replace('"', '""')
$VbsContent = @"
Set WshShell = CreateObject("WScript.Shell")
WshShell.CurrentDirectory = "$($RepoRoot.Replace('"', '""'))"
WshShell.Run """$EscapedNode"" ""$EscapedDaemon""", 0, False
"@
Set-Content -Path $VbsPath -Value $VbsContent -Encoding Unicode

if (-not $NoStartup) {
    $StartupDir = [Environment]::GetFolderPath('Startup')
    $ShortcutPath = Join-Path $StartupDir 'AntigravityCustomTheme.lnk'
    $WshShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
    $Shortcut.TargetPath = 'wscript.exe'
    $Shortcut.Arguments = """$VbsPath"""
    $Shortcut.WorkingDirectory = $RepoRoot
    $Shortcut.WindowStyle = 7
    $Shortcut.Description = 'Antigravity Custom Theme Daemon'
    $Shortcut.Save()
    Write-Host "[install-win] Startup shortcut created: $ShortcutPath"

    # Configure all Antigravity launch shortcuts & protocol handlers to include --remote-debugging-port=0
    $TargetAgyExe = Join-Path $env:LOCALAPPDATA 'Programs\antigravity\Antigravity.exe'
    $DebugFlag = '--remote-debugging-port=0'
    if (Test-Path $TargetAgyExe) {
        $DesktopDirs = @([Environment]::GetFolderPath('Desktop'), (Join-Path $env:USERPROFILE 'Desktop')) | Select-Object -Unique
        foreach ($d in $DesktopDirs) {
            if (Test-Path $d) {
                $lnk = Join-Path $d 'Antigravity.lnk'
                $s = $WshShell.CreateShortcut($lnk)
                $s.TargetPath = $TargetAgyExe
                $s.Arguments = $DebugFlag
                $s.WorkingDirectory = Split-Path $TargetAgyExe -Parent
                $s.Description = 'Antigravity (Custom Theme Enabled)'
                $s.Save()
                Write-Host "[install-win] Configured desktop shortcut: $lnk"
            }
        }

        $ProgramsDir = [Environment]::GetFolderPath('Programs')
        $StartMenuLnks = @(
            (Join-Path $ProgramsDir 'Antigravity.lnk'),
            (Join-Path $ProgramsDir 'Antigravity IDE\Antigravity IDE.lnk')
        )
        foreach ($lnk in $StartMenuLnks) {
            $parentDir = Split-Path $lnk -Parent
            if (Test-Path $parentDir) {
                $s = $WshShell.CreateShortcut($lnk)
                $s.TargetPath = $TargetAgyExe
                $s.Arguments = $DebugFlag
                $s.WorkingDirectory = Split-Path $TargetAgyExe -Parent
                $s.Save()
                Write-Host "[install-win] Configured Start Menu shortcut: $lnk"
            }
        }

        # Registry protocol handlers
        @('HKCU:\Software\Classes\antigravity\shell\open\command', 'HKCU:\Software\Classes\antigravity-ide\shell\open\command') | ForEach-Object {
            if (Test-Path $_) {
                Set-ItemProperty -Path $_ -Name '(default)' -Value "`"$TargetAgyExe`" $DebugFlag `"%1`"" -ErrorAction SilentlyContinue
            }
        }
    }
}

Write-Host "[install-win] Launching daemon via detached WMI process..."
$Launched = $false
try {
    $WmiResult = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{
        CommandLine = "wscript.exe `"$VbsPath`""
        CurrentDirectory = $RepoRoot
    } -ErrorAction Stop
    if ($WmiResult.ReturnValue -eq 0) {
        $Launched = $true
    }
} catch {
    $Launched = $false
}
if (-not $Launched) {
    Write-Host "[install-win] Fallback: launching daemon via wscript.exe..."
    Start-Process -FilePath 'wscript.exe' -ArgumentList """$VbsPath""" -WorkingDirectory $RepoRoot
}

for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Milliseconds 250
    if (Test-Path $PidFile) {
        $NewPidText = (Get-Content $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        $NewPid = 0
        if ([int]::TryParse(($NewPidText -as [string]), [ref]$NewPid) -and $NewPid -gt 0) {
            if (Get-Process -Id $NewPid -ErrorAction SilentlyContinue) {
                Write-Host "[install-win] Daemon running silently (PID $NewPid)."
                exit 0
            }
        }
    }
}

Write-Warning "[install-win] Daemon did not write daemon.pid in time. Check $RepoRoot\daemon.log."
exit 1
