# Server lokal kecil untuk TikScribe (tanpa install apa pun, cukup PowerShell bawaan Windows).
# Browser butuh http://localhost agar boleh memuat model AI dan memakai WebGPU; file:// diblokir.
param([int]$Port = 8000, [switch]$NoBrowser)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path

$listener = $null
foreach ($p in $Port..($Port + 20)) {
  try {
    $l = New-Object System.Net.HttpListener
    $l.Prefixes.Add("http://localhost:$p/")
    $l.Start(); $listener = $l; $Port = $p; break
  } catch { }
}
if (-not $listener) { throw "Tidak ada port kosong di $Port-$($Port + 20)." }

$url = "http://localhost:$Port/"
Write-Host ""
Write-Host "  TikScribe berjalan di $url" -ForegroundColor Cyan
Write-Host "  Biarkan jendela ini terbuka selama dipakai. Tutup jendela untuk berhenti."
Write-Host ""
if (-not $NoBrowser) {
  # Chrome/Edge have the most complete WebGPU (fp16) support; fall back to the default browser.
  $browsers = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
                "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
                "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe")
  $b = $browsers | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
  if ($b) {
    # Its own small profile (in this folder) makes it a separate browser process, so the flag below always
    # applies, even when the browser is already open: use the fast GPU (NVIDIA/AMD) instead of the Intel one.
    $profile = Join-Path $root '.browser-profile'
    Start-Process $b @("--user-data-dir=`"$profile`"", '--force_high_performance_gpu', '--no-first-run', '--no-default-browser-check', "--app=$url")
  } else {
    Write-Host '  Chrome/Edge tidak ditemukan. Buka alamat di atas di Chrome atau Edge (Firefox belum stabil untuk AI di GPU).' -ForegroundColor Yellow
    Start-Process $url
  }
}

# Each request is handled on its own thread so a 1.3 GB model file never blocks the page.
$handler = {
  param($ctx, $root)
  $types = @{ '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.mjs' = 'text/javascript; charset=utf-8';
              '.css' = 'text/css; charset=utf-8'; '.json' = 'application/json; charset=utf-8'; '.wasm' = 'application/wasm';
              '.txt' = 'text/plain; charset=utf-8'; '.md' = 'text/plain; charset=utf-8'; '.png' = 'image/png'; '.svg' = 'image/svg+xml'; '.ico' = 'image/x-icon' }
  $res = $ctx.Response
  try {
    $rel = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath).TrimStart('/')
    if ($rel -eq '') { $rel = 'index.html' }
    $path = [IO.Path]::GetFullPath([IO.Path]::Combine($root, $rel))
    if (-not $path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or -not [IO.File]::Exists($path)) {
      $res.StatusCode = 404; $res.Close(); return
    }
    $ext = [IO.Path]::GetExtension($path).ToLower()
    $res.ContentType = if ($types.ContainsKey($ext)) { $types[$ext] } else { 'application/octet-stream' }
    $res.Headers.Add('Cache-Control', 'no-store')  # files are already on this disk; never let the browser keep a second copy
    $fs = [IO.File]::OpenRead($path)
    try {
      $res.ContentLength64 = $fs.Length
      if ($ctx.Request.HttpMethod -ne 'HEAD') { $fs.CopyTo($res.OutputStream, 1MB) }
    } finally { $fs.Dispose() }
    $res.Close()
  } catch { try { $res.Abort() } catch { } }
}

$pool = [RunspaceFactory]::CreateRunspacePool(1, 16); $pool.Open()
$running = New-Object System.Collections.ArrayList
try {
  while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $ps = [PowerShell]::Create(); $ps.RunspacePool = $pool
    [void]$ps.AddScript($handler).AddArgument($ctx).AddArgument($root)
    [void]$running.Add(@{ ps = $ps; h = $ps.BeginInvoke() })
    foreach ($r in @($running)) { if ($r.h.IsCompleted) { $r.ps.Dispose(); $running.Remove($r) } }
  }
} finally { $listener.Stop(); $pool.Close() }
