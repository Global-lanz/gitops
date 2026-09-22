# Adiciona ou troca UM campo em qualquer secret.enc.yaml deste repo,
# preservando todos os outros campos como estao.
#
# Generaliza o recriar-secret.ps1, que so sabe lidar com o secret do Astra qa e
# com uma lista de campos fixa no codigo -- adicionar um campo novo la exige
# editar o script. Aqui os campos existentes sao descobertos por leitura, entao
# nada se perde por omissao.
#
# Exemplos:
#   .\sops-campo.ps1 -Arquivo apps\norteia\overlays\prod\secret.enc.yaml `
#                    -Campo EMBED_SHARED_SECRET -Gerar -Mostrar
#   .\sops-campo.ps1 -Arquivo apps\guia\overlays\qa\secret.enc.yaml `
#                    -Campo JWT_SECRET -Valor "..."

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Arquivo,
    [Parameter(Mandatory = $true)] [string] $Campo,
    [string] $Valor,
    # Sorteia um segredo forte em vez de receber um pronto.
    [switch] $Gerar,
    # Imprime o valor. So faz sentido com -Gerar: um segredo que voce precisa
    # entregar a um terceiro nao serve se voce nunca o ve. Fora esse caso o
    # script nao mostra valor nenhum, nem os que ja existiam.
    [switch] $Mostrar
)

$ErrorActionPreference = "Stop"

$repo = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not [IO.Path]::IsPathRooted($Arquivo)) { $Arquivo = Join-Path $repo $Arquivo }
if (-not (Test-Path $Arquivo)) {
    Write-Host "Arquivo nao encontrado: $Arquivo" -ForegroundColor Red
    exit 1
}

if ($Gerar -and $Valor) {
    Write-Host "Use -Gerar OU -Valor, nao os dois." -ForegroundColor Red
    exit 1
}
if (-not $Gerar -and -not $Valor) {
    Write-Host "Informe -Valor <texto> ou use -Gerar." -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- chave age
# Mesma busca do recriar-secret.ps1: no Windows o sops le %APPDATA%, mas o
# arquivo costuma acabar em ~/.config por causa da doc escrita para Linux.
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

$sopsYaml  = Join-Path $repo ".sops.yaml"
$recipients = @(Select-String -Path $sopsYaml -Pattern 'age1[a-z0-9]+' -AllMatches |
    ForEach-Object { $_.Matches } | ForEach-Object { $_.Value } | Select-Object -Unique)
if (-not $recipients) {
    Write-Host "Nao achei recipient age no .sops.yaml" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- ler o atual
Write-Host "Arquivo:   $Arquivo"
Write-Host "Chave age: $keyFile"
Write-Host ""
Write-Host "Decifrando o secret atual..."

# O 2>&1 num exe nativo faz o PS 5.1 empacotar cada linha de stderr num
# ErrorRecord; com ErrorActionPreference=Stop isso vira excecao terminante e
# mata o script ANTES da mensagem de erro util abaixo. Escopar o Continue so
# nesta chamada preserva o diagnostico.
$plain = & { $ErrorActionPreference = 'Continue'; sops decrypt $Arquivo 2>&1 }
if ($LASTEXITCODE -ne 0) {
    Write-Host "NAO decifrou. Erro do sops:" -ForegroundColor Red
    $plain | ForEach-Object { Write-Host "  $_" }
    Write-Host ""
    Write-Host "Rode o sops-doctor.ps1 -- ele diz exatamente qual chave falta." -ForegroundColor Red
    exit 1
}

# Preserva a ordem de leitura: o diff do git fica legivel e a revisao, honesta.
$campos = [ordered]@{}
$nomeSecret = $null
$tipoSecret = "Opaque"

foreach ($line in $plain) {
    $t = "$line"
    if ($t -match '^\s{2,}name:\s*(\S+)\s*$' -and -not $nomeSecret) { $nomeSecret = $Matches[1]; continue }
    if ($t -match '^type:\s*(\S+)\s*$') { $tipoSecret = $Matches[1]; continue }
    if ($t -match '^\s+([A-Z][A-Z0-9_]*):\s*(.*)$') {
        $campos[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
    }
}

if (-not $nomeSecret) {
    Write-Host "Nao consegui ler metadata.name do secret. Abortado." -ForegroundColor Red
    exit 1
}
if ($campos.Count -eq 0) {
    Write-Host "Nenhum campo reconhecido em stringData. Abortado para nao truncar." -ForegroundColor Red
    exit 1
}

Write-Host "Secret:    $nomeSecret" -ForegroundColor Green
Write-Host "Campos ja existentes: $($campos.Keys -join ', ')" -ForegroundColor Green

$existia = $campos.Contains($Campo)

# ---------------------------------------------------------------- novo valor
if ($Gerar) {
    # 32 bytes de CSPRNG em base64url: sem +, / ou = para nao brigar com
    # header HTTP, .env, YAML nem linha de comando de quem vai consumir.
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $Valor = [Convert]::ToBase64String($bytes).Replace('+','-').Replace('/','_').TrimEnd('=')
}

if ($existia -and $campos[$Campo] -eq $Valor) {
    Write-Host ""
    Write-Host "O campo $Campo ja tem exatamente esse valor. Nada a fazer." -ForegroundColor Yellow
    exit 0
}

$campos[$Campo] = $Valor

Write-Host ""
if ($existia) {
    Write-Host "TROCANDO o campo $Campo (valor anterior sera perdido)." -ForegroundColor Yellow
} else {
    Write-Host "ADICIONANDO o campo $Campo." -ForegroundColor Yellow
}

# ---------------------------------------------------------------- reescrever
# O texto puro so existe num temporario fora do repositorio, apagado no
# finally mesmo se algo falhar no meio -- igual ao recriar-secret.ps1.
$tmp = Join-Path $env:TEMP ("sops-campo-" + [guid]::NewGuid().ToString() + ".yaml")

try {
    $lines = @(
        "apiVersion: v1",
        "kind: Secret",
        "metadata:",
        "    name: $nomeSecret",
        "type: $tipoSecret",
        "stringData:"
    )
    foreach ($k in $campos.Keys) {
        # Aspas simples de YAML: literal, sem interpretar barra invertida nem
        # cifrao. Uma aspa simples dentro do valor vira duas (escape do YAML).
        $v = ([string]$campos[$k]).Replace("'", "''")
        $lines += "    ${k}: '$v'"
    }

    Set-Content -Path $tmp -Value $lines -Encoding ascii

    # Nao chamar isto de $args: e variavel automatica do PowerShell.
    $sopsArgs = @("encrypt", "--encrypted-regex", "^(data|stringData)$")
    foreach ($r in $recipients) { $sopsArgs += @("--age", $r) }
    $sopsArgs += $tmp

    $cifrado = & sops @sopsArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host "sops encrypt falhou. O arquivo original NAO foi tocado." -ForegroundColor Red
        exit 1
    }

    Set-Content -Path $Arquivo -Value $cifrado -Encoding ascii
}
finally {
    if (Test-Path $tmp) { Remove-Item -Force $tmp }
    Remove-Variable campos, lines, v, cifrado -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- conferir
# Le de volta do disco: a unica prova que vale e o arquivo que vai pro commit.
$depois = & { $ErrorActionPreference = 'Continue'; sops decrypt $Arquivo 2>&1 }
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "O arquivo novo NAO decifra. Restaure com:" -ForegroundColor Red
    Write-Host "  git -C `"$repo`" checkout -- $Arquivo" -ForegroundColor Red
    exit 1
}

$nomes = @($depois | Select-String -Pattern "^\s+[A-Z][A-Z0-9_]*:" |
    ForEach-Object { ($_.Line -split ":")[0].Trim() })

Write-Host ""
Write-Host "Chaves no secret agora:" -ForegroundColor Green
$nomes | ForEach-Object { Write-Host "  $_" }

if ($nomes -notcontains $Campo) {
    Write-Host ""
    Write-Host "O campo $Campo nao apareceu. Restaure com git checkout." -ForegroundColor Red
    exit 1
}

if ($Mostrar) {
    Write-Host ""
    Write-Host "Valor de ${Campo}:" -ForegroundColor Cyan
    Write-Host "  $Valor"
    Write-Host "Entregue por canal fora de banda e nao deixe no historico do shell." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "OK. Confira o diff e faca commit no repo gitops." -ForegroundColor Green
