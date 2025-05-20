<#
.SYNOPSIS
  Creates a “delta” deployment package containing ONLY files that changed
  between the specified number of past commits and HEAD.

.REQUIRES
  Git 2.x+, .NET SDK, MSBuild 16+

.NOTES
  Works with SDK-style projects (.NET 5/6/7/8) and old-style
  ASP.NET MVC/WebForms targeting .NET Framework 4.x.

#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [Parameter(Position = 0, HelpMessage = 'Path to the Git repository')]
    [string]$RepoPath,

    [Parameter(Position = 1, HelpMessage = 'Number of commits to include (1 = last commit)')]
    [ValidateRange(1, 100)]
    [int]$CommitCount,

    [Parameter(Position = 2, HelpMessage = 'Root folder for the delta package')]
    [string]$PackageRoot
)

begin {
    #--- Load optional JSON config (deltaConfig.json) -------------------
    $scriptDir = Split-Path $MyInvocation.MyCommand.Path
    $configPath = Join-Path $scriptDir 'deltaConfig.json'
    if (Test-Path $configPath) {
        try {
            $config = Get-Content -Raw -Path $configPath | ConvertFrom-Json
        }
        catch {
            Write-Warning "Could not parse config at $configPath"
        }
    }
    else {
        $config = [pscustomobject]@{}
    }

    $globalDefault = if ($config.DefaultOutputFolder) {
        $config.DefaultOutputFolder
    }
    else {
        $env:TEMP
    }

    $projects = if ($config.Projects) { $config.Projects } else { @() }

    #--- Prompt for RepoPath (predefined or custom) ----------------------
    if (-not $RepoPath -and $projects.Count -gt 0) {
        Write-Host "Available projects:"
        for ($i = 0; $i -lt $projects.Count; $i++) {
            $idx = $i + 1
            $proj = $projects[$i]
            Write-Host "  [$idx] $($proj.Name) — $($proj.RepoPath)"
        }
        Write-Host "  [0] Enter a new repository path"
        do {
            $sel = Read-Host "Select a project (0-$($projects.Count))"
        } until ($sel -match '^\d+$' -and $sel -ge 0 -and $sel -le $projects.Count)

        if ($sel -ne '0') {
            $chosen = $projects[$sel - 1]
            $RepoPath = $chosen.RepoPath
            if ($chosen.PackageRoot) {
                $PackageRoot = $chosen.PackageRoot
            }
            Write-Host "Using predefined project '$($chosen.Name)' at $RepoPath"
        }
    }

    #--- Prompt for any still-missing parameters ------------------------
    if (-not $RepoPath) {
        do {
            $RepoPath = Read-Host "Full path to the Git repo"
        } until (Test-Path $RepoPath -PathType Container)
    }

    if (-not $CommitCount) {
        do {
            $input = Read-Host "Number of commits to include (e.g. 1 for last commit)"
        } until ([int]::TryParse($input, [ref]$CommitCount) -and $CommitCount -ge 1)
    }

    ### default output folder uses globalDefault
    if (-not $PackageRoot) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $defaultRoot = Join-Path $globalDefault "DeployPackage-$stamp"
        $inputRoot = Read-Host "Output folder for the delta package (`Enter` for default: $defaultRoot)"
        if ($inputRoot) {
            $PackageRoot = $inputRoot
        }
        else {
            $PackageRoot = $defaultRoot
            Write-Host "Using default output folder: $PackageRoot"
        }
    }

    #--- Cleanup old packages (>7 days) ----------------------------------
    Get-ChildItem -Path $globalDefault -Filter 'DeployPackage-*' -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
    Remove-Item -Recurse -Force

    #--- Validate external dependencies ---------------------------------
    foreach ($cmd in 'git', 'dotnet') {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            Throw "$cmd is not installed or not in PATH."
        }
    }
    $msbuildCmd = (Get-Command msbuild.exe -ErrorAction SilentlyContinue)?.Source
    if (-not $msbuildCmd) {
        Write-Warning "msbuild.exe not found; .NET Framework projects will be skipped."
    }

    #--- Load static file extensions from optional config ---------------
    $staticExt = if ($config.StaticExtensions) {
        $config.StaticExtensions
    }
    else {
        @('.js', '.css', '.html', '.htm', '.cshtml', '.config',
            '.json', '.xml', '.png', '.jpg', '.jpeg', '.gif', '.svg', '.txt')
    }
}

process {
    Set-Location -Path $RepoPath

    #--- Determine commit range ------------------------------------------
    $range = "HEAD~$CommitCount..HEAD"
    Write-Host "`n📦 Building delta package for range $range`n"

    #--- List the commits ------------------------------------------------
    $commits = git log --pretty=format:'%h %s' -n $CommitCount $range
    Write-Host "Commits to include:"
    $commits -split "`n" | ForEach-Object { Write-Host "  - $_" }

    #--- Confirm to proceed ----------------------------------------------
    do {
        $confirmation = Read-Host "Proceed with these commits? (Y/N)"
    } until ($confirmation -match '^[YyNn]$')
    if ($confirmation -match '^[Nn]') {
        Write-Host "Operation cancelled by user."
        return
    }

    #--- Quick diffstat --------------------------------------------------
    $summary = git diff --shortstat $range
    Write-Host "`nChange summary: $summary`n"

    #--- Parse the diff --------------------------------------------------
    $diff = git diff --name-status $range | ForEach-Object {
        $parts = $_ -split "`t"
        [PSCustomObject]@{ Status = $parts[0]; Path = $parts[1] -replace '/', '\' }
    } | Where-Object { $_.Status -notmatch '^D' }

    #--- Classify files --------------------------------------------------
    $staticFiles = $diff | Where-Object {
        $staticExt -contains ([IO.Path]::GetExtension($_.Path).ToLowerInvariant())
    }
    $csFiles = $diff | Where-Object { $_.Path -like '*.cs' }

    #--- Dry-run preview -------------------------------------------------
    if ($PSBoundParameters.ContainsKey('WhatIf')) {
        Write-Host "[Preview] Would copy $($staticFiles.Count) static files"
        Write-Host "[Preview] Would build $($csFiles.Count) C# projects"
        return
    }

    #--- Copy static/resource files -------------------------------------
    Write-Host "Copying static/resource files..."
    $i = 0
    $total = $staticFiles.Count
    foreach ($f in $staticFiles) {
        $i++
        Write-Progress -Activity 'Copying static files' -Status $f.Path `
            -PercentComplete ([int]($i / $total * 100))
        $dest = Join-Path $PackageRoot $f.Path
        New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
        Copy-Item -LiteralPath $f.Path -Destination $dest -Force
    }
    Write-Progress -Activity 'Copying static files' -Completed

    #--- Identify C# projects --------------------------------------------
    $projSet = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($cs in $csFiles) {
        $dir = Split-Path $cs.Path
        do {
            $proj = Get-ChildItem -Path $dir -Filter *.csproj -ErrorAction SilentlyContinue |
            Select-Object -First 1
            $dir = Split-Path $dir -Parent
        } until ($proj -or -not $dir)
        if ($proj) { $projSet.Add($proj.FullName) | Out-Null }
    }

    if ($projSet.Count -eq 0) {
        Write-Host "No C# changes detected – only static files copied."
        Write-Host "`n✅ Done -> $PackageRoot"
        return
    }

    #--- Prepare temp build folder --------------------------------------
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $tempBuild = Join-Path $env:TEMP "DeltaBuild-$stamp"
    New-Item -ItemType Directory -Path $tempBuild -Force | Out-Null

    #--- Build projects --------------------------------------------------
    Write-Host "`nBuilding projects..."
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $projSet | ForEach-Object -Parallel {
            $projPath = $_
            $projName = [IO.Path]::GetFileNameWithoutExtension($projPath)
            $outDir = Join-Path $using:tempBuild $projName
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null

            # SDK-style if <Project Sdk=...> at top
            $isSdk = Select-String -Path $projPath -Pattern '<Project\s+Sdk\s*=' -Quiet

            if ($isSdk) {
                dotnet publish $projPath -c Release -o $outDir --nologo
            }
            else {
                if ($using:msbuildCmd) {
                    & $using:msbuildCmd $projPath /t:Build /p:Configuration=Release /p:OutDir="$outDir\" /nologo
                }
                else {
                    Write-Warning "Skipping framework project '$projName' because msbuild.exe was not found."
                    return
                }
            }

            $dll = Get-ChildItem -Path $outDir -Filter "$projName.dll" -Recurse |
            Select-Object -First 1
            if ($dll) {
                $projRel = (Split-Path $projPath -Parent) -replace [regex]::Escape($using:RepoPath), ''
                $trimmed = $projRel.TrimStart('\')
                $binDest = Join-Path $using:PackageRoot (Join-Path $trimmed 'bin')
                New-Item -ItemType Directory -Path $binDest -Force | Out-Null
                Copy-Item -LiteralPath $dll.FullName -Destination $binDest -Force
            }
            else {
                Write-Warning "Did not find $projName.dll after build."
            }
        } -ThrottleLimit ([Environment]::ProcessorCount)
    }
    else {
        foreach ($projPath in $projSet) {
            $projName = [IO.Path]::GetFileNameWithoutExtension($projPath)
            Write-Host " • $projName"
            $outDir = Join-Path $tempBuild $projName
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null

            $isSdk = Select-String -Path $projPath -Pattern '<Project\s+Sdk\s*=' -Quiet

            if ($isSdk) {
                dotnet publish $projPath -c Release -o $outDir --nologo
            }
            else {
                if ($msbuildCmd) {
                    & $msbuildCmd $projPath /t:Build /p:Configuration=Release /p:OutDir="$outDir\" /nologo
                }
                else {
                    Write-Warning "Skipping framework project '$projName' because msbuild.exe was not found."
                    continue
                }
            }

            $dll = Get-ChildItem -Path $outDir -Filter "$projName.dll" -Recurse |
            Select-Object -First 1
            if ($dll) {
                $projRel = (Split-Path $projPath -Parent) -replace [regex]::Escape($RepoPath), ''
                $trimmed = $projRel.TrimStart('\')
                $binDest = Join-Path $PackageRoot (Join-Path $trimmed 'bin')
                New-Item -ItemType Directory -Path $binDest -Force | Out-Null
                Copy-Item -LiteralPath $dll.FullName -Destination $binDest -Force
            }
            else {
                Write-Warning "Did not find $projName.dll after build."
            }      
        }
    }

    #--- Prompt to zip the package --------------------------------------
    $zipInput = Read-Host "Archive the package into a .zip? (Y/n)"
    $doZip = [string]::IsNullOrEmpty($zipInput) -or $zipInput -match '^[Yy]'
    if ($doZip) {
        $zipPath = "$PackageRoot.zip"
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        if ($PSCmdlet.ShouldProcess($PackageRoot, "Archive to $zipPath")) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [IO.Compression.ZipFile]::CreateFromDirectory($PackageRoot, $zipPath)
            Write-Host "🗜️  Archive created at $zipPath"
        }
    }
    else {
        Write-Host "Skipping archive."
    }

    #--- Cleanup intermediate build --------------------------------------
    if (Test-Path $tempBuild) {
        Remove-Item $tempBuild -Recurse -Force
    }

    #--- Final summary ---------------------------------------------------
    Write-Host "`n===== Summary ====="
    Write-Host " Static files copied: $($staticFiles.Count)"
    Write-Host " Projects built:      $($projSet.Count)"
    Write-Host " Package folder:      $PackageRoot"
    if ($doZip) {
        Write-Host " Archive created at:  $zipPath"
    }
    else {
        Write-Host " Archive: skipped"
    }
    Write-Host "=====================`n"
}