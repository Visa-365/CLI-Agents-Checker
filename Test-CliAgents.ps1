#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateRange(3, 120)]
    [int]$TimeoutSeconds = 20,

    [string]$OutputDirectory = (
        Join-Path (Get-Location) (
            "cli-audit-" + (Get-Date -Format "yyyyMMdd-HHmmss")
        )
    ),

    [string[]]$AgentCommands = @(
        "claude",
        "codex",
        "gemini",
        "copilot",
        "aider",
        "opencode",
        "agent",
        "cursor-agent",
        "ollama"
    ),

    # Optional: inspect local dependencies in this project.
    [string]$ProjectDirectory = "",
        # Explicit API address; independent of CLI discovery.
    [string]$OllamaBaseUrl = "http://localhost:11434",

    [ValidateRange(1, 60)]
    [int]$OllamaApiTimeoutSeconds = 5
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Find-Cli {
    param([string]$Name)

    $found = New-Object System.Collections.Generic.List[string]

    # Preserve command resolution order in the current PATH.
    $commands = @(
        Get-Command -Name $Name -All `
            -CommandType Application, ExternalScript `
            -ErrorAction SilentlyContinue
    )

    foreach ($command in $commands) {
        if ($command.Path -and -not $found.Contains($command.Path)) {
            $found.Add($command.Path)
        }
    }

    $directories = @(
        (Join-Path $env:APPDATA "npm"),
        (Join-Path $env:USERPROFILE ".local\bin"),
        (Join-Path $env:USERPROFILE ".cargo\bin"),
        (Join-Path $env:USERPROFILE "scoop\shims"),
        (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links")
    )

    if ($Name -eq "ollama") {
        $directories += @(
            (Join-Path $env:LOCALAPPDATA "Programs\Ollama")
        )
    }

    foreach ($directory in $directories) {
        foreach ($extension in @(".exe", ".cmd", ".bat", ".ps1")) {
            $candidate = Join-Path $directory ($Name + $extension)

            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $fullPath = (Get-Item -LiteralPath $candidate).FullName
                if (-not $found.Contains($fullPath)) {
                    $found.Add($fullPath)
                }
            }
        }
    }

    $found.ToArray()
}

function Invoke-VersionProbe {
    param(
        [string]$Path,
        [int]$Timeout,
        [string[]]$CommandArguments = @("--version"),
        [string]$WorkingDirectory = $env:TEMP
    )

    # Pass the path as a quoted literal, never as an executable expression.
    $literalPath = "'" + $Path.Replace("'", "''") + "'"

    $literalArguments = @(
        foreach ($argument in $CommandArguments) {
            "'" + $argument.Replace("'", "''") + "'"
        }
    ) -join ","

    $argumentSetup = '$cliArguments = @(' + $literalArguments + ')'

    $childScript = @"
`$ErrorActionPreference = 'Stop'
try {
    `$global:LASTEXITCODE = 0
    $argumentSetup
    & $literalPath @cliArguments
    if (`$null -ne `$LASTEXITCODE) {
        exit [int]`$LASTEXITCODE
    }
    exit 0
}
catch {
    [Console]::Error.WriteLine(`$_.Exception.Message)
    exit 1
}
"@

    $encoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($childScript)
    )

    $hostExe = if (Test-Path (Join-Path $PSHOME "pwsh.exe")) {
        Join-Path $PSHOME "pwsh.exe"
    }
    else {
        Join-Path $PSHOME "powershell.exe"
    }

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $hostExe
    $info.Arguments = "-NoLogo -NoProfile -NonInteractive -EncodedCommand $encoded"
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.WorkingDirectory = $WorkingDirectory

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info
    $timer = [Diagnostics.Stopwatch]::StartNew()

    try {
        [void]$process.Start()

        # Drain both streams concurrently to avoid pipe-buffer deadlocks.
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($Timeout * 1000)) {
            $taskkill = Join-Path $env:SystemRoot "System32\taskkill.exe"
            & $taskkill /PID $process.Id /T /F *> $null

            return [pscustomobject]@{
                Status   = "TIMEOUT"
                ExitCode = $null
                Output   = "Version check exceeded $Timeout seconds."
                StdOut   = ""
                StdErr   = ""
                Seconds  = [math]::Round($timer.Elapsed.TotalSeconds, 2)
            }
        }

        $outText = $stdout.GetAwaiter().GetResult()
        $errText = $stderr.GetAwaiter().GetResult()
        $text = (@($outText, $errText) -join "`n").Trim()
        $exitCode = $process.ExitCode

        $status = if ($exitCode -ne 0) {
            "ERROR"
        }
        elseif ([string]::IsNullOrWhiteSpace($text)) {
            "NO_OUTPUT"
        }
        else {
            "OK"
        }

        [pscustomobject]@{
            Status   = $status
            ExitCode = $exitCode
            Output   = $text
            StdOut   = $outText
            StdErr   = $errText
            Seconds  = [math]::Round($timer.Elapsed.TotalSeconds, 2)
        }
    }
    catch {
        [pscustomobject]@{
            Status   = "LAUNCH_ERROR"
            ExitCode = $null
            Output   = $_.Exception.Message
            StdOut   = ""
            StdErr   = ""
            Seconds  = [math]::Round($timer.Elapsed.TotalSeconds, 2)
        }
    }
    finally {
        $timer.Stop()
        $process.Dispose()
    }
}

function Get-NpmInventory {
    param(
        [string]$NpmPath,
        [int]$Timeout,
        [string]$ProjectDirectory = ""
    )

    $scopes = @(
        [pscustomobject]@{
            Name      = "Global"
            Directory = $env:TEMP
            Arguments = @(
                "ls", "--global", "--depth=0", "--json", "--long"
            )
        }
    )

    if (-not [string]::IsNullOrWhiteSpace($ProjectDirectory)) {
        $project = Get-Item -LiteralPath $ProjectDirectory

        if (-not $project.PSIsContainer) {
            throw "ProjectDirectory must be a directory."
        }

        if (-not (Test-Path -LiteralPath (
            Join-Path $project.FullName "package.json"
        ) -PathType Leaf)) {
            throw "No package.json found in: $($project.FullName)"
        }

        $scopes += [pscustomobject]@{
            Name      = "Project"
            Directory = $project.FullName
            Arguments = @(
                "ls", "--global=false", "--depth=0", "--json", "--long"
            )
        }
    }

    foreach ($scope in $scopes) {
        Write-Host ("Checking npm packages: {0}..." -f $scope.Name)

        $probe = Invoke-VersionProbe `
            -Path $NpmPath `
            -Timeout $Timeout `
            -CommandArguments $scope.Arguments `
            -WorkingDirectory $scope.Directory

        $packages = @()
        $problems = @()
        $parseError = ""
        $tree = $null

        # npm may return usable JSON even with a nonzero exit code.
        if (-not [string]::IsNullOrWhiteSpace($probe.StdOut)) {
            try {
                $tree = $probe.StdOut | ConvertFrom-Json
            }
            catch {
                $parseError = $_.Exception.Message
            }
        }

        if ($null -ne $tree) {
            $problemProperty = $tree.PSObject.Properties["problems"]
            if ($null -ne $problemProperty) {
                $problems = @($problemProperty.Value)
            }

            $dependencyProperty = $tree.PSObject.Properties["dependencies"]
            if ($null -ne $dependencyProperty) {
                $dependencies = $dependencyProperty.Value

                if ($null -ne $dependencies) {
                    $packages = @(
                        foreach ($property in $dependencies.PSObject.Properties) {
                            $package = $property.Value
                            $flags = @()

                            foreach ($flag in @(
                                "missing", "invalid", "extraneous"
                            )) {
                                $flagProperty = $package.PSObject.Properties[$flag]

                                if ($null -ne $flagProperty -and
                                    $flagProperty.Value) {
                                    $flags += $flag.ToUpperInvariant()
                                }
                            }

                            $version = ""
                            $versionProperty = $package.PSObject.Properties["version"]
                            if ($null -ne $versionProperty) {
                                $version = [string]$versionProperty.Value
                            }

                            $packagePath = ""
                            $pathProperty = $package.PSObject.Properties["path"]
                            if ($null -ne $pathProperty) {
                                $packagePath = [string]$pathProperty.Value
                            }

                            $packageStatus = "LISTED"
                            if ($flags.Count -gt 0) {
                                $packageStatus = $flags -join ","
                            }

                            [pscustomobject]@{
                                Scope   = $scope.Name
                                Name    = $property.Name
                                Version = $version
                                Status  = $packageStatus
                                Path    = $packagePath
                            }
                        }
                    )
                }
            }
        }

        $status = if ($probe.Status -in @("TIMEOUT", "LAUNCH_ERROR")) {
            $probe.Status
        }
        elseif ($null -eq $tree) {
            "INVALID_OR_EMPTY_JSON"
        }
        elseif ($probe.ExitCode -ne 0 -or $problems.Count -gt 0) {
            "ISSUES"
        }
        else {
            "OK"
        }

        [pscustomobject]@{
            Scope      = $scope.Name
            Directory  = $scope.Directory
            Status     = $status
            ExitCode   = $probe.ExitCode
            Seconds    = $probe.Seconds
            Packages   = @($packages)
            Problems   = @($problems)
            ParseError = $parseError
            StdOut     = $probe.StdOut
            StdErr     = $probe.StdErr
            Diagnostic = $probe.Output
        }
    }
}

function Test-OllamaApi {
    [CmdletBinding()]
    param(
        [string]$BaseUrl = "http://localhost:11434",
        [int]$TimeoutSeconds = 5
    )

    $baseUri = $null

    if (-not [Uri]::TryCreate(
        $BaseUrl,
        [UriKind]::Absolute,
        [ref]$baseUri
    )) {
        throw "Invalid OllamaBaseUrl: $BaseUrl"
    }

    if ($baseUri.Scheme -notin @("http", "https")) {
        throw "OllamaBaseUrl must use HTTP or HTTPS."
    }

    if ($baseUri.AbsolutePath -ne "/" -or
        -not [string]::IsNullOrEmpty($baseUri.Query) -or
        -not [string]::IsNullOrEmpty($baseUri.Fragment) -or
        -not [string]::IsNullOrEmpty($baseUri.UserInfo)) {
        throw "Use a base URL such as http://localhost:11434 without a path, query, fragment or credentials."
    }

    $base = $baseUri.AbsoluteUri.TrimEnd("/")
    $timer = [Diagnostics.Stopwatch]::StartNew()

    $result = [ordered]@{
        BaseUrl       = $base
        Status        = "NOT_CHECKED"
        VersionStatus = "NOT_CHECKED"
        ServerVersion = ""
        ModelsStatus  = "NOT_CHECKED"
        ModelCount    = $null
        Models        = @()
        Errors        = @()
        Seconds       = 0
    }

    try {
        $versionResponse = Invoke-RestMethod `
            -Uri "$base/api/version" `
            -Method Get `
            -TimeoutSec $TimeoutSeconds `
            -ErrorAction Stop

        if ($null -eq $versionResponse) {
            throw "Empty response from /api/version."
        }

        $versionProperty = $versionResponse.PSObject.Properties["version"]

        if ($null -eq $versionProperty -or
            [string]::IsNullOrWhiteSpace([string]$versionProperty.Value)) {
            throw "Response from /api/version has no nonempty version field."
        }

        $result.ServerVersion = [string]$versionProperty.Value
        $result.VersionStatus = "OK"
    }
    catch {
        $result.VersionStatus = "ERROR"
        $result.Errors += (
            "/api/version: " + $_.Exception.Message
        )
    }

    # Check independently: failure of one endpoint must not hide the other.
    try {
        $modelsResponse = Invoke-RestMethod `
            -Uri "$base/api/tags" `
            -Method Get `
            -TimeoutSec $TimeoutSeconds `
            -ErrorAction Stop

        if ($null -eq $modelsResponse) {
            throw "Empty response from /api/tags."
        }

        $modelsProperty = $modelsResponse.PSObject.Properties["models"]

        if ($null -eq $modelsProperty -or
            $null -eq $modelsProperty.Value) {
            throw "Response from /api/tags has no models array."
        }

        $models = @(
            foreach ($model in @($modelsProperty.Value)) {
                if ($null -eq $model) {
                    continue
                }

                $name = ""
                $size = $null
                $modifiedAt = ""

                $property = $model.PSObject.Properties["name"]
                if ($null -ne $property) {
                    $name = [string]$property.Value
                }

                $property = $model.PSObject.Properties["size"]
                if ($null -ne $property) {
                    $size = $property.Value
                }

                $property = $model.PSObject.Properties["modified_at"]
                if ($null -ne $property) {
                    $modifiedAt = [string]$property.Value
                }

                [pscustomobject]@{
                    Name       = $name
                    SizeBytes  = $size
                    ModifiedAt = $modifiedAt
                }
            }
        )

        $result.Models = @($models)
        $result.ModelCount = $models.Count
        $result.ModelsStatus = "OK"
    }
    catch {
        $result.ModelsStatus = "ERROR"
        $result.Errors += (
            "/api/tags: " + $_.Exception.Message
        )
    }

    $result.Status = if (
        $result.VersionStatus -eq "OK" -and
        $result.ModelsStatus -eq "OK"
    ) {
        "OK"
    }
    elseif (
        $result.VersionStatus -eq "OK" -or
        $result.ModelsStatus -eq "OK"
    ) {
        "PARTIAL"
    }
    else {
        "CHECK_FAILED"
    }

    $timer.Stop()
    $result.Seconds = [math]::Round($timer.Elapsed.TotalSeconds, 2)

    [pscustomobject]$result
}

$targets = @(
    foreach ($name in $AgentCommands) {
        [pscustomobject]@{ Name = $name; Kind = "Agent" }
    }

    foreach ($name in @("node", "npm", "python", "git", "wsl")) {
        [pscustomobject]@{ Name = $name; Kind = "Runtime/tool" }
    }
)

$results = @(
    foreach ($target in $targets) {
        Write-Host ("Checking {0}..." -f $target.Name)

        $paths = @(Find-Cli -Name $target.Name)

        if ($paths.Count -eq 0) {
            [pscustomobject]@{
                Name       = $target.Name
                Kind       = $target.Kind
                Status     = "NOT_FOUND"
                InPath     = $false
                Path       = ""
                OtherPaths = ""
                ExitCode   = $null
                Seconds    = 0
                Output     = ""
            }
            continue
        }

        $selected = $paths[0]
        $resolved = @(
            Get-Command -Name $target.Name -All `
                -CommandType Application, ExternalScript `
                -ErrorAction SilentlyContinue
        )
        $inPath = @($resolved | Where-Object {
            $_.Path -eq $selected
        }).Count -gt 0

        $probe = Invoke-VersionProbe `
            -Path $selected -Timeout $TimeoutSeconds

        [pscustomobject]@{
            Name       = $target.Name
            Kind       = $target.Kind
            Status     = $probe.Status
            InPath     = $inPath
            Path       = $selected
            OtherPaths = (
                @($paths | Select-Object -Skip 1) -join "; "
            )
            ExitCode   = $probe.ExitCode
            Seconds    = $probe.Seconds
            Output     = $probe.Output
        }
    }
)

[void](New-Item -ItemType Directory -Path $OutputDirectory -Force)

Write-Host ""
Write-Host "Checking Ollama API..."

$ollamaApi = Test-OllamaApi `
    -BaseUrl $OllamaBaseUrl `
    -TimeoutSeconds $OllamaApiTimeoutSeconds

$ollamaApi |
    ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath (
        Join-Path $OutputDirectory "ollama-api.json"
    ) -Encoding UTF8

Write-Host ""
Write-Host "OLLAMA SERVER"

$ollamaApi |
    Select-Object BaseUrl, Status, ServerVersion,
        ModelsStatus, ModelCount, Seconds |
    Format-Table -AutoSize -Wrap

if (@($ollamaApi.Models).Count -gt 0) {
    Write-Host "OLLAMA MODELS"

    $ollamaApi.Models |
        Format-Table Name, SizeBytes, ModifiedAt -AutoSize -Wrap

    $ollamaApi.Models |
        Export-Csv -LiteralPath (
            Join-Path $OutputDirectory "ollama-models.csv"
        ) -NoTypeInformation -Encoding UTF8
}

foreach ($message in $ollamaApi.Errors) {
    Write-Warning $message
}

$npmInventory = @()
$npmPackages = @()

$npmPaths = @(Find-Cli -Name "npm")

if ($npmPaths.Count -gt 0) {
    $npmInventory = @(
        Get-NpmInventory `
            -NpmPath $npmPaths[0] `
            -Timeout $TimeoutSeconds `
            -ProjectDirectory $ProjectDirectory
    )

    $npmPackages = @(
        foreach ($inventory in $npmInventory) {
            foreach ($package in $inventory.Packages) {
                $package
            }
        }
    )

    if ($npmPackages.Count -gt 0) {
        $npmPackages |
            Export-Csv -LiteralPath (
                Join-Path $OutputDirectory "npm-packages.csv"
            ) -NoTypeInformation -Encoding UTF8
    }

    # Always keep the diagnostic report, even if no packages were listed.
    ConvertTo-Json -InputObject @($npmInventory) -Depth 12 |
        Set-Content -LiteralPath (
            Join-Path $OutputDirectory "npm-inventory.json"
        ) -Encoding UTF8

    Write-Host ""
    Write-Host "NPM CHECKS"

    $npmInventory |
        Select-Object Scope, Status, ExitCode, Seconds, Directory |
        Format-Table -AutoSize -Wrap

    if ($npmPackages.Count -gt 0) {
        Write-Host "NPM PACKAGES"

        $npmPackages |
            Sort-Object Scope, Name |
            Format-Table Scope, Name, Version, Status -AutoSize -Wrap
    }

    foreach ($inventory in $npmInventory) {
        foreach ($problem in $inventory.Problems) {
            Write-Warning ("npm [{0}]: {1}" -f (
                $inventory.Scope
            ), $problem)
        }

        if ($inventory.Status -ne "OK") {
            Write-Warning (
                "npm [{0}]: {1}; see npm-inventory.json for details." -f
                $inventory.Scope, $inventory.Status
            )
        }
    }
}
else {
    Write-Warning "npm was not found. Package inventory was skipped."
}

$results |
    Export-Csv -LiteralPath (Join-Path $OutputDirectory "report.csv") `
        -NoTypeInformation -Encoding UTF8

$report = [ordered]@{
    CheckedAt         = (Get-Date).ToString("o")
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    TimeoutSeconds    = $TimeoutSeconds
    NpmInventory = @($npmInventory)
    OllamaApi = $ollamaApi
    Scope = "CLI discovery/version, npm inventory and Ollama API metadata; no inference test"
    Results           = $results
}

$report | ConvertTo-Json -Depth 12 |
    Set-Content -LiteralPath (Join-Path $OutputDirectory "report.json") `
        -Encoding UTF8

Write-Host ""
$results |
    Select-Object Name, Kind, Status, InPath, ExitCode, Seconds, Path |
    Format-Table -AutoSize -Wrap

Write-Host ("Reports: {0}" -f (
    (Get-Item -LiteralPath $OutputDirectory).FullName
))