<#
    Checks whether Secure Boot and TPM 2.0 are set up properly - what
    anti-cheat in many games requires - and, if they aren't, works out
    exactly why and what to change.

    THIS TOOL MAKES NO CHANGES TO THE PC. Every check only reads firmware
    variables, the registry, the TPM status and the disk layout. Fix
    commands are only printed as text for the user to run themselves.
    Anyone changing this script must keep it that way.

    The one side effect: "mbr2gpt /validate" (a check-only mode, run only on
    Legacy PCs with an MBR disk) writes Windows' usual setupact.log and
    setuperr.log files to C:\Windows.

    Run:  powershell -ExecutionPolicy Bypass -File SecureBootCheck.ps1
          (or double-click "Check Secure Boot.cmd" in this folder)
#>
param([switch]$NoPause)

$script:Version = '1.0.0'

# ------------------------------------------------------------------
#  Admin rights: the firmware variables can only be read as admin
# ------------------------------------------------------------------

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Admin rights are needed to READ the Secure Boot and TPM settings - click "Yes" on the prompt.'
    Write-Host 'They are only used for reading. This tool makes no changes to your PC.'
    if ($PSCommandPath) {
        $arguments = '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    } else {
        # Started from memory (irm ... | iex): load it from GitHub again in the admin window
        $url = 'https://raw.githubusercontent.com/Krimziee/SecureBootCheck/main/SecureBootCheck.ps1'
        $command = "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; " +
                   "& ([scriptblock]::Create((Invoke-RestMethod -Uri '$url' -UseBasicParsing)))"
        $arguments = '-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    }
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments
    } catch {
        Write-Host 'Could not get admin rights. Start the check again and click "Yes".' -ForegroundColor Red
        if (-not $NoPause) { Read-Host 'Press Enter to close' | Out-Null }
    }
    return   # not "exit": when run with "irm ... | iex", exit would close the player's PowerShell window
}

# ------------------------------------------------------------------
#  Output helpers
# ------------------------------------------------------------------

$script:Problems = New-Object System.Collections.Generic.List[object]
$script:Warnings = New-Object System.Collections.Generic.List[object]
$script:BitLocker = $null           # filled in by Test-BitLocker
$script:NeedsConversion = $false    # the fix includes mbr2gpt /convert

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host (' ' + ('-' * $Title.Length)) -ForegroundColor DarkCyan
}

function Write-Item {
    param(
        [string]$Label,
        [string]$Value = '',
        [ValidateSet('Ok', 'Warn', 'Fail', 'Info')] [string]$Status = 'Info'
    )
    $tag, $color = switch ($Status) {
        'Ok'   { '[ OK ]', 'Green' }
        'Warn' { '[WARN]', 'Yellow' }
        'Fail' { '[FAIL]', 'Red' }
        'Info' { '[INFO]', 'Gray' }
    }
    Write-Host "  $tag " -ForegroundColor $color -NoNewline
    Write-Host ("{0,-28} {1}" -f $Label, $Value)
}

# The order problems must be fixed in. Problems are listed in this order, not
# in the order they were found: e.g. the disk must be converted to GPT before
# the BIOS is switched to UEFI, and Secure Boot can only be turned on after that.
$script:FixOrder = @{ Disk = 1; BootMode = 2; SecureBoot = 3; Tpm = 4; ReadError = 5 }

function Add-Problem {
    # A problem that stops Secure Boot or TPM 2.0 from working, with the steps to fix it
    param([string]$Cause, [string[]]$Fix, [ValidateSet('Disk', 'BootMode', 'SecureBoot', 'Tpm', 'ReadError')] [string]$Area)
    $script:Problems.Add([pscustomobject]@{
        Cause = $Cause; Fix = $Fix
        Order = $script:FixOrder[$Area]
        Index = $script:Problems.Count   # keeps problems of the same area in the order they were found
    })
}

function Add-Warning {
    # Secure Boot works, but something about it should be looked at
    param([string]$Cause, [string[]]$Fix)
    $script:Warnings.Add([pscustomobject]@{ Cause = $Cause; Fix = $Fix })
}

# ------------------------------------------------------------------
#  Firmware readers
# ------------------------------------------------------------------

function Get-FirmwareType {
    # Asks Windows directly how it was booted: 1 = Legacy BIOS, 2 = UEFI
    if (-not ('SecureBootCheck.Native' -as [type])) {
        Add-Type -Namespace SecureBootCheck -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")]
public static extern bool GetFirmwareType(ref uint FirmwareType);
'@
    }
    $type = [uint32]0
    if ([SecureBootCheck.Native]::GetFirmwareType([ref]$type)) {
        switch ($type) { 1 { return 'Legacy' } 2 { return 'UEFI' } }
    }
    # Fallback: Windows also sets this variable at boot
    if ($env:firmware_type) { return $env:firmware_type }
    'Unknown'
}

function Get-UefiVariable {
    # Returns the raw bytes of a Secure Boot variable, or $null if it doesn't exist
    param([string]$Name)
    try {
        $var = Get-SecureBootUEFI -Name $Name -ErrorAction Stop
        if ($var -and $var.Bytes -and $var.Bytes.Length -gt 0) { return , $var.Bytes }
    } catch { }
    $null
}

function Get-UefiFlag {
    # Reads a one-byte on/off variable (SecureBoot, SetupMode...): 1, 0 or $null
    param([string]$Name)
    $bytes = Get-UefiVariable $Name
    if ($bytes) { [int]$bytes[0] } else { $null }
}

function Get-SignatureCertificates {
    <#
        Splits a key database (PK, KEK, db, dbx) into its certificates.
        The format is a list of EFI_SIGNATURE_LIST blocks; only the
        X.509 blocks hold certificates, the rest are file hashes.
    #>
    param([byte[]]$Bytes)
    $x509 = [guid]'a5c059a1-94e4-4aa7-87b5-ab155c2bf072'
    $offset = 0
    while ($Bytes -and $offset + 28 -le $Bytes.Length) {
        $type       = New-Object guid (, [byte[]]$Bytes[$offset..($offset + 15)])
        $listSize   = [BitConverter]::ToUInt32($Bytes, $offset + 16)
        $headerSize = [BitConverter]::ToUInt32($Bytes, $offset + 20)
        $sigSize    = [BitConverter]::ToUInt32($Bytes, $offset + 24)
        if ($listSize -lt 28 -or $offset + $listSize -gt $Bytes.Length) { break }   # damaged data

        if ($type -eq $x509 -and $sigSize -gt 16) {
            $sig = $offset + 28 + $headerSize
            while ($sig + $sigSize -le $offset + $listSize) {
                # Each entry is a 16-byte owner GUID followed by the certificate
                $der = [byte[]]$Bytes[($sig + 16)..($sig + $sigSize - 1)]
                try { New-Object Security.Cryptography.X509Certificates.X509Certificate2 (, $der) } catch { }
                $sig += $sigSize
            }
        }
        $offset += $listSize
    }
}

function Get-CommonName {
    param($Certificate)
    if ($Certificate.Subject -match 'CN=([^,]+)') { $Matches[1].Trim('"') } else { $Certificate.Subject }
}

# ------------------------------------------------------------------
#  Checks
# ------------------------------------------------------------------

function Test-IsLaptop {
    $laptopChassis = 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32
    $chassis = (Get-CimInstance Win32_SystemEnclosure).ChassisTypes
    [bool](($chassis | Where-Object { $_ -in $laptopChassis }) -or
           (Get-CimInstance Win32_ComputerSystem).PCSystemType -eq 2 -or
           (Get-CimInstance Win32_Battery))
}

function Get-BiosKey {
    <#
        Returns the brand and the key that opens the BIOS/UEFI setup, or $null
        for unknown brands. Prebuilt PCs and laptops report their brand as the
        system maker; self-built PCs often report a placeholder ("System
        manufacturer", "To Be Filled By O.E.M."), so the motherboard maker is
        checked as well.
    #>
    param($ComputerSystem, [bool]$IsLaptop)
    $board = Get-CimInstance Win32_BaseBoard

    # Regex on the maker name -> brand, key on desktops, key on laptops
    $brands = @(
        ,@('ASUS',                'ASUS',              'Del (or F2)',           'F2')
        ,@('Micro-Star|^MSI',     'MSI',               'Del',                   'Del')
        ,@('Gigabyte|AORUS',      'Gigabyte',          'Del',                   'F2')
        ,@('ASRock',              'ASRock',            'F2 or Del',             'F2')
        ,@('Biostar',             'Biostar',           'Del',                   'Del')
        ,@('EVGA',                'EVGA',              'Del',                   'Del')
        ,@('Alienware',           'Alienware',         'F2',                    'F2')
        ,@('Dell',                'Dell',              'F2',                    'F2')
        ,@('^HP|Hewlett',         'HP',                'F10 (or Esc, then F10)', 'F10 (or Esc, then F10)')
        ,@('Lenovo',              'Lenovo',            'F1 or F2',              'F2 (or the small Novo button next to the power button)')
        ,@('Acer',                'Acer',              'F2 (or Del)',           'F2')
        ,@('Samsung',             'Samsung',           'F2',                    'F2')
        ,@('Toshiba|Dynabook',    'Toshiba / Dynabook','F2',                    'F2')
        ,@('Fujitsu',             'Fujitsu',           'F2',                    'F2')
        ,@('Framework',           'Framework',         'F2',                    'F2')
        ,@('Microsoft',           'Microsoft Surface', $null,                   $null)
    )

    foreach ($maker in $ComputerSystem.Manufacturer, $board.Manufacturer) {
        foreach ($b in $brands) {
            if ($maker -notmatch $b[0]) { continue }
            $key = if ($IsLaptop) { $b[3] } else { $b[2] }

            if ($b[1] -eq 'Lenovo' -and "$($ComputerSystem.SystemFamily) $($ComputerSystem.Model)" -match 'Think') {
                $key = 'F1'   # ThinkPad, ThinkCentre, ThinkStation
            }
            if ($b[1] -eq 'Microsoft Surface') {
                if ("$($ComputerSystem.Model)" -notmatch 'Surface') { continue }   # Hyper-V also says "Microsoft"
                return [pscustomobject]@{ Brand = $b[1]; Key = $null
                    How = 'Turn the Surface off. Hold the Volume Up button, press and release Power, and keep holding Volume Up until the Surface logo goes away.' }
            }
            return [pscustomobject]@{ Brand = $b[1]; Key = $key; How = $null }
        }
    }
    $null
}

function Test-System {
    Write-Section 'Your PC'
    $cs   = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $os   = Get-CimInstance Win32_OperatingSystem
    $cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
    $board = Get-CimInstance Win32_BaseBoard
    Write-Item 'Model' ("$($cs.Manufacturer) $($cs.Model)".Trim())
    if ($board.Manufacturer -and "$($cs.Manufacturer)" -notmatch [regex]::Escape("$($board.Manufacturer)".Split(' ')[0])) {
        Write-Item 'Motherboard' ("$($board.Manufacturer) $($board.Product)".Trim())
    }
    Write-Item 'Firmware' ("$($bios.Manufacturer) $($bios.SMBIOSBIOSVersion)".Trim())
    Write-Item 'CPU' ("$($cpu.Name)".Trim())
    Write-Item 'Windows' "$($os.Caption -replace '^Microsoft ', '') (build $($os.BuildNumber))"

    $model = "$($cs.Manufacturer) $($cs.Model)"
    $vm = switch -Regex ($model) {
        'Microsoft Corporation Virtual' { 'Hyper-V'; break }
        'VMware'                        { 'VMware'; break }
        'VirtualBox|innotek'            { 'VirtualBox'; break }
        'QEMU|KVM'                      { 'QEMU/KVM'; break }
        'Parallels'                     { 'Parallels'; break }
    }
    if ($vm) { Write-Item 'Virtual machine' $vm }

    $isLaptop = Test-IsLaptop
    [pscustomobject]@{
        Vm        = $vm
        IsLaptop  = $isLaptop
        CpuVendor = switch -Wildcard ($cpu.Manufacturer) { 'AuthenticAMD' { 'AMD' } 'GenuineIntel' { 'Intel' } default { 'Other' } }
        IsWin11   = [int]$os.BuildNumber -ge 22000
        Bios      = if (-not $vm) { Get-BiosKey -ComputerSystem $cs -IsLaptop $isLaptop }
    }
}

function Test-BootMode {
    param([string]$Vm)
    Write-Section 'Boot mode'
    $firmware = Get-FirmwareType
    if ($firmware -eq 'UEFI') {
        Write-Item 'Firmware boot mode' 'UEFI' 'Ok'
        return $firmware
    }

    Write-Item 'Firmware boot mode' "$firmware (Secure Boot needs UEFI)" 'Fail'
    if ($Vm -eq 'Hyper-V') {
        Add-Problem -Area BootMode 'This is a Generation 1 Hyper-V virtual machine. Those boot with a legacy BIOS and can never use Secure Boot.' @(
            'Create a new Generation 2 virtual machine and install Windows in it (a VM cannot be converted from Gen 1 to Gen 2).'
        )
    } elseif ($Vm) {
        Add-Problem -Area BootMode "The $Vm virtual machine is set to boot with a legacy BIOS." @(
            'Shut down the VM and switch its firmware to EFI / UEFI in the VM settings, then turn on Secure Boot there.',
            'The virtual disk must use GPT first - if it uses MBR, that step is listed before this one.'
        )
    } else {
        Add-Problem -Area BootMode 'Windows was started in Legacy BIOS / CSM mode. Secure Boot only exists in UEFI mode, so it cannot be turned on yet.' @(
            'If the Windows disk still uses MBR, convert it to GPT first (that step is listed before this one) - otherwise Windows will not start in UEFI mode.',
            'In the BIOS/UEFI setup: set Boot mode to "UEFI" (not "Legacy" or "UEFI and Legacy") and disable CSM / Compatibility Support Module.',
            'Then enable Secure Boot (on some boards: set "OS Type" to "Windows UEFI mode", or Secure Boot mode to "Standard").',
            'Very old graphics cards (around 2012 and older) have no UEFI support and show a black screen without CSM. Use the integrated graphics or a newer card in that case.'
        )
    }
    $firmware
}

function Test-BootDisk {
    param([string]$Firmware)
    Write-Section 'Windows disk'
    try {
        $partition = Get-Partition -DriveLetter $env:SystemDrive[0] -ErrorAction Stop
        $disk = Get-Disk -Number $partition.DiskNumber -ErrorAction Stop
    } catch {
        Write-Item 'Partition style' 'could not be read' 'Warn'
        return
    }
    Write-Item 'Disk' "#$($disk.Number) $($disk.FriendlyName)"

    if ($disk.PartitionStyle -eq 'GPT') {
        Write-Item 'Partition style' 'GPT' 'Ok'
        return
    }

    $status = if ($Firmware -eq 'UEFI') { 'Warn' } else { 'Fail' }
    Write-Item 'Partition style' "$($disk.PartitionStyle) (UEFI needs GPT)" $status
    if ($Firmware -eq 'UEFI') { return }   # booted fine anyway, nothing to fix

    # MBR2GPT can convert the disk without reinstalling. /validate only checks, it changes nothing.
    $mbr2gpt = Join-Path $env:windir 'System32\mbr2gpt.exe'
    if (-not (Test-Path $mbr2gpt)) {
        Write-Item 'Convert without reinstall' 'MBR2GPT not available on this Windows' 'Warn'
        Add-Problem -Area Disk 'The Windows disk uses MBR. UEFI (and so Secure Boot) needs a GPT disk.' @(
            'Update Windows (MBR2GPT ships with Windows 10 1703 and later), or back up and reinstall Windows in UEFI mode.'
        )
        return
    }

    $output = & $mbr2gpt /validate /allowFullOS /disk:$($disk.Number) 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        Write-Item 'Convert without reinstall' 'possible (MBR2GPT check passed)' 'Ok'
        $script:NeedsConversion = $true
        Add-Problem -Area Disk 'The Windows disk uses MBR. UEFI (and so Secure Boot) needs a GPT disk.' @(
            'First read "Before you change anything" above: back up your files and take care of BitLocker.',
            "Convert the disk (takes a minute, designed to keep all files):  mbr2gpt /convert /allowFullOS /disk:$($disk.Number)",
            'Immediately afterwards switch the BIOS to UEFI mode - after the conversion Windows no longer starts in Legacy mode.'
        )
    } else {
        $reason = ($output -split "`r?`n" | Where-Object { $_ -match 'fail|error|cannot|unable|not ' } | Select-Object -First 3) -join ' '
        if (-not $reason) { $reason = "exit code $LASTEXITCODE" }
        Write-Item 'Convert without reinstall' 'not possible' 'Fail'
        Write-Item '  MBR2GPT says' $reason
        Add-Problem -Area Disk "The Windows disk uses MBR and MBR2GPT cannot convert it: $reason" @(
            'Most common causes: more than 3 primary partitions, no free space for the EFI partition, or a non-Windows partition layout.',
            'Details are in C:\Windows\setupact.log and setuperr.log.',
            'If it cannot be fixed: back up your files and reinstall Windows with the USB stick booted in UEFI mode.'
        )
    }
}

function Test-SecureBootState {
    Write-Section 'Secure Boot'
    $enabled = $null
    try {
        $enabled = Confirm-SecureBootUEFI -ErrorAction Stop
    } catch [System.PlatformNotSupportedException] {
        Write-Item 'Secure Boot' 'not supported on this boot mode' 'Fail'
        return $false
    } catch {
        Write-Item 'Secure Boot' "could not be read: $($_.Exception.Message)" 'Warn'
    }
    $reg = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction SilentlyContinue).UEFISecureBootEnabled
    if ($null -eq $enabled -and $null -ne $reg) { $enabled = $reg -eq 1 }

    if ($enabled) { Write-Item 'Secure Boot' 'ON' 'Ok' } else { Write-Item 'Secure Boot' 'OFF' 'Fail' }
    [bool]$enabled
}

function Test-FirmwareKeys {
    param([bool]$Enabled, [string]$Vm)

    $setupMode    = Get-UefiFlag 'SetupMode'
    $secureBoot   = Get-UefiFlag 'SecureBoot'
    $auditMode    = Get-UefiFlag 'AuditMode'
    $deployedMode = Get-UefiFlag 'DeployedMode'

    $pkBytes  = Get-UefiVariable 'PK'
    $pk  = @(if ($pkBytes)  { Get-SignatureCertificates $pkBytes })
    $kek = @(Get-SignatureCertificates (Get-UefiVariable 'KEK'))
    $db  = @(Get-SignatureCertificates (Get-UefiVariable 'db'))
    $dbx = Get-UefiVariable 'dbx'

    # ---- Mode -----------------------------------------------------
    $modeText = if ($setupMode -eq 1) { 'Setup mode (no Platform Key)' }
                elseif ($auditMode -eq 1) { 'Audit mode' }
                elseif ($deployedMode -eq 1) { 'Deployed mode' }
                elseif ($setupMode -eq 0) { 'User mode' }
                else { 'unknown' }
    Write-Item 'Firmware key mode' $modeText $(if ($setupMode -eq 1 -or $auditMode -eq 1) { 'Fail' } else { 'Info' })

    # ---- Platform Key ---------------------------------------------
    Write-Section 'Secure Boot keys'
    if (-not $pkBytes) {
        Write-Item 'Platform Key (PK)' 'missing' 'Fail'
    } elseif ($pk.Count) {
        $pkName = Get-CommonName $pk[0]
        if ($pkName -match 'DO NOT TRUST|DO NOT SHIP|\bTest\b') {
            Write-Item 'Platform Key (PK)' "$pkName  (test key!)" 'Warn'
            Add-Warning "The firmware uses a public test Platform Key (`"$pkName`"). Its private key is public, so anyone can bypass Secure Boot on this PC (known as PKfail)." @(
                'Install the latest BIOS/UEFI update from the PC or motherboard maker - fixed firmware ships a real key.'
            )
        } else {
            Write-Item 'Platform Key (PK)' $pkName 'Ok'
        }
    } else {
        Write-Item 'Platform Key (PK)' 'present' 'Ok'
    }

    # ---- KEK and db: the Microsoft certificates Windows relies on ---
    $kekNames = $kek | ForEach-Object { Get-CommonName $_ }
    $dbNames  = $db  | ForEach-Object { Get-CommonName $_ }

    $kek2011 = $kekNames -match 'Microsoft Corporation KEK CA 2011'
    $kek2023 = $kekNames -match 'KEK 2K CA 2023|KEK CA 2023'
    $win2011 = $dbNames -match 'Windows Production PCA 2011'
    $win2023 = $dbNames -match 'Windows UEFI CA 2023'
    $uefi2011 = $dbNames -match 'Microsoft Corporation UEFI CA 2011'
    $uefi2023 = $dbNames -match 'Microsoft UEFI CA 2023|Microsoft Option ROM UEFI CA 2023'

    $kekStatus = if ($kek2011 -or $kek2023) { 'Ok' } else { 'Fail' }
    Write-Item 'Microsoft KEK' $(if ($kek2023) { '2023 key' } elseif ($kek2011) { '2011 key only' } else { 'missing' }) $kekStatus

    $winStatus = if ($win2011 -or $win2023) { 'Ok' } else { 'Fail' }
    Write-Item 'Windows boot certificate' $(if ($win2023 -and $win2011) { '2011 + 2023' } elseif ($win2023) { '2023' } elseif ($win2011) { '2011 only' } else { 'missing' }) $winStatus

    $thirdStatus = if ($uefi2011 -or $uefi2023) { 'Ok' } else { 'Warn' }
    Write-Item 'Third-party UEFI cert.' $(if ($uefi2011 -or $uefi2023) { 'present' } else { 'missing' }) $thirdStatus

    Write-Item 'Revocation list (dbx)' $(if ($dbx) { "present ($($dbx.Length) bytes)" } else { 'empty' }) $(if ($dbx) { 'Ok' } else { 'Warn' })

    $otherKeys = @($kekNames | Where-Object { $_ -notmatch 'Microsoft' })
    foreach ($name in $otherKeys) { Write-Item 'Other KEK' $name }

    # ---- Work out why it's off --------------------------------------
    if (-not $Enabled) {
        if ($setupMode -eq 1 -or -not $pkBytes) {
            $steps = @(
                'In the BIOS/UEFI setup, open the Secure Boot page and choose "Restore Factory Keys" or "Install default Secure Boot keys".',
                'On some boards you first need to set Secure Boot mode to "Custom" to see that option, then back to "Standard".'
            )
            if ($Vm) { $steps += "In $Vm`: turn Secure Boot off and on again in the VM settings, or pick the Microsoft Windows Secure Boot template." }
            Add-Problem -Area SecureBoot 'The Secure Boot keys have been cleared (the firmware is in Setup mode, no Platform Key is installed). Secure Boot cannot switch on without keys.' $steps
        } elseif ($auditMode -eq 1) {
            Add-Problem -Area SecureBoot 'The firmware is in Audit mode: it checks signatures but does not enforce them.' @(
                'In the BIOS/UEFI setup, leave Audit mode (or restore the factory Secure Boot keys) and enable Secure Boot.'
            )
        } elseif (-not ($win2011 -or $win2023)) {
            Add-Problem -Area SecureBoot 'The firmware key database (db) does not contain the Microsoft Windows certificate, so the Windows boot manager would be blocked. Someone installed custom keys.' @(
                'In the BIOS/UEFI setup, choose "Restore Factory Keys" / "Install default Secure Boot keys", then enable Secure Boot.'
            )
        } elseif ($setupMode -eq 0 -and $secureBoot -eq 0) {
            $steps = @('The keys are installed correctly - Secure Boot is simply switched off. In the BIOS/UEFI setup, open the Secure Boot page and set it to "Enabled".')
            if (-not $Vm) {
                $steps += 'If the option is grey: disable CSM first, or set "OS Type" to "Windows UEFI mode" (ASUS) / Secure Boot mode to "Standard" (MSI, Gigabyte).'
                $steps += 'The change only counts after "Save & Exit" and a restart - run this check again afterwards.'
            } else {
                $steps += "Shut down the VM and enable Secure Boot in the $Vm VM settings."
            }
            Add-Problem -Area SecureBoot 'Secure Boot is turned off in the BIOS/UEFI settings.' $steps
        } else {
            Add-Problem -Area SecureBoot 'Secure Boot is off, but the firmware does not report why.' @(
                'In the BIOS/UEFI setup: restore the factory Secure Boot keys, disable CSM and enable Secure Boot.',
                'If that does not help, update the BIOS/UEFI firmware from the PC or motherboard maker.'
            )
        }

        if (-not ($uefi2011 -or $uefi2023) -and -not $Vm) {
            Add-Warning 'The "Microsoft UEFI CA" certificate is missing. Graphics cards and network cards sign their firmware with it - with Secure Boot on, they may show a black screen or not work.' @(
                'Restore the factory Secure Boot keys in the BIOS/UEFI setup; they include this certificate.'
            )
        }
    }

    # ---- Certificate update (the 2011 certificates expire in 2026) ---
    if (($win2011 -or $kek2011) -and -not ($win2023 -and $kek2023)) {
        $servicing = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing' -ErrorAction SilentlyContinue
        $state = if ($servicing.UEFICA2023Status) { " (Windows status: $($servicing.UEFICA2023Status))" } else { '' }
        Write-Item '2023 certificate update' "not installed yet$state" 'Warn'
        Add-Warning "The firmware still only has Microsoft's 2011 Secure Boot certificates, which expire in 2026. Secure Boot keeps working, but this PC cannot receive new boot security fixes until the 2023 certificates are added.$state" @(
            'Install all Windows updates and reboot twice - Windows adds the 2023 certificates automatically.',
            'If it stays stuck, install the latest BIOS/UEFI update from the PC or motherboard maker.'
        )
    } elseif ($win2023 -and $kek2023) {
        Write-Item '2023 certificate update' 'installed' 'Ok'
    }
}

function Test-Tpm {
    # Many anti-cheats require TPM 2.0 as well as Secure Boot. Returns $true when it is usable.
    param($Pc)
    Write-Section 'TPM 2.0 (security chip)'

    # The BIOS calls the TPM built into the CPU by different names
    $chipName = switch ($Pc.CpuVendor) {
        'AMD'   { 'AMD fTPM (may be called "AMD CPU fTPM" or "Firmware TPM")' }
        'Intel' { 'Intel PTT (Platform Trust Technology, may be called "Firmware TPM")' }
        default { 'the TPM (may be called "Security Device Support" or "Trusted Computing")' }
    }

    $wmi = $null; $tpm = $null; $readErrors = 0
    try { $wmi = Get-CimInstance -Namespace 'root\cimv2\Security\MicrosoftTpm' -ClassName Win32_Tpm -ErrorAction Stop } catch { $readErrors++ }
    try { $tpm = Get-Tpm -ErrorAction Stop } catch { $readErrors++ }

    # Both ways failing (e.g. access denied) says nothing about the TPM - don't guess
    if ($readErrors -eq 2) {
        Write-Item 'TPM' 'could not be read - run this check as admin' 'Warn'
        Add-Problem -Area ReadError 'The TPM status could not be read, so this check cannot tell whether it is set up.' @(
            'Close this window, start "Check Secure Boot.cmd" again and click "Yes" on the admin prompt.'
        )
        return $false
    }

    if (-not (($tpm -and $tpm.TpmPresent) -or $wmi)) {
        Write-Item 'TPM' 'not found' 'Fail'
        if ($Pc.Vm -eq 'Hyper-V') {
            Add-Problem -Area Tpm 'This virtual machine has no TPM.' @(
                'Shut down the VM, open its Settings -> Security and tick "Enable Trusted Platform Module" (Generation 2 VMs only).'
            )
        } elseif ($Pc.Vm) {
            Add-Problem -Area Tpm 'This virtual machine has no TPM.' @(
                "Shut down the VM and add a virtual TPM (vTPM) in the $($Pc.Vm) VM settings."
            )
        } else {
            Add-Problem -Area Tpm 'No TPM was found. It is either switched off in the BIOS, or this PC has none.' @(
                "In the BIOS/UEFI setup turn on $chipName. It is usually on the Security, Advanced or Trusted Computing page.",
                'Most Intel and AMD processors from the last several years have a TPM 2.0 built in - it only needs to be switched on.',
                'Older PCs without one need a TPM 2.0 module that plugs into the motherboard (check the motherboard manual for a "TPM" connector).'
            )
        }
        return $false
    }

    $spec = if ($wmi.SpecVersion) { ("$($wmi.SpecVersion)" -split ',')[0].Trim() } else { $null }
    $specStatus = if ($spec -eq '2.0') { 'Ok' } elseif ($spec) { 'Fail' } else { 'Warn' }
    Write-Item 'TPM version' $(if ($spec) { $spec } else { 'unknown' }) $specStatus
    if ($tpm.ManufacturerIdTxt) { Write-Item 'TPM maker' ("$($tpm.ManufacturerIdTxt) $($tpm.ManufacturerVersion)".Trim()) }

    if ($spec -and $spec -ne '2.0') {
        Add-Problem -Area Tpm "This PC has an older TPM $spec. Games that require a TPM need version 2.0." @(
            "If your BIOS offers $chipName, switch to it: look for `"TPM Device Selection`" and choose Firmware TPM / PTT / fTPM instead of Discrete TPM.",
            'Some Dell, HP and Lenovo PCs can update their TPM from 1.2 to 2.0 with a tool from the PC maker - check the support page for your model.'
        )
        return $false
    }

    $enabled   = if ($null -ne $tpm.TpmEnabled)   { $tpm.TpmEnabled }   else { $wmi.IsEnabled_InitialValue }
    $activated = if ($null -ne $tpm.TpmActivated) { $tpm.TpmActivated } else { $wmi.IsActivated_InitialValue }
    if ($enabled -eq $false -or $activated -eq $false) {
        Write-Item 'TPM status' 'switched off' 'Fail'
        Add-Problem -Area Tpm 'The TPM is there but switched off.' @(
            "In the BIOS/UEFI setup turn on $chipName. It is usually on the Security, Advanced or Trusted Computing page."
        )
        return $false
    }

    # Too many wrong PIN attempts lock the TPM for a while; it doesn't stop it
    # from counting as TPM 2.0, but Windows Hello and some keys stop working
    if ($tpm -and $tpm.LockedOut) {
        $heal = if ($tpm.LockoutHealTime) { " It unlocks by itself after about $($tpm.LockoutHealTime) with the PC switched on." } else { '' }
        Write-Item 'TPM lockout' 'locked (too many wrong PIN attempts)' 'Warn'
        Add-Warning "The TPM is temporarily locked because of too many wrong PIN or password attempts.$heal" @(
            'Leave the PC switched on (not asleep) until the lock wears off. Do not try more PINs, each wrong try can extend it.',
            'Do not use "Clear TPM" to get rid of the lock unless you have your BitLocker recovery key: clearing deletes the keys stored in the TPM.'
        )
    }

    if ($tpm -and $tpm.TpmReady -eq $false) {
        Write-Item 'TPM status' 'on, but not ready yet' 'Warn'
        Add-Warning 'The TPM is on, but Windows has not finished setting it up.' @(
            'Restart the PC and install all Windows updates - Windows sets it up by itself.',
            'Press Win+R and run tpm.msc to see what Windows reports about it.',
            'Do not use "Clear TPM" unless you have your BitLocker recovery key: clearing deletes the keys stored in the TPM.'
        )
        return $true
    }

    Write-Item 'TPM status' 'on and ready' 'Ok'
    $true
}

function Get-BitLockerState {
    <#
        Reads BitLocker / Device Encryption for the Windows drive. Returns
        $null if the drive isn't encrypted or the state can't be read.
        Device Encryption is often switched on automatically on Windows Home
        when you sign in with a Microsoft account, so many players don't know they have it.
    #>
    try {
        $v = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        $types = @($v.KeyProtector | ForEach-Object { "$($_.KeyProtectorType)" })
        return [pscustomobject]@{
            Encrypted   = "$($v.VolumeStatus)" -ne 'FullyDecrypted'
            Protected   = "$($v.ProtectionStatus)" -eq 'On'
            Percent     = [int]$v.EncryptionPercentage
            HasRecovery = $types -contains 'RecoveryPassword'
        }
    } catch { }

    # Fallback for systems without the BitLocker PowerShell module
    try {
        $v = Get-CimInstance -Namespace 'root\cimv2\security\microsoftvolumeencryption' -ClassName Win32_EncryptableVolume `
            -Filter "DriveLetter='$env:SystemDrive'" -ErrorAction Stop
        if (-not $v) { return $null }
        $keys = Invoke-CimMethod -InputObject $v -MethodName GetKeyProtectors -Arguments @{ KeyProtectorType = [uint32]3 } -ErrorAction Stop
        $pct  = Invoke-CimMethod -InputObject $v -MethodName GetConversionStatus -ErrorAction Stop
        return [pscustomobject]@{
            Encrypted   = $v.ConversionStatus -ne 0
            Protected   = $v.ProtectionStatus -eq 1
            Percent     = [int]$pct.EncryptionPercentage
            HasRecovery = @($keys.VolumeKeyProtectorID).Count -gt 0
        }
    } catch { }
    $null
}

function Test-BitLocker {
    # Firmware changes make BitLocker ask for the recovery key - warn before the user goes into the BIOS
    Write-Section 'Drive encryption (BitLocker)'
    $state = Get-BitLockerState
    $script:BitLocker = $state
    if (-not $state -or -not $state.Encrypted) {
        Write-Item "Drive $env:SystemDrive" 'not encrypted' 'Ok'
        return
    }
    if ($state.Protected) {
        Write-Item "Drive $env:SystemDrive" "encrypted, protection on ($($state.Percent)%)" 'Info'
    } else {
        Write-Item "Drive $env:SystemDrive" "encrypted, protection suspended ($($state.Percent)%)" 'Info'
    }
    if ($state.HasRecovery) {
        Write-Item 'Recovery key' 'exists' 'Ok'
    } else {
        Write-Item 'Recovery key' 'NONE - a recovery screen would lock you out' 'Fail'
    }
}

function Show-DataSafety {
    # Shown before the fixes: what each fix can do to the player's files, and how to stay safe
    $bl = $script:BitLocker
    $blActive = $bl -and $bl.Encrypted
    if (-not ($blActive -or $script:NeedsConversion)) { return }

    $drive = $env:SystemDrive
    Write-Host ''
    Write-Host '  BEFORE YOU CHANGE ANYTHING - protect your files' -ForegroundColor Yellow
    Write-Host '  ----------------------------------------------' -ForegroundColor Yellow

    if ($blActive) {
        Write-Host ''
        Write-Host "  Your Windows drive ($drive) is encrypted with BitLocker / Device Encryption." -ForegroundColor Yellow
        Write-Host '  Changing Secure Boot, CSM, boot mode, TPM settings or the disk layout makes Windows ask for the'
        Write-Host '  48-digit BitLocker recovery key at the next start. Without that key, everything on'
        Write-Host '  the drive is lost for good - nobody, not even Microsoft, can unlock it.'
        if (-not $bl.HasRecovery) {
            Write-Host ''
            Write-Host '  !! This drive has NO recovery key. Do not change any BIOS setting until you add one:' -ForegroundColor Red
            Write-Host "     - Add a key (admin PowerShell):  manage-bde -protectors -add $drive -RecoveryPassword" -ForegroundColor Red
        }
        Write-Host ''
        Write-Host '  To stay safe:'
        Write-Host "     - Show your recovery key now:  manage-bde -protectors -get $drive"
        Write-Host '       Write the 48-digit "Numerical Password" down or photograph it with your phone.'
        Write-Host '       If you sign in with a Microsoft account it may also be at aka.ms/myrecoverykey.'
        if ($bl.Protected) {
            Write-Host "     - Then pause BitLocker:  manage-bde -protectors -disable $drive -RebootCount 2"
            Write-Host '       Your files stay encrypted; it only stops the key prompt and turns itself back'
            Write-Host '       on after 2 restarts. Do your BIOS changes within those 2 restarts.'
        } else {
            Write-Host '     - BitLocker is already paused, but it turns back on by itself after a restart.'
            Write-Host '       Keep the recovery key at hand anyway.'
        }
        if ($bl.Percent -lt 100) {
            Write-Host "     - Encryption is still running ($($bl.Percent)%). Let it finish before you change anything." -ForegroundColor Yellow
        }
    }

    if ($script:NeedsConversion) {
        Write-Host ''
        Write-Host '  About converting the disk (mbr2gpt /convert):' -ForegroundColor Yellow
        Write-Host '     - It is built to keep all your files, but it rewrites the layout of the disk. A power cut,'
        Write-Host '       crash or forced shutdown while it runs can leave Windows unable to start.'
        Write-Host '     - Back up anything you cannot re-download first (game saves, screenshots, documents,'
        Write-Host '       photos) to a USB drive or cloud storage.'
        Write-Host '     - On a laptop, plug in the charger. Close all programs and do not turn the PC off while it runs.'
        Write-Host '     - Right after converting, Windows ONLY starts in UEFI mode. If you see "no bootable device",'
        Write-Host '       your files are fine - switch the BIOS to UEFI mode. Switching back to Legacy will not work.'
        Write-Host '     - If Linux or another system is installed on the same disk, it may stop starting.'
        Write-Host '     - Do not use third-party "convert MBR to GPT" tools; mbr2gpt is the one built into Windows.'
    }
}

function Show-BiosAccess {
    # How to get into the BIOS/UEFI setup, where almost every fix is made
    param($Pc, [string]$Firmware)
    if ($Pc.Vm) { return }   # VM fixes are made in the VM settings
    Write-Host ''
    Write-Host '  HOW TO OPEN THE BIOS/UEFI SETUP' -ForegroundColor Cyan
    Write-Host '  -------------------------------' -ForegroundColor Cyan
    $b = $Pc.Bios
    if ($b -and $b.How) {
        Write-Host "     - $($b.Brand): $($b.How)"
    } elseif ($b) {
        Write-Host "     - $($b.Brand) PC or motherboard: turn it on and keep pressing $($b.Key) until the setup screen opens."
    } else {
        Write-Host '     - Turn the PC on and keep pressing Del or F2 (some PCs use F1, F10 or Esc).'
        Write-Host '       The right key is often shown for a moment on the start screen.'
    }
    if ($Firmware -eq 'UEFI') {
        $path = if ($Pc.IsWin11) { 'Settings -> System -> Recovery -> Advanced startup' } else { 'Settings -> Update & Security -> Recovery -> Advanced startup' }
        Write-Host "     - Or from Windows: $path -> Restart now,"
        Write-Host '       then Troubleshoot -> Advanced options -> UEFI Firmware Settings -> Restart.'
    }
    Write-Host '     - If Windows starts too fast to press the key: hold Shift while clicking Shut down, then try again.'
    Write-Host '     - Changes only count after you choose "Save & Exit" (often F10).'
}

# ------------------------------------------------------------------
#  Run
# ------------------------------------------------------------------

Clear-Host
Write-Host " Secure Boot & TPM 2.0 check  v$script:Version" -ForegroundColor White
Write-Host ''
Write-Host ' +----------------------------------------------------------------+' -ForegroundColor Green
Write-Host ' |  THIS TOOL MAKES NO CHANGES TO YOUR PC.                        |' -ForegroundColor Green
Write-Host ' |  It only reads your settings. It does not change BIOS settings, |' -ForegroundColor Green
Write-Host ' |  files, disks, BitLocker or the TPM, and it never restarts.     |' -ForegroundColor Green
Write-Host ' |  Any fix it shows is for you to decide on and do yourself.      |' -ForegroundColor Green
Write-Host ' +----------------------------------------------------------------+' -ForegroundColor Green

$pc       = Test-System
$firmware = Test-BootMode -Vm $pc.Vm
Test-BootDisk -Firmware $firmware
$enabled  = $false
$keysChecked = $firmware -eq 'UEFI'
if ($keysChecked) {
    $enabled = Test-SecureBootState
    Test-FirmwareKeys -Enabled $enabled -Vm $pc.Vm
} else {
    # The Secure Boot settings don't exist in Legacy mode, so they can only be checked after the switch to UEFI
    Write-Section 'Secure Boot'
    Write-Item 'Secure Boot' 'OFF (not available in Legacy mode)' 'Fail'
    Write-Item 'Secure Boot keys' 'can only be checked once Windows starts in UEFI mode' 'Warn'
}
$tpmOk = Test-Tpm -Pc $pc
Test-BitLocker

Write-Section 'Result'
Write-Item 'Secure Boot' $(if ($enabled) { 'ON' } else { 'OFF' }) $(if ($enabled) { 'Ok' } else { 'Fail' })
Write-Item 'TPM 2.0' $(if ($tpmOk) { 'ready' } else { 'not ready' }) $(if ($tpmOk) { 'Ok' } else { 'Fail' })
Write-Host ''
if ($enabled -and $tpmOk -and -not $script:Problems.Count) {
    Write-Host '  Secure Boot and TPM 2.0 are set up properly - games that require them should run.' -ForegroundColor Green
} else {
    $count = $script:Problems.Count
    Write-Host "  $count thing$(if ($count -ne 1) { 's' }) to fix before games that require Secure Boot / TPM 2.0 will run." -ForegroundColor Red
    Show-DataSafety
    Show-BiosAccess -Pc $pc -Firmware $firmware
    Write-Host ''
    Write-Host '  WHY, AND HOW TO FIX IT  (do the steps in this order)' -ForegroundColor Red
    Write-Host '  ----------------------------------------------------' -ForegroundColor Red
    Write-Host '  These are instructions for you. This tool has not run any of these commands' -ForegroundColor DarkGray
    Write-Host '  or changed any setting - nothing happens unless you do it yourself.' -ForegroundColor DarkGray
}

$n = 0
foreach ($problem in $script:Problems | Sort-Object Order, Index) {
    $n++
    Write-Host ''
    Write-Host "  Step $n. $($problem.Cause)" -ForegroundColor Red
    foreach ($step in $problem.Fix) { Write-Host "     - $step" }
}

if ($script:Problems.Count) {
    Write-Host ''
    if (-not $keysChecked) {
        Write-Host '  After these steps, run this check again. Some Secure Boot settings can only be' -ForegroundColor Cyan
        Write-Host '  checked once Windows starts in UEFI mode, so more steps may show up then.' -ForegroundColor Cyan
    } else {
        Write-Host '  After these steps, run this check again to confirm everything is fixed.' -ForegroundColor Cyan
    }
}

foreach ($warning in $script:Warnings) {
    Write-Host ''
    Write-Host "  Note: $($warning.Cause)" -ForegroundColor Yellow
    foreach ($step in $warning.Fix) { Write-Host "     - $step" }
}

Write-Host ''
Write-Host '  Check finished. Nothing on your PC was changed.' -ForegroundColor Green
Write-Host ''
if (-not $NoPause) { Read-Host 'Press Enter to close' | Out-Null }
