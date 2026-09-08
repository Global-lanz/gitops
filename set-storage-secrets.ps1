# Adiciona STORAGE_ACCESS_KEY e STORAGE_SECRET_KEY ao secret cifrado do Astra qa.
#
# As chaves sao lidas por Read-Host: nao aparecem no historico do PowerShell e
# nao passam por nenhum arquivo em texto puro.

$ErrorActionPreference = "Stop"

# Onde esta a chave age. Procura em vez de assumir: o sops no Windows usa
# %APPDATA%, mas o arquivo costuma acabar em ~/.config por causa da documentacao
# escrita para Linux, e uma variavel SOPS_AGE_KEY_FILE sobrando na sessao aponta
# para o lugar errado sem dizer nada.
$keyCandidates = @(
    "$env:APPDATA/sops/age/keys.txt",
    "$env:USERPROFILE/AppData/Roaming/sops/age/keys.txt",
    "$env:USERPROFILE/.config/sops/age/keys.txt"
)
$keyFile = $keyCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $keyFile) {
    Write-Host "Chave age nao encontrada. Procurei em:" -ForegroundColor Red
    $keyCandidates | ForEach-Object { Write-Host "  $_" }
    exit 1
}
$env:SOPS_AGE_KEY_FILE = $keyFile
Write-Host "Chave age: $keyFile"

$file = "C:\dev\social-midia\k8s-agents\gitops\apps\astra\overlays\qa\secret.enc.yaml"

if (-not (Test-Path $file)) {
    Write-Host "Arquivo nao encontrado: $file" -ForegroundColor Red
    exit 1
}

# Confere que o sops consegue decifrar antes de tentar escrever.
sops decrypt $file | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "sops nao consegue decifrar o arquivo. Chave age ausente ou errada." -ForegroundColor Red
    exit 1
}

$access = Read-Host "Cole a STORAGE_ACCESS_KEY"
$secret = Read-Host "Cole a STORAGE_SECRET_KEY"

if ([string]::IsNullOrWhiteSpace($access) -or [string]::IsNullOrWhiteSpace($secret)) {
    Write-Host "Uma das chaves veio vazia. Nada foi alterado." -ForegroundColor Red
    exit 1
}

# O sops espera o valor como JSON. Ao chamar um executavel nativo o PowerShell
# come as aspas duplas comuns, entao elas vao escapadas com barra invertida.
$accessJson = '\"' + $access + '\"'
$secretJson = '\"' + $secret + '\"'

sops set $file '[\"stringData\"][\"STORAGE_ACCESS_KEY\"]' $accessJson
if ($LASTEXITCODE -ne 0) { Write-Host "Falha ao gravar STORAGE_ACCESS_KEY" -ForegroundColor Red; exit 1 }

sops set $file '[\"stringData\"][\"STORAGE_SECRET_KEY\"]' $secretJson
if ($LASTEXITCODE -ne 0) { Write-Host "Falha ao gravar STORAGE_SECRET_KEY" -ForegroundColor Red; exit 1 }

Remove-Variable access, secret, accessJson, secretJson

# Verificacao: lista os nomes das chaves decifradas, sem mostrar valor nenhum.
Write-Host ""
Write-Host "Chaves no secret agora:" -ForegroundColor Green
$names = sops decrypt $file |
    Select-String -Pattern "^\s+[A-Z_]+:" |
    ForEach-Object { ($_.Line -split ":")[0].Trim() }

$names | ForEach-Object { Write-Host "  $_" }

if ($names -contains "STORAGE_ACCESS_KEY" -and $names -contains "STORAGE_SECRET_KEY") {
    Write-Host ""
    Write-Host "OK. Agora: git add / commit / push no repo gitops." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "As chaves de storage NAO aparecem. Algo falhou." -ForegroundColor Red
    exit 1
}
