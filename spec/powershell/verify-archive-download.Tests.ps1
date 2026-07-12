BeforeAll {
  . "$PSScriptRoot/../../verify-archive-download.ps1"
}

Describe 'Invoke-VerifiedDownload' {
  BeforeEach {
    $script:DestinationPath = Join-Path $TestDrive 'archive.7z'
    $script:ValidDigest = 'sha256:6eed189751741e7113aee78d525d04bdfd1b87f6529a155818f88071e083b8e4'

    # Invoke-WebRequest actually writes real bytes to whatever -OutFile path
    # it's given (the staging file) -- Move-Item/Remove-Item/Get-Content
    # below all then operate on real files under $TestDrive, proving the
    # actual staging/move/cleanup behavior against the real filesystem, not
    # just that the right cmdlet names got called with the right arguments.
    Mock Invoke-WebRequest {
      param($Uri, $OutFile)
      Set-Content -Path $OutFile -Value 'downloaded content' -NoNewline
    }
    # Real Get-FileHash's .Hash is uppercase, no sha256: prefix -- matches the
    # real cmdlet's shape, not just a convenient string, so a test asserting
    # the wrong case-handling would actually catch it.
    Mock Get-FileHash { [pscustomobject]@{ Hash = '6EED189751741E7113AEE78D525D04BDFD1B87F6529A155818F88071E083B8E4' } }
  }

  Context 'happy path' {
    It 'downloads to a staging file, verifies, moves it into place, and returns the destination path' {
      $result = Invoke-VerifiedDownload -Url 'https://example.com/archive.7z' -ExpectedDigest $script:ValidDigest -DestinationPath $script:DestinationPath

      $result | Should -Be $script:DestinationPath
      Get-Content -Path $script:DestinationPath -Raw | Should -Be 'downloaded content'
      # No staging file left behind alongside the real destination.
      (Get-ChildItem -Path $TestDrive -Filter '*.download-*').Count | Should -Be 0
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
    It 'throws and leaves no staging file behind' {
      { Invoke-VerifiedDownload -Url 'https://example.com/archive.7z' -ExpectedDigest 'sha256:0000000000000000000000000000000000000000000000000000000000000000' -DestinationPath $script:DestinationPath } |
        Should -Throw '*Digest mismatch*'

      (Get-ChildItem -Path $TestDrive -Filter '*.download-*').Count | Should -Be 0
      Test-Path $script:DestinationPath | Should -Be $false
    }
  }

  Context 'download failure' {
    It 'throws when the staging file was never created' {
      Mock Invoke-WebRequest { } # writes nothing

      { Invoke-VerifiedDownload -Url 'https://example.com/archive.7z' -ExpectedDigest $script:ValidDigest -DestinationPath $script:DestinationPath } |
        Should -Throw '*Download failed*'
    }

    It 'cleans up a partial staging file left behind by a transport failure mid-download' {
      # Invoke-WebRequest -OutFile streams to disk incrementally, not
      # atomically -- a timeout or dropped connection can throw while a
      # truncated file already exists at the staging path.
      Mock Invoke-WebRequest {
        param($Uri, $OutFile)
        Set-Content -Path $OutFile -Value 'partial' -NoNewline
        throw 'The operation has timed out.'
      }

      { Invoke-VerifiedDownload -Url 'https://example.com/archive.7z' -ExpectedDigest $script:ValidDigest -DestinationPath $script:DestinationPath } |
        Should -Throw '*timed out*'

      (Get-ChildItem -Path $TestDrive -Filter '*.download-*').Count | Should -Be 0
    }
  }

  Context 'destination path integrity across retries' {
    BeforeEach {
      Set-Content -Path $script:DestinationPath -Value 'ORIGINAL VERIFIED CONTENT' -NoNewline
    }

    It 'preserves existing destination content when the transport fails' {
      Mock Invoke-WebRequest {
        param($Uri, $OutFile)
        Set-Content -Path $OutFile -Value 'partial' -NoNewline
        throw 'The operation has timed out.'
      }

      { Invoke-VerifiedDownload -Url 'https://example.com/archive.7z' -ExpectedDigest $script:ValidDigest -DestinationPath $script:DestinationPath } |
        Should -Throw

      Get-Content -Path $script:DestinationPath -Raw | Should -Be 'ORIGINAL VERIFIED CONTENT'
    }

    It 'preserves existing destination content on a digest mismatch' {
      { Invoke-VerifiedDownload -Url 'https://example.com/archive.7z' -ExpectedDigest 'sha256:0000000000000000000000000000000000000000000000000000000000000000' -DestinationPath $script:DestinationPath } |
        Should -Throw '*Digest mismatch*'

      Get-Content -Path $script:DestinationPath -Raw | Should -Be 'ORIGINAL VERIFIED CONTENT'
    }

    It 'replaces existing destination content once verification succeeds' {
      $result = Invoke-VerifiedDownload -Url 'https://example.com/archive.7z' -ExpectedDigest $script:ValidDigest -DestinationPath $script:DestinationPath

      $result | Should -Be $script:DestinationPath
      Get-Content -Path $script:DestinationPath -Raw | Should -Be 'downloaded content'
    }
  }
}
