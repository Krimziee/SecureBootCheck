<#
    The Secure Boot tab in Krimz's Toolkit. The toolkit loads this file in its
    own private module and calls the functions below. The page is the same one
    the standalone window shows (ui\Page.xaml, built by Ui.ps1), and it only reads.
#>

. (Join-Path $PSScriptRoot 'Ui.ps1')

function New-ToolPage {
    param([string]$Root, [hashtable]$Shell)
    # The version is the one in SecureBootCheck.ps1 (read from the file, nothing is run)
    $version = if ((Get-Content (Join-Path $Root 'SecureBootCheck.ps1') -Raw) -match "\`$script:Version = '([^']+)'") { $Matches[1] }
    New-SecureBootPage -Root $Root -Version $version -OnBusy $Shell.SetBusy
}

# The check runs the first time the tab is opened; "Check again" runs it after that
function Enter-ToolPage { if (-not $script:SbState.Started) { Start-SecureBootCheck } }

function Close-ToolPage { Stop-SecureBootCheck }
