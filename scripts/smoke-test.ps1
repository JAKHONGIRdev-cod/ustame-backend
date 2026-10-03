# Usta API smoke test: send-code -> verify -> me.
# Ishlatish:  powershell -ExecutionPolicy Bypass -File scripts\smoke-test.ps1 [-BaseUrl http://localhost:3000]
# Test raqam va kod .env.local dagi TEST_PHONES ning birinchi yozuvidan olinadi (SMS ketmaydi).
# Token va kod ekranga chiqarilmaydi.
# Eslatma: send-code bir raqamga 60 soniyada 1 marta va soatiga 5 martagacha ruxsat beradi,
# shuning uchun testni ketma-ket ko'p ishga tushirsangiz 2-qadam 429 qaytarishi mumkin.

param(
  [string]$BaseUrl = "http://localhost:3000",
  [string]$EnvFile = (Join-Path $PSScriptRoot "..\.env.local")
)

$ErrorActionPreference = "Stop"
# Windows PowerShell 5.1 POST so'rovga "Expect: 100-continue" qo'shadi, vercel dev esa uni qabul qilmaydi (500).
[System.Net.ServicePointManager]::Expect100Continue = $false
$BaseUrl = $BaseUrl.TrimEnd("/")

# --- TEST_PHONES ni o'qish ---
if (-not (Test-Path $EnvFile)) { Write-Host ".env.local topilmadi: $EnvFile" -ForegroundColor Red; exit 1 }
$line = Get-Content $EnvFile | Where-Object { $_ -match '^\s*TEST_PHONES\s*=' } | Select-Object -First 1
if (-not $line) { Write-Host "TEST_PHONES .env.local da yo'q" -ForegroundColor Red; exit 1 }
$value = ($line -replace '^\s*TEST_PHONES\s*=\s*', '').Trim().Trim('"', "'")
$first = ($value -split ',')[0].Trim()
$parts = $first -split ':'
if ($parts.Count -ne 2 -or $parts[0] -notmatch '^998\d{9}$' -or $parts[1] -notmatch '^\d{6}$') {
  Write-Host "TEST_PHONES birinchi yozuvi '998XXXXXXXXX:123456' formatida emas" -ForegroundColor Red; exit 1
}
$Phone = $parts[0]
$Code = $parts[1]
# To'g'ri koddan farqli 6 xonali kod
$WrongCode = if ($Code -eq "000000") { "999999" } else { "000000" }
$masked = $Phone.Substring(0, 5) + "*****" + $Phone.Substring(10)

# --- HTTP yordamchi: holat kodi va JSON ni qaytaradi, xatoda throw qilmaydi ---
function Invoke-Api {
  param([string]$Method, [string]$Path, $Body = $null, [hashtable]$Headers = @{})
  $params = @{ Uri = "$BaseUrl$Path"; Method = $Method; Headers = $Headers; UseBasicParsing = $true }
  if ($null -ne $Body) {
    $params.Body = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Compress))
    $params.ContentType = "application/json; charset=utf-8"
  }
  $status = 0; $content = $null
  try {
    $r = Invoke-WebRequest @params
    $status = [int]$r.StatusCode; $content = $r.Content
  } catch {
    $resp = $_.Exception.Response
    if ($null -eq $resp) { throw "Serverga ulanib bo'lmadi ($BaseUrl): $($_.Exception.Message)" }
    $status = [int]$resp.StatusCode
    $content = $_.ErrorDetails.Message
    if (-not $content -and $resp -is [System.Net.HttpWebResponse]) {
      $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
      $content = $reader.ReadToEnd(); $reader.Close()
    }
  }
  $json = $null
  if ($content) { try { $json = $content | ConvertFrom-Json } catch { } }
  return [pscustomobject]@{ Status = $status; Json = $json }
}

$script:passed = 0
$script:failed = 0
function Check {
  param([string]$Name, $Res, [int[]]$Expected, [scriptblock]$Extra = $null)
  $ok = $Expected -contains $Res.Status
  $detail = ""
  if ($ok -and $Extra) { $detail = & $Extra; if ($detail) { $ok = $false } }
  # Faqat xato matnini chiqaramiz (token/kod hech qachon chiqmaydi)
  $err = if ($Res.Json -and $Res.Json.error) { " error=`"$($Res.Json.error)`"" } else { "" }
  if ($ok) {
    $script:passed++
    Write-Host ("[OK]   {0} -> {1}{2}" -f $Name, $Res.Status, $err) -ForegroundColor Green
  } else {
    $script:failed++
    Write-Host ("[FAIL] {0} -> {1} (kutilgan: {2}){3} {4}" -f $Name, $Res.Status, ($Expected -join "/"), $err, $detail) -ForegroundColor Red
  }
}

Write-Host "Server: $BaseUrl   Test raqam: $masked`n"

# 1. send-code
Check "send-code noto'g'ri raqam" (Invoke-Api POST "/api/auth/send-code" @{ phone = "12345" }) 400
$r = Invoke-Api POST "/api/auth/send-code" @{ phone = $Phone }
Check "send-code test raqam" $r 200 { if (-not $r.Json.ok) { "ok=true kelmadi" } }
if ($r.Status -eq 429) { Write-Host "       (60 soniya yoki soatlik limit - biroz kutib qayta ishga tushiring)" -ForegroundColor Yellow }
Check "send-code darhol qayta" (Invoke-Api POST "/api/auth/send-code" @{ phone = $Phone }) 429

# 2. verify
Check "verify noto'g'ri kod" (Invoke-Api POST "/api/auth/verify" @{ phone = $Phone; code = $WrongCode }) 400, 401
$r = Invoke-Api POST "/api/auth/verify" @{ phone = $Phone; code = $Code }
Check "verify to'g'ri kod" $r 200 {
  if (-not $r.Json.token) { "token kelmadi" }
  elseif ($r.Json.user.phone -ne $Phone) { "user.phone mos emas" }
}
$token = $r.Json.token
if ($token) { Write-Host "       token olindi (uzunligi $($token.Length), ekranga chiqarilmaydi)" }

# 3. me
Check "me tokensiz" (Invoke-Api GET "/api/me") 401
Check "me buzuq token" (Invoke-Api GET "/api/me" -Headers @{ Authorization = "Bearer buzuq.token.qiymat" }) 401
if ($token) {
  $r = Invoke-Api GET "/api/me" -Headers @{ Authorization = "Bearer $token" }
  Check "me to'g'ri token" $r 200 { if ($r.Json.phone -ne $Phone) { "phone mos emas" } }
} else {
  $script:failed++
  Write-Host "[FAIL] me to'g'ri token -> token yo'q, o'tkazib yuborildi" -ForegroundColor Red
}
$token = $null

Write-Host "`nNatija: $script:passed OK, $script:failed FAIL"
if ($script:failed -gt 0) { exit 1 }
