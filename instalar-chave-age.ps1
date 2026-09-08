# Instala a chave age do cluster no lugar onde o sops do Windows procura.
#
# O sops usa os.UserConfigDir(), que no Windows e %APPDATA% - nao o
# ~/.config/sops/age/ da documentacao escrita para Linux. Se a chave estiver so
# no ~/.config, o sops nunca a le e o erro parece ser do arquivo cifrado.

$ErrorActionPreference = "Stop"

# Uma variavel sobrando aqui manda o sops procurar no lugar errado e mascara
# tudo o que vem depois.
Remove-Item Env:\SOPS_AGE_KEY_FILE -ErrorAction SilentlyContinue

$dir  = Join-Path $env:APPDATA "sops\age"
$file = Join-Path $dir "keys.txt"

New-Item -ItemType Directory -Force -Path $dir | Out-Null

Write-Host "Destino: $file"

# ---------------------------------------------------------------- do cluster
Write-Host "Lendo a chave do secret sops-age no cluster..."
$b64 = kubectl -n flux-system get secret sops-age -o jsonpath='{.data.age\.agekey}'

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($b64)) {
    Write-Host "Nao consegui ler o secret sops-age. O kubectl esta apontando para o cluster certo?" -ForegroundColor Red
    exit 1
}

$clusterKey = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))

# LF, sempre. O parser do age rejeita a linha AGE-SECRET-KEY se ela terminar
# em CR, e o sintoma e uma identidade silenciosamente ignorada.
$clusterKey = $clusterKey -replace "`r`n", "`n"

# ---------------------------------------------------------------- juntar
$existing = ""
if (Test-Path $file) {
    $existing = ([IO.File]::ReadAllText($file)) -replace "`r`n", "`n"
}

# Tambem aproveita o que estiver no caminho estilo Linux, se houver: o sops nao
# le de la, mas pode haver chave de outro projeto que voce ainda usa.
$linuxPath = Join-Path $env:USERPROFILE ".config\sops\age\keys.txt"
if ((Test-Path $linuxPath) -and ($linuxPath -ne $file)) {
    $fromLinux = ([IO.File]::ReadAllText($linuxPath)) -replace "`r`n", "`n"
    foreach ($block in ($fromLinux -split "(?=# created:)")) {
        if ($block.Trim() -and -not $existing.Contains($block.Trim())) {
            $existing = ($existing.TrimEnd("`n") + "`n`n" + $block.Trim() + "`n").TrimStart("`n")
        }
    }
}

if (-not $existing.Contains($clusterKey.Trim())) {
    $existing = ($existing.TrimEnd("`n") + "`n`n" + $clusterKey.Trim() + "`n").TrimStart("`n")
}

[IO.File]::WriteAllText($file, $existing)

# ---------------------------------------------------------------- conferir
Write-Host ""
Write-Host "Identidades no arquivo:" -ForegroundColor Green
age-keygen -y $file | ForEach-Object { Write-Host "  $_" }

$alvo = "C:\dev\social-midia\k8s-agents\gitops\apps\astra\overlays\qa\secret.enc.yaml"
if (Test-Path $alvo) {
    sops decrypt $alvo | Out-Null
    Write-Host ""
    if ($LASTEXITCODE -eq 0) {
        Write-Host "OK: o sops decifra o secret do Astra." -ForegroundColor Green
        Write-Host "Agora rode o recriar-secret.ps1." -ForegroundColor Green
    } else {
        Write-Host "Ainda nao decifra. Me mande a saida de: age-keygen -y `"$file`"" -ForegroundColor Red
        exit 1
    }
}
