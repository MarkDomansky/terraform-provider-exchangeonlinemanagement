# MANAGED FILE - do not edit in your fork.
#
# E2E harness: drives REAL terraform against your COMPILED provider (with the
# pshost sidecar staged next to it) using a dev_overrides CLI config, so
# `terraform init` is bypassed and the freshly built binary is loaded.
# Adapted from the engine's tests/pester/PSTerraformProvider.psm1.

$ErrorActionPreference = 'Stop'

function Write-TFLog {
    # Timestamped test diagnostics. Pester captures Write-Host, so these lines
    # show up in Detailed output and CI logs.
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [Parameter(Position = 1)][ValidateSet('INFO', 'STEP', 'WARN', 'SKIP')][string]$Level = 'INFO'
    )
    $ts = (Get-Date).ToString('HH:mm:ss.fff')
    $color = switch ($Level) {
        'STEP' { 'Cyan' }
        'WARN' { 'Yellow' }
        'SKIP' { 'DarkGray' }
        default { 'DarkCyan' }
    }
    Write-Host "[$ts][e2e][$Level] $Message" -ForegroundColor $color
}

# Repo root is three levels up from .template/tests/harness.
$script:RepoRoot       = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path
$script:ProviderBinDir = $null
$script:Exe            = if ($IsWindows) { '.exe' } else { '' }

# Provider identity comes from the one user-owned identity file.
$script:Settings = Get-Content (Join-Path $script:RepoRoot 'provider/settings.tfps.json') -Raw | ConvertFrom-Json
$script:ProviderName = $script:Settings.name
# dev_overrides keys omit the implied registry.terraform.io host.
$script:ProviderSource = $script:Settings.address -replace '^registry\.terraform\.io/', ''

function Get-ProviderName { $script:ProviderName }
function Get-ProviderSource { $script:ProviderSource }

function Resolve-Tool {
    param([string]$Name, [string[]]$Fallbacks = @())
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($f in $Fallbacks) { if (Test-Path $f) { return (Resolve-Path $f).Path } }
    throw "Could not locate '$Name' on PATH or known fallback locations."
}

function Initialize-ProviderBin {
    # Build the provider (and stage the sidecar next to it) into a dedicated
    # bin dir. Idempotent within a session unless -Force is given.
    #
    # Release-artifact mode: PSTF_PROVIDER_BIN_DIR points at a directory that
    # already holds the packaged provider binary and sidecar (an extracted
    # release zip). It is used verbatim - no build, no staging - so the suite
    # exercises the exact bytes that will be published.
    param([switch]$Force)

    if (-not $Force -and $script:ProviderBinDir -and (Test-Path $script:ProviderBinDir)) {
        return $script:ProviderBinDir
    }

    if ($env:PSTF_PROVIDER_BIN_DIR) {
        if (-not (Test-Path $env:PSTF_PROVIDER_BIN_DIR)) {
            throw "PSTF_PROVIDER_BIN_DIR is set but does not exist: $($env:PSTF_PROVIDER_BIN_DIR)"
        }
        $dir = (Resolve-Path $env:PSTF_PROVIDER_BIN_DIR).Path
        if (-not (Get-ChildItem $dir -Filter "terraform-provider-$script:ProviderName*")) {
            throw "PSTF_PROVIDER_BIN_DIR '$dir' contains no terraform-provider-$script:ProviderName binary."
        }
        if (-not (Test-Path (Join-Path $dir "pshost$script:Exe"))) {
            throw "PSTF_PROVIDER_BIN_DIR '$dir' contains no pshost$script:Exe sidecar."
        }
        $script:ProviderBinDir = $dir
        return $script:ProviderBinDir
    }

    $binDir = Join-Path $PSScriptRoot '.bin'
    Write-TFLog "building provider into $binDir" 'STEP'
    & (Join-Path $script:RepoRoot '.template' 'build' 'Build-Provider.ps1') -OutputDir $binDir
    $script:ProviderBinDir = (Resolve-Path $binDir).Path
    return $script:ProviderBinDir
}

function New-TFWorkspace {
    # Create an isolated terraform workspace: a temp dir holding the config
    # plus a dev_overrides CLI config pointing terraform at the compiled
    # provider. -Config writes inline HCL to main.tf; -ConfigPath copies a
    # directory of real .tf files (plus supporting files) in verbatim.
    [CmdletBinding(DefaultParameterSetName = 'Inline')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Inline')][string]$Config,
        [Parameter(Mandatory, ParameterSetName = 'Path')][string]$ConfigPath,
        [hashtable]$Variables
    )

    if (-not $script:ProviderBinDir) { throw "Call Initialize-ProviderBin before New-TFWorkspace." }

    $dir = Join-Path ([System.IO.Path]::GetTempPath()) ("e2e-" + [System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        $resolved = Resolve-Path $ConfigPath
        Copy-Item -Path (Join-Path $resolved '*') -Destination $dir -Recurse
        Write-TFLog "workspace <- $resolved (recursive copy)"
    }
    else {
        Set-Content -Path (Join-Path $dir 'main.tf') -Value $Config -Encoding UTF8
    }

    if ($Variables) {
        # Quoted HCL strings; backslashes forward-slashed so Windows paths stay
        # valid HCL.
        $lines = foreach ($name in $Variables.Keys) {
            $value = ([string]$Variables[$name]) -replace '\\', '/'
            "$name = `"$value`""
        }
        Set-Content -Path (Join-Path $dir 'terraform.tfvars') -Value ($lines -join "`n") -Encoding UTF8
    }

    $binDirHcl = $script:ProviderBinDir -replace '\\', '/'
    $cliConfig = @"
provider_installation {
  dev_overrides {
    "$script:ProviderSource" = "$binDirHcl"
  }
  direct {}
}
"@
    $cliConfigPath = Join-Path $dir 'dev.tfrc'
    Set-Content -Path $cliConfigPath -Value $cliConfig -Encoding UTF8

    Write-TFLog "workspace ready at $dir"
    return [pscustomobject]@{
        Dir           = $dir
        CliConfigPath = $cliConfigPath
        SidecarPath   = (Join-Path $script:ProviderBinDir "pshost$script:Exe")
    }
}

function Invoke-TF {
    # Run a terraform subcommand inside a workspace. Throws on non-zero exit.
    param(
        [Parameter(Mandatory)][pscustomobject]$Workspace,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $terraform = Resolve-Tool -Name 'terraform'

    $prevCliConfig = $env:TF_CLI_CONFIG_FILE
    $prevPsHost    = $env:PSHOST_PATH
    $env:TF_CLI_CONFIG_FILE = $Workspace.CliConfigPath
    $env:PSHOST_PATH        = $Workspace.SidecarPath

    Write-TFLog "terraform $($Arguments -join ' ')" 'STEP'
    Push-Location $Workspace.Dir
    try {
        $output = & $terraform @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-TFLog "terraform $($Arguments[0]) FAILED (exit $LASTEXITCODE)" 'WARN'
            throw "terraform $($Arguments -join ' ') failed (exit $LASTEXITCODE):`n$($output -join "`n")"
        }
        Write-TFLog "terraform $($Arguments[0]) ok"
        return $output
    }
    finally {
        Pop-Location
        $env:TF_CLI_CONFIG_FILE = $prevCliConfig
        $env:PSHOST_PATH        = $prevPsHost
    }
}

function Invoke-TFExit {
    # Like Invoke-TF but returns the exit code instead of throwing, for
    # commands whose non-zero exit is meaningful (plan -detailed-exitcode:
    # 0 = no changes, 2 = changes present).
    param(
        [Parameter(Mandatory)][pscustomobject]$Workspace,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $terraform = Resolve-Tool -Name 'terraform'

    $prevCliConfig = $env:TF_CLI_CONFIG_FILE
    $prevPsHost    = $env:PSHOST_PATH
    $env:TF_CLI_CONFIG_FILE = $Workspace.CliConfigPath
    $env:PSHOST_PATH        = $Workspace.SidecarPath

    Write-TFLog "terraform $($Arguments -join ' ') (capturing exit code)" 'STEP'
    Push-Location $Workspace.Dir
    try {
        $output = & $terraform @Arguments 2>&1
        $code = $LASTEXITCODE
        Write-TFLog "terraform $($Arguments[0]) -> exit $code"
        return [pscustomobject]@{ ExitCode = $code; Output = $output }
    }
    finally {
        Pop-Location
        $env:TF_CLI_CONFIG_FILE = $prevCliConfig
        $env:PSHOST_PATH        = $prevPsHost
    }
}

function Get-TFOutput {
    # Parsed `terraform output -json`.
    param([Parameter(Mandatory)][pscustomobject]$Workspace)
    $terraform = Resolve-Tool -Name 'terraform'

    $prevCliConfig = $env:TF_CLI_CONFIG_FILE
    $env:TF_CLI_CONFIG_FILE = $Workspace.CliConfigPath
    Push-Location $Workspace.Dir
    try {
        $json = & $terraform output -json
        if ($LASTEXITCODE -ne 0) { throw "terraform output failed (exit $LASTEXITCODE)" }
        return ($json | ConvertFrom-Json)
    }
    finally {
        Pop-Location
        $env:TF_CLI_CONFIG_FILE = $prevCliConfig
    }
}

function Remove-TFWorkspace {
    # terraform destroy (best effort) and delete the temp workspace.
    param([Parameter(Mandatory)][pscustomobject]$Workspace)
    Write-TFLog "tearing down workspace $($Workspace.Dir)"
    try { Invoke-TF -Workspace $Workspace -Arguments @('destroy', '-auto-approve', '-no-color') | Out-Null } catch { }
    Remove-Item -Recurse -Force $Workspace.Dir -ErrorAction SilentlyContinue
}

function Get-E2ETestConfig {
    # Load the gitignored E2E config (real endpoints/credentials for suites
    # that need a live target system). Returns the parsed hashtable, or $null
    # when absent so those suites can skip cleanly in CI. Commit a
    # *.template.psd1 blueprint next to it for operators to copy.
    $path = Join-Path $script:RepoRoot 'tests/e2e/config/e2e.tests.config.psd1'
    if (-not (Test-Path $path)) {
        Write-TFLog 'no e2e.tests.config.psd1 found - gated E2E suites will skip' 'SKIP'
        return $null
    }
    Write-TFLog "loaded E2E config $path"
    return Import-PowerShellDataFile -Path $path
}

Export-ModuleMember -Function Initialize-ProviderBin, New-TFWorkspace, Invoke-TF, Invoke-TFExit, `
    Get-TFOutput, Remove-TFWorkspace, Write-TFLog, Get-E2ETestConfig, Get-ProviderName, Get-ProviderSource
