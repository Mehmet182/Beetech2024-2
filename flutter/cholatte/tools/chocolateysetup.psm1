$thisScriptFolder = (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$chocoInstallVariableName = "ChocolateyInstall"
$sysDrive = $env:SystemDrive
$tempDir = $env:TEMP
$defaultChocolateyPathOld = "$sysDrive\Chocolatey"

$originalForegroundColor = $host.ui.RawUI.ForegroundColor

function Write-ChocolateyWarning {
    param (
        [string]$message = ''
    )

    try {
        Write-Host "WARNING: $message" -ForegroundColor "Yellow" -ErrorAction "Stop"
    }
    catch {
        Write-Output "WARNING: $message"
    }
}

function  Write-ChocolateyError {
    param (
        [string]$message = ''
    )

    try {
        Write-Host "ERROR: $message" -ForegroundColor "Red" -ErrorAction "Stop"
    }
    catch {
        Write-Output "ERROR: $message"
    }
}

function Remove-ShimWithAuthenticodeSignature {
    param (
        [string] $filePath
    )
    if (!(Test-Path $filePath)) {
        return
    }

    $signature = Get-AuthenticodeSignature $filePath -ErrorAction SilentlyContinue

    if (!$signature -or !$signature.SignerCertificate) {
        Write-ChocolateyWarning "Shim found in $filePath, but was not signed. Ignoring removal..."
        return
    }

    $possibleSignatures = @(
        'RealDimensions Software, LLC'
        'Chocolatey Software, Inc\.'
    )

    $possibleSignatures | ForEach-Object {
        if ($signature.SignerCertificate.Subject -match "$_") {
            Write-Output "Removing shim $filePath"
            $null = Remove-Item "$filePath"

            if (Test-Path "$filePath.ignore") {
                $null = Remove-Item "$filePath.ignore"
            }

            if (Test-Path "$filePath.old") {
                $null = Remove-Item "$filePath.old"
            }
        }
    }

    # This means the file was found, however did not get removed as it contained a authenticode signature that
    # is not ours.
    if (Test-Path $filePath) {
        Write-ChocolateyWarning "Shim found in $filePath, but did not match our signature. Ignoring removal..."
        return
    }
}

function Remove-UnsupportedShimFiles {
    param([string[]]$Paths)

    $shims = @("cpack.exe", "cver.exe", "chocolatey.exe", "cinst.exe", "clist.exe", "cpush.exe", "cuninst.exe", "cup.exe")

    $Paths | ForEach-Object {
        $path = $_
        $shims | ForEach-Object { Join-Path $path $_ } | Where-Object { Test-Path $_ } | ForEach-Object {
            $shimPath = $_
            Write-Debug "Removing shim from '$shimPath'."

            try {
                Remove-ShimWithAuthenticodeSignature -filePath $shimPath
            }
            catch {
                Write-ChocolateyWarning "Unable to remove '$shimPath'. Please remove the file manually."
            }
        }
    }
}

function Initialize-Chocolatey {
    <#
  .DESCRIPTION
    This will initialize the Chocolatey tool by
      a) setting up the "chocolateyPath" (the location where all chocolatey nuget packages will be installed)
      b) Installs chocolatey into the "chocolateyPath"
            c) Installs .net 4.8 if needed
      d) Adds Chocolatey to the PATH environment variable so you have access to the choco commands.
  .PARAMETER  ChocolateyPath
    Allows you to override the default path of (C:\ProgramData\chocolatey\) by specifying a directory chocolatey will install nuget packages.

  .EXAMPLE
    C:\PS> Initialize-Chocolatey

    Installs chocolatey into the default C:\ProgramData\Chocolatey\ directory.

  .EXAMPLE
    C:\PS> Initialize-Chocolatey -chocolateyPath "D:\ChocolateyInstalledNuGets\"

    Installs chocolatey into the custom directory D:\ChocolateyInstalledNuGets\

#>
    param(
        [Parameter(Mandatory = $false)][string]$chocolateyPath = ''
    )
    Write-Debug "Initialize-Chocolatey"

    $installModule = Join-Path $thisScriptFolder 'chocolateyInstall\helpers\chocolateyInstaller.psm1'
    Import-Module $installModule -Force

  Install-DotNet48IfMissing

    if ($chocolateyPath -eq '') {
        $programData = [Environment]::GetFolderPath("CommonApplicationData")
        $chocolateyPath = Join-Path "$programData" 'chocolatey'
    }

    # variable to allow insecure directory:
    $allowInsecureRootInstall = $false
    if ($env:ChocolateyAllowInsecureRootDirectory -eq 'true') {
        $allowInsecureRootInstall = $true
    }

    # if we have an already environment variable path, use it.
    $alreadyInitializedNugetPath = Get-ChocolateyInstallFolder
    if ($alreadyInitializedNugetPath -and $alreadyInitializedNugetPath -ne $chocolateyPath -and ($allowInsecureRootInstall -or $alreadyInitializedNugetPath -ne $defaultChocolateyPathOld)) {
        $chocolateyPath = $alreadyInitializedNugetPath
    }
    else {
        Set-ChocolateyInstallFolder $chocolateyPath
    }
    Create-DirectoryIfNotExists $chocolateyPath
    Ensure-Permissions $chocolateyPath

    #set up variables to add
    $chocolateyExePath = Join-Path $chocolateyPath 'bin'
    $chocolateyLibPath = Join-Path $chocolateyPath 'lib'

    if ($tempDir -eq $null) {
        $tempDir = Join-Path $chocolateyPath 'temp'
        Create-DirectoryIfNotExists $tempDir
    }

    $yourPkgPath = [System.IO.Path]::Combine($chocolateyLibPath, "yourPackageName")
    @"
We are setting up the Chocolatey package repository.
The packages themselves go to `'$chocolateyLibPath`'
  (i.e. $yourPkgPath).
A shim file for the command line goes to `'$chocolateyExePath`'
  and points to an executable in `'$yourPkgPath`'.

Creating Chocolatey folders if they do not already exist.

"@ | Write-Output

    #create the base structure if it doesn't exist
    Create-DirectoryIfNotExists $chocolateyExePath
    Create-DirectoryIfNotExists $chocolateyLibPath

    $possibleShimPaths = @(
        Join-Path "$chocolateyPath" "redirects"
        Join-Path "$thisScriptFolder" "chocolateyInstall\redirects"
    )
    Remove-UnsupportedShimFiles -Paths $possibleShimPaths

    Install-ChocolateyFiles $chocolateyPath
    Ensure-ChocolateyLibFiles $chocolateyLibPath

    Install-ChocolateyBinFiles $chocolateyPath $chocolateyExePath

    $chocolateyExePathVariable = $chocolateyExePath.ToLower().Replace($chocolateyPath.ToLower(), "%DIR%..\").Replace("\\", "\")
    Initialize-ChocolateyPath $chocolateyExePath $chocolateyExePathVariable
    Process-ChocolateyBinFiles $chocolateyExePath $chocolateyExePathVariable

    $realModule = Join-Path $chocolateyPath "helpers\chocolateyInstaller.psm1"
    Import-Module "$realModule" -Force

    if (-not $allowInsecureRootInstall -and (Test-Path($defaultChocolateyPathOld))) {
        Upgrade-OldChocolateyInstall $defaultChocolateyPathOld $chocolateyPath
        Install-ChocolateyBinFiles $chocolateyPath $chocolateyExePath
    }

    Add-ChocolateyProfile
    Invoke-Chocolatey-Initial
    if ($env:ChocolateyExitCode -eq $null -or $env:ChocolateyExitCode -eq '') {
        $env:ChocolateyExitCode = 0
    }

    @"
Chocolatey (choco.exe) is now ready.
You can call choco from anywhere, command line or powershell by typing choco.
Run choco /? for a list of functions.
You may need to shut down and restart powershell and/or consoles
 first prior to using choco.
"@ | Write-Output

    if (-not $allowInsecureRootInstall) {
        Remove-OldChocolateyInstall $defaultChocolateyPathOld
    }

    Remove-UnsupportedShimFiles -Paths $chocolateyExePath
}

function Set-ChocolateyInstallFolder {
    param(
        [string]$folder
    )
    Write-Debug "Set-ChocolateyInstallFolder"

    $environmentTarget = [System.EnvironmentVariableTarget]::User
    # removing old variable
    Install-ChocolateyEnvironmentVariable -variableName "$chocoInstallVariableName" -variableValue $null -variableType $environmentTarget
    if (Test-ProcessAdminRights) {
        Write-Debug "Administrator installing so using Machine environment variable target instead of User."
        $environmentTarget = [System.EnvironmentVariableTarget]::Machine
        # removing old variable
        Install-ChocolateyEnvironmentVariable -variableName "$chocoInstallVariableName" -variableValue $null -variableType $environmentTarget
    }
    else {
        Write-ChocolateyWarning "Setting ChocolateyInstall Environment Variable on USER and not SYSTEM variables.`n  This is due to either non-administrator install OR the process you are running is not being run as an Administrator."
    }

    Write-Output "Creating $chocoInstallVariableName as an environment variable (targeting `'$environmentTarget`') `n  Setting $chocoInstallVariableName to `'$folder`'"
    Write-ChocolateyWarning "It's very likely you will need to close and reopen your shell `n  before you can use choco."
    Install-ChocolateyEnvironmentVariable -variableName "$chocoInstallVariableName" -variableValue "$folder" -variableType $environmentTarget
}

function Get-ChocolateyInstallFolder() {
    Write-Debug "Get-ChocolateyInstallFolder"
    [Environment]::GetEnvironmentVariable($chocoInstallVariableName)
}

function Create-DirectoryIfNotExists($folderName) {
    Write-Debug "Create-DirectoryIfNotExists"
    if (![System.IO.Directory]::Exists($folderName)) {
        [System.IO.Directory]::CreateDirectory($folderName) | Out-Null
    }
}

function Get-LocalizedWellKnownPrincipalName {
    param (
        [Parameter(Mandatory = $true)]
        [Security.Principal.WellKnownSidType] $WellKnownSidType
    )
    $sid = New-Object -TypeName 'System.Security.Principal.SecurityIdentifier' -ArgumentList @($WellKnownSidType, $null)
    $account = $sid.Translate([Security.Principal.NTAccount])

    return $account.Value
}

function Ensure-Permissions {
    param(
        [string]$folder
    )
    Write-Debug "Ensure-Permissions"

    $defaultInstallPath = "$env:SystemDrive\ProgramData\chocolatey"
    try {
        $defaultInstallPath = Join-Path ([Environment]::GetFolderPath("CommonApplicationData")) 'chocolatey'
    }
    catch {
        # keep first setting
    }

    if ($folder.ToLower() -ne $defaultInstallPath.ToLower()) {
        Write-ChocolateyWarning "Installation folder is not the default. Not changing permissions. Please ensure your installation is secure."
        return
    }

    # Everything from here on out applies to the default installation folder

    if (!(Test-ProcessAdminRights)) {
        throw "Installation of Chocolatey to default folder requires Administrative permissions. Please run from elevated prompt. Please see https://chocolatey.org/install for details and alternatives if needing to install as a non-administrator."
    }

    $currentEA = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    try {
        # get current acl
        $acl = Get-Acl $folder

        Write-Debug "Removing existing permissions."
        $acl.Access | ForEach-Object { $acl.RemoveAccessRuleAll($_) }

        $inheritanceFlags = ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit)
        $propagationFlags = [Security.AccessControl.PropagationFlags]::None

        $rightsFullControl = [Security.AccessControl.FileSystemRights]::FullControl
        $rightsModify = [Security.AccessControl.FileSystemRights]::Modify
        $rightsReadExecute = [Security.AccessControl.FileSystemRights]::ReadAndExecute
        $rightsWrite = [Security.AccessControl.FileSystemRights]::Write

        Write-Output "Restricting write permissions to Administrators"
        $builtinAdmins = Get-LocalizedWellKnownPrincipalName -WellKnownSidType ([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid)
        $adminsAccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($builtinAdmins, $rightsFullControl, $inheritanceFlags, $propagationFlags, "Allow")
        $acl.SetAccessRule($adminsAccessRule)
        $localSystem = Get-LocalizedWellKnownPrincipalName -WellKnownSidType ([Security.Principal.WellKnownSidType]::LocalSystemSid)
        $localSystemAccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($localSystem, $rightsFullControl, $inheritanceFlags, $propagationFlags, "Allow")
        $acl.SetAccessRule($localSystemAccessRule)
        $builtinUsers = Get-LocalizedWellKnownPrincipalName -WellKnownSidType ([Security.Principal.WellKnownSidType]::BuiltinUsersSid)
        $usersAccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($builtinUsers, $rightsReadExecute, $inheritanceFlags, $propagationFlags, "Allow")
        $acl.SetAccessRule($usersAccessRule)

        $allowCurrentUser = $env:ChocolateyInstallAllowCurrentUser -eq 'true'
        if ($allowCurrentUser) {
            # get current user
            $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()

            if ($currentUser.Name -ne $localSystem) {
                $userAccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($currentUser.Name, $rightsModify, $inheritanceFlags, $propagationFlags, "Allow")
                Write-ChocolateyWarning 'Adding Modify permission for current user due to $env:ChocolateyInstallAllowCurrentUser. This could lead to escalation of privilege attacks. Consider not allowing this.'
                $acl.SetAccessRule($userAccessRule)
            }
        }
        else {
            Write-Debug 'Current user no longer set due to possible escalation of privileges - set $env:ChocolateyInstallAllowCurrentUser="true" if you require this.'
        }

        Write-Debug "Set Owner to Administrators"
        $builtinAdminsSid = New-Object System.Security.Principal.SecurityIdentifier([Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
        $acl.SetOwner($builtinAdminsSid)

        Write-Debug "Default Installation folder - removing inheritance with no copy"
        $acl.SetAccessRuleProtection($true, $false)

        # enact the changes against the actual
        Set-Acl -Path $folder -AclObject $acl

        # set an explicit append permission on the logs folder
        Write-Debug "Allow users to append to log files."
        $logsFolder = "$folder\logs"
        Create-DirectoryIfNotExists $logsFolder
        $logsAcl = Get-Acl $logsFolder
        $usersAppendAccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule($builtinUsers, $rightsWrite, [Security.AccessControl.InheritanceFlags]::ObjectInherit, [Security.AccessControl.PropagationFlags]::InheritOnly, "Allow")
        $logsAcl.SetAccessRule($usersAppendAccessRule)
        $logsAcl.SetAccessRuleProtection($false, $true)
        Set-Acl -Path $logsFolder -AclObject $logsAcl
    }
    catch {
        Write-ChocolateyWarning "Not able to set permissions for $folder."
    }
    $ErrorActionPreference = $currentEA
}

function Upgrade-OldChocolateyInstall {
    param(
        [string]$chocolateyPathOld = "$sysDrive\Chocolatey",
        [string]$chocolateyPath = "$($env:ALLUSERSPROFILE)\chocolatey"
    )

    Write-Debug "Upgrade-OldChocolateyInstall"

    if (Test-Path $chocolateyPathOld) {
        Write-Output "Attempting to upgrade `'$chocolateyPathOld`' to `'$chocolateyPath`'."
        Write-ChocolateyWarning "Copying the contents of `'$chocolateyPathOld`' to `'$chocolateyPath`'. `n This step may fail if you have anything in this folder running or locked."
        Write-Output 'If it fails, just manually copy the rest of the items out and then delete the folder.'
        Write-ChocolateyWarning "!!!! ATTN: YOU WILL NEED TO CLOSE AND REOPEN YOUR SHELL !!!!"
        #-ForegroundColor Magenta -BackgroundColor Black

        $chocolateyExePathOld = Join-Path $chocolateyPathOld 'bin'
        'Machine', 'User' |
            ForEach-Object {
                $path = Get-EnvironmentVariable -Name 'PATH' -Scope $_
                $updatedPath = [System.Text.RegularExpressions.Regex]::Replace($path, [System.Text.RegularExpressions.Regex]::Escape($chocolateyExePathOld) + '(?>;)?', '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if ($updatedPath -ne $path) {
                    Write-Output "Updating `'$_`' PATH to reflect removal of '$chocolateyPathOld'."
                    try {
                        Set-EnvironmentVariable -Name 'Path' -Value $updatedPath -Scope $_ -ErrorAction Stop
                    }
                    catch {
                        Write-ChocolateyWarning "Was not able to remove the old environment variable from PATH. You will need to do this manually"
                    }
                }
            }

        Copy-Item "$chocolateyPathOld\lib\*" "$chocolateyPath\lib" -Force -Recurse

        $from = "$chocolateyPathOld\bin"
        $to = "$chocolateyPath\bin"
        # TODO: This exclusion list needs to be updated once shims are removed
        $exclude = @("choco.exe", "RefreshEnv.cmd")
        Get-ChildItem -Path $from -Recurse -Exclude $exclude |
            ForEach-Object {
                Write-Debug "Copying $_ `n to $to"
                if ($_.PSIsContainer) {
                    Copy-Item $_ -Destination (Join-Path $to $_.Parent.FullName.Substring($from.length)) -Force -ErrorAction SilentlyContinue
                }
                else {
                    $fileToMove = (Join-Path $to $_.FullName.Substring($from.length))
                    try {
                        Copy-Item $_ -Destination $fileToMove -Exclude $exclude -Force -ErrorAction Stop
                    }
                    catch {
                        Write-ChocolateyWarning "Was not able to move `'$fileToMove`'. You may need to reinstall the shim"
                    }
                }
            }
    }
}

function Remove-OldChocolateyInstall {
    param(
        [string]$chocolateyPathOld = "$sysDrive\Chocolatey"
    )
    Write-Debug "Remove-OldChocolateyInstall"

    if (Test-Path $chocolateyPathOld) {
        Write-ChocolateyWarning "This action will result in Log Errors, you can safely ignore those. `n You may need to finish removing '$chocolateyPathOld' manually."
        try {
            Get-ChildItem -Path "$chocolateyPathOld" | ForEach-Object {
                if (Test-Path $_.FullName) {
                    Write-Debug "Removing $_ unless matches .log"
                    Remove-Item $_.FullName -Exclude *.log -Recurse -Force -ErrorAction SilentlyContinue
                }
            }

            Write-Output "Attempting to remove `'$chocolateyPathOld`'. This may fail if something in the folder is being used or locked."
            Remove-Item "$($chocolateyPathOld)" -Force -Recurse -ErrorAction Stop
        }
        catch {
            Write-ChocolateyWarning "Was not able to remove `'$chocolateyPathOld`'. You will need to manually remove it."
        }
    }
}

function Install-ChocolateyFiles {
    param(
        [string]$chocolateyPath
    )
    Write-Debug "Install-ChocolateyFiles"

    Write-Debug "Removing install files in chocolateyInstall, helpers, redirects, and tools"
    "$chocolateyPath\chocolateyInstall", "$chocolateyPath\helpers", "$chocolateyPath\redirects", "$chocolateyPath\tools" | ForEach-Object {
        #Write-Debug "Checking path $_"

        if (Test-Path $_) {
            Get-ChildItem -Path "$_" | ForEach-Object {
                #Write-Debug "Checking child path $_ ($($_.FullName))"
                if (Test-Path $_.FullName) {
                    Write-Debug "Removing $_ unless matches .log"
                    Remove-Item $_.FullName -Exclude *.log -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    Write-Debug "Attempting to move choco.exe to choco.exe.old so we can place the new version here."
    # rename the currently running process / it will be locked if it exists
    $chocoExe = Join-Path $chocolateyPath 'choco.exe'
    if (Test-Path ($chocoExe)) {
        Write-Debug "Renaming '$chocoExe' to '$chocoExe.old'"
        try {
            Remove-Item "$chocoExe.old" -Force -ErrorAction SilentlyContinue
            Move-Item $chocoExe "$chocoExe.old" -Force -ErrorAction SilentlyContinue
        }
        catch {
            Write-ChocolateyWarning "Was not able to rename `'$chocoExe`' to `'$chocoExe.old`'."
        }
    }

    # remove pdb file if it is found
    $chocoPdb = Join-Path $chocolateyPath 'choco.pdb'
    if (Test-Path ($chocoPdb)) {
        Remove-Item "$chocoPdb" -Force -ErrorAction SilentlyContinue
    }

    Write-Debug "Unpacking files required for Chocolatey."
    $chocoInstallFolder = Join-Path $thisScriptFolder "chocolateyInstall"
    $chocoExe = Join-Path $chocoInstallFolder 'choco.exe'
    $chocoExeDest = Join-Path $chocolateyPath 'choco.exe'
    Copy-Item $chocoExe $chocoExeDest -Force

    Write-Debug "Copying the contents of `'$chocoInstallFolder`' to `'$chocolateyPath`'."
    Copy-Item $chocoInstallFolder\* $chocolateyPath -Recurse -Force
}

function Ensure-ChocolateyLibFiles {
    param(
        [string]$chocolateyLibPath
    )
    Write-Debug "Ensure-ChocolateyLibFiles"
    $chocoPkgDirectory = Join-Path $chocolateyLibPath 'chocolatey'

    Create-DirectoryIfNotExists $chocoPkgDirectory

    if (!(Test-Path("$chocoPkgDirectory\chocolatey.nupkg"))) {
        Write-Output "chocolatey.nupkg file not installed in lib.`n Attempting to locate it from bootstrapper."
        $chocoZipFile = Join-Path $tempDir "chocolatey\chocoInstall\chocolatey.zip"

        Write-Debug "First the zip file at '$chocoZipFile'."
        Write-Debug "Then from a neighboring chocolatey.*nupkg file '$thisScriptFolder/../../'."

        if (Test-Path("$chocoZipFile")) {
            Write-Debug "Copying '$chocoZipFile' to '$chocoPkgDirectory\chocolatey.nupkg'."
            Copy-Item "$chocoZipFile" "$chocoPkgDirectory\chocolatey.nupkg" -Force -ErrorAction SilentlyContinue
        }

        if (!(Test-Path("$chocoPkgDirectory\chocolatey.nupkg"))) {
            $chocoPkg = Get-ChildItem "$thisScriptFolder/../../" |
                Where-Object { $_.name -match "^chocolatey.*nupkg" } |
                Sort-Object name -Descending |
                Select-Object -First 1
            if ($chocoPkg -ne '') {
                $chocoPkg = $chocoPkg.FullName
            }
            "$chocoZipFile", "$chocoPkg" | ForEach-Object {
                if ($_ -ne $null -and $_ -ne '') {
                    if (Test-Path $_) {
                        Write-Debug "Copying '$_' to '$chocoPkgDirectory\chocolatey.nupkg'."
                        Copy-Item $_ "$chocoPkgDirectory\chocolatey.nupkg" -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    }
}

function Install-ChocolateyBinFiles {
    param(
        [string] $chocolateyPath,
        [string] $chocolateyExePath
    )
    Write-Debug "Install-ChocolateyBinFiles"
    Write-Debug "Installing the bin file redirects"
    $redirectsPath = Join-Path $chocolateyPath 'redirects'
    if (!(Test-Path "$redirectsPath")) {
        Write-ChocolateyWarning "$redirectsPath does not exist"
        return
    }

    $exeFiles = Get-ChildItem "$redirectsPath" -Include @("*.exe", "*.cmd") -Recurse
    foreach ($exeFile in $exeFiles) {
        $exeFilePath = $exeFile.FullName
        $exeFileName = [System.IO.Path]::GetFileName("$exeFilePath")
        $binFilePath = Join-Path $chocolateyExePath $exeFileName
        $binFilePathRename = $binFilePath + '.old'
        $batchFilePath = $binFilePath.Replace(".exe", ".bat")
        $bashFilePath = $binFilePath.Replace(".exe", "")
        if (Test-Path ($batchFilePath)) {
            Remove-Item $batchFilePath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path ($bashFilePath)) {
            Remove-Item $bashFilePath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path ($binFilePathRename)) {
            try {
                Write-Debug "Attempting to remove $binFilePathRename"
                Remove-Item $binFilePathRename -Force -ErrorAction Stop
            }
            catch {
                Write-ChocolateyWarning "Was not able to remove `'$binFilePathRename`'. This may cause errors."
            }
        }
        if (Test-Path ($binFilePath)) {
            try {
                Write-Debug "Attempting to rename $binFilePath to $binFilePathRename"
                Move-Item -Path $binFilePath -Destination $binFilePathRename -Force -ErrorAction Stop
            }
            catch {
                Write-ChocolateyWarning "Was not able to rename `'$binFilePath`' to `'$binFilePathRename`'."
            }
        }

        try {
            Write-Debug "Attempting to copy $exeFilePath to $binFilePath"
            Copy-Item -Path $exeFilePath -Destination $binFilePath -Force -ErrorAction Stop
        }
        catch {
            Write-ChocolateyWarning "Was not able to replace `'$binFilePath`' with `'$exeFilePath`'. You may need to do this manually."
        }

        $commandShortcut = [System.IO.Path]::GetFileNameWithoutExtension("$exeFilePath")
        Write-Debug "Added command $commandShortcut"
    }
}

function Initialize-ChocolateyPath {
    param(
        [string]$chocolateyExePath = "$($env:ALLUSERSPROFILE)\chocolatey\bin",
        [string]$chocolateyExePathVariable = "%$($chocoInstallVariableName)%\bin"
    )
    Write-Debug "Initialize-ChocolateyPath"
    Write-Debug "Initializing Chocolatey Path if required"
    $environmentTarget = [System.EnvironmentVariableTarget]::User
    if (Test-ProcessAdminRights) {
        Write-Debug "Administrator installing so using Machine environment variable target instead of User."
        $environmentTarget = [System.EnvironmentVariableTarget]::Machine
    }
    else {
        Write-ChocolateyWarning "Setting ChocolateyInstall Path on USER PATH and not SYSTEM Path.`n  This is due to either non-administrator install OR the process you are running is not being run as an Administrator."
    }

    Install-ChocolateyPath -pathToInstall "$chocolateyExePath" -pathType $environmentTarget
}

function Process-ChocolateyBinFiles {
    param(
        [string]$chocolateyExePath = "$($env:ALLUSERSPROFILE)\chocolatey\bin",
        [string]$chocolateyExePathVariable = "%$($chocoInstallVariableName)%\bin"
    )
    Write-Debug "Process-ChocolateyBinFiles"
    $processedMarkerFile = Join-Path $chocolateyExePath '_processed.txt'
    if (!(Test-Path $processedMarkerFile)) {
        $files = Get-ChildItem $chocolateyExePath -Include *.bat -Recurse
        if ($files -ne $null -and $files.Count -gt 0) {
            Write-Debug "Processing Bin files"
            foreach ($file in $files) {
                Write-Output "Processing $($file.Name) to make it portable"
                $fileStream = [System.IO.File]::Open("$file", 'Open', 'Read', 'ReadWrite')
                $reader = New-Object System.IO.StreamReader($fileStream)
                $fileText = $reader.ReadToEnd()
                $reader.Close()
                $fileStream.Close()

                $fileText = $fileText.ToLower().Replace("`"" + $chocolateyPath.ToLower(), "SET DIR=%~dp0%`n""%DIR%..\").Replace("\\", "\")

                Set-Content $file -Value $fileText -Encoding Ascii
            }
        }

        Set-Content $processedMarkerFile -Value "$([System.DateTime]::Now.Date)" -Encoding Ascii
    }
}

# Adapted from http://www.west-wind.com/Weblog/posts/197245.aspx
function Get-FileEncoding($Path) {
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        Write-Debug "Detected Powershell version < 6 ; Using -Encoding byte parameter"
        $bytes = [byte[]](Get-Content $Path -Encoding byte -ReadCount 4 -TotalCount 4)
    }
    else {
        Write-Debug "Detected Powershell version >= 6 ; Using -AsByteStream parameter"
        $bytes = [byte[]](Get-Content $Path -AsByteStream -ReadCount 4 -TotalCount 4)
    }

    if (!$bytes) {
        return 'utf8'
    }

    switch -regex ('{0:x2}{1:x2}{2:x2}{3:x2}' -f $bytes[0], $bytes[1], $bytes[2], $bytes[3]) {
        '^efbbbf' {
            return 'utf8'
        }
        '^2b2f76' {
            return 'utf7'
        }
        '^fffe' {
            return 'unicode'
        }
        '^feff' {
            return 'bigendianunicode'
        }
        '^0000feff' {
            return 'utf32'
        }
        default {
            return 'ascii'
        }
    }
}

function Add-ChocolateyProfile {
    Write-Debug "Add-ChocolateyProfile"
    try {
        $profileFile = "$profile"
        if ($profileFile -eq $null -or $profileFile -eq '') {
            Write-Output 'Not setting tab completion: Profile variable ($profile) resulted in an empty string.'
            return
        }

        $profileDirectory = (Split-Path -Parent $profileFile)

        if ($env:ChocolateyNoProfile -ne $null -and $env:ChocolateyNoProfile -ne '') {
            Write-Warning "Not setting tab completion: Environment variable "ChocolateyNoProfile" exists and is set."
            return
        }

        $localSystem = Get-LocalizedWellKnownPrincipalName -WellKnownSidType ([Security.Principal.WellKnownSidType]::LocalSystemSid)
        # get current user
        $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
        if ($currentUser.Name -eq $localSystem) {
            Write-Warning "Not setting tab completion: Current user is SYSTEM user."
            return
        }

        if (!(Test-Path($profileDirectory))) {
            Write-Debug "Creating '$profileDirectory'"
            New-Item "$profileDirectory" -Type Directory -Force -ErrorAction SilentlyContinue | Out-Null
        }

        if (!(Test-Path($profileFile))) {
            Write-Warning "Not setting tab completion: Profile file does not exist at '$profileFile'."
            return

            #Write-Debug "Creating '$profileFile'"
            #"" | Out-File $profileFile -Encoding UTF8
        }

        # Check authenticode, but only if file is greater than 5 bytes
        $profileFileInfo = New-Object System.IO.FileInfo($profileFile)
        if ($profileFileInfo.Length -gt 5) {
            $signature = Get-AuthenticodeSignature $profile
            if ($signature.Status -ne 'NotSigned') {
                Write-Warning "Not setting tab completion: File is Authenticode signed at '$profile'."
                return
            }
        }

        $profileInstall = @'

# Import the Chocolatey Profile that contains the necessary code to enable
# tab-completions to function for `choco`.
# Be aware that if you are missing these lines from your profile, tab completion
# for `choco` will not function.
# See https://ch0.co/tab-completion for details.
$ChocolateyProfile = "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1"
if (Test-Path($ChocolateyProfile)) {
  Import-Module "$ChocolateyProfile"
}
'@

        $chocoProfileSearch = '$ChocolateyProfile'
        if (Select-String -Path $profileFile -Pattern $chocoProfileSearch -Quiet -SimpleMatch) {
            Write-Debug "Chocolatey profile is already installed."
            return
        }

        Write-Output 'Adding Chocolatey to the profile. This will provide tab completion, refreshenv, etc.'
        $profileInstall | Out-File $profileFile -Append -Encoding (Get-FileEncoding $profileFile)
        Write-ChocolateyWarning 'Chocolatey profile installed. Reload your profile - type . $profile'

        if ($PSVersionTable.PSVersion.Major -lt 3) {
            Write-ChocolateyWarning "Tab completion does not currently work in PowerShell v2. `n Please upgrade to a more recent version of PowerShell to take advantage of tab completion."
            #Write-ChocolateyWarning "To load tab expansion, you need to install PowerTab. `n See https://powertab.codeplex.com/ for details."
        }
    }
    catch {
        Write-ChocolateyWarning "Unable to add Chocolatey to the profile. You will need to do it manually. Error was '$_'"
        @'
This is how add the Chocolatey Profile manually.
Find your $profile. Then add the following lines to it:

$ChocolateyProfile = "$env:ChocolateyInstall\helpers\chocolateyProfile.psm1"
if (Test-Path($ChocolateyProfile)) {
  Import-Module "$ChocolateyProfile"
}
'@ | Write-Output
    }
}

$netFx48InstallTries = 0

function Install-DotNet48IfMissing {
    param(
        $forceFxInstall = $false
    )
    # we can't take advantage of any chocolatey module functions, because they
    # haven't been unpacked because they require .NET Framework 4.8

    Write-Debug "Install-DotNet48IfMissing called with `$forceFxInstall=$forceFxInstall"
    $NetFxArch = "Framework"
    if ([IntPtr]::Size -eq 8) {
        $NetFxArch = "Framework64"
    }

    $NetFx48Url = 'https://download.visualstudio.microsoft.com/download/pr/2d6bb6b2-226a-4baa-bdec-798822606ff1/8494001c276a4b96804cde7829c04d7f/ndp48-x86-x64-allos-enu.exe'
    $NetFx48Path = "$tempDir"
    $NetFx48InstallerFile = 'ndp48-x86-x64-allos-enu.exe'
    $NetFx48Installer = Join-Path $NetFx48Path $NetFx48InstallerFile

    if (((Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -ErrorAction SilentlyContinue).Release -lt 528040) -or $forceFxInstall) {
        Write-Output "The registry key for .Net 4.8 was not found or this is forced"

        if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") {
            Write-Warning "A reboot is required. `n If you encounter errors, reboot the system and attempt the operation again"
        }

        $netFx48InstallTries += 1

        if (!(Test-Path $NetFx48Installer)) {
            Write-Output "Downloading `'$NetFx48Url`' to `'$NetFx48Installer`' - the installer is 100+ MBs, so this could take a while on a slow connection."
            (New-Object Net.WebClient).DownloadFile("$NetFx48Url","$NetFx48Installer")
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.WorkingDirectory = "$NetFx48Path"
        $psi.FileName = "$NetFx48InstallerFile"
        # https://msdn.microsoft.com/library/ee942965(v=VS.100).aspx#command_line_options
        # http://blogs.msdn.com/b/astebner/archive/2010/05/12/10011664.aspx
        # For the actual setup.exe (if you want to unpack first) - /repair /x86 /x64 /ia64 /parameterfolder Client /q /norestart
        $psi.Arguments = "/q /norestart"

        Write-Output "Installing `'$NetFx48Installer`' - this may take awhile with no output."
        $s = [System.Diagnostics.Process]::Start($psi);
        $s.WaitForExit();
        if ($s.ExitCode -eq 1641 -or $s.ExitCode -eq 3010) {
          throw ".NET Framework 4.8 was installed, but a reboot is required. `n Please reboot the system and try to install/upgrade Chocolatey again."
        }
        if ($s.ExitCode -ne 0) {
            if ($netFx48InstallTries -ge 2) {
                Write-ChocolateyError ".NET Framework install failed with exit code `'$($s.ExitCode)`'. `n This will cause the rest of the install to fail."
                throw "Error installing .NET Framework 4.8 (exit code $($s.ExitCode)). `n Please install the .NET Framework 4.8 manually and reboot the system `n and then try to install/upgrade Chocolatey again. `n Download at `'$NetFx48Url`'"
            } else {
                Write-ChocolateyWarning "Try #$netFx48InstallTries of .NET framework install failed with exit code `'$($s.ExitCode)`'. Trying again."
                Install-DotNet48IfMissing $true
            }
        }
    }
}

function Invoke-Chocolatey-Initial {
    Write-Debug "Initializing Chocolatey files, etc by running Chocolatey..."

    try {
        $chocoInstallationFolder = Get-ChocolateyInstallFolder
        $chocoExe = Join-Path -Path $chocoInstallationFolder -ChildPath "choco.exe"
        & $chocoExe -v | Out-Null
        Write-Debug "Chocolatey execution completed successfully."
    }
    catch {
        Write-ChocolateyWarning "Unable to run Chocolatey at this time.  It is likely that .Net Framework installation requires a system reboot"
    }
}

Export-ModuleMember -Function Initialize-Chocolatey;

# SIG # Begin signature block
# MIIjgQYJKoZIhvcNAQcCoIIjcjCCI24CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCA39JLHX5VaGh4p
# OsPlBNITa6kB+jS84fiCu+fCNF4FhqCCHXowggUwMIIEGKADAgECAhAECRgbX9W7
# ZnVTQ7VvlVAIMA0GCSqGSIb3DQEBCwUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNV
# BAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0xMzEwMjIxMjAwMDBa
# Fw0yODEwMjIxMjAwMDBaMHIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xMTAvBgNVBAMTKERpZ2lD
# ZXJ0IFNIQTIgQXNzdXJlZCBJRCBDb2RlIFNpZ25pbmcgQ0EwggEiMA0GCSqGSIb3
# DQEBAQUAA4IBDwAwggEKAoIBAQD407Mcfw4Rr2d3B9MLMUkZz9D7RZmxOttE9X/l
# qJ3bMtdx6nadBS63j/qSQ8Cl+YnUNxnXtqrwnIal2CWsDnkoOn7p0WfTxvspJ8fT
# eyOU5JEjlpB3gvmhhCNmElQzUHSxKCa7JGnCwlLyFGeKiUXULaGj6YgsIJWuHEqH
# CN8M9eJNYBi+qsSyrnAxZjNxPqxwoqvOf+l8y5Kh5TsxHM/q8grkV7tKtel05iv+
# bMt+dDk2DZDv5LVOpKnqagqrhPOsZ061xPeM0SAlI+sIZD5SlsHyDxL0xY4PwaLo
# LFH3c7y9hbFig3NBggfkOItqcyDQD2RzPJ6fpjOp/RnfJZPRAgMBAAGjggHNMIIB
# yTASBgNVHRMBAf8ECDAGAQH/AgEAMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAK
# BggrBgEFBQcDAzB5BggrBgEFBQcBAQRtMGswJAYIKwYBBQUHMAGGGGh0dHA6Ly9v
# Y3NwLmRpZ2ljZXJ0LmNvbTBDBggrBgEFBQcwAoY3aHR0cDovL2NhY2VydHMuZGln
# aWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENBLmNydDCBgQYDVR0fBHow
# eDA6oDigNoY0aHR0cDovL2NybDQuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJl
# ZElEUm9vdENBLmNybDA6oDigNoY0aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0Rp
# Z2lDZXJ0QXNzdXJlZElEUm9vdENBLmNybDBPBgNVHSAESDBGMDgGCmCGSAGG/WwA
# AgQwKjAoBggrBgEFBQcCARYcaHR0cHM6Ly93d3cuZGlnaWNlcnQuY29tL0NQUzAK
# BghghkgBhv1sAzAdBgNVHQ4EFgQUWsS5eyoKo6XqcQPAYPkt9mV1DlgwHwYDVR0j
# BBgwFoAUReuir/SSy4IxLVGLp6chnfNtyA8wDQYJKoZIhvcNAQELBQADggEBAD7s
# DVoks/Mi0RXILHwlKXaoHV0cLToaxO8wYdd+C2D9wz0PxK+L/e8q3yBVN7Dh9tGS
# dQ9RtG6ljlriXiSBThCk7j9xjmMOE0ut119EefM2FAaK95xGTlz/kLEbBw6RFfu6
# r7VRwo0kriTGxycqoSkoGjpxKAI8LpGjwCUR4pwUR6F6aGivm6dcIFzZcbEMj7uo
# +MUSaJ/PQMtARKUT8OZkDCUIQjKyNookAv4vcn4c10lFluhZHen6dGRrsutmQ9qz
# sIzV6Q3d9gEgzpkxYz0IGhizgZtPxpMQBvwHgfqL2vmCSfdibqFT+hKUGIUukpHq
# aGxEMrJmoecYpJpkUe8wggU5MIIEIaADAgECAhAKudMQ+yEr6IyBs9LC6M5RMA0G
# CSqGSIb3DQEBCwUAMHIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJ
# bmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xMTAvBgNVBAMTKERpZ2lDZXJ0
# IFNIQTIgQXNzdXJlZCBJRCBDb2RlIFNpZ25pbmcgQ0EwHhcNMjEwNDI3MDAwMDAw
# WhcNMjQwNDMwMjM1OTU5WjB3MQswCQYDVQQGEwJVUzEPMA0GA1UECBMGS2Fuc2Fz
# MQ8wDQYDVQQHEwZUb3Bla2ExIjAgBgNVBAoTGUNob2NvbGF0ZXkgU29mdHdhcmUs
# IEluYy4xIjAgBgNVBAMTGUNob2NvbGF0ZXkgU29mdHdhcmUsIEluYy4wggEiMA0G
# CSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQChcaeNqeO3O3hzbDYYMcxvv/QNSPE4
# fpI+NGECR+FYdDO2utX9/SPxRCzWBrsgntPs/7IPk/uFZk/yTIiNoXO+cqJE45L9
# 2Ldfn6gAcwjGna/j2f/bbSFSeXW9z9lM3DJecFwXQleWR/8OKCnD+d1ZmHB0BA5v
# 0bQCfU8ZT7S0u9+KAKqyqgZrJyQiPfBVqXes9RSua7+0SVXmaBrJf9njHAf5KNFY
# /TEgm1r1zYwxfcsuE5eYdr2/suytUJpN18m9DmAdYm72va0KMxoKIBGuQy9DnaDI
# +nMiegsdhkL9sIysIin7Pcwjkwx9lRmtIqJA27Hfgb1MaL0OnkpwRY+VAgMBAAGj
# ggHEMIIBwDAfBgNVHSMEGDAWgBRaxLl7KgqjpepxA8Bg+S32ZXUOWDAdBgNVHQ4E
# FgQUTvMFGF2V6ylQalFt+afRXjSaBIMwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQM
# MAoGCCsGAQUFBwMDMHcGA1UdHwRwMG4wNaAzoDGGL2h0dHA6Ly9jcmwzLmRpZ2lj
# ZXJ0LmNvbS9zaGEyLWFzc3VyZWQtY3MtZzEuY3JsMDWgM6Axhi9odHRwOi8vY3Js
# NC5kaWdpY2VydC5jb20vc2hhMi1hc3N1cmVkLWNzLWcxLmNybDBLBgNVHSAERDBC
# MDYGCWCGSAGG/WwDATApMCcGCCsGAQUFBwIBFhtodHRwOi8vd3d3LmRpZ2ljZXJ0
# LmNvbS9DUFMwCAYGZ4EMAQQBMIGEBggrBgEFBQcBAQR4MHYwJAYIKwYBBQUHMAGG
# GGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBOBggrBgEFBQcwAoZCaHR0cDovL2Nh
# Y2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0U0hBMkFzc3VyZWRJRENvZGVTaWdu
# aW5nQ0EuY3J0MAwGA1UdEwEB/wQCMAAwDQYJKoZIhvcNAQELBQADggEBAKFxncHA
# zDFesUJXaM21qMRk5+nIZcDuISfGgJcDjMHsRLw7na5Yn7IhiNY+OsKnPVkfPhL/
# MNXSHG6on+IpxiB2/Bry9thqKvpQdPBe8mFN0ctJDgrSceyRC5SA9EiO22J3YNe0
# yVEKAG+Yk2A/WhKBzCCpRskMlRr7KeLm6DvAgvDsMfkKtePMl2PraON+tFNpc2b1
# LTKT4okiU5uAWpjYAt9sYBsKTeZb5NJt0ZQ3akEEIAQs63/mSDAZlzMOJMWNK/yv
# 4NU5CiPVcohJ0WjUJUIrAMmAVlZ2h8NhCXJOv28cHWEgPks/zqdDdIhJfDF+ALd1
# 0JTBrwCNcYQG68AwggWNMIIEdaADAgECAhAOmxiO+dAt5+/bUOIIQBhaMA0GCSqG
# SIb3DQEBDAUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMx
# GTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNVBAMTG0RpZ2lDZXJ0IEFz
# c3VyZWQgSUQgUm9vdCBDQTAeFw0yMjA4MDEwMDAwMDBaFw0zMTExMDkyMzU5NTla
# MGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsT
# EHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRydXN0ZWQgUm9v
# dCBHNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAL/mkHNo3rvkXUo8
# MCIwaTPswqclLskhPfKK2FnC4SmnPVirdprNrnsbhA3EMB/zG6Q4FutWxpdtHauy
# efLKEdLkX9YFPFIPUh/GnhWlfr6fqVcWWVVyr2iTcMKyunWZanMylNEQRBAu34Lz
# B4TmdDttceItDBvuINXJIB1jKS3O7F5OyJP4IWGbNOsFxl7sWxq868nPzaw0QF+x
# embud8hIqGZXV59UWI4MK7dPpzDZVu7Ke13jrclPXuU15zHL2pNe3I6PgNq2kZhA
# kHnDeMe2scS1ahg4AxCN2NQ3pC4FfYj1gj4QkXCrVYJBMtfbBHMqbpEBfCFM1Lyu
# GwN1XXhm2ToxRJozQL8I11pJpMLmqaBn3aQnvKFPObURWBf3JFxGj2T3wWmIdph2
# PVldQnaHiZdpekjw4KISG2aadMreSx7nDmOu5tTvkpI6nj3cAORFJYm2mkQZK37A
# lLTSYW3rM9nF30sEAMx9HJXDj/chsrIRt7t/8tWMcCxBYKqxYxhElRp2Yn72gLD7
# 6GSmM9GJB+G9t+ZDpBi4pncB4Q+UDCEdslQpJYls5Q5SUUd0viastkF13nqsX40/
# ybzTQRESW+UQUOsxxcpyFiIJ33xMdT9j7CFfxCBRa2+xq4aLT8LWRV+dIPyhHsXA
# j6KxfgommfXkaS+YHS312amyHeUbAgMBAAGjggE6MIIBNjAPBgNVHRMBAf8EBTAD
# AQH/MB0GA1UdDgQWBBTs1+OC0nFdZEzfLmc/57qYrhwPTzAfBgNVHSMEGDAWgBRF
# 66Kv9JLLgjEtUYunpyGd823IDzAOBgNVHQ8BAf8EBAMCAYYweQYIKwYBBQUHAQEE
# bTBrMCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wQwYIKwYB
# BQUHMAKGN2h0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFzc3Vy
# ZWRJRFJvb3RDQS5jcnQwRQYDVR0fBD4wPDA6oDigNoY0aHR0cDovL2NybDMuZGln
# aWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENBLmNybDARBgNVHSAECjAI
# MAYGBFUdIAAwDQYJKoZIhvcNAQEMBQADggEBAHCgv0NcVec4X6CjdBs9thbX979X
# B72arKGHLOyFXqkauyL4hxppVCLtpIh3bb0aFPQTSnovLbc47/T/gLn4offyct4k
# vFIDyE7QKt76LVbP+fT3rDB6mouyXtTP0UNEm0Mh65ZyoUi0mcudT6cGAxN3J0TU
# 53/oWajwvy8LpunyNDzs9wPHh6jSTEAZNUZqaVSwuKFWjuyk1T3osdz9HNj0d1pc
# VIxv76FQPfx2CWiEn2/K2yCNNWAcAgPLILCsWKAOQGPFmCLBsln1VWvPJ6tsds5v
# Iy30fnFqI2si/xK4VC0nftg62fC2h5b9W9FcrBjDTZ9ztwGpn1eqXijiuZQwggau
# MIIElqADAgECAhAHNje3JFR82Ees/ShmKl5bMA0GCSqGSIb3DQEBCwUAMGIxCzAJ
# BgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5k
# aWdpY2VydC5jb20xITAfBgNVBAMTGERpZ2lDZXJ0IFRydXN0ZWQgUm9vdCBHNDAe
# Fw0yMjAzMjMwMDAwMDBaFw0zNzAzMjIyMzU5NTlaMGMxCzAJBgNVBAYTAlVTMRcw
# FQYDVQQKEw5EaWdpQ2VydCwgSW5jLjE7MDkGA1UEAxMyRGlnaUNlcnQgVHJ1c3Rl
# ZCBHNCBSU0E0MDk2IFNIQTI1NiBUaW1lU3RhbXBpbmcgQ0EwggIiMA0GCSqGSIb3
# DQEBAQUAA4ICDwAwggIKAoICAQDGhjUGSbPBPXJJUVXHJQPE8pE3qZdRodbSg9Ge
# TKJtoLDMg/la9hGhRBVCX6SI82j6ffOciQt/nR+eDzMfUBMLJnOWbfhXqAJ9/UO0
# hNoR8XOxs+4rgISKIhjf69o9xBd/qxkrPkLcZ47qUT3w1lbU5ygt69OxtXXnHwZl
# jZQp09nsad/ZkIdGAHvbREGJ3HxqV3rwN3mfXazL6IRktFLydkf3YYMZ3V+0VAsh
# aG43IbtArF+y3kp9zvU5EmfvDqVjbOSmxR3NNg1c1eYbqMFkdECnwHLFuk4fsbVY
# TXn+149zk6wsOeKlSNbwsDETqVcplicu9Yemj052FVUmcJgmf6AaRyBD40NjgHt1
# biclkJg6OBGz9vae5jtb7IHeIhTZgirHkr+g3uM+onP65x9abJTyUpURK1h0QCir
# c0PO30qhHGs4xSnzyqqWc0Jon7ZGs506o9UD4L/wojzKQtwYSH8UNM/STKvvmz3+
# DrhkKvp1KCRB7UK/BZxmSVJQ9FHzNklNiyDSLFc1eSuo80VgvCONWPfcYd6T/jnA
# +bIwpUzX6ZhKWD7TA4j+s4/TXkt2ElGTyYwMO1uKIqjBJgj5FBASA31fI7tk42Pg
# puE+9sJ0sj8eCXbsq11GdeJgo1gJASgADoRU7s7pXcheMBK9Rp6103a50g5rmQzS
# M7TNsQIDAQABo4IBXTCCAVkwEgYDVR0TAQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQU
# uhbZbU2FL3MpdpovdYxqII+eyG8wHwYDVR0jBBgwFoAU7NfjgtJxXWRM3y5nP+e6
# mK4cD08wDgYDVR0PAQH/BAQDAgGGMBMGA1UdJQQMMAoGCCsGAQUFBwMIMHcGCCsG
# AQUFBwEBBGswaTAkBggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29t
# MEEGCCsGAQUFBzAChjVodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNl
# cnRUcnVzdGVkUm9vdEc0LmNydDBDBgNVHR8EPDA6MDigNqA0hjJodHRwOi8vY3Js
# My5kaWdpY2VydC5jb20vRGlnaUNlcnRUcnVzdGVkUm9vdEc0LmNybDAgBgNVHSAE
# GTAXMAgGBmeBDAEEAjALBglghkgBhv1sBwEwDQYJKoZIhvcNAQELBQADggIBAH1Z
# jsCTtm+YqUQiAX5m1tghQuGwGC4QTRPPMFPOvxj7x1Bd4ksp+3CKDaopafxpwc8d
# B+k+YMjYC+VcW9dth/qEICU0MWfNthKWb8RQTGIdDAiCqBa9qVbPFXONASIlzpVp
# P0d3+3J0FNf/q0+KLHqrhc1DX+1gtqpPkWaeLJ7giqzl/Yy8ZCaHbJK9nXzQcAp8
# 76i8dU+6WvepELJd6f8oVInw1YpxdmXazPByoyP6wCeCRK6ZJxurJB4mwbfeKuv2
# nrF5mYGjVoarCkXJ38SNoOeY+/umnXKvxMfBwWpx2cYTgAnEtp/Nh4cku0+jSbl3
# ZpHxcpzpSwJSpzd+k1OsOx0ISQ+UzTl63f8lY5knLD0/a6fxZsNBzU+2QJshIUDQ
# txMkzdwdeDrknq3lNHGS1yZr5Dhzq6YBT70/O3itTK37xJV77QpfMzmHQXh6OOmc
# 4d0j/R0o08f56PGYX/sr2H7yRp11LB4nLCbbbxV7HhmLNriT1ObyF5lZynDwN7+Y
# AN8gFk8n+2BnFqFmut1VwDophrCYoCvtlUG3OtUVmDG0YgkPCr2B2RP+v6TR81fZ
# vAT6gt4y3wSJ8ADNXcL50CN/AAvkdgIm2fBldkKmKYcJRyvmfxqkhQ/8mJb2VVQr
# H4D6wPIOK+XW+6kvRBVK5xMOHds3OBqhK/bt1nz8MIIGwjCCBKqgAwIBAgIQBUSv
# 85SdCDmmv9s/X+VhFjANBgkqhkiG9w0BAQsFADBjMQswCQYDVQQGEwJVUzEXMBUG
# A1UEChMORGlnaUNlcnQsIEluYy4xOzA5BgNVBAMTMkRpZ2lDZXJ0IFRydXN0ZWQg
# RzQgUlNBNDA5NiBTSEEyNTYgVGltZVN0YW1waW5nIENBMB4XDTIzMDcxNDAwMDAw
# MFoXDTM0MTAxMzIzNTk1OVowSDELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lD
# ZXJ0LCBJbmMuMSAwHgYDVQQDExdEaWdpQ2VydCBUaW1lc3RhbXAgMjAyMzCCAiIw
# DQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAKNTRYcdg45brD5UsyPgz5/X5dLn
# XaEOCdwvSKOXejsqnGfcYhVYwamTEafNqrJq3RApih5iY2nTWJw1cb86l+uUUI8c
# IOrHmjsvlmbjaedp/lvD1isgHMGXlLSlUIHyz8sHpjBoyoNC2vx/CSSUpIIa2mq6
# 2DvKXd4ZGIX7ReoNYWyd/nFexAaaPPDFLnkPG2ZS48jWPl/aQ9OE9dDH9kgtXkV1
# lnX+3RChG4PBuOZSlbVH13gpOWvgeFmX40QrStWVzu8IF+qCZE3/I+PKhu60pCFk
# cOvV5aDaY7Mu6QXuqvYk9R28mxyyt1/f8O52fTGZZUdVnUokL6wrl76f5P17cz4y
# 7lI0+9S769SgLDSb495uZBkHNwGRDxy1Uc2qTGaDiGhiu7xBG3gZbeTZD+BYQfvY
# sSzhUa+0rRUGFOpiCBPTaR58ZE2dD9/O0V6MqqtQFcmzyrzXxDtoRKOlO0L9c33u
# 3Qr/eTQQfqZcClhMAD6FaXXHg2TWdc2PEnZWpST618RrIbroHzSYLzrqawGw9/sq
# hux7UjipmAmhcbJsca8+uG+W1eEQE/5hRwqM/vC2x9XH3mwk8L9CgsqgcT2ckpME
# tGlwJw1Pt7U20clfCKRwo+wK8REuZODLIivK8SgTIUlRfgZm0zu++uuRONhRB8qU
# t+JQofM604qDy0B7AgMBAAGjggGLMIIBhzAOBgNVHQ8BAf8EBAMCB4AwDAYDVR0T
# AQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDAgBgNVHSAEGTAXMAgGBmeB
# DAEEAjALBglghkgBhv1sBwEwHwYDVR0jBBgwFoAUuhbZbU2FL3MpdpovdYxqII+e
# yG8wHQYDVR0OBBYEFKW27xPn783QZKHVVqllMaPe1eNJMFoGA1UdHwRTMFEwT6BN
# oEuGSWh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRHNFJT
# QTQwOTZTSEEyNTZUaW1lU3RhbXBpbmdDQS5jcmwwgZAGCCsGAQUFBwEBBIGDMIGA
# MCQGCCsGAQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wWAYIKwYBBQUH
# MAKGTGh0dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFRydXN0ZWRH
# NFJTQTQwOTZTSEEyNTZUaW1lU3RhbXBpbmdDQS5jcnQwDQYJKoZIhvcNAQELBQAD
# ggIBAIEa1t6gqbWYF7xwjU+KPGic2CX/yyzkzepdIpLsjCICqbjPgKjZ5+PF7SaC
# inEvGN1Ott5s1+FgnCvt7T1IjrhrunxdvcJhN2hJd6PrkKoS1yeF844ektrCQDif
# XcigLiV4JZ0qBXqEKZi2V3mP2yZWK7Dzp703DNiYdk9WuVLCtp04qYHnbUFcjGnR
# uSvExnvPnPp44pMadqJpddNQ5EQSviANnqlE0PjlSXcIWiHFtM+YlRpUurm8wWkZ
# us8W8oM3NG6wQSbd3lqXTzON1I13fXVFoaVYJmoDRd7ZULVQjK9WvUzF4UbFKNOt
# 50MAcN7MmJ4ZiQPq1JE3701S88lgIcRWR+3aEUuMMsOI5ljitts++V+wQtaP4xeR
# 0arAVeOGv6wnLEHQmjNKqDbUuXKWfpd5OEhfysLcPTLfddY2Z1qJ+Panx+VPNTwA
# vb6cKmx5AdzaROY63jg7B145WPR8czFVoIARyxQMfq68/qTreWWqaNYiyjvrmoI1
# VygWy2nyMpqy0tg6uLFGhmu6F/3Ed2wVbK6rr3M66ElGt9V/zLY4wNjsHPW2obhD
# LN9OTH0eaHDAdwrUAuBcYLso/zjlUlrWrBciI0707NMX+1Br/wd3H3GXREHJuEbT
# bDJ8WC9nR2XlG3O2mflrLAZG70Ee8PBf4NvZrZCARK+AEEGKMYIFXTCCBVkCAQEw
# gYYwcjELMAkGA1UEBhMCVVMxFTATBgNVBAoTDERpZ2lDZXJ0IEluYzEZMBcGA1UE
# CxMQd3d3LmRpZ2ljZXJ0LmNvbTExMC8GA1UEAxMoRGlnaUNlcnQgU0hBMiBBc3N1
# cmVkIElEIENvZGUgU2lnbmluZyBDQQIQCrnTEPshK+iMgbPSwujOUTANBglghkgB
# ZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJ
# AzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8G
# CSqGSIb3DQEJBDEiBCBFLl+A0p9h+sepDQ96ul6iO7UZYnw5NDDw6PXozxAfFTAN
# BgkqhkiG9w0BAQEFAASCAQCeFRsnOvmfbhN/7L/4EyenY1ti9i9Tal2yYqVK0quz
# gVbg+LBLFpkeWXT7ptqac6h0HI6DdOqUbzHv2k8179pmpczsfeRQ1G/cqPQ3JMyx
# 5XItx5E5QnwWX08Tr06lLjV8JFEWGYJh77M58++AXibj6W4OT3Z9vwpD5cgFSYf0
# LSCS9mt8JFBS7PXIt7Jp54uZbhY8CFzrII2Ff+gsEv0Zmiv5ucdK+yMCctXfmfpk
# KtI1RFNfCV+/TvA/wqtrKq1v6v/0AL9GBO+k+dqNSYzhizBRp3H9uAqdOgff5M7d
# nsrYr3bTVX9dn/NRZKwcTaUbAX6iuO942mVvTNSuZ7hsoYIDIDCCAxwGCSqGSIb3
# DQEJBjGCAw0wggMJAgEBMHcwYzELMAkGA1UEBhMCVVMxFzAVBgNVBAoTDkRpZ2lD
# ZXJ0LCBJbmMuMTswOQYDVQQDEzJEaWdpQ2VydCBUcnVzdGVkIEc0IFJTQTQwOTYg
# U0hBMjU2IFRpbWVTdGFtcGluZyBDQQIQBUSv85SdCDmmv9s/X+VhFjANBglghkgB
# ZQMEAgEFAKBpMBgGCSqGSIb3DQEJAzELBgkqhkiG9w0BBwEwHAYJKoZIhvcNAQkF
# MQ8XDTIzMDgwODA3MDgyOFowLwYJKoZIhvcNAQkEMSIEID/mNFNyb4KucIGUi+SK
# gRpAL0cW29y3JKe2qbmGgLxhMA0GCSqGSIb3DQEBAQUABIICAF05XG2oe2j7cyR0
# OUUDE7J4V/z0zvHQH0y2M4+yXLLAtxlYQetCGgxxDhVTtKIgvDbsYGEJudS2o1i5
# eInS9d1Bv4biJfUfc0VzCCNzTATLArPVgtTZSjW1Dxbom7w+afA09OlTwcMWeBj7
# v/o54zX2SGA9XeiK9chKnBIpoomMvDjuMwNO1BmEG7/vaNtS8N8/OrTV2GEI5NHS
# HU7n1jX8G0r/C7hq53HVD2GPMv0TLJw8j+tqYfnbhD7NVW4OPAUlen/IkNP09aTb
# 8O7U9iTN/tDrHA6FNkY5PfH/F3Rl8zhJumjQDmgMvcIL+Hucd3WCLdGHR0xGuCRK
# YTliO/M6NUE4osuRPBYzmbppS21rvWVI2B/4Ao2g5ieO6IlLDdmHK0izEErGPbJt
# dRWArapezTE6JOLF4NEEXt5D7X8hfqg/C+0530oAodD6Ya2PUBX2Yh4d13Md/kjh
# pVlUtKujM02pVnwIqWdHwwKr1QeGvw6n0ObiVWm3Jx49RKdp+hr3XL+aHhrfe0nm
# 3Hou2hkEvR5O0kBYK1+PGonYBqEP+8pE5e5zXqP2Ck93kdBx2uFEyLN91SXkjVLP
# sbByBolk39lBk50TyLCNKb9Lt5JjFGss8UMCMEZRUYiEbj63LMCzZ6p4RrVwd9Pa
# a0Q2DvsJN5ErWOGxTJGxHuMKeO9R
# SIG # End signature block
