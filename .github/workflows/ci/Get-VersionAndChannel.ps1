[CmdletBinding()]
param(
    [string]$GithubRepository,

    [string]$GithubEventReleaseTagName
)

$owner, $repository = $GithubRepository -split '/'
$tagName = $GithubEventReleaseTagName
$version = $tagName -replace '^v'

Write-Host "Tag Name: $tagName"
Write-Host "Version: $version"

$ReleaseUrl = "https://api.github.com/repos/$($owner)/$($repository)/releases/tags/$($tagName)"
$Headers = @{
    "Accept"               = "application/vnd.github+json"
    "Authorization"        = "Bearer ${env:GITHUB_TOKEN}"
    "X-GitHub-Api-Version" = "2022-11-28"
}

try {
    $ReleaseData = Invoke-RestMethod -Uri $ReleaseUrl -Headers $Headers
    $IsPrerelease = $ReleaseData.prerelease
    Write-Host "Release: '$tagName'; Pre-release: $IsPrerelease"
    if ($IsPrerelease) {
        $channel = 'dev'
    } else {
        $channel = 'stable'
    }
    Write-Host "Determined channel: $channel"
} catch {
    Write-Error "Failed to retrieve release information for '$tagName'. Error: $($_.Exception.Message)"
    exit 1
}

Write-Host "Storing channel and version in outputs."

if (-not [string]::IsNullOrEmpty($channel)) {
    Write-Host "Channel determined: $channel"
    Write-Output "channel=$channel" >> $env:GITHUB_OUTPUT
} else {
    Write-Error "Failed to determine channel for release '$tagName'."
    exit 1
}

if (-not [string]::IsNullOrEmpty($version)) {
    Write-Host "Version determined: $version"
    Write-Output "version=$version" >> $env:GITHUB_OUTPUT
} else {
    Write-Error "Failed to determine version for release '$tagName'."
    exit 1
}