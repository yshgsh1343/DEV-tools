param(
    [Parameter(Mandatory=$false)]
    [string]$BucketPath = ".",
    
    [Parameter(Mandatory=$false)]
    [int]$MaxAppsPerRun = 30,
    
    [Parameter(Mandatory=$false)]
    [int]$CheckIntervalHours = 24
)

# Add summary tracking
$summary = @{
    TotalManifests = 0
    AppsToCheck = 0
    AppsChecked = 0
    AppsUpdated = 0
    AppsWithErrors = 0
    Errors = @()
    Warnings = @()
    UpdatedApps = @()
}

# Configuration
$TrackerFile = Join-Path $BucketPath ".github/data/app-tracker.json"
$ManifestsPath = Join-Path $BucketPath "bucket"

Write-Host "##[group]🚀 Smart Updater Start" -ForegroundColor Blue
Write-Host "Bucket Path: $BucketPath" -ForegroundColor Cyan
Write-Host "Max Apps Per Run: $MaxAppsPerRun" -ForegroundColor Cyan
Write-Host "Check Interval: $CheckIntervalHours hours" -ForegroundColor Cyan

# Load tracker database
if (Test-Path $TrackerFile) {
    $trackerContent = Get-Content $TrackerFile -Raw
    if ($trackerContent.Trim() -ne "") {
        try {
            $tracker = $trackerContent | ConvertFrom-Json -AsHashtable
            Write-Host "Loaded tracker with $($tracker.Count) apps" -ForegroundColor Green
        } catch {
            Write-Host "##[warning]Failed to parse tracker, starting fresh" -ForegroundColor Yellow
            $tracker = @{}
        }
    } else {
        $tracker = @{}
        Write-Host "Tracker file empty, starting fresh" -ForegroundColor Yellow
    }
} else {
    $tracker = @{}
    Write-Host "No tracker file found, starting fresh" -ForegroundColor Yellow
}

# Get all manifests
$manifests = Get-ChildItem $ManifestsPath -Filter *.json
$summary.TotalManifests = $manifests.Count

Write-Host "Found $($manifests.Count) manifests" -ForegroundColor Cyan
Write-Host "##[endgroup]" -ForegroundColor Blue

# Calculate which apps to check
$appsToCheck = @()
$now = Get-Date

foreach ($manifest in $manifests) {
    $appName = $manifest.BaseName
    
    # Check if app is in tracker
    if ($tracker.ContainsKey($appName)) {
        try {
            $lastChecked = [datetime]::Parse($tracker[$appName].lastChecked)
            $hoursSinceCheck = ($now - $lastChecked).TotalHours
            
            # Skip if checked recently
            if ($hoursSinceCheck -lt $CheckIntervalHours) {
                continue
            }
            
            # Calculate priority score
            $updateFrequency = $tracker[$appName].updateFrequency
            $daysSinceUpdate = if ($tracker[$appName].lastUpdated) {
                ($now - [datetime]::Parse($tracker[$appName].lastUpdated)).TotalDays
            } else {
                365  # Never updated, high priority
            }
            
            $priorityScore = $daysSinceUpdate * $updateFrequency
            
            $appsToCheck += [PSCustomObject]@{
                Name = $appName
                Path = $manifest.FullName
                Priority = $priorityScore
                LastChecked = $lastChecked
                IsNew = $false
            }
        } catch {
            # Invalid tracker entry, treat as new
            $summary.Warnings += "Invalid tracker entry for $appName, resetting"
            $appsToCheck += [PSCustomObject]@{
                Name = $appName
                Path = $manifest.FullName
                Priority = 500
                LastChecked = $null
                IsNew = $true
            }
        }
    } else {
        # New app, high priority
        $appsToCheck += [PSCustomObject]@{
            Name = $appName
            Path = $manifest.FullName
            Priority = 1000
            LastChecked = $null
            IsNew = $true
        }
    }
}

$summary.AppsToCheck = $appsToCheck.Count

# Sort by priority (highest first) and take top N
$appsToCheck = $appsToCheck | Sort-Object Priority -Descending | Select-Object -First $MaxAppsPerRun

Write-Host "##[group]📋 Apps Selected for Check" -ForegroundColor Blue
Write-Host "Checking $($appsToCheck.Count) apps this run:" -ForegroundColor Green
$appsToCheck | ForEach-Object { 
    $status = if ($_.IsNew) { "NEW" } else { "EXISTING" }
    Write-Host "  - $($_.Name) (priority: $($_.Priority), status: $status)" 
}
Write-Host "##[endgroup]" -ForegroundColor Blue

# Setup Scoop
if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
    Write-Host "##[group]⬇️ Installing Scoop" -ForegroundColor Blue
    try {
        Invoke-RestMethod get.scoop.sh | Invoke-Expression
        Write-Host "Scoop installed successfully" -ForegroundColor Green
    } catch {
        Write-Host "##[error]Failed to install Scoop: $_" -ForegroundColor Red
        $summary.Errors += "Failed to install Scoop: $_"
        exit 1
    }
    Write-Host "##[endgroup]" -ForegroundColor Blue
}

# Add local bucket (using absolute path)
$bucketFullPath = Resolve-Path $BucketPath
Write-Host "##[group]📂 Adding Local Bucket" -ForegroundColor Blue
Write-Host "Bucket path: $bucketFullPath" -ForegroundColor Cyan

try {
    $bucketOutput = scoop.cmd bucket add local "$bucketFullPath" 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Bucket added successfully" -ForegroundColor Green
    } else {
        Write-Host "##[warning]Bucket add returned non-zero exit code: $LASTEXITCODE" -ForegroundColor Yellow
        Write-Host "Output: $bucketOutput" -ForegroundColor Gray
    }
} catch {
    Write-Host "##[warning]Error adding bucket: $_" -ForegroundColor Yellow
}
Write-Host "##[endgroup]" -ForegroundColor Blue

# Check each app
$checkedThisRun = @{}
Write-Host "##[group]🔍 Checking Apps" -ForegroundColor Blue

foreach ($app in $appsToCheck) {
    if ($checkedThisRun.ContainsKey($app.Name)) {
        Write-Host "  ⏭️  Skipping $($app.Name) - already checked" -ForegroundColor Gray
        continue
    }
    
    Write-Host "  🔍 Checking $($app.Name)..." -ForegroundColor Cyan
    
    try {
        # Run scoop checkver and apply manifest autoupdate changes
        $result = scoop.cmd checkver $app.Name --force --update 2>&1 | Out-String
        $summary.AppsChecked++
        
        # Check if update is available
        if ($result -match "(\S+)\s+->\s+(\S+)") {
            $oldVersion = $matches[1]
            $newVersion = $matches[2]
            
            Write-Host "    ✅ Update available: $oldVersion -> $newVersion" -ForegroundColor Green
            
            # Update tracker
            $tracker[$app.Name] = @{
                lastChecked = $now.ToString("o")
                lastUpdated = $now.ToString("o")
                currentVersion = $newVersion
                updateFrequency = 1.0
            }
            
            $summary.AppsUpdated++
            $summary.UpdatedApps += "$app.Name ($oldVersion → $newVersion)"
            
            # Add GitHub annotation for workflow
            Write-Host "##[group]📦 $($app.Name) Update Found" -ForegroundColor Green
            Write-Host "Old: $oldVersion" -ForegroundColor Gray
            Write-Host "New: $newVersion" -ForegroundColor Green
            Write-Host "##[endgroup]" -ForegroundColor Green
            
        } else {
            # No update found
            Write-Host "    ⏹️  No update available" -ForegroundColor Gray
            
            # Get current version from manifest
            $manifestContent = Get-Content $app.Path -Raw | ConvertFrom-Json
            $currentVersion = $manifestContent.version
            
            # Update tracker with last checked time
            if (-not $tracker.ContainsKey($app.Name)) {
                $tracker[$app.Name] = @{}
            }
            
            $tracker[$app.Name].lastChecked = $now.ToString("o")
            $tracker[$app.Name].currentVersion = $currentVersion
            
            # Adjust update frequency (reduce if no update)
            if ($tracker[$app.Name].updateFrequency) {
                $tracker[$app.Name].updateFrequency = [math]::Max(0.1, $tracker[$app.Name].updateFrequency * 0.95)
            } else {
                $tracker[$app.Name].updateFrequency = 0.5
            }
        }
    } catch {
        $errorMsg = "Error checking $($app.Name): $_"
        Write-Host "    ❌ $errorMsg" -ForegroundColor Red
        $summary.AppsWithErrors++
        $summary.Errors += $errorMsg
        
        # Still update tracker with error time
        if (-not $tracker.ContainsKey($app.Name)) {
            $tracker[$app.Name] = @{}
        }
        $tracker[$app.Name].lastChecked = $now.ToString("o")
        $tracker[$app.Name].updateFrequency = 0.1
    }
    
    $checkedThisRun[$app.Name] = $true
    
    # Small delay to avoid rate limits
    Start-Sleep -Milliseconds 300
}

Write-Host "##[endgroup]" -ForegroundColor Blue

# Save tracker
Write-Host "##[group]💾 Saving Tracker" -ForegroundColor Blue
try {
    $trackerJson = $tracker | ConvertTo-Json -Depth 3
    Set-Content -Path $TrackerFile -Value $trackerJson
    Write-Host "Tracker saved with $($tracker.Count) apps" -ForegroundColor Green
} catch {
    $errorMsg = "Failed to save tracker: $_"
    Write-Host "##[error]$errorMsg" -ForegroundColor Red
    $summary.Errors += $errorMsg
}
Write-Host "##[endgroup]" -ForegroundColor Blue

# Final summary
Write-Host "##[group]📊 Run Summary" -ForegroundColor Blue
Write-Host "Total Manifests: $($summary.TotalManifests)" -ForegroundColor Cyan
Write-Host "Apps Selected: $($summary.AppsToCheck)" -ForegroundColor Cyan
Write-Host "Apps Checked: $($summary.AppsChecked)" -ForegroundColor Cyan
Write-Host "Apps Updated: $($summary.AppsUpdated)" -ForegroundColor $(if ($summary.AppsUpdated -gt 0) { "Green" } else { "Gray" })
Write-Host "Apps with Errors: $($summary.AppsWithErrors)" -ForegroundColor $(if ($summary.AppsWithErrors -gt 0) { "Red" } else { "Gray" })

if ($summary.UpdatedApps.Count -gt 0) {
    Write-Host "`n✅ Updated Apps:" -ForegroundColor Green
    $summary.UpdatedApps | ForEach-Object { Write-Host "  - $_" -ForegroundColor Green }
}

if ($summary.Warnings.Count -gt 0) {
    Write-Host "`n⚠️ Warnings:" -ForegroundColor Yellow
    $summary.Warnings | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}

if ($summary.Errors.Count -gt 0) {
    Write-Host "`n❌ Errors:" -ForegroundColor Red
    $summary.Errors | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}
Write-Host "##[endgroup]" -ForegroundColor Blue

# Set workflow output
$hasUpdates = if ($summary.AppsUpdated -gt 0) { "true" } else { "false" }
if ($env:GITHUB_OUTPUT) {
    "apps_updated=$($summary.AppsUpdated)" >> $env:GITHUB_OUTPUT
    "apps_checked=$($summary.AppsChecked)" >> $env:GITHUB_OUTPUT
    "apps_with_errors=$($summary.AppsWithErrors)" >> $env:GITHUB_OUTPUT
    "has_updates=$hasUpdates" >> $env:GITHUB_OUTPUT
}

# Exit successfully; the workflow uses has_updates to decide whether to commit.
if ($summary.AppsUpdated -gt 0) {
    Write-Host "##[group]🚀 Updates Found - Commit Required" -ForegroundColor Green
    Write-Host "##[endgroup]" -ForegroundColor Green
} else {
    Write-Host "##[group]✅ No Updates Found" -ForegroundColor Gray
    Write-Host "##[endgroup]" -ForegroundColor Gray
}

exit 0
