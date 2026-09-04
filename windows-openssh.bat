@echo off
rem ---------------------------------------------------------------------------
rem windows-openssh.bat — amaiko fork addition, not present upstream.
rem
rem Runs from SetupComplete.cmd (or the GPO startup-script path) once, right
rem after Windows Setup finishes and after windows-set-netconf-*.bat has brought
rem the network up. Its whole job is to leave the machine reachable over SSH so
rem that everything else — NetBird enrolment, the build toolchain, the Forgejo
rem runner and its token — can be delivered later over an encrypted channel
rem instead of being baked into a public disk image.
rem
rem WHY THIS EXISTS AT ALL. Hetzner's `ssh_keys` on a cloud server only seeds the
rem Linux image it was created from. Windows Setup overwrites that disk, so by
rem the time this runs there is no authorized_keys anywhere and no other way in
rem except RDP with a password.
rem
rem NOTHING SECRET IS IN THIS FILE, DELIBERATELY. It reads the PUBLIC key out of
rem the Hetzner metadata service rather than carrying one, so this fork stays
rem free of any amaiko-specific content and can be public without leaking even a
rem public key. The metadata already holds the key because the server is created
rem with `ssh_keys` set.
rem ---------------------------------------------------------------------------

rem The Feature-on-Demand package, not a GitHub release. It is the
rem Microsoft-supported path, needs no version pin to stay correct, and is
rem serviced by Windows Update like any other Windows component. It does require
rem outbound access to Windows Update at this moment; if that fails, this script
rem fails and the recovery is RDP, which the unattend has already enabled.
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ^
  "if ((Get-WindowsCapability -Online -Name 'OpenSSH.Server*').State -ne 'Installed') { Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' }"

rem Start it and keep it started. Both services: ssh-agent is not needed to
rem accept a connection, but leaving it disabled breaks key handling later.
sc.exe config sshd start= auto
sc.exe config ssh-agent start= auto
net start sshd

rem PowerShell as the login shell rather than cmd.exe. The provisioning script
rem that follows is PowerShell, and piping it into a cmd.exe session mangles
rem quoting in ways that are painful to debug over a one-shot SSH channel.
reg add "HKLM\SOFTWARE\OpenSSH" /v DefaultShell /t REG_SZ ^
  /d "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" /f

rem The FoD install normally creates this rule; assert it anyway, because a
rem missing inbound rule presents exactly like a dead sshd from the outside.
netsh advfirewall firewall add rule name="OpenSSH Server (sshd)" ^
  dir=in action=allow protocol=TCP localport=22

rem --- the authorized key, from Hetzner metadata ---
rem
rem /hetzner/v1/metadata/public-keys answers a YAML list, so entries arrive as
rem `- ssh-ed25519 AAAA... comment` and sometimes quoted. Strip the list marker
rem and any surrounding quotes, keep only lines that actually look like a key,
rem and refuse to write an empty file — an empty administrators_authorized_keys
rem locks SSH out just as thoroughly as a missing one, but looks configured.
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "$raw = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 'http://169.254.169.254/hetzner/v1/metadata/public-keys').Content;" ^
  "$keys = $raw -split \"`n\" | ForEach-Object { $_.Trim() -replace '^-\s*','' -replace '^[\"'']|[\"'']$','' } | Where-Object { $_ -match '^(ssh-(rsa|ed25519)|ecdsa-sha2-)' };" ^
  "if (-not $keys) { throw 'no usable public key in Hetzner metadata' };" ^
  "$dir = Join-Path $env:ProgramData 'ssh';" ^
  "New-Item -ItemType Directory -Force -Path $dir | Out-Null;" ^
  "Set-Content -Path (Join-Path $dir 'administrators_authorized_keys') -Value $keys -Encoding ascii"

rem THE ACL STEP IS NOT OPTIONAL AND IT FAILS SILENTLY WHEN SKIPPED.
rem
rem sshd refuses to read administrators_authorized_keys if any account beyond
rem Administrators and SYSTEM holds rights on it — inherited rights from
rem ProgramData are enough to trip this. The connection is then rejected as if
rem the key were wrong, and the only evidence is in sshd's own log, which is not
rem where anyone looks first. /inheritance:r drops the inherited ACEs; the two
rem grants put back exactly what is allowed.
icacls "%ProgramData%\ssh\administrators_authorized_keys" /inheritance:r ^
  /grant "Administrators:F" /grant "SYSTEM:F"

rem Pick up the DefaultShell registry value and the new key file.
net stop sshd
net start sshd
