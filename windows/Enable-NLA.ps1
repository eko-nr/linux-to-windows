# ===========================================================
# Secure RDP Configuration Script (No TLS + NLA + Lockout)
# Works on Windows 10 LTSC / Enterprise / Pro
# ===========================================================

Write-Host "=== Configuring Secure RDP with NLA (No TLS) and Lockout Policy ===" -ForegroundColor Cyan

# --- Enable NLA ---
Write-Host "`n[1/5] Enabling Network Level Authentication (NLA)..." -ForegroundColor Yellow
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name UserAuthentication -Value 1

# --- Use Security Layer = 1 (HTTP/RDP, no TLS) ---
Write-Host "[2/5] Setting SecurityLayer to 1 (RDP security, no TLS)..." -ForegroundColor Yellow
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name SecurityLayer -Value 1

# --- Enable RDP if disabled ---
Write-Host "[3/5] Ensuring RDP is enabled..." -ForegroundColor Yellow
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections -Value 0

# --- Configure lockout policy ---
Write-Host "[4/5] Setting lockout policy: 5 attempts, 15 minutes..." -ForegroundColor Yellow
net accounts /lockoutthreshold:5 /lockoutduration:15 /lockoutwindow:15 | Out-Null

# --- Restart RDP service ---
Write-Host "[5/5] Restarting Remote Desktop Services..." -ForegroundColor Yellow
Stop-Service TermService -Force
Start-Service TermService

Write-Host "`n✅ Configuration complete!" -ForegroundColor Green
Write-Host "------------------------------------------------------"
Write-Host "RDP/NLA status:"
Write-Host "  • NLA = Enabled (UserAuthentication=1)"
Write-Host "  • SecurityLayer = 1 (RDP/HTTP, no TLS)"
Write-Host "  • Lockout = 5 attempts / 15 min lock"
Write-Host "------------------------------------------------------"

# --- Verification output ---
Write-Host "`n🔍 Verifying registry values..." -ForegroundColor Cyan
$ua = Get-ItemPropertyValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name UserAuthentication
$sl = Get-ItemPropertyValue -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name SecurityLayer
Write-Host "UserAuthentication = $ua"
Write-Host "SecurityLayer      = $sl"

Write-Host "`n🔐 Verifying account policy..." -ForegroundColor Cyan
net accounts | findstr /i "Lockout"
Write-Host "`nDone."