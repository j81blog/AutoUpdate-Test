<#
.SYNOPSIS
    A test script to demonstrate a self-contained auto-update functionality.

.DESCRIPTION
    This script includes a robust update-checking framework and performs a simple task
    to show which version is currently running. It fetches its version information from
    an external GitHub Gist and derives its own context, like its filename.

.NOTES
    Function Name   : Test-AutoUpdater.ps1
    Version         : v1.0.8
    Author          : John Billekens

.LINK
    https://blog.j81.nl
#>
[CmdletBinding()]
param (
    [Parameter(HelpMessage = "Automatically download and install the new version.")]
    [switch]$AutoUpdate,

    [Parameter(HelpMessage = "Restart the script with the same parameters after a successful update.")]
    [switch]$RestartAfterUpdate,

    [Parameter(HelpMessage = "Choose the update channel: 'stable' for releases, 'dev' for testing.")]
    [ValidateSet('stable', 'dev')]
    [string]$UpdateChannel = 'stable',

    [Parameter(HelpMessage = "Revert to the most recent backup (.bak) file.")]
    [switch]$Rollback,

    [Parameter(HelpMessage = "Skip the update check entirely.")]
    [switch]$NoUpdateCheck,

    [Parameter(HelpMessage = "Force a check for updates, even if the last check was recent.")]
    [Switch]$ForceCheckUpdate
)

# --- Script Configuration ---
$ScriptVersion = '1.0.11'
# The required certificate subject is now a fixed configuration variable for this script.
$RequiredCertificateSubject = 'CN=John Billekens Consultancy, O=John Billekens Consultancy, L=Schijndel, C=NL'

#================================================================================
# SECTION: SCRIPT AUTO-UPDATE FRAMEWORK
#================================================================================
function Invoke-ScriptUpdateCheck {
    <#
.SYNOPSIS
    Checks for a new version of the script and optionally performs an update.

.DESCRIPTION
    This function connects to a GitHub repository to check for new script versions based on a
    versioninfo.json file. It supports signed scripts via GitHub Releases, dependency checking,
    update throttling, and multiple update channels.

.PARAMETER CurrentVersion
    The version of the currently running script.

.PARAMETER AutoUpdate
    A switch to automatically download and apply an available update.

.PARAMETER RestartAfterUpdate
    A switch to restart the script with its original parameters after a successful update.

.PARAMETER UpdateChannel
    The update channel to check ('stable' or 'dev').

.PARAMETER Rollback
    A switch to initiate a rollback to the most recent backup file.

.PARAMETER NoUpdateCheck
    A switch to bypass the update check.

.PARAMETER CheckIntervalHours
    The number of hours to wait before checking for an update again.

.NOTES
    Function Name   : Invoke-ScriptUpdateCheck
    Version         : v1.0.5
    Author          : John Billekens

.LINK
    https://blog.j81.nl
#>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([boolean])]
    param (

        [Parameter(Mandatory = $true)]
        [string]$CurrentVersion,

        [Parameter(Mandatory = $false)]
        [switch]$AutoUpdate,

        [Parameter(Mandatory = $false)]
        [switch]$RestartAfterUpdate,

        [Parameter(Mandatory = $false)]
        [ValidateSet('stable', 'dev')]
        [string]$UpdateChannel = 'stable',

        [Parameter(Mandatory = $false)]
        [switch]$Rollback,

        [Parameter(Mandatory = $false)]
        [switch]$NoUpdateCheck,

        [Parameter(Mandatory = $false)]
        [int]$CheckIntervalHours = 24,

        [Parameter()]
        [Switch]$ForceCheckUpdate
    )

    #region --- CONFIGURATION ---
    $githubUser = "j81blog"
    $githubRepo = "AutoUpdate-Test"
    $jsonUrl = "https://gist.githubusercontent.com/$($githubUser)/27a5c52571bddc7eff4ea21f407d4e71/raw/versioninfo.json"

    # Script determines its own context
    $scriptFullName = (Get-Variable -Name MyInvocation -Scope 1).Value.MyCommand.Name
    $scriptPath = (Get-Variable -Name MyInvocation -Scope 1).Value.MyCommand.Path
    $scriptRoot = Split-Path -Path $scriptPath -Parent
    #endregion

    #region --- INITIAL CHECKS & MODES (Rollback/NoCheck) ---
    if ($NoUpdateCheck) {
        Write-Verbose -Message "Update check explicitly skipped."
        return $true
    }

    if ($Rollback) {
        $backupFile = Get-ChildItem -Path $scriptRoot -Filter "$($scriptFullName -replace '\.ps1$', '*.bak')" | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
        if (-not $backupFile) {
            Write-Error -Message "No backup file (.bak) found to roll back to."
            return $false
        }
        if ($PSCmdlet.ShouldProcess($scriptFullName, "Rollback to version from '$($backupFile.Name)'")) {
            $brokenScriptPath = "$($scriptPath).broken_$(Get-Date -Format 'yyyyMMddHHmmss')"
            Rename-Item -Path $scriptPath -NewName $brokenScriptPath
            Rename-Item -Path $backupFile.FullName -NewName $scriptFullName
            Write-Host "Rollback successful. Please start the script again." -ForegroundColor Green
        }
        exit
    }
    #endregion

    #region --- THROTTLING ---
    $lastCheckFile = Join-Path -Path $env:TEMP -ChildPath "$($scriptFullName)_lastupdatecheck.txt"
    if ((Test-Path -Path $lastCheckFile) -and $CheckIntervalHours -gt 0) {
        try {
            if ((-Not $ForceCheckUpdate) -and (Get-Date) -lt ([datetime]::FromFileTimeUtc($(Get-Content -Path $lastCheckFile))).AddHours($CheckIntervalHours)) {
                Write-Verbose -Message "Update check skipped; last check was recent."
                return $true
            }
        } catch {
            Write-Warning -Message "Could not parse last update check time. Checking now."
        }
    }
    #endregion

    #region --- FETCH UPDATE INFO ---
    Write-Verbose -Message "Checking for updates... (Channel: $($UpdateChannel))"
    try {
        $versionInfo = Invoke-RestMethod -Uri $jsonUrl -ErrorAction Stop
        Set-Content -Path $lastCheckFile -Value ((Get-Date).ToFileTimeUtc())
    } catch {
        Write-Warning -Message "Could not retrieve update information from Gist. Continuing with current version."
        return $true
    }

    $channelData = $versionInfo.channels.$UpdateChannel
    $latestVersionString = $channelData.version
    $currentVersionObj = [System.Version]$CurrentVersion
    $latestVersionObj = [System.Version]$latestVersionString
    #endregion

    #region --- VERSION & DEPENDENCY CHECK ---
    if ($channelData.forceUpdateBelowVersion -and ($currentVersionObj -lt [System.Version]$channelData.forceUpdateBelowVersion)) {
        Write-Error -Message "CRITICAL: Your script version ($($CurrentVersion)) is outdated. Update to $($latestVersionString) is required. Please run with '-AutoUpdate'."
        return $false
    }

    if ($latestVersionObj -le $currentVersionObj) {
        Write-Verbose -Message "Your script is up-to-date (Version: $($CurrentVersion))."
        return $true
    }

    Write-Host "A new version ($($latestVersionString)) is available for the '$($UpdateChannel)' channel!" -ForegroundColor Yellow

    $versionDetails = $versionInfo.changelog.$latestVersionString
    if ($versionDetails.notes) {
        Write-Host -Message "What's new:"
        $versionDetails.notes | ForEach-Object { Write-Host -Message " - $_" }
    }
    #endregion

    #region --- UPDATE EXECUTION ---
    if (-not $AutoUpdate) {
        Write-Host -Message "Run with '-AutoUpdate' to install."
        return $true
    }
    if (-not $PSCmdlet.ShouldProcess($scriptPath, "Update to version $($latestVersionString)")) {
        return $true
    }

    try {
        $releaseApiUrl = "https://api.github.com/repos/$($githubUser)/$($githubRepo)/releases/tags/v$($latestVersionString)"
        Write-Verbose -Message "Getting release information from $($releaseApiUrl)"
        $releaseInfo = Invoke-RestMethod -Uri $releaseApiUrl -ErrorAction Stop

        $downloadUrl = ($releaseInfo.assets | Where-Object { $_.name -eq $scriptFullName }).browser_download_url
        if (-not $downloadUrl) { throw "Could not find asset '$($scriptFullName)' in release '$($latestVersionString)'." }

        $tempPath = Join-Path -Path $env:TEMP -ChildPath $scriptFullName
        Write-Verbose -Message "Downloading signed script from $($downloadUrl)..."
        Invoke-WebRequest -Uri $downloadUrl -OutFile $tempPath -ErrorAction Stop

        Write-Verbose -Message "Verifying Authenticode signature..."
        $signature = Get-AuthenticodeSignature -FilePath $tempPath
        if ($signature.Status -ne 'Valid') { throw "Signature check failed! Status: $($signature.Status)." }

        # The function uses the $RequiredCertificateSubject variable from the parent script scope
        if ($signature.SignerCertificate.Subject -ne $RequiredCertificateSubject) { throw "Certificate subject mismatch! Expected '$($RequiredCertificateSubject)', but got '$($signature.SignerCertificate.Subject)'." }
        Write-Verbose -Message "Signature valid and matches expected subject."

        Unblock-File -Path $tempPath
        $backupPath = "$($scriptPath -replace '\.ps1$', "_v$($CurrentVersion).bak")"
        Rename-Item -Path $scriptPath -NewName $backupPath -Force -ErrorAction Stop
        Move-Item -Path $tempPath -Destination $scriptPath -Force -ErrorAction Stop
        Write-Host "Script successfully updated to version $($latestVersionString)." -ForegroundColor Green
    } catch {
        Write-Error -Message "Update failed: $($_.Exception.Message)"
        if (Test-Path -Path $backupPath) {
            Move-Item -Path $backupPath -Destination $scriptPath -Force
            Write-Host "Restored previous version." -ForegroundColor Green
        }
        return $false
    }

    if ($RestartAfterUpdate) {
        Write-Host -Message "Restarting script..."
        $currentPSEngine = (Get-Process -Id $PID).Path
        Write-Verbose -Message "Restarting with engine: $($currentPSEngine)"
        $restartCommand = (Get-Variable -Name MyInvocation -Scope 1).Value.Line
        Start-Process -FilePath $currentPSEngine -ArgumentList "-NoProfile -Command `"$(& {$restartCommand})`""
        exit
    }
    #endregion

    return $true
}


# --- SCRIPT EXECUTION ---
try {
    $updateCheckResult = Invoke-ScriptUpdateCheck `
        -CurrentVersion $ScriptVersion `
        -AutoUpdate:$AutoUpdate `
        -RestartAfterUpdate:$RestartAfterUpdate `
        -UpdateChannel:$UpdateChannel `
        -Rollback:$Rollback `
        -NoUpdateCheck:$NoUpdateCheck `
        -ForceCheckUpdate:$ForceCheckUpdate `
        -ErrorAction Stop

    # Stop the script if the update check returns a fatal error
    if (-not $updateCheckResult) {
        exit
    }
} catch {
    Write-Warning -Message "An unexpected error occurred in the update check: $($_.Exception.Message)"
}

# --- PAYLOAD ---
Write-Host -ForegroundColor Cyan "========================================"
Write-Host -ForegroundColor Cyan " Welcome to the Auto-Updater Test Script"
Write-Host -ForegroundColor Cyan " This is version: $($ScriptVersion)"
Write-Host -ForegroundColor Cyan "========================================"

