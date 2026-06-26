#!/bin/bash

# ============================================================
#  ASTRA LINUX – Создание домашних папок пользователей
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

DOCS_BASE="/home/Документы"
MAC_LEVELS="/etc/parsec/mac_levels"
MACDB_DIR="/etc/parsec/macdb"

# ----------------------------------------------------------
# Проверка root
# ----------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    whiptail --title "Ошибка" --msgbox "Ошибка: этот модуль должен запускаться от имени root (sudo)." 8 58
    exit 1
fi

# ----------------------------------------------------------
# 1. Загрузка уровней MAC (с защитой от мусора)
# ----------------------------------------------------------
declare -A NAME_FROM_ID
declare -A ID_FROM_NAME
LEVEL_IDS=()

if [[ ! -f "$MAC_LEVELS" ]]; then
    whiptail --title "Ошибка" --msgbox "Ошибка: файл $MAC_LEVELS не найден!" 8 58
    exit 1
fi

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^# ]] && continue
    [[ "$line" != *:* ]] && continue

    name="${line%%:*}"
    id="${line##*:}"
    NAME_FROM_ID["$id"]="$name"
    ID_FROM_NAME["$name"]="$id"
    LEVEL_IDS+=("$id")
done < "$MAC_LEVELS"

IFS=$'\n' LEVEL_IDS=($(sort -n <<<"${LEVEL_IDS[*]}"))
unset IFS
MAX_LEVEL_ID="${LEVEL_IDS[-1]}"

# ----------------------------------------------------------
# 2. Подготовка списка пользователей
# ----------------------------------------------------------
declare -a ALL_USERS
declare -A USER_SURNAME
declare -A USER_MAX_LEVEL
declare -A USER_MIC_LEVEL

while IFS=: read -r user pw uid gid gecos home shell; do
    (( uid < 1000 )) && continue
    case "$user" in
        nobody|admsec|daemon|bin|sync|halt|shutdown|systemd*|messagebus|polkit*)
            continue
            ;;
    esac

    surname=$(echo "$gecos" | awk '{print $1}' | sed 's/,.*//')
    [[ -z "$surname" ]] && continue
    [[ ! "$surname" =~ ^[А-Яа-яЁё]+$ ]] && continue

    macfile="$MACDB_DIR/$uid"
    lvl=0
    mic=0
    if [[ -f "$macfile" ]]; then
        lvl=$(cut -d: -f4 "$macfile")
        mic=$(cut -d: -f6 "$macfile")
        [[ -z "$mic" ]] && mic=0
    fi

    ALL_USERS+=("$user")
    USER_SURNAME["$user"]="$surname"
    USER_MAX_LEVEL["$user"]="$lvl"
    USER_MIC_LEVEL["$user"]="$mic"

done < <(getent passwd)

if (( ${#ALL_USERS[@]} == 0 )); then
    whiptail --title "Инфо" --msgbox "Нет пользователей с корректными ФИО (кириллица) — нечего создавать." 8 58
    exit 0
fi

# ----------------------------------------------------------
# 3. Меню выбора пользователя
# ----------------------------------------------------------
menu_args=()
for i in "${!ALL_USERS[@]}"; do
    user="${ALL_USERS[$i]}"
    menu_args+=("$((i+1))" "$user (${USER_SURNAME[$user]})")
done
menu_args+=("a" "Обработать ВСЕХ найденных пользователей")

choice=$(whiptail --title "Создание папок пользователей" \
                  --menu "Выберите пользователя для подготовки:" \
                  18 76 8 \
                  "${menu_args[@]}" \
                  3>&1 1>&2 2>&3)

exit_code=$?
if [ $exit_code -ne 0 ]; then
    exit 0
fi

declare -a SELECTED_USERS
case "$choice" in
    a)
        SELECTED_USERS=("${ALL_USERS[@]}")
        ;;
    *)
        idx=$((choice-1))
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( idx >= 0 && idx < ${#ALL_USERS[@]} )); then
            SELECTED_USERS=("${ALL_USERS[$idx]}")
        else
            whiptail --title "Ошибка" --msgbox "Некорректный выбор." 8 58
            exit 1
        fi
        ;;
esac

LOG_FILE="/tmp/folder_creation.log"
echo "=== Лог создания папок для пользователей ===" > "$LOG_FILE"
echo "Базовый каталог: $DOCS_BASE" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# ----------------------------------------------------------
# 4. Проверка базового каталога
# ----------------------------------------------------------
if [[ ! -d "$DOCS_BASE" ]]; then
    echo "  [ !! ] Каталог $DOCS_BASE не найден (создание)" >> "$LOG_FILE"
    if mkdir -p "$DOCS_BASE" 2>/dev/null; then
        chown root:users "$DOCS_BASE"
        chmod 770 "$DOCS_BASE"
        pdpl-file "${MAX_LEVEL_ID}:0:127:ccnr" "$DOCS_BASE" &>/dev/null
        echo "  [ OK ] Базовый каталог успешно создан." >> "$LOG_FILE"
    else
        echo "  [ !! ] Ошибка создания базового каталога." >> "$LOG_FILE"
    fi
fi

# ----------------------------------------------------------
# 5. Обработка выбранных пользователей
# ----------------------------------------------------------
for user in "${SELECTED_USERS[@]}"; do
    surname="${USER_SURNAME[$user]}"
    user_max="${USER_MAX_LEVEL[$user]}"
    user_gid=$(id -gn "$user")
    surdir="$DOCS_BASE/$surname"

    echo ">>> Обслуживание: $user (Фамилия: $surname)" >> "$LOG_FILE"
    echo "    Макс. уровень доступа: ${NAME_FROM_ID[$user_max]}" >> "$LOG_FILE"
    echo "    Уровень целостности:   ${USER_MIC_LEVEL[$user]}" >> "$LOG_FILE"

    # Фамильная папка
    if [[ ! -d "$surdir" ]]; then
        echo "      [+ ] Создаю: $surname" >> "$LOG_FILE"
        mkdir -p "$surdir"
    fi
    chown "$user":"$user_gid" "$surdir"
    chmod 770 "$surdir"
    user_mic="${USER_MIC_LEVEL[$user]}"
    pdpl-file "${user_max}:0:${user_mic}:ccnr" "$surdir" &>/dev/null

    # Уровневые папки
    for lvl in "${LEVEL_IDS[@]}"; do
        (( lvl > user_max )) && continue

        lvl_name="${NAME_FROM_ID[$lvl]}"
        lvl_dir="$surdir/$lvl_name"

        if [[ ! -d "$lvl_dir" ]]; then
            echo "      [+ ] Создаю: $lvl_name" >> "$LOG_FILE"
            mkdir -p "$lvl_dir"
        fi

        chown "$user":"$user_gid" "$lvl_dir"
        chmod 770 "$lvl_dir"

        if pdpl-file --unite "${lvl}:0:${user_mic}:ccnr" "$lvl_dir" &>/dev/null; then
            echo "      [ OK ] Подпапка: $lvl_name (MAC установлен)" >> "$LOG_FILE"
        else
            echo "      [ !! ] Подпапка: $lvl_name (ошибка MAC)" >> "$LOG_FILE"
        fi
    done
    echo "" >> "$LOG_FILE"
done

echo "=========================================" >> "$LOG_FILE"
echo "  РАБОТА ЗАВЕРШЕНА" >> "$LOG_FILE"
echo "=========================================" >> "$LOG_FILE"

# Показываем лог в textbox
whiptail --title "Результаты операции" --textbox "$LOG_FILE" 20 76

exit 0
