#!/bin/bash

# ============================================================
# АСТРА LINUX – Полное удаление пользователя и его данных
# Очистка: учетная запись, home dir, macdb, документы.
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
MAC_DB_DIR="/etc/parsec/macdb"

# ----------------------------------------------------------
# Проверка root
# ----------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    whiptail --title "Ошибка" --msgbox "Ошибка: этот модуль должен запускаться от имени root (через sudo)." 8 58
    exit 1
fi

# ----------------------------------------------------------
# 1. Сбор списка пользователей
# ----------------------------------------------------------
declare -a USERS_LIST
declare -A USER_SURNAME
declare -A USER_UID

while IFS=: read -r user pw uid gid gecos home shell; do
    # uid < 1000 — системные учётки, пропускаем
    (( uid < 1000 )) && continue

    # Игнорируем административные записи
    case "$user" in
        nobody|admsec|daemon|bin|sync|halt|shutdown|systemd*|messagebus|polkit*)
            continue
            ;;
    esac

    # Фамилия из GECOS
    surname=$(echo "$gecos" | awk '{print $1}' | sed 's/,.*//')
    
    USERS_LIST+=("$user")
    USER_SURNAME["$user"]="${surname:-Не указана}"
    USER_UID["$user"]="$uid"

done < <(getent passwd)

if (( ${#USERS_LIST[@]} == 0 )); then
    whiptail --title "Инфо" --msgbox "В системе нет доступных для удаления пользовательских записей." 8 58
    exit 0
fi

# ----------------------------------------------------------
# 2. Меню выбора пользователя
# ----------------------------------------------------------
menu_args=()
for i in "${!USERS_LIST[@]}"; do
    user="${USERS_LIST[$i]}"
    menu_args+=("$((i+1))" "$user (${USER_SURNAME[$user]})")
done

choice=$(whiptail --title "Удаление пользователя" \
                  --menu "Выберите пользователя для удаления (Внимание! Данные будут удалены):" \
                  18 76 8 \
                  "${menu_args[@]}" \
                  3>&1 1>&2 2>&3)

exit_code=$?
if [ $exit_code -ne 0 ]; then
    exit 0
fi

idx=$?
if [[ "$choice" =~ ^[0-9]+$ ]]; then
    idx=$((choice-1))
else
    whiptail --title "Ошибка" --msgbox "Некорректный выбор." 8 58
    exit 1
fi

TARGET_USER="${USERS_LIST[$idx]}"
TARGET_UID="${USER_UID[$TARGET_USER]}"
TARGET_SURNAME="${USER_SURNAME[$TARGET_USER]}"

# ----------------------------------------------------------
# 3. Подтверждение удаления
# ----------------------------------------------------------
confirm_msg="ВЫ СОБИРАЕТЕСЬ УДАЛИТЬ ПОЛЬЗОВАТЕЛЯ:\n\n"
confirm_msg+="  Логин:    $TARGET_USER\n"
confirm_msg+="  UID:      $TARGET_UID\n"
confirm_msg+="  Фамилия:  $TARGET_SURNAME\n\n"
confirm_msg+="Будут безвозвратно удалены:\n"
confirm_msg+="  - Учетная запись\n"
confirm_msg+="  - Домашний каталог\n"
confirm_msg+="  - Данные мандатного доступа (Parsec MACDB)\n"
confirm_msg+="  - Каталог документов ($DOCS_BASE/$TARGET_SURNAME)\n\n"
confirm_msg+="Вы действительно хотите продолжить?"

whiptail --title "Подтверждение удаления" --yesno "$confirm_msg" 18 68
if [ $? -ne 0 ]; then
    exit 0
fi

LOG_FILE="/tmp/user_deletion.log"
echo "=== Лог удаления пользователя ===" > "$LOG_FILE"
echo "Пользователь: $TARGET_USER" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# ----------------------------------------------------------
# 4. Процесс удаления
# ----------------------------------------------------------
echo ">>> ПЕРЕХОДИМ К УДАЛЕНИЮ..." >> "$LOG_FILE"

# а) Удаление учетной записи и домашнего каталога
if userdel -r "$TARGET_USER" 2>/dev/null; then
    echo "  [ OK ] Учетная запись и домашний каталог удалены" >> "$LOG_FILE"
else
    # Если залогинен или возникли проблемы
    echo "  [ !! ] Ошибка userdel. Попытка закрыть активные сессии..." >> "$LOG_FILE"
    pkill -u "$TARGET_USER" 2>/dev/null
    sleep 1
    if userdel -r -f "$TARGET_USER" 2>/dev/null; then
        echo "  [ OK ] Учетная запись удалена принудительно" >> "$LOG_FILE"
    else
        echo "  [ !! ] Критическая ошибка при удалении аккаунта" >> "$LOG_FILE"
    fi
fi

# б) Очистка MACDB
MAC_FILE="${MAC_DB_DIR}/${TARGET_UID}"
if [[ -f "$MAC_FILE" ]]; then
    rm -f "$MAC_FILE"
    echo "  [ OK ] Мандатные атрибуты (Parsec MACDB) очищены" >> "$LOG_FILE"
else
    echo "  [ -- ] Запись в MACDB отсутствовала" >> "$LOG_FILE"
fi

# в) Удаление каталога в /home/Документы
DOCS_DIR="${DOCS_BASE}/${TARGET_SURNAME}"
if [[ -n "$TARGET_SURNAME" && "$TARGET_SURNAME" != "Не указана" && -d "$DOCS_DIR" ]]; then
    rm -rf "$DOCS_DIR"
    echo "  [ OK ] Каталог документов ($TARGET_SURNAME) удален" >> "$LOG_FILE"
else
    echo "  [ -- ] Каталог документов не найден" >> "$LOG_FILE"
fi

echo "" >> "$LOG_FILE"
echo "=========================================" >> "$LOG_FILE"
echo "  РАБОТА ЗАВЕРШЕНА" >> "$LOG_FILE"
echo "=========================================" >> "$LOG_FILE"

# Показываем лог в textbox
whiptail --title "Результаты операции" --textbox "$LOG_FILE" 20 76

exit 0
