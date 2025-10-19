Write-Host "🔧 Enabling Remote Desktop and Firewall rules..." -ForegroundColor Cyan

Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
    -Name "fDenyTSConnections" -Value 0 -Force

Set-Service -Name TermService -StartupType Automatic
Start-Service -Name TermService

Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue

$rules = @(
    @{ Name = "Allow RDP TCP 3389"; Protocol = "TCP"; Port = 3389 },
    @{ Name = "Allow RDP UDP 3389"; Protocol = "UDP"; Port = 3389 }
)
foreach ($r in $rules) {
    if (-not (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $r.Name -Direction Inbound -Action Allow `
            -Protocol $r.Protocol -LocalPort $r.Port -Profile Any -Enabled True | Out-Null
        Write-Host "✅ Added firewall rule: $($r.Name)"
    } else {
        Write-Host "ℹ️  Firewall rule already exists: $($r.Name)"
    }
}

Write-Host "`n✅ Remote Desktop enabled and Firewall configured for TCP/UDP 3389." -ForegroundColor Green
