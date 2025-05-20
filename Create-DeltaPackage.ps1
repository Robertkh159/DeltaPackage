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

[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low')]
param(
    [Parameter(Position=0, HelpMessage='Path to the Git repository')]
    [string]$RepoPath,

    [Parameter(Position=1, HelpMessage='Number of commits to include (1 = last commit)')]
    [ValidateRange(1,100)]
    [int]$CommitCount,

    [Parameter(Position=2, HelpMessage='Root folder for the delta package')]
    [string]$PackageRoot
)

begin {
    # If run without args, prompt for each
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

    if (-not $PackageRoot) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $PackageRoot = Join-Path $env:TEMP "DeployPackage-$stamp"
    }

    # Clean up old deploy packages (>7 days)
    Get-ChildItem -Path $env:TEMP -Filter 'DeployPackage-*' -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
      ForEach-Object { Remove-Item $_.FullName -Recurse -Force }

    # Validate external dependencies
    foreach ($cmd in 'git','dotnet') {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            Throw "$cmd is not installed or not in PATH."
        }
    }
    if (-not (Get-Command msbuild -ErrorAction SilentlyContinue)) {
        Write-Warning "msbuild not found; .NET Framework projects may fail to build."
    }

    # Load static file extensions from optional config
    $scriptDir  = Split-Path $MyInvocation.MyCommand.Path
    $configPath = Join-Path $scriptDir 'deltaConfig.json'
    if (Test-Path $configPath) {
        try { $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json } catch {}
    }
    $staticExt = if ($config?.StaticExtensions) { $config.StaticExtensions } else {
        @('.js','.css','.html','.htm','.cshtml','.config','.json','.xml',
          '.png','.jpg','.jpeg','.gif','.svg','.txt')
    }
}

process {
    Set-Location -Path $RepoPath

    # Build range and show commits + diffstat
    $range = "HEAD~$CommitCount..HEAD"
    Write-Host "`n📦 Building delta package for range $range`n"

    # List the commits
    $commits = git log --pretty=format:'%h %s' -n $CommitCount $range
    Write-Host "Commits to include:"
    $commits.Split("`n") | ForEach-Object { Write-Host "  - $_" }

    # Show quick diffstat
    $summary = git diff --shortstat $range
    Write-Host "`nChange summary: $summary`n"

    # Parse diff
    $gitOutput = git diff --name-status $range
    $diff = $gitOutput | ForEach-Object {
        $parts = $_ -split "`t"
        [PSCustomObject]@{ Status = $parts[0]; Path = $parts[1] -replace '/', '\' }
    } | Where-Object { $_.Status -notmatch '^D' }

    # Classify
    $staticFiles = $diff | Where-Object {
        $staticExt -contains ([IO.Path]::GetExtension($_.Path).ToLowerInvariant())
    }
    $csFiles = $diff | Where-Object { $_.Path -like '*.cs' }

    # Dry-run preview
    if ($PSBoundParameters.ContainsKey('WhatIf')) {
        Write-Host "[Preview] Would copy $($staticFiles.Count) static files"
        Write-Host "[Preview] Would build $($csFiles.Count) C# projects"
        return
    }

    # Copy static files
    Write-Host "Copying static/resource files..."
    $i = 0; $total = $staticFiles.Count
    foreach ($f in $staticFiles) {
        $i++
        Write-Progress -Activity 'Copying static files' -Status $f.Path -PercentComplete ([int]($i/$total*100))
        $dest = Join-Path $PackageRoot $f.Path
        New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
        Copy-Item -LiteralPath $f.Path -Destination $dest -Force
    }
    Write-Progress -Activity 'Copying static files' -Completed

    # Identify projects
    $projSet = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($cs in $csFiles) {
        $dir = Split-Path $cs.Path
        do {
            $proj = Get-ChildItem -Path $dir -Filter *.csproj -ErrorAction SilentlyContinue | Select-Object -First 1
            $dir  = Split-Path $dir -Parent
        } until ($proj -or -not $dir)
        if ($proj) { $projSet.Add($proj.FullName) | Out-Null }
    }

    if ($projSet.Count -eq 0) {
        Write-Host "No C# changes detected – only static files copied."
        Write-Host "`n✅ Done -> $PackageRoot"
        return
    }

    # Prepare build folder
    $stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
    $tempBuild = Join-Path $env:TEMP "DeltaBuild-$stamp"
    New-Item -ItemType Directory -Path $tempBuild -Force | Out-Null

    # Build projects (parallel on PS7+)
    Write-Host "`nBuilding projects..."
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $projSet | ForEach-Object -Parallel {
            $projPath = $_
            $projName = [IO.Path]::GetFileNameWithoutExtension($projPath)
            $outDir   = Join-Path $using:tempBuild $projName
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null

            if (Select-String -Path $projPath -Pattern '<TargetFramework' -Quiet) {
                dotnet publish $projPath -c Release -o $outDir --nologo
            } else {
                dotnet msbuild $projPath /t:Build /p:Configuration=Release /p:OutDir="$outDir\" /nologo
            }

            $dll = Get-ChildItem -Path $outDir -Filter "$projName.dll" -Recurse | Select-Object -First 1
            if ($dll) {
                $projRel = (Split-Path $projPath -Parent) -replace [regex]::Escape($using:RepoPath), ''
                $trimmed = $projRel.TrimStart('\')
                $binDest = Join-Path $using:PackageRoot (Join-Path $trimmed 'bin')
                New-Item -ItemType Directory -Path $binDest -Force | Out-Null
                Copy-Item -LiteralPath $dll.FullName -Destination $binDest -Force
            } else {
                Write-Warning "Did not find $projName.dll after build."
            }
        } -ThrottleLimit ([Environment]::ProcessorCount)
    } else {
        foreach ($projPath in $projSet) {
            $projName = [IO.Path]::GetFileNameWithoutExtension($projPath)
            Write-Host " • $projName"
            $outDir = Join-Path $tempBuild $projName
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null

            if (Select-String -Path $projPath -Pattern '<TargetFramework' -Quiet) {
                dotnet publish $projPath -c Release -o $outDir --nologo
            } else {
                dotnet msbuild $projPath /t:Build /p:Configuration=Release /p:OutDir="$outDir\" /nologo
            }

            $dll = Get-ChildItem -Path $outDir -Filter "$projName.dll" -Recurse | Select-Object -First 1
            if ($dll) {
                $projRel = (Split-Path $projPath -Parent) -replace [regex]::Escape($RepoPath), ''
                $trimmed = $projRel.TrimStart('\')
                $binDest = Join-Path $PackageRoot (Join-Path $trimmed 'bin')
                New-Item -ItemType Directory -Path $binDest -Force | Out-Null
                Copy-Item -LiteralPath $dll.FullName -Destination $binDest -Force
            } else {
                Write-Warning "Did not find $projName.dll after build."
            }
        }
    }

    # Archive the package
    $zipPath = "$PackageRoot.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    if ($PSCmdlet.ShouldProcess($PackageRoot, "Archive to $zipPath")) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($PackageRoot, $zipPath)
    }

    # Cleanup intermediate build
    if (Test-Path $tempBuild) { Remove-Item $tempBuild -Recurse -Force }

    # Final summary
    Write-Host "`n===== Summary ====="
    Write-Host " Static files copied: $($staticFiles.Count)"
    Write-Host " Projects built:      $($projSet.Count)"
    Write-Host " Package folder:      $PackageRoot"
    Write-Host " Archive created at:  $zipPath"
    Write-Host "=====================`n"
}
