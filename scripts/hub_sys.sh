#!/bin/bash
# ============================================================
#               ХАБ УПРАВЛЕНИЯ: РАБОТА С СИСТЕМОЙ
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

# Проверка на запуск от root (sudo)
if [ "$EUID" -ne 0 ]; then
    whiptail --title "Ошибка" --msgbox "Ошибка: Этот скрипт должен быть запущен от root (sudo)." 8 58
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MAC_FILE="/etc/parsec/mac_levels"

if [[ ! -f "$MAC_FILE" ]]; then
    whiptail --title "Ошибка" --msgbox "Ошибка: Файл $MAC_FILE не найден!" 8 58
    exit 1
fi

# ======================================================
#   ВЫБОР НОВОГО МАКСИМАЛЬНОГО УРОВНЯ МАНДАТНОГО ДОСТУПА
# ======================================================

declare -A LVL_NAME
declare -A LVL_ID
CURRENT_MAX_ID=0

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^# ]] && continue
    [[ "$line" != *:* ]] && continue
    name="${line%%:*}"
    id="${line##*:}"
    LVL_NAME["$id"]="$name"
    LVL_ID["$name"]="$id"
    (( id > CURRENT_MAX_ID )) && CURRENT_MAX_ID="$id"
done < "$MAC_FILE"

CURRENT_MAX_NAME="${LVL_NAME[$CURRENT_MAX_ID]}"

# Инициализация имен по умолчанию
declare -A CUSTOM_NAMES
DEFAULT_VALS=("Несекретно" "ДСП" "Секретно" "Сов.секретно")

# Инициализируем CUSTOM_NAMES текущими значениями из системы или дефолтными
for (( i=0; i<=3; i++ )); do
    if [[ -n "${LVL_NAME[$i]}" ]]; then
        CUSTOM_NAMES[$i]="${LVL_NAME[$i]}"
    else
        CUSTOM_NAMES[$i]="${DEFAULT_VALS[$i]}"
    fi
done

while true; do
    # Шаг 1: Выбор уровня
    lvl_choice=$(whiptail --title "Настройка мандатного уровня доступа (MAC)" \
                          --cancel-button "Назад" \
                          --menu "   ───┤ Управление: ↑/↓ - переход, Enter - выбор, Tab - кнопки ├───\n\nТекущий максимальный уровень: $CURRENT_MAX_ID ($CURRENT_MAX_NAME)\n\nУкажите новый максимальный доступный уровень в системе:" \
                          18 76 5 \
                          "0" "Несекретно" \
                          "1" "ДСП" \
                          "2" "Секретно" \
                          "3" "Сов.секретно" \
                          "4" "Пропустить настройку и оставить текущий" \
                          3>&1 1>&2 2>&3)
    exit_code=$?
    
    # Если нажали ESC / Cancel
    if [ $exit_code -ne 0 ]; then
        echo "Выход в главное меню..."
        exit 0
    fi
    
    if [ "$lvl_choice" = "4" ]; then
        break # Просто выходим из цикла настройки и открываем меню
    fi
    
    target_level_id="$lvl_choice"
    target_level_name="${CUSTOM_NAMES[$target_level_id]}"
    
    # Строим список названий по ГОСТу для выбранного диапазона уровней
    gost_names=""
    for (( i=0; i<=target_level_id; i++ )); do
        if [[ $i -gt 0 ]]; then
            gost_names+=", "
        fi
        gost_names+="${DEFAULT_VALS[$i]}"
    done
    
    # Шаг 2: Выбор режима именования
    name_mode=$(whiptail --title "Режим именования уровней" \
                         --cancel-button "Назад" \
                         --menu "   ───┤ Управление: ↑/↓ - переход, Enter - выбор, Tab - кнопки ├───\n\nВыбран новый максимальный уровень: $target_level_id ($target_level_name)\n\nУровни будут настроены в диапазоне 0 - $target_level_id.\nВыберите режим именования:" \
                         18 76 2 \
                         "1" "Имена по ГОСТ ($gost_names)" \
                         "2" "Задать собственные названия (ручной ввод)" \
                         3>&1 1>&2 2>&3)
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        # Если нажали отмену, возвращаемся к началу цикла
        continue
    fi
    
    # Заполняем имена для текущего выбора (для сброса возможных остатков прошлых итераций)
    for (( i=0; i<=target_level_id; i++ )); do
        # Если в этой итерации мы уже редактировали имя, оставляем его, иначе берем текущее из системы / дефолт
        if [[ -z "${CUSTOM_NAMES[$i]}" ]]; then
            if [[ -n "${LVL_NAME[$i]}" ]]; then
                CUSTOM_NAMES[$i]="${LVL_NAME[$i]}"
            else
                CUSTOM_NAMES[$i]="${DEFAULT_VALS[$i]}"
            fi
        fi
    done
    
    # Шаг 3: Ввод собственных названий
    if [ "$name_mode" = "2" ]; then
        cancelled=false
        for (( i=0; i<=target_level_id; i++ )); do
            current="${CUSTOM_NAMES[$i]}"
            new_name=$(whiptail --title "Название уровня $i" \
                                 --inputbox "Введите название для уровня доступа $i:" \
                                 10 60 "$current" \
                                 3>&1 1>&2 2>&3)
            exit_code=$?
            if [ $exit_code -ne 0 ]; then
                # Отменили ввод конкретного уровня - возвращаемся к началу цикла
                cancelled=true
                break
            fi
            [[ -n "$new_name" ]] && CUSTOM_NAMES[$i]="$new_name"
        done
        if [ "$cancelled" = true ]; then
            continue
        fi
    else
        # Имена по ГОСТ - сбрасываем к дефолтным ГОСТ-значениям
        for (( i=0; i<=target_level_id; i++ )); do
            CUSTOM_NAMES[$i]="${DEFAULT_VALS[$i]}"
        done
    fi
    
    # Шаг 4: Подтверждение
    summary="Итоговый список мандатных уровней:\n\n"
    for (( i=0; i<=target_level_id; i++ )); do
        summary+="  Уровень $i: ${CUSTOM_NAMES[$i]}\n"
    done
    summary+="\nПрименить данные изменения в файле $MAC_FILE?"
    
    whiptail --title "Подтверждение изменений" \
             --yesno "$summary" \
             16 76
    exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        # Если нажали "Нет" - возвращаемся на начало цикла для редактирования
        continue
    fi
    
    # Шаг 5: Запись и перезапуск
    whiptail --title "Настройка MAC" --infobox "Применение настроек...\nОбновление $MAC_FILE и перезапуск службы PARSEC." 10 65
    
    TMP=$(mktemp)
    echo "#levels" > "$TMP"
    for (( i=0; i<=target_level_id; i++ )); do
        printf "%s:%d\n" "${CUSTOM_NAMES[$i]}" "$i" >> "$TMP"
    done
    
    sudo cp "$TMP" "$MAC_FILE"
    rm -f "$TMP"
    
    sudo systemctl restart parsec.service
    
    # Специфичная инициализация Astra
    if [[ -x /usr/lib/parsec/systemd/parsec_systemd_init ]]; then
        sudo /usr/lib/parsec/systemd/parsec_systemd_init start
    fi
    sleep 1
    
    whiptail --title "Успех" --msgbox "Новый набор уровней (0-$target_level_id) успешно применён в системе.\n\nВНИМАНИЕ: Для корректного применения уровней в запущенных сессиях пользователей рекомендуется перезагрузить операционную систему." 10 65
    break # Выходим из цикла настройки, переходим к меню
done

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

default_choice="Создание пользователей (МКД)"
while true; do
    choice=$(whiptail --title "Работа с системой" \
                      --cancel-button "Назад" \
                      --default-item "$default_choice" \
                      --menu "   ───┤ Управление: ↑/↓ - переход, Enter - выбор, Tab - кнопки ├───\n\nВыберите действие для работы с системой:" \
                      18 76 3 \
                      "Создание пользователей (МКД)" "" \
                      "Создание домашних папок пользователей" "" \
                      "Удаление пользователя и его данных" "" \
                      3>&1 1>&2 2>&3)
                      
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        break
    fi
    
    default_choice="$choice"
    
    case "$choice" in
        "Создание пользователей (МКД)")
            check_and_run "$SCRIPT_DIR/Создание пользователей.sh"
            ;;
        "Создание домашних папок пользователей")
            check_and_run "$SCRIPT_DIR/Создание папок для пользователей.sh"
            ;;
        "Удаление пользователя и его данных")
            check_and_run "$SCRIPT_DIR/Удаление пользователя.sh"
            ;;
    esac
done

exit 0
