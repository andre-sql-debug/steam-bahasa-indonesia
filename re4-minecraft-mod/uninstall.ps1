# Removes the RE4 Minecraft mod: the Minecraft mod file and its setting from your CurseForge profile, and the RE4
# scripts, overlay plugin, mob models and the mod's data files from RE4. Your Minecraft worlds are not touched.
# Run it with uninstall.bat (double-click). Uses the folders install.bat remembered in install-paths.txt.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$pathsFile = Join-Path $here 'install-paths.txt'

function Step($text) { Write-Host ''; Write-Host "== $text" -ForegroundColor Cyan }
function Ok($text) { Write-Host "   $text" -ForegroundColor Green }
function Fail($text) {
    Write-Host ''
    Write-Host "PROBLEM: $text" -ForegroundColor Red
    exit 1
}
function Remove($path) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Recurse -Force
        Ok "removed $path"
    }
}

$saved = @{}
if (Test-Path $pathsFile) {
    foreach ($line in Get-Content $pathsFile) {
        $parts = $line -split '=', 2
        if ($parts.Count -eq 2) { $saved[$parts[0]] = $parts[1] }
    }
}
$re4 = $saved['re4']
while (-not ($re4 -and (Test-Path (Join-Path $re4 're4.exe')))) {
    $re4 = Read-Host 'Paste the RE4 folder (the one with re4.exe), or leave empty to skip RE4'
    if (-not $re4) { break }
}
$mods = $saved['mods']
if (-not ($mods -and (Test-Path $mods))) {
    $mods = Read-Host 'Paste the Minecraft profile''s mods folder, or leave empty to skip Minecraft'
}

if (Get-Process -Name 're4' -ErrorAction SilentlyContinue) {
    Fail 'Close Resident Evil 4 first (its plugin file is in use), then run this again.'
}

if ($mods -and (Test-Path $mods)) {
    Step 'Removing the Minecraft mod'
    try {
        Get-ChildItem $mods -Filter 're4bridge-*.jar' | ForEach-Object { Remove $_.FullName }
    } catch {
        Fail 'Could not remove the mod. Close Minecraft first, then run this again.'
    }
    Remove (Join-Path (Split-Path -Parent $mods) 'config\re4bridge.txt')
}

if ($re4) {
    Step 'Removing the RE4 scripts, overlay plugin, mob models and data'
    $autorun = Join-Path $re4 'reframework\autorun'
    if (Test-Path $autorun) {
        Get-ChildItem $autorun -Filter 'minecraft_*.lua' | ForEach-Object { Remove $_.FullName }
    }
    Remove (Join-Path $re4 'reframework\plugins\re4_minecraft_overlay.dll')
    $data = Join-Path $re4 'reframework\data'
    if (Test-Path $data) {
        # (also the overlay picture file and half-written .tmp files)
        Get-ChildItem $data -Filter 'minecraft_*' -File | ForEach-Object { Remove $_.FullName }
    }
    Remove (Join-Path $re4 'natives\STM\minecraft')
    Write-Host '   REFramework''s Loose File Loader was left on (other mods may use it); turn it off in RE4: Insert > Loose File Loader.'
}

Remove $pathsFile
Write-Host ''
Write-Host 'The RE4 Minecraft mod is removed.' -ForegroundColor Green
