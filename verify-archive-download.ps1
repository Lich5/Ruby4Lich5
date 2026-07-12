# Shared download-and-verify primitive, per docs/DECISIONS.md Phase 18 SS1 --
# given a URL and an expected sha256 digest, downloads to a destination path,
# hashes the local file, and either returns that verified path or throws.
# Deliberately does not resolve "which release/tag/asset" (that's two
# genuinely different policies -- exact-tag lookup vs. latest-in-series --
# left local to each caller, per Phase 18's own explicit rejection of a
# single resolver abstraction) and does not extract the downloaded archive
# (extraction/installation shape differs per caller: 7z for the .7z archive
# consumers, a silent .exe install for build-ruby4lich5-installer.yaml).
#
# Invoke-VerifiedDownload is a plain function, not top-level script code --
# same shape as fetch-lich.ps1's own Invoke-LichFetch, for the same reason:
# spec/powershell/verify-archive-download.Tests.ps1 dot-sources this file and
# calls the function directly with mocked cmdlets, real behavioral coverage
# instead of only a syntax check. It throws on failure rather than calling
# exit (exit inside a function would kill the whole test process on the first
# failure path); the bottom guard converts that into a real exit-code/stdout
# contract, but only when actually run as a script --
# $MyInvocation.InvocationName is '.' when dot-sourced, so the guard is a
# no-op during tests.

param(
  # Not Mandatory here -- the spec file dot-sources this with no args to
  # reach Invoke-VerifiedDownload directly, and a Mandatory top-level param
  # blocks on a missing-value prompt in that non-interactive context.
  # Required-ness is enforced below, only on the direct-execution path.
  [string]$Url,
  [string]$ExpectedDigest,
  [string]$DestinationPath
)

function Invoke-VerifiedDownload {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$ExpectedDigest,
    [Parameter(Mandatory = $true)][string]$DestinationPath,
    [int]$TimeoutSec = 60
  )

  # Validated here, not just trusted from the caller -- every caller of this
  # helper already validates this shape before calling (the same
  # '^sha256:[0-9a-f]{64}$' check used throughout this project), but a shared
  # primitive that's the one place a real digest comparison happens should
  # not silently compare against a malformed value and either always fail or,
  # worse, coincidentally match.
  if ($ExpectedDigest -notmatch '^sha256:[0-9a-f]{64}$') {
    throw "ExpectedDigest is missing or malformed -- got '$ExpectedDigest'."
  }

  # Whole download+verify sequence wrapped in one try/catch -- Invoke-WebRequest
  # -OutFile streams to disk incrementally, not atomically, so a timeout or
  # dropped connection mid-transfer can leave a truncated file at
  # $DestinationPath even though Invoke-WebRequest itself throws rather than
  # returning. A throw from Invoke-WebRequest would otherwise propagate
  # straight past cleanup, leaving that partial file behind -- real gap,
  # found in review 2026-07-12: only the digest-mismatch path used to clean
  # up. Every failure path here now funnels through the same cleanup before
  # re-throwing the original exception.
  try {
    Invoke-WebRequest -Uri $Url -OutFile $DestinationPath -UseBasicParsing -TimeoutSec $TimeoutSec
    if (!(Test-Path $DestinationPath)) {
      throw "Download failed: expected file $DestinationPath was not created."
    }

    $localDigest = "sha256:" + (Get-FileHash -Path $DestinationPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($localDigest -ne $ExpectedDigest) {
      throw "Digest mismatch for $DestinationPath -- expected $ExpectedDigest, got $localDigest. Refusing to trust this download."
    }
  } catch {
    Remove-Item $DestinationPath -Force -ErrorAction SilentlyContinue
    throw
  }

  return $DestinationPath
}

if ($MyInvocation.InvocationName -ne '.') {
  $ErrorActionPreference = 'Stop'
  try {
    if ([string]::IsNullOrWhiteSpace($Url) -or [string]::IsNullOrWhiteSpace($ExpectedDigest) -or [string]::IsNullOrWhiteSpace($DestinationPath)) {
      throw "Url, ExpectedDigest, and DestinationPath are all required. Usage: verify-archive-download.ps1 -Url <url> -ExpectedDigest <sha256:...> -DestinationPath <path>"
    }

    $verifiedPath = Invoke-VerifiedDownload -Url $Url -ExpectedDigest $ExpectedDigest -DestinationPath $DestinationPath
    Write-Output $verifiedPath
    exit 0
  } catch {
    Write-Error "Verified download failed: $($_.Exception.Message)"
    exit 1
  }
}
