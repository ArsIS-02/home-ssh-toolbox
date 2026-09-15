@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Command "$m='#__PWSH'+'_BEGIN__';$c=Get-Content -Raw -Encoding UTF8 '%~f0';$i=$c.IndexOf($m);iex $c.Substring($i+$m.Length)"
exit /b
#__PWSH_BEGIN__
#Requires -Version 5.1

# ============================================================
#  Интерактивный SSH-комбайн для Windows
# ============================================================

# === НАСТРОЙКИ И ПУТИ ===
$SshDir         = Join-Path $env:USERPROFILE ".ssh"
$RegistryFile   = Join-Path $SshDir "deploy_keys.log"
$KnownHostsFile = Join-Path $SshDir "known_hosts"
$SshTimeout     = 5

$Global:PubKey      = $null
$Global:AlreadyList = @()
$Global:AddedList   = @()
$Global:FailedList  = @()
$Global:SkippedList = @()

# === ВЫВОД ===
function Write-Header ($text) {
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "  $text" -ForegroundColor White
    Write-Host "==========================================" -ForegroundColor Cyan
}
function Write-Ok   ($msg) { Write-Host "  [+] $msg" -ForegroundColor Green }
function Write-Warn ($msg) { Write-Host "  [!] $msg" -ForegroundColor Yellow }
function Write-Err  ($msg) { Write-Host "  [-] $msg" -ForegroundColor Red }
function Write-Info ($msg) { Write-Host "  [i] $msg" -ForegroundColor Cyan }
function Write-Dim  ($msg) { Write-Host "     $msg" -ForegroundColor DarkGray }

function Pause-Continue {
    Write-Host ""
    Read-Host "Нажмите Enter, чтобы продолжить..."
}

# === УТИЛИТЫ ===
function Get-KeyFingerprint ($pubPath) {
    if (-not (Test-Path $pubPath)) { return "" }
    $line = ssh-keygen -lf $pubPath 2>$null
    if (-not $line) { return "" }
    return (($line -split '\s+')[1])
}
function Get-KeyType ($pubPath) {
    if (-not (Test-Path $pubPath)) { return "" }
    $line = ssh-keygen -lf $pubPath 2>$null
    if (-not $line) { return "" }
    return (($line -split '\s+')[3].Trim('(', ')'))
}
function Get-KeyBits ($pubPath) {
    if (-not (Test-Path $pubPath)) { return 0 }
    $line = ssh-keygen -lf $pubPath 2>$null
    if (-not $line) { return 0 }
    $bits = ($line -split '\s+')[0]
    return [int]$bits
}
function Test-KeyUsedInRegistry ($pubPath) {
    $fp = Get-KeyFingerprint $pubPath
    if (-not $fp -or -not (Test-Path $RegistryFile)) { return $false }
    return [bool](Select-String -Path $RegistryFile -Pattern ([regex]::Escape("fp=$fp")) -Quiet)
}
function Test-KeyWorks ($user, $hostName, $privKeyPath) {
    ssh -i $privKeyPath -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=$SshTimeout -o PreferredAuthentications=publickey "$user@$hostName" "true" 2>$null
    return $LASTEXITCODE -eq 0
}
function Get-RegistryUsersForHost ($hostName) {
    if (-not (Test-Path $RegistryFile)) { return @() }
    $pattern = "^" + [regex]::Escape($hostName) + "\s+(\S+)\s+added"
    $users = Get-Content $RegistryFile | Where-Object { $_ -match $pattern } | ForEach-Object { ($_ -split '\s+')[1] } | Sort-Object -Unique
    return @($users)
}

# === ГЕНЕРАЦИЯ КЛЮЧА ===
function New-SshKey {
    Write-Header "Генерация SSH-ключа"
    Write-Host "  1) ed25519 (recommended)"
    Write-Host "  2) rsa 4096"
    $choice = Read-Host "Ваш выбор [1]"
    if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "1" }

    $keyType = "ed25519"; $keyFile = Join-Path $SshDir "id_ed25519"; $extraArgs = @()
    if ($choice -eq "2") {
        $keyType = "rsa"; $keyFile = Join-Path $SshDir "id_rsa"; $extraArgs = @("-b", "4096")
    }

    if (Test-Path $keyFile) {
        Write-Warn "Ключ уже существует: $keyFile"
        $overwrite = Read-Host "Перезаписать (старый сохранится в .bak)? [y/N]"
        if ($overwrite -notmatch "^[Yy]$") {
            $Global:PubKey = "$keyFile.pub"
            Write-Info "Отменено."
            return
        }
        $ts = Get-Date -Format "yyyyMMdd_HHmmss"
        Copy-Item $keyFile "${keyFile}.bak.$ts" -Force
        if (Test-Path "$keyFile.pub") { Copy-Item "$keyFile.pub" "${keyFile}.pub.bak.$ts" -Force }
        Write-Dim "Старый ключ сохранён как ${keyFile}.bak.$ts"
    }

    if (-not (Test-Path $SshDir)) {
        New-Item -ItemType Directory -Path $SshDir -Force | Out-Null
    }

    $default = "$env:USERNAME@$env:COMPUTERNAME"
    $comment = Read-Host "Комментарий к ключу [$default]"
    if ([string]::IsNullOrWhiteSpace($comment)) { $comment = $default }

    Write-Dim "Пароль на ключ (Enter — без пароля)"
    $pass = Read-Host -AsSecureString "  Passphrase"
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass)
    $plainPass = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)

    $kgArgs = @("-t", $keyType) + $extraArgs + @("-C", $comment, "-f", $keyFile, "-N", $plainPass)
    ssh-keygen @kgArgs

    if ($LASTEXITCODE -eq 0 -and (Test-Path "$keyFile.pub")) {
        Write-Ok "Ключ успешно создан."
        Write-Dim "Приватный: $keyFile"
        Write-Dim "Публичный: $keyFile.pub"
        $Global:PubKey = "$keyFile.pub"
    } else {
        Write-Err "Ошибка генерации ключа."
    }
}

# === РАССЫЛКА КЛЮЧА ===
function Copy-SshKeyToHost ($user, $hostName) {
    Write-Info "Копирование ключа на $user@$hostName..."

    $pubKeyContent = (Get-Content $Global:PubKey -Raw).Trim()

    $template = @'
mkdir -p ~/.ssh
chmod 700 ~/.ssh
grep -qxF 'KEYPLACEHOLDER' ~/.ssh/authorized_keys 2>/dev/null || echo 'KEYPLACEHOLDER' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
echo OK
'@
    $remoteCmd = $template.Replace('KEYPLACEHOLDER', $pubKeyContent)

    $output = ssh -o StrictHostKeyChecking=no -o ConnectTimeout=$SshTimeout "$user@$hostName" $remoteCmd 2>&1

    if ($output -match "OK") {
        return $true
    } else {
        Write-Err "Не удалось скопировать ключ. Проверьте пароль и доступность хоста."
        return $false
    }
}

# === ОЧИСТКА KNOWN_HOSTS ===
function Remove-StaleKnownHosts {
    param([switch]$DryRun)

    Write-Header "Очистка known_hosts"
    if (-not (Test-Path $KnownHostsFile)) {
        Write-Warn "Файл не найден: $KnownHostsFile"
        return
    }

    $lines = @(Get-Content $KnownHostsFile)
    $newLines = New-Object System.Collections.ArrayList
    $removed = 0
    $kept = 0
    $hashed = 0

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
            [void]$newLines.Add($line); continue
        }
        if ($line.StartsWith("|")) {
            [void]$newLines.Add($line); $kept++; $hashed++; continue
        }

        $field = ($line -split '\s+')[0]
        $hostPart = $field
        $port = 22
        if ($field -match '^\[(.+)\]:(\d+)$') {
            $hostPart = $Matches[1]
            $port = [int]$Matches[2]
        }

        $scanResult = ssh-keyscan -p $port -T $SshTimeout -t rsa,ecdsa,ed25519 $hostPart 2>$null
        if ($LASTEXITCODE -eq 0 -and $scanResult) {
            [void]$newLines.Add($line); $kept++
            Write-Dim "= ${hostPart}:${port} -- up"
        } else {
            $removed++
            if ($DryRun) { Write-Err "- ${hostPart}:${port} -- will be removed (DRY-RUN)" }
            else         { Write-Err "- ${hostPart}:${port} -- removed" }
        }
    }

    Write-Host ""
    Write-Info "Всего записей: $($lines.Count)"
    Write-Ok   "Оставлено: $kept"
    if ($hashed -gt 0) { Write-Dim "  из них хешированных: $hashed (пропущены)" }
    Write-Err  "Удалено: $removed"

    if ($DryRun -or $removed -eq 0) {
        if ($DryRun) { Write-Info "Режим DRY-RUN: файл не изменён." }
        if (-not $DryRun) { Write-Ok "Нечего удалять. Файл не изменён." }
        return
    }

    $backup = "$KnownHostsFile.bak.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Copy-Item $KnownHostsFile $backup -Force
    Write-Dim "Резервная копия: $backup"

    $newLines | Set-Content $KnownHostsFile -Encoding ASCII
    Write-Ok "Файл обновлён."
}

# === УДАЛЕНИЕ КОНКРЕТНОГО ХОСТА ИЗ KNOWN_HOSTS ===
function Remove-KnownHostEntry {
    Write-Header "Удаление конкретного хоста из known_hosts"

    if (-not (Test-Path $KnownHostsFile)) {
        Write-Warn "Файл не найден: $KnownHostsFile"
        return
    }

    Write-Dim "Введите имя хоста, IP или [host]:port."
    Write-Dim "Пустая строка - отмена."
    $h = Read-Host "Хост"

    if ([string]::IsNullOrWhiteSpace($h)) { return }

    $matches = @(Get-Content $KnownHostsFile | Where-Object {
        -not $_.StartsWith("#") -and
        -not $_.StartsWith("|") -and
        (($_ -split '\s+')[0] -split ',') -contains $h
    })

    if ($matches.Count -eq 0) {
        Write-Info "Прямых совпадений в файле не найдено (возможно, записи хешированы)."
    } else {
        Write-Host "Найдено записей: $($matches.Count)"
        foreach ($m in $matches) {
            $field = ($m -split '\s+')[0]
            $keyType = ($m -split '\s+')[1]
            Write-Host "  $field  ($keyType)"
        }
    }

    $backup = "$KnownHostsFile.bak.$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    Copy-Item $KnownHostsFile $backup -Force
    Write-Dim "Резервная копия: $backup"

    $output = ssh-keygen -R $h -f $KnownHostsFile 2>&1

    if ($output -match "updated" -or $output -match "found:\d+") {
        Write-Ok "Запись для '$h' удалена из $KnownHostsFile."
    } elseif ($output -match "not found") {
        Write-Warn "Запись для '$h' не найдена."
        Write-Dim "Бэкап можно удалить вручную: $backup"
    } else {
        Write-Err "Не удалось удалить запись."
        Write-Dim $output
    }
}

# === АУДИТ КЛЮЧЕЙ ===
function Invoke-KeyAudit {
    Write-Header "Аудит SSH-ключей в ~/.ssh/"
    $keys = @(Get-ChildItem -Path $SshDir -Filter "*.pub" -File -ErrorAction SilentlyContinue)

    if ($keys.Count -eq 0) {
        Write-Warn "Публичных ключей не найдено."
        return
    }

    foreach ($key in $keys) {
        Write-Host ""
        Write-Host "--- $($key.FullName) ---" -ForegroundColor Cyan
        $type = Get-KeyType $key.FullName
        $bits = Get-KeyBits $key.FullName
        $fp   = Get-KeyFingerprint $key.FullName
        $priv = $key.FullName -replace '\.pub$', ''

        Write-Host "  Тип:         $type"
        Write-Host "  Длина:       $bits бит"
        Write-Host "  Отпечаток:   $fp"
        if (Test-Path $priv) { Write-Host "  Приватная:   есть" }
        else { Write-Host "  Приватная:   НЕТ" -ForegroundColor Red }

        if (-not (Test-Path $priv)) {
            Write-Err "Приватная часть отсутствует - использовать ключ нельзя."
        }

        if (Test-KeyUsedInRegistry $key.FullName) {
            Write-Ok "Ключ используется (найден в реестре)."
        } else {
            Write-Info "Ключ пока нигде не упоминается."
        }

        switch ($type) {
            "ED25519" { Write-Ok "ED25519 (256 бит) - современный и безопасный." }
            "RSA" {
                if ($bits -lt 2048) { Write-Err "RSA $bits бит - небезопасно (нужно >= 2048)." }
                elseif ($bits -lt 3072) { Write-Warn "RSA $bits бит - допустимо, но рекомендуется >= 3072." }
                else { Write-Ok "RSA $bits бит - безопасно." }
            }
            "ECDSA" { Write-Info "ECDSA $bits бит - допустимо." }
            default { Write-Info "Тип: $type, длина: $bits бит." }
        }
    }
    Pause-Continue
}

# === ОБРАБОТКА ОДНОГО ХОСТА ===
function Invoke-ProcessHost ($hostName) {
    Write-Host ""
    Write-Host "----------------------------------------" -ForegroundColor Cyan
    Write-Host "  Хост: $hostName" -ForegroundColor Cyan
    Write-Host "----------------------------------------" -ForegroundColor Cyan

    $prevUsers = Get-RegistryUsersForHost $hostName
    if ($prevUsers.Count -gt 0) {
        Write-Info "В реестре есть записи: ключ уже разложен под:"
        foreach ($u in $prevUsers) { Write-Dim "- $u" }
    }

    $user = Read-Host "  Пользователь для входа (skip - пропустить, q - выход)"
    if ($user -eq "q" -or $user -eq "Q") {
        Show-Report
        exit
    }
    if ($user -eq "skip" -or $user -eq "SKIP") {
        $Global:SkippedList += "  - $hostName"
        return
    }
    if ([string]::IsNullOrWhiteSpace($user)) { return }

    $privKey = $Global:PubKey -replace '\.pub$', ''
    if (Test-KeyWorks $user $hostName $privKey) {
        Write-Ok "Ключ УЖЕ работает для $user@$hostName. Копирование не требуется."
        $Global:AlreadyList += "  - $hostName (пользователь: $user)"
        $fp = Get-KeyFingerprint $Global:PubKey
        "$hostName $user added $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') fp=$fp" | Add-Content $RegistryFile
        return
    }

    if (Copy-SshKeyToHost $user $hostName) {
        Write-Ok "Успешно"
        $Global:AddedList += "  - $hostName (теперь заходите как: $user)"
        $fp = Get-KeyFingerprint $Global:PubKey
        "$hostName $user added $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') fp=$fp" | Add-Content $RegistryFile
    } else {
        Write-Err "Ошибка"
        $Global:FailedList += "  - $hostName (пользователь: $user)"
    }
}

# === МЕНЮ ХОСТОВ ===
function Show-HostMenu ($hosts, $label) {
    while ($true) {
        Write-Header "Хосты из $label"
        for ($i = 0; $i -lt $hosts.Count; $i++) {
            Write-Host "  $($i + 1)) $($hosts[$i])"
        }
        Write-Host "  a) Обработать ВСЕ хосты"
        Write-Host "  0) Назад"
        $choice = Read-Host "Ваш выбор"

        if ($choice -eq "a" -or $choice -eq "A") {
            foreach ($h in $hosts) { Invoke-ProcessHost $h }
            Pause-Continue
        } elseif ($choice -eq "0") {
            return
        } elseif ($choice -match '^\d+$') {
            $n = [int]$choice
            if ($n -ge 1 -and $n -le $hosts.Count) {
                Invoke-ProcessHost $hosts[$n - 1]
                Pause-Continue
            } else {
                Write-Err "Неверный выбор."
            }
        } else {
            Write-Err "Неверный выбор."
        }
    }
}

# === РУЧНОЙ ВВОД ===
function Show-ManualEntry {
    while ($true) {
        Write-Header "Ручной ввод хостов"
        Write-Dim "Введите имя хоста или IP. Пустая строка - назад."
        $hostName = Read-Host "Хост"
        if ([string]::IsNullOrWhiteSpace($hostName)) { return }
        Invoke-ProcessHost $hostName
        Pause-Continue
    }
}

# === РЕЕСТР И ОТЧЁТ ===
function Show-Registry {
    Write-Header "Реестр разложенных ключей"
    if (-not (Test-Path $RegistryFile)) {
        Write-Warn "Реестр пуст."
        Pause-Continue
        return
    }
    $content = Get-Content $RegistryFile
    if (-not $content -or $content.Count -eq 0) {
        Write-Warn "Реестр пуст."
        Pause-Continue
        return
    }
    $content | ForEach-Object { Write-Host $_ }
    Pause-Continue
}

function Show-Report {
    Write-Header "ИТОГИ"
    $any = $false
    if ($Global:AlreadyList.Count -gt 0) {
        $any = $true
        Write-Host "Ключ уже был разложен ранее:" -ForegroundColor Green
        $Global:AlreadyList | ForEach-Object { Write-Host $_ -ForegroundColor Green }
    }
    if ($Global:AddedList.Count -gt 0) {
        $any = $true
        Write-Host "Ключ добавлен этим запуском:" -ForegroundColor Green
        $Global:AddedList | ForEach-Object { Write-Host $_ -ForegroundColor Green }
        Write-Host "Проверить подключение:"
        foreach ($line in $Global:AddedList) {
            if ($line -match "хост: (.+?) \(теперь заходите как: (.+?)\)") {
                Write-Host "    ssh $($Matches[2])@$($Matches[1])" -ForegroundColor Cyan
            }
        }
    }
    if ($Global:FailedList.Count -gt 0) {
        $any = $true
        Write-Host "Не удалось добавить ключ:" -ForegroundColor Red
        $Global:FailedList | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    }
    if ($Global:SkippedList.Count -gt 0) {
        $any = $true
        Write-Host "Пропущено:" -ForegroundColor Yellow
        $Global:SkippedList | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
    }
    if (-not $any) { Write-Dim "Ничего не сделано." }
}

# === УПРАВЛЕНИЕ КЛЮЧОМ ===
function Show-KeyMenu {
    while ($true) {
        Write-Header "Управление SSH-ключом"
        if ($Global:PubKey -and (Test-Path $Global:PubKey)) {
            Write-Host "  Текущий ключ: $Global:PubKey" -ForegroundColor Green
        } else {
            Write-Host "  Текущий ключ: (не выбран)" -ForegroundColor Yellow
        }
        Write-Host "  1) Найти и выбрать существующий ключ"
        Write-Host "  2) Сгенерировать новый ключ"
        Write-Host "  3) Аудит ключей"
        Write-Host "  0) Назад"
        $choice = Read-Host "Ваш выбор"

        switch ($choice) {
            "1" {
                $keys = @(Get-ChildItem -Path $SshDir -Filter "*.pub" -File -ErrorAction SilentlyContinue)
                if ($keys.Count -eq 0) { Write-Warn "Ключей не найдено."; Pause-Continue; continue }
                for ($i = 0; $i -lt $keys.Count; $i++) {
                    Write-Host "  $($i + 1)) $($keys[$i].FullName)"
                }
                $sel = Read-Host "Выберите номер (0 - отмена)"
                if ($sel -match '^\d+$') {
                    $n = [int]$sel
                    if ($n -ge 1 -and $n -le $keys.Count) {
                        $Global:PubKey = $keys[$n - 1].FullName
                        Write-Ok "Выбран: $Global:PubKey"
                    }
                }
                Pause-Continue
            }
            "2" { New-SshKey; Pause-Continue }
            "3" { Invoke-KeyAudit }
            "0" { return }
            default { Write-Err "Неверный выбор." }
        }
    }
}

# === ОТЗЫВ КЛЮЧА ===
function Revoke-KeyFromHosts {
    Write-Header "Отзыв ключа с удалённых хостов"
    $pubPath = Read-Host "Путь к .pub (Enter - отмена)"
    if ([string]::IsNullOrWhiteSpace($pubPath)) { return }
    if (-not (Test-Path $pubPath)) { Write-Err "Файл не найден."; return }

    $fp = Get-KeyFingerprint $pubPath
    if (-not $fp) { Write-Err "Не удалось вычислить отпечаток."; return }
    Write-Info "Отпечаток: $fp"

    if (-not (Test-Path $RegistryFile)) { Write-Warn "Реестр пуст."; return }

    $entries = @(Get-Content $RegistryFile | Where-Object { $_ -match [regex]::Escape("fp=$fp") })
    if ($entries.Count -eq 0) { Write-Warn "Записей с таким отпечатком нет."; return }

    Write-Host "Хосты из реестра:"
    $entries | ForEach-Object { Write-Host "  $_" }

    $confirm = Read-Host "Продолжить? [y/N]"
    if ($confirm -notmatch "^[Yy]$") { Write-Info "Отменено."; return }

    foreach ($entry in $entries) {
        $parts = $entry -split '\s+'
        $hostName = $parts[0]; $user = $parts[1]
        Write-Host "  Хост: $hostName (пользователь: $user)"

        $template = @'
tmp=$(mktemp)
while IFS= read -r line; do
    line_fp=$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')
    if [ "$line_fp" != "FINGERPRINT_PLACEHOLDER" ]; then echo "$line" >> "$tmp"; fi
done < ~/.ssh/authorized_keys
mv "$tmp" ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
echo OK
'@
        $remoteCmd = $template.Replace('FINGERPRINT_PLACEHOLDER', $fp)

        $output = ssh -o StrictHostKeyChecking=no -o ConnectTimeout=$SshTimeout "$user@$hostName" $remoteCmd 2>&1
        if ($output -match "OK") { Write-Ok "Ключ удалён с $user@$hostName" }
        else { Write-Err "Не удалось на $user@$hostName" }
    }
    Pause-Continue
}

# === ЧТЕНИЕ ФАЙЛА HOSTS ===
function Get-HostsFromFile ($path) {
    $hosts = @()
    if (-not (Test-Path $path)) { return $hosts }
    Get-Content $path | ForEach-Object {
        $line = $_.Trim()
        if ($line -and -not $line.StartsWith("#")) {
            $parts = $line -split '\s+'
            if ($parts.Count -ge 2 -and $parts[0] -match '^\d+\.\d+\.\d+\.\d+$') {
                $hosts += $parts[1]
            } elseif ($parts.Count -ge 1) {
                $hosts += $parts[0]
            }
        }
    }
    return @($hosts)
}

# === ГЛАВНОЕ МЕНЮ ===
function Show-MainMenu {
    while ($true) {
        Clear-Host
        Write-Host ""
        Write-Host "==========================================" -ForegroundColor Cyan
        Write-Host "  Интерактивная рассылка SSH-ключа (Win)" -ForegroundColor White
        Write-Host "==========================================" -ForegroundColor Cyan
        if ($Global:PubKey -and (Test-Path $Global:PubKey)) {
            Write-Host "  Ключ:   $Global:PubKey" -ForegroundColor Green
        } else {
            Write-Host "  Ключ:   (не выбран)" -ForegroundColor Yellow
        }
        Write-Host "  Реестр: $RegistryFile" -ForegroundColor DarkGray
        Write-Host "------------------------------------------" -ForegroundColor DarkGray
        Write-Host "  1) Хосты из файла hosts"
        Write-Host "  2) Ввести хост вручную"
        Write-Host "  3) Управление SSH-ключом"
        Write-Host "  4) Очистить known_hosts (все мёртвые хосты)"
        Write-Host "  5) Удалить конкретный хост из known_hosts"
        Write-Host "  6) Отозвать ключ с хостов"
        Write-Host "  7) Показать реестр"
        Write-Host "  8) Показать итоги"
        Write-Host "  0) Выход"
        $choice = Read-Host "Ваш выбор"

        switch ($choice) {
            "1" {
                if (-not $Global:PubKey) { Write-Warn "Сначала выберите ключ (пункт 3)."; Pause-Continue; continue }
                $default = "$env:SystemRoot\System32\drivers\etc\hosts"
                $hostsFile = Read-Host "Путь к файлу hosts [Enter - $default]"
                if ([string]::IsNullOrWhiteSpace($hostsFile)) { $hostsFile = $default }
                if (-not (Test-Path $hostsFile)) { Write-Err "Файл не найден: $hostsFile"; Pause-Continue; continue }
                $hosts = Get-HostsFromFile $hostsFile
                if ($hosts.Count -eq 0) { Write-Warn "В файле нет хостов."; Pause-Continue; continue }
                Show-HostMenu $hosts $hostsFile
            }
            "2" {
                if (-not $Global:PubKey) { Write-Warn "Сначала выберите ключ (пункт 3)."; Pause-Continue; continue }
                Show-ManualEntry
            }
            "3" { Show-KeyMenu }
            "4" {
                $dry = Read-Host "Режим DRY-RUN (без изменений)? [y/N]"
                Remove-StaleKnownHosts -DryRun:($dry -match "^[Yy]$")
                Pause-Continue
            }
            "5" {
                Remove-KnownHostEntry
                Pause-Continue
            }
            "6" { Revoke-KeyFromHosts }
            "7" { Show-Registry }
            "8" { Show-Report; Pause-Continue }
            "0" {
                Show-Report
                Write-Host ""
                Write-Host "До встречи!" -ForegroundColor Green
                exit
            }
            default { Write-Err "Неверный выбор." }
        }
    }
}

# === ТОЧКА ВХОДА ===
if (-not (Get-Command ssh-keygen -ErrorAction SilentlyContinue)) {
    Write-Err "ssh-keygen не найден. Установите OpenSSH Client:"
    Write-Dim "Параметры -> Приложения -> Дополнительные компоненты -> OpenSSH Client"
    exit 1
}

if (-not (Test-Path $SshDir)) { New-Item -ItemType Directory -Path $SshDir -Force | Out-Null }
if (-not (Test-Path $RegistryFile)) { New-Item -ItemType File -Path $RegistryFile -Force | Out-Null }

Show-MainMenu