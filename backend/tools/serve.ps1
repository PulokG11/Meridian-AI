# Minimal static file server for serving the repo root (index.html, process-maps.html) locally
# so the browser pane can open it (file:// URLs disable some browser features the prototype needs).
# Usage: powershell -File backend/tools/serve.ps1 [-Port 8731]
# Ctrl+C to stop, or kill the process directly.

param([int]$Port = 8731)

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
Write-Output "Serving $repoRoot on http://127.0.0.1:$Port/  (Ctrl+C to stop)"

$mime = @{ '.html'='text/html'; '.js'='text/javascript'; '.css'='text/css'; '.json'='application/json'; '.png'='image/png'; '.svg'='image/svg+xml' }

try {
  while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $req = $ctx.Request
    $res = $ctx.Response
    $path = $req.Url.AbsolutePath
    if ($path -eq '/') { $path = '/index.html' }
    $filePath = Join-Path $repoRoot ($path.TrimStart('/'))
    if (Test-Path $filePath -PathType Leaf) {
      $ext = [System.IO.Path]::GetExtension($filePath)
      $ct = $mime[$ext]; if (-not $ct) { $ct = 'application/octet-stream' }
      $bytes = [System.IO.File]::ReadAllBytes($filePath)
      $res.ContentType = $ct
      $res.ContentLength64 = $bytes.Length
      $res.OutputStream.Write($bytes, 0, $bytes.Length)
    } else {
      $res.StatusCode = 404
      $msg = [System.Text.Encoding]::UTF8.GetBytes("Not found: $path")
      $res.OutputStream.Write($msg, 0, $msg.Length)
    }
    $res.OutputStream.Close()
  }
} finally {
  $listener.Stop()
}
