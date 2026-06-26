#!/bin/bash
# ============================================================
#       СКРИПТ АВТОМАТИЧЕСКОГО АУДИТА БЕЗОПАСНОСТИ OPENSCAP
# ============================================================
# Этот скрипт выполняет автоматический поиск базы ФСТЭК на
# внешних накопителях, развертывание OpenSCAP и запуск сканирования.

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

# Проверка запуска от имени суперпользователя (root)
if [ "$EUID" -ne 0 ]; then
    whiptail --title "Ошибка" --msgbox "Ошибка: Этот скрипт должен быть запущен от root (sudo)." 8 58
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

total_steps=8
current_step=0
update_progress() {
    local msg="$1"
    current_step=$((current_step + 1))
    local percent=$((current_step * 100 / total_steps))
    [ "$percent" -gt 100 ] && percent=100
    echo "XXX" >&3
    echo "$percent" >&3
    echo "$msg" >&3
    echo "XXX" >&3
}

find_local_db() {
    local found=""
    # 1. Поиск на внешних накопителях
    for mount_dir in /media /run/media /mnt; do
        if [ -d "$mount_dir" ]; then
            found=$(find "$mount_dir" -type f -iname "scanovalcontent*.deb" 2>/dev/null | head -n 1)
            [ -n "$found" ] && break
        fi
    done

    # 2. Поиск в каталоге проекта
    if [ -z "$found" ]; then
        found=$(find "$ROOT_DIR" -maxdepth 2 -type f -iname "scanovalcontent*.deb" 2>/dev/null | head -n 1)
    fi

    echo "$found"
}

download_db() {
    local log_file="/tmp/scanoval_db_download.log"
    echo "=== Запуск загрузки базы ФСТЭК ===" > "$log_file"
    
    whiptail --title "Загрузка базы ФСТЭК" --infobox "Подключение к серверу БДУ ФСТЭК и скачивание базы..." 8 60
    
    local status=""
    if curl -s -k -I https://bdu.fstec.ru >/dev/null 2>&1 || wget -q --spider --no-check-certificate https://bdu.fstec.ru >/dev/null 2>&1; then
        if wget --no-check-certificate -O "$ROOT_DIR/service/scanovalcontent_alse17.deb" https://bdu.fstec.ru/files/scanovalcontent_alse17.deb >> "$log_file" 2>&1; then
            status="success"
        else
            status="failed_download"
        fi
    else
        status="failed_connection"
    fi
    
    if [ "$status" = "success" ]; then
        whiptail --title "Успех" --msgbox "База успешно скачана и сохранена в:\n$ROOT_DIR/service/scanovalcontent_alse17.deb" 10 65
        return 0
    elif [ "$status" = "failed_connection" ]; then
        whiptail --title "Ошибка сети" --msgbox "Не удалось подключиться к сайту ФСТЭК (https://bdu.fstec.ru).\nПроверьте подключение к интернету." 10 65
        return 1
    else
        whiptail --title "Ошибка загрузки" --msgbox "Не удалось скачать базу. Подробный лог сохранен в:\n$log_file" 10 65
        return 1
    fi
}

check_dependencies() {
    local missing_pkgs=()
    local pkg
    for pkg in openscap-scanner openscap-common unzip; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            missing_pkgs+=("$pkg")
        fi
    done
    
    local db_file=$(find_local_db)
    local db_found=false
    if [ -n "$db_file" ]; then
        db_found=true
    fi
    
    local has_errors=false
    local msg=""
    
    if [ ${#missing_pkgs[@]} -ne 0 ]; then
        has_errors=true
        msg="В системе отсутствуют необходимые пакеты:\n"
        for p in "${missing_pkgs[@]}"; do
            msg+="  - $p\n"
        done
    fi
    
    if [ "$db_found" = false ]; then
        has_errors=true
        msg="${msg}OVAL-база ФСТЭК (scanovalcontent*.deb) не найдена в системе.\n"
    fi
    
    if [ "$has_errors" = true ]; then
        msg="${msg}\nВы будете перенаправлены в менеджер репозиториев для подключения установочного диска/образа."
        whiptail --title "Зависимости не найдены" --msgbox "$msg" 15 76
        
        # Переносим в менеджер репозиториев
        if [ -f "$SCRIPT_DIR/repo_manager.sh" ]; then
            chmod +x "$SCRIPT_DIR/repo_manager.sh"
            "$SCRIPT_DIR/repo_manager.sh"
        else
            whiptail --title "Ошибка" --msgbox "Скрипт repo_manager.sh не найден!" 8 58
        fi
    else
        whiptail --title "Проверка завершена" --msgbox "Все необходимые зависимости обнаружены!\n\nКомпоненты:\n  - openscap-scanner (пакет)\n  - openscap-common (пакет)\n  - unzip (пакет)\n  - OVAL-база ФСТЭК (БД)" 14 70
    fi
}

run_scanner() {
    local found_file=$(find_local_db)
    
    if [ -z "$found_file" ]; then
        whiptail --title "Ошибка" --msgbox "Ошибка: OVAL-база ФСТЭК не найдена в системе!\nПожалуйста, скачайте ее или выполните проверку зависимостей." 10 65
        return 1
    fi

    current_step=0
    {
        # Сохраняем FD 1 (пайп к whiptail) в FD 3
        exec 3>&1
        
        # Перенаправляем стандартный вывод и ошибки в лог-файл
        exec > /tmp/scanoval_checker_raw.log 2>&1

        # Шаг 1: Поиск OVAL-базы ФСТЭК (уже найдена, просто подтверждаем)
        update_progress "Подтверждение пути OVAL-базы ФСТЭК..."
        sleep 1

        # Шаг 2: Подготовка окружения
        update_progress "Подготовка рабочего каталога..."
        
        REAL_USER="$SUDO_USER"
        if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
            USER_HOME="/root"
            REAL_USER="root"
        else
            USER_HOME=$(eval echo "~$REAL_USER")
        fi

        WORK_DIR="$USER_HOME/scanoval"
        RESULT_DIR="$ROOT_DIR/report/scanoval"

        mkdir -p "$WORK_DIR"
        mkdir -p "$RESULT_DIR"
        cp "$found_file" "$WORK_DIR/"
        cd "$WORK_DIR" || exit 1

        # Шаг 3: Обновление репозиториев
        update_progress "Обновление списков пакетов APT..."
        if [ -f /etc/apt/sources.list ]; then
            if ! grep -q "file:/media/astra_iso" /etc/apt/sources.list; then
                sed -i 's/^#\s*\(deb .*astra.*\)/\1/' /etc/apt/sources.list
            fi
        fi

        apt-get update

        # Шаг 4: Установка OpenSCAP
        update_progress "Установка пакетов OpenSCAP (это может занять время)..."
        apt-get install -y openscap-scanner openscap-common unzip

        # Шаг 5: Распаковка архива
        update_progress "Распаковка ZIP-архива базы ФСТЭК..."
        mkdir -p content
        mkdir -p unpack

        filename=$(basename "$found_file")
        unzip -o "$filename" -d content/

        # Шаг 6: Извлечение XML-базы данных
        update_progress "Извлечение XML-файла базы уязвимостей ФСТЭК..."
        
        inner_deb=$(find content/ -name "scanoval-content-*.deb" 2>/dev/null | head -n 1)
        if [ -z "$inner_deb" ]; then
            echo "Ошибка: В архиве не найден внутренний deb-пакет!"
            exit 1
        fi

        dpkg-deb -x "$inner_deb" unpack/

        oval_xml=$(find unpack/var/lib/scanoval/data/ -name "*OVAL.xml" 2>/dev/null | head -n 1)
        if [ -z "$oval_xml" ]; then
            oval_xml=$(find unpack/ -name "*.xml" 2>/dev/null | head -n 1)
        fi

        if [ -z "$oval_xml" ]; then
            echo "Ошибка: OVAL XML-файл не найден!"
            exit 1
        fi

        # Шаг 7: Запуск сканирования
        update_progress "Запуск оценки уязвимостей OpenSCAP (это может занять время)..."
        
        start_time=$(date "+%Y-%m-%d %H:%M:%S")
        oscap oval eval \
          --results "$RESULT_DIR/scanoval-results.xml" \
          "$oval_xml"

        # Шаг 8: Генерация отчета
        update_progress "Генерация отчетов сканирования..."
        python3 "$ROOT_DIR/service/generate_custom_report.py" "$oval_xml" "$RESULT_DIR/scanoval-results.xml" "$RESULT_DIR/scanoval-report.html" "$start_time"

        if [ "$REAL_USER" != "root" ]; then
            chown -R "$REAL_USER:$REAL_USER" "$RESULT_DIR" "$WORK_DIR" 2>/dev/null || true
        fi
        chmod 755 "$RESULT_DIR" 2>/dev/null || true
        chmod 644 "$RESULT_DIR"/scanoval-* 2>/dev/null || true

    } | whiptail --gauge "Выполнение сканирования OVAL..." 10 70 0
    exit_code=${PIPESTATUS[0]}
    
    if [ $exit_code -eq 0 ]; then
        whiptail --title "Сканирование завершено" --msgbox "Сканирование уязвимостей успешно завершено!\n\nРезультаты сохранены в:\n$RESULT_DIR\n\nФайлы отчетов:\n- scanoval-report.html\n- scanoval-results.xml" 15 76
    else
        whiptail --title "Ошибка" --msgbox "Произошла ошибка во время сканирования OVAL.\n\nПодробный лог выполнения доступен в:\n/tmp/scanoval_checker_raw.log" 12 70
    fi
    
    return $exit_code
}

# ============================================================
#               ГЛАВНЫЙ ЗАПУСК И ИНИЦИАЛИЗАЦИЯ
# ============================================================

# 1. Проверяем базу перед выбором меню
db_file=$(find_local_db)
if [ -z "$db_file" ]; then
    whiptail --title "База уязвимостей не найдена" \
             --yesno "OVAL-база ФСТЭК не обнаружена в системе.\nХотите попытаться скачать её с официального сайта ФСТЭК БДУ?" 10 65
    if [ $? -eq 0 ]; then
        download_db
    fi
fi

# 2. Запуск меню
default_choice="Начало сканирования"
while true; do
    choice=$(whiptail --title "ScanOval сканирование" \
                      --cancel-button "Назад" \
                      --default-item "$default_choice" \
                      --menu "   ───┤ Управление: ↑/↓ - переход, Enter - выбор, Tab - кнопки ├───\n\nВыберите действие для OVAL-сканера:" \
                      18 76 3 \
                      "Начало сканирования" "" \
                      "Проверка зависимостей" "" \
                      "Назад в меню" "" \
                      3>&1 1>&2 2>&3)
    exit_code=$?
    
    if [ $exit_code -ne 0 ] || [ "$choice" = "Назад в меню" ]; then
        break
    fi
    
    default_choice="$choice"
    
    case "$choice" in
        "Начало сканирования")
            run_scanner
            ;;
        "Проверка зависимостей")
            check_dependencies
            ;;
    esac
done

exit 0
