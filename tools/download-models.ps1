# Unduh semua model AI ke folder "models" (sekali saja, ±2,9 GB).
# Unduhan paralel (beberapa koneksi sekaligus) jauh lebih cepat dari satu koneksi.
# File yang sudah lengkap dilewati; kalau terputus, jalankan lagi dan unduhan dilanjutkan.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$models = Join-Path $root 'models'
$HF = 'https://huggingface.co'
$curlBase = @('-L', '--fail', '--silent', '--show-error', '--retry', '10', '--retry-all-errors', '--retry-delay', '2')

$whisperCommon = @('config.json', 'generation_config.json', 'preprocessor_config.json', 'tokenizer.json', 'tokenizer_config.json',
                   'added_tokens.json', 'special_tokens_map.json', 'normalizer.json', 'vocab.json', 'merges.txt')
$qwenId = 'Qwen3.5-2B-q4f16_1-MLC'
$qwenDir = "$qwenId/resolve/main"
$qwenUrl = "$HF/mlc-ai/$qwenId/resolve/main"

$small = New-Object System.Collections.ArrayList   # [url, relative path]
$big = New-Object System.Collections.ArrayList
foreach ($f in $whisperCommon) {
  [void]$small.Add(@("$HF/onnx-community/whisper-large-v3-turbo/resolve/main/$f", "whisper-large-v3-turbo/$f"))
  [void]$small.Add(@("$HF/onnx-community/whisper-base/resolve/main/$f", "whisper-base/$f"))
}
[void]$big.Add(@("$HF/onnx-community/whisper-large-v3-turbo/resolve/main/onnx/encoder_model_fp16.onnx", 'whisper-large-v3-turbo/onnx/encoder_model_fp16.onnx'))
[void]$big.Add(@("$HF/onnx-community/whisper-large-v3-turbo/resolve/main/onnx/decoder_model_merged_q4f16.onnx", 'whisper-large-v3-turbo/onnx/decoder_model_merged_q4f16.onnx'))
[void]$small.Add(@("$HF/onnx-community/whisper-base/resolve/main/onnx/encoder_model.onnx", 'whisper-base/onnx/encoder_model.onnx'))
[void]$small.Add(@("$HF/onnx-community/whisper-base/resolve/main/onnx/decoder_model_merged_quantized.onnx", 'whisper-base/onnx/decoder_model_merged_quantized.onnx'))
foreach ($f in @('mlc-chat-config.json', 'tensor-cache.json', 'tokenizer.json', 'tokenizer_config.json', 'vocab.json', 'merges.txt')) {
  [void]$small.Add(@("$qwenUrl/$f", "$qwenDir/$f"))
}
[void]$small.Add(@('https://raw.githubusercontent.com/mlc-ai/binary-mlc-llm-libs/main/web-llm-models/v0_2_86/base/Qwen3.5-2B-q4f16_1_cs1k-webgpu.wasm', 'libs/Qwen3.5-2B-q4f16_1_cs1k-webgpu.wasm'))

function Test-Done($rel) { $p = Join-Path $models $rel; (Test-Path $p) -and (Get-Item $p).Length -gt 0 }

# Many files at once: one curl process, 8 parallel connections.
function Get-Many($list) {
  $todo = @($list | Where-Object { -not (Test-Done $_[1]) })
  if (-not $todo.Count) { return 0 }
  Write-Host "  Mengunduh $($todo.Count) file ..."
  $cfg = New-TemporaryFile
  $lines = foreach ($t in $todo) {
    $dest = Join-Path $models $t[1]
    New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
    "url = `"$($t[0])`""; "output = `"$($dest -replace '\\', '/').part`""
  }
  Set-Content -Path $cfg -Value $lines -Encoding ascii
  & curl.exe @curlBase --parallel --parallel-max 8 -C - -K $cfg.FullName
  $code = $LASTEXITCODE; Remove-Item $cfg
  if ($code -ne 0) { throw "Sebagian file gagal diunduh (curl exit $code). Jalankan lagi untuk melanjutkan." }
  foreach ($t in $todo) { $d = Join-Path $models $t[1]; Move-Item -Force "$d.part" $d }
  return $todo.Count
}

# One big file split into 12 ranges downloaded in parallel, then joined.
function Get-Big($url, $rel) {
  if (Test-Done $rel) { return 0 }
  $dest = Join-Path $models $rel
  New-Item -ItemType Directory -Force (Split-Path -Parent $dest) | Out-Null
  $head = & curl.exe -sIL --retry 5 $url
  $size = [int64](($head | Select-String '^content-length:\s*(\d+)' | Select-Object -Last 1).Matches[0].Groups[1].Value)
  Write-Host ("  Mengunduh {0} ({1:N0} MB) ..." -f $rel, ($size / 1MB))
  $n = 12; $step = [math]::Ceiling($size / $n); $segs = @()
  for ($i = 0; $i -lt $n; $i++) {
    $a = $i * $step; $b = [math]::Min($size, $a + $step) - 1
    $segs += ,@("$dest.seg$i", $a, $b)
  }
  $len = { param($p) if (Test-Path $p) { (Get-Item $p).Length } else { 0 } }
  # Each round fetches only the bytes still missing from every segment and appends them,
  # so a dropped connection never throws away what was already downloaded.
  for ($round = 1; $round -le 40; $round++) {
    $cfg = New-TemporaryFile; $pending = @()
    $lines = foreach ($s in $segs) {
      $have = & $len $s[0]; $want = $s[2] - $s[1] + 1
      if ($have -ge $want) { continue }
      $pending += ,$s
      # "next" keeps every range separate; without it curl applies the last range to all transfers.
      if ($pending.Count -gt 1) { 'next' }
      "url = `"$url`""; "range = $($s[1] + $have)-$($s[2])"; "output = `"$("$($s[0]).tmp" -replace '\\', '/')`""
      'location'; 'silent'; 'speed-limit = 50000'; 'speed-time = 20'
    }
    if (-not $pending.Count) { Remove-Item $cfg; break }
    Set-Content -Path $cfg -Value $lines -Encoding ascii
    & curl.exe --parallel --parallel-max $n -K $cfg.FullName
    Remove-Item $cfg
    foreach ($s in $pending) {
      $tmp = "$($s[0]).tmp"
      if (Test-Path $tmp) {
        $out = [IO.File]::Open($s[0], 'Append'); $in = [IO.File]::OpenRead($tmp)
        try { $in.CopyTo($out, 4MB) } finally { $in.Dispose(); $out.Dispose() }
        Remove-Item $tmp
      }
    }
    $got = ($segs | ForEach-Object { & $len $_[0] } | Measure-Object -Sum).Sum
    Write-Host ("    {0:N0} / {1:N0} MB" -f ($got / 1MB), ($size / 1MB))
  }
  foreach ($s in $segs) { if ((& $len $s[0]) -ne ($s[2] - $s[1] + 1)) { throw "Unduhan $rel belum lengkap. Jalankan lagi untuk melanjutkan." } }
  $out = [IO.File]::Create("$dest.part")
  try { foreach ($s in $segs) { $in = [IO.File]::OpenRead($s[0]); try { $in.CopyTo($out, 4MB) } finally { $in.Dispose() } } } finally { $out.Dispose() }
  if ((Get-Item "$dest.part").Length -ne $size) { throw "Ukuran $rel tidak cocok, jalankan lagi." }
  Move-Item -Force "$dest.part" $dest
  foreach ($s in $segs) { Remove-Item $s[0] }
  return 1
}

Write-Host 'Memeriksa model AI di folder models ...'
$new = Get-Many $small
foreach ($b in $big) { $new += Get-Big $b[0] $b[1] }
# Qwen weights come in ~40 shards listed in tensor-cache.json.
$manifest = Get-Content -Raw (Join-Path $models "$qwenDir/tensor-cache.json") | ConvertFrom-Json
$shards = foreach ($r in $manifest.records) { ,@("$qwenUrl/$($r.dataPath)", "$qwenDir/$($r.dataPath)") }
$new += Get-Many $shards

$size = (Get-ChildItem -Recurse -File $models | Measure-Object Length -Sum).Sum / 1GB
if ($new -gt 0) { Write-Host ("Selesai: {0} file baru, total model {1:N2} GB." -f $new, $size) }
else { Write-Host ("Model sudah lengkap ({0:N2} GB)." -f $size) }
