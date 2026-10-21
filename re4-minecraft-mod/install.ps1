# Installs or updates the RE4 Minecraft mod:
# puts the Minecraft mod in your CurseForge profile, and copies the RE4 scripts and overlay plugin.
# Uses the ready-made files in prebuilt\ (no Java needed); builds the Minecraft mod only if they are missing.
# Run it with install.bat (double-click). Folders it finds are remembered in install-paths.txt.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$pathsFile = Join-Path $here 'install-paths.txt'
$re4FolderName = 'RESIDENT EVIL 4  BIOHAZARD RE4'

function Step($text) { Write-Host ''; Write-Host "== $text" -ForegroundColor Cyan }
function Ok($text) { Write-Host "   $text" -ForegroundColor Green }
function Fail($text) {
    Write-Host ''
    Write-Host "PROBLEM: $text" -ForegroundColor Red
    exit 1
}

# Remembered folders from last time
$saved = @{}
if (Test-Path $pathsFile) {
    foreach ($line in Get-Content $pathsFile) {
        $parts = $line -split '=', 2
        if ($parts.Count -eq 2) { $saved[$parts[0]] = $parts[1] }
    }
}

# ---------------------------------------------------------------- RE4 folder
Step 'Finding Resident Evil 4'
$candidates = @()
if ($saved['re4']) { $candidates += $saved['re4'] }
$steamRoots = @()
try { $steamRoots += (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath } catch { }
$steamRoots += 'C:\Program Files (x86)\Steam'
foreach ($root in $steamRoots) {
    $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
            $candidates += (Join-Path ($m.Groups[1].Value -replace '\\\\', '\') "steamapps\common\$re4FolderName")
        }
    }
    $candidates += (Join-Path $root "steamapps\common\$re4FolderName")
}
$candidates += "D:\SteamLibrary\steamapps\common\$re4FolderName"

$re4 = $null
foreach ($c in $candidates) {
    if ($c -and (Test-Path (Join-Path $c 're4.exe'))) { $re4 = $c; break }
}
while (-not $re4) {
    $answer = Read-Host 'Could not find RE4. Paste the RE4 folder (the one with re4.exe)'
    if (Test-Path (Join-Path $answer 're4.exe')) { $re4 = $answer } else { Write-Host '   re4.exe is not in that folder, try again.' }
}
Ok $re4
if (-not (Test-Path (Join-Path $re4 'dinput8.dll'))) {
    Fail 'REFramework is not installed in RE4 (dinput8.dll is missing). Install REFramework first.'
}

# ---------------------------------------------------------------- CurseForge profile
Step 'Finding your Minecraft profile (CurseForge)'
$mods = $null
if ($saved['mods'] -and (Test-Path $saved['mods'])) { $mods = $saved['mods'] }
if (-not $mods) {
    $instances = Join-Path $env:USERPROFILE 'curseforge\minecraft\Instances'
    if (Test-Path $instances) {
        # A profile that already has the mod, else one called RE4
        $withMod = Get-ChildItem $instances -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'mods\re4bridge-*.jar') } | Select-Object -First 1
        if ($withMod) { $mods = Join-Path $withMod.FullName 'mods' }
        elseif (Test-Path (Join-Path $instances 'RE4')) { $mods = Join-Path $instances 'RE4\mods' }
    }
}
while (-not $mods) {
    $answer = Read-Host 'Could not find the profile. In CurseForge: profile ... > Open Folder, then paste that folder here'
    if (Test-Path $answer) { $mods = Join-Path $answer 'mods' } else { Write-Host '   That folder does not exist, try again.' }
}
New-Item -ItemType Directory -Force -Path $mods | Out-Null
Ok $mods

# ---------------------------------------------------------------- Minecraft mod file
$prebuilt = Join-Path $here 'prebuilt'
$jar = Get-ChildItem $prebuilt -Filter 're4bridge-*.jar' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($jar) {
    Step 'Using the ready-made Minecraft mod'
    Ok $jar.Name
} else {
Step 'Building the Minecraft mod (first time takes a few minutes)'
# The build uses JAVA_HOME if it is set, otherwise the java on the PATH
$java = 'java'
if ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME 'bin\java.exe'))) { $java = Join-Path $env:JAVA_HOME 'bin\java.exe' }
elseif (-not (Get-Command java -ErrorAction SilentlyContinue)) {
    Fail 'Java is not installed. Install the Temurin 21 JDK from adoptium.net, then run this again.'
}
$javaVersion = (& cmd /c "`"$java`" -version 2>&1") -join ' '
if ($javaVersion -notmatch 'version "21') {
    Fail "Java 21 is needed, but this was found: $javaVersion"
}
$modDir = Join-Path $here 'minecraft-bridge-mod'
Push-Location $modDir
& cmd /c 'gradlew.bat build'
$buildCode = $LASTEXITCODE
Pop-Location
if ($buildCode -ne 0) {
    Fail 'The build failed. Take a screenshot of the red error text above and send it to Claude.'
}
$jar = Get-ChildItem (Join-Path $modDir 'build\libs') -Filter 're4bridge-*.jar' |
    Where-Object { $_.Name -notmatch 'sources' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $jar) { Fail 'The build finished but no mod file was made.' }
Ok $jar.Name
}

# ---------------------------------------------------------------- Install the Minecraft mod
Step 'Installing the Minecraft mod'
try {
    Get-ChildItem $mods -Filter 're4bridge-*.jar' | Remove-Item -Force
    Copy-Item $jar.FullName $mods -Force
} catch {
    Fail 'Could not replace the mod. Close Minecraft first, then run this again.'
}
Ok "$($jar.Name) -> $mods"

# Tell the mod where RE4 is (in case it is not the default D: drive folder)
$instance = Split-Path -Parent $mods
$configDir = Join-Path $instance 'config'
New-Item -ItemType Directory -Force -Path $configDir | Out-Null
$bridgeFile = Join-Path $re4 'reframework\data\minecraft_bridge.json'
Set-Content -Path (Join-Path $configDir 're4bridge.txt') -Encoding ASCII -Value @(
    "# Full path of the file the RE4 script reads (inside RE4's reframework\data folder)",
    $bridgeFile
)
Ok 'Minecraft mod knows where RE4 is'

# ---------------------------------------------------------------- RE4 scripts
Step 'Installing the RE4 scripts'
$autorun = Join-Path $re4 'reframework\autorun'
New-Item -ItemType Directory -Force -Path $autorun | Out-Null
foreach ($old in @('minecraft_hearts.lua', 'minecraft_creative.lua')) {
    $oldPath = Join-Path $autorun $old
    if (Test-Path $oldPath) { Remove-Item $oldPath -Force; Ok "removed old $old" }
}
$scripts = Get-ChildItem $here -Filter 'minecraft_*.lua' | Where-Object { $_.Name -ne 'minecraft_scanner.lua' }
foreach ($s in $scripts) {
    Copy-Item $s.FullName $autorun -Force
    Ok $s.Name
}

# ---------------------------------------------------------------- RE4 overlay plugin
Step 'Installing the RE4 overlay plugin (shows Minecraft''s own hand, items and HUD in RE4)'
$plugins = Join-Path $re4 'reframework\plugins'
New-Item -ItemType Directory -Force -Path $plugins | Out-Null
$dll = Join-Path $prebuilt 're4_minecraft_overlay.dll'
if (Test-Path $dll) {
    try {
        Copy-Item $dll $plugins -Force
    } catch {
        Fail 'Could not replace the overlay plugin. Close RE4 first, then run this again.'
    }
    Ok "re4_minecraft_overlay.dll -> $plugins"
} else {
    Write-Host '   prebuilt\re4_minecraft_overlay.dll is missing; skipping the overlay plugin' -ForegroundColor Yellow
}

Set-Content -Path $pathsFile -Encoding ASCII -Value @("re4=$re4", "mods=$mods")

Write-Host ''
Write-Host 'All done! Start Minecraft (RE4 profile, Superflat world), then RE4.' -ForegroundColor Green
Write-Host 'Keep the Minecraft window open behind RE4 (not minimized): it draws the hand and HUD you see in RE4.'
Write-Host 'If RE4 was already running: Insert > ScriptRunner > Reset scripts.'
