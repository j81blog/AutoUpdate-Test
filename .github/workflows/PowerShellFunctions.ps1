<#
.SYNOPSIS
    Gets the full commit message for a given commit name (tag or SHA)
    from a GitHub repository using the REST API.

.PARAMETER PersonalAccessToken
    Your GitHub Personal Access Token with enough permissions (e.g., 'Contents' read).

.PARAMETER Owner
    The owner of the GitHub repository (e.g., 'owner').

.PARAMETER Repository
    The name of the GitHub repository (e.g., 'Hello-World').

.PARAMETER CommitName
    The name of the commit (e.g., tag name like 'My Commit Message Subject' or full commit SHA).

.EXAMPLE
    $PersonalAccessToken = "ghp_YOUR_PERSONAL_ACCESS_TOKEN" # Replace with your actual PAT
    $owner = "YourOrgOrUsername"
    $repository = "YourRepoName"
    $commitName = "My Commit Message Subject"

    Get-GitHubCommitDescriptionByName -PersonalAccessToken $PersonalAccessToken `
        -Owner $owner `
        -Repository $repository `
        -CommitName $commitName

.NOTES
    Version        : 1.0.1
    Author         : John Billekens
    Compatibility  : PowerShell 5.1+
    Requires       : Internet connection and valid GitHub PAT.
#>
function Get-GitHubCommitDescriptionByName {
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [Alias('PAT')]
        [string]$PersonalAccessToken,

        [Parameter(Mandatory = $true)]
        [string]$Owner,

        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$CommitName
    ) # End param

    Write-Verbose "Attempting to get full commit description for '$($CommitName)' from '$($Owner)/$($Repository)' using GitHub REST API."

    $headers = @{
        "Accept"               = "application/vnd.github+json"
        "Authorization"        = "Bearer $($PersonalAccessToken)"
        "X-GitHub-Api-Version" = "2022-11-28"
    } # End headers

    # First, try to get the commit directly. If $CommitName is a tag,
    # we might need to resolve it to a SHA first.
    # The 'ref' parameter can accept a SHA, branch name, or tag name.
    $commitApiUrl = "https://api.github.com/repos/$($Owner)/$($Repository)/commits/$($CommitName)"

    try {
        $commitResponse = Invoke-RestMethod -Uri $commitApiUrl -Headers $headers -Method Get

        # The full commit message is in the 'message' property of the 'commit' object
        # which typically includes both subject and body.
        # We want the body only. Often the first line is the subject, and the rest is the body.
        $fullCommitMessage = "$($commitResponse.commit.message)".Trim()
        $output = [PSCustomObject]@{
            Subject     = $null
            FullMessage = $fullCommitMessage.Trim()
            Description = $null
        }

        if ($null -ne $fullCommitMessage) {
            # Split the message into lines
            $messageLines = $fullCommitMessage.Split([Environment]::NewLine, [StringSplitOptions]::RemoveEmptyEntries)

            # The first line is usually the subject. The rest is the body.
            if ($messageLines.Count -gt 1) {
                Write-Verbose "Commit message contains multiple lines. Splitting into subject and body."
                # Skip the first line (subject) and join the remaining lines.
                $output.Subject = $messageLines[0]
                $output.CommitMessage = ($messageLines | Select-Object -Skip 1) -join [Environment]::NewLine
            } else {
                Write-Verbose "Commit message is a single line. Using it as both subject and commit message."
                # If there's only one line, it's just the subject/short description
                $output.Subject = $messageLines[0]
                $output.CommitMessage = $messageLines[0]
            }

        } else {
            Write-Warning "No commit message found for '$($CommitName)'."
            return $null
        }
        Write-Verbose "Successfully retrieved commit message for '$($CommitName)'."
    } catch {
        Write-Error "An error occurred while fetching commit details from GitHub API: $($_.Exception.Message)"
        return $null
    }
    Write-Verbose "Successfully retrieved commit details for '$($CommitName)'."
    # Return the full commit message
    return $output
}
