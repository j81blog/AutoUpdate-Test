[CmdletBinding()]
param(
    [string]$GithubRepository,

    [string]$GithubGistID,

    [string]$GithubGistFilename,

    [string]$Version,

    [string]$Channel
)

Import-Module -Name J81.PSScriptTools -Force -ErrorAction Stop
$owner, $repository = $GithubRepository -split '/'
$gistRawUrl = "https://gist.githubusercontent.com/$($owner)/$($GithubGistID)/raw/"
$VerbosePreference = 'Continue'
try {
    Write-Host "Fetching and parsing JSON from $($gistRawUrl)"
    $json = Invoke-RestMethod -Uri $gistRawUrl -ErrorAction Stop
    Write-Host "Successfully parsed Gist content."
} catch {
    Write-Error "Failed to fetch or parse Gist content. Error: $($_.Exception.Message)"
    exit 1
}

# Get the new version info from the previous step
Write-Host "New Version: $($Version), Channel: $($Channel)"

Write-Verbose "Retrieving release notes for version $($Version) in channel $($Channel) in repository $($owner)/$($repository)."
# Retrieve the release notes by name
$params = @{
    PersonalAccessToken = $env:PAT_TOKEN
    GithubOwner         = $owner
    GithubRepo          = $repository
    CommitName          = "v$Version"
    Github              = $true
}
$releaseNotes = Get-GitHubCommitDescriptionByName @params -ErrorAction Stop
Write-Verbose "Release notes retrieved: $($releaseNotes)"

# If a changelog entry for this new version doesn't exist, create one.
if (-not $json.changelog.$Version) {
    Write-Host "No changelog entry found for version $($Version). Creating a new one."

    # Find the previous version to copy dependencies from.
    $newEntry = $json.changelog._newversion
    if (-not [String]::IsNullOrEmpty($newEntry) -and ($newEntry | Get-Member -Type NoteProperty).Count -gt 0) {
        Write-Host "Used the template from the _newversion entry."
    } else {
        Write-Host "No template found for _newversion. Creating a new entry."
        $newEntry = @{
            CertificateSubject = ""
            dependencies       = @{
                minPSVersion = "5.1"
                modules      = @()
            }
            notes              = @()
        }
    }
    $json.changelog | Add-Member -MemberType NoteProperty -Name $Version -Value $newEntry
    $json.lastupdated = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
} else {
    Write-Host "Changelog entry for version $($Version) already exists."
}

# Update the 'notes' with the body from the GitHub release.
# We split the string by newlines and filter out any empty lines.
$notesArray = $releaseNotes -split [System.Environment]::NewLine | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$json.changelog.$Version.notes = $notesArray
Write-Host "Updated changelog notes for version $($Version)."

Write-Host "=========================================================="
Write-Host "New Release Notes:"
foreach ($note in $json.changelog.$Version.notes) {
    Write-Host "- $($note)"
}
Write-Host "=========================================================="
# Update the version number in the correct channel.
$json.channels.$Channel.version = $Version
Write-Host "Updated $($Channel) channel to version $($Version)."

# Convert the full, updated object back to JSON.
$newJsonString = $json | ConvertTo-Json -Depth 10

# Prepare the request body for updating the Gist
$body = @{
    description = "AutoUpdate Version Info - $($Version)"
    files       = @{
        "$($GithubGistFile)" = @{
            content = $newJsonString
        }
    }
}
# Prepare the headers for the API request
$headers = @{
    Authorization = "Bearer $($env:PAT_TOKEN)"
    Accept        = "application/vnd.github+json"
}
$gistUpdateUrl = "https://api.github.com/gists/$($GithubGistID)"
Write-Host "Updating Gist at $($gistUpdateUrl) with new content."
$response = Invoke-RestMethod -Uri $gistUpdateUrl -Method Patch -Headers $headers -Body ($body | ConvertTo-Json -Depth 6) -ErrorAction Stop
Write-Host "Gist updated successfully. Response: $($response | ConvertTo-Json -Depth 6)"