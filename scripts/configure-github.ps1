<#
  One-time GitHub repository configuration for Studio Stud.
  Uses the GitHub REST API directly — no gh CLI required.

  Prerequisites:
    A GitHub Personal Access Token (classic) with scopes:
      - repo  (full control of private repositories)
      OR for a public repo:
      - public_repo + admin:repo_hook

  How to get a token:
    GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)
    → Generate new token → check "repo" → copy it

  Usage:
    .\scripts\configure-github.ps1 -Token "ghp_xxxxxxxxxxxx"
    .\scripts\configure-github.ps1  # will prompt for token

  Branch model:
    development  →  (PR)  →  beta  →  (PR)  →  main
    ^ push here               ^ beta testers      ^ public release
#>
param(
    [string]$Token = '',
    [string]$Repo  = 'tyleradams2002/studio-stud'
)
$ErrorActionPreference = 'Stop'

if (-not $Token) {
    $secure = Read-Host "GitHub Personal Access Token" -AsSecureString
    $bstr   = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try   { $Token = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
if (-not $Token) { throw "Token is required." }

$headers = @{
    Authorization = "Bearer $Token"
    Accept        = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
}
$api = "https://api.github.com"

function Invoke-GH {
    param([string]$Method, [string]$Path, [hashtable]$Body = $null)
    $uri = "$api$Path"
    $params = @{ Uri=$uri; Method=$Method; Headers=$headers; ContentType='application/json' }
    if ($Body) { $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress) }
    try {
        Invoke-RestMethod @params
    } catch {
        $msg = $_.ErrorDetails.Message
        if ($msg) {
            $parsed = $msg | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($parsed.message) { throw "GitHub API error on $Method $Path : $($parsed.message)" }
        }
        throw $_
    }
}

# ---------- Verify token ----------
Write-Host "Verifying token..."
$me = Invoke-GH GET /user
Write-Host "  Authenticated as: $($me.login)"
Write-Host ""

# ---------- Branch protection ----------
function Set-BranchProtection {
    param(
        [string]$Branch,
        [bool]$RequirePr     = $false,
        [bool]$RequireChecks = $false,
        [bool]$EnforceAdmins = $false
    )

    $body = @{
        enforce_admins                = $EnforceAdmins
        restrictions                  = $null
        allow_force_pushes            = $false
        allow_deletions               = $false
        required_linear_history       = $false
        required_status_checks        = $null
        required_pull_request_reviews = $null
    }

    if ($RequireChecks) {
        $body.required_status_checks = @{
            strict   = $true
            contexts = @('Build & Test')
        }
    }

    if ($RequirePr) {
        $body.required_pull_request_reviews = @{
            required_approving_review_count = 0
            dismiss_stale_reviews           = $false
        }
    }

    Write-Host "  Protecting [$Branch]  (PR=$RequirePr, CI=$RequireChecks, enforceAdmins=$EnforceAdmins)"
    Invoke-GH PUT "/repos/$Repo/branches/$Branch/protection" -Body $body | Out-Null
    Write-Host "  OK"
}

Write-Host "=== Branch protection ==="
Set-BranchProtection -Branch 'main'        -RequirePr $true  -RequireChecks $true  -EnforceAdmins $true
Set-BranchProtection -Branch 'beta'        -RequirePr $true  -RequireChecks $true  -EnforceAdmins $false
Set-BranchProtection -Branch 'development' -RequirePr $false -RequireChecks $false -EnforceAdmins $false
Write-Host ""

# ---------- Actions environment ----------
Write-Host "=== Actions environment: release ==="
Invoke-GH PUT "/repos/$Repo/environments/release" -Body @{} | Out-Null
Write-Host "  Created."
Write-Host "  ACTION NEEDED: GitHub → Settings → Environments → release"
Write-Host "    → add yourself as a Required reviewer."
Write-Host ""

# ---------- GitHub Pages ----------
Write-Host "=== GitHub Pages ==="
try {
    Invoke-GH POST "/repos/$Repo/pages" -Body @{
        source = @{ branch = 'gh-pages'; path = '/' }
    } | Out-Null
    Write-Host "  Pages enabled from gh-pages branch."
} catch {
    if ($_ -match '409|already') {
        Write-Host "  Pages already enabled."
    } else {
        Write-Host "  Could not enable Pages: $_ (push a gh-pages branch first if needed)."
    }
}
Write-Host ""

# ---------- Summary ----------
Write-Host "=== Branch summary ==="
$branches = Invoke-GH GET "/repos/$Repo/branches"
$branches | ForEach-Object {
    Write-Host "  $($_.name.PadRight(16)) protected=$($_.protected)"
}
Write-Host ""
Write-Host "Setup complete. Your workflow:"
Write-Host "  1. Push work to  : development"
Write-Host "  2. Promote       : Actions → Promote → 'development → beta'"
Write-Host "  3. Promote       : Actions → Promote → 'beta → main'"
Write-Host "  4. Tag a release : git tag vX.Y.Z && git push origin vX.Y.Z"
