#!/bin/bash
# ============================================================
#               ГЛАВНЫЙ ЦЕНТРАЛИЗОВАННЫЙ ХАБ УПРАВЛЕНИЯ
# ============================================================
# Позволяет запускать аудит безопасности и OVAL-сканер ФСТЭК.

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

# Проверка на запуск от root (sudo)
if [ "$EUID" -ne 0 ]; then
    whiptail --title "Ошибка" --msgbox "Ошибка: Этот скрипт должен быть запущен от root (sudo)." 8 58
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Функция проверки существования и прав на запуск файла
check_and_run() {
    local target_script="$1"
    if [ ! -f "$target_script" ]; then
        whiptail --title "Ошибка" --msgbox "Ошибка: Файл $target_script не найден!" 8 58
        return 1
    fi
    
    # Делаем исполняемым, если еще не сделан
    chmod +x "$target_script"
    
    # Запуск
    "$target_script"
}

# Функция проверки наличия зависимостей
get_dependencies_status() {
    local missing=()
    local pkg
    for pkg in openscap-scanner openscap-common unzip; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            missing+=("$pkg")
        fi
    done

    if [ ${#missing[@]} -ne 0 ]; then
        local msg="ВНИМАНИЕ: Отсутствуют пакеты для OVAL-сканера: "
        local p
        for p in "${missing[@]}"; do
            msg+="$p "
        done
        msg+="\nНастройте репозиторий (пункт 5) для их установки."
        echo -e "$msg"
    else
        echo "Все необходимые зависимости установлены."
    fi
}

default_choice="Установка антивирусного ПО"
while true; do
    status_msg=$(get_dependencies_status)
    
    choice=$(whiptail --title "АО НИИ \"РУБИН\"" \
                      --cancel-button "Выход" \
                      --default-item "$default_choice" \
                      --menu "   ───┤ Управление: ↑/↓ - переход, Enter - выбор, Tab - кнопки ├───\n\nВыберите инструмент для запуска:\n\n$status_msg" \
                      18 76 6 \
                      "Аудит и скриншоты" "" \
                      "ScanOval сканирование" "" \
                      "Установка антивирусного ПО" "" \
                      "Работа с системой" "" \
                      "Инструменты" "" \
                      "Выход" "" \
                      3>&1 1>&2 2>&3)
                      
    exit_code=$?
    if [ $exit_code -ne 0 ] || [ "$choice" = "Выход" ]; then
        break
    fi
    
    default_choice="$choice"
    
    case "$choice" in
        "Аудит и скриншоты")
            check_and_run "$SCRIPT_DIR/scripts/security_checker.sh"
            ;;
        "ScanOval сканирование")
            check_and_run "$SCRIPT_DIR/scripts/scanoval_checker.sh"
            ;;
        "Установка антивирусного ПО")
            check_and_run "$SCRIPT_DIR/scripts/antivirus_installer.sh"
            ;;
        "Работа с системой")
            check_and_run "$SCRIPT_DIR/scripts/hub_sys.sh"
            ;;
        "Инструменты")
            check_and_run "$SCRIPT_DIR/scripts/repo_manager.sh"
            ;;
    esac
done

exit 0
