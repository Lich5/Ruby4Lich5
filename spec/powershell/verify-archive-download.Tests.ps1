BeforeAll {
  . "$PSScriptRoot/../../verify-archive-download.ps1"
}

Describe 'Invoke-VerifiedDownload' {
  BeforeEach {
    $script:DestinationPath = Join-Path $TestDrive 'archive.7z'
    $script:ValidDigest = 'sha256:6eed189751741e7113aee78d525d04bdfd1b87f6529a155818f88071e083b8e4'

    Mock Invoke-WebRequest { }
    Mock Test-Path { $true }
    Mock Remove-Item { }
    # Real Get-FileHash's .Hash is uppercase, no sha256: prefix -- matches the
    # real cmdlet's shape, not just a convenient string, so a test asserting
    # the wrong case-handling would actually catch it.
    Mock Get-FileHash { [pscustomobject]@{ Hash = '6EED189751741E7113AEE78D525D04BDFD1B87F6529A155818F88071E083B8E4' } }
  }

  Context 'happy path' {
    It 'downloads, verifies, and returns the destination path when the digest matches' {
      $result = Invoke-VerifiedDownload -Url 'https://example.com/archive.7z' -ExpectedDigest $script:ValidDigest -DestinationPath $script:DestinationPath

      $result | Should -Be $script:DestinationPath
      Should -Invoke Invoke-WebRequest -Times 1 -Exactly
      Should -Invoke Remove-Item -Times 0 -Exactly
    }

    It 'passes the given TimeoutSec through to Invoke-WebRequest' {
      Invoke-VerifiedDownload -Url 'https://example.com/archive.7z' -ExpectedDigest $script:ValidDigest -DestinationPath $script:DestinationPath -TimeoutSec 120 | Out-Null

      Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $TimeoutSec -eq 120 }
    }
  }

  Context 'malformed ExpectedDigest' {
    It 'throws before ever attempting a download' {
      { Invoke-VerifiedDownload -Url 'https://example.com/archive.7z' -ExpectedDigest 'not-a-digest' -DestinationPath $script:DestinationPath } |
        Should -Throw '*missing or malformed*'

      Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'rejects an empty string via the Mandatory parameter binding itself' {
      { Invoke-VerifiedDownload -Url 'https://example.com/archive.7z' -ExpectedDigest '' -DestinationPath $script:DestinationPath } |
        Should -Throw '*'
    }
  }

  Context 'digest mismatch' {
    It 'throws and deletes the downloaded file, never returning a path' {
      { Invoke-VerifiedDownload -Url 'https://example.com/archive.7z' -ExpectedDigest 'sha256:0000000000000000000000000000000000000000000000000000000000000000' -DestinationPath $script:DestinationPath } |
        Should -Throw '*Digest mismatch*'

      Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $Path -eq $script:DestinationPath }
    }
  }

  Context 'download failure' {
    It 'throws when the destination file was never created' {
      Mock Test-Path { $false }

      { Invoke-VerifiedDownload -Url 'https://example.com/archive.7z' -ExpectedDigest $script:ValidDigest -DestinationPath $script:DestinationPath } |
        Should -Throw '*Download failed*'
    }

    It 'cleans up a partial file left behind by a transport failure mid-download' {
      # Invoke-WebRequest -OutFile streams to disk incrementally, not
      # atomically -- a timeout or dropped connection can throw while a
      # truncated file already exists at DestinationPath. Test-Path true
      # here simulates exactly that partial file.
      Mock Invoke-WebRequest { throw 'The operation has timed out.' }

      { Invoke-VerifiedDownload -Url 'https://example.com/archive.7z' -ExpectedDigest $script:ValidDigest -DestinationPath $script:DestinationPath } |
        Should -Throw '*timed out*'

      Should -Invoke Remove-Item -Times 1 -Exactly -ParameterFilter { $Path -eq $script:DestinationPath }
    }
  }
}
