# Delta-Deploy PowerShell Script

A PowerShell cmdlet that generates a **delta deployment package** containing only the files changed in the last *N* commits. Supports static files (JS, CSS, HTML, images, etc.) and C# projects (SDK-style and .NET Framework). Automatically archives the package and cleans up intermediate files.

---

## Features

* **Delta-based packaging**: Only files changed in the last `N` commits are collected.
* **Static resource support**: Copies JS, CSS, HTML, JSON, images, and other extensions.
* **C# project builds**: Detects and builds affected SDK-style (`dotnet publish`) or old-style (`msbuild`) projects and collects their primary DLLs.
* **CmdletBinding**: Supports `-WhatIf`, `-Verbose`, `-Confirm`, and parameter validation.
* **Config-driven**: Optional `deltaConfig.json` to override static file extensions.
* **Cleanup**: Removes old packages older than 7 days and intermediate build folders.
* **Parallel builds**: Leverages PowerShell 7+ `ForEach-Object -Parallel` for multi-core speed.
* **Archiving**: Outputs a `.zip` archive of the resulting package.
* **Summary**: Prints a final table of copied files, built projects, and the archive path.

---

## Prerequisites

* **PowerShell 5.1+** (Windows) or **PowerShell 7+**
* [Git](https://git-scm.com/) in your `PATH`
* [.NET SDK](https://dotnet.microsoft.com/download) 5.0, 6.0, 7.0, or 8.0
* [MSBuild](https://docs.microsoft.com/visualstudio/msbuild/) (for .NET Framework projects)

---

## Installation

1. Copy `Create-DeltaPackage.ps1` into your scripts folder.
2. (Optional) Create `deltaConfig.json` alongside to customize extensions:

   ```json
   {
     "StaticExtensions": [".js", ".css", ".scss", ".svg", ".ico"]
   }
   ```
3. Unblock the script if necessary:

   ```powershell
   Unblock-File .\Create-DeltaPackage.ps1
   ```

---

## Usage

```powershell
# Basic: package changes from last commit
PS> . 'C:\Scripts\Create-DeltaPackage.ps1' -RepoPath 'C:\Projects\MyApp' -CommitCount 1

# Specify a custom output folder and include last 3 commits
PS> . 'C:\Scripts\Create-DeltaPackage.ps1' -RepoPath 'C:\Projects\MyApp' -CommitCount 3 -PackageRoot 'C:\Temp\DeltaPackage'

# Preview only (no file operations)
PS> . 'C:\Scripts\Create-DeltaPackage.ps1' -RepoPath 'C:\Projects\MyApp' -CommitCount 2 -WhatIf

# Verbose mode for more detail
PS> . 'C:\Scripts\Create-DeltaPackage.ps1' -RepoPath 'C:\Projects\MyApp' -Verbose
```

* **`-RepoPath`** (mandatory): Root of your Git repository.
* **`-CommitCount`** (optional, default = 1): Number of most recent commits to include.
* **`-PackageRoot`** (optional): Destination folder for the delta package. Defaults to `%TEMP%\DeployPackage-yyyyMMdd-HHmmss`.
* **Common parameters**: `-WhatIf`, `-Verbose`, `-Confirm` supported.

---

## How It Works

1. **Cleanup**: Removes any `DeployPackage-*` folders in `%TEMP%` older than 7 days.
2. **Dependency check**: Verifies `git`, `dotnet`, and `msbuild` availability.
3. **Diff parsing**: Runs `git diff --name-status HEAD~N..HEAD` and filters out deletions.
4. **Static files**: Copies all changed files with matching extensions (configurable).
5. **Project detection**: Scans for `.csproj` files above each changed `.cs` file.
6. **Build step**:

   * SDK-style: `dotnet publish -c Release`
   * Framework: `msbuild /p:Configuration=Release`
7. **DLL collection**: Grabs each project’s primary DLL and places it under `bin` in the package.
8. **Archiving**: Zips the entire package folder to `PackageRoot.zip`.
9. **Cleanup**: Deletes the temporary build folder.
10. **Summary**: Outputs counts and paths in a table.

---

## Customization

* **Extensions**: Edit or create `deltaConfig.json`:

  ```json
  {
    "StaticExtensions": [".js",".css",".scss",".woff2"]
  }
  ```
* **Cleanup age**: Adjust the `AddDays(-7)` value in the `begin` block.
* **Parallelism**: Change `ThrottleLimit` or disable `-Parallel` for PS5.

---

## Troubleshooting

* **Script won’t run**: ensure execution policy allows remote scripts: `Set-ExecutionPolicy RemoteSigned`.
* **msbuild not found**: install Visual Studio Build Tools.
* **No files copied**: verify your `CommitCount` and that there are indeed changes in the last N commits.
* **Permission issues**: run PowerShell as Administrator or choose an output folder you own.

---

## License

MIT © Robert Khurmatuline