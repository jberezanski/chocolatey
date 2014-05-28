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
	Add-ChocolateyInstall $path $targetScope
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
	# note: the specs below are correct when installing with administrative permissions with UAC enabled
	# the test suite is always run elevated, so no easy way to test limited user install for now

	Context "When installing with `$Env:ChocolateyInstall set at Machine scope" {
		Setup-ChocolateyInstallationPackage
	
		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall $installDir 'Machine'

			Initialize-Chocolatey
			
			Verify-ExpectedContentInstalled $installDir
			
			It "should preserve value of ChocolateyInstall at Process scope" {
				Assert-ChocolateyInstallIs $installDir 'Process'
			}
			
			It "should preserve value of ChocolateyInstall at Machine scope" {
				Assert-ChocolateyInstallIs $installDir 'Machine'
			}
			
			It "should not create ChocolateyInstall at User scope" {
				Assert-ChocolateyInstallIsNull 'User'
			}
		}
	}

	Context "When installing with `$Env:ChocolateyInstall set at User scope" {
		Setup-ChocolateyInstallationPackage
	
		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall $installDir 'User'

			Initialize-Chocolatey
			
			Verify-ExpectedContentInstalled $installDir
			
			It "should preserve value of ChocolateyInstall at Process scope" {
				Assert-ChocolateyInstallIs $installDir 'Process'
			}
			
			It "should create ChocolateyInstall at Machine scope" {
				Assert-ChocolateyInstallIs $installDir 'Machine'
			}
			
			It "should preserve value of ChocolateyInstall at User scope" {
				Assert-ChocolateyInstallIs $installDir 'User'
			}
		}
	}

	Context "When installing with installation directory not on PATH" {
		Setup-ChocolateyInstallationPackage
	
		Execute-WithEnvironmentBackup {
			Setup-ChocolateyInstall $installDir 'User'
			Remove-DirectoryFromPath "$installDir\bin"

			Initialize-Chocolatey

			$binDir = "$installDir\bin"

			It "should add bin to PATH at Process scope" {
				Assert-OnPath $binDir 'Process'
			}
			
			It "should add bin to PATH at Machine scope" {
				Assert-OnPath $binDir 'Machine'
			}
			
			It "should not add bin to PATH at User scope" {
				Assert-NotOnPath $binDir 'User'
			}
		}
	}
}
