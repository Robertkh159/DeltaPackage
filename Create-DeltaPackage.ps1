<#
 .SYNOPSIS
   Creates a “delta” deployment package containing ONLY files that changed
   between the specified number of past commits and HEAD.

 .REQUIRES
   Git 2.x+, dotnet SDK, MSBuild 16+

 .NOTES
   Works with SDK-style projects (.NET 5/6/7/8) and old-style
   ASP.NET MVC / WebForms projects targeting .NET Framework 4.x.
#>

param (
    [string]$RepoPath,
    [int]   $CommitCount,
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

#-- 2. Determine commit range based on number of commits ----------------------
if (-not $CommitCount) {
    $input = Read-Host "Number of commits to include (e.g. 1 for last commit)"
    if (-not $input) {
        $CommitCount = 1
    } else {
        if (-not [int]::TryParse($input, [ref]$parsed)) {
            throw "Invalid number of commits: '$input'"
        }
        $CommitCount = $parsed
    }
}

$CommitOrRange = "HEAD~$CommitCount..HEAD"
Write-Host "📦 Building delta package for range $CommitOrRange`n"

#-- 3. Prepare output folder ---------------------------------------------------
if (-not $PackageRoot) {
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $PackageRoot = Join-Path $env:TEMP "DeployPackage-$stamp"
}
New-Item -ItemType Directory -Path $PackageRoot -Force | Out-Null

#-- 4. Parse the git diff ------------------------------------------------------
$diff = git diff --name-status $CommitOrRange | ForEach-Object {
    $parts = $_ -split "`t"
    [pscustomobject]@{
        Status = $parts[0]    # A|M|R|etc.
        Path   = $parts[1] -replace '/', '\\'
    }
} | Where-Object { $_.Status -notmatch '^D' }   # ignore deletions

$staticExt = @(
    '.js','.css','.html','.htm','.cshtml','.config',
    '.json','.xml','.png','.jpg','.jpeg','.gif',
    '.svg','.txt'
)

$staticFiles = $diff | Where-Object { $staticExt -contains ([IO.Path]::GetExtension($_.Path)) }
$csFiles     = $diff | Where-Object { $_.Path -like '*.cs' }

#-- 5. Copy static / resource files -------------------------------------------
foreach ($f in $staticFiles) {
    $dest = Join-Path $PackageRoot $f.Path
    New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
    Copy-Item -LiteralPath $f.Path -Destination $dest -Force
}

#-- 6. Identify and build affected C# projects --------------------------------
$projSet = [System.Collections.Generic.HashSet[string]]::new()
foreach ($cs in $csFiles) {
    $searchDir = Split-Path $cs.Path
    do {
        $proj = Get-ChildItem $searchDir -Filter *.csproj -ErrorAction SilentlyContinue | Select-Object -First 1
        $searchDir = Split-Path $searchDir -Parent
    } until ($proj -or -not $searchDir)

    if ($proj) { $projSet.Add($proj.FullName) | Out-Null }
}

if ($projSet.Count -eq 0) {
    Write-Host "No C# changes detected - only static files copied."
    Write-Host "Done -> $PackageRoot"
    exit
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$tempBuild = Join-Path $env:TEMP "DeltaBuild-$stamp"
New-Item -ItemType Directory -Path $tempBuild -Force | Out-Null

foreach ($projPath in $projSet) {
    $projName = [IO.Path]::GetFileNameWithoutExtension($projPath)
    $outDir   = Join-Path $tempBuild $projName
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    Write-Host "Building $projName ..."
    $isSdk = Select-String -Path $projPath -Pattern "<TargetFramework" -Quiet

    if ($isSdk) {
        dotnet publish $projPath -c Release -o $outDir --nologo
    } else {
        dotnet msbuild $projPath /t:Build /p:Configuration=Release /p:OutDir="$outDir\" /nologo
    }

    # Copy the primary DLL
    $dll = Get-ChildItem $outDir -Filter "$projName.dll" -Recurse | Select-Object -First 1
    if (-not $dll) {
        Write-Warning "Did not find $projName.dll after build."
        continue
    }

    $projRel   = (Split-Path $projPath -Parent) -replace [regex]::Escape($RepoPath), ''
    $trimmed   = $projRel.TrimStart("\\")
    $binDest   = Join-Path $PackageRoot (Join-Path $trimmed "bin")
    New-Item -ItemType Directory -Path $binDest -Force | Out-Null
    Copy-Item $dll.FullName $binDest -Force
}

Write-Host "✅ Package complete: $PackageRoot"
