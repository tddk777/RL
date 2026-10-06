<#
.SYNOPSIS
    Installs the Godot editor on the E: drive, in self-contained mode.

.DESCRIPTION
    Everything this script writes stays under $ToolsRoot (E:\Tools by default):
      E:\Tools\_downloads\            downloaded zip + checksum list
      E:\Tools\Godot\<version>\       the editor executables
      E:\Tools\Godot\<version>\editor_data\   editor settings, cache, export templates
      E:\Tools\Godot\godot.cmd        shim that launches the installed version

    The `._sc_` marker file next to the executable switches Godot to
    self-contained mode, so it stops writing to %APPDATA% and %LOCALAPPDATA% on C:.

    The script refuses to run if E: is missing or $ToolsRoot is not on E:.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\setup-windows.ps1
#>
[CmdletBinding()]
param(
    [string]$GodotVersion = "4.7.2",
    [string]$ToolsRoot = "E:\Tools"
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"  # Invoke-WebRequest is very slow with the progress bar
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not (Test-Path "E:\")) {
    throw "Drive E: was not found. This project installs tools on E: only; connect or map E: and re-run."
}
$ToolsRoot = [IO.Path]::GetFullPath($ToolsRoot)
if (-not $ToolsRoot.StartsWith("E:\", [StringComparison]::OrdinalIgnoreCase)) {
    throw "ToolsRoot must be on E: (got '$ToolsRoot')."
}

$tag = "$GodotVersion-stable"
$zipName = "Godot_v$($tag)_win64.exe.zip"
$exeName = "Godot_v$($tag)_win64.exe"
$baseUrl = "https://github.com/godotengine/godot/releases/download/$tag"

$downloads = Join-Path $ToolsRoot "_downloads"
$godotRoot = Join-Path $ToolsRoot "Godot"
$installDir = Join-Path $godotRoot $GodotVersion
$exePath = Join-Path $installDir $exeName
New-Item -ItemType Directory -Force -Path $downloads, $installDir | Out-Null

if (Test-Path $exePath) {
    Write-Host "Godot $GodotVersion is already installed at $installDir"
} else {
    $zipPath = Join-Path $downloads $zipName
    $sumsPath = Join-Path $downloads "Godot_v$($tag)_SHA512-SUMS.txt"

    Write-Host "Downloading $zipName to $downloads ..."
    Invoke-WebRequest -Uri "$baseUrl/$zipName" -OutFile $zipPath
    Invoke-WebRequest -Uri "$baseUrl/SHA512-SUMS.txt" -OutFile $sumsPath

    $expected = (Select-String -Path $sumsPath -Pattern ([regex]::Escape($zipName)) |
        Select-Object -First 1).Line.Split(" ", [StringSplitOptions]::RemoveEmptyEntries)[0]
    $actual = (Get-FileHash -Path $zipPath -Algorithm SHA512).Hash
    if (-not $expected -or $actual -ne $expected.ToUpperInvariant()) {
        Remove-Item $zipPath -Force
        throw "Checksum mismatch for $zipName; the download was deleted. Try again."
    }
    Write-Host "Checksum OK. Extracting to $installDir ..."
    Expand-Archive -Path $zipPath -DestinationPath $installDir -Force
}

# Self-contained mode: editor data lives in $installDir\editor_data instead of C:.
New-Item -ItemType File -Force -Path (Join-Path $installDir "._sc_") | Out-Null

# Stable launcher so scripts don't need to know the version.
$shim = Join-Path $godotRoot "godot.cmd"
Set-Content -Path $shim -Encoding ASCII -Value "@echo off`r`n`"$exePath`" %*"

Write-Host ""
Write-Host "Done."
Write-Host "  Editor:   $exePath"
Write-Host "  Launcher: $shim"
Write-Host "  Data:     $(Join-Path $installDir 'editor_data')"
Write-Host ""
Write-Host "Open the project with tools\open-editor.cmd (repo expected at E:\Projects\RL)."
