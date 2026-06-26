#!/bin/bash

# ============================================================
#  ASTRA LINUX – Менеджер локального репозитория (ISO / CD-ROM)
# ============================================================

# Настройка кастомной темы для whiptail (TUI)
export NEWT_COLORS='
  root=white,gray
  window=white,lightgray
  border=black,lightgray
  shadow=white,black
  button=black,green
  actbutton=black,red
  compactbutton=black,
  title=black,
  roottext=black,magenta
  textbox=black,lightgray
  acttextbox=gray,white
  entry=lightgray,gray
  disentry=gray,lightgray
  checkbox=black,lightgray
  actcheckbox=black,green
  emptyscale=,black
  fullscale=,red
  listbox=black,lightgray
  actlistbox=lightgray,gray
  actsellistbox=black,green
'

if [[ "$EUID" -ne 0 ]]; then
    whiptail --title "Ошибка" --msgbox "Ошибка: этот модуль должен запускаться от имени root (sudo)." 8 58
    exit 1
fi

MOUNT_POINT="/media/astra_iso"

# Определение кодового имени системы по умолчанию
if [[ -f "/etc/astra_version" ]]; then
    VER_DETECTED=$(cat /etc/astra_version | grep -oE "1\.[0-9]" | head -n 1)
    [[ -n "$VER_DETECTED" ]] && CODENAME="${VER_DETECTED}_x86-64"
fi
CODENAME=${CODENAME:-"1.8_x86-64"} # Резервное значение

# Логирование во временный файл
LOG_FILE="/tmp/repo_manager.log"
echo "=== Сбор логов репозитория ===" > "$LOG_FILE"

log_ok() { echo -e "  [ OK ] $1" >> "$LOG_FILE"; }
log_info() { echo -e "  [ -- ] $1" >> "$LOG_FILE"; }
log_err() { echo -e "  [ !! ] $1" >> "$LOG_FILE"; }

disable_internet_repos() {
    log_info "Временное отключение сетевых репозиториев..."
    cp -n /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null
    sed -i -E 's/^([[:space:]]*deb(-src)?[[:space:]]+(\[[^\]]+\][[:space:]]+)?https?:\/\/)/# OFFLINE_DISABLED: \1/g' /etc/apt/sources.list
    
    local list_file
    for list_file in /etc/apt/sources.list.d/*.list; do
        if [[ -f "$list_file" ]]; then
            cp -n "$list_file" "${list_file}.bak" 2>/dev/null
            sed -i -E 's/^([[:space:]]*deb(-src)?[[:space:]]+(\[[^\]]+\][[:space:]]+)?https?:\/\/)/# OFFLINE_DISABLED: \1/g' "$list_file"
        fi
    done
    log_ok "Сетевые репозитории временно отключены."
}

enable_internet_repos() {
    log_info "Восстановление сетевых репозиториев..."
    sed -i -E 's/^# OFFLINE_DISABLED: ([[:space:]]*deb(-src)?[[:space:]]+(\[[^\]]+\][[:space:]]+)?https?:\/\/)/\1/g' /etc/apt/sources.list
    
    local list_file
    for list_file in /etc/apt/sources.list.d/*.list; do
        if [[ -f "$list_file" ]]; then
            sed -i -E 's/^# OFFLINE_DISABLED: ([[:space:]]*deb(-src)?[[:space:]]+(\[[^\]]+\][[:space:]]+)?https?:\/\/)/\1/g' "$list_file"
        fi
    done
    log_ok "Сетевые репозитории восстановлены."
}

mount_iso_simple() {
    local manual_iso
    manual_iso=$(whiptail --title "Подключение репозитория" \
                          --inputbox "Введите путь к ISO-файлу (или оставьте пустым для автопоиска CD-ROM):" \
                          10 60 \
                          3>&1 1>&2 2>&3)
                          
    if [ $? -ne 0 ]; then
        return 0
    fi
    
    {
        # Сохраняем FD 1 (пайп к whiptail) в FD 3
        exec 3>&1
        
        # Перенаправляем стандартный вывод и ошибки в лог-файл
        exec > "$LOG_FILE" 2>&1
        
        echo "XXX" >&3
        echo 10 >&3
        echo "Поиск устройства или ISO-файла..." >&3
        echo "XXX" >&3
        
        local is_auto=0
        if [[ -z "$manual_iso" ]]; then
            is_auto=1
            CD_DEV=$(lsblk -do NAME,TYPE | grep -E "rom|cd" | awk '{print "/dev/"$1}' | head -n 1)
            if [[ -z "$CD_DEV" ]]; then
                log_err "Устройство CD-ROM не найдено в системе."
                echo "error_cd" > /tmp/repo_status
                return 1
            fi
            manual_iso="$CD_DEV"
            log_info "Автоматически найдено устройство: $manual_iso"
        else
            if [[ ! -e "$manual_iso" ]]; then
                log_err "Файл или устройство '$manual_iso' не найдено."
                echo "error_path" > /tmp/repo_status
                return 1
            fi
        fi

        echo "XXX" >&3
        echo 30 >&3
        echo "Монтирование $manual_iso..." >&3
        echo "XXX" >&3

        mkdir -p "$MOUNT_POINT"
        if ! mountpoint -q "$MOUNT_POINT"; then
            log_info "Монтирование $manual_iso в $MOUNT_POINT..."
            if ! mount "$manual_iso" "$MOUNT_POINT" 2>/dev/null; then
                if ! mount -o loop "$manual_iso" "$MOUNT_POINT" 2>/dev/null; then
                    log_err "Не удалось смонтировать $manual_iso"
                    if [[ $is_auto -eq 1 ]]; then
                        echo "error_auto_mount" > /tmp/repo_status
                    else
                        echo "error_mount" > /tmp/repo_status
                    fi
                    return 1
                fi
            fi
            log_ok "Успешно смонтировано."
        else
            log_info "Точка монтирования $MOUNT_POINT уже занята."
        fi

        echo "XXX" >&3
        echo 50 >&3
        echo "Настройка репозитория в sources.list..." >&3
        echo "XXX" >&3

        local detected_code=$(ls "$MOUNT_POINT/dists" 2>/dev/null | head -n 1)
        if [[ -n "$detected_code" ]]; then
            CODENAME="$detected_code"
            log_info "На диске обнаружен дистрибутив: $CODENAME"
        fi

        local repo_line="deb [trusted=yes] file:$MOUNT_POINT $CODENAME main contrib non-free"
        if ! grep -qxF "$repo_line" /etc/apt/sources.list; then
            echo -e "\n# Astra Linux ISO Repository\n$repo_line" >> /etc/apt/sources.list
            log_ok "Запись репозитория добавлена в /etc/apt/sources.list"
        else
            log_info "Запись репозитория уже существует in /etc/apt/sources.list"
        fi

        [[ -f "/etc/apt/sources.list.d/astra_iso_simple.list" ]] && rm -f "/etc/apt/sources.list.d/astra_iso_simple.list"

        disable_internet_repos

        echo "XXX" >&3
        echo 70 >&3
        echo "Обновление списков пакетов APT (это может занять время)..." >&3
        echo "XXX" >&3

        log_info "Обновление списка пакетов APT..."
        if apt-get update >> "$LOG_FILE" 2>&1; then
            log_ok "Список пакетов обновлен."
            echo "success" > /tmp/repo_status
        else
            log_err "Ошибка обновления пакетов."
            echo "error_update" > /tmp/repo_status
        fi
        
        echo "XXX" >&3
        echo 100 >&3
        echo "Успешно завершено" >&3
        echo "XXX" >&3
    } | whiptail --gauge "Подключение репозитория..." 10 70 0
    
    local status
    status=$(cat /tmp/repo_status 2>/dev/null)
    rm -f /tmp/repo_status
    
    if [ "$status" = "success" ]; then
        whiptail --title "Успех" --msgbox "Локальный репозиторий успешно подключен!\nСетевые репозитории временно отключены.\n\nЛог сохранен в: $LOG_FILE" 12 65
    elif [ "$status" = "error_cd" ] || [ "$status" = "error_auto_mount" ]; then
        whiptail --title "Ошибка" --msgbox "Ошибка: Штатный диск Astra Linux не найден автоматически в устройстве CD-ROM. Вставьте диск или укажите путь к ISO-образу вручную." 10 70
    elif [ "$status" = "error_path" ]; then
        whiptail --title "Ошибка" --msgbox "Ошибка: Указанный файл или устройство не найдено." 8 58
    elif [ "$status" = "error_mount" ]; then
        whiptail --title "Ошибка" --msgbox "Ошибка: Не удалось смонтировать образ. Убедитесь, что указан корректный путь к ISO." 10 58
    else
        whiptail --title "Ошибка" --msgbox "Ошибка обновления списков APT. Проверьте лог в:\n$LOG_FILE" 10 58
    fi
}

unmount_iso_simple() {
    {
        # Сохраняем FD 1 (пайп к whiptail) в FD 3
        exec 3>&1
        
        # Перенаправляем стандартный вывод и ошибки в лог-файл
        exec > "$LOG_FILE" 2>&1
        
        echo "XXX" >&3
        echo 20 >&3
        echo "Отключение репозитория в sources.list..." >&3
        echo "XXX" >&3
        
        if grep -q "file:$MOUNT_POINT" /etc/apt/sources.list 2>/dev/null; then
            sed -i '\@file:'"$MOUNT_POINT"'@d' /etc/apt/sources.list
            sed -i '/# Astra Linux ISO Repository/d' /etc/apt/sources.list
            log_ok "Запись репозитория удалена из /etc/apt/sources.list"
        fi

        echo "XXX" >&3
        echo 50 >&3
        echo "Размонтирование $MOUNT_POINT..." >&3
        echo "XXX" >&3
        
        if mountpoint -q "$MOUNT_POINT"; then
            if umount "$MOUNT_POINT" 2>/dev/null; then
                log_ok "Успешно размонтировано."
            else
                log_err "Не удалось размонтировать $MOUNT_POINT"
            fi
        fi

        echo "XXX" >&3
        echo 70 >&3
        echo "Восстановление сетевых репозиториев..." >&3
        echo "XXX" >&3
        
        enable_internet_repos
        
        echo "XXX" >&3
        echo 90 >&3
        echo "Обновление списков пакетов APT..." >&3
        echo "XXX" >&3
        
        apt-get update >> "$LOG_FILE" 2>&1
        
        echo "XXX" >&3
        echo 100 >&3
        echo "Успешно завершено" >&3
        echo "XXX" >&3
    } | whiptail --gauge "Отключение репозитория..." 10 70 0
    
    whiptail --title "Успех" --msgbox "Локальный репозиторий отключен.\nСетевые репозитории восстановлены." 10 58
}

default_choice="Подключить локальный репозиторий (ISO/диск)"
while true; do
    choice=$(whiptail --title "Менеджер репозиториев Astra" \
                      --cancel-button "Назад" \
                      --default-item "$default_choice" \
                      --menu "   ───┤ Управление: ↑/↓ - переход, Enter - выбор, Tab - кнопки ├───\n\nВыберите действие:" \
                      18 76 2 \
                      "Подключить локальный репозиторий (ISO/диск)" "" \
                      "Отключить локальный репозиторий" "" \
                      3>&1 1>&2 2>&3)
                      
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        break
    fi
    
    default_choice="$choice"
    
    case "$choice" in
        "Подключить локальный репозиторий (ISO/диск)") mount_iso_simple ;;
        "Отключить локальный репозиторий") unmount_iso_simple ;;
    esac
done

exit 0
