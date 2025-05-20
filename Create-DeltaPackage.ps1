<#
 .SYNOPSIS
   Creates a “delta” deployment package containing ONLY files that changed
   between two git commits.

 .REQUIRES
   Git 2.x+, dotnet SDK, MSBuild 16+

 .NOTES
   Works with SDK-style projects (.NET 5/6/7/8) and old-style
   ASP.NET MVC / WebForms projects targeting .NET Framework 4.x.
#>

param (
    [string]$RepoPath,
    [string]$CommitOrRange,
    [string]$PackageRoot
)

#-- 1. Get repo path -----------------------------------------------------------
if (-not $RepoPath) {
    $RepoPath = Read-Host "Full path to the git repo"
}
if (-not (Test-Path $RepoPath)) {
    throw "Path '$RepoPath' does not exist."
}
Set-Location $RepoPath

#-- 2. Get commit / range ------------------------------------------------------
$defaultRange = "HEAD~1..HEAD"
if (-not $CommitOrRange) {
    $CommitOrRange = Read-Host "Commit (SHA) or commit range (e.g. $defaultRange)"
    if (-not $CommitOrRange) { $CommitOrRange = $defaultRange }
}

#-- 3. Prepare output folder ---------------------------------------------------
if (-not $PackageRoot) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $PackageRoot = Join-Path $env:TEMP "DeployPackage-$stamp"
}
New-Item -ItemType Directory -Path $PackageRoot -Force | Out-Null

Write-Host "📦 Building delta package at $PackageRoot`n"

#-- 4. Parse the git diff ------------------------------------------------------
$diff = git diff --name-status $CommitOrRange | ForEach-Object {
    $parts = $_ -split "`t"
    [pscustomobject]@{
        Status = $parts[0]    # A|M|R|etc.
        Path   = $parts[1] -replace '/', '\'
    }
} | Where-Object { $_.Status -notmatch '^D' }   # ignore deletions

$staticExt = @(
    '.js',
    '.css',
    '.html',
    '.htm',
    '.cshtml',
    '.config',
    '.json',
    '.xml',
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.svg',
    '.txt'
)

$staticFiles = $diff | Where-Object {
    $staticExt -contains ([IO.Path]::GetExtension($_.Path))
}
$csFiles = $diff | Where-Object { $_.Path -like '*.cs' }

#-- 5. Copy static / resource files -------------------------------------------
foreach ($f in $staticFiles) {
    $dest = Join-Path $PackageRoot $f.Path
    New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
    Copy-Item $f.Path $dest -Force
}

#-- 6. Work out which projects contain the changed C# files --------------------
$projSet = [System.Collections.Generic.HashSet[string]]::new()

foreach ($cs in $csFiles) {
    $searchDir = Split-Path $cs.Path
    $proj = $null

    do {
        $proj = Get-ChildItem $searchDir -Filter *.csproj -ErrorAction SilentlyContinue |
        Select-Object -First 1
        $searchDir = Split-Path $searchDir -Parent
    } until ($proj -or -not $searchDir)

    if ($proj) { 
        $projSet.Add($proj.FullName) | Out-Null 
    }

}

# Nothing to build? We're done.
if ($projSet.Count -eq 0) {
    Write-Host "No .cs changes detected - static files copied only."
    Write-Host "Done -> $PackageRoot"
}

$tempBuild = Join-Path $env:TEMP "DeltaBuild-$stamp"
New-Item $tempBuild -ItemType Directory -Force | Out-Null

foreach ($projPath in $projSet) {
    $projName = [IO.Path]::GetFileNameWithoutExtension($projPath)
    $outDir = Join-Path $tempBuild $projName
    New-Item $outDir -ItemType Directory -Force | Out-Null

    Write-Host "Building $projName ..."

    $isSdk = Select-String -Path $projPath -Pattern "<TargetFramework" -Quiet

    if ($isSdk) {
        dotnet publish $projPath -c Release -o $outDir --nologo
    }
    else {
         dotnet msbuild $projPath /t:Build /p:Configuration=Release /p:OutDir="$outDir\" /nologo
    }

    # Grab the primary DLL (ProjectName.dll)
    $dll = Get-ChildItem $outDir -Filter "$projName.dll" -Recurse | Select-Object -First 1
    if (-not $dll) {
        Write-Warning "Did not find $projName.dll after build."
        continue
    }

    $projRel = (Split-Path $projPath -Parent) -replace [regex]::Escape($RepoPath), ''
    $trimmedRel = $projRel.TrimStart("\")
    $binDest = Join-Path $PackageRoot (Join-Path $trimmedRel "bin")
    New-Item $binDest -ItemType Directory -Force | Out-Null
    Copy-Item $dll.FullName $binDest -Force

}

Write-Host "Package complete: $PackageRoot "
