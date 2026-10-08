<#
    Secure Boot & TPM 2.0 Check - online starter

    Run this in PowerShell:

        irm https://raw.githubusercontent.com/Krimziee/SecureBootCheck/main/run.ps1 | iex

    What it does:
      1. Opens a new PowerShell window with admin rights (Windows asks "Yes/No")
      2. That window loads the newest SecureBootCheck.ps1 from GitHub into
         memory and runs it

    Nothing is saved to disk and nothing on the PC is changed.
#>

& {
    $url = 'https://raw.githubusercontent.com/Krimziee/SecureBootCheck/main/SecureBootCheck.ps1'

    # The admin window downloads the check itself and runs it from memory.
    # Passed as an encoded command so no quoting can break on the way.
    $command = "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; " +
               "& ([scriptblock]::Create((Invoke-RestMethod -Uri '$url' -UseBasicParsing)))"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))

    Write-Host ''
    Write-Host ' Secure Boot & TPM 2.0 Check' -ForegroundColor Cyan
    Write-Host ' This check makes no changes to your PC - it only reads your settings.' -ForegroundColor Gray
    Write-Host ' Click "Yes" when Windows asks for permission (needed to READ the settings).' -ForegroundColor Gray
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded
        )
        Write-Host ' The check is opening in a new window. You can close this one.' -ForegroundColor Green
    } catch {
        Write-Host " Couldn't start the check: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host ' Run the command again and click "Yes" on the admin prompt.' -ForegroundColor Gray
    }
}
