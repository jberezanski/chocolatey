$here = Split-Path -Parent $MyInvocation.MyCommand.Definition
$base = Split-Path -parent (Split-Path -Parent $here)

function Backup-Environment()
{
	Write-Debug 'Backing up the environment'
	$machineEnv = @{}
	$key = Get-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
	$key.GetValueNames() | ForEach-Object { $machineEnv[$_] = $key.GetValue($_) }

	$userEnv = @{}
	$key = Get-Item 'HKCU:\Environment'
	$key.GetValueNames() | ForEach-Object { $userEnv[$_] = $key.GetValue($_) }

	$processEnv = @{}
	Get-ChildItem Env:\ | ForEach-Object { $processEnv[$_.Key] = $_.Value }

	return New-Object PSCustomObject -Property @{ machine = $machineEnv; user = $userEnv; process = $processEnv }
}

function Restore-Environment($state)
{
	Write-Debug 'Restoring the environment'
	$state.machine.GetEnumerator() | ForEach-Object {
		$current = [Environment]::GetEnvironmentVariable($_.Key, 'Machine')
		if ($current -ne $_.Value) {
			Write-Debug "Restoring value of environment variable $($_.Key) at Machine scope"
			[Environment]::SetEnvironmentVariable($_.Key, $_.Value, 'Machine')
		}
	}

	$key = Get-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
	$key.GetValueNames() | Where-Object { -not $state.machine.ContainsKey($_) } | ForEach-Object { 
		Write-Debug "Deleting environment variable $_ at Machine scope"
		[Environment]::SetEnvironmentVariable($_, $null, 'Machine') 
	}

	$state.user.GetEnumerator() | ForEach-Object {
		$current = [Environment]::GetEnvironmentVariable($_.Key, 'User')
		if ($current -ne $_.Value) {
			Write-Debug "Restoring value of environment variable $($_.Key) at User scope"
			[Environment]::SetEnvironmentVariable($_.Key, $_.Value, 'User')
		}
	}

	$key = Get-Item 'HKCU:\Environment'
	$key.GetValueNames() | Where-Object { -not $state.user.ContainsKey($_) } | ForEach-Object {
		Write-Debug "Deleting environment variable $_ at User scope"
		[Environment]::SetEnvironmentVariable($_, $null, 'User')
	}

	$state.process.GetEnumerator() | ForEach-Object {
		$current = [Environment]::GetEnvironmentVariable($_.Key, 'Process')
		if ($current -ne $_.Value) {
			Write-Debug "Restoring value of environment variable $($_.Key) at Process scope"
			[Environment]::SetEnvironmentVariable($_.Key, $_.Value, 'Process')
		}
	}

	Get-ChildItem Env:\ | Select-Object -ExpandProperty Name | Where-Object { -not $state.process.ContainsKey($_) } | ForEach-Object {
		Write-Debug "Deleting environment variable $_ at Process scope"
		[Environment]::SetEnvironmentVariable($_, $null, 'Process')
	}
}

function Execute-WithEnvironmentBackup($scriptBlock)
{
	$savedEnvironment = Backup-Environment
	try
	{
		& $scriptBlock
	}
	finally
	{
		Restore-Environment $savedEnvironment
	}
}

function Execute-WithMockingUAC([string]$status, $scriptBlock)
{
    switch ($status) {
        'Enabled' { $enabled = $true }
        'Disabled' { $enabled = $false }
        default { throw "Invalid `$status value: $status" }
    }
    $uacRegPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    if (-not (Test-Path $uacRegPath)) {
        if ($enabled) {
            Write-Warning "UAC mock: registry path $uacRegPath does not exist. This means that tests mocking UAC enabled would not be conclusive, so this test is skipped."
        } else {
            Write-Verbose "UAC mock: registry path $uacRegPath does not exist, assuming UAC is not present."
		    & $scriptBlock
        }
        return
    }
    $uacRegValue = "EnableLUA"
    try
    {
        $vals = Get-ItemProperty -Path $uacRegPath
        $savedValue = $vals.EnableLUA
    }
    catch
    {
        $savedValue = $null
    }
    if ($enabled) {
        $mockedValue = 1
    } else {
        $mockedValue = 0
    }
    if ($savedValue -ne $mockedValue) {
        Write-Verbose "UAC mock: setting $uacRegValue value to $mockedValue"
        Set-ItemProperty -Path $uacRegPath -Name $uacRegValue -Value $mockedValue -Type DWord
    } else {
        Write-Verbose "UAC mock: $uacRegValue is already $mockedValue"
    }
	try
	{
		& $scriptBlock
	}
	finally
	{
        if ($savedValue -ne $mockedValue) {
            if ($savedValue -eq $null) {
                Write-Verbose "UAC mock: clearing $uacRegValue because it did not exist previously"
                Clear-ItemProperty -Path $uacRegPath -Name $uacRegValue
            } else {
                Write-Verbose "UAC mock: restoring previous $uacRegValue value $savedValue"
                Set-ItemProperty -Path $uacRegPath -Name $uacRegValue -Value $savedValue -Type DWord
            }
        }
	}
}

function Remove-EnvironmentVariable($name)
{
	Write-Debug "Ensuring environment variable $name is not set at any scope"
	'Machine','User','Process' | ForEach-Object {
		if (-not ([String]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($name, $_)))) {
			Write-Debug "Deleting environment variable $name at $_ scope"
			[Environment]::SetEnvironmentVariable($name, $null, $_)
		}
	}
}

function Remove-DirectoryFromPath($directory)
{
	Write-Debug "Ensuring directory $directory is not on PATH at any scope"
	'Machine','User','Process' | ForEach-Object {
		$scope = $_
		$curPath = [Environment]::GetEnvironmentVariable('PATH', $scope)
		$newPath = ($curPath -split ';' | Where-Object { $_.TrimEnd('\') -ne $directory.TrimEnd('\') }) -join ';'
		if ($newPath -ne $curPath) {
			Write-Debug "Removing directory $directory from PATH at $scope scope"
			[Environment]::SetEnvironmentVariable('PATH', $newPath, $scope)
		}
	}
}

function Add-DirectoryToPath($directory, $scope)
{
	$curPath = [Environment]::GetEnvironmentVariable('PATH', $scope)
	$newPath = ($curPath -split ';' | Where-Object { $_.TrimEnd('\') -ne $directory.TrimEnd('\') }) -join ';'
	if ($newPath -ne $curPath) {
		Write-Debug "Directory $directory is already on PATH at $scope scope"
	} else {
		Write-Debug "Adding directory $directory to PATH at $scope scope"
		if ([String]::IsNullOrEmpty($newPath)) {
			[Environment]::SetEnvironmentVariable('PATH', $directory, $scope)
		} else {
			[Environment]::SetEnvironmentVariable('PATH', "$($newPath.TrimEnd(';'));$directory", $scope)
		}
	}
	if ($scope -ne 'Process') {
		$curPath = [Environment]::GetEnvironmentVariable('PATH', 'Process')
		$newPath = ($curPath -split ';' | Where-Object { $_.TrimEnd('\') -ne $directory.TrimEnd('\') }) -join ';'
		if ($newPath -eq $curPath) {
			Write-Debug "Adding directory $directory to PATH at Process scope"
			if ([String]::IsNullOrEmpty($newPath)) {
				[Environment]::SetEnvironmentVariable('PATH', $directory, 'Process')
			} else {
				[Environment]::SetEnvironmentVariable('PATH', "$($newPath.TrimEnd(';'));$directory", 'Process')
			}
		}
	}
}

function Add-EnvironmentVariable($name, $value, $targetScope)
{
	Write-Debug "Setting $name to $value at $targetScope scope"
	[Environment]::SetEnvironmentVariable($name, $value, $targetScope)
	if ($targetScope -eq 'Process') {
		Write-Debug "Current $name value is '$value' (from Process scope)"
		return
	}
	# find lowest scope with $name set and use that value as current
	foreach ($currentScope in @('User', 'Machine')) {
		$valueAtCurrentScope = [Environment]::GetEnvironmentVariable($name, $currentScope)
		if ($valueAtCurrentScope -ne $null) {
			Write-Debug "Current $name value is '$valueAtCurrentScope' (from $currentScope scope)"
			[Environment]::SetEnvironmentVariable($name, $valueAtCurrentScope, 'Process')
			break
		}
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

function Assert-OnPath($directory, $pathScope)
{
	$path = [Environment]::GetEnvironmentVariable('PATH', $pathScope)
	$dirInPath = [Environment]::GetEnvironmentVariable('PATH', $pathScope) -split ';' | Where-Object { $_ -eq $directory }
	"$dirInPath" | Should not BeNullOrEmpty
}

function Assert-NotOnPath($directory, $pathScope)
{
	$path = [Environment]::GetEnvironmentVariable('PATH', $pathScope)
	$dirInPath = [Environment]::GetEnvironmentVariable('PATH', $pathScope) -split ';' | Where-Object { $_ -eq $directory }
	"$dirInPath" | Should BeNullOrEmpty
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

Describe "Initialize-Chocolatey" {
	# note: the specs below are correct when installing with administrative permissions
	# the test suite is always run elevated, so no easy way to test limited user install for now

	Context "When installing as admin, without UAC, with `$Env:ChocolateyInstall not set, with explicit chocolateyPath" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall $null

			Execute-WithMockingUAC Disabled {
			    Initialize-Chocolatey -chocolateyPath $installDir

			    Verify-ExpectedContentInstalled $installDir

			    It "should create ChocolateyInstall at Process scope" {
				    Assert-ChocolateyInstallIs $installDir 'Process'
			    }

			    It "should not create ChocolateyInstall at User scope" {
				    Assert-ChocolateyInstallIsNull 'User'
			    }

			    It "should create ChocolateyInstall at Machine scope" {
				    Assert-ChocolateyInstallIs $installDir 'Machine'
			    }
            }
		}
	}

	Context "When installing as admin, without UAC, with `$Env:ChocolateyInstall set at Process scope, with same explicit chocolateyPath" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall $installDir 'Process'

			Execute-WithMockingUAC Disabled {
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
	}

	Context "When installing as admin, without UAC, with `$Env:ChocolateyInstall set at Process scope, with different explicit chocolateyPath" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall $installDir 'Process'

			Execute-WithMockingUAC Disabled {
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


	Context "When installing as admin, without UAC, with `$Env:ChocolateyInstall set at Machine scope" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall $installDir 'Machine'

			Execute-WithMockingUAC Disabled {
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

	Context "When installing as admin, without UAC, with `$Env:ChocolateyInstall set at User scope" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall $installDir 'User'

			Execute-WithMockingUAC Disabled {
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

	Context "When installing as admin, without UAC, with `$Env:ChocolateyInstall set at Process scope" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall $installDir 'Process'

			Execute-WithMockingUAC Disabled {
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

	Context "When installing as admin, without UAC, with `$Env:ChocolateyInstall set at Machine scope and same at User scope" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall $installDir 'Machine'
			Add-ChocolateyInstall $installDir 'User'

			Execute-WithMockingUAC Disabled {
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

	Context "When installing as admin, without UAC, with `$Env:ChocolateyInstall set at Machine scope and different at User scope" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall 'X:\nonexistent' 'Machine'
			Add-ChocolateyInstall $installDir 'User'

			Execute-WithMockingUAC Disabled {
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

	Context "When installing as admin, without UAC, with `$Env:ChocolateyInstall set at Machine scope and different at Process scope" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall 'X:\nonexistent' 'Machine'
			Add-ChocolateyInstall $installDir 'Process'

			Execute-WithMockingUAC Disabled {
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

	Context "When installing as admin, without UAC, with `$Env:ChocolateyInstall set at User scope and different at Process scope" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall 'X:\nonexistent' 'User'
			Add-ChocolateyInstall $installDir 'Process'

			Execute-WithMockingUAC Disabled {
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

	Context "When installing as admin, without UAC, with bin directory not on PATH" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall $installDir 'User'
			Remove-DirectoryFromPath "$installDir\bin"

			Execute-WithMockingUAC Disabled {
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
	}

	Context "When installing as admin, without UAC, with bin directory on PATH at Machine scope" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall $installDir 'User'
			Remove-DirectoryFromPath "$installDir\bin"
			Add-DirectoryToPath "$installDir\bin" 'Machine'

			Execute-WithMockingUAC Disabled {
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

	Context "When installing as admin, without UAC, with bin directory on PATH at User scope" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall $installDir 'User'
			Remove-DirectoryFromPath "$installDir\bin"
			Add-DirectoryToPath "$installDir\bin" 'User'

			Execute-WithMockingUAC Disabled {
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

	Context "When installing as admin, with UAC, with `$Env:ChocolateyInstall not set, with explicit chocolateyPath" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall $null

			Execute-WithMockingUAC Enabled {
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

	Context "When installing as admin, with UAC, with `$Env:ChocolateyInstall set at Process scope, with same explicit chocolateyPath" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall $installDir 'Process'

			Execute-WithMockingUAC Enabled {
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

	Context "When installing as admin, with UAC, with `$Env:ChocolateyInstall set at Process scope, with different explicit chocolateyPath" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall $installDir 'Process'

			Execute-WithMockingUAC Enabled {
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

	Context "When installing as admin, with UAC, with `$Env:ChocolateyInstall set at Machine scope" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall $installDir 'Machine'

			Execute-WithMockingUAC Enabled {
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

	Context "When installing as admin, with UAC, with `$Env:ChocolateyInstall set at User scope" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall $installDir 'User'

			Execute-WithMockingUAC Enabled {
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

	Context "When installing as admin, with UAC, with `$Env:ChocolateyInstall set at Process scope" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall $installDir 'Process'

			Execute-WithMockingUAC Enabled {
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

	Context "When installing as admin, with UAC, with `$Env:ChocolateyInstall set at Machine scope and same at User scope" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall $installDir 'Machine'
			Add-ChocolateyInstall $installDir 'User'

			Execute-WithMockingUAC Enabled {
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

	Context "When installing as admin, with UAC, with `$Env:ChocolateyInstall set at Machine scope and different at User scope" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall 'X:\nonexistent' 'Machine'
			Add-ChocolateyInstall $installDir 'User'

			Execute-WithMockingUAC Enabled {
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

	Context "When installing as admin, with UAC, with `$Env:ChocolateyInstall set at Machine scope and different at Process scope" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall 'X:\nonexistent' 'Machine'
			Add-ChocolateyInstall $installDir 'Process'

			Execute-WithMockingUAC Enabled {
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

	Context "When installing as admin, with UAC, with `$Env:ChocolateyInstall set at User scope and different at Process scope" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall 'X:\nonexistent' 'User'
			Add-ChocolateyInstall $installDir 'Process'

			Execute-WithMockingUAC Enabled {
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

	Context "When installing as admin, with UAC, with bin directory not on PATH" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall $installDir 'User'
			Remove-DirectoryFromPath "$installDir\bin"

			Execute-WithMockingUAC Enabled {
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

	Context "When installing as admin, with UAC, with bin directory on PATH at Machine scope" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall $installDir 'User'
			Remove-DirectoryFromPath "$installDir\bin"
			Add-DirectoryToPath "$installDir\bin" 'Machine'

			Execute-WithMockingUAC Enabled {
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

	Context "When installing as admin, with UAC, with bin directory on PATH at User scope" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall $installDir 'User'
			Remove-DirectoryFromPath "$installDir\bin"
			Add-DirectoryToPath "$installDir\bin" 'User'

			Execute-WithMockingUAC Enabled {
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

	Context "When installing as admin, with UAC, with bin directory on PATH at User scope" {
		Setup-ChocolateyInstallationPackage

		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall $installDir 'User'
			Remove-DirectoryFromPath "$installDir\bin"
			Add-DirectoryToPath "$installDir\bin" 'User'

			Execute-WithMockingUAC Enabled {
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
