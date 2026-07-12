[CmdletBinding()]
param(
    [string]$Repository = "Drastics-Experiments/resonance",
    [switch]$DownloadOnly,
    [string]$Destination = (Join-Path ([Environment]::GetFolderPath("UserProfile")) "Downloads"),
    [switch]$Silent
)

$ErrorActionPreference = "Stop"
$headers = @{
    Accept = "application/vnd.github+json"
    "User-Agent" = "Resonance-Windows-Installer"
    "X-GitHub-Api-Version" = "2022-11-28"
}
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("Resonance-Installer-" + [guid]::NewGuid().ToString("N"))

try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    Write-Host "Finding the latest Resonance release..."
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/latest" -Headers $headers
    $manifestAsset = @($release.assets) | Where-Object { $_.name -eq "latest.yml" } | Select-Object -First 1
    if (-not $manifestAsset) { throw "The latest release does not contain latest.yml." }

    $manifestPath = Join-Path $temporaryRoot "latest.yml"
    Invoke-WebRequest -UseBasicParsing -Uri $manifestAsset.browser_download_url -Headers $headers -OutFile $manifestPath
    $manifest = Get-Content -LiteralPath $manifestPath -Raw
    $pathMatch = [regex]::Match($manifest, "(?m)^path:\s*(.+?)\s*$")
    $hashMatch = [regex]::Match($manifest, "(?m)^sha512:\s*(\S+)\s*$")
    if (-not $pathMatch.Success -or -not $hashMatch.Success) { throw "The update manifest is missing its installer path or SHA-512 hash." }

    $installerName = $pathMatch.Groups[1].Value.Trim()
    $expectedHash = $hashMatch.Groups[1].Value.Trim()
    if ([IO.Path]::GetFileName($installerName) -ne $installerName -or $installerName -notlike "Resonance-Setup-*.exe") {
        throw "The update manifest contains an unexpected installer name."
    }
    $installerAsset = @($release.assets) | Where-Object { $_.name -eq $installerName } | Select-Object -First 1
    if (-not $installerAsset) { throw "The latest release does not contain $installerName." }

    $installerPath = Join-Path $temporaryRoot $installerName
    Write-Host "Downloading $installerName..."
    Invoke-WebRequest -UseBasicParsing -Uri $installerAsset.browser_download_url -Headers $headers -OutFile $installerPath

    $sha512 = [Security.Cryptography.SHA512]::Create()
    $stream = [IO.File]::OpenRead($installerPath)
    try {
        $actualHash = [Convert]::ToBase64String($sha512.ComputeHash($stream))
    } finally {
        $stream.Dispose()
        $sha512.Dispose()
    }
    if ($actualHash -cne $expectedHash) { throw "Installer verification failed: SHA-512 does not match latest.yml." }
    Write-Host "Installer verification passed."

    if ($DownloadOnly) {
        $resolvedDestination = [IO.Path]::GetFullPath($Destination)
        New-Item -ItemType Directory -Path $resolvedDestination -Force | Out-Null
        $savedPath = Join-Path $resolvedDestination $installerName
        Copy-Item -LiteralPath $installerPath -Destination $savedPath -Force
        Write-Host "Saved verified installer to $savedPath"
    } else {
        $process = if ($Silent) {
            Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait -PassThru
        } else {
            Start-Process -FilePath $installerPath -Wait -PassThru
        }
        if ($process.ExitCode -notin @(0, 1641, 3010)) { throw "The installer exited with code $($process.ExitCode)." }
        Write-Host "Resonance installation completed."
    }
} finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        $resolvedTemporary = [IO.Path]::GetFullPath($temporaryRoot)
        $systemTemporary = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if ($resolvedTemporary.StartsWith($systemTemporary, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force
        }
    }
}
