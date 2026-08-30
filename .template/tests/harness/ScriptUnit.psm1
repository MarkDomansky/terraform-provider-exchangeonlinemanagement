# MANAGED FILE - do not edit in your fork.
#
# Script-level unit-test harness: runs ONE CRUD script in-process with a fake
# $InputData, enforcing the engine contract, WITHOUT terraform, Go, or the
# pshost sidecar. Because the script runs in the calling PowerShell session,
# Pester's Mock works on any cmdlet the script calls - so tests are fast and
# never touch the real target system.
#
# Contract enforced (mirrors the engine):
#   - $InputData (hashtable) is bound BY NAME to the script's own param block;
#     when the script has none, the harness injects param([hashtable]$InputData)
#     exactly as the engine does
#   - $InputData is the only parameter the engine ever supplies, so any other
#     parameter must be optional, and $Action must not be a parameter at all
#   - $Action is a variable in the enclosing scope
#   - anything written to the error stream fails the run
#   - create/update must emit exactly one object; read/delete may emit zero
#   - create must emit a non-empty 'id'

$ErrorActionPreference = 'Stop'

# Repo root is three levels up from .template/tests/harness.
$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..')).Path

function Get-ResourceScriptPath {
    # Path of one CRUD script, e.g. provider/resources/<name>/create.ps1.
    param(
        [ValidateSet('resources', 'data-sources')][string]$Kind = 'resources',
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('create', 'read', 'update', 'delete')][string]$Action
    )
    Join-Path $script:RepoRoot 'provider' $Kind $Name "$Action.ps1"
}

function Get-ResourceManifest {
    # Parsed manifest (resource.tfps.json / datasource.tfps.json) of a resource
    # or data source. (Full validation lives in the engine; `go test ./...`
    # runs it against the embedded tree.)
    param(
        [ValidateSet('resources', 'data-sources')][string]$Kind = 'resources',
        [Parameter(Mandatory)][string]$Name
    )
    $manifestName = if ($Kind -eq 'data-sources') { 'datasource.tfps.json' } else { 'resource.tfps.json' }
    $path = Join-Path $script:RepoRoot 'provider' $Kind $Name $manifestName
    if (-not (Test-Path -LiteralPath $path)) { throw "No $manifestName at $path" }
    Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Get-ScriptParameter {
    # Parameters declared by a script's top-level param block, as
    # [pscustomobject]@{ Name; Mandatory }. Uses the same AST inspection the
    # engine's RunspaceManager does.
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Script
    )
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Script, [ref]$null, [ref]$null)
    if (-not $ast.ParamBlock) { return @() }

    foreach ($p in $ast.ParamBlock.Parameters) {
        $mandatory = $false
        foreach ($attr in $p.Attributes) {
            if ($attr -isnot [System.Management.Automation.Language.AttributeAst]) { continue }
            if ($attr.TypeName.GetReflectionAttributeType() -ne [System.Management.Automation.ParameterAttribute]) { continue }
            foreach ($named in $attr.NamedArguments) {
                if ($named.ArgumentName -ne 'Mandatory') { continue }
                # `Mandatory` on its own is shorthand for `Mandatory = $true`.
                $mandatory = $named.ExpressionOmitted -or
                    "$($named.Argument.Extent.Text)" -notin '$false', '0'
            }
        }
        [pscustomobject]@{ Name = $p.Name.VariablePath.UserPath; Mandatory = $mandatory }
    }
}

function Assert-ScriptParameterContract {
    # Fails on param blocks the engine cannot satisfy. It binds -InputData and
    # nothing else, so a second mandatory parameter throws an opaque
    # ParameterBindingException at apply time, and a declared $Action parameter
    # silently shadows the enclosing-scope variable with $null.
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyCollection()][object[]]$Parameters = @()
    )
    $file = Split-Path -Leaf $Path

    if ($Parameters.Name -contains 'Action') {
        throw "$file declares an `$Action parameter; the engine sets `$Action in the enclosing scope and never binds it, so the parameter would always be `$null - remove it and read the variable."
    }
    $orphanMandatory = @($Parameters | Where-Object { $_.Mandatory -and $_.Name -ne 'InputData' })
    if ($orphanMandatory) {
        throw "$file marks $($orphanMandatory.Name -join ', ') as Mandatory; the engine only binds -InputData, so nothing can supply them. Give them defaults instead."
    }
}

function Invoke-ResourceScript {
    # Run one CRUD script with a fake $InputData and return the emitted object
    # (a hashtable/PSObject), enforcing the engine contract. Set up globals
    # (e.g. $global:ProviderData, your own state) before calling, or pass
    # -ProviderData to have $global:ProviderData populated for the call.
    param(
        [ValidateSet('resources', 'data-sources')][string]$Kind = 'resources',
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('create', 'read', 'update', 'delete')][string]$Action,
        [hashtable]$InputData = @{},
        # Becomes $global:ProviderData for the duration of the call. Put your
        # custom provider attributes under .Config, mirroring the engine.
        [hashtable]$ProviderData
    )

    $scriptPath = Get-ResourceScriptPath -Kind $Kind -Name $Name -Action $Action
    if (-not (Test-Path -LiteralPath $scriptPath)) { throw "No script at $scriptPath" }
    $content = Get-Content -LiteralPath $scriptPath -Raw

    $prevProviderData = $global:ProviderData
    if ($PSBoundParameters.ContainsKey('ProviderData')) {
        $global:ProviderData = $ProviderData
    }

    try {
        # Mirror the engine's BuildScript: bind -InputData by name to the
        # script's own param block, or inject one when it has none.
        $declared = Get-ScriptParameter -Script $content
        Assert-ScriptParameterContract -Path $scriptPath -Parameters $declared

        $prelude = if ($declared.Name -contains 'InputData') { '' } else { "param([hashtable]`$InputData)`n" }
        $sb = [scriptblock]::Create($prelude + $content)

        # $Action reaches the script as an enclosing-scope variable (the engine
        # assigns it outside the script's own scope), never as a parameter.
        $errors = @()
        $emitted = @(& $sb -InputData $InputData 2>&1 | ForEach-Object {
                if ($_ -is [System.Management.Automation.ErrorRecord]) { $errors += $_ } else { $_ }
            })

        if ($errors.Count -gt 0) {
            throw "Script $Action.ps1 wrote to the error stream (this fails the operation in the engine):`n$($errors -join "`n")"
        }
        if ($emitted.Count -gt 1) {
            throw "Script $Action.ps1 emitted $($emitted.Count) objects; the engine requires exactly one (pipe stray output to Out-Null)."
        }
        if ($emitted.Count -eq 0) {
            if ($Action -in 'create', 'update') {
                throw "Script $Action.ps1 emitted nothing; create/update must emit exactly one object."
            }
            return $null
        }

        $result = $emitted[0]
        if ($Action -eq 'create') {
            $id = if ($result -is [hashtable]) { $result['id'] } else { $result.id }
            if (-not $id) {
                throw "create.ps1 must emit a non-empty 'id' (got: $($result | ConvertTo-Json -Compress -Depth 5))"
            }
        }
        return $result
    }
    finally {
        $global:ProviderData = $prevProviderData
    }
}

Export-ModuleMember -Function Invoke-ResourceScript, Get-ResourceScriptPath, Get-ResourceManifest, Get-ScriptParameter
