# Recria o secret cifrado do Astra qa.
#
# Cada campo e perguntado mostrando se ja existe valor. Enter vazio MANTEM o que
# esta la; so digite quando quiser trocar.
#
# O texto puro so existe num arquivo temporario fora do repositorio, apagado no
# finally - mesmo se algo falhar no meio.

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------- chave age
# Procura em vez de assumir: o sops no Windows le %APPDATA%, mas o arquivo
# costuma acabar em ~/.config por causa da documentacao escrita para Linux.
Remove-Item Env:\SOPS_AGE_KEY_FILE -ErrorAction SilentlyContinue

$keyCandidates = @(
    "$env:APPDATA/sops/age/keys.txt",
    "$env:USERPROFILE/AppData/Roaming/sops/age/keys.txt",
    "$env:USERPROFILE/.config/sops/age/keys.txt"
)
$keyFile = $keyCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $keyFile) {
    Write-Host "Chave age nao encontrada. Procurei em:" -ForegroundColor Red
    $keyCandidates | ForEach-Object { Write-Host "  $_" }
    Write-Host "Rode antes o instalar-chave-age.ps1." -ForegroundColor Red
    exit 1
}
$env:SOPS_AGE_KEY_FILE = $keyFile
Write-Host "Chave age: $keyFile"

# ---------------------------------------------------------------- caminhos
$repo     = "C:\dev\social-midia\k8s-agents\gitops"
$target   = Join-Path $repo "apps\astra\overlays\qa\secret.enc.yaml"
$sopsYaml = Join-Path $repo ".sops.yaml"
$tmp      = Join-Path $env:TEMP ("astra-secret-" + [guid]::NewGuid().ToString() + ".yaml")

$recipient = (Select-String -Path $sopsYaml -Pattern "age:\s*(age1[a-z0-9]+)" |
    Select-Object -First 1).Matches[0].Groups[1].Value
if (-not $recipient) {
    Write-Host "Nao achei o recipient age no .sops.yaml" -ForegroundColor Red
    exit 1
}
Write-Host "Recipient: $recipient"

# ---------------------------------------------------------------- valores atuais
$atual = @{}

if (Test-Path $target) {
    Write-Host ""
    Write-Host "Lendo o secret atual..."
    $plain = sops decrypt $target 2>&1

    if ($LASTEXITCODE -eq 0) {
        foreach ($line in $plain) {
            if ("$line" -match '^\s+([A-Z][A-Z0-9_]*):\s*(.*)$') {
                $atual[$Matches[1]] = $Matches[2].Trim().Trim('"').Trim("'")
            }
        }
        Write-Host "Encontrados: $($atual.Keys -join ', ')" -ForegroundColor Green
    } else {
        # Mostrado, nao engolido: e este erro que explica por que o script
        # passaria a pedir tudo do zero.
        Write-Host "O secret atual NAO decifrou. Erro do sops:" -ForegroundColor Red
        $plain | ForEach-Object { Write-Host "  $_" }
        Write-Host ""
        Write-Host "Sem conseguir ler, nao da para preservar os valores." -ForegroundColor Red
        Write-Host "Rode o instalar-chave-age.ps1 e tente de novo." -ForegroundColor Red
        exit 1
    }
}

# ---------------------------------------------------------------- perguntar
$campos = @("DB_URL", "DB_USER", "DB_PASSWORD", "STORAGE_ACCESS_KEY", "STORAGE_SECRET_KEY")
$novo = @{}

Write-Host ""
Write-Host "Enter vazio mantem o valor atual." -ForegroundColor Cyan
Write-Host ""

foreach ($campo in $campos) {
    $tem = $atual.ContainsKey($campo) -and -not [string]::IsNullOrWhiteSpace($atual[$campo])

    if ($tem) {
        # Nunca imprime segredo. DB_URL nao e segredo e aparece inteira; para o
        # resto mostra so o tamanho, o suficiente para reconhecer.
        if ($campo -eq "DB_URL") {
            $dica = $atual[$campo]
        } else {
            $dica = "definido, $($atual[$campo].Length) caracteres"
        }
        $resposta = Read-Host "$campo [$dica]"
    } else {
        $resposta = Read-Host "$campo (vazio hoje, precisa preencher)"
    }

    if ([string]::IsNullOrWhiteSpace($resposta)) {
        if ($tem) {
            $novo[$campo] = $atual[$campo]
        } else {
            Write-Host "$campo nao tem valor atual e ficou vazio. Nada foi alterado." -ForegroundColor Red
            exit 1
        }
    } else {
        $novo[$campo] = $resposta.Trim()
    }
}

# ---------------------------------------------------------------- escrever
$mudou = $campos | Where-Object { $atual[$_] -ne $novo[$_] }
Write-Host ""
if ($mudou) {
    Write-Host "Vao mudar: $($mudou -join ', ')" -ForegroundColor Yellow
} else {
    Write-Host "Nenhum valor mudou. O arquivo sera reescrito igual." -ForegroundColor Yellow
}

try {
    $lines = @(
        "apiVersion: v1",
        "kind: Secret",
        "metadata:",
        "    name: astra-secret",
        "type: Opaque",
        "stringData:"
    )

    # Aspas simples de YAML: literal, sem interpretar barra invertida nem cifrao.
    # Uma aspa simples dentro do valor vira duas, que e o escape do YAML.
    foreach ($campo in $campos) {
        $valor = $novo[$campo].Replace("'", "''")
        $lines += "    ${campo}: '$valor'"
    }

    Set-Content -Path $tmp -Value $lines -Encoding ascii

    $cifrado = sops encrypt --age $recipient --encrypted-regex "^(data|stringData)$" $tmp
    if ($LASTEXITCODE -ne 0) {
        Write-Host "sops encrypt falhou. O arquivo antigo NAO foi tocado." -ForegroundColor Red
        exit 1
    }

    Set-Content -Path $target -Value $cifrado -Encoding ascii
}
finally {
    if (Test-Path $tmp) { Remove-Item -Force $tmp }
    Remove-Variable atual, novo, lines, valor, cifrado, resposta -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- conferir
$names = sops decrypt $target |
    Select-String -Pattern "^\s+[A-Z][A-Z0-9_]*:" |
    ForEach-Object { ($_.Line -split ":")[0].Trim() }

Write-Host ""
if ($LASTEXITCODE -ne 0) {
    Write-Host "O arquivo novo nao decifra. Restaure com:" -ForegroundColor Red
    Write-Host "  git -C `"$repo`" checkout -- apps/astra/overlays/qa/secret.enc.yaml" -ForegroundColor Red
    exit 1
}

Write-Host "Chaves no secret:" -ForegroundColor Green
$names | ForEach-Object { Write-Host "  $_" }

$faltando = $campos | Where-Object { $names -notcontains $_ }
if ($faltando) {
    Write-Host ""
    Write-Host "Faltou: $($faltando -join ', '). Restaure com git checkout." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "OK. Confira o diff e faca commit no repo gitops." -ForegroundColor Green
