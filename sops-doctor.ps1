# Diagnostica, em uma passada, por que o sops nao decifra os secrets deste repo.
#
# Existe porque o sintoma e sempre o mesmo ("Failed to get the data key") e a
# causa quase nunca e o arquivo cifrado. Sem este script a investigacao vira
# uma tarde; com ele sao cinco segundos.
#
# NUNCA imprime chave privada. `age-keygen -y` deriva so a parte publica.

$ErrorActionPreference = "Continue"

$repo = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host ""
Write-Host "=== sops doctor ===" -ForegroundColor Cyan
Write-Host ""

# ------------------------------------------------------------ 0. ferramentas
$faltando = @()
foreach ($exe in @("sops", "age-keygen", "kubectl")) {
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { $faltando += $exe }
}
if ($faltando) {
    Write-Host "FALTA instalar: $($faltando -join ', ')" -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------ 1. a variavel
# Primeiro de tudo: uma SOPS_AGE_KEY_FILE sobrando aponta o sops para um
# arquivo que pode nem existir, e a partir dai todo o resto do diagnostico
# mente. Esta e a armadilha numero um.
if ($env:SOPS_AGE_KEY_FILE) {
    Write-Host "ATENCAO: SOPS_AGE_KEY_FILE esta setada:" -ForegroundColor Yellow
    Write-Host "  $($env:SOPS_AGE_KEY_FILE)" -ForegroundColor Yellow
    if (-not (Test-Path $env:SOPS_AGE_KEY_FILE)) {
        Write-Host "  ...e o arquivo NAO existe. E provavelmente sua causa raiz." -ForegroundColor Red
    }
    Write-Host "  Para descartar: Remove-Item Env:\SOPS_AGE_KEY_FILE" -ForegroundColor Yellow
    Write-Host ""
}

# ------------------------------------------------------------ 2. os arquivos
# No Windows o sops usa os.UserConfigDir() = %APPDATA%. O ~/.config/sops/age
# da documentacao (escrita para Linux) e lido apenas se voce apontar a
# variavel para la. Ter chave so no segundo e o classico "instalei e nao
# funcionou".
$candidatos = [ordered]@{
    "%APPDATA% (o que o sops LE no Windows)" = Join-Path $env:APPDATA "sops\age\keys.txt"
    "~/.config (estilo Linux, so informativo)" = Join-Path $env:USERPROFILE ".config\sops\age\keys.txt"
}

$identidades = @()

Write-Host "Arquivos de chave:" -ForegroundColor Cyan
foreach ($rotulo in $candidatos.Keys) {
    $caminho = $candidatos[$rotulo]
    if (Test-Path $caminho) {
        $pubs = @(age-keygen -y $caminho 2>$null)
        $info = Get-Item $caminho
        Write-Host "  [ok]    $rotulo" -ForegroundColor Green
        # Tamanho e mtime aparecem porque "rodei o instalador" e "o instalador
        # gravou" nao sao a mesma coisa. Um arquivo com data antiga e o mesmo
        # numero de bytes de antes diz, sozinho, que a escrita nao aconteceu.
        Write-Host "          $caminho"
        Write-Host "          $($info.Length) bytes, modificado em $($info.LastWriteTime)" -ForegroundColor DarkGray
        foreach ($p in $pubs) {
            Write-Host "          -> $p" -ForegroundColor DarkGray
            if ($rotulo -like "*APPDATA*") { $identidades += $p }
        }
        # CR no fim da linha faz o parser do age ignorar a identidade em
        # silencio: o arquivo "tem" a chave e mesmo assim nada decifra.
        $bruto = [IO.File]::ReadAllText($caminho)
        if ($bruto -match "`r`n") {
            Write-Host "          AVISO: arquivo com CRLF. O age pode ignorar a identidade." -ForegroundColor Yellow
            Write-Host "          Corrija com o instalar-chave-age.ps1 (ele normaliza para LF)." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [--]    $rotulo" -ForegroundColor DarkGray
        Write-Host "          $caminho (ausente)"
    }
}

# ------------------------------------------------------------ 3. o recipient
$sopsYaml = Join-Path $repo ".sops.yaml"
$recipients = @(Select-String -Path $sopsYaml -Pattern 'age1[a-z0-9]+' -AllMatches |
    ForEach-Object { $_.Matches } | ForEach-Object { $_.Value } | Select-Object -Unique)

Write-Host ""
Write-Host "Recipients exigidos pelo .sops.yaml:" -ForegroundColor Cyan
foreach ($r in $recipients) { Write-Host "  $r" }

# ------------------------------------------------------------ 4. o veredito
Write-Host ""
$cobertos = @($recipients | Where-Object { $identidades -contains $_ })
$orfaos   = @($recipients | Where-Object { $identidades -notcontains $_ })

if ($orfaos.Count -eq 0) {
    # Casar identidade com recipient e inferencia, nao prova. Ja aconteceu de
    # esta conta fechar e o sops mesmo assim nao decifrar -- um "verde" que
    # custa a tarde inteira de quem confia nele. Entao o veredito final e o
    # unico teste que vale: tentar decifrar um arquivo de verdade.
    $amostra = Get-ChildItem -Path (Join-Path $repo "apps") -Recurse -Filter "secret.enc.yaml" -File |
        Select-Object -First 1
    if ($amostra) {
        & { $ErrorActionPreference = 'Continue'; sops decrypt $amostra.FullName 2>&1 } | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "VEREDITO: decifra de verdade (testado em $($amostra.Name))." -ForegroundColor Green
        } else {
            Write-Host "VEREDITO: as identidades batem, mas o sops NAO decifra." -ForegroundColor Red
            Write-Host "Voce tem uma chave publica que confere e ainda assim falha." -ForegroundColor Red
            Write-Host "Causas tipicas, nesta ordem:" -ForegroundColor Yellow
            Write-Host "  1. CRLF no keys.txt: o age ignora a identidade em silencio." -ForegroundColor Yellow
            Write-Host "  2. SOPS_AGE_KEY_FILE apontando para outro arquivo (veja acima)." -ForegroundColor Yellow
            Write-Host "  3. O arquivo lido aqui nao e o que o sops le: confira o mtime" -ForegroundColor Yellow
            Write-Host "     acima -- se for antigo, o instalador nao gravou onde voce pensa." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Saida crua do sops:" -ForegroundColor DarkGray
            & { $ErrorActionPreference = 'Continue'; sops decrypt $amostra.FullName 2>&1 } |
                Select-Object -First 12 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        }
    } else {
        Write-Host "VEREDITO: identidades batem, mas nao achei secret para testar." -ForegroundColor Yellow
    }
} else {
    Write-Host "VEREDITO: falta a chave privada de:" -ForegroundColor Red
    foreach ($o in $orfaos) { Write-Host "  $o" -ForegroundColor Red }
    Write-Host ""
    Write-Host "Correcao (le a chave do cluster e MESCLA, sem sobrescrever):" -ForegroundColor Yellow
    Write-Host "  .\instalar-chave-age.ps1" -ForegroundColor White
    Write-Host ""
    Write-Host "NAO rode 'age-keygen -o keys.txt' para tentar consertar." -ForegroundColor Red
    Write-Host "Esse comando SOBRESCREVE o arquivo e apaga a identidade que"  -ForegroundColor Red
    Write-Host "funcionava. E como este repo perdeu a chave: as duas identidades" -ForegroundColor Red
    Write-Host "locais sao de 23 e 25/jul, geradas por engano, e nenhuma delas" -ForegroundColor Red
    Write-Host "e a que cifra os secrets." -ForegroundColor Red
}

# ------------------------------------------------------------ 5. o cluster
Write-Host ""
Write-Host "Copia de seguranca no cluster:" -ForegroundColor Cyan
$nomes = kubectl get secret sops-age -n flux-system -o "go-template={{range `$k,`$v := .data}}{{`$k}} {{end}}" 2>$null
if ($LASTEXITCODE -eq 0 -and $nomes) {
    Write-Host "  flux-system/sops-age presente (chaves: $($nomes.Trim()))" -ForegroundColor Green
} else {
    Write-Host "  NAO consegui ler flux-system/sops-age." -ForegroundColor Red
    Write-Host "  Se a chave nao estiver em mais nenhum lugar, os secrets deste" -ForegroundColor Red
    Write-Host "  repo sao irrecuperaveis. Veja o aviso de recipient unico abaixo." -ForegroundColor Red
}

# ------------------------------------------------------------ 6. durabilidade
if ($recipients.Count -le 1) {
    Write-Host ""
    Write-Host "RISCO ESTRUTURAL: ha um unico recipient." -ForegroundColor Yellow
    Write-Host "Toda a criptografia deste repo depende de uma chave privada que" -ForegroundColor Yellow
    Write-Host "hoje so existe dentro do cluster. Perdeu o cluster sem backup," -ForegroundColor Yellow
    Write-Host "perdeu todo secret.enc.yaml, para sempre." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Mitigacao (depois que o doctor passar):" -ForegroundColor Yellow
    Write-Host "  .\sops-adicionar-recipient.ps1 -Recipient <sua-chave-publica-local>" -ForegroundColor White
}

Write-Host ""
