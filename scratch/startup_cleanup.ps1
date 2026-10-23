# Startup cleanup (reversible)
#
# Usage (run in PowerShell; tasks/HKLM need an ADMIN shell):
#   .\startup_cleanup.ps1 -List      # show current state
#   .\startup_cleanup.ps1            # DRY RUN: show what would change
#   .\startup_cleanup.ps1 -Apply     # apply (disable picked items)
#   .\startup_cleanup.ps1 -Restore   # re-enable everything listed below
#
# How it works:
#   - Run keys / Startup folder: uses the SAME mechanism as Task Manager
#     (Explorer\StartupApproved 12-byte flag). Nothing is deleted -> fully reversible.
#   - Scheduled tasks: Disable-ScheduledTask / Enable-ScheduledTask.
#
# Nothing is uninstalled and no registry value is removed.

param(
  [switch]$Apply,
  [switch]$Restore,
  [switch]$List
)

# ===================== EDIT ONLY THIS BLOCK =====================
# Task names: "TaskName" for root folder, or "Folder\TaskName".
$DisableTasks = @(
  'cua-driver-serve',                                 # Cua driver daemon: opens the blank PowerShell window at logon
  'DouyinUser\DouyinGuard\LaunchDouyinGuard',         # Douyin guard (douyin background processes)
  'WpsUpdateTask_20763',                              # WPS Office update check
  'WpsUpdateLogonTask_20763',                         # WPS Office update check (logon variant)
  'WpsWakeWnsLogonTask'                               # WPS push-message wake task
  ,'GoogleUser\GoogleUpdater\GoogleUpdaterTaskUser157.0.8089.0{6F1EF25F-69A7-428E-9A77-6986846EEB92}'
)

# HKCU Run values (no admin needed)
$DisableRunHKCU = @(
  'MicrosoftEdgeAutoLaunch_B93BF4BB9464309445AF07651450AB6C',  # Edge auto-launch (only enabled one left)
  'Gemini',                                                    # Google Gemini launcher
  'QQNT',                                                      # QQ (keep if you want it in tray at boot)
  'Weixin'                                                     # WeChat
)

# Startup folder items (.lnk names, no admin needed)
$DisableStartupFolder = @(
  'Ollama.lnk',        # Ollama local model server (KEEP if DeepSeek Harness needs it)
  'UserRecall.lnk'     # Tonghuashun (ths) background news/quote fetcher
)

# HKLM Run values (ADMIN needed)
$DisableRunHKLM = @(
  'Autodesk Access Service'   # Autodesk update helper
)

# HKLM 32-bit Run values (ADMIN needed) - uses ...\StartupApproved\Run32
$DisableRunHKLM32 = @(
  'D4Svr_ICBC.exe'            # ICBC bank USB-key helper (C:\Program Files (x86)\ICBCEbankTools\...)
)
# ================================================================

$ErrorActionPreference = 'Continue'

$runHkcu = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$folder  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder'
$runHklm = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$runHklm32 = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run32'

$off = [byte[]](3,0,0,0,0,0,0,0,0,0,0,0)
$on  = [byte[]](2,0,0,0,0,0,0,0,0,0,0,0)

function Get-State($key, $name) {
  if (-not (Test-Path $key)) { return 'absent' }
  try { $v = (Get-ItemProperty -Path $key -Name $name -ErrorAction Stop).$name } catch { return 'absent' }
  if ($v -is [byte[]] -and $v.Length -ge 1) {
    if ($v[0] -eq 3) { return 'disabled' }
    return 'enabled'
  }
  return 'unknown'
}

function Set-Approval($key, $name, [byte[]]$flag, [string]$label) {
  $cur = Get-State $key $name
  $want = 'enabled'; if ($flag[0] -eq 3) { $want = 'disabled' }
  if ($List) {
    '  {0,-52} {1,-30} {2}' -f $label, $name, $cur
    return
  }
  if ($cur -eq $want) {
    '  [skip] {0}: already {1}' -f $name, $want
    return
  }
  if (-not ($Apply -or $Restore)) {
    '  [dry]  {0}: {1} -> {2}' -f $name, $cur, $want
    return
  }
  if (-not (Test-Path $key)) {
    try { New-Item -Path $key -Force | Out-Null } catch { '  [fail] cannot create key {0}: {1}' -f $key, $_.Exception.Message; return }
  }
  try {
    New-ItemProperty -Path $key -Name $name -Value $flag -PropertyType Binary -Force | Out-Null
    '  [ok]   {0} -> {1}' -f $name, $want
  } catch {
    '  [fail] {0}: {1}' -f $name, $_.Exception.Message
  }
}

function Set-TaskState($full, [string]$want) {
  $path = '\'; $nm = $full
  $i = $full.LastIndexOf('\')
  if ($i -ge 0) { $path = $full.Substring(0, $i + 1); $nm = $full.Substring($i + 1) }
  if (-not $path.StartsWith('\')) { $path = '\' + $path }   # TaskPath must start with a backslash
  $t = $null
  try { $t = Get-ScheduledTask -TaskPath $path -TaskName $nm -ErrorAction Stop } catch { $t = $null }
  if (-not $t) { '  [skip] task not found: {0}{1}' -f $path, $nm; return }
  if ($List) { '  {0,-52} {1,-30} {2}' -f ('task ' + $path), $nm, $t.State; return }
  $isDisabled = ($t.State -eq 'Disabled')
  if ($want -eq 'disabled' -and $isDisabled) { '  [skip] task {0}: already disabled' -f $nm; return }
  if ($want -eq 'enabled' -and -not $isDisabled) { '  [skip] task {0}: already enabled' -f $nm; return }
  if (-not ($Apply -or $Restore)) { '  [dry]  task {0}: {1} -> {2}' -f $nm, $t.State, $want; return }
  try {
    if ($want -eq 'disabled') { Disable-ScheduledTask -TaskPath $path -TaskName $nm | Out-Null }
    else { Enable-ScheduledTask -TaskPath $path -TaskName $nm | Out-Null }
    '  [ok]   task {0} -> {1}' -f $nm, $want
  } catch {
    '  [fail] task {0}: {1}' -f $nm, $_.Exception.Message
  }
}

$flag = $off
$taskWant = 'disabled'
$mode = 'DRY RUN (nothing changed)'
if ($List) { $mode = 'LIST' }
if ($Apply) { $mode = 'APPLY'; }
if ($Restore) { $flag = $on; $taskWant = 'enabled'; $mode = 'RESTORE' }

'=== startup_cleanup: {0} ===' -f $mode
''
'[HKCU Run]'
foreach ($n in $DisableRunHKCU) { Set-Approval $runHkcu $n $flag '' }
'[Startup folder]'
foreach ($n in $DisableStartupFolder) { Set-Approval $folder $n $flag '' }
'[HKLM Run]  (needs admin)'
foreach ($n in $DisableRunHKLM) { Set-Approval $runHklm $n $flag '' }
'[HKLM Run32]  (needs admin)'
foreach ($n in $DisableRunHKLM32) { Set-Approval $runHklm32 $n $flag '' }
'[Scheduled tasks]  (needs admin)'
foreach ($t in $DisableTasks) { Set-TaskState $t $taskWant }
''
if (-not ($Apply -or $Restore) -and -not $List) {
  'Dry run only. Re-run with -Apply to change, or -Restore to re-enable.'
}
'Done.'
