#!/bin/bash
# ============================================================
#  Домашняя SSH-инфраструктура (Linux / РЕД ОС)
# ============================================================

# === ЦВЕТА ===
if [ -t 1 ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_CYAN=$'\033[36m'; C_BRED=$'\033[1;31m'; C_BGREEN=$'\033[1;32m'
    C_BYELLOW=$'\033[1;33m'; C_BBLUE=$'\033[1;34m'; C_BCYAN=$'\033[1;36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""
    C_CYAN=""; C_BRED=""; C_BGREEN=""; C_BYELLOW=""; C_BBLUE=""; C_BCYAN=""
fi

hr()   { printf "${C_DIM}%s${C_RESET}\n" "──────────────────────────────────────────"; }
ok()   { echo "${C_GREEN}  ✔  $1${C_RESET}"; }
warn() { echo "${C_YELLOW}  ⚠  $1${C_RESET}"; }
err()  { echo "${C_RED}  ✖  $1${C_RESET}"; }
info() { echo "${C_CYAN}  ℹ  $1${C_RESET}"; }
dim()  { echo "${C_DIM}     $1${C_RESET}"; }
header() {
    echo ""
    echo "${C_BCYAN}==========================================${C_RESET}"
    echo "${C_BOLD}${C_BBLUE}  $1${C_RESET}"
    echo "${C_BCYAN}==========================================${C_RESET}"
}
pause() {
    echo ""
    printf "${C_DIM}Нажмите Enter, чтобы продолжить...${C_RESET}"
    read -r _
}

# === ПУТИ И НАСТРОЙКИ ===
SSH_DIR="$HOME/.ssh"
INVENTORY="$SSH_DIR/home_hosts.txt"
REGISTRY="$SSH_DIR/deploy_keys.log"
KNOWN_HOSTS="$SSH_DIR/known_hosts"
HOSTS_FILE="/etc/hosts"
SSH_TIMEOUT=5

# === ГЛОБАЛЬНЫЕ ===
PUB_KEY=""
USER_ARG=""
ALREADY_LIST=""
ADDED_LIST=""
FAILED_LIST=""
SKIPPED_LIST=""

# ============================================================
#  ОБЩИЕ УТИЛИТЫ
# ============================================================

ensure_dirs() {
    if [ ! -d "$SSH_DIR" ]; then
        mkdir -p "$SSH_DIR"
        chmod 700 "$SSH_DIR"
    fi
    [ ! -f "$REGISTRY" ] && { : > "$REGISTRY"; chmod 600 "$REGISTRY"; }
    [ ! -f "$INVENTORY" ] && { : > "$INVENTORY"; chmod 600 "$INVENTORY"; }
}

fingerprint_of() {
    local pub="$1"
    [ -f "$pub" ] || { echo ""; return; }
    ssh-keygen -lf "$pub" 2>/dev/null | awk '{print $2}'
}

key_type_of() {
    local pub="$1"
    ssh-keygen -lf "$pub" 2>/dev/null | awk '{print $4}' | tr -d '()'
}

key_bits_of() {
    local pub="$1"
    ssh-keygen -lf "$pub" 2>/dev/null | awk '{print $1}'
}

key_already_works() {
    local user="$1" host="$2"
    local priv="${PUB_KEY%.pub}"
    ssh -i "$priv" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout="$SSH_TIMEOUT" \
        -o PreferredAuthentications=publickey \
        "$user@$host" true 2>/dev/null
}

registry_users_for_host() {
    local host="$1"
    [ -f "$REGISTRY" ] || return 0
    awk -v h="$host" '$1 == h && $3 == "added" {print $2}' "$REGISTRY" | sort -u
}

# ============================================================
#  ИНВЕНТАРЬ ХОСТОВ
# ============================================================

inventory_count() {
    [ -f "$INVENTORY" ] || { echo 0; return; }
    local c
    c="$(grep -cE '^[^#[:space:]]' "$INVENTORY" 2>/dev/null)"
    [ -z "$c" ] && c=0
    echo "$c"
}

inventory_names() {
    [ -f "$INVENTORY" ] || return 0
    awk '!/^#/ && NF >= 2 && $1 ~ /^[0-9.]+$/ { print $2 }' "$INVENTORY"
}

inventory_ip_of() {
    local name="$1"
    [ -f "$INVENTORY" ] || { echo ""; return; }
    awk -v n="$name" '!/^#/ && ($2 == n || $3 == n || $4 == n) { print $1; exit }' "$INVENTORY"
}

inventory_has_host() {
    local name="$1"
    [ -f "$INVENTORY" ] || return 1
    grep -qE "^[^#]*[[:space:]]${name}([[:space:]]|$)" "$INVENTORY"
}

inventory_show() {
    header "Инвентарь хостов"
    if [ ! -f "$INVENTORY" ] || [ ! -s "$INVENTORY" ]; then
        warn "Инвентарь пуст: $INVENTORY"
        dim "Добавьте хосты через пункт 1 главного меню."
        return
    fi
    printf "${C_BOLD}%-18s %-30s %s${C_RESET}\n" "IP" "ИМЯ" "АЛИАСЫ"
    hr
    awk '!/^#/ && NF >= 2 { aliases=""; for (i=3;i<=NF;i++) aliases=aliases" "$i; printf "%-18s %-30s %s\n", $1, $2, aliases }' "$INVENTORY"
    echo ""
    dim "Файл: $INVENTORY"
}

inventory_add() {
    header "Добавить хост в инвентарь"
    echo ""
    local ip name aliases

    read -rp "  ${C_BOLD}IP-адрес${C_RESET} (например, 192.168.1.10): " ip
    [ -z "$ip" ] && { info "Отменено."; return; }
    if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        err "Некорректный IP."
        return
    fi

    read -rp "  ${C_BOLD}Имя хоста${C_RESET} (например, macmini.local): " name
    [ -z "$name" ] && { info "Отменено."; return; }

    read -rp "  ${C_BOLD}Алиасы${C_RESET} через пробел (можно пусто): " aliases

    local line="$ip $name"
    [ -n "$aliases" ] && line="$line $aliases"

    if inventory_has_host "$name"; then
        warn "Хост '$name' уже есть в инвентаре:"
        grep -E "^[^#]*[[:space:]]${name}([[:space:]]|$)" "$INVENTORY"
        read -rp "  Всё равно добавить дубликат? [y/N]: " a
        [[ ! "$a" =~ ^[Yy]$ ]] && { info "Отменено."; return; }
    fi

    echo "$line" >> "$INVENTORY"
    ok "Добавлено: $line"
}

inventory_remove() {
    header "Удалить хост из инвентаря"
    echo ""
    read -rp "  Имя хоста для удаления: " name
    [ -z "$name" ] && return

    if ! inventory_has_host "$name"; then
        warn "Хост '$name' не найден в инвентаре."
        return
    fi

    local tmp
    tmp="$(mktemp)"
    grep -vE "^[^#]*[[:space:]]${name}([[:space:]]|$)" "$INVENTORY" > "$tmp"
    mv "$tmp" "$INVENTORY"
    ok "Хост '$name' удалён из инвентаря."
}

inventory_import_from_hosts() {
    header "Импорт из /etc/hosts в инвентарь"
    echo ""
    if [ ! -r "$HOSTS_FILE" ]; then
        err "Не могу прочитать $HOSTS_FILE"
        return
    fi

    local count=0
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        local ip name
        ip="$(echo "$line" | awk '{print $1}')"
        name="$(echo "$line" | awk '{print $2}')"
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        [[ "$ip" == 127.* ]] && continue
        [ -z "$name" ] && continue
        inventory_has_host "$name" && continue

        echo "$line" >> "$INVENTORY"
        dim "+ $ip $name"
        count=$((count + 1))
    done < "$HOSTS_FILE"

    if [ "$count" -eq 0 ]; then
        info "Новых хостов не найдено."
    else
        ok "Импортировано записей: $count"
    fi
}

# ============================================================
#  ОБНАРУЖЕНИЕ ХОСТОВ
# ============================================================

discover_from_dns_axfr() {
    header "Обнаружение хостов через DNS AXFR"
    echo ""
    dim "Скрипт попробует получить все записи зоны через"
    dim "зонный трансфер. Работает, только если ваш DNS-сервер"
    dim "разрешает AXFR для вашей подсети."
    echo ""

    read -rp "  ${C_BOLD}Домен зоны${C_RESET} (например, home.local): " zone
    [ -z "$zone" ] && return

    read -rp "  ${C_BOLD}DNS-сервер${C_RESET} (IP, Enter — из /etc/resolv.conf): " dns
    if [ -z "$dns" ]; then
        dns="$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf)"
        [ -z "$dns" ] && { err "Не удалось определить DNS-сервер."; return; }
        info "Использую DNS-сервер: $dns"
    fi

    if ! command -v dig >/dev/null 2>&1; then
        err "Утилита dig не найдена. Установите: sudo dnf install -y bind-utils"
        return
    fi

    info "Запрашиваю AXFR для зоны $zone у $dns..."
    local output
    output="$(dig +noall +answer AXFR "$zone" @"$dns" 2>&1)"

    if [ -z "$output" ] || echo "$output" | grep -qi "failed\|refused\|timed out\|Transfer failed"; then
        err "Зонный трансфер не удался."
        dim "Возможные причины: AXFR запрещён, неверный домен/сервер."
        return
    fi

    local added=0
    while read -r name ttl class type ip; do
        [ "$type" = "A" ] || continue
        name="${name%.}"
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        [[ "$ip" == 127.* ]] && continue

        if inventory_has_host "$name"; then
            dim "= $name ($ip) — уже в инвентаре"
        else
            echo "$ip $name" >> "$INVENTORY"
            dim "+ $ip $name"
            added=$((added + 1))
        fi
    done <<< "$output"

    echo ""
    if [ "$added" -eq 0 ]; then
        info "Новых хостов не найдено."
    else
        ok "Добавлено в инвентарь: $added"
    fi
}

discover_from_network_scan() {
    header "Обнаружение хостов (локальный nmap)"
    echo ""
    dim "Требуется nmap и права sudo."
    echo ""

    read -rp "  ${C_BOLD}Подсеть${C_RESET} [192.168.1.0/24]: " subnet
    subnet="${subnet:-192.168.1.0/24}"

    if ! command -v nmap >/dev/null 2>&1; then
        err "nmap не найден. Установите: sudo dnf install -y nmap"
        return
    fi

    if ! check_sudo; then
        err "Нужны права root для сканирования."
        return
    fi

    info "Сканирую $subnet..."
    local scan
    scan="$(sudo nmap -sn -oG - "$subnet" 2>/dev/null | awk '/^Host:/ {print $2, $3}')"

    if [ -z "$scan" ]; then
        warn "Живых хостов не найдено."
        return
    fi

    local added=0
    while read -r ip name; do
        [ -z "$ip" ] && continue
        name="${name#(}"
        name="${name%)}"
        [ -z "$name" ] && name="$ip"

        if inventory_has_host "$name" || inventory_has_host "$ip"; then
            dim "= $name ($ip) — уже в инвентаре"
        else
            echo "$ip $name" >> "$INVENTORY"
            dim "+ $ip $name"
            added=$((added + 1))
        fi
    done <<< "$scan"

    echo ""
    if [ "$added" -eq 0 ]; then
        info "Новых хостов не найдено."
    else
        ok "Добавлено: $added"
    fi
}

discover_from_mdns() {
    header "Обнаружение хостов через mDNS (Avahi)"
    echo ""

    if ! command -v avahi-browse >/dev/null 2>&1; then
        err "avahi-browse не найден. Установите: sudo dnf install -y avahi-tools"
        return
    fi

    info "Сканирую сеть (5 секунд)..."
    local output
    output="$(avahi-browse -art --terminate 2>/dev/null)"

    local names
    names="$(echo "$output" | grep -oE '= [^ ]+ IPv[46] [^ ]+\.local' | awk '{print $4}' | sort -u)"

    if [ -z "$names" ]; then
        warn "Хостов через mDNS не найдено."
        return
    fi

    local added=0
    while read -r name; do
        [ -z "$name" ] && continue
        local ip
        ip="$(avahi-resolve -n "$name" 2>/dev/null | awk '{print $2}')"
        [ -z "$ip" ] && continue

        if inventory_has_host "$name"; then
            dim "= $name ($ip) — уже в инвентаре"
        else
            echo "$ip $name" >> "$INVENTORY"
            dim "+ $ip $name"
            added=$((added + 1))
        fi
    done <<< "$names"

    echo ""
    if [ "$added" -eq 0 ]; then
        info "Новых хостов не найдено."
    else
        ok "Добавлено: $added"
    fi
}

discover_via_remote_host() {
    header "Обнаружение хостов через удалённый хост"
    echo ""
    dim "Скрипт зайдёт по SSH на указанный хост и выполнит там"
    dim "сканирование сети, а результат добавит в ваш инвентарь."
    echo ""

    read -rp "  ${C_BOLD}Хост для сканирования${C_RESET} (user@host или host): " target
    [ -z "$target" ] && return
    if [[ "$target" != *"@"* ]]; then
        target="$(whoami)@$target"
    fi

    read -rp "  ${C_BOLD}Подсеть${C_RESET} [192.168.1.0/24]: " subnet
    subnet="${subnet:-192.168.1.0/24}"

    info "Проверяю доступ к $target..."
    if ! ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" \
             -o StrictHostKeyChecking=accept-new "$target" "true" 2>/dev/null; then
        err "Не удалось подключиться к $target без пароля."
        dim "Разложите ключ: ssh-copy-id $target"
        return
    fi
    ok "Соединение установлено."

    info "Проверяю утилиты на $target..."
    local has_nmap has_ip has_arp has_sudo
    has_nmap="$(ssh -o BatchMode=yes "$target" "command -v nmap >/dev/null 2>&1 && echo yes || echo no" 2>/dev/null)"
    has_ip="$(ssh -o BatchMode=yes "$target" "command -v ip >/dev/null 2>&1 && echo yes || echo no" 2>/dev/null)"
    has_arp="$(ssh -o BatchMode=yes "$target" "command -v arp >/dev/null 2>&1 && echo yes || echo no" 2>/dev/null)"
    has_sudo="$(ssh -o BatchMode=yes "$target" "sudo -n true 2>/dev/null && echo yes || echo no" 2>/dev/null)"
    dim "nmap: $has_nmap | ip: $has_ip | arp: $has_arp | sudo без пароля: $has_sudo"
    echo ""

    local output="" method=""

    if [ "$has_nmap" = "yes" ]; then
        info "Использую nmap..."
        if [ "$has_sudo" = "yes" ]; then
            output="$(ssh -o BatchMode=yes "$target" "sudo nmap -sn -oG - '$subnet'" 2>/dev/null)"
            method="nmap (sudo)"
        else
            output="$(ssh -o BatchMode=yes "$target" "nmap -sn -oG - '$subnet'" 2>/dev/null)"
            method="nmap"
        fi

        if [ -n "$output" ]; then
            local added=0
            while read -r ip name; do
                [ -z "$ip" ] && continue
                name="${name#(}"
                name="${name%)}"
                [ -z "$name" ] && name="$ip"
                if inventory_has_host "$name" || inventory_has_host "$ip"; then
                    dim "= $name ($ip) — уже в инвентаре"
                else
                    echo "$ip $name" >> "$INVENTORY"
                    dim "+ $ip $name"
                    added=$((added + 1))
                fi
            done < <(echo "$output" | awk '/^Host:/ {print $2, $3}')
            echo ""
            if [ "$added" -eq 0 ]; then
                info "Новых хостов не найдено (метод: $method)."
            else
                ok "Добавлено: $added (метод: $method)"
            fi
            return
        fi
        warn "nmap не вернул результат, пробую ARP-таблицу."
    fi

    if [ "$has_ip" = "yes" ]; then
        info "Читаю ARP-таблицу через ip neigh..."
        output="$(ssh -o BatchMode=yes "$target" "ip neigh show" 2>/dev/null)"
        method="ip neigh"
    elif [ "$has_arp" = "yes" ]; then
        info "Читаю ARP-таблицу через arp -a..."
        output="$(ssh -o BatchMode=yes "$target" "arp -a" 2>/dev/null)"
        method="arp -a"
    fi

    if [ -n "$output" ]; then
        local added=0
        if [ "$method" = "ip neigh" ]; then
            while read -r ip _; do
                [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
                [[ "$ip" == 127.* ]] && continue
                if inventory_has_host "$ip"; then
                    dim "= $ip — уже в инвентаре"
                else
                    echo "$ip $ip" >> "$INVENTORY"
                    dim "+ $ip"
                    added=$((added + 1))
                fi
            done < <(echo "$output" | awk '{print $1}')
        elif [ "$method" = "arp -a" ]; then
            while read -r ip; do
                [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
                [[ "$ip" == 127.* ]] && continue
                if inventory_has_host "$ip"; then
                    dim "= $ip — уже в инвентаре"
                else
                    echo "$ip $ip" >> "$INVENTORY"
                    dim "+ $ip"
                    added=$((added + 1))
                fi
            done < <(echo "$output" | grep -oE '\([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\)' | tr -d '()')
        fi
        echo ""
        if [ "$added" -eq 0 ]; then
            info "Новых хостов не найдено (метод: $method)."
        else
            ok "Добавлено: $added (метод: $method)"
            warn "Имён хостов нет — добавлены только IP."
            dim "Дополните имена вручную: пункт 1 → 2"
        fi
        return
    fi

    err "Не удалось получить список хостов."
}

# ============================================================
#  РАБОТА С /etc/hosts
# ============================================================

hosts_has_name() {
    local name="$1"
    [ -r "$HOSTS_FILE" ] || return 1
    grep -qE "^[^#]*[[:space:]]${name}([[:space:]]|$)" "$HOSTS_FILE"
}

hosts_entry_of() {
    local name="$1"
    grep -E "^[^#]*[[:space:]]${name}([[:space:]]|$)" "$HOSTS_FILE" 2>/dev/null | head -n1
}

check_sudo() {
    if ! command -v sudo >/dev/null 2>&1; then
        return 1
    fi
    sudo -n true 2>/dev/null && return 0
    info "Для изменения $HOSTS_FILE требуется sudo."
    sudo -v || return 1
    return 0
}

hosts_add_entry() {
    local ip="$1" name="$2" aliases="$3"

    if hosts_has_name "$name"; then
        warn "Уже есть в /etc/hosts:"
        dim "$(hosts_entry_of "$name")"
        return 1
    fi

    if ! check_sudo; then
        err "Нет доступа к sudo. Пропускаю '$name'."
        return 1
    fi

    local line="$ip $name"
    [ -n "$aliases" ] && line="$line $aliases"

    if echo "$line" | sudo tee -a "$HOSTS_FILE" > /dev/null; then
        ok "Добавлено в $HOSTS_FILE: $line"
        return 0
    else
        err "Не удалось добавить '$name'"
        return 1
    fi
}

sync_hosts_from_inventory() {
    header "Синхронизация $HOSTS_FILE с инвентарём"
    echo ""

    if [ ! -f "$INVENTORY" ] || [ ! -s "$INVENTORY" ]; then
        warn "Инвентарь пуст."
        return
    fi

    local added=0 skipped=0
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        local ip name aliases
        ip="$(echo "$line" | awk '{print $1}')"
        name="$(echo "$line" | awk '{print $2}')"
        aliases="$(echo "$line" | awk '{ for (i=3;i<=NF;i++) printf "%s ", $i }')"

        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        [ -z "$name" ] && continue

        if hosts_has_name "$name"; then
            local existing_ip
            existing_ip="$(hosts_entry_of "$name" | awk '{print $1}')"
            if [ "$existing_ip" = "$ip" ]; then
                dim "= $name ($ip) — уже есть"
            else
                warn "! $name — локально $existing_ip, в инвентаре $ip"
            fi
            skipped=$((skipped + 1))
        else
            hosts_add_entry "$ip" "$name" "$aliases" && added=$((added + 1))
        fi
    done < "$INVENTORY"

    echo ""
    hr
    info "Добавлено: $added, уже было: $skipped"
}

# --- Просмотр /etc/hosts удалённого хоста ---
show_remote_hosts() {
    header "Просмотр /etc/hosts удалённого хоста"
    echo ""
    dim "Просто показывает содержимое файла на удалённом хосте."
    dim "Ничего не меняет — ни там, ни локально."
    echo ""

    read -rp "  ${C_BOLD}Хост${C_RESET} (user@host или host): " target
    [ -z "$target" ] && return
    if [[ "$target" != *"@"* ]]; then
        target="$(whoami)@$target"
    fi

    info "Проверяю доступ к $target..."
    if ! ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" \
             -o StrictHostKeyChecking=accept-new "$target" "true" 2>/dev/null; then
        err "Не удалось подключиться к $target без пароля."
        dim "Разложите ключ: ssh-copy-id $target"
        return
    fi

    info "Читаю /etc/hosts с $target..."
    local remote_hosts
    remote_hosts="$(ssh -o BatchMode=yes "$target" "cat /etc/hosts" 2>/dev/null)"

    if [ -z "$remote_hosts" ]; then
        err "Файл пуст или не читается."
        return
    fi

    # Посчитаем статистику
    local total hosts_lines
    total="$(echo "$remote_hosts" | wc -l)"
    hosts_lines="$(echo "$remote_hosts" | grep -cE '^[[:space:]]*[0-9]')"

    echo ""
    echo "${C_BCYAN}--- /etc/hosts на $target ---${C_RESET}"
    echo "$remote_hosts"
    echo "${C_BCYAN}--- конец ---${C_RESET}"
    echo ""
    dim "Всего строк: $total, из них с IP: $hosts_lines"
}

# --- Импорт /etc/hosts с удалённого хоста ---
import_hosts_from_remote() {
    header "Импорт /etc/hosts с удалённого хоста"
    echo ""
    dim "Скрипт зайдёт по SSH на указанный хост, прочитает его"
    dim "/etc/hosts и добавит недостающие записи в ЛОКАЛЬНЫЙ."
    dim "На удалённом хосте ничего не меняется."
    echo ""

    read -rp "  ${C_BOLD}Хост-источник${C_RESET} (user@host или host): " target
    [ -z "$target" ] && return
    if [[ "$target" != *"@"* ]]; then
        target="$(whoami)@$target"
    fi

    info "Проверяю доступ к $target..."
    if ! ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" \
             -o StrictHostKeyChecking=accept-new "$target" "true" 2>/dev/null; then
        err "Не удалось подключиться к $target без пароля."
        dim "Разложите ключ: ssh-copy-id $target"
        return
    fi
    ok "Соединение установлено."

    info "Читаю /etc/hosts с $target..."
    local remote_hosts
    remote_hosts="$(ssh -o BatchMode=yes "$target" "cat /etc/hosts" 2>/dev/null)"

    if [ -z "$remote_hosts" ]; then
        err "Не удалось прочитать /etc/hosts на $target."
        return
    fi

    # Предложим посмотреть, что там (полезно перед импортом)
    echo ""
    read -rp "  ${C_BOLD}Показать содержимое $target:/etc/hosts?${C_RESET} [y/N]: " sh
    if [[ "$sh" =~ ^[Yy]$ ]]; then
        echo ""
        echo "${C_BCYAN}--- /etc/hosts на $target ---${C_RESET}"
        echo "$remote_hosts"
        echo "${C_BCYAN}--- конец ---${C_RESET}"
    fi

    echo ""
    info "Сравниваю с локальным $HOSTS_FILE..."
    echo ""

    local to_add=""
    local added=0
    local skipped=0
    local seen_lines=""

    while IFS= read -r line; do
        line="$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -z "$line" ] && continue
        [[ "$line" = \#* ]] && continue

        local ip
        ip="$(echo "$line" | awk '{print $1}')"
        [ -z "$ip" ] && continue
        [[ "$ip" == "127."* ]] && continue
        [[ "$ip" == "::1" ]] && continue
        [[ "$ip" == "fe80"* ]] && continue
        [[ "$ip" == "ff"* ]] && continue
        [[ "$ip" == "0.0.0.0" ]] && continue

        # Дедупликация: если такая строка уже попадалась в этом файле — пропускаем
        if echo "$seen_lines" | grep -qxF "$line"; then
            continue
        fi
        seen_lines="${seen_lines}${line}"$'\n'

        local names
        names="$(echo "$line" | awk '{for (i=2;i<=NF;i++) print $i}')"
        [ -z "$names" ] && continue

        local need_add=0
        local missing_names=""
        while read -r name; do
            [ -z "$name" ] && continue
            if ! hosts_has_name "$name"; then
                need_add=1
                missing_names="$missing_names $name"
            fi
        done <<< "$names"

        if [ "$need_add" -eq 1 ]; then
            local first_name
            first_name="$(echo "$names" | head -n1)"
            if grep -qE "^[[:space:]]*${ip}[[:space:]]+${first_name}([[:space:]]|$)" "$HOSTS_FILE" 2>/dev/null; then
                dim "≈ $ip$missing_names — IP уже есть с другими именами"
                skipped=$((skipped + 1))
            else
                to_add="${to_add}${line}"$'\n'
                added=$((added + 1))
                dim "+ $line"
            fi
        else
            dim "= $line — уже есть локально"
            skipped=$((skipped + 1))
        fi
    done <<< "$remote_hosts"

    echo ""
    hr

    if [ "$added" -eq 0 ]; then
        ok "Все записи с $target уже есть локально. Нечего добавлять."
        echo ""
        info "Пропущено (уже есть): $skipped"
        return
    fi

    info "Будет добавлено записей: $added"
    dim "Уже есть локально: $skipped"
    echo ""

    read -rp "  Добавить их в $HOSTS_FILE? [y/N]: " a
    [[ ! "$a" =~ ^[Yy]$ ]] && { info "Отменено."; return; }

    if ! check_sudo; then
        err "Нет доступа к sudo."
        return
    fi

    local backup="/etc/hosts.bak.$(date +%Y%m%d_%H%M%S)"
    if ! sudo cp "$HOSTS_FILE" "$backup"; then
        err "Не удалось создать бэкап. Отменяю."
        return
    fi
    dim "Резервная копия: $backup"

    local marker="# --- imported from $target at $(date '+%Y-%m-%d %H:%M:%S') ---"

    {
        echo ""
        echo "$marker"
        printf "%s" "$to_add"
    } | sudo tee -a "$HOSTS_FILE" > /dev/null

    if [ $? -eq 0 ]; then
        ok "Добавлено записей: $added"
        dim "Источник: $target"
    else
        err "Не удалось записать в $HOSTS_FILE"
    fi
}

# ============================================================
#  УПРАВЛЕНИЕ КЛЮЧОМ
# ============================================================

generate_key() {
    header "Генерация SSH-ключа"
    echo ""
    echo "  ${C_BOLD}1)${C_RESET} ed25519 ${C_GREEN}(рекомендуется)${C_RESET}"
    echo "  ${C_BOLD}2)${C_RESET} rsa 4096"
    echo ""
    read -rp "Ваш выбор [1]: " kt
    kt="${kt:-1}"

    local keytype keyfile bits
    case "$kt" in
        2) keytype="rsa"; bits="-b 4096"; keyfile="$SSH_DIR/id_rsa" ;;
        *) keytype="ed25519"; bits=""; keyfile="$SSH_DIR/id_ed25519" ;;
    esac

    if [ -f "$keyfile" ]; then
        warn "Ключ уже существует: $keyfile"
        read -rp "Перезаписать (старый сохранится в .bak)? [y/N]: " ow
        [[ ! "$ow" =~ ^[Yy]$ ]] && { PUB_KEY="$keyfile.pub"; info "Отменено."; return 0; }
        local ts
        ts="$(date +%Y%m%d_%H%M%S)"
        cp "$keyfile" "$keyfile.bak.$ts"
        [ -f "$keyfile.pub" ] && cp "$keyfile.pub" "$keyfile.pub.bak.$ts"
        dim "Старый ключ сохранён как $keyfile.bak.$ts"
    fi

    mkdir -p "$SSH_DIR" 2>/dev/null
    chmod 700 "$SSH_DIR" 2>/dev/null

    local comment
    read -rp "Комментарий к ключу [$(whoami)@$(hostname)]: " comment
    comment="${comment:-$(whoami)@$(hostname)}"

    echo "${C_DIM}Пароль на ключ (Enter — без пароля):${C_RESET}"
    local pass
    read -rsp "  Passphrase: " pass
    echo ""

    if [ -n "$pass" ]; then
        ssh-keygen -t "$keytype" $bits -C "$comment" -f "$keyfile"
    else
        ssh-keygen -t "$keytype" $bits -C "$comment" -f "$keyfile" -N ""
    fi

    if [ $? -eq 0 ] && [ -f "$keyfile.pub" ]; then
        ok "Ключ успешно создан."
        dim "Приватный: $keyfile"
        dim "Публичный: $keyfile.pub"
        PUB_KEY="$keyfile.pub"
        return 0
    else
        err "Ошибка генерации ключа."
        dim "Проверьте права на $SSH_DIR:"
        dim "  ls -ld $SSH_DIR"
        dim "Если владелец root — исправьте:"
        dim "  sudo chown -R $(whoami):$(whoami) $SSH_DIR"
        return 1
    fi
}

find_and_pick_key() {
    local found_list=()
    local f
    for f in "$SSH_DIR/"*.pub; do
        [ -f "$f" ] || continue
        found_list+=("$f")
    done

    if [ ${#found_list[@]} -eq 0 ]; then
        warn "В $SSH_DIR нет публичных ключей."
        return 1
    fi

    if [ ${#found_list[@]} -eq 1 ]; then
        local base
        base="$(basename "${found_list[0]}")"
        if [[ ! "$base" =~ ^(ansible|deploy|backup|service|automation) ]]; then
            PUB_KEY="${found_list[0]}"
            info "Автоматически выбран единственный ключ:"
            dim "$PUB_KEY"
            return 0
        fi
        info "Найден только служебный ключ '$base' — выбираю вручную."
    fi

    header "Выбор публичного ключа"
    local i=1
    for k in "${found_list[@]}"; do
        printf "  ${C_BYELLOW}%d)${C_RESET} ${C_BOLD}%s${C_RESET}\n" "$i" "$k"
        printf "     ${C_DIM}тип: %s, отпечаток: %s${C_RESET}\n" "$(key_type_of "$k")" "$(fingerprint_of "$k")"
        i=$((i + 1))
    done
    echo "  ${C_BOLD}m)${C_RESET} Указать путь вручную"
    echo "  ${C_BOLD}0)${C_RESET} Назад"
    echo ""
    read -rp "Выберите ключ: " c

    if [ "$c" = "0" ]; then
        return 0
    elif [ "$c" = "m" ] || [ "$c" = "M" ]; then
        read -rp "  Путь к .pub: " p
        p="${p/#\~/$HOME}"
        if [ -f "$p" ]; then
            PUB_KEY="$p"
            ok "Выбран: $PUB_KEY"
        else
            err "Файл не найден: $p"
        fi
    elif [[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#found_list[@]} ]; then
        PUB_KEY="${found_list[$((c - 1))]}"
        ok "Выбран: $PUB_KEY"
    else
        err "Неверный выбор."
    fi
}

key_audit() {
    header "Аудит SSH-ключей в $SSH_DIR"

    local any=0
    local f priv
    for f in "$SSH_DIR/"*.pub; do
        [ -f "$f" ] || continue
        any=1
        priv="${f%.pub}"
        echo ""
        echo "${C_BCYAN}--- $f ---${C_RESET}"
        printf "  Тип:         %s\n" "$(key_type_of "$f")"
        printf "  Длина:       %s бит\n" "$(key_bits_of "$f")"
        printf "  Отпечаток:   %s\n" "$(fingerprint_of "$f")"

        if [ -f "$priv" ]; then
            printf "  Приватная:   ${C_GREEN}есть${C_RESET}\n"
        else
            printf "  Приватная:   ${C_RED}НЕТ${C_RESET}\n"
            err "Приватная часть отсутствует."
        fi

        local type bits
        type="$(key_type_of "$f")"
        bits="$(key_bits_of "$f")"
        case "$type" in
            ED25519) ok "ED25519 (256 бит) — современный и безопасный." ;;
            RSA)
                if [ "$bits" -lt 2048 ]; then
                    err "RSA $bits бит — небезопасно (нужно ≥ 2048)."
                elif [ "$bits" -lt 3072 ]; then
                    warn "RSA $bits бит — допустимо, рекомендуется ≥ 3072."
                else
                    ok "RSA $bits бит — безопасно."
                fi
                ;;
            ECDSA) info "ECDSA $bits бит — допустимо." ;;
            *) info "Тип: $type, длина: $bits бит." ;;
        esac
    done

    [ "$any" -eq 0 ] && warn "Публичных ключей не найдено."
}

key_menu() {
    while true; do
        header "Управление SSH-ключом"
        if [ -n "$PUB_KEY" ] && [ -f "$PUB_KEY" ]; then
            printf "  ${C_DIM}Текущий ключ:${C_RESET} ${C_GREEN}%s${C_RESET}\n" "$PUB_KEY"
        else
            printf "  ${C_DIM}Текущий ключ:${C_RESET} ${C_YELLOW}(не выбран)${C_RESET}\n"
        fi
        hr
        echo ""
        echo "  ${C_BOLD}1)${C_RESET} Найти и выбрать существующий ключ"
        echo "  ${C_BOLD}2)${C_RESET} Сгенерировать новый ключ"
        echo "  ${C_BOLD}3)${C_RESET} Показать публичный ключ"
        echo "  ${C_BOLD}4)${C_RESET} Аудит ключей"
        echo "  ${C_BOLD}0)${C_RESET} Назад"
        echo ""
        read -rp "Ваш выбор: " choice

        case "$choice" in
            1) find_and_pick_key; pause ;;
            2) generate_key; pause ;;
            3)
                if [ -n "$PUB_KEY" ] && [ -f "$PUB_KEY" ]; then
                    echo ""
                    echo "${C_CYAN}$(cat "$PUB_KEY")${C_RESET}"
                else
                    warn "Ключ не выбран."
                fi
                pause
                ;;
            4) key_audit; pause ;;
            0) return ;;
            *) err "Неверный выбор." ;;
        esac
    done
}

ensure_key() {
    if [ -n "$PUB_KEY" ] && [ -f "$PUB_KEY" ]; then
        return 0
    fi

    echo ""
    warn "Публичный ключ ещё не выбран."

    local found="" f
    for f in "$SSH_DIR/id_ed25519.pub" "$SSH_DIR/id_rsa.pub" "$SSH_DIR/id_ecdsa.pub"; do
        if [ -f "$f" ]; then
            found="$f"
            break
        fi
    done

    if [ -n "$found" ]; then
        info "Найден ключ: $found"
        read -rp "Использовать его? [Y/n]: " a
        a="${a:-Y}"
        if [[ "$a" =~ ^[Yy]$ ]]; then
            PUB_KEY="$found"
            return 0
        fi
    else
        info "Стандартного ключа (id_ed25519/id_rsa) не найдено."
    fi

    read -rp "Сгенерировать новый ключ сейчас? [Y/n]: " a
    a="${a:-Y}"
    if [[ "$a" =~ ^[Yy]$ ]]; then
        generate_key && return 0
        # Если генерация не удалась — возвращаем 1
        return 1
    fi

    err "Без ключа разложить его не получится."
    return 1
}

# ============================================================
#  РАССЫЛКА КЛЮЧА
# ============================================================

deploy_to_host() {
    local host="$1"

    echo ""
    echo "${C_BCYAN}┌─────────────────────────────────────────┐${C_RESET}"
    printf "${C_BCYAN}│${C_RESET}  ${C_BOLD}Хост:${C_RESET} ${C_BOLD}${C_BBLUE}%-32s${C_RESET} ${C_BCYAN}│${C_RESET}\n" "$host"
    echo "${C_BCYAN}└─────────────────────────────────────────┘${C_RESET}"

    local prev
    prev="$(registry_users_for_host "$host")"
    if [ -n "$prev" ]; then
        info "В реестре есть записи:"
        echo "$prev" | while read -r u; do
            [ -n "$u" ] && dim "  • $u"
        done
    fi

    local user
    if [ -n "$USER_ARG" ]; then
        user="$USER_ARG"
        info "Пользователь (из -u): $user"
    else
        read -rp "  ${C_BOLD}Пользователь${C_RESET} ${C_DIM}(skip — пропустить, q — выход)${C_RESET}: " user
        case "$user" in
            q|Q)
                info "Выход."
                show_report
                exit 0
                ;;
            skip|SKIP)
                SKIPPED_LIST="${SKIPPED_LIST}  - $host\n"
                return
                ;;
            "") return ;;
        esac
    fi

    if key_already_works "$user" "$host"; then
        ok "Ключ УЖЕ работает для $user@$host."
        ALREADY_LIST="${ALREADY_LIST}  - $(printf '%-25s' "$host") пользователь: $user\n"
        local fp
        fp="$(fingerprint_of "$PUB_KEY")"
        if ! grep -q "^$host $user added .*fp=$fp" "$REGISTRY" 2>/dev/null; then
            echo "$host $user added $(date '+%Y-%m-%d %H:%M:%S') fp=$fp" >> "$REGISTRY"
        fi
        return
    fi

    info "Копирование ключа на $user@$host..."
    if ssh-copy-id -i "$PUB_KEY" \
            -o StrictHostKeyChecking=no \
            -o ConnectTimeout="$SSH_TIMEOUT" \
            "$user@$host" </dev/null; then
        ok "Успешно"
        ADDED_LIST="${ADDED_LIST}  - $(printf '%-25s' "$host") теперь заходите как: $user\n"
        local fp
        fp="$(fingerprint_of "$PUB_KEY")"
        echo "$host $user added $(date '+%Y-%m-%d %H:%M:%S') fp=$fp" >> "$REGISTRY"
    else
        err "Ошибка"
        FAILED_LIST="${FAILED_LIST}  - $(printf '%-25s' "$host") пользователь: $user\n"
    fi
}

deploy_menu_from_inventory() {
    if [ ! -f "$INVENTORY" ] || [ ! -s "$INVENTORY" ]; then
        warn "Инвентарь пуст."
        return
    fi

    local hosts_list=()
    while IFS= read -r name; do
        [ -n "$name" ] && hosts_list+=("$name")
    done < <(inventory_names)

    if [ ${#hosts_list[@]} -eq 0 ]; then
        warn "В инвентаре нет хостов."
        return
    fi

    while true; do
        header "Хосты из инвентаря"
        local i=1 h
        for h in "${hosts_list[@]}"; do
            local ip
            ip="$(inventory_ip_of "$h")"
            printf "  ${C_BYELLOW}%2d)${C_RESET} ${C_BOLD}%-30s${C_RESET} ${C_DIM}%s${C_RESET}\n" "$i" "$h" "$ip"
            i=$((i + 1))
        done
        echo ""
        echo "  ${C_GREEN}a)${C_RESET} Обработать ${C_BOLD}ВСЕ${C_RESET} хосты"
        echo "  ${C_BOLD}0)${C_RESET} Назад"
        echo ""
        read -rp "Ваш выбор: " choice

        case "$choice" in
            a|A)
                for h in "${hosts_list[@]}"; do
                    deploy_to_host "$h"
                done
                pause
                ;;
            0) return ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#hosts_list[@]} ]; then
                    deploy_to_host "${hosts_list[$((choice - 1))]}"
                    pause
                else
                    err "Неверный выбор."
                fi
                ;;
        esac
    done
}

deploy_menu_from_hosts() {
    if [ ! -r "$HOSTS_FILE" ]; then
        err "Не могу прочитать $HOSTS_FILE"
        return
    fi

    local hosts_list=()
    local seen_names=""
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        local ip name
        ip="$(echo "$line" | awk '{print $1}')"
        name="$(echo "$line" | awk '{print $2}')"
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
        [[ "$ip" == 127.* ]] && continue
        [ -z "$name" ] && continue
        # Дедупликация
        if echo "$seen_names" | grep -qxF "$name"; then
            continue
        fi
        seen_names="${seen_names}${name}"$'\n'
        hosts_list+=("$name")
    done < "$HOSTS_FILE"

    if [ ${#hosts_list[@]} -eq 0 ]; then
        warn "В $HOSTS_FILE нет подходящих хостов."
        return
    fi

    while true; do
        header "Хосты из $HOSTS_FILE"
        local i=1 h
        for h in "${hosts_list[@]}"; do
            printf "  ${C_BYELLOW}%2d)${C_RESET} ${C_BOLD}%s${C_RESET}\n" "$i" "$h"
            i=$((i + 1))
        done
        echo ""
        echo "  ${C_GREEN}a)${C_RESET} Обработать ${C_BOLD}ВСЕ${C_RESET} хосты"
        echo "  ${C_BOLD}0)${C_RESET} Назад"
        echo ""
        read -rp "Ваш выбор: " choice

        case "$choice" in
            a|A)
                for h in "${hosts_list[@]}"; do
                    deploy_to_host "$h"
                done
                pause
                ;;
            0) return ;;
            *)
                if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#hosts_list[@]} ]; then
                    deploy_to_host "${hosts_list[$((choice - 1))]}"
                    pause
                else
                    err "Неверный выбор."
                fi
                ;;
        esac
    done
}

deploy_manual() {
    while true; do
        header "Ручной ввод хоста"
        dim "Введите имя хоста или IP. Пустая строка — назад."
        echo ""
        read -rp "${C_BOLD}Хост:${C_RESET} " host
        [ -z "$host" ] && return

        if ! hosts_has_name "$host"; then
            warn "Хост '$host' не найден в $HOSTS_FILE."
            read -rp "  Добавить его в $HOSTS_FILE? [y/N]: " a
            if [[ "$a" =~ ^[Yy]$ ]]; then
                local ip
                read -rp "  IP-адрес хоста: " ip
                if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    hosts_add_entry "$ip" "$host" ""
                    if ! inventory_has_host "$host"; then
                        echo "$ip $host" >> "$INVENTORY"
                        dim "Также добавлено в инвентарь."
                    fi
                else
                    err "Некорректный IP."
                fi
            fi
        fi

        deploy_to_host "$host"
        pause
    done
}

# ============================================================
#  KNOWN_HOSTS
# ============================================================

clean_known_hosts() {
    header "Очистка known_hosts"
    if [ ! -f "$KNOWN_HOSTS" ]; then
        warn "Файл не найден: $KNOWN_HOSTS"
        return
    fi

    read -rp "Режим DRY-RUN (без изменений)? [y/N]: " dry
    local dry_run=0
    [[ "$dry" =~ ^[Yy]$ ]] && dry_run=1

    local temp
    temp="$(mktemp)"
    local total=0 kept=0 removed=0 hashed=0

    while IFS= read -r line; do
        if [ -z "$line" ] || [[ "$line" = \#* ]]; then
            echo "$line" >> "$temp"
            continue
        fi
        total=$((total + 1))

        if [[ "$line" = \|* ]]; then
            echo "$line" >> "$temp"
            kept=$((kept + 1)); hashed=$((hashed + 1))
            continue
        fi

        local field host port first
        field="$(echo "$line" | awk '{print $1}')"
        first="${field%%,*}"
        if [[ "$first" =~ ^\[(.+)\]:([0-9]+)$ ]]; then
            host="${BASH_REMATCH[1]}"
            port="${BASH_REMATCH[2]}"
        else
            host="$first"
            port="22"
        fi

        if ssh-keyscan -p "$port" -T "$SSH_TIMEOUT" -t rsa,ecdsa,ed25519 "$host" 2>/dev/null | grep -q .; then
            echo "$line" >> "$temp"
            kept=$((kept + 1))
            dim "= $host:$port — жив"
        else
            removed=$((removed + 1))
            if [ "$dry_run" -eq 1 ]; then
                err "- $host:$port — будет удалено (DRY-RUN)"
            else
                err "- $host:$port — удалено"
            fi
        fi
    done < "$KNOWN_HOSTS"

    echo ""
    hr
    info "Всего записей: $total"
    ok   "Оставлено: $kept"
    [ "$hashed" -gt 0 ] && dim "  хешированных (пропущено): $hashed"
    err  "Удалено: $removed"

    if [ "$dry_run" -eq 1 ] || [ "$removed" -eq 0 ]; then
        rm -f "$temp"
        [ "$dry_run" -eq 1 ] && info "Режим DRY-RUN: файл не изменён."
        [ "$removed" -eq 0 ] && [ "$dry_run" -eq 0 ] && ok "Нечего удалять."
        return
    fi

    local backup="$KNOWN_HOSTS.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$KNOWN_HOSTS" "$backup"
    dim "Резервная копия: $backup"

    mv "$temp" "$KNOWN_HOSTS"
    chmod 600 "$KNOWN_HOSTS"
    ok "Файл обновлён."
}

remove_known_host_entry() {
    header "Удаление конкретного хоста из known_hosts"
    if [ ! -f "$KNOWN_HOSTS" ]; then
        warn "Файл не найден: $KNOWN_HOSTS"
        return
    fi

    read -rp "Имя хоста или IP (пусто — отмена): " h
    [ -z "$h" ] && return

    local backup="$KNOWN_HOSTS.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$KNOWN_HOSTS" "$backup"
    dim "Резервная копия: $backup"

    if ssh-keygen -R "$h" -f "$KNOWN_HOSTS" 2>&1 | grep -qi "updated\|found"; then
        ok "Запись для '$h' удалена."
    else
        warn "Запись для '$h' не найдена."
    fi
}

# ============================================================
#  РЕЕСТР И ОТЧЁТ
# ============================================================

show_registry() {
    header "Реестр разложенных ключей"
    if [ ! -f "$REGISTRY" ] || [ ! -s "$REGISTRY" ]; then
        warn "Реестр пуст."
        return
    fi
    printf "${C_BOLD}%-25s %-15s %-8s %s %s${C_RESET}\n" "HOST" "USER" "ACTION" "WHEN" "FP"
    hr
    awk '{printf "%-25s %-15s %-8s %s %s %s\n", $1, $2, $3, $4, $5, $6}' "$REGISTRY"
}

show_report() {
    header "ИТОГИ"
    if [ -n "$ALREADY_LIST" ]; then
        echo "${C_BGREEN}Ключ уже был разложен ранее:${C_RESET}"
        printf "${C_GREEN}%b${C_RESET}" "$ALREADY_LIST"
        echo ""
    fi
    if [ -n "$ADDED_LIST" ]; then
        echo "${C_BGREEN}Ключ добавлен этим запуском:${C_RESET}"
        printf "${C_GREEN}%b${C_RESET}" "$ADDED_LIST"
        echo ""
        echo "${C_BOLD}Проверить подключение:${C_RESET}"
        printf "%b" "$ADDED_LIST" | while read -r line; do
            [ -z "$line" ] && continue
            local host user
            host="$(echo "$line" | awk '{print $2}')"
            user="$(echo "$line" | awk '{print $NF}')"
            [ -n "$host" ] && [ -n "$user" ] && echo "    ${C_CYAN}ssh $user@$host${C_RESET}"
        done
        echo ""
    fi
    if [ -n "$FAILED_LIST" ]; then
        echo "${C_BRED}Не удалось добавить ключ:${C_RESET}"
        printf "${C_RED}%b${C_RESET}" "$FAILED_LIST"
        echo ""
    fi
    if [ -n "$SKIPPED_LIST" ]; then
        echo "${C_BYELLOW}Пропущено:${C_RESET}"
        printf "${C_YELLOW}%b${C_RESET}" "$SKIPPED_LIST"
        echo ""
    fi
    if [ -z "$ALREADY_LIST$ADDED_LIST$FAILED_LIST$SKIPPED_LIST" ]; then
        dim "Ничего не сделано."
        echo ""
    fi
    hr
    dim "Реестр: $REGISTRY"
}

# ============================================================
#  ПОДМЕНЮ
# ============================================================

inventory_menu() {
    while true; do
        header "Инвентарь хостов"
        echo "  ${C_BOLD}1)${C_RESET} Показать инвентарь"
        echo "  ${C_BOLD}2)${C_RESET} Добавить хост вручную"
        echo "  ${C_BOLD}3)${C_RESET} Удалить хост"
        echo "  ${C_BOLD}4)${C_RESET} Импортировать из /etc/hosts"
        echo "  ${C_BOLD}5)${C_RESET} Обнаружить через DNS (AXFR)"
        echo "  ${C_BOLD}6)${C_RESET} Обнаружить локальным nmap"
        echo "  ${C_BOLD}7)${C_RESET} Обнаружить через mDNS (Avahi)"
        echo "  ${C_BOLD}8)${C_RESET} Обнаружить через удалённый хост"
        echo "  ${C_BOLD}0)${C_RESET} Назад"
        echo ""
        read -rp "Ваш выбор: " ic
        case "$ic" in
            1) inventory_show; pause ;;
            2) inventory_add; pause ;;
            3) inventory_remove; pause ;;
            4) inventory_import_from_hosts; pause ;;
            5) discover_from_dns_axfr; pause ;;
            6) discover_from_network_scan; pause ;;
            7) discover_from_mdns; pause ;;
            8) discover_via_remote_host; pause ;;
            0) return ;;
            *) err "Неверный выбор." ;;
        esac
    done
}

hosts_menu() {
    while true; do
        header "Синхронизация /etc/hosts"
        echo "  ${C_BOLD}1)${C_RESET} Из инвентаря (добавить недостающие)"
        echo "  ${C_BOLD}2)${C_RESET} Показать /etc/hosts удалённого хоста"
        echo "  ${C_BOLD}3)${C_RESET} Импорт с удалённого хоста (SSH)"
        echo "  ${C_BOLD}0)${C_RESET} Назад"
        echo ""
        read -rp "Ваш выбор: " sc
        case "$sc" in
            1) sync_hosts_from_inventory; pause ;;
            2) show_remote_hosts; pause ;;
            3) import_hosts_from_remote; pause ;;
            0) return ;;
            *) err "Неверный выбор." ;;
        esac
    done
}

# ============================================================
#  ГЛАВНОЕ МЕНЮ
# ============================================================

main_menu() {
    while true; do
        clear 2>/dev/null
        echo ""
        echo "${C_BCYAN}╔══════════════════════════════════════════╗${C_RESET}"
        echo "${C_BCYAN}║${C_RESET}  ${C_BOLD}${C_BBLUE}Домашняя SSH-инфраструктура${C_RESET}             ${C_BCYAN}║${C_RESET}"
        echo "${C_BCYAN}╚══════════════════════════════════════════╝${C_RESET}"
        if [ -n "$PUB_KEY" ] && [ -f "$PUB_KEY" ]; then
            printf "  ${C_DIM}Ключ:${C_RESET}      ${C_GREEN}%s${C_RESET}\n" "$PUB_KEY"
        else
            printf "  ${C_DIM}Ключ:${C_RESET}      ${C_YELLOW}(не выбран)${C_RESET}\n"
        fi
        printf "  ${C_DIM}Инвентарь:${C_RESET} %s ${C_DIM}(%s хостов)${C_RESET}\n" "$INVENTORY" "$(inventory_count)"
        hr
        echo ""
        echo "  ${C_BOLD}1)${C_RESET} Инвентарь хостов"
        echo "  ${C_BOLD}2)${C_RESET} Синхронизация ${C_CYAN}/etc/hosts${C_RESET}"
        echo "  ${C_BOLD}3)${C_RESET} Разослать ключ по хостам ${C_DIM}(инвентарь)${C_RESET}"
        echo "  ${C_BOLD}4)${C_RESET} Разослать ключ по хостам ${C_DIM}(/etc/hosts)${C_RESET}"
        echo "  ${C_BOLD}5)${C_RESET} Ввести хост вручную"
        echo "  ${C_BOLD}6)${C_RESET} Управление SSH-ключом"
        echo "  ${C_BOLD}7)${C_RESET} Очистить known_hosts"
        echo "  ${C_BOLD}8)${C_RESET} Удалить конкретный хост из known_hosts"
        echo "  ${C_BOLD}9)${C_RESET} Показать реестр"
        echo "  ${C_BOLD}10)${C_RESET} Показать итоги"
        echo "  ${C_BOLD}0)${C_RESET} Выход"
        echo ""
        read -rp "${C_BOLD}Ваш выбор:${C_RESET} " choice

        case "$choice" in
            1) inventory_menu ;;
            2) hosts_menu ;;
            3)
                ensure_key || { pause; continue; }
                deploy_menu_from_inventory
                ;;
            4)
                ensure_key || { pause; continue; }
                deploy_menu_from_hosts
                ;;
            5)
                ensure_key || { pause; continue; }
                deploy_manual
                ;;
            6) key_menu ;;
            7) clean_known_hosts; pause ;;
            8) remove_known_host_entry; pause ;;
            9) show_registry; pause ;;
            10) show_report; pause ;;
            0|q|Q)
                clear 2>/dev/null
                show_report
                echo ""
                echo "${C_BGREEN}До встречи!${C_RESET}"
                exit 0
                ;;
            *) err "Неверный выбор." ;;
        esac
    done
}

# ============================================================
#  АРГУМЕНТЫ И СТАРТ
# ============================================================

while getopts "k:u:t:h" opt; do
    case "$opt" in
        k) PUB_KEY="${OPTARG/#\~/$HOME}" ;;
        u) USER_ARG="$OPTARG" ;;
        t) SSH_TIMEOUT="$OPTARG" ;;
        h)
            cat <<EOF
Использование: $0 [опции]

  -k FILE    путь к публичному ключу
  -u USER    пользователь по умолчанию
  -t SEC     таймаут SSH (по умолчанию $SSH_TIMEOUT)
  -h         справка

Без аргументов запускается интерактивное меню.
EOF
            exit 0
            ;;
        *) echo "Используйте -h для справки."; exit 1 ;;
    esac
done

if ! command -v ssh-copy-id >/dev/null 2>&1; then
    err "ssh-copy-id не найден. Установите openssh-clients:"
    dim "sudo dnf install -y openssh-clients"
    exit 1
fi

ensure_dirs
main_menu
