#!/bin/bash
# ============================================================
#               УСТАНОВКА АНТИВИРУСНОГО ПО
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

if [ "$EUID" -ne 0 ]; then
    whiptail --title "Ошибка" --msgbox "Ошибка: Этот скрипт должен быть запущен от root (sudo)." 8 58
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Функция определения пакетного менеджера хоста (deb или rpm)
detect_pkg_type() {
    if command -v dpkg >/dev/null 2>&1; then
        echo "deb"
    elif command -v rpm >/dev/null 2>&1; then
        echo "rpm"
    else
        echo "unknown"
    fi
}

# Функция быстрого поиска корней примонтированных накопителей и папки проекта
find_antivirus_roots() {
    local search_paths=("$ROOT_DIR")
    
    # 1. Точки монтирования из /proc/mounts
    if [ -f /proc/mounts ]; then
        while read -r dev mnt fstype opt; do
            # Исключаем виртуальные и системные папки
            if [[ "$mnt" =~ ^/(sys|proc|dev|run|snap|boot|var/lib/snapd) ]]; then
                continue
            fi
            if [ -d "$mnt" ]; then
                search_paths+=("$mnt")
            fi
        done < /proc/mounts
    fi
    
    # 2. Папки первого/второго уровня в стандартных путях монтирования
    for parent in /media /run/media /mnt; do
        if [ -d "$parent" ]; then
            while IFS= read -r sub; do
                if [ -d "$sub" ] && [ "$sub" != "$parent" ]; then
                    search_paths+=("$sub")
                fi
            done < <(find "$parent" -maxdepth 2 -type d 2>/dev/null)
        fi
    done
    
    # Возвращаем все уникальные существующие пути
    printf "%s\n" "${search_paths[@]}" | sort -u
}

# Функция поиска файлов установки Dr.Web по именам файлов в корнях (без привязки к имени папки)
find_drweb_installers() {
    local roots=("$@")
    local found_files=()
    
    # Определение архитектуры
    local arch=$(uname -m)
    local drweb_arch="amd64"
    case "$arch" in
        x86_64) drweb_arch="amd64" ;;
        aarch64|arm64) drweb_arch="arm64" ;;
        i386|i686) drweb_arch="x86" ;;
    esac
    
    for r in "${roots[@]}"; do
        if [ ! -d "$r" ]; then
            continue
        fi
        while IFS= read -r f; do
            if [ -f "$f" ]; then
                found_files+=("$f")
            fi
        done < <(find "$r" -maxdepth 4 -type f \( -name "drweb-workstations_*~linux_${drweb_arch}.run" -o -name "drweb-file-servers_*~linux_${drweb_arch}.run" \) 2>/dev/null)
    done
    
    if [ ${#found_files[@]} -gt 0 ]; then
        printf "%s\n" "${found_files[@]}" | sort -u
    fi
}

# Функция поиска файлов установки KESL по именам файлов (без привязки к имени папки)
find_kesl_installers() {
    local pkg_type="$1"
    shift
    local roots=("$@")
    local found_pairs=()
    
    local base_pattern=""
    local gui_pattern=""
    local arch=$(uname -m)
    
    if [ "$pkg_type" = "deb" ]; then
        local deb_arch="amd64"
        case "$arch" in
            x86_64) deb_arch="amd64" ;;
            aarch64|arm64) deb_arch="arm64" ;;
            i386|i686) deb_arch="i386" ;;
        esac
        base_pattern="kesl_*_${deb_arch}.deb"
        gui_pattern="kesl-gui_*_${deb_arch}.deb"
    else
        local rpm_arch="x86_64"
        case "$arch" in
            x86_64) rpm_arch="x86_64" ;;
            i386|i686) rpm_arch="i386" ;;
        esac
        base_pattern="kesl-*.${rpm_arch}.rpm"
        gui_pattern="kesl-gui-*.${rpm_arch}.rpm"
    fi
    
    for r in "${roots[@]}"; do
        if [ ! -d "$r" ]; then
            continue
        fi
        while IFS= read -r base_pkg; do
            if [ -f "$base_pkg" ]; then
                local dir=$(dirname "$base_pkg")
                local gui_pkg=""
                
                # Ищем GUI пакет в той же папке или во вложенной папке gui/ (до глубины 2 от dir)
                gui_pkg=$(find "$dir" -maxdepth 2 -type f -name "$gui_pattern" 2>/dev/null | head -n 1)
                
                found_pairs+=("${base_pkg}|${gui_pkg}")
            fi
        done < <(find "$r" -maxdepth 4 -type f -name "$base_pattern" 2>/dev/null)
    done
    
    if [ ${#found_pairs[@]} -gt 0 ]; then
        printf "%s\n" "${found_pairs[@]}" | sort -u
    fi
}

# Функция поиска папок баз в соответствии с примонтированными путями
find_bases_folders() {
    local av_type="$1"
    shift
    local roots=("$@")
    local found_dirs=()
    
    for r in "${roots[@]}"; do
        if [ ! -d "$r" ]; then
            continue
        fi
        
        # Сканируем корни на наличие папок bases, update, updates (без учета регистра)
        while IFS= read -r d; do
            if [ -d "$d" ]; then
                # Проверим, что внутри есть файлы (чтобы исключить пустые каталоги)
                if [ -n "$(ls -A "$d" 2>/dev/null)" ]; then
                    # Проверяем, есть ли .vdb файлы в этой папке (признак Dr.Web)
                    local is_drweb=0
                    if find "$d" -maxdepth 2 -type f -name "*.vdb" 2>/dev/null | grep -q "."; then
                        is_drweb=1
                    fi
                    
                    if [ "$av_type" = "drweb" ] && [ $is_drweb -eq 1 ]; then
                        found_dirs+=("$d")
                    elif [ "$av_type" = "kesl" ] && [ $is_drweb -eq 0 ]; then
                        # Дополнительно убедимся, что путь не содержит "drweb" или "dr.web", на случай если папка пуста от vdb, но является частью drweb
                        local lower_path=$(echo "$d" | tr '[:upper:]' '[:lower:]')
                        if [[ "$lower_path" != *"drweb"* ]] && [[ "$lower_path" != *"dr.web"* ]]; then
                            found_dirs+=("$d")
                        fi
                    fi
                fi
            fi
        done < <(find "$r" -maxdepth 4 -type d \( -iname "bases" -o -iname "update" -o -iname "updates" \) 2>/dev/null)
    done
    
    if [ ${#found_dirs[@]} -gt 0 ]; then
        printf "%s\n" "${found_dirs[@]}" | sort -u
    fi
}

# Диалог ввода пути для копирования баз
ask_local_update_dir() {
    local default_path="/home/bases/update"
    local chosen_path
    
    chosen_path=$(whiptail --title "Локальная папка для копирования баз" \
                           --inputbox "Введите абсолютный путь к папке, куда будут скопированы базы для обновления:" \
                           10 70 "$default_path" \
                           3>&1 1>&2 2>&3)
                           
    if [ $? -ne 0 ] || [ -z "$chosen_path" ]; then
        echo ""
    else
        echo "$chosen_path"
    fi
}

# Функция проверки доступности интернета
check_internet() {
    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        if curl -s -I --connect-timeout 3 https://dnl-3.geo.kaspersky.com >/dev/null 2>&1; then
            return 0
        fi
    fi
    return 1
}

# Функция обработки оффлайн режима для APT
handle_offline_apt_fallback() {
    local pkg_type
    pkg_type=$(detect_pkg_type)
    if [ "$pkg_type" != "deb" ]; then
        return 0
    fi

    if ! check_internet; then
        # Проверяем, есть ли активные сетевые репозитории
        local has_active_net_repos=0
        if grep -E "^[[:space:]]*deb[[:space:]]+(\[[^\]]+\][[:space:]]+)?https?://" /etc/apt/sources.list &>/dev/null; then
            has_active_net_repos=1
        fi
        local list_file
        for list_file in /etc/apt/sources.list.d/*.list; do
            if [ -f "$list_file" ]; then
                if grep -E "^[[:space:]]*deb[[:space:]]+(\[[^\]]+\][[:space:]]+)?https?://" "$list_file" &>/dev/null; then
                    has_active_net_repos=1
                fi
            fi
        done

        if [ "$has_active_net_repos" -eq 1 ]; then
            whiptail --title "Отсутствует подключение к интернету" \
                     --yes-button "Подключить ISO" \
                     --no-button "Отключить сеть" \
                     --yesno "Обнаружено отсутствие интернета. В системе активны сетевые\nрепозитории, что вызовет долгое зависание при работе APT.\n\nХотите ли вы сейчас подключить локальный репозиторий\n(Astra Linux ISO/CD-ROM)?" 12 70
            local res=$?
            if [ $res -eq 0 ]; then
                # Запускаем менеджер локального репозитория
                if [ -f "$SCRIPT_DIR/repo_manager.sh" ]; then
                    chmod +x "$SCRIPT_DIR/repo_manager.sh"
                    "$SCRIPT_DIR/repo_manager.sh"
                else
                    whiptail --title "Ошибка" --msgbox "Скрипт repo_manager.sh не найден!" 8 58
                fi
            else
                # Временно отключаем сетевые репозитории
                whiptail --title "Отключение сетевых репозиториев" \
                         --msgbox "Сетевые репозитории будут временно отключены для\nпредотвращения зависания. Они будут автоматически\nвосстановлены после завершения установки." 10 65
                
                # Создаем резервную копию и комментируем сетевые репозитории
                cp -n /etc/apt/sources.list /etc/apt/sources.list.bak 2>/dev/null
                sed -i -E 's/^([[:space:]]*deb(-src)?[[:space:]]+(\[[^\]]+\][[:space:]]+)?https?:\/\/)/# TEMP_OFFLINE_DISABLED: \1/g' /etc/apt/sources.list
                
                for list_file in /etc/apt/sources.list.d/*.list; do
                    if [ -f "$list_file" ]; then
                        cp -n "$list_file" "${list_file}.bak" 2>/dev/null
                        sed -i -E 's/^([[:space:]]*deb(-src)?[[:space:]]+(\[[^\]]+\][[:space:]]+)?https?:\/\/)/# TEMP_OFFLINE_DISABLED: \1/g' "$list_file"
                    fi
                done
                
                touch /tmp/temp_repos_disabled
            fi
        fi
    fi
}

# Функция восстановления временно отключенных репозиториев
restore_temp_disabled_repos() {
    if [ -f /tmp/temp_repos_disabled ]; then
        sed -i -E 's/^# TEMP_OFFLINE_DISABLED: ([[:space:]]*deb(-src)?[[:space:]]+(\[[^\]]+\][[:space:]]+)?https?:\/\/)/\1/g' /etc/apt/sources.list
        
        local list_file
        for list_file in /etc/apt/sources.list.d/*.list; do
            if [ -f "$list_file" ]; then
                sed -i -E 's/^# TEMP_OFFLINE_DISABLED: ([[:space:]]*deb(-src)?[[:space:]]+(\[[^\]]+\][[:space:]]+)?https?:\/\/)/\1/g' "$list_file"
            fi
        done
        rm -f /tmp/temp_repos_disabled
    fi
}

# Вспомогательные функции для обновления прогресса whiptail --gauge
update_install_progress() {
    local percent="$1"
    local msg="$2"
    echo "XXX" >&3 2>/dev/null || true
    echo "$percent" >&3 2>/dev/null || true
    echo "$msg" >&3 2>/dev/null || true
    echo "XXX" >&3 2>/dev/null || true
}

update_install_msg() {
    local msg="$1"
    echo "XXX" >&3 2>/dev/null || true
    echo "$msg" >&3 2>/dev/null || true
    echo "XXX" >&3 2>/dev/null || true
}

# Вспомогательная функция автонастройки KESL
configure_kesl_if_needed() {
    if [ -f "/opt/kaspersky/kesl/bin/kesl-setup.pl" ]; then
        update_install_msg "Настройка Kaspersky Endpoint Security..."
        
        local updater_source="https://dnl-3.geo.kaspersky.com"
        if ! check_internet; then
            updater_source="/home/bases/update"
            mkdir -p "$updater_source"
        fi
        
        local use_gui="no"
        if [ -f "/opt/kaspersky/kesl/libexec/kesl-gui" ] || dpkg -s kesl-gui >/dev/null 2>&1 || rpm -q kesl-gui >/dev/null 2>&1; then
            use_gui="yes"
        fi
        
        local ini_file="/tmp/kesl_autoinstall.ini"
        cat <<EOF > "$ini_file"
EULA_AGREED=yes
PRIVACY_POLICY_AGREED=yes
USE_KSN=no
UPDATER_SOURCE=$updater_source
PROXY_USAGE=no
SERVICE_LOCALE=ru_RU.UTF-8
GROUP_CLEAN=no
USE_GUI=$use_gui
UPDATE_EXECUTE=no
EOF
        /opt/kaspersky/kesl/bin/kesl-setup.pl --autoinstall="$ini_file" 3>&-
        local code=$?
        echo "Код настройки kesl-setup.pl: $code"
        rm -f "$ini_file"
    fi
}

# Функция установки пакетов через Whiptail Gauge TUI
install_pkg() {
    local name="$1"
    shift
    local files=("$@")
    local log_file="/tmp/antivirus_install.log"

    # Проверяем доступность интернета и обрабатываем оффлайн режим перед началом установки
    handle_offline_apt_fallback
    
    echo "=== Запуск установки $name ===" > "$log_file"
    chmod 666 "$log_file" 2>/dev/null || true
    if [ -n "$SUDO_USER" ]; then
        chown "$SUDO_USER:" "$log_file" 2>/dev/null || true
    fi
    echo "Список пакетов для установки:" >> "$log_file"
    for f in "${files[@]}"; do
        echo "  - $f" >> "$log_file"
    done
    echo "Дата запуска: $(date)" >> "$log_file"
    echo "----------------------------------------" >> "$log_file"

    local status_file="/tmp/install_status"
    echo "1" > "$status_file"

    {
        exec 3>&1
        exec >> "$log_file" 2>&1

        update_install_progress "15" "Проверка конфигурации перед установкой..."
        
        # Если ставится Kaspersky, лечим незавершенную установку
        if [[ "$name" == *"Kaspersky"* ]]; then
            configure_kesl_if_needed
        fi

        update_install_progress "25" "Распаковка и установка пакетов..."
        
        # Разделяем запуск по типу
        local deb_files=()
        local rpm_files=()
        local run_files=()
        for f in "${files[@]}"; do
            if [[ "$f" == *.deb ]]; then
                deb_files+=("$f")
            elif [[ "$f" == *.rpm ]]; then
                rpm_files+=("$f")
            elif [[ "$f" == *.run ]]; then
                run_files+=("$f")
            fi
        done

        if [ ${#deb_files[@]} -gt 0 ]; then
            # Разделяем на базовые deb и GUI deb для исключения проблем с предзависимостями (Pre-Depends)
            local base_debs=()
            local gui_debs=()
            for df in "${deb_files[@]}"; do
                if [[ "$(basename "$df")" == *gui* ]]; then
                    gui_debs+=("$df")
                else
                    base_debs+=("$df")
                fi
            done

            if [ ${#base_debs[@]} -gt 0 ]; then
                dpkg -i "${base_debs[@]}" 3>&-
                local code=$?
                echo "Код возврата dpkg (base): $code"
                
                update_install_progress "55" "Разрешение зависимостей базовых пакетов через APT..."
                apt-get install -f -y 3>&-
                echo "Код возврата apt-get -f (base): $?"
            fi

            # Если ставится Kaspersky, после базового пакета запускаем настройку
            if [[ "$name" == *"Kaspersky"* ]]; then
                configure_kesl_if_needed
            fi

            if [ ${#gui_debs[@]} -gt 0 ]; then
                update_install_progress "65" "Установка графического интерфейса (GUI)..."
                
                dpkg -i "${gui_debs[@]}" 3>&-
                local code=$?
                echo "Код возврата dpkg (gui): $code"
                
                update_install_progress "75" "Разрешение зависимостей GUI пакетов через APT..."
                apt-get install -f -y 3>&-
                echo "Код возврата apt-get -f (gui): $?"
            fi
            
            # Финальная конфигурация после установки GUI
            if [[ "$name" == *"Kaspersky"* ]]; then
                configure_kesl_if_needed
            fi
        fi

        if [ ${#rpm_files[@]} -gt 0 ]; then
            update_install_progress "50" "Установка RPM пакетов..."
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y "${rpm_files[@]}" 3>&-
                echo "Код возврата dnf: $?"
            elif command -v yum >/dev/null 2>&1; then
                yum localinstall -y "${rpm_files[@]}" 3>&-
                echo "Код возврата yum: $?"
            elif command -v rpm >/dev/null 2>&1; then
                rpm -ivh "${rpm_files[@]}" 3>&-
                echo "Код возврата rpm: $?"
            else
                echo "Ошибка: Не найден пакетный менеджер для RPM (dnf/yum/rpm)."
            fi
            
            # Финальная конфигурация для RPM
            if [[ "$name" == *"Kaspersky"* ]]; then
                configure_kesl_if_needed
            fi
        fi

        for rf in "${run_files[@]}"; do
            update_install_progress "80" "Запуск установщика $rf..."
            chmod +x "$rf"
            "$rf" -- --non-interactive 3>&-
            echo "Код возврата запуска (.run): $?"
        done
        
        # Проверяем успешность установки перед выходом из subshell
        local installed=0
        if [[ "$name" == *"Kaspersky"* ]] && { command -v kesl-control &>/dev/null || [ -f "/opt/kaspersky/kesl/bin/kesl-control" ]; }; then
            installed=1
        elif [[ "$name" == *"Dr.Web"* ]] && { command -v drweb-ctl &>/dev/null || [ -f "/opt/drweb.com/bin/drweb-ctl" ] || [ -f "/opt/drweb/bin/drweb-ctl" ] || [ -f "/usr/bin/drweb-ctl" ] || [ -f "/usr/local/bin/drweb-ctl" ]; }; then
            installed=1
        fi
        
        if [ $installed -eq 1 ]; then
            echo "0" > "$status_file"
            update_install_progress "100" "Установка успешно завершена!"
        else
            echo "Ошибка: исполняемые файлы антивируса не найдены после установки."
            update_install_progress "100" "Ошибка установки!"
        fi
    } | whiptail --gauge "Установка $name..." 10 70 0 3>&-

    local exit_status=1
    if [ -f "$status_file" ]; then
        exit_status=$(cat "$status_file")
        rm -f "$status_file"
    fi

    # Восстановление сетевых репозиториев, если они были временно отключены
    restore_temp_disabled_repos

    if [ "$exit_status" -eq 0 ]; then
        whiptail --title "Успех" --msgbox "Установка $name успешно завершена!" 8 60
    else
        whiptail --title "Ошибка установки" --textbox "$log_file" 20 76
    fi


    # Опрос статуса службы после установки
    local service_name=""
    if [[ "$name" == *"Kaspersky"* ]]; then
        service_name="kesl"
    elif [[ "$name" == *"Dr.Web"* ]]; then
        service_name="drweb-configd"
    fi

    if [[ -n "$service_name" ]]; then
        whiptail --title "Проверка службы" \
                 --yes-button "Проверить службу" \
                 --no-button "В меню" \
                 --yesno "Установка завершена. Хотите проверить статус системной службы $service_name?" 10 70
        if [ $? -eq 0 ]; then
            local status_log="/tmp/antivirus_service_status.log"
            echo "=== Статус службы $service_name ===" > "$status_log"
            echo "Дата проверки: $(date)" >> "$status_log"
            echo "----------------------------------------" >> "$status_log"
            systemctl status "$service_name" >> "$status_log" 2>&1
            
            whiptail --title "Статус службы $service_name" --textbox "$status_log" 20 76
            rm -f "$status_log"
        fi
    fi
}

# Обработчик установки Kaspersky Endpoint Security
handle_kesl_install() {
    local pkg_type
    pkg_type=$(detect_pkg_type)
    if [ "$pkg_type" = "unknown" ]; then
        whiptail --title "Ошибка" --msgbox "Ошибка: Не удалось определить пакетный менеджер (dpkg или rpm не найдены)." 8 60
        return 1
    fi
    
    local roots=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            roots+=("$line")
        fi
    done < <(find_antivirus_roots)
    
    if [ ${#roots[@]} -eq 0 ]; then
        whiptail --title "Ошибка" --msgbox "Ошибка: Папка KESL не найдена на примонтированных дисках или в проекте." 8 68
        return 1
    fi
    
    local found_pairs=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            found_pairs+=("$line")
        fi
    done < <(find_kesl_installers "${pkg_type}" "${roots[@]}")
    
    if [ ${#found_pairs[@]} -eq 0 ]; then
        whiptail --title "Ошибка" --msgbox "Ошибка: Установочные пакеты KESL для текущей архитектуры не найдены в директориях KESL/." 9 68
        return 1
    fi
    
    local selected_pair=""
    if [ ${#found_pairs[@]} -eq 1 ]; then
        selected_pair="${found_pairs[0]}"
    else
        # Показываем меню выбора источника
        local menu_args=()
        local idx=1
        for pair in "${found_pairs[@]}"; do
            local base_pkg=$(echo "$pair" | cut -d'|' -f1)
            local relative_path="${base_pkg#$ROOT_DIR}"
            if [ "$relative_path" != "$base_pkg" ]; then
                menu_args+=("$idx" "Проект: $(basename "$base_pkg")")
            else
                local mnt_name=$(basename "$(dirname "$(dirname "$base_pkg")")")
                menu_args+=("$idx" "$mnt_name: $(basename "$base_pkg")")
            fi
            ((idx++))
        done
        
        local choice
        choice=$(whiptail --title "Выберите источник установки KESL" \
                          --menu "Найдено несколько источников. Выберите один:" \
                          15 100 6 \
                          "${menu_args[@]}" \
                          3>&1 1>&2 2>&3)
        if [ $? -ne 0 ] || [ -z "$choice" ]; then
            return 1
        fi
        
        selected_pair="${found_pairs[$((choice-1))]}"
    fi
    
    local base_pkg=$(echo "$selected_pair" | cut -d'|' -f1)
    local gui_pkg=$(echo "$selected_pair" | cut -d'|' -f2)
    
    # Формируем список для установки
    local install_files=("$base_pkg")
    local install_gui=0
    
    if [ -n "$gui_pkg" ]; then
        whiptail --title "Обнаружен GUI-интерфейс" \
                 --yesno "Для Kaspersky Endpoint Security обнаружен пакет GUI:\n  - $(basename "$gui_pkg")\n\nЖелаете установить графический интерфейс совместно с антивирусом?" 12 70
        if [ $? -eq 0 ]; then
            install_gui=1
            install_files+=("$gui_pkg")
        fi
    fi
    
    # Подтверждение установки
    local files_str="Будут установлены следующие пакеты:\n"
    for f in "${install_files[@]}"; do
        files_str+="  - $(basename "$f")\n"
    done
    
    whiptail --title "Подтверждение установки KESL" \
             --yesno "$files_str\nЖелаете начать установку?" 14 74
    if [ $? -eq 0 ]; then
        install_pkg "Kaspersky Endpoint Security" "${install_files[@]}"
    fi
}

# Обработчик установки Dr.Web Security Space
handle_drweb_install() {
    local roots=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            roots+=("$line")
        fi
    done < <(find_antivirus_roots)
    
    if [ ${#roots[@]} -eq 0 ]; then
        whiptail --title "Ошибка" --msgbox "Ошибка: Папка dr.web не найдена на примонтированных дисках или в проекте." 8 68
        return 1
    fi
    
    local found_files=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            found_files+=("$line")
        fi
    done < <(find_drweb_installers "${roots[@]}")
    
    if [ ${#found_files[@]} -eq 0 ]; then
        whiptail --title "Ошибка" --msgbox "Ошибка: Установочные пакеты Dr.Web (.run) для текущей архитектуры не найдены в директориях dr.web/files/." 9 72
        return 1
    fi
    
    local selected_file=""
    if [ ${#found_files[@]} -eq 1 ]; then
        selected_file="${found_files[0]}"
    else
        # Показываем меню выбора файла
        local menu_args=()
        local idx=1
        for f in "${found_files[@]}"; do
            local relative_path="${f#$ROOT_DIR}"
            if [ "$relative_path" != "$f" ]; then
                menu_args+=("$idx" "Проект: $(basename "$f")")
            else
                local mnt_name=$(basename "$(dirname "$(dirname "$(dirname "$f")")")")
                menu_args+=("$idx" "$mnt_name: $(basename "$f")")
            fi
            ((idx++))
        done
        
        local choice
        choice=$(whiptail --title "Выберите пакет Dr.Web для установки" \
                          --menu "Найдено несколько пакетов Dr.Web. Выберите один:" \
                          15 100 6 \
                          "${menu_args[@]}" \
                          3>&1 1>&2 2>&3)
        if [ $? -ne 0 ] || [ -z "$choice" ]; then
            return 1
        fi
        
        selected_file="${found_files[$((choice-1))]}"
    fi
    
    # Подтверждение установки
    whiptail --title "Подтверждение установки Dr.Web" \
             --yesno "Будет установлен следующий пакет:\n  - $(basename "$selected_file")\n\nЖелаете начать установку?" 12 70
    if [ $? -eq 0 ]; then
        install_pkg "Dr.Web Security Space" "$selected_file"
    fi
}

# Функция получения описания кода ошибки Kaspersky
get_kesl_error_desc() {
    local code="$1"
    case "$code" in
        0) echo "Успешно завершено." ;;
        1) echo "Общая ошибка в аргументах команды." ;;
        2) echo "Ошибка в переданных настройках приложения." ;;
        64) echo "Служба Kaspersky Endpoint Security не запущена." ;;
        65) echo "Задача обновления не найдена." ;;
        66) echo "Базы приложения не загружены." ;;
        67) echo "Ошибка активации (сетевая ошибка при проверке)." ;;
        68) echo "Команда заблокирована политикой администрирования." ;;
        101) echo "Ошибка лицензии (недействительная/отсутствует лицензия)." ;;
        102) echo "Лицензия заблокирована (находится в черном списке)." ;;
        103) echo "Срок действия лицензии истек." ;;
        *) echo "Неизвестная ошибка (код возврата: $code)." ;;
    esac
}

# Функция получения описания кода ошибки Dr.Web
get_drweb_error_desc() {
    local code="$1"
    case "$code" in
        0) echo "Успешно завершено." ;;
        1) echo "Ошибка IPC (компонент не может подключиться к drweb-configd)." ;;
        65) echo "Операция не поддерживается данным компонентом." ;;
        90) echo "Неверный DRL-файл (ошибка списка серверов обновления)." ;;
        92) echo "Полученный архив обновлений поврежден." ;;
        93) echo "Ошибка аутентификации на прокси-сервере." ;;
        101) echo "Ошибка лицензии (недействительный или истекший ключевой файл)." ;;
        105) echo "Ошибка скачивания файлов обновления." ;;
        *) echo "Неизвестная ошибка (код возврата: $code)." ;;
    esac
}

# Функция обновления баз Kaspersky
update_bases_kesl() {
    local log_file="/tmp/kesl_update.log"
    echo "=== Запуск обновления баз Kaspersky (Офлайн) ===" > "$log_file"
    echo "Дата запуска: $(date)" >> "$log_file"
    echo "----------------------------------------" >> "$log_file"

    if ! command -v kesl-control &>/dev/null; then
        whiptail --title "Ошибка" --msgbox "Ошибка: Антивирус Kaspersky не установлен (утилита kesl-control не найдена)." 8 58
        return 1
    fi

    # 1. Поиск корней
    local roots=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            roots+=("$line")
        fi
    done < <(find_antivirus_roots)

    if [ ${#roots[@]} -eq 0 ]; then
        whiptail --title "Ошибка" --msgbox "Ошибка: Корневые папки обновлений не найдены на примонтированных дисках или в проекте." 8 68
        return 1
    fi

    # 2. Поиск папок с базами
    local found_dirs=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            found_dirs+=("$line")
        fi
    done < <(find_bases_folders "kesl" "${roots[@]}")

    if [ ${#found_dirs[@]} -eq 0 ]; then
        whiptail --title "Ошибка" --msgbox "Ошибка: Папки с базами обновлений (bases, update, updates) не найдены." 8 68
        return 1
    fi

    # Выбор источника
    local selected_dir=""
    if [ ${#found_dirs[@]} -eq 1 ]; then
        selected_dir="${found_dirs[0]}"
    else
        local menu_args=()
        local idx=1
        for d in "${found_dirs[@]}"; do
            local relative_path="${d#$ROOT_DIR}"
            if [ "$relative_path" != "$d" ]; then
                menu_args+=("$idx" "Проект: $relative_path")
            else
                local mnt_name=$(basename "$(dirname "$d")")
                if [ "$mnt_name" = "KESL" ] || [ "$mnt_name" = "dr.web" ]; then
                    mnt_name=$(basename "$(dirname "$(dirname "$d")")")
                fi
                menu_args+=("$idx" "$mnt_name: $(basename "$d")")
            fi
            ((idx++))
        done

        local choice
        choice=$(whiptail --title "Выберите папку с базами KESL" \
                          --menu "Найдено несколько папок с базами. Выберите одну:" \
                          15 100 6 \
                          "${menu_args[@]}" \
                          3>&1 1>&2 2>&3)
        if [ $? -ne 0 ] || [ -z "$choice" ]; then
            return 1
        fi
        selected_dir="${found_dirs[$((choice-1))]}"
    fi

    # 3. Диалог выбора пути
    local local_update_dir
    local_update_dir=$(ask_local_update_dir)
    if [ -z "$local_update_dir" ]; then
        return 1
    fi

    # Спрашиваем подтверждение
    whiptail --title "Подтверждение обновления" \
             --yesno "Будет выполнено копирование баз из:\n$selected_dir\n\nВ локальную директорию:\n$local_update_dir\n\nЖелаете начать процесс?" 14 74
    if [ $? -ne 0 ]; then
        return 1
    fi

    local status_file="/tmp/kesl_update_status"
    echo "1" > "$status_file"

    # Создание папки, если ее нет, и очистка
    mkdir -p "$local_update_dir"
    rm -rf "${local_update_dir:?}"/*

    # Запускаем TUI Gauge
    {
        exec 3>&1
        exec > "$log_file" 2>&1

        update_install_progress "10" "Копирование баз обновлений..."
        
        # Копируем содержимое найденной папки
        cp -r "$selected_dir"/* "$local_update_dir/"
        local cp_code=$?
        echo "Код копирования баз: $cp_code"
        if [ $cp_code -ne 0 ]; then
            echo "Ошибка копирования файлов баз."
            update_install_progress "100" "Ошибка копирования!"
            echo "1" > "$status_file"
            exit 1
        fi

        update_install_progress "40" "Настройка KESL на локальный каталог баз..."
        
        kesl-control --set-settings Update SourceType=Custom CustomSources.item_0000.URL="$local_update_dir" CustomSources.item_0000.Enabled=Yes
        local set_code=$?
        echo "Код настройки KESL: $set_code"
        if [ $set_code -ne 0 ]; then
            echo "Ошибка настройки KESL на локальный источник."
            update_install_progress "100" "Ошибка настройки!"
            echo "1" > "$status_file"
            exit 1
        fi

        update_install_progress "60" "Запуск обновления баз KESL..."

        local task_id="Update"
        if ! LC_ALL=C kesl-control --get-task-list 2>/dev/null | grep -i -q "Update"; then
            task_id="6"
        fi

        kesl-control --start-task "$task_id"
        local start_code=$?
        echo "Код запуска задачи: $start_code"
        if [ $start_code -ne 0 ]; then
            echo "Ошибка запуска задачи обновления."
            update_install_progress "100" "Ошибка запуска задачи!"
            echo "1" > "$status_file"
            exit 1
        fi

        # Цикл опроса состояния
        update_install_progress "70" "Ожидание завершения обновления..."
        
        local check_count=0
        local success=0
        while true; do
            sleep 2
            local state_output
            state_output=$(LC_ALL=C kesl-control --get-task-state "$task_id" 2>/dev/null)
            local current_state=""
            
            # Парсим строку State или Состояние
            local state_line
            state_line=$(echo "$state_output" | grep -E -i "^(State|Состояние):")
            if [ -n "$state_line" ]; then
                current_state=$(echo "$state_line" | awk -F': ' '{print $2}' | tr -d '\r' | xargs)
            fi
            
            # Переводим статус в единый английский формат для внутренней логики
            local lower_state
            lower_state=$(echo "$current_state $state_output" | tr '[:upper:]' '[:lower:]')
            
            if [[ "$lower_state" =~ completed|success|завершен|выполнен ]]; then
                current_state="Completed"
            elif [[ "$lower_state" =~ running|started|starting|запущен|выполняется ]]; then
                current_state="Running"
            elif [[ "$lower_state" =~ failed|error|ошибка|сбой ]]; then
                current_state="Failed"
            elif [[ "$lower_state" =~ stopped|остановлен ]]; then
                current_state="Stopped"
            else
                current_state="Unknown"
            fi
            
            echo "Опрос состояния задачи ($task_id): $current_state"
            
            if [ "$current_state" = "Completed" ]; then
                echo "Обновление завершено успешно."
                success=1
                break
            elif [ "$current_state" = "Failed" ] || [ "$current_state" = "Stopped" ]; then
                echo "Ошибка или остановка задачи обновления."
                break
            fi
            
            ((check_count++))
            if [ $check_count -gt 150 ]; then
                echo "Превышен таймаут ожидания завершения задачи обновления (300 секунд)."
                break
            fi
            
            local pct=$(( 70 + (check_count * 25 / 150) ))
            if [ $pct -gt 95 ]; then pct=95; fi
            update_install_progress "$pct" "Обновление выполняется... (Статус: $current_state)"
        done

        if [ $success -eq 1 ]; then
            echo "0" > "$status_file"
            update_install_progress "100" "Обновление успешно завершено!"
        else
            echo "1" > "$status_file"
            update_install_progress "100" "Ошибка обновления баз!"
        fi
    } | whiptail --gauge "Офлайн-обновление баз KESL..." 10 70 0 3>&-

    local exit_status=1
    if [ -f "$status_file" ]; then
        exit_status=$(cat "$status_file")
        rm -f "$status_file"
    fi

    if [ "$exit_status" -eq 0 ]; then
        whiptail --title "Успех" --msgbox "Обновление баз KESL успешно завершено!" 8 60
    else
        whiptail --title "Ошибка обновления баз" --textbox "$log_file" 20 76
    fi

    # Вывод информации о базах и приложении
    local info_log="/tmp/kesl_app_info.log"
    echo "=== Текущая информация о KESL и базах ===" > "$info_log"
    echo "Дата проверки: $(date)" >> "$info_log"
    echo "----------------------------------------" >> "$info_log"
    kesl-control --app-info >> "$info_log" 2>&1
    
    whiptail --title "Информация о базах KESL" --textbox "$info_log" 20 76
    rm -f "$info_log"
}

# Функция обновления баз Dr.Web
update_bases_drweb() {
    local log_file="/tmp/drweb_update.log"
    echo "=== Запуск обновления баз Dr.Web (Офлайн) ===" > "$log_file"
    echo "Дата запуска: $(date)" >> "$log_file"
    echo "----------------------------------------" >> "$log_file"

    if ! command -v drweb-ctl &>/dev/null; then
        whiptail --title "Ошибка" --msgbox "Ошибка: Антивирус Dr.Web не установлен (утилита drweb-ctl не найдена)." 8 58
        return 1
    fi

    # 1. Поиск корней
    local roots=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            roots+=("$line")
        fi
    done < <(find_antivirus_roots)

    if [ ${#roots[@]} -eq 0 ]; then
        whiptail --title "Ошибка" --msgbox "Ошибка: Корневые папки обновлений не найдены на примонтированных дисках или в проекте." 8 68
        return 1
    fi

    # 2. Поиск папок с базами
    local found_dirs=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            found_dirs+=("$line")
        fi
    done < <(find_bases_folders "drweb" "${roots[@]}")

    if [ ${#found_dirs[@]} -eq 0 ]; then
        whiptail --title "Ошибка" --msgbox "Ошибка: Папки с базами обновлений (bases, update, updates) не найдены." 8 68
        return 1
    fi

    # Выбор источника
    local selected_dir=""
    if [ ${#found_dirs[@]} -eq 1 ]; then
        selected_dir="${found_dirs[0]}"
    else
        local menu_args=()
        local idx=1
        for d in "${found_dirs[@]}"; do
            local relative_path="${d#$ROOT_DIR}"
            if [ "$relative_path" != "$d" ]; then
                menu_args+=("$idx" "Проект: $relative_path")
            else
                local mnt_name=$(basename "$(dirname "$d")")
                if [ "$mnt_name" = "KESL" ] || [ "$mnt_name" = "dr.web" ]; then
                    mnt_name=$(basename "$(dirname "$(dirname "$d")")")
                fi
                menu_args+=("$idx" "$mnt_name: $(basename "$d")")
            fi
            ((idx++))
        done

        local choice
        choice=$(whiptail --title "Выберите папку с базами Dr.Web" \
                          --menu "Найдено несколько папок с базами. Выберите одну:" \
                          15 100 6 \
                          "${menu_args[@]}" \
                          3>&1 1>&2 2>&3)
        if [ $? -ne 0 ] || [ -z "$choice" ]; then
            return 1
        fi
        selected_dir="${found_dirs[$((choice-1))]}"
    fi

    # 3. Диалог выбора пути
    local local_update_dir
    local_update_dir=$(ask_local_update_dir)
    if [ -z "$local_update_dir" ]; then
        return 1
    fi

    # Спрашиваем подтверждение
    whiptail --title "Подтверждение обновления" \
             --yesno "Будет выполнено копирование баз из:\n$selected_dir\n\nВ локальную директорию:\n$local_update_dir\n\nЖелаете начать процесс?" 14 74
    if [ $? -ne 0 ]; then
        return 1
    fi

    local status_file="/tmp/drweb_update_status"
    echo "1" > "$status_file"

    # Создание папки, если ее нет, и очистка
    mkdir -p "$local_update_dir"
    rm -rf "${local_update_dir:?}"/*

    # Запускаем TUI Gauge
    {
        exec 3>&1
        exec > "$log_file" 2>&1

        update_install_progress "20" "Копирование файлов баз..."
        
        cp -r "$selected_dir"/* "$local_update_dir/"
        local cp_code=$?
        echo "Код копирования баз: $cp_code"
        if [ $cp_code -ne 0 ]; then
            echo "Ошибка копирования файлов баз."
            update_install_progress "100" "Ошибка копирования!"
            echo "1" > "$status_file"
            exit 1
        fi

        update_install_progress "50" "Запуск офлайн-обновления Dr.Web..."
        
        drweb-ctl update --From "$local_update_dir"
        local update_code=$?
        echo "Код возврата drweb-ctl update: $update_code"
        if [ $update_code -eq 0 ]; then
            echo "Статус: Обновление выполнено успешно."
            echo "0" > "$status_file"
        else
            echo "Статус: Ошибка обновления."
            echo "Описание: $(get_drweb_error_desc "$update_code")"
            echo "1" > "$status_file"
        fi
        
        update_install_progress "100" "Обновление завершено!"
    } | whiptail --gauge "Офлайн-обновление баз Dr.Web..." 10 70 0 3>&-

    local exit_status=1
    if [ -f "$status_file" ]; then
        exit_status=$(cat "$status_file")
        rm -f "$status_file"
    fi

    if [ "$exit_status" -eq 0 ]; then
        whiptail --title "Успех" --msgbox "Обновление баз Dr.Web успешно завершено!" 8 60
    else
        whiptail --title "Ошибка обновления баз" --textbox "$log_file" 20 76
    fi
}

# Функция поиска файлов ключей лицензии (*.key)
find_license_keys() {
    local roots=("$@")
    local found_files=()
    
    for r in "${roots[@]}"; do
        if [ ! -d "$r" ]; then
            continue
        fi
        while IFS= read -r f; do
            if [ -f "$f" ]; then
                found_files+=("$f")
            fi
        done < <(find "$r" -maxdepth 4 -type f -name "*.key" 2>/dev/null)
    done
    
    if [ ${#found_files[@]} -gt 0 ]; then
        printf "%s\n" "${found_files[@]}" | sort -u
    fi
}

# Функция активации лицензии Kaspersky
activate_license_kesl() {
    if ! command -v kesl-control &>/dev/null; then
        whiptail --title "Ошибка" --msgbox "Ошибка: Антивирус Kaspersky не установлен (утилита kesl-control не найдена)." 8 58
        return 1
    fi

    local roots=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            roots+=("$line")
        fi
    done < <(find_antivirus_roots)

    local found_keys=()
    if [ ${#roots[@]} -gt 0 ]; then
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                found_keys+=("$line")
            fi
        done < <(find_license_keys "${roots[@]}")
    fi

    local selected_key=""
    if [ ${#found_keys[@]} -eq 0 ]; then
        selected_key=$(whiptail --title "Ввод пути к файлу лицензии KESL" \
                               --inputbox "Файлы лицензии (*.key) не найдены автоматически.\n\nВведите абсолютный путь к файлу ключа лицензии KESL:" \
                               12 70 \
                               3>&1 1>&2 2>&3)
        if [ $? -ne 0 ] || [ -z "$selected_key" ]; then
            return 1
        fi
    elif [ ${#found_keys[@]} -eq 1 ]; then
        selected_key="${found_keys[0]}"
        whiptail --title "Обнаружен ключ лицензии KESL" \
                 --yesno "Найден следующий ключ лицензии:\n$selected_key\n\nИспользовать его для активации?" 12 70
        if [ $? -ne 0 ]; then
            selected_key=$(whiptail --title "Ввод пути к файлу лицензии KESL" \
                                   --inputbox "Введите абсолютный путь к файлу ключа лицензии KESL:" \
                                   10 70 \
                                   3>&1 1>&2 2>&3)
            if [ $? -ne 0 ] || [ -z "$selected_key" ]; then
                return 1
            fi
        fi
    else
        local menu_args=()
        local idx=1
        for k in "${found_keys[@]}"; do
            local relative_path="${k#$ROOT_DIR}"
            if [ "$relative_path" != "$k" ]; then
                menu_args+=("$idx" "Проект: $(basename "$k")")
            else
                local mnt_name=$(basename "$(dirname "$k")")
                menu_args+=("$idx" "$mnt_name: $(basename "$k")")
            fi
            ((idx++))
        done
        
        local manual_idx=$idx
        menu_args+=("$manual_idx" "[ Указать путь вручную ]")
        
        local choice
        choice=$(whiptail --title "Выберите файл ключа KESL" \
                          --menu "Найдено несколько ключей. Выберите один:" \
                          15 100 6 \
                          "${menu_args[@]}" \
                          3>&1 1>&2 2>&3)
        if [ $? -ne 0 ] || [ -z "$choice" ]; then
            return 1
        fi
        
        if [ "$choice" -eq "$manual_idx" ]; then
            selected_key=$(whiptail --title "Ввод пути к файлу лицензии KESL" \
                                   --inputbox "Введите абсолютный путь к файлу ключа лицензии KESL:" \
                                   10 70 \
                                   3>&1 1>&2 2>&3)
            if [ $? -ne 0 ] || [ -z "$selected_key" ]; then
                return 1
            fi
        else
            selected_key="${found_keys[$((choice-1))]}"
        fi
    fi

    if [ ! -f "$selected_key" ]; then
        whiptail --title "Ошибка" --msgbox "Ошибка: Файл '$selected_key' не существует." 8 58
        return 1
    fi

    whiptail --title "Активация лицензии KESL" \
             --yesno "Вы собираетесь активировать KESL с помощью ключа:\n$selected_key\n\nПродолжить?" 12 70
    if [ $? -ne 0 ]; then
        return 1
    fi

    local log_file="/tmp/kesl_activation.log"
    echo "=== Запуск активации лицензии KESL ===" > "$log_file"
    echo "Ключ: $selected_key" >> "$log_file"
    echo "Дата запуска: $(date)" >> "$log_file"
    echo "----------------------------------------" >> "$log_file"

    kesl-control --add-active-key "$selected_key" >> "$log_file" 2>&1
    local res=$?

    if [ $res -eq 0 ]; then
        whiptail --title "Успех" --msgbox "Лицензия Kaspersky Endpoint Security успешно активирована!" 8 60
    else
        whiptail --title "Ошибка активации" --textbox "$log_file" 20 76
    fi
    rm -f "$log_file"
}

# Функция активации лицензии Dr.Web
activate_license_drweb() {
    if ! command -v drweb-ctl &>/dev/null; then
        whiptail --title "Ошибка" --msgbox "Ошибка: Антивирус Dr.Web не установлен (утилита drweb-ctl не найдена)." 8 58
        return 1
    fi

    local roots=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            roots+=("$line")
        fi
    done < <(find_antivirus_roots)

    local found_keys=()
    if [ ${#roots[@]} -gt 0 ]; then
        while IFS= read -r line; do
            if [ -n "$line" ]; then
                found_keys+=("$line")
            fi
        done < <(find_license_keys "${roots[@]}")
    fi

    local selected_key=""
    if [ ${#found_keys[@]} -eq 0 ]; then
        selected_key=$(whiptail --title "Ввод пути к файлу лицензии Dr.Web" \
                               --inputbox "Файлы лицензии (*.key) не найдены автоматически.\n\nВведите абсолютный путь к файлу ключа лицензии Dr.Web:" \
                               12 70 \
                               3>&1 1>&2 2>&3)
        if [ $? -ne 0 ] || [ -z "$selected_key" ]; then
            return 1
        fi
    elif [ ${#found_keys[@]} -eq 1 ]; then
        selected_key="${found_keys[0]}"
        whiptail --title "Обнаружен ключ лицензии Dr.Web" \
                 --yesno "Найден следующий ключ лицензии:\n$selected_key\n\nИспользовать его для активации?" 12 70
        if [ $? -ne 0 ]; then
            selected_key=$(whiptail --title "Ввод пути к файлу лицензии Dr.Web" \
                                   --inputbox "Введите абсолютный путь к файлу ключа лицензии Dr.Web:" \
                                   10 70 \
                                   3>&1 1>&2 2>&3)
            if [ $? -ne 0 ] || [ -z "$selected_key" ]; then
                return 1
            fi
        fi
    else
        local menu_args=()
        local idx=1
        for k in "${found_keys[@]}"; do
            local relative_path="${k#$ROOT_DIR}"
            if [ "$relative_path" != "$k" ]; then
                menu_args+=("$idx" "Проект: $(basename "$k")")
            else
                local mnt_name=$(basename "$(dirname "$k")")
                menu_args+=("$idx" "$mnt_name: $(basename "$k")")
            fi
            ((idx++))
        done
        
        local manual_idx=$idx
        menu_args+=("$manual_idx" "[ Указать путь вручную ]")
        
        local choice
        choice=$(whiptail --title "Выберите файл ключа Dr.Web" \
                          --menu "Найдено несколько ключей. Выберите один:" \
                          15 100 6 \
                          "${menu_args[@]}" \
                          3>&1 1>&2 2>&3)
        if [ $? -ne 0 ] || [ -z "$choice" ]; then
            return 1
        fi
        
        if [ "$choice" -eq "$manual_idx" ]; then
            selected_key=$(whiptail --title "Ввод пути к файлу лицензии Dr.Web" \
                                   --inputbox "Введите абсолютный путь к файлу ключа лицензии Dr.Web:" \
                                   10 70 \
                                   3>&1 1>&2 2>&3)
            if [ $? -ne 0 ] || [ -z "$selected_key" ]; then
                return 1
            fi
        else
            selected_key="${found_keys[$((choice-1))]}"
        fi
    fi

    if [ ! -f "$selected_key" ]; then
        whiptail --title "Ошибка" --msgbox "Ошибка: Файл '$selected_key' не существует." 8 58
        return 1
    fi

    whiptail --title "Активация лицензии Dr.Web" \
             --yesno "Вы собираетесь активировать Dr.Web с помощью ключа:\n$selected_key\n\nПродолжить?" 12 70
    if [ $? -ne 0 ]; then
        return 1
    fi

    local log_file="/tmp/drweb_activation.log"
    echo "=== Запуск активации лицензии Dr.Web ===" > "$log_file"
    echo "Ключ: $selected_key" >> "$log_file"
    echo "Дата запуска: $(date)" >> "$log_file"
    echo "----------------------------------------" >> "$log_file"

    local success=0
    mkdir -p /etc/opt/drweb.com
    cp "$selected_key" /etc/opt/drweb.com/drweb32.key >> "$log_file" 2>&1
    local cp_code=$?
    echo "Код копирования ключа: $cp_code" >> "$log_file"
    
    if [ $cp_code -eq 0 ]; then
        chmod 644 /etc/opt/drweb.com/drweb32.key >> "$log_file" 2>&1
        drweb-ctl reload >> "$log_file" 2>&1
        local reload_code=$?
        echo "Код перезапуска конфигурации drweb-ctl reload: $reload_code" >> "$log_file"
        if [ $reload_code -eq 0 ]; then
            success=1
        fi
    fi

    if [ $success -eq 1 ]; then
        whiptail --title "Успех" --msgbox "Лицензия Dr.Web успешно активирована!" 8 60
    else
        whiptail --title "Ошибка активации" --textbox "$log_file" 20 76
    fi
    rm -f "$log_file"
}

# Подменю для Kaspersky
show_kaspersky_submenu() {
    local default_sub="Установка"
    while true; do
        sub_choice=$(whiptail --title "Kaspersky Endpoint Security" \
                              --cancel-button "Назад" \
                              --default-item "$default_sub" \
                              --menu "   ───┤ Управление: ↑/↓ - переход, Enter - выбор, Tab - кнопки ├───\n\nВыберите действие:" \
                              18 76 4 \
                              "Установка" "" \
                              "Обновление баз" "" \
                              "Активация лицензии" "" \
                              "Назад" "" \
                              3>&1 1>&2 2>&3)
                              
        exit_code=$?
        if [ $exit_code -ne 0 ] || [ "$sub_choice" = "Назад" ]; then
            break
        fi
        
        default_sub="$sub_choice"
        
        case "$sub_choice" in
            "Установка")
                handle_kesl_install
                ;;
            "Обновление баз")
                update_bases_kesl
                ;;
            "Активация лицензии")
                activate_license_kesl
                ;;
        esac
    done
}

# Подменю для Dr.Web
show_drweb_submenu() {
    local default_sub="Установка"
    while true; do
        sub_choice=$(whiptail --title "Dr.Web Security Space" \
                              --cancel-button "Назад" \
                              --default-item "$default_sub" \
                              --menu "   ───┤ Управление: ↑/↓ - переход, Enter - выбор, Tab - кнопки ├───\n\nВыберите действие:" \
                              18 76 4 \
                              "Установка" "" \
                              "Обновление баз" "" \
                              "Активация лицензии" "" \
                              "Назад" "" \
                              3>&1 1>&2 2>&3)
                              
        exit_code=$?
        if [ $exit_code -ne 0 ] || [ "$sub_choice" = "Назад" ]; then
            break
        fi
        
        default_sub="$sub_choice"
        
        case "$sub_choice" in
            "Установка")
                handle_drweb_install
                ;;
            "Обновление баз")
                update_bases_drweb
                ;;
            "Активация лицензии")
                activate_license_drweb
                ;;
        esac
    done
}

default_choice="Kaspersky endpoint security"
while true; do
    choice=$(whiptail --title "Установка антивирусного ПО" \
                      --cancel-button "Назад" \
                      --default-item "$default_choice" \
                      --menu "   ───┤ Управление: ↑/↓ - переход, Enter - выбор, Tab - кнопки ├───\n\nВыберите антивирусное ПО для установки:" \
                      18 76 2 \
                      "Kaspersky endpoint security" "" \
                      "Dr.Web security space" "" \
                      3>&1 1>&2 2>&3)
                      
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        break
    fi
    
    default_choice="$choice"
    
    case "$choice" in
        "Kaspersky endpoint security")
            show_kaspersky_submenu
            ;;
        "Dr.Web security space")
            show_drweb_submenu
            ;;
    esac
done

exit 0
