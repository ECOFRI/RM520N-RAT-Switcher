[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repositoryRoot 'RM520N-RAT.ps1'

$tokens = $null
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref]$tokens,
    [ref]$parseErrors)

if ($parseErrors.Count -gt 0) {
    $details = $parseErrors | ForEach-Object {
        '{0}:{1} {2}' -f $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber, $_.Message
    }
    throw ("PowerShell parse errors:`n" + ($details -join [Environment]::NewLine))
}

$content = Get-Content -LiteralPath $scriptPath -Raw
$requiredPatterns = [ordered]@{
    'tool version' = "\`$script:ToolVersion = '1\.1\.1'"
    'dynamic RAT catalog' = 'function Get-DataClassCatalog'
    'supported-mask validation' = 'does not report support for requested data-class bits'
    'NSA anchor validation' = '5G NSA requires its LTE anchor'
    'background worker' = "'apply'"
    'radio recovery' = 'Restore-CellularRadioOn'
    'LTE mask' = '\[uint32\]0x20'
    'NSA mask' = '\[uint32\]0x40'
}

foreach ($check in $requiredPatterns.GetEnumerator()) {
    if ($content -notmatch $check.Value) {
        throw ('Missing expected implementation marker: ' + $check.Key)
    }
}

if ($content -match '0x00000021') {
    throw 'The obsolete LTE + GPRS mask 0x00000021 must not be used.'
}

if ($content -match 'return\s+@\(\$presets\)') {
    throw 'Generic List[object] must be materialized with ToArray() for Windows PowerShell 5.1.'
}

'PASS: PowerShell parses and required safety markers are present.'
