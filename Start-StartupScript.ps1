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
	$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath } elseif ($MyInvocation.MyCommand.Definition) { Split-Path -Parent $MyInvocation.MyCommand.Definition } else { $PWD.Path }
	$configPath = Join-Path $scriptDir "config.json"
	$exampleConfigPath = Join-Path $scriptDir "config.example.json"

	$targetPath = if (Test-Path $configPath) { $configPath } elseif (Test-Path $exampleConfigPath) { $exampleConfigPath } else { $null }

	if ($targetPath) {
		try {
			$rawJson = Get-Content -Path $targetPath -Raw -Encoding UTF8
			$cleanJson = $rawJson -replace '(?s)/\*.*?\*/', '' -replace '(?m)^\s*//.*$', '' -replace ',\s*(?=[}\]])', ''
			$configObj = $cleanJson | ConvertFrom-Json
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
		Settings    = [PSCustomObject]@{
			InitialStartupDelaySeconds   = 15
			BatteryPrePopupDelaySeconds  = 20
			BatteryPopupCountdownSeconds = 60
			AcPopupCountdownSeconds      = 60
			SnoozeDurationMinutes        = 5
			LogPath                      = "%TEMP%\SmartStartup_log.txt"
		}
		Features    = [PSCustomObject]@{
			Bluetooth           = $true
			VisualEffects       = $true
			ToastNotifications  = $true
			AcLaunchPopup       = $true
			BatteryWarningPopup = $true
			LaunchAppsOnAc      = $true
			CloseAppsOnBattery  = $true
		}
		AcMode      = [PSCustomObject]@{
			AppsToLaunch = @()
		}
		BatteryMode = [PSCustomObject]@{
			ProcessesToClose            = @()
			GracefulCloseTimeoutSeconds = 3
		}
	}
}

$global:config = Get-ScriptConfiguration

function Test-FeatureEnabled {
	param(
		[Parameter(Mandatory = $true)][string]$FeatureName,
		[string]$LegacySettingName = $null,
		[bool]$Default = $true
	)

	if ($global:config.PSObject.Properties['Features'] -and $global:config.Features) {
		if ($global:config.Features.PSObject.Properties[$FeatureName]) {
			return [bool]$global:config.Features.$FeatureName
		}
	}

	if ($global:config.PSObject.Properties['Settings'] -and $global:config.Settings) {
		if ($global:config.Settings.PSObject.Properties[$FeatureName]) {
			return [bool]$global:config.Settings.$FeatureName
		}
		if ($LegacySettingName -and $global:config.Settings.PSObject.Properties[$LegacySettingName]) {
			return [bool]$global:config.Settings.$LegacySettingName
		}
	}

	return $Default
}

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
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$Win32API = @'
using System;
using System.Runtime.InteropServices;
public class User32 {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SystemParametersInfo(int uiAction, int uiParam, bool pvParam, int fWinIni);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")]
    public static extern IntPtr GetDesktopWindow();
}

public class TrayRefresher {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr FindWindowEx(IntPtr parentHandle, IntPtr childAfter, string className, string windowTitle);
    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    public const uint WM_MOUSEMOVE = 0x0200;

    public static void RefreshTray() {
        try {
            IntPtr hTray = FindWindow("Shell_TrayWnd", null);
            if (hTray != IntPtr.Zero) {
                IntPtr hNotify = FindWindowEx(hTray, IntPtr.Zero, "TrayNotifyWnd", null);
                if (hNotify != IntPtr.Zero) {
                    IntPtr hSysPager = FindWindowEx(hNotify, IntPtr.Zero, "SysPager", null);
                    IntPtr hTool = hSysPager != IntPtr.Zero ? FindWindowEx(hSysPager, IntPtr.Zero, "ToolbarWindow32", null) : FindWindowEx(hNotify, IntPtr.Zero, "ToolbarWindow32", null);
                    if (hTool != IntPtr.Zero) RefreshToolbar(hTool);
                }
            }
            IntPtr hOverflow = FindWindow("NotifyIconOverflowWindow", null);
            if (hOverflow != IntPtr.Zero) {
                IntPtr hTool = FindWindowEx(hOverflow, IntPtr.Zero, "ToolbarWindow32", null);
                if (hTool != IntPtr.Zero) RefreshToolbar(hTool);
            }
        } catch {}
    }

    private static void RefreshToolbar(IntPtr hTool) {
        RECT rect;
        if (GetClientRect(hTool, out rect)) {
            for (int x = 0; x < rect.Right; x += 8) {
                for (int y = 0; y < rect.Bottom; y += 8) {
                    IntPtr lParam = (IntPtr)((y << 16) | (x & 0xFFFF));
                    SendMessage(hTool, WM_MOUSEMOVE, IntPtr.Zero, lParam);
                }
            }
        }
    }
}
public class DisplayConfigManager {
    public const int SDC_APPLY = 0x00000080;
    public const int SDC_USE_SUPPLIED_DISPLAY_CONFIG = 0x00000020;
    public const int SDC_ALLOW_CHANGES = 0x00000402;
    public const uint QDC_ONLY_ACTIVE_PATHS = 0x00000002;

    [DllImport("user32.dll")]
    public static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPathArrayElements, out uint numModeInfoArrayElements);

    [DllImport("user32.dll")]
    public static extern int QueryDisplayConfig(uint flags, ref uint numPathArrayElements, [Out] DISPLAYCONFIG_PATH_INFO[] pathArray, ref uint numModeInfoArrayElements, [Out] DISPLAYCONFIG_MODE_INFO[] modeInfoArray, IntPtr currentTopologyId);

    [DllImport("user32.dll")]
    public static extern int SetDisplayConfig(uint numPathArrayElements, [In] DISPLAYCONFIG_PATH_INFO[] pathArray, uint numModeInfoArrayElements, [In] DISPLAYCONFIG_MODE_INFO[] modeInfoArray, uint flags);

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_RATIONAL {
        public uint Numerator;
        public uint Denominator;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_SOURCE_INFO {
        public uint adapterIdLow;
        public uint adapterIdHigh;
        public uint id;
        public uint modeInfoIdx;
        public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_TARGET_INFO {
        public uint adapterIdLow;
        public uint adapterIdHigh;
        public uint id;
        public uint modeInfoIdx;
        public uint outputTechnology;
        public uint rotation;
        public uint scaling;
        public DISPLAYCONFIG_RATIONAL refreshRate;
        public uint scanLineOrdering;
        public bool targetAvailable;
        public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_PATH_INFO {
        public DISPLAYCONFIG_PATH_SOURCE_INFO sourceInfo;
        public DISPLAYCONFIG_PATH_TARGET_INFO targetInfo;
        public uint flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct DISPLAYCONFIG_VIDEO_SIGNAL_INFO {
        public ulong pixelRate;
        public DISPLAYCONFIG_RATIONAL hSyncFreq;
        public DISPLAYCONFIG_RATIONAL vSyncFreq;
        public DISPLAYCONFIG_RATIONAL activeSize;
        public DISPLAYCONFIG_RATIONAL totalSize;
        public uint videoStandard;
        public uint vSyncFreqDivider;
        public uint colorStandard;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct DISPLAYCONFIG_TARGET_MODE {
        [FieldOffset(0)]
        public DISPLAYCONFIG_VIDEO_SIGNAL_INFO targetVideoSignalInfo;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct DISPLAYCONFIG_MODE_INFO {
        [FieldOffset(0)]
        public uint infoType;
        [FieldOffset(4)]
        public uint id;
        [FieldOffset(8)]
        public uint adapterIdLow;
        [FieldOffset(12)]
        public uint adapterIdHigh;
        [FieldOffset(16)]
        public DISPLAYCONFIG_TARGET_MODE targetMode;
        [FieldOffset(60)]
        public uint dummy;
    }

    public static uint GetCurrentHz() {
        uint pathCount = 0, modeCount = 0;
        if (GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out pathCount, out modeCount) != 0) return 0;
        var paths = new DISPLAYCONFIG_PATH_INFO[pathCount];
        var modes = new DISPLAYCONFIG_MODE_INFO[modeCount];
        if (QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero) != 0) return 0;
        if (pathCount > 0 && paths[0].targetInfo.refreshRate.Denominator > 0) {
            return paths[0].targetInfo.refreshRate.Numerator / paths[0].targetInfo.refreshRate.Denominator;
        }
        return 0;
    }

    public static int SetRefreshRate(uint targetHz) {
        uint pathCount = 0, modeCount = 0;
        int result = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out pathCount, out modeCount);
        if (result != 0) return result;

        var paths = new DISPLAYCONFIG_PATH_INFO[pathCount];
        var modes = new DISPLAYCONFIG_MODE_INFO[modeCount];

        result = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero);
        if (result != 0) return result;

        for (int i = 0; i < modes.Length; i++) {
            if (modes[i].infoType == 2) {
                if (targetHz == 60) {
                    modes[i].targetMode.targetVideoSignalInfo.pixelRate = 155240000;
                    modes[i].targetMode.targetVideoSignalInfo.vSyncFreq.Numerator = 97025;
                    modes[i].targetMode.targetVideoSignalInfo.vSyncFreq.Denominator = 1617;
                    modes[i].targetMode.targetVideoSignalInfo.hSyncFreq.Numerator = 776200;
                    modes[i].targetMode.targetVideoSignalInfo.hSyncFreq.Denominator = 11;
                    paths[0].targetInfo.refreshRate.Numerator = 97025;
                    paths[0].targetInfo.refreshRate.Denominator = 1617;
                } else {
                    modes[i].targetMode.targetVideoSignalInfo.pixelRate = 372560000;
                    modes[i].targetMode.targetVideoSignalInfo.vSyncFreq.Numerator = 232850;
                    modes[i].targetMode.targetVideoSignalInfo.vSyncFreq.Denominator = 1617;
                    modes[i].targetMode.targetVideoSignalInfo.hSyncFreq.Numerator = 1862800;
                    modes[i].targetMode.targetVideoSignalInfo.hSyncFreq.Denominator = 11;
                    paths[0].targetInfo.refreshRate.Numerator = 232850;
                    paths[0].targetInfo.refreshRate.Denominator = 1617;
                }
            }
        }

        uint flags = (uint)(SDC_APPLY | SDC_USE_SUPPLIED_DISPLAY_CONFIG | SDC_ALLOW_CHANGES);
        return SetDisplayConfig(pathCount, paths, modeCount, modes, flags);
    }
}
'@
Add-Type -TypeDefinition $Win32API

function Get-DisplayRefreshRate {
	try {
		$hz = [DisplayConfigManager]::GetCurrentHz()
		if ($hz -gt 0) { return [int]$hz }
		$vc = Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.CurrentRefreshRate -gt 0 } | Select-Object -First 1
		if ($vc -and $vc.CurrentRefreshRate) {
			return [int]$vc.CurrentRefreshRate
		}
	}
	catch {}
	return 0
}

function Set-DisplayRefreshRate {
	param([int]$TargetHz)
	if (-not (Test-FeatureEnabled -FeatureName "DisplayRefreshRate" -Default $true)) { return }
	try {
		$curHz = Get-DisplayRefreshRate
		if ($curHz -eq $TargetHz) {
			Write-Host "[$(Get-Date)] Screen refresh rate already at $TargetHz Hz. Skipping."
			return
		}
		Write-Host "[$(Get-Date)] Current refresh rate: $curHz Hz. Switching to $TargetHz Hz..."
		$res = [DisplayConfigManager]::SetRefreshRate([uint32]$TargetHz)
		Write-Host "[$(Get-Date)] SetDisplayConfig result code: $res"
	}
	catch {
		Write-Host "[WARN] $(Get-Date) - Failed to set refresh rate: $_"
	}
}

function Set-DisplayBrightness {
	param([int]$TargetBrightness)
	if (-not (Test-FeatureEnabled -FeatureName "DisplayBrightness" -Default $true)) { return }
	try {
		$cur = (Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightness -ErrorAction SilentlyContinue).CurrentBrightness
		if ($cur -eq $TargetBrightness) {
			Write-Host "[$(Get-Date)] Brightness already at $TargetBrightness%. Skipping."
			return
		}
		$brightnessObj = Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightnessMethods -ErrorAction SilentlyContinue
		if ($brightnessObj) {
			$brightnessObj | Invoke-CimMethod -MethodName WmiSetBrightness -Arguments @{ Timeout = 1; Brightness = [byte]$TargetBrightness } | Out-Null
			Write-Host "[$(Get-Date)] Display brightness changed from $cur% to $TargetBrightness%"
		}
	}
	catch {
		Write-Host "[WARN] $(Get-Date) - Failed to set display brightness: $_"
	}
}

function Set-WindowsVisuals {
	param([bool]$Enable)
	if (-not (Test-FeatureEnabled -FeatureName "VisualEffects" -LegacySettingName "ManageVisualEffects")) { return }
	$minAnimate = if ($Enable) { "1" } else { "0" }
	Set-ItemProperty -Path "HKCU:\Control Panel\Desktop\WindowMetrics" -Name "MinAnimate" -Value $minAnimate
	$transparency = if ($Enable) { 1 } else { 0 }
	Set-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "EnableTransparency" -Value $transparency
	[User32]::SystemParametersInfo(0x1043, 0, $Enable, 3) | Out-Null
}

function Set-BluetoothState {
	param([string]$TargetState)
	if (-not (Test-FeatureEnabled -FeatureName "Bluetooth" -LegacySettingName "ManageBluetooth")) { return }
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
	if (-not (Test-FeatureEnabled -FeatureName "ToastNotifications" -LegacySettingName "ShowToastNotifications")) { return }
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
		try {
			[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe").Show($toast)
		}
		catch {
			[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Windows PowerShell").Show($toast)
		}
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
		Close-BatteryPopup
		Start-Sleep -Milliseconds 200

		if ($global:popupRunspace) {
			try { $global:popupRunspace.Dispose() } catch {}
			$global:popupRunspace = $null
		}

		$global:popupData.Action = "none"
		$global:popupData.ShouldClose = $false

		$rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
		$rs.ApartmentState = "STA"
		$rs.ThreadOptions = "ReuseThread"
		$rs.Open()
		$rs.SessionStateProxy.SetVariable("sharedData", $global:popupData)
		$rs.SessionStateProxy.SetVariable("totalSeconds", $CountdownSeconds)

		$ps = [System.Management.Automation.PowerShell]::Create()
		$ps.Runspace = $rs
		$null = $ps.AddScript({
			Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

			$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Apply Eco Config" Height="230" Width="450"
        WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ShowInTaskbar="False"
        ShowActivated="False" Focusable="False" Opacity="0"
        TextOptions.TextFormattingMode="Display"
        TextOptions.TextRenderingMode="ClearType"
        RenderOptions.ClearTypeHint="Enabled"
        UseLayoutRounding="True">
    <Window.Resources>
        <Style x:Key="BtnPrimary" TargetType="Button">
            <Setter Property="Background" Value="#E65100"/>
            <Setter Property="Foreground" Value="#FFFFFF"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Height" Value="38"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="RenderTransformOrigin" Value="0.5,0.5"/>
            <Setter Property="RenderTransform">
                <Setter.Value>
                    <ScaleTransform ScaleX="1.0" ScaleY="1.0"/>
                </Setter.Value>
            </Setter>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid SnapsToDevicePixels="True">
                            <Border x:Name="glow" CornerRadius="8" Background="#FF9100" Opacity="0">
                                <Border.Effect>
                                    <DropShadowEffect Color="#FF9100" BlurRadius="12" ShadowDepth="0" Opacity="0.5"/>
                                </Border.Effect>
                            </Border>
                            <Border x:Name="bdr" Background="{TemplateBinding Background}" CornerRadius="8" SnapsToDevicePixels="True">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                                  RecognizesAccessKey="False" SnapsToDevicePixels="True"/>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="glow" Property="Opacity" Value="1"/>
                                <Setter TargetName="bdr" Property="Background" Value="#FFA726"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="glow" Property="Opacity" Value="0.3"/>
                                <Setter TargetName="bdr" Property="Background" Value="#CC4400"/>
                                <Setter Property="RenderTransform">
                                    <Setter.Value>
                                        <ScaleTransform ScaleX="0.96" ScaleY="0.96"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="BtnSecondary" TargetType="Button">
            <Setter Property="Background" Value="#252532"/>
            <Setter Property="Foreground" Value="#D5D5E2"/>
            <Setter Property="BorderBrush" Value="#3D3D52"/>
            <Setter Property="BorderThickness" Value="1.5"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Height" Value="38"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="RenderTransformOrigin" Value="0.5,0.5"/>
            <Setter Property="RenderTransform">
                <Setter.Value>
                    <ScaleTransform ScaleX="1.0" ScaleY="1.0"/>
                </Setter.Value>
            </Setter>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid SnapsToDevicePixels="True">
                            <Border x:Name="glow" CornerRadius="8" Background="#2A1B12" Opacity="0">
                                <Border.Effect>
                                    <DropShadowEffect Color="#FF9100" BlurRadius="10" ShadowDepth="0" Opacity="0.35"/>
                                </Border.Effect>
                            </Border>
                            <Border x:Name="bdr" Background="{TemplateBinding Background}" CornerRadius="8" 
                                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" SnapsToDevicePixels="True">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                                  RecognizesAccessKey="False" SnapsToDevicePixels="True"/>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="glow" Property="Opacity" Value="1"/>
                                <Setter TargetName="bdr" Property="BorderBrush" Value="#FF9100"/>
                                <Setter TargetName="bdr" Property="Background" Value="#2A1B12"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="glow" Property="Opacity" Value="0.2"/>
                                <Setter TargetName="bdr" Property="Background" Value="#1C120B"/>
                                <Setter Property="RenderTransform">
                                    <Setter.Value>
                                        <ScaleTransform ScaleX="0.96" ScaleY="0.96"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Window.Triggers>
        <EventTrigger RoutedEvent="Window.Loaded">
            <BeginStoryboard>
                <Storyboard>
                    <DoubleAnimation Storyboard.TargetName="RootScale" Storyboard.TargetProperty="ScaleX"
                                     From="0.70" To="1.0" Duration="0:0:0.75">
                        <DoubleAnimation.EasingFunction>
                            <CubicEase EasingMode="EaseOut"/>
                        </DoubleAnimation.EasingFunction>
                    </DoubleAnimation>
                    <DoubleAnimation Storyboard.TargetName="RootScale" Storyboard.TargetProperty="ScaleY"
                                     From="0.70" To="1.0" Duration="0:0:0.75">
                        <DoubleAnimation.EasingFunction>
                            <CubicEase EasingMode="EaseOut"/>
                        </DoubleAnimation.EasingFunction>
                    </DoubleAnimation>
                    <DoubleAnimation Storyboard.TargetProperty="Opacity"
                                     From="0.0" To="1.0" Duration="0:0:0.75">
                        <DoubleAnimation.EasingFunction>
                            <QuadraticEase EasingMode="EaseOut"/>
                        </DoubleAnimation.EasingFunction>
                    </DoubleAnimation>
                </Storyboard>
            </BeginStoryboard>
        </EventTrigger>
    </Window.Triggers>
    <Border Name="RootBorder" Background="#1C1C22" CornerRadius="14" BorderBrush="#363645" BorderThickness="1.5" RenderTransformOrigin="0.5,0.5">
        <Border.RenderTransform>
            <ScaleTransform x:Name="RootScale" ScaleX="0.70" ScaleY="0.70"/>
        </Border.RenderTransform>
        <Border.Effect>
            <DropShadowEffect Color="#000000" BlurRadius="28" ShadowDepth="4" Opacity="0.65"/>
        </Border.Effect>
        <Grid Margin="24,20,24,20">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <!-- Header -->
            <StackPanel Grid.Row="0" Orientation="Horizontal">
                <Border Width="38" Height="38" CornerRadius="19" Background="#3D2914" Margin="0,0,14,0">
                    <TextBlock Text="ECO" FontSize="13" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="#FF9100" FontFamily="Segoe UI Variable Display, Segoe UI"/>
                </Border>
                <StackPanel VerticalAlignment="Center">
                    <TextBlock Text="Apply Eco Config" FontSize="17" FontWeight="SemiBold" Foreground="#FFFFFF" FontFamily="Segoe UI Variable Display, Segoe UI"/>
                    <TextBlock Text="60Hz | 30% Brightness | Close Apps" FontSize="12" Foreground="#8F8FA4" Margin="0,2,0,0"/>
                </StackPanel>
            </StackPanel>

            <!-- Body Message -->
            <TextBlock Grid.Row="1" Text="Kill all apps and go Eco?" 
                       TextWrapping="Wrap" FontSize="14" Foreground="#D5D5E2" Margin="0,12,0,8" VerticalAlignment="Center" LineHeight="18"/>

            <!-- Progress Bar -->
            <ProgressBar Grid.Row="2" Name="CountdownProgress" Height="4" Value="100" Minimum="0" Maximum="100" 
                         Foreground="#FF9100" Background="#2A2A38" BorderThickness="0" Margin="0,0,0,16"/>

            <!-- Action Buttons -->
            <Grid Grid.Row="3">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="12"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <Button Grid.Column="0" Name="BtnApply" Style="{StaticResource BtnPrimary}">
                    <TextBlock Name="TxtApply" Text="Apply (60s)"/>
                </Button>

                <Button Grid.Column="2" Name="BtnCancel" Style="{StaticResource BtnSecondary}" Content="Don't Apply"/>
            </Grid>
        </Grid>
    </Border>
</Window>
'@
			$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
			$window = [System.Windows.Markup.XamlReader]::Load($reader)

			$rootBorder = $window.FindName("RootBorder")
			$rootScale = $window.FindName("RootScale")
			$btnApply = $window.FindName("BtnApply")
			$btnCancel = $window.FindName("BtnCancel")
			$progress = $window.FindName("CountdownProgress")
			$txtApply = $window.FindName("TxtApply")

			$window.Add_MouseLeftButtonDown({ $window.DragMove() })

			# Handle PrintScreen so Lightshot triggers even if this elevated window has focus
			$window.Add_PreviewKeyDown({
				param($s, $e)
				if ($e.Key -eq [System.Windows.Input.Key]::Snapshot -or $e.SystemKey -eq [System.Windows.Input.Key]::Snapshot) {
					$e.Handled = $true
					[User32]::SetForegroundWindow([User32]::GetDesktopWindow()) | Out-Null
					$lsPath = "C:\Program Files (x86)\Skillbrains\lightshot\5.5.0.7\Lightshot.exe"
					if (Test-Path $lsPath) {
						Start-Process -FilePath $lsPath -ErrorAction SilentlyContinue
					} else {
						[User32]::keybd_event(0x2C, 0, 0, [UIntPtr]::Zero)
						[User32]::keybd_event(0x2C, 0, 2, [UIntPtr]::Zero)
					}
				}
			})

			# Set WS_EX_NOACTIVATE (0x08000000) and hook WM_MOUSEACTIVATE so clicks never steal focus from Lightshot / background apps
			$window.Add_SourceInitialized({
				try {
					$helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
					$exStyle = [User32]::GetWindowLong($helper.Handle, -20)
					[User32]::SetWindowLong($helper.Handle, -20, ($exStyle -bor 0x08000000)) | Out-Null
					$source = [System.Windows.Interop.HwndSource]::FromHwnd($helper.Handle)
					$source.AddHook({
						param($hwnd, $msg, $wParam, $lParam, [ref]$handled)
						if ($msg -eq 0x0021) { # WM_MOUSEACTIVATE
							$handled = $true
							return [IntPtr]3 # MA_NOACTIVATE: never steal focus on mouse clicks
						}
						return [IntPtr]::Zero
					})
				} catch {}
			})

			$script:remaining = $totalSeconds
			$txtApply.Text = "Apply ($($script:remaining)s)"

			$script:isClosing = $false
			$closeWithFade = {
				param($chosenAction)
				if ($script:isClosing) { return }
				$script:isClosing = $true
				$sharedData.Action = $chosenAction
				$timer.Stop()

				# Calm, smooth fade-out as requested for eco mode
				$fadeAnim = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.0, [System.Windows.Duration][TimeSpan]::FromMilliseconds(220))
				$fadeAnim.Add_Completed({
					$window.Close()
				})
				$window.BeginAnimation([System.Windows.Window]::OpacityProperty, $fadeAnim)
			}

			$btnApply.Add_Click({
				& $closeWithFade "yes"
			})

			$btnCancel.Add_Click({
				& $closeWithFade "no"
			})

			$timer = New-Object System.Windows.Threading.DispatcherTimer
			$timer.Interval = [TimeSpan]::FromSeconds(1)
			$timer.Add_Tick({
				if ($sharedData.ShouldClose) {
					$timer.Stop()
					$window.Close()
					return
				}
				$script:remaining--
				if ($totalSeconds -gt 0) {
					$progress.Value = [double]($script:remaining / $totalSeconds) * 100
				}
				if ($script:remaining -le 0) {
					& $closeWithFade "yes"
				}
				else {
					$txtApply.Text = "Apply ($($script:remaining)s)"
				}
			})

			$window.Add_Closing({
				$timer.Stop()
				if ($sharedData.Action -eq "none") {
					$sharedData.Action = "no"
				}
			})

			$timer.Start()
			$frame = New-Object System.Windows.Threading.DispatcherFrame
			$window.Add_Closed({ $frame.Continue = $false })
			$window.Show()
			[System.Windows.Threading.Dispatcher]::PushFrame($frame)
		})

		$global:popupRunspace = $rs
		$global:popupPS = $ps
		$handle = $ps.BeginInvoke()
		Write-Host "[$(Get-Date)] Apply Eco Config WPF popup shown (${CountdownSeconds}s countdown)"

		while (-not $handle.IsCompleted) {
			Start-Sleep -Milliseconds 100
			if ($global:currentState -eq 'Online' -or [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -eq 'Online') {
				Close-BatteryPopup
				break
			}
		}

		$action = $global:popupData.Action
		try { $rs.Dispose() } catch {}
		$global:popupRunspace = $null
		$global:popupPS = $null
		return $action
	}
	catch {
		Write-Host "[ERROR] $(Get-Date) - Show-BatteryWarningPopup Error: $_"
		return "no"
	}
}

function Enable-AcMode {
	param([switch]$SkipPopup)
	Write-Host "Entering Enable-AcMode"

	# Safety check: ensure power is genuinely Online
	if ([System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -ne 'Online') {
		Write-Host "[$(Get-Date)] Power is not Online. Skipping Enable-AcMode."
		return
	}

	Set-BluetoothState -TargetState 'On'
	Set-WindowsVisuals -Enable $true

	$acBrightness = if ($global:config.Settings.AcBrightness) { [int]$global:config.Settings.AcBrightness } else { 70 }
	$acHz = if ($global:config.Settings.AcRefreshRate) { [int]$global:config.Settings.AcRefreshRate } else { 144 }

	$appsToLaunch = @()
	if ($global:config.AcMode.AppsToLaunch) {
		$appsToLaunch = @($global:config.AcMode.AppsToLaunch | Where-Object {
			$isEnabled = $true
			if ($_.PSObject.Properties['Enabled'] -and $_.Enabled -eq $false) {
				$isEnabled = $false
			}
			$isEnabled
		})
	}

	$popupEnabled = Test-FeatureEnabled -FeatureName "AcLaunchPopup" -Default $true
	$shouldApply = $false

	if (-not $SkipPopup -and $popupEnabled) {
		$countdownSec = if ($global:config.Settings.AcPopupCountdownSeconds) { [int]$global:config.Settings.AcPopupCountdownSeconds } else { 60 }
		$userChoice = Show-AcLaunchPopup -CountdownSeconds $countdownSec
		if ($userChoice -eq "yes") {
			Write-Host "[$(Get-Date)] User confirmed (or timed out). Applying AC Config..."
			$shouldApply = $true
		}
		else {
			Write-Host "[$(Get-Date)] AC Config canceled by user (Action: $userChoice)."
		}
	}
	else {
		if ($SkipPopup) {
			Write-Host "[$(Get-Date)] SkipPopup active (fresh boot on AC). Automatically applying AC Config..."
		}
		else {
			Write-Host "[$(Get-Date)] AcLaunchPopup disabled. Automatically applying AC Config..."
		}
		$shouldApply = $true
	}

	# Safety check: if power dropped to battery while waiting or preparing, abort
	if ([System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -ne 'Online') {
		Write-Host "[$(Get-Date)] Power disconnected before launch could execute. Aborting AC Config."
		return
	}

	if ($shouldApply) {
		Set-DisplayBrightness -TargetBrightness $acBrightness
		Set-DisplayRefreshRate -TargetHz $acHz

		$power = [System.Windows.Forms.SystemInformation]::PowerStatus
		$batteryPercent = [int]($power.BatteryLifePercent * 100)

		$toastParts = @()
		if ($batteryPercent -gt 0) { $toastParts += "Battery: $batteryPercent%" }
		if (Test-FeatureEnabled -FeatureName "DisplayRefreshRate") { $toastParts += "$acHz Hz" }
		if (Test-FeatureEnabled -FeatureName "DisplayBrightness") { $toastParts += "Brightness $acBrightness%" }
		if (Test-FeatureEnabled -FeatureName "Bluetooth" -LegacySettingName "ManageBluetooth") { $toastParts += "Bluetooth ON" }
		if (Test-FeatureEnabled -FeatureName "VisualEffects" -LegacySettingName "ManageVisualEffects") { $toastParts += "Visuals ON" }
		$toastText = if ($toastParts.Count -gt 0) { $toastParts -join " | " } else { "AC mode active" }
		Show-InfoToast -Title "Apply AC Config" -Text $toastText

		# Clean ghost tray icons before launching apps
		[TrayRefresher]::RefreshTray()

		if ((Test-FeatureEnabled -FeatureName "LaunchAppsOnAc" -Default $true) -and $appsToLaunch.Count -gt 0) {
			Invoke-AppsLaunch -Apps $appsToLaunch
		}
	}
	else {
		Write-Host "[$(Get-Date)] AC Config was not applied."
	}
}

# Sends a signal to close the AC launch popup from the main runspace
function Close-AcLaunchPopup {
	try {
		if ($global:acPopupData) {
			$global:acPopupData.ShouldClose = $true
		}
		$global:acPopupPS = $null
		$global:acPopupRunspace = $null
	}
	catch {}
}

# Shows AC app launch confirmation popup in a dedicated STA runspace
function Show-AcLaunchPopup {
	param([int]$CountdownSeconds = 60)
	try {
		Close-AcLaunchPopup
		Start-Sleep -Milliseconds 200

		if ($global:acPopupRunspace) {
			try { $global:acPopupRunspace.Dispose() } catch {}
			$global:acPopupRunspace = $null
		}

		$global:acPopupData.Action = "none"
		$global:acPopupData.ShouldClose = $false

		$rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
		$rs.ApartmentState = "STA"
		$rs.ThreadOptions = "ReuseThread"
		$rs.Open()
		$rs.SessionStateProxy.SetVariable("sharedData", $global:acPopupData)
		$rs.SessionStateProxy.SetVariable("totalSeconds", $CountdownSeconds)

		$ps = [System.Management.Automation.PowerShell]::Create()
		$ps.Runspace = $rs
		$null = $ps.AddScript({
			Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

			$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Apply AC Config" Height="230" Width="450"
        WindowStartupLocation="CenterScreen" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ShowInTaskbar="False"
        ShowActivated="False" Focusable="False" Opacity="0"
        TextOptions.TextFormattingMode="Display"
        TextOptions.TextRenderingMode="ClearType"
        RenderOptions.ClearTypeHint="Enabled"
        UseLayoutRounding="True">
    <Window.Resources>
        <Style x:Key="BtnPrimary" TargetType="Button">
            <Setter Property="Background" Value="#9bff00"/>
            <Setter Property="Foreground" Value="#0D0D11"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Height" Value="38"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="RenderTransformOrigin" Value="0.5,0.5"/>
            <Setter Property="RenderTransform">
                <Setter.Value>
                    <ScaleTransform ScaleX="1.0" ScaleY="1.0"/>
                </Setter.Value>
            </Setter>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid SnapsToDevicePixels="True">
                            <Border x:Name="glow" CornerRadius="8" Background="#9bff00" Opacity="0">
                                <Border.Effect>
                                    <DropShadowEffect Color="#9bff00" BlurRadius="14" ShadowDepth="0" Opacity="0.5"/>
                                </Border.Effect>
                            </Border>
                            <Border x:Name="bdr" Background="{TemplateBinding Background}" CornerRadius="8" SnapsToDevicePixels="True">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                                  RecognizesAccessKey="False" SnapsToDevicePixels="True"/>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="glow" Property="Opacity" Value="1"/>
                                <Setter TargetName="bdr" Property="Background" Value="#B4FF33"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="glow" Property="Opacity" Value="0.3"/>
                                <Setter TargetName="bdr" Property="Background" Value="#82DE00"/>
                                <Setter Property="RenderTransform">
                                    <Setter.Value>
                                        <ScaleTransform ScaleX="0.96" ScaleY="0.96"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="BtnSecondary" TargetType="Button">
            <Setter Property="Background" Value="#252532"/>
            <Setter Property="Foreground" Value="#D5D5E2"/>
            <Setter Property="BorderBrush" Value="#3D3D52"/>
            <Setter Property="BorderThickness" Value="1.5"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Height" Value="38"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="RenderTransformOrigin" Value="0.5,0.5"/>
            <Setter Property="RenderTransform">
                <Setter.Value>
                    <ScaleTransform ScaleX="1.0" ScaleY="1.0"/>
                </Setter.Value>
            </Setter>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid SnapsToDevicePixels="True">
                            <Border x:Name="glow" CornerRadius="8" Background="#1C2914" Opacity="0">
                                <Border.Effect>
                                    <DropShadowEffect Color="#9bff00" BlurRadius="10" ShadowDepth="0" Opacity="0.35"/>
                                </Border.Effect>
                            </Border>
                            <Border x:Name="bdr" Background="{TemplateBinding Background}" CornerRadius="8" 
                                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" SnapsToDevicePixels="True">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                                  RecognizesAccessKey="False" SnapsToDevicePixels="True"/>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="glow" Property="Opacity" Value="1"/>
                                <Setter TargetName="bdr" Property="BorderBrush" Value="#9bff00"/>
                                <Setter TargetName="bdr" Property="Background" Value="#1C2914"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="glow" Property="Opacity" Value="0.2"/>
                                <Setter TargetName="bdr" Property="Background" Value="#141E0F"/>
                                <Setter Property="RenderTransform">
                                    <Setter.Value>
                                        <ScaleTransform ScaleX="0.96" ScaleY="0.96"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <Window.Triggers>
        <EventTrigger RoutedEvent="Window.Loaded">
            <BeginStoryboard>
                <Storyboard>
                    <DoubleAnimation Storyboard.TargetName="RootScale" Storyboard.TargetProperty="ScaleX"
                                     From="0.70" To="1.0" Duration="0:0:0.75">
                        <DoubleAnimation.EasingFunction>
                            <CubicEase EasingMode="EaseOut"/>
                        </DoubleAnimation.EasingFunction>
                    </DoubleAnimation>
                    <DoubleAnimation Storyboard.TargetName="RootScale" Storyboard.TargetProperty="ScaleY"
                                     From="0.70" To="1.0" Duration="0:0:0.75">
                        <DoubleAnimation.EasingFunction>
                            <CubicEase EasingMode="EaseOut"/>
                        </DoubleAnimation.EasingFunction>
                    </DoubleAnimation>
                    <DoubleAnimation Storyboard.TargetProperty="Opacity"
                                     From="0.0" To="1.0" Duration="0:0:0.75">
                        <DoubleAnimation.EasingFunction>
                            <QuadraticEase EasingMode="EaseOut"/>
                        </DoubleAnimation.EasingFunction>
                    </DoubleAnimation>
                </Storyboard>
            </BeginStoryboard>
        </EventTrigger>
    </Window.Triggers>
    <Border Name="RootBorder" Background="#1C1C22" CornerRadius="14" BorderBrush="#363645" BorderThickness="1.5" RenderTransformOrigin="0.5,0.5">
        <Border.RenderTransform>
            <ScaleTransform x:Name="RootScale" ScaleX="0.70" ScaleY="0.70"/>
        </Border.RenderTransform>
        <Border.Effect>
            <DropShadowEffect Color="#000000" BlurRadius="28" ShadowDepth="4" Opacity="0.65"/>
        </Border.Effect>
        <Grid Margin="24,20,24,20">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <!-- Header -->
            <StackPanel Grid.Row="0" Orientation="Horizontal">
                <Border Width="38" Height="38" CornerRadius="19" Background="#1C2C05" Margin="0,0,14,0">
                    <TextBlock Text="AC" FontSize="14" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center" Foreground="#9bff00" FontFamily="Segoe UI Variable Display, Segoe UI"/>
                </Border>
                <StackPanel VerticalAlignment="Center">
                    <TextBlock Text="Apply AC Config" FontSize="17" FontWeight="SemiBold" Foreground="#FFFFFF" FontFamily="Segoe UI Variable Display, Segoe UI"/>
                    <TextBlock Text="144Hz | 70% Brightness | Startup Apps" FontSize="12" Foreground="#8F8FA4" Margin="0,2,0,0"/>
                </StackPanel>
            </StackPanel>

            <!-- Body Message -->
            <TextBlock Grid.Row="1" Text="Launch apps and turn on everything?" 
                       TextWrapping="Wrap" FontSize="14" Foreground="#D5D5E2" Margin="0,12,0,8" VerticalAlignment="Center" LineHeight="18"/>

            <!-- Progress Bar -->
            <ProgressBar Grid.Row="2" Name="CountdownProgress" Height="4" Value="100" Minimum="0" Maximum="100" 
                         Foreground="#9bff00" Background="#2A2A38" BorderThickness="0" Margin="0,0,0,16"/>

            <!-- Action Buttons -->
            <Grid Grid.Row="3">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="12"/>
                    <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>

                <Button Grid.Column="0" Name="BtnApply" Style="{StaticResource BtnPrimary}">
                    <TextBlock Name="TxtApply" Text="Apply (60s)"/>
                </Button>

                <Button Grid.Column="2" Name="BtnCancel" Style="{StaticResource BtnSecondary}" Content="Don't Apply"/>
            </Grid>
        </Grid>
    </Border>
</Window>
'@
			$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
			$window = [System.Windows.Markup.XamlReader]::Load($reader)

			$rootBorder = $window.FindName("RootBorder")
			$rootScale = $window.FindName("RootScale")
			$btnApply = $window.FindName("BtnApply")
			$btnCancel = $window.FindName("BtnCancel")
			$progress = $window.FindName("CountdownProgress")
			$txtApply = $window.FindName("TxtApply")

			$window.Add_MouseLeftButtonDown({ $window.DragMove() })

			# Handle PrintScreen so Lightshot triggers even if this elevated window has focus
			$window.Add_PreviewKeyDown({
				param($s, $e)
				if ($e.Key -eq [System.Windows.Input.Key]::Snapshot -or $e.SystemKey -eq [System.Windows.Input.Key]::Snapshot) {
					$e.Handled = $true
					[User32]::SetForegroundWindow([User32]::GetDesktopWindow()) | Out-Null
					$lsPath = "C:\Program Files (x86)\Skillbrains\lightshot\5.5.0.7\Lightshot.exe"
					if (Test-Path $lsPath) {
						Start-Process -FilePath $lsPath -ErrorAction SilentlyContinue
					} else {
						[User32]::keybd_event(0x2C, 0, 0, [UIntPtr]::Zero)
						[User32]::keybd_event(0x2C, 0, 2, [UIntPtr]::Zero)
					}
				}
			})

			# Set WS_EX_NOACTIVATE (0x08000000) and hook WM_MOUSEACTIVATE so clicks never steal focus from Lightshot / background apps
			$window.Add_SourceInitialized({
				try {
					$helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
					$exStyle = [User32]::GetWindowLong($helper.Handle, -20)
					[User32]::SetWindowLong($helper.Handle, -20, ($exStyle -bor 0x08000000)) | Out-Null
					$source = [System.Windows.Interop.HwndSource]::FromHwnd($helper.Handle)
					$source.AddHook({
						param($hwnd, $msg, $wParam, $lParam, [ref]$handled)
						if ($msg -eq 0x0021) { # WM_MOUSEACTIVATE
							$handled = $true
							return [IntPtr]3 # MA_NOACTIVATE: never steal focus on mouse clicks
						}
						return [IntPtr]::Zero
					})
				} catch {}
			})

			$script:remaining = $totalSeconds
			$txtApply.Text = "Apply ($($script:remaining)s)"

			$script:isClosing = $false
			$closeWithFade = {
				param($chosenAction)
				if ($script:isClosing) { return }
				$script:isClosing = $true
				$sharedData.Action = $chosenAction
				$timer.Stop()

				if ($chosenAction -eq "yes") {
					# High-Performance Overdrive / Power Surge exit animation!
					try {
						$rootBorder.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#9bff00")
						$glow = New-Object System.Windows.Media.Effects.DropShadowEffect
						$glow.Color = [System.Windows.Media.ColorConverter]::ConvertFromString("#9bff00")
						$glow.BlurRadius = 45
						$glow.ShadowDepth = 0
						$glow.Opacity = 0.9
						$rootBorder.Effect = $glow
					} catch {}

					# Pulse scale outward like a shockwave: 1.0 -> 1.07
					$scaleAnim = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 1.07, [System.Windows.Duration][TimeSpan]::FromMilliseconds(240))
					$scaleAnim.EasingFunction = New-Object System.Windows.Media.Animation.QuadraticEase -Property @{ EasingMode = "EaseIn" }
					$rootScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $scaleAnim)
					$rootScale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $scaleAnim)

					# Accelerate opacity fade: 1.0 -> 0.0
					$fadeAnim = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.0, [System.Windows.Duration][TimeSpan]::FromMilliseconds(240))
					$fadeAnim.EasingFunction = New-Object System.Windows.Media.Animation.QuadraticEase -Property @{ EasingMode = "EaseIn" }
					$fadeAnim.Add_Completed({
						$window.Close()
					})
					$window.BeginAnimation([System.Windows.Window]::OpacityProperty, $fadeAnim)
				}
				else {
					# Smooth normal fade out
					$fadeAnim = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.0, [System.Windows.Duration][TimeSpan]::FromMilliseconds(180))
					$fadeAnim.Add_Completed({
						$window.Close()
					})
					$window.BeginAnimation([System.Windows.Window]::OpacityProperty, $fadeAnim)
				}
			}

			$btnApply.Add_Click({
				& $closeWithFade "yes"
			})

			$btnCancel.Add_Click({
				& $closeWithFade "no"
			})

			$timer = New-Object System.Windows.Threading.DispatcherTimer
			$timer.Interval = [TimeSpan]::FromSeconds(1)
			$timer.Add_Tick({
				if ($sharedData.ShouldClose) {
					$timer.Stop()
					$window.Close()
					return
				}
				$script:remaining--
				if ($totalSeconds -gt 0) {
					$progress.Value = [double]($script:remaining / $totalSeconds) * 100
				}
				if ($script:remaining -le 0) {
					& $closeWithFade "yes"
				}
				else {
					$txtApply.Text = "Apply ($($script:remaining)s)"
				}
			})

			$window.Add_Closing({
				$timer.Stop()
				if ($sharedData.Action -eq "none") {
					$sharedData.Action = "no"
				}
			})

			$timer.Start()
			$frame = New-Object System.Windows.Threading.DispatcherFrame
			$window.Add_Closed({ $frame.Continue = $false })
			$window.Show()
			[System.Windows.Threading.Dispatcher]::PushFrame($frame)
		})

		$global:acPopupRunspace = $rs
		$global:acPopupPS = $ps
		$handle = $ps.BeginInvoke()
		Write-Host "[$(Get-Date)] Apply AC Config WPF popup shown (${CountdownSeconds}s countdown)"

		while (-not $handle.IsCompleted) {
			Start-Sleep -Milliseconds 100
			if ($global:currentState -eq 'Offline' -or [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -eq 'Offline') {
				Close-AcLaunchPopup
				break
			}
		}

		$action = $global:acPopupData.Action
		try { $rs.Dispose() } catch {}
		$global:acPopupRunspace = $null
		$global:acPopupPS = $null
		return $action
	}
	catch {
		Write-Host "[ERROR] $(Get-Date) - Show-AcLaunchPopup Error: $_"
		return "no"
	}
}

function Invoke-AppsLaunch {
	param($Apps)
	if (-not $Apps) { return }

	foreach ($app in $Apps) {
		if ($app.PSObject.Properties['Enabled'] -and $app.Enabled -eq $false) {
			Write-Host "SKIP: $($app.Name) is disabled in config"
			continue
		}

		# Abort remaining launches immediately if power was lost
		if ([System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -ne 'Online') {
			Write-Host "[$(Get-Date)] Power switched to battery during launch sequence. Aborting remaining app launches."
			break
		}

		try {
			$appPath = if ($app.Path) { [System.Environment]::ExpandEnvironmentVariables($app.Path) } else { "" }
			$targetAppPath = $appPath

			if ($app.Type -eq "UWP") {
				$pkg = Get-AppxPackage -Name "*$($app.Name)*" -ErrorAction SilentlyContinue
				if (-not $pkg -and $app.ProcessName) {
					$pkg = Get-AppxPackage -Name "*$($app.ProcessName)*" -ErrorAction SilentlyContinue
				}
				if ($pkg) {
					try {
						$manifest = Get-AppxPackageManifest $pkg -ErrorAction SilentlyContinue
						$appId = $manifest.Package.Applications.Application[0].Id
						if ($pkg.PackageFamilyName -and $appId) {
							$targetAppPath = "shell:AppsFolder\$($pkg.PackageFamilyName)!$appId"
						}
					}
					catch {}
				}
			}

			if ($app.Type -eq "URI" -or $app.Type -eq "UWP") {
				if ($app.ProcessName) {
					$existing = Get-Process -Name $app.ProcessName -ErrorAction SilentlyContinue
					if (-not $existing -and $app.ProcessName -like "*ModernFlyouts*") {
						$existing = Get-Process -Name "ModernFlyoutsHost" -ErrorAction SilentlyContinue
					}
					if ($existing) {
						Write-Host "SKIP: $($app.ProcessName) already running"
						continue
					}
				}
				Write-Host "Launching UWP/URI App: $targetAppPath"
				Start-Process "explorer.exe" -ArgumentList $targetAppPath

				# If ModernFlyouts opened its settings GUI, dismiss it automatically into the tray
				if ($app.Name -like "*ModernFlyouts*" -or $targetAppPath -like "*ModernFlyouts*") {
					Start-Sleep -Milliseconds 1800
					$mf = Get-Process -Name "ModernFlyoutsHost" -ErrorAction SilentlyContinue | Select-Object -First 1
					if ($mf -and $mf.MainWindowHandle -ne 0) {
						$mf.CloseMainWindow() | Out-Null
					}
				}
			}
			elseif ([string]::IsNullOrWhiteSpace($appPath)) {
				Write-Host "SKIP: $($app.Name) has empty path"
			}
			elseif (Test-Path $appPath) {
				# Check if process is already running — skip to avoid duplicate launch
				$processName = if ($app.ProcessName) { $app.ProcessName } else { [System.IO.Path]::GetFileNameWithoutExtension($appPath) }
				$existingProcess = Get-Process -Name $processName -ErrorAction SilentlyContinue
				if (-not $existingProcess -and $processName -like "*ModernFlyouts*") {
					$existingProcess = Get-Process -Name "ModernFlyoutsHost" -ErrorAction SilentlyContinue
				}
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

function Enable-BatteryMode {
	Write-Host "Entering Enable-BatteryMode"
	Set-BluetoothState -TargetState 'Off'
	Set-WindowsVisuals -Enable $false

	$batBrightness = if ($global:config.Settings.BatteryBrightness) { [int]$global:config.Settings.BatteryBrightness } else { 30 }
	$batHz = if ($global:config.Settings.BatteryRefreshRate) { [int]$global:config.Settings.BatteryRefreshRate } else { 60 }

	Set-DisplayBrightness -TargetBrightness $batBrightness
	Set-DisplayRefreshRate -TargetHz $batHz
    
	$toastParts = @()
	if (Test-FeatureEnabled -FeatureName "Bluetooth" -LegacySettingName "ManageBluetooth") { $toastParts += "Bluetooth OFF" }
	if (Test-FeatureEnabled -FeatureName "DisplayBrightness") { $toastParts += "Brightness $batBrightness%" }
	if (Test-FeatureEnabled -FeatureName "DisplayRefreshRate") { $toastParts += "$batHz Hz" }
	if (Test-FeatureEnabled -FeatureName "VisualEffects" -LegacySettingName "ManageVisualEffects") { $toastParts += "Visuals OFF" }
	if (Test-FeatureEnabled -FeatureName "CloseAppsOnBattery") { $toastParts += "Apps closed" }
	$toastText = if ($toastParts.Count -gt 0) { $toastParts -join " | " } else { "Eco mode active" }
	Show-InfoToast -Title "Apply Eco Config" -Text $toastText
	
	if (-not (Test-FeatureEnabled -FeatureName "CloseAppsOnBattery" -Default $true)) {
		Write-Host "[$(Get-Date)] CloseAppsOnBattery feature is disabled in config."
		return
	}

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

			# Immediately sweep away dead ghost icons from the system tray & overflow flyout
			Start-Sleep -Milliseconds 400
			[TrayRefresher]::RefreshTray()
		}
	}
}

# --- State Machine & Events ---
$global:currentState = [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus
# Synchronized hashtables for cross-runspace communication with the popups
$global:popupData = [System.Collections.Hashtable]::Synchronized(@{ Action = "none"; ShouldClose = $false })
$global:popupRunspace = $null
$global:popupPS = $null

$global:acPopupData = [System.Collections.Hashtable]::Synchronized(@{ Action = "none"; ShouldClose = $false })
$global:acPopupRunspace = $null
$global:acPopupPS = $null

$global:batteryTimer = New-Object System.Timers.Timer
$global:batteryTimer.AutoReset = $false # We trigger it manually for each step

Unregister-Event -SourceIdentifier "BatteryTimer" -ErrorAction SilentlyContinue
Register-ObjectEvent -InputObject $global:batteryTimer -EventName Elapsed -SourceIdentifier "BatteryTimer" -Action {
	if ($global:currentState -eq 'Online' -or [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -eq 'Online') { return }

	$popupSec = if ($global:config.Settings.BatteryPopupCountdownSeconds) { [int]$global:config.Settings.BatteryPopupCountdownSeconds } else { 60 }
	Write-Host "[$(Get-Date)] Battery pre-delay elapsed. Showing Apply Eco Config popup..."
	$action = Show-BatteryWarningPopup -CountdownSeconds $popupSec

	if ($global:currentState -eq 'Online' -or [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -eq 'Online') {
		Write-Host "[$(Get-Date)] Power restored to AC during popup. Skipping Eco mode."
		return
	}

	if ($action -eq "yes") {
		Write-Host "[$(Get-Date)] Eco Config confirmed (or countdown elapsed) - applying Eco mode."
		Enable-BatteryMode
	}
	else {
		Write-Host "[$(Get-Date)] Eco Config canceled by user ('Don't Apply')."
	}
} | Out-Null

function Invoke-BatterySequence {
	Write-Host "Entering Invoke-BatterySequence"
	$popupEnabled = Test-FeatureEnabled -FeatureName "BatteryWarningPopup" -Default $true
	if (-not $popupEnabled) {
		Write-Host "[$(Get-Date)] Battery warning popup is disabled. Enabling battery mode immediately."
		Enable-BatteryMode
		return
	}
	$prePopup = if ($global:config.Settings.BatteryPrePopupDelaySeconds) { [int]$global:config.Settings.BatteryPrePopupDelaySeconds * 1000 } else { 20000 }
	$global:popupData.Action = "none"
	$global:popupData.ShouldClose = $false
	$global:batteryTimer.Interval = $prePopup
	$global:batteryTimer.Start()
	Write-Host "[$(Get-Date)] Battery pre-popup timer started ($($global:config.Settings.BatteryPrePopupDelaySeconds)s delay)"
}

# Register Power Event Monitor immediately so power state transitions during startup are tracked
Unregister-Event -SourceIdentifier "PowerMonitor" -ErrorAction SilentlyContinue
Register-WmiEvent -Query "SELECT * FROM Win32_PowerManagementEvent WHERE EventType = 10" -SourceIdentifier "PowerMonitor" -Action {
	$status = [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus
	if ($status -eq 'Offline' -and $global:currentState -eq 'Online') {
		Write-Host "[$(Get-Date)] MODE SWITCH: AC -> Battery"
		$global:currentState = 'Offline'
		Close-AcLaunchPopup
		Invoke-BatterySequence
	}
	elseif ($status -eq 'Online' -and $global:currentState -eq 'Offline') {
		Write-Host "[$(Get-Date)] MODE SWITCH: Battery -> AC"
		$global:currentState = 'Online'
		$global:batteryTimer.Stop()
		Close-BatteryPopup
		Enable-AcMode
	}
} | Out-Null

# Initial Startup Delay
$initialDelay = if ($global:config.Settings.InitialStartupDelaySeconds) { [int]$global:config.Settings.InitialStartupDelaySeconds } else { 15 }
if ($initialDelay -gt 0) {
	Write-Host "[$(Get-Date)] Waiting initial startup delay: $initialDelay seconds..."
	Start-Sleep -Seconds $initialDelay
}

# Re-evaluate live power status after initial delay
$global:currentState = [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus

if ($global:currentState -eq 'Online') {
	Write-Host "Configuration Name: AC Power"
	$skipOnBoot = Test-FeatureEnabled -FeatureName "SkipAcPopupOnBoot" -Default $true
	$isFreshBoot = $false
	if ($skipOnBoot) {
		try {
			$uptime = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
			# If system uptime is less than 15 minutes, this is a fresh system boot / power-on
			if ($uptime.TotalMinutes -lt 15) {
				$isFreshBoot = $true
				Write-Host "[$(Get-Date)] Fresh boot detected (Uptime: $([int]$uptime.TotalMinutes)m $([int]$uptime.Seconds)s). Skipping AC confirmation popup."
			}
		}
		catch {
			$isFreshBoot = $true
		}
	}

	if ($isFreshBoot) {
		Enable-AcMode -SkipPopup
	}
	else {
		Enable-AcMode
	}
}
else {
	Write-Host "Configuration Name: Battery Power"
	Enable-BatteryMode
}

# Keep script alive to process events and timers
while ($true) {
	Wait-Event -Timeout 5
}