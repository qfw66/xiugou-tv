$ErrorActionPreference = "Stop"
$jarPath = Join-Path $PSScriptRoot "dist/companion-service.jar"
$port = 18999

Write-Host "Starting Companion Service on port $port..."
$proc = Start-Process -FilePath "java" -ArgumentList "-jar", ('"' + $jarPath + '"'), "--port=$port" -WindowStyle Hidden -PassThru

try {
    Start-Sleep -Milliseconds 1200
    Write-Host "Checking /health endpoint..."
    $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$port/health" -Method Get
    Write-Host "Response received: $($resp | ConvertTo-Json -Compress)"

    Write-Host "Checking /spider/load dummy test..."
    $loadBody = @{
        key = "testSite"
        api = "csp_Douban"
        ext = ""
        jar = ""
    } | ConvertTo-Json
    $loadResp = Invoke-RestMethod -Uri "http://127.0.0.1:$port/spider/load" -Method Post -Body $loadBody -ContentType "application/json"
    Write-Host "Load response: $($loadResp | ConvertTo-Json -Compress)"

    Write-Host "Sending /shutdown..."
    Invoke-RestMethod -Uri "http://127.0.0.1:$port/shutdown" -Method Post | Out-Null
    Write-Host "Companion service successfully shut down!"
} finally {
    if ($proc -and !$proc.HasExited) {
        Stop-Process -Id $proc.Id -Force
    }
}
