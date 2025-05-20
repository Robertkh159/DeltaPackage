# Create-DeltaPackage.ps1

A PowerShell script that builds a **"delta" deployment package** containing **only** the files that changed between a specified number of past commits and the current `HEAD`.

---

## Table of Contents

1. [Synopsis](#synopsis)
2. [Requirements](#requirements)
3. [Configuration (Optional)](#configuration-optional)
4. [Parameters](#parameters)
5. [Usage Examples](#usage-examples)
6. [How It Works](#how-it-works)
7. [JSON Config Schema](#json-config-schema)
8. [Contributing](#contributing)
9. [License](#license)

---

## Synopsis

Creates a delta deployment package by:

1. Determining changes in the last *N* commits
2. Copying modified static/resource files
3. Building and packaging changed C# projects (SDK-style & legacy)
4. Optionally zipping the output

---

## Requirements

* **PowerShell**: Windows PowerShell 5.1 or PowerShell 7+
* **Git**: version 2.x or later in `PATH`
* **.NET SDK**: for SDK-style project builds
* **MSBuild 16+**: required for legacy .NET Framework builds (optional)

---

## Configuration (Optional)

Place an optional `deltaConfig.json` in the same folder as the script to predefine settings:

```json
{
  "DefaultOutputFolder": "C:\\Deployments",
  "Projects": [
    {
      "Name": "MyApp",
      "RepoPath": "C:\\Source\\MyApp",
      "PackageRoot": "C:\\Deployments\\MyApp"
    }
  ],
  "StaticExtensions": [".js", ".css", ".html", ".json", ".png"]
}
```

* **DefaultOutputFolder**: Root folder for output packages (defaults to `%TEMP%`).
* **Projects**: An array of predefined repos:

  * `Name`: Friendly name displayed in prompts.
  * `RepoPath`: Full path to the Git repository.
  * `PackageRoot` (optional): Custom output folder.
* **StaticExtensions**: File extensions to treat as static resources.

---

## Parameters

| Parameter      | Position | Description                                                | Required | Default / Behavior                          |
| -------------- | -------- | ---------------------------------------------------------- | -------- | ------------------------------------------- |
| `-RepoPath`    | 0        | Full path to the Git repository                            | No       | Prompt or select from config projects       |
| `-CommitCount` | 1        | Number of commits to include (1 = last commit)             | No       | Prompt until valid integer ≥1               |
| `-PackageRoot` | 2        | Output root folder for the delta package                   | No       | Prompt or default (`DeployPackage-<stamp>`) |
| `-WhatIf`      | N/A      | Preview mode: shows actions without copying/building files | No       | Off                                         |

---

## Usage Examples

### 1. Fully Interactive

```powershell
.\Create-DeltaPackage.ps1
```

Follows prompts for any missing parameters and uses defaults/config.

### 2. Non-Interactive Invocation

```powershell
.\Create-DeltaPackage.ps1 \
  -RepoPath "C:\MyRepo" \
  -CommitCount 3 \
  -PackageRoot "D:\Deployments\MyRepo_Delta"
```

### 3. Dry-Run Preview

```powershell
.\Create-DeltaPackage.ps1 -RepoPath "C:\MyRepo" -CommitCount 1 -WhatIf
```

Shows which files would be copied/built without performing operations.

---

## How It Works

1. **Load Configuration**: Reads `deltaConfig.json` if present.
2. **Parameter Resolution**: Prompts for any missing inputs; allows selecting predefined projects.
3. **Cleanup**: Removes old `DeployPackage-*` folders older than 7 days.
4. **Dependency Check**: Ensures `git` and `dotnet` are in `PATH`; warns if `msbuild.exe` is missing.
5. **Commit Range**: Builds a range string `HEAD~<CommitCount>..HEAD` and summarizes changes.
6. **Diff Parsing**: Collects changed files, excluding deletions, and classifies them:

   * **Static files** (`.js`, `.css`, `.html`, etc.)
   * **C# files** (`*.cs`)
7. **Static File Copy**: Copies modified static files to the package folder, preserving directory structure.
8. **Project Build**:

   * **SDK-style**: Uses `dotnet publish -c Release -o <temp>`
   * **Legacy**: Uses `msbuild.exe /t:Build /p:OutDir=<temp>` if available.
   * Copies resulting DLLs into the package’s `bin` folders.
9. **Archive** (optional): Prompts to zip the package.
10. **Cleanup**: Deletes intermediate build directory.
11. **Summary**: Prints counts of files copied, projects built, and final package location.

---

## JSON Config Schema

```json
{
  "DefaultOutputFolder": "string",
  "Projects": [
    {
      "Name": "string",
      "RepoPath": "string",
      "PackageRoot": "string"
    }
  ],
  "StaticExtensions": [ "string" ]
}
```

---

## Contributing

1. Fork the repository.
2. Create a feature branch: `git checkout -b feature/my-feature`.
3. Commit your changes: `git commit -m "Add new feature"`.
4. Push to remote: `git push origin feature/my-feature`.
5. Open a Pull Request.

---

## License

This project is licensed under the [MIT License](LICENSE).
