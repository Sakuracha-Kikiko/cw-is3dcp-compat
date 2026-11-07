# build-offline.ps1
#
# Offline build for cw_issponder_compat.
# Uses the Minecraft + NeoForge runtime libraries already installed on this machine
# (Mojmap jars, no Gradle, no access to maven.neoforged.net) plus the Iron's Spellbooks
# jar from the modpack.
#
# Usage:
#   .\build-offline.ps1
#   .\build-offline.ps1 -Install                 # also copy the jar into the modpack
#   .\build-offline.ps1 -PackMods "D:\pack\mods"
#   .\build-offline.ps1 -MinecraftHome "D:\.minecraft" -NeoForgeVersion 21.1.256
#
# NOTE: keep this file ASCII-only; Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
#
[CmdletBinding()]
param(
    [string]$MinecraftHome = "$env:APPDATA\.minecraft",
    [string]$PackMods = '',
    [string]$NeoForgeVersion = '',
    [switch]$Install
)

$ErrorActionPreference = 'Stop'
$root   = $PSScriptRoot
$lib    = Join-Path $MinecraftHome 'libraries'
$build  = Join-Path $root 'build'
$outDir = Join-Path $build 'libs'

function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }
function Info($msg) { Write-Host "  $msg" }

if (-not (Test-Path $lib)) { Fail "libraries not found: $lib (use -MinecraftHome)" }

# ---------- 1. gradle.properties is the single source of truth for mods.toml placeholders ----------
$props = @{}
foreach ($line in Get-Content (Join-Path $root 'gradle.properties')) {
    if ($line -match '^\s*([A-Za-z0-9_.]+)\s*=\s*(.*)$') { $props[$Matches[1]] = $Matches[2].Trim() }
}

function NewestDir([string]$path, [string]$filter) {
    if (-not (Test-Path $path)) { return $null }
    Get-ChildItem $path -Directory |
        Where-Object { $_.Name -like $filter } |
        Sort-Object { [version]($_.Name -replace '[^0-9.].*$','') } -Descending |
        Select-Object -First 1
}

# ---------- 2. locate compile dependencies ----------
# 2.1 Minecraft: the Mojmap jar is *-srg.jar (NeoForge 1.20.2+ runtime mapping);
#     the *-extra.jar next to it is the obfuscated vanilla client.
$mcDir = NewestDir (Join-Path $lib 'net\minecraft\client') "$($props.minecraft_version)-*"
if (-not $mcDir) { Fail "net/minecraft/client/$($props.minecraft_version)-* not found" }
$mcJar = Get-ChildItem $mcDir.FullName -Filter '*-srg.jar' | Sort-Object Name -Descending | Select-Object -First 1
if (-not $mcJar) { Fail "*-srg.jar not found in $($mcDir.FullName)" }
Info "Minecraft : $($mcJar.Name)"

# 2.2 NeoForge universal (MC 1.21.1 -> NeoForge 21.1.x)
$nfBase = Join-Path $lib 'net\neoforged\neoforge'
if ($NeoForgeVersion) {
    $nfJar = Join-Path $nfBase "$NeoForgeVersion\neoforge-$NeoForgeVersion-universal.jar"
    if (-not (Test-Path $nfJar)) { Fail "not found: $nfJar" }
} else {
    $mcParts = $props.minecraft_version.Split('.')
    $nfPattern = "$($mcParts[1]).$($mcParts[2]).*"
    $nfDir = Get-ChildItem $nfBase -Directory -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -like $nfPattern } |
             Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    if (-not $nfDir) { Fail "net/neoforged/neoforge/$nfPattern not found" }
    $nfJar = (Get-ChildItem $nfDir.FullName -Filter '*-universal.jar' | Select-Object -First 1).FullName
}
Info "NeoForge  : $(Split-Path $nfJar -Leaf)"

# 2.3 FancyModLoader (@Mod / @EventBusSubscriber) + EventBus
$fmlDir = NewestDir (Join-Path $lib 'net\neoforged\fancymodloader\loader') '4.*'
if (-not $fmlDir) { Fail "fancymodloader/loader/4.* not found" }
$fmlJar = (Get-ChildItem $fmlDir.FullName -Filter '*.jar' | Select-Object -First 1).FullName
Info "FML       : $(Split-Path $fmlJar -Leaf)"

$busDir = NewestDir (Join-Path $lib 'net\neoforged\bus') '8.*'
if (-not $busDir) { Fail "net/neoforged/bus/8.* not found" }
$busJar = (Get-ChildItem $busDir.FullName -Filter '*.jar' | Select-Object -First 1).FullName
Info "EventBus  : $(Split-Path $busJar -Leaf)"

# 2.4 Supporting libraries. DataFixerUpper is required because Registry extends Keyable;
#     the rest (Guava/Gson/fastutil/joml/slf4j/commons) show up in MC signatures.
$extraJars = New-Object System.Collections.Generic.List[string]
foreach ($pat in 'com\mojang', 'com\google', 'it\unimi\dsi', 'org\joml', 'org\slf4j', 'org\apache') {
    $dir = Join-Path $lib $pat
    if (Test-Path $dir) {
        Get-ChildItem $dir -Recurse -File -Filter '*.jar' -ErrorAction SilentlyContinue |
            ForEach-Object { $extraJars.Add($_.FullName) }
    }
}
Info "Support   : $($extraJars.Count) extra jars"

# 2.5 Iron's Spellbooks: libs\ first, then the modpack's mods folder
$libsDir = Join-Path $root 'libs'
$ironJar = $null
if (Test-Path $libsDir) {
    $ironJar = Get-ChildItem $libsDir -Filter '*irons_spellbooks*.jar' -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $ironJar) {
    if (-not $PackMods) {
        $cand = Get-ChildItem (Join-Path $MinecraftHome 'versions') -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName 'mods' } |
                Where-Object { Test-Path $_ } |
                Where-Object { Get-ChildItem $_ -Filter '*irons_spellbooks*.jar' -ErrorAction SilentlyContinue } |
                Select-Object -First 1
        if ($cand) { $PackMods = $cand }
    }
    if ($PackMods) {
        $ironJar = Get-ChildItem $PackMods -Filter '*irons_spellbooks*.jar' -ErrorAction SilentlyContinue | Select-Object -First 1
    }
}
if (-not $ironJar) {
    Fail "irons_spellbooks*.jar not found. Copy it into libs\ or pass -PackMods <mods dir>."
}
Info "Iron's    : $($ironJar.Name)"

# ---------- 3. compile ----------
$javac = 'C:\Program Files\Java\jdk-21.0.12.1\bin\javac.exe'
if (-not (Test-Path $javac)) { $javac = (Get-Command javac -ErrorAction Stop).Source }
$jarExe = Join-Path (Split-Path $javac) 'jar.exe'
if (-not (Test-Path $jarExe)) { $jarExe = (Get-Command jar -ErrorAction Stop).Source }

$srcDir     = Join-Path $root 'src\main\java'
$resDir     = Join-Path $root 'src\main\resources'
$classesDir = Join-Path $build 'classes'
$resOutDir  = Join-Path $build 'resources'

Remove-Item $classesDir, $resOutDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $classesDir, $resOutDir, $outDir | Out-Null

$cpParts = @($mcJar.FullName, $nfJar, $fmlJar, $busJar) + $extraJars.ToArray() + @($ironJar.FullName)
$cp = $cpParts -join ';'
$sources = Get-ChildItem $srcDir -Recurse -Filter *.java | Select-Object -ExpandProperty FullName
Info "Compiling $($sources.Count) source file(s) ..."
& $javac -encoding UTF-8 --release 21 -nowarn -cp $cp -d $classesDir @sources
if ($LASTEXITCODE -ne 0) { Fail "javac failed (exit $LASTEXITCODE)" }

# ---------- 4. expand mods.toml placeholders ----------
# Read as explicit UTF-8: PS 5.1's Get-Content -Raw would decode a BOM-less UTF-8 file as ANSI.
$toml = [IO.File]::ReadAllText((Join-Path $resDir 'META-INF\neoforge.mods.toml'), (New-Object Text.UTF8Encoding($false)))
foreach ($k in $props.Keys) { $toml = $toml.Replace('${' + $k + '}', $props[$k]) }
if ($toml -match '\$\{[A-Za-z0-9_.]+\}') { Fail "unresolved placeholder in mods.toml: $($Matches[0])" }
$tomlDir = Join-Path $resOutDir 'META-INF'
New-Item -ItemType Directory -Force -Path $tomlDir | Out-Null
# must be BOM-less: FML's TOML parser rejects a leading BOM (PS 5.1 -Encoding utf8 would add one)
[IO.File]::WriteAllText((Join-Path $tomlDir 'neoforge.mods.toml'), $toml, (New-Object Text.UTF8Encoding($false)))

# ---------- 5. package ----------
$jarName = "$($props.mod_id)-neoforge$($props.minecraft_version)-$($props.mod_version).jar"
$jarPath = Join-Path $outDir $jarName
Remove-Item $jarPath -Force -ErrorAction SilentlyContinue
& $jarExe --create --file $jarPath -C $classesDir . -C $resOutDir .
if ($LASTEXITCODE -ne 0) { Fail "jar packaging failed" }

Write-Host ""
Write-Host "BUILD OK: $jarPath" -ForegroundColor Green
Write-Host ("  size {0:n0} KB" -f ((Get-Item $jarPath).Length / 1KB))

# ---------- 6. optional install ----------
if ($Install) {
    if (-not $PackMods) { Fail "-Install needs a mods directory (pass -PackMods)" }
    Copy-Item $jarPath (Join-Path $PackMods $jarName) -Force
    Write-Host "copied to: $(Join-Path $PackMods $jarName)" -ForegroundColor Green
}
