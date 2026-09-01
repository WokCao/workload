<#
Polls Docker Hub for a new digest of ca0huuqu0c/food-review-backend:dev and, when it
changes, rolls the food-review-backend Deployment in food-review-dev to pick it up.
Run this in its own terminal (or as a Scheduled Task) — it loops forever.

Requires: minikube running, kubectl/minikube on PATH.
#>
param(
    [string]$DockerHubUser = "ca0huuqu0c",
    [string]$Image = "food-review-backend",
    [string]$Tag = "dev",
    [string]$Namespace = "food-review-dev",
    [string]$Deployment = "food-review-backend",
    [int]$PollIntervalSeconds = 60
)

$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

$stateFile = Join-Path $PSScriptRoot ".last-digest-$Tag"
$lastDigest = if (Test-Path $stateFile) { (Get-Content $stateFile -Raw).Trim() } else { "" }

Write-Output "Watching docker.io/$DockerHubUser/$Image`:$Tag every $PollIntervalSeconds s (last known digest: $lastDigest)"

while ($true) {
    try {
        $resp = Invoke-RestMethod -Uri "https://hub.docker.com/v2/repositories/$DockerHubUser/$Image/tags/$Tag" -TimeoutSec 15
        $digest = $resp.digest

        if ($digest -and $digest -ne $lastDigest) {
            Write-Output "$(Get-Date -Format o) New digest detected: $digest (was: $(if ($lastDigest) { $lastDigest } else { '<none>' }))"

            minikube kubectl -- rollout restart "deployment/$Deployment" -n $Namespace
            minikube kubectl -- rollout status "deployment/$Deployment" -n $Namespace --timeout=200s

            if ($LASTEXITCODE -eq 0) {
                $digest | Set-Content $stateFile -NoNewline
                $lastDigest = $digest
                Write-Output "$(Get-Date -Format o) Redeploy done."
            } else {
                Write-Output "$(Get-Date -Format o) Rollout did not report success — will retry next poll without saving the new digest."
            }
        }
    } catch {
        Write-Output "$(Get-Date -Format o) Poll error: $_"
    }

    Start-Sleep -Seconds $PollIntervalSeconds
}
