# Adiciona um segundo recipient age a TODOS os secret.enc.yaml do repo.
#
# Por que isso importa: hoje o .sops.yaml tem um unico recipient, e a chave
# privada dele so existe dentro do cluster (flux-system/sops-age). Isso e um
# ponto unico de falha com consequencia permanente -- perdeu o cluster sem
# backup da chave, todo secret.enc.yaml vira lixo cifrado para sempre. Nenhum
# `git revert` traz de volta.
#
# Com dois recipients, qualquer uma das duas chaves privadas decifra. O dado
# nao muda: o `sops updatekeys` so re-cifra a data key para o novo conjunto de
# destinatarios.
#
# Rode o sops-doctor.ps1 antes. Sem conseguir decifrar, isto nao tem como rodar.

[CmdletBinding()]
param(
    # Chave PUBLICA (age1...) que passara a poder decifrar. Tipicamente uma que
    # voce ja tem localmente -- veja a saida do sops-doctor.ps1.
    [Parameter(Mandatory = $true)] [string] $Recipient,
    # Mostra o que mudaria sem escrever nada.
    [switch] $Simular
)

$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $MyInvocation.MyCommand.Path

if ($Recipient -notmatch '^age1[a-z0-9]{50,}$') {
    Write-Host "Recipient nao parece uma chave publica age: $Recipient" -ForegroundColor Red
    exit 1
}

Remove-Item Env:\SOPS_AGE_KEY_FILE -ErrorAction SilentlyContinue
$keyCandidates = @(
    "$env:APPDATA/sops/age/keys.txt",
    "$env:USERPROFILE/AppData/Roaming/sops/age/keys.txt",
    "$env:USERPROFILE/.config/sops/age/keys.txt"
)
$keyFile = $keyCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $keyFile) {
    Write-Host "Chave age nao encontrada. Rode o sops-doctor.ps1." -ForegroundColor Red
    exit 1
}
$env:SOPS_AGE_KEY_FILE = $keyFile

$sopsYaml = Join-Path $repo ".sops.yaml"
$alvos = @(Get-ChildItem -Path (Join-Path $repo "apps") -Recurse -Filter "secret.enc.yaml" -File)

Write-Host ""
Write-Host "Recipient a adicionar: $Recipient"
Write-Host "Chave age em uso:      $keyFile"
Write-Host "Secrets encontrados:   $($alvos.Count)"
Write-Host ""

if ($alvos.Count -eq 0) {
    Write-Host "Nenhum secret.enc.yaml encontrado. Abortado." -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------- 1. porta de entrada
# Checa TODOS antes de tocar em qualquer um. Um arquivo que ja nao decifrava
# antes desta mudanca nao pode ser confundido depois com estrago deste script.
Write-Host "Conferindo que todos decifram HOJE..." -ForegroundColor Cyan
$quebrados = @()
foreach ($a in $alvos) {
    & { $ErrorActionPreference = 'Continue'; sops decrypt $a.FullName 2>&1 } | Out-Null
    if ($LASTEXITCODE -ne 0) { $quebrados += $a.FullName }
}
if ($quebrados) {
    Write-Host "Estes nao decifram nem antes da mudanca:" -ForegroundColor Red
    $quebrados | ForEach-Object { Write-Host "  $($_.Replace($repo, '.'))" -ForegroundColor Red }
    Write-Host ""
    Write-Host "Resolva isso primeiro (sops-doctor.ps1). Nada foi alterado." -ForegroundColor Red
    exit 1
}
Write-Host "  todos os $($alvos.Count) decifram." -ForegroundColor Green

# ------------------------------------------------------- 2. o .sops.yaml
$conteudo = [IO.File]::ReadAllText($sopsYaml)
if ($conteudo -match [regex]::Escape($Recipient)) {
    Write-Host ""
    Write-Host "O .sops.yaml ja lista esse recipient. Seguindo para o updatekeys." -ForegroundColor Yellow
} else {
    # O campo `age:` do sops aceita varios destinatarios separados por virgula.
    $novo = [regex]::Replace($conteudo, '(?m)^(\s*age:\s*)(age1[a-z0-9]+)\s*$', "`${1}`${2},$Recipient")
    if ($novo -eq $conteudo) {
        Write-Host "Nao consegui localizar as linhas 'age:' no .sops.yaml." -ForegroundColor Red
        exit 1
    }
    if ($Simular) {
        Write-Host "[simulacao] .sops.yaml ficaria assim:" -ForegroundColor Cyan
        $novo -split "`n" | Where-Object { $_ -match 'age:' } | ForEach-Object { Write-Host "  $_" }
    } else {
        [IO.File]::WriteAllText($sopsYaml, $novo)
        Write-Host ""
        Write-Host ".sops.yaml atualizado." -ForegroundColor Green
    }
}

# ------------------------------------------------------- 3. updatekeys
Write-Host ""
if ($Simular) {
    Write-Host "[simulacao] rodaria 'sops updatekeys -y' em:" -ForegroundColor Cyan
    $alvos | ForEach-Object { Write-Host "  $($_.FullName.Replace($repo, '.'))" }
    Write-Host ""
    Write-Host "Nada foi alterado." -ForegroundColor Yellow
    exit 0
}

Write-Host "Re-cifrando a data key de cada secret..." -ForegroundColor Cyan
$falhas = @()
foreach ($a in $alvos) {
    $rel = $a.FullName.Replace($repo, '.')
    & { $ErrorActionPreference = 'Continue'; sops updatekeys -y $a.FullName 2>&1 } | Out-Null
    if ($LASTEXITCODE -ne 0) { $falhas += $rel; Write-Host "  FALHOU  $rel" -ForegroundColor Red }
    else { Write-Host "  ok      $rel" -ForegroundColor DarkGray }
}

# ------------------------------------------------------- 4. conferir
Write-Host ""
Write-Host "Conferindo que todos ainda decifram..." -ForegroundColor Cyan
$pos = @()
foreach ($a in $alvos) {
    & { $ErrorActionPreference = 'Continue'; sops decrypt $a.FullName 2>&1 } | Out-Null
    if ($LASTEXITCODE -ne 0) { $pos += $a.FullName.Replace($repo, '.') }
}

Write-Host ""
if ($falhas -or $pos) {
    Write-Host "DEU RUIM. Reverta tudo com:" -ForegroundColor Red
    Write-Host "  git -C `"$repo`" checkout -- .sops.yaml apps/" -ForegroundColor White
    exit 1
}

Write-Host "OK: $($alvos.Count) secrets agora aceitam os dois recipients." -ForegroundColor Green
Write-Host "Confira o diff e faca commit. O Flux continua decifrando com a chave" -ForegroundColor Green
Write-Host "do cluster -- ela nao foi removida de lugar nenhum." -ForegroundColor Green
Write-Host ""
