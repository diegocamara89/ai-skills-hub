param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pythonScript = Join-Path $scriptDir "claude_codex_orchestrator.py"

$py = Get-Command py -ErrorAction SilentlyContinue
if ($py) {
    & $py.Source -3 $pythonScript @Arguments
    exit $LASTEXITCODE
}

$python = Get-Command python -ErrorAction SilentlyContinue
if ($python) {
    & $python.Source $pythonScript @Arguments
    exit $LASTEXITCODE
}

throw "Python nao encontrado no PATH. Instale Python 3 e tente novamente."
