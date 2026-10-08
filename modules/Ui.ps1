<#
    The Secure Boot & TPM 2.0 Check window (WPF, built into Windows).

    THE WINDOW ONLY SHOWS RESULTS. The checks are the ones in
    SecureBootCheck.ps1 and only read. They run in a background runspace (a
    second PowerShell inside the same program), so the window never freezes.
    Fix steps are shown as text the player can select and copy - the window
    has no button that changes anything, and must never get one.
    Windows functions are declared in memory (not with Add-Type, which runs the
    C# compiler and writes temporary files).
#>

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:Ui      = @{}   # named controls from ui\Page.xaml
$script:SbState = @{}   # everything that changes while the page is open

$script:Glyph  = @{ Ok = [char]0xE73E; Fail = [char]0xE711; Warn = [char]0xE7BA; Info = [char]0xE946 }
$script:Colors = @{ Ok = '#6CCB5F'; Warn = '#FCE100'; Fail = '#FF99A4'; Info = '#8A8A8A'; Accent = '#4CA6FF'; Muted = '#A6A6A6'; Text = '#F3F3F3' }
$script:BadgeBack = @{ Ok = '#1F3A26'; Warn = '#3A3415'; Fail = '#3A1F22' }

# ------------------------------------------------------------------
#  Windows functions (in memory, no files)
# ------------------------------------------------------------------

function Get-NativeMethods {
    if ($script:Native) { return $script:Native }
    $assembly = [AppDomain]::CurrentDomain.DefineDynamicAssembly((New-Object Reflection.AssemblyName 'SecureBootCheckWindow'), 'Run')
    $type = $assembly.DefineDynamicModule('SecureBootCheckWindow').DefineType('WindowNative', 'Public, Class')
    $functions = @(
        @{ Dll = 'user32.dll'; Name = 'SetProcessDpiAwarenessContext'; Returns = [bool]; Parameters = @([IntPtr]) }
        @{ Dll = 'user32.dll'; Name = 'SetProcessDPIAware';            Returns = [bool]; Parameters = @() }
        @{ Dll = 'dwmapi.dll'; Name = 'DwmSetWindowAttribute';         Returns = [int];  Parameters = @([IntPtr], [int], [int].MakeByRefType(), [int]) }
    )
    foreach ($f in $functions) {
        $method = $type.DefinePInvokeMethod($f.Name, $f.Dll, 'Public, Static, PinvokeImpl', 'Standard', $f.Returns,
                                            [Type[]]$f.Parameters, 'Winapi', 'Auto')
        $method.SetImplementationFlags('PreserveSig')
    }
    $script:Native = $type.CreateType()
    $script:Native
}

function Enable-DpiAwareness {
    # Sharp text on high-resolution screens (otherwise Windows stretches the window and it looks blurry)
    try {
        $native = Get-NativeMethods
        if (-not $native::SetProcessDpiAwarenessContext([IntPtr]::new(-4))) { [void]$native::SetProcessDPIAware() }
    } catch { }
}

# ------------------------------------------------------------------
#  Small helpers
# ------------------------------------------------------------------

function Invoke-UiSafely {
    # An error inside a button or timer handler must never close the window
    param([scriptblock]$Action)
    try { & $Action }
    catch {
        [System.Windows.MessageBox]::Show("Something went wrong in the window:`n$($_.Exception.Message)", 'Secure Boot & TPM 2.0 Check', 'OK', 'Warning') | Out-Null
    }
}

function New-Text {
    param([string]$Text, [string]$Color = $script:Colors.Text, [double]$Size = 14, [string]$Weight = 'Normal', [string]$Margin = '0')
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    $t.Foreground = $Color
    $t.FontSize = $Size
    $t.FontWeight = $Weight
    $t.Margin = $Margin
    $t.TextWrapping = 'Wrap'
    $t
}

function New-Icon {
    param([string]$Glyph, [string]$Color = $script:Colors.Accent, [double]$Size = 16)
    $t = New-Text $Glyph $Color $Size
    $t.FontFamily = 'Segoe Fluent Icons, Segoe MDL2 Assets'
    $t.VerticalAlignment = 'Top'
    $t
}

function New-SelectableText {
    # Text the player can select and copy (for example a command to type themselves)
    param([string]$Text, [string]$Color = $script:Colors.Text, [double]$Size = 13.5, [string]$Weight = 'Normal', [string]$Font)
    $t = New-Object System.Windows.Controls.TextBox
    $t.Text = $Text
    $t.IsReadOnly = $true
    $t.BorderThickness = 0
    $t.Background = 'Transparent'
    $t.Foreground = $Color
    $t.FontSize = $Size
    $t.FontWeight = $Weight
    $t.TextWrapping = 'Wrap'
    $t.Padding = '0'
    $t.Margin = '-2,0,0,0'   # the box adds 2 pixels on the left; line it up with normal text
    $t.SelectionBrush = $script:Colors.Accent
    if ($Font) { $t.FontFamily = $Font }
    $t
}

function New-AdviceText {
    <#
        One line of advice. A command after two spaces ("Show your recovery key
        now:  manage-bde ...") is shown on its own line in a code box.
    #>
    param([string]$Text, [string]$Color = $script:Colors.Text, [string]$Weight = 'Normal')
    if ($Text -notmatch '^(.*?:)\s{2,}(\S.*)$') { return (New-SelectableText $Text $Color -Weight $Weight) }
    $panel = New-Object System.Windows.Controls.StackPanel
    [void]$panel.Children.Add((New-SelectableText $Matches[1] $Color -Weight $Weight))
    $code = New-Object System.Windows.Controls.Border
    $code.Background = '#1A1A1A'
    $code.BorderBrush = $script:Ui.Page.FindResource('Line')
    $code.BorderThickness = 1
    $code.CornerRadius = 5
    $code.Padding = '10,6'
    $code.Margin = '0,6,0,2'
    $code.HorizontalAlignment = 'Left'
    $code.Child = New-SelectableText $Matches[2] '#E6E6E6' 13 -Font 'Cascadia Mono, Consolas'
    $code.ToolTip = 'Select the text to copy it. This tool never runs it - only you can.'
    [void]$panel.Children.Add($code)
    $panel
}

function New-Bullet {
    param([string]$Text, [string]$Color = $script:Colors.Text, [string]$Margin = '0,4,0,0')
    $row = New-Object System.Windows.Controls.Grid
    $row.Margin = $Margin
    $row.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = '18' }))
    $row.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $dot = New-Text ([string][char]0x2022) $script:Colors.Muted 14
    $content = New-AdviceText $Text $Color
    [System.Windows.Controls.Grid]::SetColumn($content, 1)
    [void]$row.Children.Add($dot); [void]$row.Children.Add($content)
    $row
}

function New-Card {
    param([string]$Margin = '0,0,0,12', [string]$Background, [string]$BorderBrush)
    $b = New-Object System.Windows.Controls.Border
    $b.Style = $script:Ui.Page.FindResource('Card')
    $b.Margin = $Margin
    if ($Background)  { $b.Background = $Background }
    if ($BorderBrush) { $b.BorderBrush = $BorderBrush }
    $b
}

function New-Label {
    param([string]$Text, [string]$Margin = '0,6,0,8')
    $t = New-Text $Text $script:Colors.Muted 12 -Margin $Margin
    $t
}

function Get-WorstStatus {
    param($Items)
    $statuses = @($Items | ForEach-Object Status)
    foreach ($s in 'Fail', 'Warn', 'Ok') { if ($s -in $statuses) { return $s } }
    'Info'
}

# ------------------------------------------------------------------
#  Showing the results
# ------------------------------------------------------------------

function Show-PcInfo {
    param($Section)
    $panel = $script:Ui.PcInfoPanel
    $panel.Children.Clear()
    $table = New-Object System.Windows.Controls.Grid
    $table.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = '96' }))
    $table.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $row = 0
    foreach ($item in $Section.Items) {
        $table.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition))
        $name  = New-Text $item.Label $script:Colors.Muted 12.5 -Margin '0,3'
        $value = New-Text "$($item.Value)".Trim() -Size 13 -Margin '0,3'
        [System.Windows.Controls.Grid]::SetRow($name, $row); [System.Windows.Controls.Grid]::SetRow($value, $row)
        [System.Windows.Controls.Grid]::SetColumn($value, 1)
        [void]$table.Children.Add($name); [void]$table.Children.Add($value)
        $row++
    }
    [void]$panel.Children.Add($table)
}

function Show-CheckCards {
    # One card per check (Boot mode, Windows disk, ...): its worst result as the icon, then every line
    param($Sections)
    $panel = $script:Ui.ChecksPanel
    $panel.Children.Clear()
    foreach ($section in $Sections) {
        if ($section.Title -in 'Your PC', 'Result' -or -not $section.Items.Count) { continue }
        $worst = Get-WorstStatus $section.Items
        $card = New-Card '0,0,0,10'
        $stack = New-Object System.Windows.Controls.StackPanel

        $head = New-Object System.Windows.Controls.StackPanel
        $head.Orientation = 'Horizontal'
        $head.Margin = '0,0,0,6'
        $icon = New-Icon $script:Glyph[$worst] $script:Colors[$worst] 15
        $icon.Margin = '0,2,10,0'
        [void]$head.Children.Add($icon)
        [void]$head.Children.Add((New-Text $section.Title -Weight 'SemiBold'))
        [void]$stack.Children.Add($head)

        foreach ($item in $section.Items) {
            $row = New-Object System.Windows.Controls.Grid
            $row.Margin = '0,3'
            $row.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = '25' }))
            $row.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = '128' }))
            $row.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
            $mark = New-Icon $script:Glyph[$item.Status] $script:Colors[$item.Status] 11
            $mark.Margin = '2,3,0,0'
            if ($item.Status -eq 'Info') { $mark.Text = '' }
            $label = New-Text $item.Label $script:Colors.Muted 12.5
            $valueColor = if ($item.Status -in 'Warn', 'Fail') { $script:Colors[$item.Status] } else { $script:Colors.Text }
            $value = New-Text "$($item.Value)".Trim() $valueColor 12.5 -Margin '8,0,0,0'
            [System.Windows.Controls.Grid]::SetColumn($label, 1)
            [System.Windows.Controls.Grid]::SetColumn($value, 2)
            [void]$row.Children.Add($mark); [void]$row.Children.Add($label); [void]$row.Children.Add($value)
            [void]$stack.Children.Add($row)
        }
        $card.Child = $stack
        [void]$panel.Children.Add($card)
    }
}

function Show-Verdict {
    param($Result)
    $ready = $Result.SecureBootOn -and $Result.TpmOk -and -not $Result.Problems.Count
    $notes = $Result.Warnings.Count
    $count = $Result.Problems.Count

    $level = if (-not $ready) { 'Fail' } elseif ($notes) { 'Warn' } else { 'Ok' }
    $script:Ui.ResultBadge.Background = $script:BadgeBack[$level]
    $script:Ui.ResultIcon.Text = $script:Glyph[$level]
    $script:Ui.ResultIcon.Foreground = $script:Colors[$level]

    if ($ready) {
        $script:Ui.ResultTitle.Text = 'Secure Boot and TPM 2.0 are ready'
        $script:Ui.ResultSubtitle.Text = 'Games that require them should run.' +
            $(if ($notes) { " $notes note$(if ($notes -ne 1) { 's' }) below $(if ($notes -ne 1) { 'are' } else { 'is' }) worth a look." })
    } else {
        $script:Ui.ResultTitle.Text = if ($count) { "$count thing$(if ($count -ne 1) { 's' }) to fix" } else { 'Not ready yet' }
        $script:Ui.ResultSubtitle.Text = 'Games that require Secure Boot / TPM 2.0 won''t run until this is fixed. Do the steps below in order.' +
            $(if (-not $Result.KeysChecked) { ' More steps may show up once Windows starts in UEFI mode.' })
    }

    # Two chips: the two things games ask for
    $chips = $script:Ui.ChipsPanel
    $chips.Children.Clear()
    foreach ($chip in @(
        @{ Text = "Secure Boot $(if ($Result.SecureBootOn) { 'on' } else { 'off' })"; Ok = $Result.SecureBootOn }
        @{ Text = "TPM 2.0 $(if ($Result.TpmOk) { 'ready' } else { 'not ready' })";  Ok = $Result.TpmOk }
    )) {
        $status = if ($chip.Ok) { 'Ok' } else { 'Fail' }
        $border = New-Object System.Windows.Controls.Border
        $border.Background = $script:BadgeBack[$status]
        $border.CornerRadius = 12
        $border.Padding = '10,3,12,4'
        $border.Margin = '0,0,8,4'
        $line = New-Object System.Windows.Controls.StackPanel
        $line.Orientation = 'Horizontal'
        $icon = New-Icon $script:Glyph[$status] $script:Colors[$status] 11
        $icon.Margin = '0,3,7,0'
        [void]$line.Children.Add($icon)
        [void]$line.Children.Add((New-Text $chip.Text $script:Colors[$status] 13))
        $border.Child = $line
        [void]$chips.Children.Add($border)
    }
}

function Show-Advice {
    # Right column under the verdict: protect your files, how to open the BIOS, the steps, notes
    param($Result)
    $panel = $script:Ui.AdvicePanel
    $panel.Children.Clear()
    $count = $Result.Problems.Count

    if ($count -and $Result.DataSafety.Count) {
        $card = New-Card -Background '#2A2716' -BorderBrush '#5A5122'
        $stack = New-Object System.Windows.Controls.StackPanel
        $head = New-Object System.Windows.Controls.StackPanel
        $head.Orientation = 'Horizontal'
        $icon = New-Icon $script:Glyph.Warn $script:Colors.Warn 15
        $icon.Margin = '0,1,10,0'
        [void]$head.Children.Add($icon)
        [void]$head.Children.Add((New-Text 'Before you change anything - protect your files' $script:Colors.Warn 14.5 'SemiBold'))
        [void]$stack.Children.Add($head)
        foreach ($l in $Result.DataSafety) {
            $color = switch ($l.Tone) { 'Warn' { $script:Colors.Warn } 'Fail' { $script:Colors.Fail } default { $script:Colors.Text } }
            switch ($l.Kind) {
                'Heading' { [void]$stack.Children.Add((New-Text $l.Text $color 13.5 'SemiBold' '0,14,0,2')) }
                'Text'    { $t = New-AdviceText $l.Text $color; $t.Margin = '0,8,0,0'; [void]$stack.Children.Add($t) }
                'Bullet'  { [void]$stack.Children.Add((New-Bullet $l.Text $color)) }
            }
        }
        $card.Child = $stack
        [void]$panel.Children.Add($card)
    }

    if ($count -and $Result.BiosAccess.Count) {
        $card = New-Card
        $stack = New-Object System.Windows.Controls.StackPanel
        $head = New-Object System.Windows.Controls.StackPanel
        $head.Orientation = 'Horizontal'
        $icon = New-Icon ([char]0xE713) $script:Colors.Accent 15
        $icon.Margin = '0,1,10,0'
        [void]$head.Children.Add($icon)
        [void]$head.Children.Add((New-Text 'How to open the BIOS/UEFI setup' -Size 14.5 -Weight 'SemiBold'))
        [void]$stack.Children.Add($head)
        foreach ($tip in $Result.BiosAccess) { [void]$stack.Children.Add((New-Bullet $tip)) }
        $card.Child = $stack
        [void]$panel.Children.Add($card)
    }

    if ($count) {
        [void]$panel.Children.Add((New-Label 'WHY, AND HOW TO FIX IT  -  DO THE STEPS IN THIS ORDER' '0,10,0,2'))
        [void]$panel.Children.Add((New-Text 'These are instructions for you. This tool has not run any of these commands or changed any setting - nothing happens unless you do it yourself.' $script:Colors.Muted 12.5 -Margin '0,0,0,10'))
        $n = 0
        foreach ($problem in $Result.Problems) {
            $n++
            $card = New-Card
            $grid = New-Object System.Windows.Controls.Grid
            $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = 'Auto' }))
            $grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
            $number = New-Object System.Windows.Controls.Border
            $number.Width = 28; $number.Height = 28; $number.CornerRadius = 14
            $number.Background = $script:BadgeBack.Fail
            $number.VerticalAlignment = 'Top'
            $digit = New-Text "$n" $script:Colors.Fail 13.5 'SemiBold'
            $digit.HorizontalAlignment = 'Center'; $digit.VerticalAlignment = 'Center'
            $number.Child = $digit
            $stack = New-Object System.Windows.Controls.StackPanel
            $stack.Margin = '14,3,0,0'
            [void]$stack.Children.Add((New-AdviceText $problem.Cause -Weight 'SemiBold'))
            foreach ($step in $problem.Fix) { [void]$stack.Children.Add((New-Bullet $step -Margin '0,6,0,0')) }
            [System.Windows.Controls.Grid]::SetColumn($stack, 1)
            [void]$grid.Children.Add($number); [void]$grid.Children.Add($stack)
            $card.Child = $grid
            [void]$panel.Children.Add($card)
        }
        $again = if (-not $Result.KeysChecked) {
            'After these steps, run this check again. Some Secure Boot settings can only be checked once Windows starts in UEFI mode, so more steps may show up then.'
        } else {
            'After these steps, run this check again to confirm everything is fixed.'
        }
        [void]$panel.Children.Add((New-Text $again $script:Colors.Accent 13 -Margin '2,2,0,14'))
    }

    foreach ($warning in $Result.Warnings) {
        $card = New-Card
        $stack = New-Object System.Windows.Controls.StackPanel
        $head = New-Object System.Windows.Controls.Grid
        $head.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{ Width = 'Auto' }))
        $head.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
        $icon = New-Icon $script:Glyph.Warn $script:Colors.Warn 15
        $icon.Margin = '0,2,12,0'
        $cause = New-AdviceText "Note: $($warning.Cause)" -Weight 'SemiBold'
        [System.Windows.Controls.Grid]::SetColumn($cause, 1)
        [void]$head.Children.Add($icon); [void]$head.Children.Add($cause)
        [void]$stack.Children.Add($head)
        foreach ($step in $warning.Fix) { [void]$stack.Children.Add((New-Bullet $step -Margin '27,6,0,0')) }
        $card.Child = $stack
        [void]$panel.Children.Add($card)
    }

    if (-not $count -and -not $Result.Warnings.Count) {
        $card = New-Card
        $card.Child = New-Text 'Nothing to fix. If a game still says Secure Boot or TPM 2.0 is missing, restart the PC and start the game again - some games only check when they start.' $script:Colors.Muted 13.5
        [void]$panel.Children.Add($card)
    }
}

function Show-SecureBootResult {
    param($Result)
    $s = $script:SbState
    $s.Result = $Result
    $script:Ui.VersionText.Text = "v$($Result.Version)"
    Show-PcInfo ($Result.Sections | Where-Object Title -eq 'Your PC' | Select-Object -First 1)
    Show-CheckCards $Result.Sections
    Show-Verdict $Result
    Show-Advice $Result
    $script:Ui.CheckingPage.Visibility = 'Collapsed'
    $script:Ui.ResultPage.Visibility = 'Visible'
    $script:Ui.FooterText.Text = "Checked at $((Get-Date).ToString('t')). Nothing on your PC was changed."
}

function Show-CheckFailed {
    param([string]$Message)
    $script:Ui.CheckingPage.Visibility = 'Visible'
    $script:Ui.ResultPage.Visibility = 'Collapsed'
    $script:Ui.CheckingTitle.Text = 'The check could not finish'
    $script:Ui.CheckingText.Text = "$Message`nNothing on your PC was changed. Press Check again to try once more."
    $script:Ui.FooterText.Text = ''
}

# ------------------------------------------------------------------
#  Running the check in the background
# ------------------------------------------------------------------

function Set-CheckBusy {
    param([bool]$Busy)
    $script:Ui.CheckButton.IsEnabled = -not $Busy
    if ($script:SbState.OnBusy) { try { & $script:SbState.OnBusy $Busy } catch { } }
}

function Start-SecureBootCheck {
    $s = $script:SbState
    if ($s.PowerShell) { return }   # already checking
    $s.Started = $true
    $script:Ui.ResultPage.Visibility = 'Collapsed'
    $script:Ui.CheckingPage.Visibility = 'Visible'
    $script:Ui.CheckingTitle.Text = 'Checking your PC...'
    $script:Ui.CheckingText.Text = 'Reading the firmware settings, the TPM and the disk layout. This takes a few seconds and changes nothing.'
    $script:Ui.FooterText.Text = ''
    Set-CheckBusy $true

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ExecutionPolicy = 'Bypass'
    $runspace = [runspacefactory]::CreateRunspace($iss)
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript({
        param($File)
        $ErrorActionPreference = 'Continue'
        . $File -LoadOnly
        Invoke-SecureBootCheck
    }.ToString()).AddArgument($s.ScriptFile)
    $s.PowerShell = $ps
    $s.Handle = $ps.BeginInvoke()

    $s.Timer = New-Object System.Windows.Threading.DispatcherTimer
    $s.Timer.Interval = [TimeSpan]::FromMilliseconds(120)
    $s.Timer.Add_Tick({ Invoke-UiSafely { Receive-CheckResult } })
    $s.Timer.Start()
}

function Receive-CheckResult {
    $s = $script:SbState
    if (-not $s.Handle -or -not $s.Handle.IsCompleted) { return }
    $s.Timer.Stop()
    $ps = $s.PowerShell
    $result = $null; $problem = $null
    try {
        $output = $ps.EndInvoke($s.Handle)
        $result = $output | Where-Object { $_.PSObject.Properties['Sections'] } | Select-Object -Last 1
        if (-not $result) {
            $problem = @($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join ' '
            if (-not $problem) { $problem = 'The check stopped without a result.' }
        }
    } catch {
        $problem = $_.Exception.Message
    } finally {
        Stop-SecureBootCheck
    }
    if ($result) { Show-SecureBootResult $result } else { Show-CheckFailed $problem }
}

function Stop-SecureBootCheck {
    # Ends the background check (also when the window closes while it is still running)
    $s = $script:SbState
    if ($s.Timer) { $s.Timer.Stop(); $s.Timer = $null }
    if ($s.PowerShell) {
        try { if (-not $s.Handle.IsCompleted) { $s.PowerShell.Stop() } } catch { }
        try { $s.PowerShell.Runspace.Dispose(); $s.PowerShell.Dispose() } catch { }
        $s.PowerShell = $null; $s.Handle = $null
    }
    Set-CheckBusy $false
}

# ------------------------------------------------------------------
#  Page and window
# ------------------------------------------------------------------

function Import-SecureBootTheme {
    # The shared look (Theme.xaml) becomes the application's resources. Krimz's Toolkit does this itself.
    param([string]$Root)
    [xml]$xaml = Get-Content (Join-Path $Root 'ui\Theme.xaml') -Raw -Encoding UTF8
    $theme = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
    $app = [System.Windows.Application]::Current
    if (-not $app) { $app = New-Object System.Windows.Application }
    $app.ShutdownMode = 'OnExplicitShutdown'
    $app.Resources = $theme
}

function New-SecureBootPage {
    <#
        Builds the page (ui\Page.xaml). Used by the standalone window below and
        by Krimz's Toolkit (modules\Page.ps1). The check starts with
        Start-SecureBootCheck. -OnBusy is called with $true / $false around it.
    #>
    param([string]$Root, [string]$Version, [scriptblock]$OnBusy)

    [xml]$xaml = Get-Content (Join-Path $Root 'ui\Page.xaml') -Raw -Encoding UTF8
    $page = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
    $script:Ui.Page = $page
    $xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object {
        $name = $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml')
        if ($name) { $script:Ui[$name] = $page.FindName($name) }
    }
    $s = $script:SbState
    $s.ScriptFile = Join-Path $Root 'SecureBootCheck.ps1'
    $s.OnBusy = $OnBusy
    $s.Started = $false
    if ($Version) { $script:Ui.VersionText.Text = "v$Version" }

    $script:Ui.CheckButton.Add_Click({ Invoke-UiSafely { Start-SecureBootCheck } })
    $page
}

function Show-SecureBootWindow {
    # The standalone window. -NoShow builds it without opening it (used for automated screenshots)
    param([string]$Root, [string]$Version = $script:Version, [switch]$NoShow)

    Enable-DpiAwareness
    Import-SecureBootTheme $Root
    [xml]$xaml = Get-Content (Join-Path $Root 'ui\MainWindow.xaml') -Raw -Encoding UTF8
    $window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
    $script:Ui.Window = $window
    $window.Content = New-SecureBootPage -Root $Root -Version $Version

    # Dark title bar to match the window (Windows 10 2004+ / Windows 11)
    $window.Add_SourceInitialized({
        try {
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $script:Ui.Window).Handle
            $on = 1
            [void](Get-NativeMethods)::DwmSetWindowAttribute($hwnd, 20, [ref]$on, 4)
        } catch { }
    })
    $window.Add_ContentRendered({ Invoke-UiSafely { Start-SecureBootCheck } })
    $window.Add_Closing({ Stop-SecureBootCheck })

    if ($NoShow) { return $window }
    [void]$window.ShowDialog()
}
