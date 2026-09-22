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
    # Cria o arquivo do zero, com este nome de Secret. So e aceito quando
    # -Arquivo ainda nao existe; num arquivo existente seria uma forma silenciosa
    # de renomear o Secret e orfanar o que estava aplicado no cluster.
    [string] $NovoSecret,
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
$criando = -not (Test-Path $Arquivo)

if ($criando -and -not $NovoSecret) {
    Write-Host "Arquivo nao encontrado: $Arquivo" -ForegroundColor Red
    Write-Host "Para criar um secret novo, passe -NovoSecret <nome-do-Secret>." -ForegroundColor Yellow
    exit 1
}
if (-not $criando -and $NovoSecret) {
    Write-Host "-NovoSecret so vale para arquivo inexistente. $Arquivo ja existe." -ForegroundColor Red
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
if (-not $criando) { Write-Host "Decifrando o secret atual..." }

# O 2>&1 num exe nativo faz o PS 5.1 empacotar cada linha de stderr num
# ErrorRecord; com ErrorActionPreference=Stop isso vira excecao terminante e
# mata o script ANTES da mensagem de erro util. Escopar o Continue so nessa
# chamada preserva o diagnostico.
#
# Preserva a ordem de leitura: o diff do git fica legivel e a revisao, honesta.
$campos = [ordered]@{}
$nomeSecret = $null
$tipoSecret = "Opaque"

if ($criando) {
    $nomeSecret = $NovoSecret
    Write-Host "Arquivo novo. Secret: $nomeSecret" -ForegroundColor Green
} else {
    $plain = & { $ErrorActionPreference = 'Continue'; sops decrypt $Arquivo 2>&1 }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "NAO decifrou. Erro do sops:" -ForegroundColor Red
        $plain | ForEach-Object { Write-Host "  $_" }
        Write-Host ""
        Write-Host "Rode o sops-doctor.ps1 -- ele diz exatamente qual chave falta." -ForegroundColor Red
        exit 1
    }

    foreach ($line in $plain) {
        $t = "$line"
        if ($t -match '^\s{2,}name:\s*(\S+)\s*$' -and -not $nomeSecret) { $nomeSecret = $Matches[1]; continue }
        if ($t -match '^type:\s*(\S+)\s*$') { $tipoSecret = $Matches[1]; continue }
        # Minusculas e hifen entram porque nem toda chave de Secret e uma env
        # var: o chart do Postgres espera `postgres-password` e `password`.
        # Exige valor (.+) para nao capturar as chaves de estrutura do YAML.
        if ($t -match '^\s+([A-Za-z][A-Za-z0-9_.-]*):\s*(.+)$') {
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
}

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
$stamp  = [guid]::NewGuid().ToString()
$tmp    = Join-Path $env:TEMP ("sops-campo-$stamp.yaml")
$tmpCfg = Join-Path $env:TEMP ("sops-campo-$stamp.sops.yaml")

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

    # O sops procura creation_rules para o caminho do arquivo que esta cifrando
    # -- e o temporario vive no %TEMP%, que nao casa com nenhum path_regex do
    # .sops.yaml do repo. Resultado: "error loading config: no matching
    # creation rules found", mesmo passando --age explicito. Passar --age NAO
    # dispensa a checagem de regras.
    #
    # Entao damos ao sops um config proprio, ao lado do temporario, com uma
    # regra que casa com ele e carrega os mesmos recipients do repo. Nada de
    # escrever texto puro dentro do repositorio so para o path_regex bater.
    #
    # A descoberta do .sops.yaml e pelo CWD, entao o erro so aparece quando se
    # roda de dentro do repo -- de outro diretorio o mesmo comando passa, o que
    # torna a falha confusamente intermitente.
    #
    # Atencao a posicao: --config e flag GLOBAL do sops e tem de vir ANTES do
    # subcomando. `sops encrypt --config X` falha com "flag provided but not
    # defined: -config"; o certo e `sops --config X encrypt`.
    $cfgLines = @(
        "creation_rules:",
        "  - path_regex: .*",
        "    encrypted_regex: ^(data|stringData)$",
        "    age: $($recipients -join ',')"
    )
    Set-Content -Path $tmpCfg -Value $cfgLines -Encoding ascii

    $cifrado = & { $ErrorActionPreference = 'Continue'
                   sops --config $tmpCfg encrypt $tmp 2>&1 }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "sops encrypt falhou. O arquivo original NAO foi tocado." -ForegroundColor Red
        $cifrado | Select-Object -First 8 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        exit 1
    }

    Set-Content -Path $Arquivo -Value $cifrado -Encoding ascii
}
finally {
    # O texto puro e o config saem juntos, aconteca o que acontecer.
    if (Test-Path $tmp)    { Remove-Item -Force $tmp }
    if (Test-Path $tmpCfg) { Remove-Item -Force $tmpCfg }
    Remove-Variable campos, lines, v, cifrado, cfgLines -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------- conferir
# Le de volta do disco: a unica prova que vale e o arquivo que vai pro commit.
$depois = & { $ErrorActionPreference = 'Continue'; sops decrypt $Arquivo 2>&1 }
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    if ($criando) {
        # Nao existia antes desta execucao, entao nao ha versao a restaurar --
        # `git checkout` aqui so produziria um "pathspec did not match".
        Write-Host "O arquivo gerado NAO decifra. Ele e novo: apague e tente de novo." -ForegroundColor Red
        Write-Host "  Remove-Item `"$Arquivo`"" -ForegroundColor Red
    } else {
        Write-Host "O arquivo novo NAO decifra. Restaure com:" -ForegroundColor Red
        Write-Host "  git -C `"$repo`" checkout -- $Arquivo" -ForegroundColor Red
    }
    exit 1
}

$nomes = @($depois | Select-String -Pattern "^\s+[A-Za-z][A-Za-z0-9_.-]*:" |
    ForEach-Object { ($_.Line -split ":")[0].Trim() } |
    Where-Object { $_ -ne "name" })

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
