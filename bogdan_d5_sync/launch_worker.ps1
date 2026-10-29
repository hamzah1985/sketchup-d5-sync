param([string]$Python, [string]$Worker, [string]$Configuration)
$ErrorActionPreference = 'Stop'
try {
    $folder = Split-Path -Parent $Configuration
    # Windows filenames cannot contain quotes. These are individual quoted
    # arguments to the trusted Python executable, never a shell expression.
    $arguments = @('-u', ('"' + $Worker + '"'), ('"' + $Configuration + '"'))
    Start-Process -FilePath $Python -ArgumentList $arguments -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $folder 'stdout.log') `
        -RedirectStandardError (Join-Path $folder 'stderr.log') | Out-Null
} catch {
    $_.Exception.ToString() | Set-Content -LiteralPath ($Configuration + '.error')
    exit 1
}
