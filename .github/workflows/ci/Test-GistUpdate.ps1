[CmdletBinding()]
param(
    [string]$GithubRepository,

    [string]$GithubGistID,

    [string]$GithubGistFilename,

    [string]$Version,

    [string]$Channel

)

$owner, $repository = $GithubRepository -split '/'
$gistRawUrl = "https://gist.githubusercontent.com/$($owner)/$($GithubGistID)/raw/$($GithubGistFilename)"
Write-Host "Testing Gist update at $($gistRawUrl) for version $($Version) in channel $($Channel) to check if the version is set and contains release notes."
try {
    $json = Invoke-RestMethod -Uri $gistRawUrl -ErrorAction Stop
    Write-Host "Successfully fetched Gist content for testing."
    if ($json.channels.$Channel.version -eq $Version) {
        Write-Host "Version in Gist matches the expected version: $($Version)."
    } else {
        Write-Error "Version mismatch! Expected: $($Version), Found: $($json.channels.$Channel.version)"
        exit 1
    }
    if ($json.changelog.$Version -and $json.changelog.$Version.notes.Count -gt 0) {
        Write-Host "Release notes for version $($Version) are present in the Gist."
    } else {
        Write-Error "Release notes for version $($Version) are missing in the Gist."
        exit 1
    }
} catch {
    Write-Error "Failed to fetch Gist content for testing. Error: $($_.Exception.Message)"
    exit 1
}