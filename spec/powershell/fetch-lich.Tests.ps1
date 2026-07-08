BeforeAll {
  . "$PSScriptRoot/../../fetch-lich.ps1"
}

Describe 'Invoke-LichFetch' {
  BeforeEach {
    Mock Invoke-WebRequest { }
    Mock Expand-Archive { }
    Mock Remove-Item { }
    Mock Set-Content { }
    Mock New-Item { }
    Mock Test-Path { $true }
  }

  Context 'happy path' {
    BeforeEach {
      Mock Invoke-RestMethod {
        [pscustomobject]@{
          tag_name = 'v5.18.0'
          assets   = @(
            [pscustomobject]@{ name = 'lich-5.tar.gz'; browser_download_url = 'https://example.com/lich-5.tar.gz' }
            [pscustomobject]@{ name = 'lich-5.zip'; browser_download_url = 'https://example.com/lich-5.zip' }
            [pscustomobject]@{ name = 'Ruby4Lich5.exe'; browser_download_url = 'https://example.com/Ruby4Lich5.exe' }
          )
        }
      }
    }

    It 'returns the resolved tag' {
      $result = Invoke-LichFetch -DestDir 'C:\App\R4LInstall\Lich5'
      $result | Should -Be 'v5.18.0'
    }

    It 'requests the latest release endpoint, not a specific tag' {
      Invoke-LichFetch -DestDir 'C:\App\R4LInstall\Lich5' | Out-Null
      Should -Invoke Invoke-RestMethod -Times 1 -ParameterFilter {
        $Uri -eq 'https://api.github.com/repos/elanthia-online/lich-5/releases/latest'
      }
    }

    It 'downloads specifically the lich-5.zip asset, not the tar.gz or the .exe' {
      Invoke-LichFetch -DestDir 'C:\App\R4LInstall\Lich5' | Out-Null
      Should -Invoke Invoke-WebRequest -Times 1 -ParameterFilter {
        $Uri -eq 'https://example.com/lich-5.zip'
      }
    }

    It 'extracts into the parent of DestDir, not DestDir itself' {
      # lich-5.zip already contains a top-level Lich5/ folder (verified
      # directly against the real asset) -- extracting into DestDir itself
      # would double-nest it.
      Invoke-LichFetch -DestDir 'C:\App\R4LInstall\Lich5' | Out-Null
      Should -Invoke Expand-Archive -Times 1 -ParameterFilter {
        $DestinationPath -eq 'C:\App\R4LInstall'
      }
    }

    It 'writes a lich-fetched.txt record containing the resolved tag' {
      Invoke-LichFetch -DestDir 'C:\App\R4LInstall\Lich5' | Out-Null
      Should -Invoke Set-Content -Times 1 -ParameterFilter {
        $Path -eq 'C:\App\R4LInstall\Lich5\lich-fetched.txt' -and $Value -match 'tag=v5\.18\.0'
      }
    }

    It 'sets TLS 1.2 before the first network call' {
      Mock Invoke-RestMethod {
        [Net.ServicePointManager]::SecurityProtocol | Should -Match 'Tls12'
        [pscustomobject]@{
          tag_name = 'v5.18.0'
          assets   = @([pscustomobject]@{ name = 'lich-5.zip'; browser_download_url = 'https://example.com/lich-5.zip' })
        }
      }
      Invoke-LichFetch -DestDir 'C:\App\R4LInstall\Lich5' | Out-Null
    }

    It 'removes a pre-existing DestDir before extracting, so a stale install cannot linger' {
      Invoke-LichFetch -DestDir 'C:\App\R4LInstall\Lich5' | Out-Null
      Should -Invoke Remove-Item -ParameterFilter { $Path -eq 'C:\App\R4LInstall\Lich5' }
    }

    It 'cleans up the downloaded zip after extraction' {
      Invoke-LichFetch -DestDir 'C:\App\R4LInstall\Lich5' | Out-Null
      Should -Invoke Remove-Item -ParameterFilter { $Path -like '*lich-5-fetch.zip' }
    }
  }

  Context 'the release has no lich-5.zip asset' {
    BeforeEach {
      Mock Invoke-RestMethod {
        [pscustomobject]@{
          tag_name = 'v5.18.0'
          assets   = @([pscustomobject]@{ name = 'lich-5.tar.gz'; browser_download_url = 'https://example.com/lich-5.tar.gz' })
        }
      }
    }

    It 'throws naming the missing asset and the release tag' {
      { Invoke-LichFetch -DestDir 'C:\App\R4LInstall\Lich5' } | Should -Throw '*lich-5.zip not found in release v5.18.0*'
    }

    It 'never attempts a download once the asset is confirmed missing' {
      { Invoke-LichFetch -DestDir 'C:\App\R4LInstall\Lich5' } | Should -Throw
      Should -Invoke Invoke-WebRequest -Times 0
    }
  }

  Context 'extraction did not produce the expected DestDir' {
    BeforeEach {
      Mock Invoke-RestMethod {
        [pscustomobject]@{
          tag_name = 'v5.18.0'
          assets   = @([pscustomobject]@{ name = 'lich-5.zip'; browser_download_url = 'https://example.com/lich-5.zip' })
        }
      }
      # First Test-Path call (pre-existing DestDir check) -> false;
      # second (post-extraction verification) -> false too, so this
      # exercises the real post-extraction guard, not the pre-clean check.
      Mock Test-Path { $false }
    }

    It 'throws rather than silently leaving the xcopy source empty' {
      { Invoke-LichFetch -DestDir 'C:\App\R4LInstall\Lich5' } | Should -Throw '*Expected extracted content*not found*'
    }
  }
}
