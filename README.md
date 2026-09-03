# ⚡ Windows Startup & Battery Automator 🔋

A custom smart automation script for Windows 10/11 that dynamically adapts your system configuration, visual effects, and background applications depending on the current power source (**AC Power 🔌** vs **Battery Power 🔋**).

---

## 🌟 Key Features 

### 🔌 AC Power Mode (Plugged In)
- 📶 **Bluetooth Management:** Automatically powers on Bluetooth.
- ✨ **Visual Effects:** Re-enables window animations and Windows transparency effects for a full aesthetic experience.
- 🚀 **App Launcher:** Launches your favorite background apps (Standard `.exe`, UWP/Store apps, or launched as standard user).
- 📥 **Tray Minimization:** Automatically minimizes supported applications to the system tray (e.g., Telegram) right after startup.
- 🔔 **Toast Notifications:** Sends native Windows notifications informing you when AC mode is active.

### 🔋 Battery Power Mode (On Battery)
- ⏰ **Interactive Warning Popup:** Displays a sleek dark-mode countdown dialog before taking action:
  - 💤 **Snooze for 5 min:** Temporarily delay power-saving mode.
  - ⏸️ **Postpone until plugged in:** Keeps apps and Bluetooth running until you plug back into AC power.
  - ⏳ **Auto-apply:** Automatically switches when the countdown expires.
- 📴 **Bluetooth Optimization:** Automatically turns off Bluetooth to conserve energy.
- 🍃 **Performance Boost:** Disables visual effects and animations to reduce GPU and CPU power draw.
- 🛑 **Graceful App Termination:** Sends a graceful close request to configured heavy background processes, followed by force-termination if they do not exit in time.

---

## ⚙️ Configuration (`config.json`) 🛠️

The script automatically reads [config.json](config.json) located in the same directory. If `config.json` is not found, it gracefully falls back to [config.example.json](config.example.json) or built-in default values.

### 📝 Sample `config.json`:

```json
{
  "Settings": {
    "InitialStartupDelaySeconds": 15,
    "BatteryPrePopupDelaySeconds": 20,
    "BatteryPopupCountdownSeconds": 60,
    "SnoozeDurationMinutes": 5,
    "ManageBluetooth": true,
    "ManageVisualEffects": true,
    "ShowToastNotifications": true,
    "LogPath": "%TEMP%\\SmartStartup_log.txt"
  },
  "AcMode": {
    "AppsToLaunch": [
      {
        "Name": "Wallpaper Engine",
        "Path": "%ProgramFiles(x86)%\\Steam\\steamapps\\common\\wallpaper_engine\\wallpaper64.exe",
        "Args": "",
        "Type": "Exe",
        "ProcessName": "wallpaper64",
        "RunAsUser": false,
        "MinimizeToTray": false
      },
      {
        "Name": "ModernFlyouts",
        "Path": "shell:AppsFolder\\32669SamG.ModernFlyouts_pcy8vm99wrpcg!App",
        "Args": "",
        "Type": "UWP",
        "ProcessName": "ModernFlyouts",
        "RunAsUser": false,
        "MinimizeToTray": false
      },
      {
        "Name": "Telegram",
        "Path": "%APPDATA%\\Telegram Desktop\\Telegram.exe",
        "Args": "-startintray",
        "Type": "Exe",
        "ProcessName": "Telegram",
        "RunAsUser": true,
        "MinimizeToTray": true
      }
    ]
  },
  "BatteryMode": {
    "ProcessesToClose": [
      "*wallpaper*",
      "*ModernFlyouts*",
      "*LangOver*",
      "*Telegram*",
      "*PowerToys*"
    ],
    "GracefulCloseTimeoutSeconds": 3
  }
}
```

---

## 📖 Configuration Reference

### 🔧 Settings
| Parameter | Type | Description |
| :--- | :---: | :--- |
| ⏱️&nbsp;`InitialStartupDelaySeconds` | `int` | Delay after script startup before applying initial state (in seconds). |
| ⏳&nbsp;`BatteryPrePopupDelaySeconds` | `int` | Buffer time after unplugging before showing the warning dialog (in seconds). |
| ⏲️&nbsp;`BatteryPopupCountdownSeconds` | `int` | Duration of the countdown timer in the battery warning dialog (in seconds). |
| 💤&nbsp;`SnoozeDurationMinutes` | `int` | Time to wait before showing the popup again when "Snooze" is clicked (in minutes). |
| 📶&nbsp;`ManageBluetooth` | `bool` | Whether to toggle Bluetooth on AC/Battery power state changes (`true` / `false`). |
| ✨&nbsp;`ManageVisualEffects` | `bool` | Whether to toggle Windows transparency and animations (`true` / `false`). |
| 🔔&nbsp;`ShowToastNotifications` | `bool` | Whether to show native Windows toast notifications (`true` / `false`). |
| 📄&nbsp;`LogPath` | `string` | Path to session log file. Supports environment variables (e.g., `%TEMP%`). |

### 🚀 AcMode.AppsToLaunch
| Parameter | Type | Description |
| :--- | :---: | :--- |
| 🏷️&nbsp;`Name` | `string` | Friendly name of the application. |
| 📁&nbsp;`Path` | `string` | Executable path, shell URI, or Store URI. Supports environment variables. |
| 💬&nbsp;`Args` | `string` | Command line arguments passed when launching the app. |
| 🧩&nbsp;`Type` | `string` | Launch mechanism: `"Exe"`, `"UWP"`, or `"URI"`. |
| 🔍&nbsp;`ProcessName` | `string` | Process name to check if the app is already running (prevents duplicates). |
| 👤&nbsp;`RunAsUser` | `bool` | Launches via Windows Explorer shell to run as standard user when running elevated. |
| 📥&nbsp;`MinimizeToTray` | `bool` | Automatically sends a window close message to minimize the app into the tray. |

### 🔋 BatteryMode
| Parameter | Type | Description |
| :--- | :---: | :--- |
| 🛑&nbsp;`ProcessesToClose` | `array` | List of process name patterns to terminate (supports wildcards, e.g. `*Telegram*`). |
| ⏳&nbsp;`GracefulCloseTimeoutSeconds` | `int` | Seconds to wait for graceful exit before forcing process termination. |

---

## 🛠️ Getting Started & Autostart 

### 🏃 Quick Run

`powershell.exe -ExecutionPolicy Bypass -File .\startUpScript.ps1`

### ⏰ Autostart via Windows Task Scheduler
To have the script run quietly in the background on system startup:

1. 🔍 Press <kbd>Win</kbd> + <kbd>R</kbd>, type `taskschd.msc`, and press **Enter**.
2. ➕ Click **Create Task...** in the Actions panel.
3. 📌 **General Tab:**
   - **Name:** `Windows Startup & Battery Automator`
   - Check **Run with highest privileges** 🛡️.
4. ⏰ **Triggers Tab:**
   - Click **New...** and select **At log on** (or **At startup**).
5. ⚡ **Actions Tab:**
   - Click **New...**
   - **Action:** `Start a program`
   - **Program/script:** `powershell.exe`
   - **Add arguments:** `-WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\Path\To\startUpScript.ps1"`
   - **Start in:** `C:\Path\To\` *(Folder containing your script and `config.json`)*
6. 🔋 **Conditions Tab:**
   - Uncheck **Start the task only if the computer is on AC power** (so it starts even when on battery).
7. ✅ Click **OK** to save and activate the task!

---

## 📋 Requirements

- 🪟 Windows 10 or Windows 11 (64-bit)
- 💻 Windows PowerShell 5.1 (built into Windows 10/11)
- 🔓 PowerShell script execution allowed (`-ExecutionPolicy Bypass`)
