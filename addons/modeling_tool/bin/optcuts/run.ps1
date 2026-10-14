param([Parameter(Mandatory=$true)][string]$JobDir,[Parameter(Mandatory=$true)][string]$Executable)
$ErrorActionPreference = 'Stop'
try {
    Remove-Item Env:TOPOPPI_FOOTPRINT_SIDECAR -ErrorAction SilentlyContinue
    Remove-Item Env:TOPOPPI_FRAGMENTATION_WEIGHT -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Force -Path (Join-Path $JobDir 'output') | Out-Null
    $process = Start-Process -FilePath $Executable -ArgumentList @('100','input.obj','0.999','1','0','4.1','1','0','modeling') -WorkingDirectory $JobDir -WindowStyle Hidden -RedirectStandardOutput (Join-Path $JobDir 'stdout.log') -RedirectStandardError (Join-Path $JobDir 'stderr.log') -PassThru
    $processHandle = $process.Handle
    $deadline = [DateTime]::UtcNow.AddMinutes(3)
    while (-not $process.HasExited) {
        if ((Test-Path -LiteralPath (Join-Path $JobDir 'cancel')) -or [DateTime]::UtcNow -gt $deadline) {
            $process.Kill()
            $process.WaitForExit()
            throw 'OptCuts cancelled or exceeded the three minute limit.'
        }
        Start-Sleep -Milliseconds 100
        $process.Refresh()
    }
    $process.WaitForExit()
    $result = @{exit_code=$process.ExitCode; error=''}
} catch {
    $result = @{exit_code=-1; error=$_.Exception.Message}
}
$result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $JobDir 'done.tmp') -Encoding UTF8
Move-Item -LiteralPath (Join-Path $JobDir 'done.tmp') -Destination (Join-Path $JobDir 'done.json') -Force
