$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
$base = Split-Path -Parent (Split-Path -Parent $here)
. (Join-Path (Split-Path -Parent $here) '_TestHelpers.ps1')

function Execute-AsMockedNonAdmin($scriptBlock)
{
    $global:ChocolateyTestsMockAdminRights = $false
    try
    {
        & $scriptBlock
    }
    finally
    {
        Remove-Variable ChocolateyTestsMockAdminRights -scope global
    }
}

function Add-ChocolateyInstall($path, $targetScope)
{
    Add-EnvironmentVariable 'ChocolateyInstall' $path $targetScope
}

function Setup-ChocolateyInstall($path, $targetScope)
{
    Remove-EnvironmentVariable 'ChocolateyInstall'
    if ($path -ne $null) {
        Add-ChocolateyInstall $path $targetScope
    }
}

function Verify-ExpectedContentInstalled($installDir)
{
    It "should create installation directory" {
      $installDir | Should Exist
    }

    It "should create expected subdirectories" {
      "$installDir\bin" | Should Exist
      "$installDir\chocolateyInstall" | Should Exist
      "$installDir\lib" | Should Exist
    }

    It "should copy files to expected locations" {
      "$installDir\bin\choco.exe" | Should Exist
      "$installDir\chocolateyInstall\chocolatey.ps1" | Should Exist
      "$installDir\chocolateyInstall\helpers\functions\Install-ChocolateyPackage.ps1" | Should Exist
    }
}

function Assert-ChocolateyInstallIs($value, $scope)
{
    "$([Environment]::GetEnvironmentVariable('ChocolateyInstall', $scope))" | Should Be $value
}

function Assert-ChocolateyInstallIsNull($scope)
{
    "$([Environment]::GetEnvironmentVariable('ChocolateyInstall', $scope))" | Should BeNullOrEmpty
}

function Setup-ChocolateyInstallationPackage
{
    Setup -Dir 'chocotmp'
    Setup -Dir 'chocotmp\chocolateyInstall'
    $script:tmpDir = 'TestDrive:\chocotmp'

    Get-ChildItem "$base\nuget\tools" | Copy-Item -Destination $tmpDir -Recurse -Force
    Get-ChildItem "$base\src" | Copy-Item -Destination "$tmpDir\chocolateyInstall" -Recurse -Force

    $script:installDir = Join-Path (Resolve-Path 'TestDrive:\').ProviderPath chocoinstall

    Get-Module chocolateysetup | Remove-Module
    Import-Module "$tmpDir\chocolateysetup.psm1"
}

function Get-DefaultChocolateyInstallDir
{
    $programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    $chocolateyPath = Join-Path $programData chocolatey
    return $chocolateyPath
}

function Execute-ChocolateyInstallationInDefaultDir($scriptBlock)
{
    $defaultDir = Get-DefaultChocolateyInstallDir
    if (Test-Path $defaultDir) {
        Write-Warning "Skipping default installation test because the default installation directory already exists ($defaultDir)"
        return
    }
    $script:installDir = $defaultDir
    try
    {
        & $scriptBlock
    }
    finally
    {
        Write-Debug "Removing default installation directory if exists ($defaultDir)"
        Get-Item $defaultDir | Remove-Item -Recurse -Force
    }
}

Describe "Initialize-Chocolatey" {
    # note: the correctness of the specs below is dependent upon all code using Test-AdminRights
    # the test suite is always run elevated, so the only way to test limited user install is to mock that function

    Context "When installing as admin, with `$Env:ChocolateyInstall not set and no arguments" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall $null

            Execute-ChocolateyInstallationInDefaultDir {
                Initialize-Chocolatey

                Verify-ExpectedContentInstalled $installDir

                It "should create ChocolateyInstall at Process scope" {
                    Assert-ChocolateyInstallIs $installDir 'Process'
                }

                It "should not ChocolateyInstall at User scope" {
                    Assert-ChocolateyInstallIsNull 'User'
                }

                It "should create ChocolateyInstall at Machine scope" {
                    Assert-ChocolateyInstallIs $installDir 'Machine'
                }
            }
        }
    }

    Context "When installing as admin, with `$Env:ChocolateyInstall not set, with explicit chocolateyPath" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall $null

            Initialize-Chocolatey -chocolateyPath $installDir

            Verify-ExpectedContentInstalled $installDir

            It "should create ChocolateyInstall at Process scope" {
                Assert-ChocolateyInstallIs $installDir 'Process'
            }

            It "should not ChocolateyInstall at User scope" {
                Assert-ChocolateyInstallIsNull 'User'
            }

            It "should create ChocolateyInstall at Machine scope" {
                Assert-ChocolateyInstallIs $installDir 'Machine'
            }
        }
    }

    Context "When installing as admin, with `$Env:ChocolateyInstall set at Process scope, with same explicit chocolateyPath" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall $installDir 'Process'

            Initialize-Chocolatey -chocolateyPath $installDir

            Verify-ExpectedContentInstalled $installDir

            It "should preserve value of ChocolateyInstall at Process scope" {
                Assert-ChocolateyInstallIs $installDir 'Process'
            }

            It "should not create ChocolateyInstall at User scope" {
                Assert-ChocolateyInstallIsNull 'User'
            }

            # this is unexpected - different behavior than both when chocolateyPath is not passed and when passed chocolateyPath is different than environment
            It "should create ChocolateyInstall at Machine scope" {
                Assert-ChocolateyInstallIs $installDir 'Machine'
            }
        }
    }

    Context "When installing as admin, with `$Env:ChocolateyInstall set at Process scope, with different explicit chocolateyPath" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall $installDir 'Process'

            Initialize-Chocolatey -chocolateyPath 'X:\nonexistent'

            # Is this really desired behavior - giving precedence to environment over explicit argument?
            Verify-ExpectedContentInstalled $installDir

            It "should preserve value of ChocolateyInstall at Process scope" {
                Assert-ChocolateyInstallIs $installDir 'Process'
            }

            It "should not create ChocolateyInstall at User scope" {
                Assert-ChocolateyInstallIsNull 'User'
            }

            It "should not create ChocolateyInstall at Machine scope" {
                Assert-ChocolateyInstallIsNull 'Machine'
            }
        }
    }

    Context "When installing as admin with `$Env:ChocolateyInstall set at Machine scope" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall $installDir 'Machine'

            Initialize-Chocolatey

            Verify-ExpectedContentInstalled $installDir

            It "should preserve value of ChocolateyInstall at Process scope" {
                Assert-ChocolateyInstallIs $installDir 'Process'
            }

            It "should not create ChocolateyInstall at User scope" {
                Assert-ChocolateyInstallIsNull 'User'
            }

            It "should preserve value of ChocolateyInstall at Machine scope" {
                Assert-ChocolateyInstallIs $installDir 'Machine'
            }
        }
    }

    Context "When installing as admin with `$Env:ChocolateyInstall set at User scope" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall $installDir 'User'

            Initialize-Chocolatey

            Verify-ExpectedContentInstalled $installDir

            It "should preserve value of ChocolateyInstall at Process scope" {
                Assert-ChocolateyInstallIs $installDir 'Process'
            }

            It "should preserve value of ChocolateyInstall at User scope" {
                Assert-ChocolateyInstallIs $installDir 'User'
            }

            It "should not create ChocolateyInstall at Machine scope" {
                Assert-ChocolateyInstallIsNull 'Machine'
            }
        }
    }

    Context "When installing as admin with `$Env:ChocolateyInstall set at Process scope" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall $installDir 'Process'

            Initialize-Chocolatey

            Verify-ExpectedContentInstalled $installDir

            It "should preserve value of ChocolateyInstall at Process scope" {
                Assert-ChocolateyInstallIs $installDir 'Process'
            }

            It "should not create ChocolateyInstall at User scope" {
                Assert-ChocolateyInstallIsNull 'User'
            }

            It "should not create ChocolateyInstall at Machine scope" {
                Assert-ChocolateyInstallIsNull 'Machine'
            }
        }
    }

    Context "When installing as admin with `$Env:ChocolateyInstall set at Machine scope and same at User scope" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall $installDir 'Machine'
            Add-ChocolateyInstall $installDir 'User'

            Initialize-Chocolatey

            Verify-ExpectedContentInstalled $installDir

            It "should preserve value of ChocolateyInstall at Process scope" {
                Assert-ChocolateyInstallIs $installDir 'Process'
            }

            It "should preserve value of ChocolateyInstall at User scope" {
                Assert-ChocolateyInstallIs $installDir 'User'
            }

            It "should preserve value of ChocolateyInstall at Machine scope" {
                Assert-ChocolateyInstallIs $installDir 'Machine'
            }
        }
    }

    Context "When installing as admin with `$Env:ChocolateyInstall set at Machine scope and different at User scope" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall 'X:\nonexistent' 'Machine'
            Add-ChocolateyInstall $installDir 'User'

            Initialize-Chocolatey

            Verify-ExpectedContentInstalled $installDir

            It "should preserve value of ChocolateyInstall at Process scope" {
                Assert-ChocolateyInstallIs $installDir 'Process'
            }

            It "should preserve value of ChocolateyInstall at User scope" {
                Assert-ChocolateyInstallIs $installDir 'User'
            }

            It "should preserve value of ChocolateyInstall at Machine scope" {
                Assert-ChocolateyInstallIs 'X:\nonexistent' 'Machine'
            }
        }
    }

    Context "When installing as admin with `$Env:ChocolateyInstall set at Machine scope and different at Process scope" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall 'X:\nonexistent' 'Machine'
            Add-ChocolateyInstall $installDir 'Process'

            Initialize-Chocolatey

            Verify-ExpectedContentInstalled $installDir

            It "should preserve value of ChocolateyInstall at Process scope" {
                Assert-ChocolateyInstallIs $installDir 'Process'
            }

            It "should not create ChocolateyInstall at User scope" {
                Assert-ChocolateyInstallIsNull 'User'
            }

            It "should preserve value of ChocolateyInstall at Machine scope" {
                Assert-ChocolateyInstallIs 'X:\nonexistent' 'Machine'
            }
        }
    }

    Context "When installing as admin with `$Env:ChocolateyInstall set at User scope and different at Process scope" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall 'X:\nonexistent' 'User'
            Add-ChocolateyInstall $installDir 'Process'

            Initialize-Chocolatey

            Verify-ExpectedContentInstalled $installDir

            It "should preserve value of ChocolateyInstall at Process scope" {
                Assert-ChocolateyInstallIs $installDir 'Process'
            }

            It "should preserve value of ChocolateyInstall at User scope" {
                Assert-ChocolateyInstallIs 'X:\nonexistent' 'User'
            }

            It "should not create ChocolateyInstall at Machine scope" {
                Assert-ChocolateyInstallIsNull 'Machine'
            }
        }
    }

    Context "When installing as admin with bin directory not on PATH" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall $installDir 'User'
            Remove-DirectoryFromPath "$installDir\bin"

            Initialize-Chocolatey

            $binDir = "$installDir\bin"

            It "should add bin to PATH at Process scope" {
                Assert-OnPath $binDir 'Process'
            }

            It "should not add bin to PATH at User scope" {
                Assert-NotOnPath $binDir 'User'
            }

            It "should add bin to PATH at Machine scope" {
                Assert-OnPath $binDir 'Machine'
            }
        }
    }

    Context "When installing as admin with bin directory on PATH at Machine scope" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall $installDir 'User'
            Remove-DirectoryFromPath "$installDir\bin"
            Add-DirectoryToPath "$installDir\bin" 'Machine'

            Initialize-Chocolatey

            $binDir = "$installDir\bin"

            It "should retain bin on PATH at Process scope" {
                Assert-OnPath $binDir 'Process'
            }

            It "should not add bin to PATH at User scope" {
                Assert-NotOnPath $binDir 'User'
            }

            It "should retain bin on PATH at Machine scope" {
                Assert-OnPath $binDir 'Machine'
            }
        }
    }

    Context "When installing as admin with bin directory on PATH at User scope" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall $installDir 'User'
            Remove-DirectoryFromPath "$installDir\bin"
            Add-DirectoryToPath "$installDir\bin" 'User'

            Initialize-Chocolatey

            $binDir = "$installDir\bin"

            It "should retain bin on PATH at Process scope" {
                Assert-OnPath $binDir 'Process'
            }

            It "should retain bin on PATH at User scope" {
                Assert-OnPath $binDir 'User'
            }

            It "should not add bin to PATH at Machine scope" {
                Assert-NotOnPath $binDir 'Machine'
            }
        }
    }

    Context "When installing as simulated standard user, with `$Env:ChocolateyInstall not set and no arguments" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall $null

            Execute-AsMockedNonAdmin {
                Execute-ChocolateyInstallationInDefaultDir {
                    Initialize-Chocolatey

                    Verify-ExpectedContentInstalled $installDir

                    It "should create ChocolateyInstall at Process scope" {
                        Assert-ChocolateyInstallIs $installDir 'Process'
                    }

                    It "should create ChocolateyInstall at User scope" {
                        Assert-ChocolateyInstallIs $installDir 'User'
                    }

                    It "should not create ChocolateyInstall at Machine scope" {
                        Assert-ChocolateyInstallIsNull 'Machine'
                    }
                }
            }
        }
    }

    Context "When installing as simulated standard user, with `$Env:ChocolateyInstall not set, with explicit chocolateyPath" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall $null

            Execute-AsMockedNonAdmin {
                Initialize-Chocolatey -chocolateyPath $installDir

                Verify-ExpectedContentInstalled $installDir

                It "should create ChocolateyInstall at Process scope" {
                    Assert-ChocolateyInstallIs $installDir 'Process'
                }

                It "should create ChocolateyInstall at User scope" {
                    Assert-ChocolateyInstallIs $installDir 'User'
                }

                It "should not create ChocolateyInstall at Machine scope" {
                    Assert-ChocolateyInstallIsNull 'Machine'
                }
            }
        }
    }

    Context "When installing as simulated standard user, with `$Env:ChocolateyInstall set at Process scope, with same explicit chocolateyPath" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall $installDir 'Process'

            Execute-AsMockedNonAdmin {
                Initialize-Chocolatey -chocolateyPath $installDir

                Verify-ExpectedContentInstalled $installDir

                It "should preserve value of ChocolateyInstall at Process scope" {
                    Assert-ChocolateyInstallIs $installDir 'Process'
                }

                # this is unexpected - different behavior than both when chocolateyPath is not passed and when passed chocolateyPath is different than environment
                It "should create ChocolateyInstall at User scope" {
                    Assert-ChocolateyInstallIs $installDir 'User'
                }

                It "should not create ChocolateyInstall at Machine scope" {
                    Assert-ChocolateyInstallIsNull 'Machine'
                }
            }
        }
    }

    Context "When installing as simulated standard user, with `$Env:ChocolateyInstall set at Process scope, with different explicit chocolateyPath" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall $installDir 'Process'

            Execute-AsMockedNonAdmin {
                Initialize-Chocolatey -chocolateyPath 'X:\nonexistent'

                # Is this really desired behavior - giving precedence to environment over explicit argument?
                Verify-ExpectedContentInstalled $installDir

                It "should preserve value of ChocolateyInstall at Process scope" {
                    Assert-ChocolateyInstallIs $installDir 'Process'
                }

                It "should not create ChocolateyInstall at User scope" {
                    Assert-ChocolateyInstallIsNull 'User'
                }

                It "should not create ChocolateyInstall at Machine scope" {
                    Assert-ChocolateyInstallIsNull 'Machine'
                }
            }
        }
    }

    Context "When installing as simulated standard user with `$Env:ChocolateyInstall set at Machine scope" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall $installDir 'Machine'

            Execute-AsMockedNonAdmin {
                Initialize-Chocolatey

                Verify-ExpectedContentInstalled $installDir

                It "should preserve value of ChocolateyInstall at Process scope" {
                    Assert-ChocolateyInstallIs $installDir 'Process'
                }

                It "should not create ChocolateyInstall at User scope" {
                    Assert-ChocolateyInstallIsNull 'User'
                }

                It "should preserve value of ChocolateyInstall at Machine scope" {
                    Assert-ChocolateyInstallIs $installDir 'Machine'
                }
            }
        }
    }

    Context "When installing as simulated standard user with `$Env:ChocolateyInstall set at User scope" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall $installDir 'User'

            Execute-AsMockedNonAdmin {
                Initialize-Chocolatey

                Verify-ExpectedContentInstalled $installDir

                It "should preserve value of ChocolateyInstall at Process scope" {
                    Assert-ChocolateyInstallIs $installDir 'Process'
                }

                It "should preserve value of ChocolateyInstall at User scope" {
                    Assert-ChocolateyInstallIs $installDir 'User'
                }

                It "should not create ChocolateyInstall at Machine scope" {
                    Assert-ChocolateyInstallIsNull 'Machine'
                }
            }
        }
    }

    Context "When installing as simulated standard user with `$Env:ChocolateyInstall set at Process scope" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall $installDir 'Process'

            Execute-AsMockedNonAdmin {
                Initialize-Chocolatey

                Verify-ExpectedContentInstalled $installDir

                It "should preserve value of ChocolateyInstall at Process scope" {
                    Assert-ChocolateyInstallIs $installDir 'Process'
                }

                It "should not create ChocolateyInstall at User scope" {
                    Assert-ChocolateyInstallIsNull 'User'
                }

                It "should not create ChocolateyInstall at Machine scope" {
                    Assert-ChocolateyInstallIsNull 'Machine'
                }
            }
        }
    }

    Context "When installing as simulated standard user with `$Env:ChocolateyInstall set at Machine scope and same at User scope" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall $installDir 'Machine'
            Add-ChocolateyInstall $installDir 'User'

            Execute-AsMockedNonAdmin {
                Initialize-Chocolatey

                Verify-ExpectedContentInstalled $installDir

                It "should preserve value of ChocolateyInstall at Process scope" {
                    Assert-ChocolateyInstallIs $installDir 'Process'
                }

                It "should preserve value of ChocolateyInstall at User scope" {
                    Assert-ChocolateyInstallIs $installDir 'User'
                }

                It "should preserve value of ChocolateyInstall at Machine scope" {
                    Assert-ChocolateyInstallIs $installDir 'Machine'
                }
            }
        }
    }

    Context "When installing as simulated standard user with `$Env:ChocolateyInstall set at Machine scope and different at User scope" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall 'X:\nonexistent' 'Machine'
            Add-ChocolateyInstall $installDir 'User'

            Execute-AsMockedNonAdmin {
                Initialize-Chocolatey

                Verify-ExpectedContentInstalled $installDir

                It "should preserve value of ChocolateyInstall at Process scope" {
                    Assert-ChocolateyInstallIs $installDir 'Process'
                }

                It "should preserve value of ChocolateyInstall at User scope" {
                    Assert-ChocolateyInstallIs $installDir 'User'
                }

                It "should preserve value of ChocolateyInstall at Machine scope" {
                    Assert-ChocolateyInstallIs 'X:\nonexistent' 'Machine'
                }
            }
        }
    }

    Context "When installing as simulated standard user with `$Env:ChocolateyInstall set at Machine scope and different at Process scope" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall 'X:\nonexistent' 'Machine'
            Add-ChocolateyInstall $installDir 'Process'

            Execute-AsMockedNonAdmin {
                Initialize-Chocolatey

                Verify-ExpectedContentInstalled $installDir

                It "should preserve value of ChocolateyInstall at Process scope" {
                    Assert-ChocolateyInstallIs $installDir 'Process'
                }

                It "should not create ChocolateyInstall at User scope" {
                    Assert-ChocolateyInstallIsNull 'User'
                }

                It "should preserve value of ChocolateyInstall at Machine scope" {
                    Assert-ChocolateyInstallIs 'X:\nonexistent' 'Machine'
                }
            }
        }
    }

    Context "When installing as simulated standard user with `$Env:ChocolateyInstall set at User scope and different at Process scope" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall 'X:\nonexistent' 'User'
            Add-ChocolateyInstall $installDir 'Process'

            Execute-AsMockedNonAdmin {
                Initialize-Chocolatey

                Verify-ExpectedContentInstalled $installDir

                It "should preserve value of ChocolateyInstall at Process scope" {
                    Assert-ChocolateyInstallIs $installDir 'Process'
                }

                It "should preserve value of ChocolateyInstall at User scope" {
                    Assert-ChocolateyInstallIs 'X:\nonexistent' 'User'
                }

                It "should not create ChocolateyInstall at Machine scope" {
                    Assert-ChocolateyInstallIsNull 'Machine'
                }
            }
        }
    }

    Context "When installing as simulated standard user with bin directory not on PATH" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall $installDir 'User'
            Remove-DirectoryFromPath "$installDir\bin"

            Execute-AsMockedNonAdmin {
                Initialize-Chocolatey

                $binDir = "$installDir\bin"

                It "should add bin to PATH at Process scope" {
                    Assert-OnPath $binDir 'Process'
                }

                It "should add bin to PATH at User scope" {
                    Assert-OnPath $binDir 'User'
                }

                It "should not add bin to PATH at Machine scope" {
                    Assert-NotOnPath $binDir 'Machine'
                }
            }
        }
    }

    Context "When installing as simulated standard user with bin directory on PATH at Machine scope" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall $installDir 'User'
            Remove-DirectoryFromPath "$installDir\bin"
            Add-DirectoryToPath "$installDir\bin" 'Machine'

            Execute-AsMockedNonAdmin {
                Initialize-Chocolatey

                $binDir = "$installDir\bin"

                It "should retain bin on PATH at Process scope" {
                    Assert-OnPath $binDir 'Process'
                }

                It "should not add bin to PATH at User scope" {
                    Assert-NotOnPath $binDir 'User'
                }

                It "should retain bin on PATH at Machine scope" {
                    Assert-OnPath $binDir 'Machine'
                }
            }
        }
    }

    Context "When installing as simulated standard user with bin directory on PATH at User scope" {
        Setup-ChocolateyInstallationPackage

        Execute-WithEnvironmentBackup {
            Setup-ChocolateyInstall $installDir 'User'
            Remove-DirectoryFromPath "$installDir\bin"
            Add-DirectoryToPath "$installDir\bin" 'User'

            Execute-AsMockedNonAdmin {
                Initialize-Chocolatey

                $binDir = "$installDir\bin"

                It "should retain bin on PATH at Process scope" {
                    Assert-OnPath $binDir 'Process'
                }

                It "should retain bin on PATH at User scope" {
                    Assert-OnPath $binDir 'User'
                }

                It "should not add bin to PATH at Machine scope" {
                    Assert-NotOnPath $binDir 'Machine'
                }
            }
        }
    }
}
