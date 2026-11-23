# Collects Nebula on the Ship game records into records.js for viewer.html.
# Also keeps a backup copy of every record in .\backup so old games survive even if the mod deletes them.
# While Among Us (NoS) is running, it also saves the minimap images from Nebula's local server into assets.js.
param(
  [string]$Src = (Join-Path $env:USERPROFILE 'AppData\LocalLow\Innersloth\Among Us\NebulaOnTheShip\GameRecords'),
  [string]$GameDir = 'C:\Program Files (x86)\Steam\steamapps\common\Among Us NoS'
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$here = $PSScriptRoot
$backup = Join-Path $here 'backup'
New-Item -ItemType Directory -Force $backup | Out-Null
$utf8 = New-Object Text.UTF8Encoding $false

# ---- game records ----
$copied = 0
if (Test-Path $Src) {
  $srcRoot = (Resolve-Path $Src).Path
  foreach ($f in Get-ChildItem $srcRoot -Recurse -File -Filter *.json) {
    $marked = $f.DirectoryName -ne $srcRoot
    $destDir = if ($marked) { Join-Path $backup 'Marked' } else { $backup }
    New-Item -ItemType Directory -Force $destDir | Out-Null
    $dest = Join-Path $destDir $f.Name
    # A game marked later: drop the old unmarked copy so it counts as marked
    $plainCopy = Join-Path $backup $f.Name
    if ($marked -and (Test-Path $plainCopy)) { Remove-Item $plainCopy -Force }
    # A game unmarked in-game: drop the marked copy so it counts as unmarked
    $markedCopy = Join-Path (Join-Path $backup 'Marked') $f.Name
    if (-not $marked -and (Test-Path $markedCopy)) { Move-Item $markedCopy $dest -Force }
    if (-not (Test-Path $dest) -or (Get-Item $dest).Length -ne $f.Length) {
      Copy-Item $f.FullName $dest -Force
      $copied++
    }
  }
} else {
  Write-Host "Record folder not found: $Src (using backup only)"
}

# ---- viewer settings (names, marks, hidden games...) ----
# The viewer keeps its settings inside the browser. A file made with "export settings" is copied into
# .\backup\settings so it is backed up with the games, and the viewer loads it automatically in a new browser.
# Sources: this folder and the Downloads folder (nos-viewer-settings*.json). The newest file wins.
$setDir = Join-Path $backup 'settings'
$setFile = Join-Path $setDir 'nos-viewer-settings.json'
$downloads = $null
try { $downloads = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}' } catch {}
if ($downloads) { $downloads = [Environment]::ExpandEnvironmentVariables($downloads) } else { $downloads = Join-Path $env:USERPROFILE 'Downloads' }
$cands = @()
foreach ($d in @($here, $downloads)) {
  if ($d -and (Test-Path $d)) { $cands += @(Get-ChildItem $d -File -Filter 'nos-viewer-settings*.json' -ErrorAction SilentlyContinue) }
}
$newest = $cands | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($newest -and (-not (Test-Path $setFile) -or $newest.LastWriteTime -gt (Get-Item $setFile).LastWriteTime)) {
  $t = [IO.File]::ReadAllText($newest.FullName, [Text.Encoding]::UTF8)
  if ($t -match '"app"\s*:\s*"nos-record-viewer"' -and $t -match '"kind"\s*:\s*"settings"') {
    New-Item -ItemType Directory -Force $setDir | Out-Null
    Copy-Item $newest.FullName $setFile -Force
    (Get-Item $setFile).LastWriteTime = $newest.LastWriteTime
    Write-Host "settings: saved $($newest.Name) to backup\settings"
  }
}

$seen = @{}
$sb = New-Object System.Text.StringBuilder
if (Test-Path $setFile) {
  $t = [IO.File]::ReadAllText($setFile, [Text.Encoding]::UTF8).Trim().TrimStart([char]0xFEFF)
  if ($t.StartsWith('{')) { [void]$sb.Append("window.__NOS_SETTINGS__=" + $t + ";`n") }
}
[void]$sb.Append("window.__NOS_RECORDS__=[`n")
$n = 0
foreach ($f in Get-ChildItem $backup -Recurse -File -Filter *.json | Where-Object { $_.DirectoryName -ne $setDir } | Sort-Object Name) {
  $txt = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8).Trim()
  if (-not $txt.StartsWith('{')) { continue }
  $marked = $f.DirectoryName -ne $backup
  if ($seen.ContainsKey($f.Name)) { continue }
  $seen[$f.Name] = $true
  if ($n -gt 0) { [void]$sb.Append(",`n") }
  [void]$sb.Append('{"file":' + (ConvertTo-Json $f.Name) + ',"marked":' + $marked.ToString().ToLower() + ',"data":' + $txt + '}')
  $n++
}
[void]$sb.Append("`n];`n")
[IO.File]::WriteAllText((Join-Path $here 'records.js'), $sb.ToString(), $utf8)
Write-Host "records.js: $n games ($copied new/updated files backed up)"

# ---- minimap images (only while the game is running) ----
$howTo = 'To save map images: in Among Us (NoS), play one game to the results screen, then run open-viewer.cmd again WITHOUT closing the game.'

# Plain HTTP GET to the local Nebula server (no proxy, short timeout)
function Get-Local([string]$url, [int]$timeoutMs, [switch]$Bytes) {
  $req = [System.Net.HttpWebRequest]::Create($url)
  $req.Proxy = $null
  $req.Timeout = $timeoutMs
  $req.ReadWriteTimeout = $timeoutMs
  $res = $req.GetResponse()
  try {
    $ms = New-Object IO.MemoryStream
    $res.GetResponseStream().CopyTo($ms)
    $data = $ms.ToArray()
    if ($Bytes) { return ,$data }
    return [Text.Encoding]::UTF8.GetString($data)
  } finally { $res.Close() }
}

# Where is the game? 1) the running Among Us process  2) -GameDir  3) Steam libraries with Nebula installed
$dirs = New-Object System.Collections.Generic.List[string]
foreach ($p in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -eq 'Among Us' })) {
  try { if ($p.Path) { $dirs.Add((Split-Path $p.Path)) } } catch {}
}
$dirs.Add($GameDir)
foreach ($vdf in @((Join-Path ${env:ProgramFiles(x86)} 'Steam\steamapps\libraryfolders.vdf'), (Join-Path $env:ProgramFiles 'Steam\steamapps\libraryfolders.vdf'))) {
  if (-not (Test-Path $vdf)) { continue }
  foreach ($m in @(Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"')) {
    $common = Join-Path ($m.Matches[0].Groups[1].Value -replace '\\\\', '\') 'steamapps\common'
    foreach ($c in @(Get-ChildItem $common -Directory -ErrorAction SilentlyContinue)) {
      if (Test-Path (Join-Path $c.FullName 'BepInEx\nebula')) { $dirs.Add($c.FullName) }
    }
  }
}
$dirs = @($dirs | Where-Object { $_ } | Select-Object -Unique)

# Which port? From the game logs first, then Nebula's usual ports
$ports = New-Object System.Collections.Generic.List[int]
foreach ($d in $dirs) {
  foreach ($log in @((Join-Path $d 'BepInEx\LogOutput.log'), (Join-Path $d 'NebulaLog.txt'))) {
    if (-not (Test-Path $log)) { continue }
    try {
      $m = Select-String -Path $log -Pattern 'Started\. http://127\.0\.0\.1:(\d+)/' | Select-Object -Last 1
      if ($m) { $ports.Add([int]$m.Matches[0].Groups[1].Value) }
    } catch {}
  }
}
foreach ($p in 27100..27110) { $ports.Add($p) }
$ports = @($ports | Select-Object -Unique)

$base = $null; $mapsJson = $null
foreach ($p in $ports) {
  try {
    $txt = Get-Local "http://127.0.0.1:$p/api/maps" 2000
    $null = $txt | ConvertFrom-Json
    $base = "http://127.0.0.1:$p"; $mapsJson = $txt; break
  } catch {}
}
if (-not $base) {
  if ($dirs.Count -gt 0) { Write-Host ('Game folder(s) checked: ' + ($dirs -join ' | ')) }
  if (Test-Path (Join-Path $here 'assets.js')) { Write-Host 'assets.js: Nebula server not found, keeping the saved map images' }
  else { Write-Host 'assets.js: Nebula server not found (no map images yet)'; Write-Host $howTo }
  return
}
Write-Host "Nebula server: $base"
$images = @{}
foreach ($m in ($mapsJson | ConvertFrom-Json)) {
  $key = "$($m.mapId)-$($m.inMapId)"
  try {
    $bytes = Get-Local "$base/maps/$key.png" 20000 -Bytes
    $images[$key] = 'data:image/png;base64,' + [Convert]::ToBase64String($bytes)
  } catch { Write-Host "  map $key failed: $($_.Exception.Message)" }
}
$objJson = 'null'; $objPng = $null
try {
  $objJson = Get-Local "$base/api/map-objects" 5000
  $objPng = 'data:image/png;base64,' + [Convert]::ToBase64String((Get-Local "$base/map-objects.png" 20000 -Bytes))
} catch { Write-Host "  map objects failed: $($_.Exception.Message)" }
if ($images.Count -eq 0) {
  Write-Host 'assets.js: could not download any map image (kept the old file)'
  return
}

$a = New-Object System.Text.StringBuilder
[void]$a.Append('window.__NOS_ASSETS__={"maps":' + $mapsJson + ',"mapObjects":' + $objJson + ',"mapObjectsImage":' + (ConvertTo-Json $objPng) + ',"images":{')
$first = $true
foreach ($k in $images.Keys) {
  if (-not $first) { [void]$a.Append(',') }
  $first = $false
  [void]$a.Append((ConvertTo-Json $k) + ':' + (ConvertTo-Json $images[$k]))
}
[void]$a.Append("}};`n")
[IO.File]::WriteAllText((Join-Path $here 'assets.js'), $a.ToString(), $utf8)
Write-Host "assets.js: $($images.Count) minimap images saved"
