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

[CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact='Low', DefaultParameterSetName='Delta')]
param(
    [Parameter(Mandatory=$true, Position=0, HelpMessage='Path to the Git repository')]
    [ValidateScript({ Test-Path $_ -PathType 'Container' })]
    [string]$RepoPath,

    [Parameter(Position=1, HelpMessage='Number of commits to include (1 = last commit)')]
    [ValidateRange(1,100)]
    [int]$CommitCount = 1,

    [Parameter(Position=2, HelpMessage='Root folder for the delta package')]
    [string]$PackageRoot = (Join-Path $env:TEMP "DeployPackage-$(Get-Date -Format 'yyyyMMdd-HHmmss')")
)

begin {
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
    $range     = "HEAD~$CommitCount..HEAD"
    Write-Verbose "Diff range: $range"

    # Run git diff
    $gitOutput = git diff --name-status $range 2>&1
    if ($LASTEXITCODE -ne 0) { Throw "git diff failed: $gitOutput" }

    # Parse diff
    $diff = $gitOutput | ForEach-Object {
        $parts = $_ -split "`t"
        [PSCustomObject]@{ Status = $parts[0]; Path = $parts[1] -replace '/', '\' }
    } | Where-Object { $_.Status -notmatch '^D' }

    # Classify files
    $staticFiles = $diff | Where-Object { $staticExt -contains ([IO.Path]::GetExtension($_.Path).ToLowerInvariant()) }
    $csFiles     = $diff | Where-Object { $_.Path -like '*.cs' }

    # Preview mode
    if ($PSBoundParameters.ContainsKey('WhatIf')) {
        Write-Host "[Preview] Would copy static files: $($staticFiles.Count)"
        Write-Host "[Preview] Would build C# projects: $($csFiles.Count)"
        return
    }

    # Copy static files
    $i = 0; $total = $staticFiles.Count
    foreach ($f in $staticFiles) {
        $i++ ; Write-Progress -Activity 'Copying static files' -Status $f.Path -PercentComplete ([int]($i/$total*100))
        $dest = Join-Path $PackageRoot $f.Path
        New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
        Copy-Item -LiteralPath $f.Path -Destination $dest -Force
    }
    Write-Progress -Activity 'Copying static files' -Completed

    # Identify C# projects
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
        Write-Host "No C# changes detected - only static files copied."
        Write-Host "Done -> $PackageRoot"
        return
    }

    # Prepare build folder
    $stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'
    $tempBuild = Join-Path $env:TEMP "DeltaBuild-$stamp"
    New-Item -ItemType Directory -Path $tempBuild -Force | Out-Null

    # Build projects
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $projSet | ForEach-Object -Parallel {
            $projPath = $_
            $projName = [IO.Path]::GetFileNameWithoutExtension($projPath)
            $outDir   = Join-Path $using:tempBuild $projName
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null

            $isSdk = Select-String -Path $projPath -Pattern '<TargetFramework' -Quiet
            if ($isSdk) {
                dotnet publish $projPath -c Release -o $outDir --nologo
            } else {
                dotnet msbuild $projPath /t:Build /p:Configuration=Release /p:OutDir="$outDir\" /nologo
            }

            # Copy DLL
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
            Write-Verbose "Building $projName"

            $outDir = Join-Path $tempBuild $projName
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
            $isSdk  = Select-String -Path $projPath -Pattern '<TargetFramework' -Quiet

            if ($isSdk) {
                dotnet publish $projPath -c Release -o $outDir --nologo
            } else {
                dotnet msbuild $projPath /t:Build /p:Configuration=Release /p:OutDir="$outDir\" /nologo
            }

            # Copy DLL
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
        Write-Host "🗜️  Archive created at $zipPath"
    }

    # Cleanup intermediate build
    if (Test-Path $tempBuild) {
        Remove-Item $tempBuild -Recurse -Force
    }

    # Summary
    [PSCustomObject]@{
        CopiedStaticFiles = $staticFiles.Count
        BuiltProjects      = $projSet.Count
        PackageFolder      = $PackageRoot
        Archive            = $zipPath
    } | Format-Table -AutoSize
}
