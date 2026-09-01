if ($PSVersionTable.PSVersion.Major -ne 5) {
	$winPsPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
	if (Test-Path $winPsPath) {
		& $winPsPath -NoProfile -ExecutionPolicy Bypass -File "$PSCommandPath" @args
		exit $LASTEXITCODE
	}
	else {
		Write-Error "Windows PowerShell 5.1 не знайдено в системі."
		exit 1
	}
}

# --- Configuration Loader ---
function Get-ScriptConfiguration {
	$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
	$configPath = Join-Path $scriptDir "config.json"
	$exampleConfigPath = Join-Path $scriptDir "config.example.json"

	$targetPath = if (Test-Path $configPath) { $configPath } elseif (Test-Path $exampleConfigPath) { $exampleConfigPath } else { $null }

	if ($targetPath) {
		try {
			$rawJson = Get-Content -Path $targetPath -Raw -Encoding UTF8
			$configObj = $rawJson | ConvertFrom-Json
			Write-Host "[INFO] Loaded configuration from: $targetPath"
			return $configObj
		}
		catch {
			Write-Warning "[WARN] Failed to parse configuration JSON: $_"
		}
	}
	else {
		Write-Warning "[WARN] No config.json or config.example.json found at $scriptDir. Using default fallback configuration."
	}

	# Default fallback configuration
	return [PSCustomObject]@{
		Settings = [PSCustomObject]@{
			InitialStartupDelaySeconds   = 15
			BatteryPrePopupDelaySeconds  = 20
			BatteryPopupCountdownSeconds = 60
			SnoozeDurationMinutes        = 5
			ManageBluetooth              = $true
			ManageVisualEffects          = $true
			ShowToastNotifications       = $true
			LogPath                      = "%TEMP%\SmartStartup_log.txt"
		}
		AcMode = [PSCustomObject]@{
			AppsToLaunch = @()
		}
		BatteryMode = [PSCustomObject]@{
			ProcessesToClose            = @()
			GracefulCloseTimeoutSeconds = 3
		}
	}
}

$global:config = Get-ScriptConfiguration

$logPathRaw = if ($global:config.Settings.LogPath) { $global:config.Settings.LogPath } else { "%TEMP%\SmartStartup_log.txt" }
$logPath = [System.Environment]::ExpandEnvironmentVariables($logPathRaw)

if (Test-Path $logPath) {
	if ((Get-Item $logPath).Length -gt 5MB) {
		Remove-Item $logPath -Force
	}
}
Start-Transcript -Path $logPath -Append

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$Win32API = @'
using System;
using System.Runtime.InteropServices;
public class User32 {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfo(int uiAction, int uiParam, bool pvParam, int fWinIni);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
'@
Add-Type -TypeDefinition $Win32API

function Set-WindowsVisuals {
	param([bool]$Enable)
	if ($global:config.Settings.ManageVisualEffects -eq $false) { return }
	$minAnimate = if ($Enable) { "1" } else { "0" }
	Set-ItemProperty -Path "HKCU:\Control Panel\Desktop\WindowMetrics" -Name "MinAnimate" -Value $minAnimate
	$transparency = if ($Enable) { 1 } else { 0 }
	Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "EnableTransparency" -Value $transparency
	[User32]::SystemParametersInfo(0x1043, 0, $Enable, 3) | Out-Null
}

function Set-BluetoothState {
	param([string]$TargetState)
	if ($global:config.Settings.ManageBluetooth -eq $false) { return }
	try {
		Add-Type -AssemblyName System.Runtime.WindowsRuntime
		$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
        
		function AwaitWinRT($WinRtTask, $ResultType) {
			$asTask = $asTaskGeneric.MakeGenericMethod($ResultType)
			$netTask = $asTask.Invoke($null, @($WinRtTask))
			$netTask.Wait(-1) | Out-Null
			return $netTask.Result
		}
        
		[Windows.Devices.Radios.Radio, Windows.System.Devices, ContentType = WindowsRuntime] | Out-Null
		$radios = AwaitWinRT ([Windows.Devices.Radios.Radio]::GetRadiosAsync()) ([System.Collections.Generic.IReadOnlyList[Windows.Devices.Radios.Radio]])
        
		$bt = $radios | Where-Object { $_.Kind -eq 'Bluetooth' }
		if ($bt) {
			$targetStateInt = if ($TargetState -eq 'On') { 1 } else { 2 }
			if ([int]$bt.State -ne $targetStateInt) {
				AwaitWinRT ($bt.SetStateAsync($targetStateInt)) ([Windows.Devices.Radios.RadioAccessStatus]) | Out-Null
			}
		}
	}
	catch {
		Write-Host "[ERROR] $(Get-Date) - BT Error: $_"
	}
}

function Show-InfoToast {
	param([string]$Title, [string]$Text)
	if ($global:config.Settings.ShowToastNotifications -eq $false) { return }
	try {
		[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
		[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null
        
		$xmlString = @"
<toast duration="short">
    <visual>
        <binding template="ToastGeneric">
            <text>$Title</text>
            <text>$Text</text>
        </binding>
    </visual>
</toast>
"@
		$xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
		$xml.LoadXml($xmlString)
		$toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
		[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Windows PowerShell").Show($toast)
	}
	catch { Write-Host "[ERROR] $(Get-Date) - Show-InfoToast Error: $_" }
}

# Sends a signal to close the popup from the main runspace
function Close-BatteryPopup {
	try {
		if ($global:popupData) {
			$global:popupData.ShouldClose = $true
		}
		$global:popupPS = $null
		$global:popupRunspace = $null
	}
	catch {}
}

# Shows battery warning popup in a dedicated STA runspace so the UI has
# its own message loop — cursor updates instantly, window gets focus correctly
function Show-BatteryWarningPopup {
	param([int]$CountdownSeconds = 60)
	try {
		# Signal any existing popup to close, then clean up runspace
		Close-BatteryPopup
		Start-Sleep -Milliseconds 300  # let previous form finish closing

		# Cleanup old runspace objects if still alive
		if ($global:popupRunspace) {
			try { $global:popupRunspace.Dispose() } catch {}
			$global:popupRunspace = $null
		}

		# Reset state
		$global:popupData.Action = "none"
		$global:popupData.ShouldClose = $false

		# Create a dedicated STA runspace — required for WinForms to work properly
		$rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
		$rs.ApartmentState = "STA"
		$rs.ThreadOptions = "ReuseThread"
		$rs.Open()
		$rs.SessionStateProxy.SetVariable("sharedData", $global:popupData)
		$rs.SessionStateProxy.SetVariable("totalSeconds", $CountdownSeconds)

		$ps = [System.Management.Automation.PowerShell]::Create()
		$ps.Runspace = $rs
		$null = $ps.AddScript({
				Add-Type -AssemblyName System.Windows.Forms
				Add-Type -AssemblyName System.Drawing

				$form = New-Object System.Windows.Forms.Form
				$form.Text = ([char]0x26A1).ToString() + " Battery Power Mode"
				$form.ClientSize = New-Object System.Drawing.Size(430, 185)
				$form.StartPosition = "CenterScreen"
				$form.FormBorderStyle = "FixedDialog"
				$form.MaximizeBox = $false
				$form.MinimizeBox = $false
				$form.ShowInTaskbar = $false
				$form.TopMost = $true
				$form.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
				$form.ForeColor = [System.Drawing.Color]::White

				$script:remaining = $totalSeconds

				$label = New-Object System.Windows.Forms.Label
				$label.Text = "Background apps will close and Bluetooth`nwill turn off in $($script:remaining) seconds."
				$label.Location = New-Object System.Drawing.Point(25, 20)
				$label.Size = New-Object System.Drawing.Size(380, 65)
				$label.Font = New-Object System.Drawing.Font("Segoe UI", 12)
				$label.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 230)
				$form.Controls.Add($label)

				$btnSnooze = New-Object System.Windows.Forms.Button
				$btnSnooze.Text = "Snooze for 5 min"
				$btnSnooze.Location = New-Object System.Drawing.Point(25, 120)
				$btnSnooze.Size = New-Object System.Drawing.Size(180, 45)
				$btnSnooze.FlatStyle = "Flat"
				$btnSnooze.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
				$btnSnooze.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 55)
				$btnSnooze.ForeColor = [System.Drawing.Color]::White
				$btnSnooze.Font = New-Object System.Drawing.Font("Segoe UI", 10)
				$btnSnooze.Cursor = [System.Windows.Forms.Cursors]::Hand
				$btnSnooze.Add_Click({
						$sharedData.Action = "snooze"
						$countdownTimer.Stop()
						$form.Close()
					})
				$form.Controls.Add($btnSnooze)

				$btnPostpone = New-Object System.Windows.Forms.Button
				$btnPostpone.Text = "Postpone until plugged in"
				$btnPostpone.Location = New-Object System.Drawing.Point(225, 120)
				$btnPostpone.Size = New-Object System.Drawing.Size(180, 45)
				$btnPostpone.FlatStyle = "Flat"
				$btnPostpone.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
				$btnPostpone.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 55)
				$btnPostpone.ForeColor = [System.Drawing.Color]::White
				$btnPostpone.Font = New-Object System.Drawing.Font("Segoe UI", 10)
				$btnPostpone.Cursor = [System.Windows.Forms.Cursors]::Hand
				$btnPostpone.Add_Click({
						$sharedData.Action = "postpone"
						$countdownTimer.Stop()
						$form.Close()
					})
				$form.Controls.Add($btnPostpone)

				# WinForms Timer ticks every second — updates countdown and checks ShouldClose signal
				$countdownTimer = New-Object System.Windows.Forms.Timer
				$countdownTimer.Interval = 1000
				$countdownTimer.Add_Tick({
						if ($sharedData.ShouldClose) {
							$countdownTimer.Stop()
							$form.Close()
							return
						}
						$script:remaining--
						if ($script:remaining -le 0) {
							$countdownTimer.Stop()
							$form.Close()
						}
						else {
							$label.Text = "Background apps will close and Bluetooth`nwill turn off in $($script:remaining) seconds."
						}
					})
				$countdownTimer.Start()

				# Application.Run = proper WinForms message loop (instant cursor, focus, events)
				[System.Windows.Forms.Application]::Run($form)
				$countdownTimer.Dispose()
			})

		$global:popupRunspace = $rs
		$global:popupPS = $ps
		$ps.BeginInvoke() | Out-Null
		Write-Host "[$(Get-Date)] Battery warning popup shown (${CountdownSeconds}s countdown)"
	}
	catch { Write-Host "[ERROR] $(Get-Date) - Show-BatteryWarningPopup Error: $_" }
}

function Enable-AcMode {
	Write-Host "Entering Enable-AcMode"
	Set-BluetoothState -TargetState 'On'
	Set-WindowsVisuals -Enable $true
    
	Show-InfoToast -Title "AC Power" -Text "Bluetooth ON. Visuals activated. Launching background apps."
    
	if ($global:config.AcMode.AppsToLaunch) {
		foreach ($app in $global:config.AcMode.AppsToLaunch) {
			try {
				$appPath = if ($app.Path) { [System.Environment]::ExpandEnvironmentVariables($app.Path) } else { "" }
				if ($app.Type -eq "URI" -or $app.Type -eq "UWP") {
					if ($app.ProcessName) {
						$existing = Get-Process -Name $app.ProcessName -ErrorAction SilentlyContinue
						if ($existing) {
							Write-Host "SKIP: $($app.ProcessName) already running"
							continue
						}
					}
					Write-Host "Launching UWP/URI App: $appPath"
					Start-Process "explorer.exe" -ArgumentList $appPath
				}
				elseif (Test-Path $appPath) {
					# Check if process is already running — skip to avoid duplicate launch
					$processName = if ($app.ProcessName) { $app.ProcessName } else { [System.IO.Path]::GetFileNameWithoutExtension($appPath) }
					$existingProcess = Get-Process -Name $processName -ErrorAction SilentlyContinue
					if ($existingProcess) {
						Write-Host "SKIP: $processName already running"
						continue
					}

					$workDir = Split-Path -Parent $appPath
					$appArgs = if ($app.Args) { [System.Environment]::ExpandEnvironmentVariables($app.Args) } else { "" }

					if ($app.RunAsUser) {
						Write-Host "Launching as User via Shell: $appPath"
						$Shell = New-Object -ComObject Shell.Application
						$Desktop = $Shell.Windows() | Where-Object { $_.Name -match "Windows Explorer|File Explorer" -or $_.DocumentType -eq "IShellFolderViewDual" } | Select-Object -First 1
						if ($Desktop) {
							$Desktop.Document.Application.ShellExecute($appPath, $appArgs, $workDir, "open", 1)
						}
						else {
							Start-Process "explorer.exe" -ArgumentList "`"$appPath`""
						}
					}
					elseif ([string]::IsNullOrWhiteSpace($appArgs)) {
						Write-Host "Launching Process: $appPath"
						Start-Process -FilePath $appPath -WorkingDirectory $workDir -WindowStyle Normal
					}
					else {
						Write-Host "Launching Process: $appPath with args: $appArgs"
						Start-Process -FilePath $appPath -WorkingDirectory $workDir -ArgumentList $appArgs -WindowStyle Normal
					}
				}
				else {
					Write-Host "App path not found: $appPath"
				}
			}
			catch { Write-Host "[ERROR] $(Get-Date) - Enable-AcMode App Launch Error for $($app.Path): $_" }
			Start-Sleep -Seconds 2
		}
	}

	# Minimize apps to tray if configured with MinimizeToTray: true
	# CloseMainWindow() sends WM_CLOSE which apps like Telegram intercept by minimizing to tray
	if ($global:config.AcMode.AppsToLaunch) {
		$trayApps = @($global:config.AcMode.AppsToLaunch | Where-Object { $_.MinimizeToTray -eq $true })
		foreach ($trayApp in $trayApps) {
			$pName = if ($trayApp.ProcessName) { $trayApp.ProcessName } else { [System.IO.Path]::GetFileNameWithoutExtension($trayApp.Path) }
			if ($pName) {
				Start-Job -ScriptBlock {
					param($procName)
					for ($i = 0; $i -lt 15; $i++) {
						Start-Sleep -Seconds 2
						$proc = Get-Process -Name $procName -ErrorAction SilentlyContinue
						if ($proc -and $proc.MainWindowHandle -ne [IntPtr]::Zero) {
							$proc.CloseMainWindow() | Out-Null
							break
						}
					}
				} -ArgumentList $pName | Out-Null
			}
		}
	}
}

function Enable-BatteryMode {
	Write-Host "Entering Enable-BatteryMode"
	Set-BluetoothState -TargetState 'Off'
	Set-WindowsVisuals -Enable $false
    
	Show-InfoToast -Title "Battery Power" -Text "Bluetooth OFF. Background apps closed to save energy."
	
	$processesToClose = if ($global:config.BatteryMode.ProcessesToClose) { @($global:config.BatteryMode.ProcessesToClose) } else { @() }
	if ($processesToClose.Count -gt 0) {
		$appsToClose = Get-Process -Name $processesToClose -ErrorAction SilentlyContinue
		if ($appsToClose) {
			foreach ($app in $appsToClose) {
				if ($app.MainWindowHandle -ne 0) {
					$app.CloseMainWindow() | Out-Null
				}
			}
			$closeTimeout = if ($global:config.BatteryMode.GracefulCloseTimeoutSeconds) { [int]$global:config.BatteryMode.GracefulCloseTimeoutSeconds } else { 3 }
			Start-Sleep -Seconds $closeTimeout
	        
			$appsRemaining = Get-Process -Name $processesToClose -ErrorAction SilentlyContinue
			if ($appsRemaining) {
				$appsRemaining | Stop-Process -Force -ErrorAction SilentlyContinue
			}
		}
	}
}

# --- State Machine & Events ---
$global:currentState = [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus
$global:timerState = "InitialDelay"
# Synchronized hashtable for cross-runspace communication with the popup
$global:popupData = [System.Collections.Hashtable]::Synchronized(@{ Action = "none"; ShouldClose = $false })
$global:popupRunspace = $null
$global:popupPS = $null

$global:batteryTimer = New-Object System.Timers.Timer
$global:batteryTimer.AutoReset = $false # We trigger it manually for each step

$popupCountdownSec = if ($global:config.Settings.BatteryPopupCountdownSeconds) { [int]$global:config.Settings.BatteryPopupCountdownSeconds } else { 60 }
$snoozeMs = if ($global:config.Settings.SnoozeDurationMinutes) { [int]$global:config.Settings.SnoozeDurationMinutes * 60000 } else { 300000 }
$prePopupMs = if ($global:config.Settings.BatteryPrePopupDelaySeconds) { [int]$global:config.Settings.BatteryPrePopupDelaySeconds * 1000 } else { 20000 }

Unregister-Event -SourceIdentifier "BatteryTimer" -ErrorAction SilentlyContinue
Register-ObjectEvent -InputObject $global:batteryTimer -EventName Elapsed -SourceIdentifier "BatteryTimer" -Action {
	if ($global:currentState -eq 'Online') { return }

	$popupSec = if ($global:config.Settings.BatteryPopupCountdownSeconds) { [int]$global:config.Settings.BatteryPopupCountdownSeconds } else { 60 }
	$snoozeTime = if ($global:config.Settings.SnoozeDurationMinutes) { [int]$global:config.Settings.SnoozeDurationMinutes * 60000 } else { 300000 }

	if ($global:timerState -eq "InitialDelay") {
		$global:popupData.Action = "none"
		Show-BatteryWarningPopup -CountdownSeconds $popupSec
		$global:timerState = "WaitingForToast"
		$global:batteryTimer.Interval = ($popupSec * 1000)
		$global:batteryTimer.Start()
	}
	elseif ($global:timerState -eq "WaitingForToast") {
		$action = $global:popupData.Action
		if ($action -eq "snooze") {
			Write-Host "[$(Get-Date)] Snooze chosen - waiting ($($global:config.Settings.SnoozeDurationMinutes) min)"
			$global:popupData.Action = "none"
			$global:timerState = "Snoozing"
			$global:batteryTimer.Interval = $snoozeTime
			$global:batteryTimer.Start()
		}
		elseif ($action -eq "postpone") {
			# Popup stays closed until next power event
			Write-Host "[$(Get-Date)] Postponed until plugged in"
			$global:popupData.Action = "none"
		}
		else {
			# Countdown elapsed with no action (or X pressed) -> execute battery mode
			Write-Host "[$(Get-Date)] Countdown expired - enabling battery mode"
			Close-BatteryPopup
			Enable-BatteryMode
		}
	}
	elseif ($global:timerState -eq "Snoozing") {
		Write-Host "[$(Get-Date)] Snooze ended - showing popup again"
		$global:popupData.Action = "none"
		Show-BatteryWarningPopup -CountdownSeconds $popupSec
		$global:timerState = "WaitingForToast"
		$global:batteryTimer.Interval = ($popupSec * 1000)
		$global:batteryTimer.Start()
	}
} | Out-Null

function Invoke-BatterySequence {
	Write-Host "Entering Invoke-BatterySequence"
	$prePopup = if ($global:config.Settings.BatteryPrePopupDelaySeconds) { [int]$global:config.Settings.BatteryPrePopupDelaySeconds * 1000 } else { 20000 }
	$global:popupData.Action = "none"
	$global:popupData.ShouldClose = $false
	$global:timerState = "InitialDelay"
	$global:batteryTimer.Interval = $prePopup
	$global:batteryTimer.Start()
}

# Initialization
$initialDelay = if ($global:config.Settings.InitialStartupDelaySeconds) { [int]$global:config.Settings.InitialStartupDelaySeconds } else { 15 }
Start-Sleep -Seconds $initialDelay

if ($global:currentState -eq 'Online') {
	Write-Host "Configuration Name: AC Power"
	Enable-AcMode
}
else {
	Write-Host "Configuration Name: Battery Power"
	Enable-BatteryMode
}

Unregister-Event -SourceIdentifier "PowerMonitor" -ErrorAction SilentlyContinue
Register-WmiEvent -Query "SELECT * FROM Win32_PowerManagementEvent WHERE EventType = 10" -SourceIdentifier "PowerMonitor" -Action {
	$status = [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus
	if ($status -eq 'Offline' -and $global:currentState -eq 'Online') {
		Write-Host "[$(Get-Date)] MODE SWITCH: AC -> Battery"
		$global:currentState = 'Offline'
		Invoke-BatterySequence
	}
	elseif ($status -eq 'Online' -and $global:currentState -eq 'Offline') {
		Write-Host "[$(Get-Date)] MODE SWITCH: Battery -> AC"
		$global:currentState = 'Online'
		$global:batteryTimer.Stop()
		Close-BatteryPopup
		Enable-AcMode
	}
}

# Keep script alive to process events and timers
while ($true) {
	Wait-Event -Timeout 5
}