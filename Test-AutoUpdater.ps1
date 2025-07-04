<#
.SYNOPSIS
    A test script to demonstrate a self-contained auto-update functionality.

.DESCRIPTION
    This script includes a robust update-checking framework and performs a simple task
    to show which version is currently running. It fetches its version information from
    an external GitHub Gist and derives its own context, like its filename.

.NOTES
    Function Name   : Test-AutoUpdater.ps1
    Version         : v1.2.2
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
$ScriptVersion = '1.2.2'
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
        [Alias('ShowDevInfo')]
        [Switch]$ShowDevInfoIfNewerVersion = $false,

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
            if ($ForceCheckUpdate) {
                Write-Verbose -Message "Forced update check, ignoring last check time."
            } elseif ((Get-Date) -lt ([datetime]::FromFileTimeUtc($(Get-Content -Path $lastCheckFile))).AddHours($CheckIntervalHours)) {
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
        Write-Verbose -Message "Retrieved version information from $($jsonUrl)"
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
        Write-Verbose -Message "Your script is up-to-date (Latest Version: $($latestVersionString), Script Version: $($CurrentVersion))."
        return $true
    }

    Write-Host "`r`nA new version ($($latestVersionString)) is available for the '$($UpdateChannel)' channel!" -ForegroundColor Yellow

    $versionDetails = $versionInfo.changelog.$latestVersionString
    if ($versionDetails.notes -or $versionDetails.notes.Count -gt 0) {
        Write-Host -Message "`r`nRelease Notes for version $($latestVersionString):" -ForegroundColor Cyan
        $versionDetails.notes | ForEach-Object { Write-Host -Message " => $_" }
    }
    if (($ShowDevInfoIfNewerVersion -or $channelData.showDevInfo) -and [version]$versionInfo.channels.dev.version -gt $latestVersionObj) {
        Write-Host -Message "`r`nIMPORTANT: A newer development version ($($versionInfo.channels.dev.version)) is available in the 'dev' channel." -ForegroundColor Yellow
        Write-Host -Message "Consider switching to the 'dev' channel for the latest features and fixes." -ForegroundColor Yellow
        if ($versionInfo.changelog.$($versionInfo.channels.dev.version).notes -or $versionInfo.changelog.$($versionInfo.channels.dev.version).notes.Count -gt 0) {
            Write-Host -Message "`r`nDevelopment Release Notes for version $($versionInfo.channels.dev.version):" -ForegroundColor Cyan
            $versionInfo.changelog.$($versionInfo.channels.dev.version).notes | ForEach-Object { Write-Host -Message " => $_" }
        }
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
        Write-Verbose -Message "Downloading update from $($downloadUrl)..."
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



# SIG # Begin signature block
# MIImdwYJKoZIhvcNAQcCoIImaDCCJmQCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCUW4BXSbBQ21AI
# lq1QtZ3L9KXLTWRTmOHO1w7HrK5fJ6CCIAowggYUMIID/KADAgECAhB6I67aU2mW
# D5HIPlz0x+M/MA0GCSqGSIb3DQEBDAUAMFcxCzAJBgNVBAYTAkdCMRgwFgYDVQQK
# Ew9TZWN0aWdvIExpbWl0ZWQxLjAsBgNVBAMTJVNlY3RpZ28gUHVibGljIFRpbWUg
# U3RhbXBpbmcgUm9vdCBSNDYwHhcNMjEwMzIyMDAwMDAwWhcNMzYwMzIxMjM1OTU5
# WjBVMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSwwKgYD
# VQQDEyNTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIENBIFIzNjCCAaIwDQYJ
# KoZIhvcNAQEBBQADggGPADCCAYoCggGBAM2Y2ENBq26CK+z2M34mNOSJjNPvIhKA
# VD7vJq+MDoGD46IiM+b83+3ecLvBhStSVjeYXIjfa3ajoW3cS3ElcJzkyZlBnwDE
# JuHlzpbN4kMH2qRBVrjrGJgSlzzUqcGQBaCxpectRGhhnOSwcjPMI3G0hedv2eNm
# GiUbD12OeORN0ADzdpsQ4dDi6M4YhoGE9cbY11XxM2AVZn0GiOUC9+XE0wI7CQKf
# OUfigLDn7i/WeyxZ43XLj5GVo7LDBExSLnh+va8WxTlA+uBvq1KO8RSHUQLgzb1g
# bL9Ihgzxmkdp2ZWNuLc+XyEmJNbD2OIIq/fWlwBp6KNL19zpHsODLIsgZ+WZ1AzC
# s1HEK6VWrxmnKyJJg2Lv23DlEdZlQSGdF+z+Gyn9/CRezKe7WNyxRf4e4bwUtrYE
# 2F5Q+05yDD68clwnweckKtxRaF0VzN/w76kOLIaFVhf5sMM/caEZLtOYqYadtn03
# 4ykSFaZuIBU9uCSrKRKTPJhWvXk4CllgrwIDAQABo4IBXDCCAVgwHwYDVR0jBBgw
# FoAU9ndq3T/9ARP/FqFsggIv0Ao9FCUwHQYDVR0OBBYEFF9Y7UwxeqJhQo1SgLqz
# YZcZojKbMA4GA1UdDwEB/wQEAwIBhjASBgNVHRMBAf8ECDAGAQH/AgEAMBMGA1Ud
# JQQMMAoGCCsGAQUFBwMIMBEGA1UdIAQKMAgwBgYEVR0gADBMBgNVHR8ERTBDMEGg
# P6A9hjtodHRwOi8vY3JsLnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNUaW1lU3Rh
# bXBpbmdSb290UjQ2LmNybDB8BggrBgEFBQcBAQRwMG4wRwYIKwYBBQUHMAKGO2h0
# dHA6Ly9jcnQuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY1RpbWVTdGFtcGluZ1Jv
# b3RSNDYucDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdvLmNvbTAN
# BgkqhkiG9w0BAQwFAAOCAgEAEtd7IK0ONVgMnoEdJVj9TC1ndK/HYiYh9lVUacah
# RoZ2W2hfiEOyQExnHk1jkvpIJzAMxmEc6ZvIyHI5UkPCbXKspioYMdbOnBWQUn73
# 3qMooBfIghpR/klUqNxx6/fDXqY0hSU1OSkkSivt51UlmJElUICZYBodzD3M/SFj
# eCP59anwxs6hwj1mfvzG+b1coYGnqsSz2wSKr+nDO+Db8qNcTbJZRAiSazr7KyUJ
# Go1c+MScGfG5QHV+bps8BX5Oyv9Ct36Y4Il6ajTqV2ifikkVtB3RNBUgwu/mSiSU
# ice/Jp/q8BMk/gN8+0rNIE+QqU63JoVMCMPY2752LmESsRVVoypJVt8/N3qQ1c6F
# ibbcRabo3azZkcIdWGVSAdoLgAIxEKBeNh9AQO1gQrnh1TA8ldXuJzPSuALOz1Uj
# b0PCyNVkWk7hkhVHfcvBfI8NtgWQupiaAeNHe0pWSGH2opXZYKYG4Lbukg7HpNi/
# KqJhue2Keak6qH9A8CeEOB7Eob0Zf+fU+CCQaL0cJqlmnx9HCDxF+3BLbUufrV64
# EbTI40zqegPZdA+sXCmbcZy6okx/SjwsusWRItFA3DE8MORZeFb6BmzBtqKJ7l93
# 9bbKBy2jvxcJI98Va95Q5JnlKor3m0E7xpMeYRriWklUPsetMSf2NvUQa/E5vVye
# fQIwggZFMIIELaADAgECAhAIMk+dt9qRb2Pk8qM8Xl1RMA0GCSqGSIb3DQEBCwUA
# MFYxCzAJBgNVBAYTAlBMMSEwHwYDVQQKExhBc3NlY28gRGF0YSBTeXN0ZW1zIFMu
# QS4xJDAiBgNVBAMTG0NlcnR1bSBDb2RlIFNpZ25pbmcgMjAyMSBDQTAeFw0yNDA0
# MDQxNDA0MjRaFw0yNzA0MDQxNDA0MjNaMGsxCzAJBgNVBAYTAk5MMRIwEAYDVQQH
# DAlTY2hpam5kZWwxIzAhBgNVBAoMGkpvaG4gQmlsbGVrZW5zIENvbnN1bHRhbmN5
# MSMwIQYDVQQDDBpKb2huIEJpbGxla2VucyBDb25zdWx0YW5jeTCCAaIwDQYJKoZI
# hvcNAQEBBQADggGPADCCAYoCggGBAMslntDbSQwHZXwFhmibivbnd0Qfn6sqe/6f
# os3pKzKxEsR907RkDMet2x6RRg3eJkiIr3TFPwqBooyXXgK3zxxpyhGOcuIqyM9J
# 28DVf4kUyZHsjGO/8HFjrr3K1hABNUszP0o7H3o6J31eqV1UmCXYhQlNoW9FOmRC
# 1amlquBmh7w4EKYEytqdmdOBavAD5Xq4vLPxNP6kyA+B2YTtk/xM27TghtbwFGKn
# u9Vwnm7dFcpLxans4ONt2OxDQOMA5NwgcUv/YTpjhq9qoz6ivG55NRJGNvUXsM3w
# 2o7dR6Xh4MuEGrTSrOWGg2A5EcLH1XqQtkF5cZnAPM8W/9HUp8ggornWnFVQ9/6M
# ga+ermy5wy5XrmQpN+x3u6tit7xlHk1Hc+4XY4a4ie3BPXG2PhJhmZAn4ebNSBwN
# Hh8z7WTT9X9OFERepGSytZVeEP7hgyptSLcuhpwWeR4QdBb7dV++4p3PsAUQVHFp
# wkSbrRTv4EiJ0Lcz9P1HPGFoHiFAQQIDAQABo4IBeDCCAXQwDAYDVR0TAQH/BAIw
# ADA9BgNVHR8ENjA0MDKgMKAuhixodHRwOi8vY2NzY2EyMDIxLmNybC5jZXJ0dW0u
# cGwvY2NzY2EyMDIxLmNybDBzBggrBgEFBQcBAQRnMGUwLAYIKwYBBQUHMAGGIGh0
# dHA6Ly9jY3NjYTIwMjEub2NzcC1jZXJ0dW0uY29tMDUGCCsGAQUFBzAChilodHRw
# Oi8vcmVwb3NpdG9yeS5jZXJ0dW0ucGwvY2NzY2EyMDIxLmNlcjAfBgNVHSMEGDAW
# gBTddF1MANt7n6B0yrFu9zzAMsBwzTAdBgNVHQ4EFgQUO6KtBpOBgmrlANVAnyiQ
# C6W6lJwwSwYDVR0gBEQwQjAIBgZngQwBBAEwNgYLKoRoAYb2dwIFAQQwJzAlBggr
# BgEFBQcCARYZaHR0cHM6Ly93d3cuY2VydHVtLnBsL0NQUzATBgNVHSUEDDAKBggr
# BgEFBQcDAzAOBgNVHQ8BAf8EBAMCB4AwDQYJKoZIhvcNAQELBQADggIBAEQsN8wg
# PMdWVkwHPPTN+jKpdns5AKVFjcn00psf2NGVVgWWNQBIQc9lEuTBWb54IK6Ga3hx
# QRZfnPNo5HGl73YLmFgdFQrFzZ1lnaMdIcyh8LTWv6+XNWfoyCM9wCp4zMIDPOs8
# LKSMQqA/wRgqiACWnOS4a6fyd5GUIAm4CuaptpFYr90l4Dn/wAdXOdY32UhgzmSu
# xpUbhD8gVJUaBNVmQaRqeU8y49MxiVrUKJXde1BCrtR9awXbqembc7Nqvmi60tYK
# lD27hlpKtj6eGPjkht0hHEsgzU0Fxw7ZJghYG2wXfpF2ziN893ak9Mi/1dmCNmor
# GOnybKYfT6ff6YTCDDNkod4egcMZdOSv+/Qv+HAeIgEvrxE9QsGlzTwbRtbm6gwY
# YcVBs/SsVUdBn/TSB35MMxRhHE5iC3aUTkDbceo/XP3uFhVL4g2JZHpFfCSu2TQr
# rzRn2sn07jfMvzeHArCOJgBW1gPqR3WrJ4hUxL06Rbg1gs9tU5HGGz9KNQMfQFQ7
# 0Wz7UIhezGcFcRfkIfSkMmQYYpsc7rfzj+z0ThfDVzzJr2dMOFsMlfj1T6l22GBq
# 9XQx0A4lcc5Fl9pRxbOuHHWFqIBD/BCEhwniOCySzqENd2N+oz8znKooSISStnkN
# aYXt6xblJF2dx9Dn89FK7d1IquNxOwt0tI5dMIIGYjCCBMqgAwIBAgIRAKQpO24e
# 3denNAiHrXpOtyQwDQYJKoZIhvcNAQEMBQAwVTELMAkGA1UEBhMCR0IxGDAWBgNV
# BAoTD1NlY3RpZ28gTGltaXRlZDEsMCoGA1UEAxMjU2VjdGlnbyBQdWJsaWMgVGlt
# ZSBTdGFtcGluZyBDQSBSMzYwHhcNMjUwMzI3MDAwMDAwWhcNMzYwMzIxMjM1OTU5
# WjByMQswCQYDVQQGEwJHQjEXMBUGA1UECBMOV2VzdCBZb3Jrc2hpcmUxGDAWBgNV
# BAoTD1NlY3RpZ28gTGltaXRlZDEwMC4GA1UEAxMnU2VjdGlnbyBQdWJsaWMgVGlt
# ZSBTdGFtcGluZyBTaWduZXIgUjM2MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEA04SV9G6kU3jyPRBLeBIHPNyUgVNnYayfsGOyYEXrn3+SkDYTLs1crcw/
# ol2swE1TzB2aR/5JIjKNf75QBha2Ddj+4NEPKDxHEd4dEn7RTWMcTIfm492TW22I
# 8LfH+A7Ehz0/safc6BbsNBzjHTt7FngNfhfJoYOrkugSaT8F0IzUh6VUwoHdYDpi
# ln9dh0n0m545d5A5tJD92iFAIbKHQWGbCQNYplqpAFasHBn77OqW37P9BhOASdmj
# p3IijYiFdcA0WQIe60vzvrk0HG+iVcwVZjz+t5OcXGTcxqOAzk1frDNZ1aw8nFhG
# EvG0ktJQknnJZE3D40GofV7O8WzgaAnZmoUn4PCpvH36vD4XaAF2CjiPsJWiY/j2
# xLsJuqx3JtuI4akH0MmGzlBUylhXvdNVXcjAuIEcEQKtOBR9lU4wXQpISrbOT8ux
# +96GzBq8TdbhoFcmYaOBZKlwPP7pOp5Mzx/UMhyBA93PQhiCdPfIVOCINsUY4U23
# p4KJ3F1HqP3H6Slw3lHACnLilGETXRg5X/Fp8G8qlG5Y+M49ZEGUp2bneRLZoyHT
# yynHvFISpefhBCV0KdRZHPcuSL5OAGWnBjAlRtHvsMBrI3AAA0Tu1oGvPa/4yeei
# Ayu+9y3SLC98gDVbySnXnkujjhIh+oaatsk/oyf5R2vcxHahajMCAwEAAaOCAY4w
# ggGKMB8GA1UdIwQYMBaAFF9Y7UwxeqJhQo1SgLqzYZcZojKbMB0GA1UdDgQWBBSI
# YYyhKjdkgShgoZsx0Iz9LALOTzAOBgNVHQ8BAf8EBAMCBsAwDAYDVR0TAQH/BAIw
# ADAWBgNVHSUBAf8EDDAKBggrBgEFBQcDCDBKBgNVHSAEQzBBMDUGDCsGAQQBsjEB
# AgEDCDAlMCMGCCsGAQUFBwIBFhdodHRwczovL3NlY3RpZ28uY29tL0NQUzAIBgZn
# gQwBBAIwSgYDVR0fBEMwQTA/oD2gO4Y5aHR0cDovL2NybC5zZWN0aWdvLmNvbS9T
# ZWN0aWdvUHVibGljVGltZVN0YW1waW5nQ0FSMzYuY3JsMHoGCCsGAQUFBwEBBG4w
# bDBFBggrBgEFBQcwAoY5aHR0cDovL2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVi
# bGljVGltZVN0YW1waW5nQ0FSMzYuY3J0MCMGCCsGAQUFBzABhhdodHRwOi8vb2Nz
# cC5zZWN0aWdvLmNvbTANBgkqhkiG9w0BAQwFAAOCAYEAAoE+pIZyUSH5ZakuPVKK
# 4eWbzEsTRJOEjbIu6r7vmzXXLpJx4FyGmcqnFZoa1dzx3JrUCrdG5b//LfAxOGy9
# Ph9JtrYChJaVHrusDh9NgYwiGDOhyyJ2zRy3+kdqhwtUlLCdNjFjakTSE+hkC9F5
# ty1uxOoQ2ZkfI5WM4WXA3ZHcNHB4V42zi7Jk3ktEnkSdViVxM6rduXW0jmmiu71Z
# pBFZDh7Kdens+PQXPgMqvzodgQJEkxaION5XRCoBxAwWwiMm2thPDuZTzWp/gUFz
# i7izCmEt4pE3Kf0MOt3ccgwn4Kl2FIcQaV55nkjv1gODcHcD9+ZVjYZoyKTVWb4V
# qMQy/j8Q3aaYd/jOQ66Fhk3NWbg2tYl5jhQCuIsE55Vg4N0DUbEWvXJxtxQQaVR5
# xzhEI+BjJKzh3TQ026JxHhr2fuJ0mV68AluFr9qshgwS5SpN5FFtaSEnAwqZv3IS
# +mlG50rK7W3qXbWwi4hmpylUfygtYLEdLQukNEX1jiOKMIIGgjCCBGqgAwIBAgIQ
# NsKwvXwbOuejs902y8l1aDANBgkqhkiG9w0BAQwFADCBiDELMAkGA1UEBhMCVVMx
# EzARBgNVBAgTCk5ldyBKZXJzZXkxFDASBgNVBAcTC0plcnNleSBDaXR5MR4wHAYD
# VQQKExVUaGUgVVNFUlRSVVNUIE5ldHdvcmsxLjAsBgNVBAMTJVVTRVJUcnVzdCBS
# U0EgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkwHhcNMjEwMzIyMDAwMDAwWhcNMzgw
# MTE4MjM1OTU5WjBXMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1p
# dGVkMS4wLAYDVQQDEyVTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIFJvb3Qg
# UjQ2MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAiJ3YuUVnnR3d6Lkm
# gZpUVMB8SQWbzFoVD9mUEES0QUCBdxSZqdTkdizICFNeINCSJS+lV1ipnW5ihkQy
# C0cRLWXUJzodqpnMRs46npiJPHrfLBOifjfhpdXJ2aHHsPHggGsCi7uE0awqKggE
# /LkYw3sqaBia67h/3awoqNvGqiFRJ+OTWYmUCO2GAXsePHi+/JUNAax3kpqstbl3
# vcTdOGhtKShvZIvjwulRH87rbukNyHGWX5tNK/WABKf+Gnoi4cmisS7oSimgHUI0
# Wn/4elNd40BFdSZ1EwpuddZ+Wr7+Dfo0lcHflm/FDDrOJ3rWqauUP8hsokDoI7D/
# yUVI9DAE/WK3Jl3C4LKwIpn1mNzMyptRwsXKrop06m7NUNHdlTDEMovXAIDGAvYy
# nPt5lutv8lZeI5w3MOlCybAZDpK3Dy1MKo+6aEtE9vtiTMzz/o2dYfdP0KWZwZIX
# bYsTIlg1YIetCpi5s14qiXOpRsKqFKqav9R1R5vj3NgevsAsvxsAnI8Oa5s2oy25
# qhsoBIGo/zi6GpxFj+mOdh35Xn91y72J4RGOJEoqzEIbW3q0b2iPuWLA911cRxgY
# 5SJYubvjay3nSMbBPPFsyl6mY4/WYucmyS9lo3l7jk27MAe145GWxK4O3m3gEFEI
# kv7kRmefDR7Oe2T1HxAnICQvr9sCAwEAAaOCARYwggESMB8GA1UdIwQYMBaAFFN5
# v1qqK0rPVIDh2JvAnfKyA2bLMB0GA1UdDgQWBBT2d2rdP/0BE/8WoWyCAi/QCj0U
# JTAOBgNVHQ8BAf8EBAMCAYYwDwYDVR0TAQH/BAUwAwEB/zATBgNVHSUEDDAKBggr
# BgEFBQcDCDARBgNVHSAECjAIMAYGBFUdIAAwUAYDVR0fBEkwRzBFoEOgQYY/aHR0
# cDovL2NybC51c2VydHJ1c3QuY29tL1VTRVJUcnVzdFJTQUNlcnRpZmljYXRpb25B
# dXRob3JpdHkuY3JsMDUGCCsGAQUFBwEBBCkwJzAlBggrBgEFBQcwAYYZaHR0cDov
# L29jc3AudXNlcnRydXN0LmNvbTANBgkqhkiG9w0BAQwFAAOCAgEADr5lQe1oRLjl
# ocXUEYfktzsljOt+2sgXke3Y8UPEooU5y39rAARaAdAxUeiX1ktLJ3+lgxtoLQhn
# 5cFb3GF2SSZRX8ptQ6IvuD3wz/LNHKpQ5nX8hjsDLRhsyeIiJsms9yAWnvdYOdEM
# q1W61KE9JlBkB20XBee6JaXx4UBErc+YuoSb1SxVf7nkNtUjPfcxuFtrQdRMRi/f
# InV/AobE8Gw/8yBMQKKaHt5eia8ybT8Y/Ffa6HAJyz9gvEOcF1VWXG8OMeM7Vy7B
# s6mSIkYeYtddU1ux1dQLbEGur18ut97wgGwDiGinCwKPyFO7ApcmVJOtlw9FVJxw
# /mL1TbyBns4zOgkaXFnnfzg4qbSvnrwyj1NiurMp4pmAWjR+Pb/SIduPnmFzbSN/
# G8reZCL4fvGlvPFk4Uab/JVCSmj59+/mB2Gn6G/UYOy8k60mKcmaAZsEVkhOFuoj
# 4we8CYyaR9vd9PGZKSinaZIkvVjbH/3nlLb0a7SBIkiRzfPfS9T+JesylbHa1LtR
# V9U/7m0q7Ma2CQ/t392ioOssXW7oKLdOmMBl14suVFBmbzrt5V5cQPnwtd3UOTpS
# 9oCG+ZZheiIvPgkDmA8FzPsnfXW5qHELB43ET7HHFHeRPRYrMBKjkb8/IN7Po0d0
# hQoF4TeMM+zYAJzoKQnVKOLg8pZVPT8wgga5MIIEoaADAgECAhEAmaOACiZVO2Wr
# 3G6EprPqOTANBgkqhkiG9w0BAQwFADCBgDELMAkGA1UEBhMCUEwxIjAgBgNVBAoT
# GVVuaXpldG8gVGVjaG5vbG9naWVzIFMuQS4xJzAlBgNVBAsTHkNlcnR1bSBDZXJ0
# aWZpY2F0aW9uIEF1dGhvcml0eTEkMCIGA1UEAxMbQ2VydHVtIFRydXN0ZWQgTmV0
# d29yayBDQSAyMB4XDTIxMDUxOTA1MzIxOFoXDTM2MDUxODA1MzIxOFowVjELMAkG
# A1UEBhMCUEwxITAfBgNVBAoTGEFzc2VjbyBEYXRhIFN5c3RlbXMgUy5BLjEkMCIG
# A1UEAxMbQ2VydHVtIENvZGUgU2lnbmluZyAyMDIxIENBMIICIjANBgkqhkiG9w0B
# AQEFAAOCAg8AMIICCgKCAgEAnSPPBDAjO8FGLOczcz5jXXp1ur5cTbq96y34vuTm
# flN4mSAfgLKTvggv24/rWiVGzGxT9YEASVMw1Aj8ewTS4IndU8s7VS5+djSoMcbv
# IKck6+hI1shsylP4JyLvmxwLHtSworV9wmjhNd627h27a8RdrT1PH9ud0IF+njvM
# k2xqbNTIPsnWtw3E7DmDoUmDQiYi/ucJ42fcHqBkbbxYDB7SYOouu9Tj1yHIohzu
# C8KNqfcYf7Z4/iZgkBJ+UFNDcc6zokZ2uJIxWgPWXMEmhu1gMXgv8aGUsRdaCtVD
# 2bSlbfsq7BiqljjaCun+RJgTgFRCtsuAEw0pG9+FA+yQN9n/kZtMLK+Wo837Q4QO
# ZgYqVWQ4x6cM7/G0yswg1ElLlJj6NYKLw9EcBXE7TF3HybZtYvj9lDV2nT8mFSkc
# SkAExzd4prHwYjUXTeZIlVXqj+eaYqoMTpMrfh5MCAOIG5knN4Q/JHuurfTI5XDY
# O962WZayx7ACFf5ydJpoEowSP07YaBiQ8nXpDkNrUA9g7qf/rCkKbWpQ5boufUnq
# 1UiYPIAHlezf4muJqxqIns/kqld6JVX8cixbd6PzkDpwZo4SlADaCi2JSplKShBS
# ND36E/ENVv8urPS0yOnpG4tIoBGxVCARPCg1BnyMJ4rBJAcOSnAWd18Jx5n858JS
# qPECAwEAAaOCAVUwggFRMA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFN10XUwA
# 23ufoHTKsW73PMAywHDNMB8GA1UdIwQYMBaAFLahVDkCw6A/joq8+tT4HKbROg79
# MA4GA1UdDwEB/wQEAwIBBjATBgNVHSUEDDAKBggrBgEFBQcDAzAwBgNVHR8EKTAn
# MCWgI6Ahhh9odHRwOi8vY3JsLmNlcnR1bS5wbC9jdG5jYTIuY3JsMGwGCCsGAQUF
# BwEBBGAwXjAoBggrBgEFBQcwAYYcaHR0cDovL3N1YmNhLm9jc3AtY2VydHVtLmNv
# bTAyBggrBgEFBQcwAoYmaHR0cDovL3JlcG9zaXRvcnkuY2VydHVtLnBsL2N0bmNh
# Mi5jZXIwOQYDVR0gBDIwMDAuBgRVHSAAMCYwJAYIKwYBBQUHAgEWGGh0dHA6Ly93
# d3cuY2VydHVtLnBsL0NQUzANBgkqhkiG9w0BAQwFAAOCAgEAdYhYD+WPUCiaU58Q
# 7EP89DttyZqGYn2XRDhJkL6P+/T0IPZyxfxiXumYlARMgwRzLRUStJl490L94C9L
# GF3vjzzH8Jq3iR74BRlkO18J3zIdmCKQa5LyZ48IfICJTZVJeChDUyuQy6rGDxLU
# UAsO0eqeLNhLVsgw6/zOfImNlARKn1FP7o0fTbj8ipNGxHBIutiRsWrhWM2f8pXd
# d3x2mbJCKKtl2s42g9KUJHEIiLni9ByoqIUul4GblLQigO0ugh7bWRLDm0CdY9rN
# LqyA3ahe8WlxVWkxyrQLjH8ItI17RdySaYayX3PhRSC4Am1/7mATwZWwSD+B7eMc
# ZNhpn8zJ+6MTyE6YoEBSRVrs0zFFIHUR08Wk0ikSf+lIe5Iv6RY3/bFAEloMU+vU
# BfSouCReZwSLo8WdrDlPXtR0gicDnytO7eZ5827NS2x7gCBibESYkOh1/w1tVxTp
# V2Na3PR7nxYVlPu1JPoRZCbH86gc96UTvuWiOruWmyOEMLOGGniR+x+zPF/2DaGg
# K2W1eEJfo2qyrBNPvF7wuAyQfiFXLwvWHamoYtPZo0LHuH8X3n9C+xN4YaNjt2yw
# zOr+tKyEVAotnyU9vyEVOaIYMk3IeBrmFnn0gbKeTTyYeEEUz/Qwt4HOUBCrW602
# NCmvO1nm+/80nLy5r0AZvCQxaQ4xggXDMIIFvwIBATBqMFYxCzAJBgNVBAYTAlBM
# MSEwHwYDVQQKExhBc3NlY28gRGF0YSBTeXN0ZW1zIFMuQS4xJDAiBgNVBAMTG0Nl
# cnR1bSBDb2RlIFNpZ25pbmcgMjAyMSBDQQIQCDJPnbfakW9j5PKjPF5dUTANBglg
# hkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3AgEMMQowCKACgAChAoAAMBkGCSqGSIb3
# DQEJAzEMBgorBgEEAYI3AgEEMBwGCisGAQQBgjcCAQsxDjAMBgorBgEEAYI3AgEV
# MC8GCSqGSIb3DQEJBDEiBCCDU/9bOzjlOOdhZZEkfTKf5L6A6TWR8+If2MunIeXW
# 7DANBgkqhkiG9w0BAQEFAASCAYCxTTzTa8hsYDJqKdlY91yPBD6bK6rbbHC7+cIF
# EiFKcWIyIqqdGToxyysK5mG631dU2+lFFyBsGGVYigj+TUhmZmpad8saCBqxi0hx
# umKfEf2J4wxAWGNbHmgzAVax4lrtaT98xCCWwoYS1o7OV/ln1/w5I1XUzdR/+ORY
# QvQbLiZndvdGEjboWwq1FWeZDkful+aYgIdhDuvw4NZDe8KZX7AS43f7OJa5wpg+
# t3KPx3y6FLcN4ctxVDfumTFXyd7t1EhLXY4WduEE64WY5R9Gmiu2YePqzNg3uiEi
# AkXwXZSnVy35lmwXYmFNF4FLU1143h2dYh840429i6jwG17iUlFUCt1KJiMaVvBx
# aXoRDHR988dkY8a+F18oJ7aZGCyyca+7PGzM+74DQpdJj5V37eREG9XlXTcPEW+t
# XD+zABK/FTN1fCEYPVEIO0w/lIrtlomuzeh+4+JmIKgm/KCVnE1xnMZleM0lr+j6
# x6jfJt6/gXThKZXG0Lr8vrXAWQWhggMjMIIDHwYJKoZIhvcNAQkGMYIDEDCCAwwC
# AQEwajBVMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMSww
# KgYDVQQDEyNTZWN0aWdvIFB1YmxpYyBUaW1lIFN0YW1waW5nIENBIFIzNgIRAKQp
# O24e3denNAiHrXpOtyQwDQYJYIZIAWUDBAICBQCgeTAYBgkqhkiG9w0BCQMxCwYJ
# KoZIhvcNAQcBMBwGCSqGSIb3DQEJBTEPFw0yNTA3MDQxOTAwNDZaMD8GCSqGSIb3
# DQEJBDEyBDDyOiykQ5MiFwa5iKl4NqCSULgVBPe+UC9EWmCC85/3uDdrv8ksAsfo
# QEN4hL1I2pUwDQYJKoZIhvcNAQEBBQAEggIAgMAaRA9C3JTYrHfoI6E8DFcnIbfo
# QgJ8Y488KPN82tENx75aIREU/LN65E6B/AiktccKdiNyhP0BPIEZ/KUzQfr3si4/
# BolUo3U8zK0YwKykOpQK1nudpIjl7nPREjuyngDnGuDDzNvEZ4f3FM6Zw1wG38Y9
# nvbA5SennZ8BQ8C2VdeoL6baFlBIZ7Cmi44/54GCTA6Llfjun4dirBfK9bBarD2/
# 7htXTxB2qCvRhmwl4ThTg8DtrzsS3O+K4YUrpBx5max4tVMCH1ueCPp1qbRBBMGu
# MOMwvNMOyyBjQfZ8BsWrFrTmj0kcJLuHTkqBbiQ32CJOvKMUiHAnHPVu4CeXqSpq
# xSYgysEIHAYOh6F8MtuzUWZ6syGY0NoQoHQQ++AfJVEY4J/LxJX8QRHdsAbEa9t9
# w56Rtz+ecghB+PwtdlHSRNVVhrNxSaALJFX/mISTlE3rquJmrsCgKmFUTGlvh5fN
# yG/2U0O9oyLLmrGjc9b+luHNHD1sfFGJpAuh6pHaCDv2qnSENFoSy0ri1gmOuhuj
# 9Oq4aZtyFqTy3eJoJranu9tXf7ROFUUFLWvdryCVsJxS1nBoyUFBk5j0XF4Ujrb3
# G9G5YVS6ShUSqC/2l/i1jIpHHkP/2rdGcG4lbNgMwcpIc66sPpdARbDIJJZCUXNN
# ziC9S6XzKHg1BCg=
# SIG # End signature block
