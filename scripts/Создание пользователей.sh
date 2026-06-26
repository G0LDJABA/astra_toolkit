#!/bin/bash

# ============================================================
#  АСТРА LINUX – Автоматизированное создание пользователей с МКД
#  Автогенерация userX, фильтр групп, уровни МКД.
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

MAC_LEVELS_FILE="/etc/parsec/mac_levels"
MAC_CAT_FILE="/etc/parsec/mac/mac_categories"
MAC_DB_DIR="/etc/parsec/macdb"
USERADD_BIN=$(command -v useradd 2>/dev/null || echo "/usr/sbin/useradd")

if [[ ! -f "$MAC_LEVELS_FILE" ]]; then
    whiptail --title "Ошибка" --msgbox "Ошибка: файл $MAC_LEVELS_FILE не найден!" 8 58
    exit 1
fi

# Читаем уровни, фильтруем комментарии и сортируем по ID
declare -A LEVEL_NAME LEVEL_ID
i=1
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^# ]] && continue
    [[ "$line" != *:* ]] && continue

    name="${line%%:*}"
    id="${line##*:}"
    
    LEVEL_NAME[$i]="$name"
    LEVEL_ID[$i]="$id"
    ((i++))
done < <(grep -v '^#' "$MAC_LEVELS_FILE" | grep ':' | sort -t: -k2 -n)
TOTAL_LEVELS=$((i-1))

# ============================================================
#        СТАНДАРТНЫЕ ГРУППЫ Astra Linux
# ============================================================
DEFAULT_GROUPS="audio,video,cdrom,floppy,dialout,plugdev,scanner,lp"

# ============================================================
#        ЧТЕНИЕ И ВЫВОД ПОЛИТИКИ ПАРОЛЕЙ
# ============================================================
show_password_policy_text() {
    local pam_file="/etc/pam.d/common-password"
    local out="Требования к сложности пароля (PAM):\n\n"
    
    if [[ ! -f "$pam_file" ]]; then
        out+="* Действуют стандартные правила системы (конфигурация PAM не найдена)."
        echo -e "$out"
        return
    fi

    local line=$(grep "pam_pwquality.so" "$pam_file" | head -n 1)
    if [[ -z "$line" ]]; then
        out+="* Правила сложности в PAM не описаны (действуют умолчания)."
        echo -e "$out"
        return
    fi

    parse_param() {
        local val=$(echo "$line" | grep -o "$1=[-]*[0-9]*" | cut -d= -f2)
        if [[ -n "$val" ]]; then
            if [[ "$val" -lt 0 ]]; then
                echo "${val#-}"
            else
                echo "0"
            fi
        fi
    }

    local p_minlen=$(echo "$line" | grep -o "minlen=[0-9]*" | cut -d= -f2)
    local p_lmin=$(parse_param "lcredit")
    local p_umin=$(parse_param "ucredit")
    local p_dmin=$(parse_param "dcredit")
    local p_omin=$(parse_param "ocredit")

    [[ -n "$p_minlen" ]] && out+="* Минимальная длина: $p_minlen\n"
    [[ "$p_lmin" -gt 0 ]] && out+="* Строчные буквы (abc): минимум $p_lmin\n"
    [[ "$p_umin" -gt 0 ]] && out+="* Заглавные буквы (ABC): минимум $p_umin\n"
    [[ "$p_dmin" -gt 0 ]] && out+="* Цифры (123): минимум $p_dmin\n"
    [[ "$p_omin" -gt 0 ]] && out+="* Спецсимволы (@#$): минимум $p_omin\n"

    [[ "$line" == *"enforce_for_root"* ]] && out+="* Действует для root: Да\n"
    [[ "$line" == *"usercheck=1"* ]]      && out+="* Проверка на имя пользователя: Да\n"
    [[ "$line" == *"gecoscheck=1"* ]]     && out+="* Проверка данных ФИО: Да\n"

    echo -e "$out"
}

# ============================================================
#        ФУНКЦИИ ВВОДА ДАННЫХ
# ============================================================

input_gecos_tui() {
    while true; do
        full_name=$(whiptail --title "Ввод ФИО" \
                             --inputbox "Введите ФИО пользователя (напр. Иванов И.И., минимум 5 символов):" \
                             10 60 "$full_name" \
                             3>&1 1>&2 2>&3)
        [[ $? -ne 0 ]] && return 1
        if [[ ${#full_name} -ge 5 && "$full_name" =~ [А-Яа-яA-Za-z] ]]; then
            break
        else
            whiptail --title "Ошибка" --msgbox "Ошибка: Введите корректное ФИО (минимум 5 символов, буквы)." 8 58
        fi
    done

    while true; do
        gecos_other=$(whiptail --title "Ввод должности" \
                               --inputbox "Введите должность / примечание (минимум 2 символа):" \
                               10 60 "$gecos_other" \
                               3>&1 1>&2 2>&3)
        [[ $? -ne 0 ]] && return 1
        if [[ ${#gecos_other} -ge 2 && "$gecos_other" =~ [А-Яа-яA-Za-z] ]]; then
            break
        else
            whiptail --title "Ошибка" --msgbox "Ошибка: Должность введена некорректно." 8 58
        fi
    done
    gecos="${full_name},,,${gecos_other}"
    return 0
}

select_levels_tui() {
    # Подготовка аргументов для whiptail --menu
    local lvl_args=()
    local n
    for ((n=1; n<=TOTAL_LEVELS; n++)); do
        lvl_args+=("$n" "${LEVEL_NAME[$n]}")
    done

    while true; do
        min_choice=$(whiptail --title "Минимальный уровень доступа" \
                              --menu "Выберите минимальный уровень мандатного доступа:" \
                              18 76 8 \
                              "${lvl_args[@]}" \
                              3>&1 1>&2 2>&3)
        [[ $? -ne 0 ]] && return 1
        break
    done
    MIN_LVL="${LEVEL_ID[$min_choice]}"

    # Максимальный уровень должен быть >= минимального
    local max_lvl_args=()
    for ((n=min_choice; n<=TOTAL_LEVELS; n++)); do
        max_lvl_args+=("$n" "${LEVEL_NAME[$n]}")
    done

    while true; do
        max_choice=$(whiptail --title "Максимальный уровень доступа" \
                              --menu "Выберите максимальный уровень мандатного доступа (>= ${LEVEL_NAME[$min_choice]}):" \
                              18 76 8 \
                              "${max_lvl_args[@]}" \
                              3>&1 1>&2 2>&3)
        [[ $? -ne 0 ]] && return 1
        break
    done
    MAX_LVL="${LEVEL_ID[$max_choice]}"
    return 0
}

select_mic_tui() {
    while true; do
        mic_choice=$(whiptail --title "Уровень целостности (MIC)" \
                              --menu "Выберите уровень целостности для пользователя:" \
                              18 76 4 \
                              "1" "0 - Низкий (Low)" \
                              "2" "63 - Высокий (High)" \
                              "3" "Расширенная настройка (выбор категорий)" \
                              3>&1 1>&2 2>&3)
        [[ $? -ne 0 ]] && return 1
        
        case "$mic_choice" in
            1)
                SEL_MIC="0"
                break
                ;;
            2)
                SEL_MIC="63"
                break
                ;;
            3)
                # Расширенная настройка
                local sum=0
                bit_args=(
                    "1" "[bit 0 / 1] Сетевые сервисы" "OFF"
                    "2" "[bit 1 / 2] Виртуализация" "OFF"
                    "3" "[bit 2 / 4] Специальное ПО" "OFF"
                    "4" "[bit 3 / 8] Графический сервер" "OFF"
                    "5" "[bit 4 / 16] Свободен (СУБД)" "OFF"
                    "6" "[bit 5 / 32] Свободен (Сетевые сервисы доп.)" "OFF"
                    "7" "[bit 6 / 64] Зарезервирован" "OFF"
                    "8" "[bit 7 / 128] Зарезервирован" "OFF"
                )
                
                chosen_bits=$(whiptail --title "Категории целостности" \
                                       --checklist "Выберите категории целостности:" \
                                       18 76 8 \
                                       "${bit_args[@]}" \
                                       3>&1 1>&2 2>&3)
                if [ $? -eq 0 ]; then
                    eval "chosen_bits_arr=($chosen_bits)"
                    local b
                    for b in "${chosen_bits_arr[@]}"; do
                        case $b in
                            1) ((sum += 1)) ;;
                            2) ((sum += 2)) ;;
                            3) ((sum += 4)) ;;
                            4) ((sum += 8)) ;;
                            5) ((sum += 16)) ;;
                            6) ((sum += 32)) ;;
                            7) ((sum += 64)) ;;
                            8) ((sum += 128)) ;;
                        esac
                    done
                    SEL_MIC="$sum"
                    break
                fi
                ;;
        esac
    done
    return 0
}

update_groups_string() {
    final_groups=$(IFS=,; echo "${ADD_GROUPS[*]}")
    final_groups=$(echo "$final_groups" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,,*/,/g; s/^,//; s/,$//')
}

select_groups_tui() {
    if ((${#ADD_GROUPS[@]} == 0)); then
        IFS=',' read -ra ADD_GROUPS <<< "$DEFAULT_GROUPS"
    fi

    while true; do
        update_groups_string
        choice=$(whiptail --title "Настройка групп пользователя" \
                          --menu "Текущие группы: $final_groups\n\nВыберите действие:" \
                          18 76 5 \
                          "1" "Изменить стандартные группы (выбор чекбоксами)" \
                          "2" "Найти и добавить другую группу" \
                          "3" "Удалить группу из списка" \
                          "0" "Готово" \
                          3>&1 1>&2 2>&3)
        [[ $? -ne 0 || "$choice" == "0" ]] && break

        case "$choice" in
            1)
                local std_args=()
                local g
                for g in audio video cdrom floppy dialout plugdev scanner lp; do
                    local status="OFF"
                    if [[ " ${ADD_GROUPS[*]} " =~ " $g " ]]; then
                        status="ON"
                    fi
                    std_args+=("$g" "Стандартная группа" "$status")
                done
                
                chosen=$(whiptail --title "Стандартные группы" \
                                  --checklist "Выберите стандартные группы:" \
                                  18 76 8 \
                                  "${std_args[@]}" \
                                  3>&1 1>&2 2>&3)
                if [ $? -eq 0 ]; then
                    local new_list=()
                    local item
                    for item in "${ADD_GROUPS[@]}"; do
                        if [[ ! " audio video cdrom floppy dialout plugdev scanner lp " =~ " $item " ]]; then
                            new_list+=("$item")
                        fi
                    done
                    eval "chosen_arr=($chosen)"
                    for item in "${chosen_arr[@]}"; do
                        new_list+=("$item")
                    done
                    ADD_GROUPS=("${new_list[@]}")
                fi
                ;;
            2)
                filter=$(whiptail --title "Поиск группы" --inputbox "Введите название или часть названия группы:" 10 60 3>&1 1>&2 2>&3)
                if [[ $? -eq 0 && -n "$filter" ]]; then
                    mapfile -t FILTERED < <(cut -d: -f1 /etc/group | grep -i "$filter" | sort | head -n 30)
                    if ((${#FILTERED[@]} == 0)); then
                        whiptail --title "Результат" --msgbox "Группы по запросу '$filter' не найдены." 8 58
                    else
                        local search_args=()
                        for g in "${FILTERED[@]}"; do
                            local status="OFF"
                            if [[ " ${ADD_GROUPS[*]} " =~ " $g " ]]; then
                                    status="ON"
                            fi
                            search_args+=("$g" "Группа системы" "$status")
                        done
                        
                        chosen_search=$(whiptail --title "Выбор найденных групп" \
                                                 --checklist "Выберите группы для добавления:" \
                                                 18 76 10 \
                                                 "${search_args[@]}" \
                                                 3>&1 1>&2 2>&3)
                        if [ $? -eq 0 ]; then
                            eval "chosen_search_arr=($chosen_search)"
                            for item in "${chosen_search_arr[@]}"; do
                                if [[ ! " ${ADD_GROUPS[*]} " =~ " $item " ]]; then
                                    ADD_GROUPS+=("$item")
                                fi
                            done
                        fi
                    fi
                fi
                ;;
            3)
                if ((${#ADD_GROUPS[@]} == 0)); then
                    whiptail --title "Инфо" --msgbox "Список выбранных групп пуст." 8 58
                    continue
                fi
                
                local del_args=()
                for i in "${!ADD_GROUPS[@]}"; do
                    del_args+=("$((i+1))" "${ADD_GROUPS[$i]}")
                done
                
                to_del=$(whiptail --title "Удаление группы" \
                                  --menu "Выберите группу для удаления из списка:" \
                                  18 76 8 \
                                  "${del_args[@]}" \
                                  3>&1 1>&2 2>&3)
                if [ $? -eq 0 ]; then
                    local idx=$((to_del-1))
                    unset "ADD_GROUPS[$idx]"
                    ADD_GROUPS=("${ADD_GROUPS[@]}")
                fi
                ;;
        esac
    done
}

# ============================================================
#                ОСНОВНОЙ ЦИКЛ СОЗДАНИЯ ПОЛЬЗОВАТЕЛЯ
# ============================================================

while true; do
    # Сброс переменных для нового пользователя
    username=""
    full_name=""
    gecos_other=""
    declare -a ADD_GROUPS=()
    min_choice=1
    max_choice=1
    MIN_LVL=""
    MAX_LVL=""
    SEL_MIC="0"
    sel_cats=0

    # Автогенерация userX
    mapfile -t EXISTING < <(cut -d: -f1 /etc/passwd | grep -E '^user[0-9]+$')
    max_n=0
    for u in "${EXISTING[@]}"; do
        num="${u#user}"
        if [[ "$num" =~ ^[0-9]+$ ]] && (( num > max_n )); then
            max_n=$num
        fi
    done
    next_n=$((max_n + 1))
    suggested_uname="user${next_n}"

    # Ввод имени пользователя
    username=$(whiptail --title "Имя пользователя" \
                         --inputbox "Введите имя пользователя (логин):" \
                         10 60 "$suggested_uname" \
                         3>&1 1>&2 2>&3)
    [[ $? -ne 0 ]] && exit 0

    while true; do
        if [[ -z "$username" ]]; then
            username=$(whiptail --title "Ошибка" --inputbox "Имя пользователя не может быть пустым. Введите имя пользователя:" 10 60 3>&1 1>&2 2>&3)
            [[ $? -ne 0 ]] && exit 0
            continue
        fi
        if id "$username" &>/dev/null; then
            username=$(whiptail --title "Ошибка" --inputbox "Пользователь '$username' уже существует. Введите другое имя:" 10 60 3>&1 1>&2 2>&3)
            [[ $? -ne 0 ]] && exit 0
            continue
        fi
        break
    done

    # Ввод данных по шагам
    input_gecos_tui || exit 0
    select_groups_tui || exit 0
    select_levels_tui || exit 0
    select_mic_tui || exit 0

    # Цикл подтверждения сводки и редактирования
    while true; do
        update_groups_string
        
        summary="Сводка по новому пользователю:\n"
        summary+="  Имя:            $username\n"
        summary+="  ФИО:            $full_name\n"
        summary+="  Должность:      $gecos_other\n"
        summary+="  Группы:         $final_groups\n"
        summary+="  MIN уровень:    ${LEVEL_NAME[$min_choice]}\n"
        summary+="  MAX уровень:    ${LEVEL_NAME[$max_choice]}\n"
        summary+="  Уровень MIC:    $SEL_MIC"

        choice=$(whiptail --title "Подтверждение параметров" \
                          --menu "$summary\n\nВыберите действие:" \
                          20 76 3 \
                          "1" "Создать пользователя" \
                          "2" "Редактировать параметры" \
                          "0" "Отмена" \
                          3>&1 1>&2 2>&3)
        [[ $? -ne 0 || "$choice" == "0" ]] && exit 0

        if [[ "$choice" == "1" ]]; then
            break
        fi

        # Редактирование параметров
        edit_opt=$(whiptail --title "Редактирование параметров" \
                            --menu "Что именно вы хотите изменить?" \
                            18 76 6 \
                            "1" "Имя пользователя [$username]" \
                            "2" "ФИО и должность [$full_name, $gecos_other]" \
                            "3" "Группы [$final_groups]" \
                            "4" "Уровни доступа [${LEVEL_NAME[$min_choice]} - ${LEVEL_NAME[$max_choice]}]" \
                            "5" "Уровень целостности (MIC) [$SEL_MIC]" \
                            "0" "Назад к сводке" \
                            3>&1 1>&2 2>&3)
        [[ $? -ne 0 || "$edit_opt" == "0" ]] && continue

        case "$edit_opt" in
            1)
                new_uname=$(whiptail --title "Новое имя пользователя" --inputbox "Введите имя пользователя:" 10 60 "$username" 3>&1 1>&2 2>&3)
                if [[ $? -eq 0 && -n "$new_uname" ]]; then
                    if id "$new_uname" &>/dev/null; then
                        whiptail --title "Ошибка" --msgbox "Пользователь '$new_uname' уже существует!" 8 58
                    else
                        username="$new_uname"
                    fi
                fi
                ;;
            2)
                # Переопределяем ФИО/должность
                while true; do
                    full_name=$(whiptail --title "Ввод ФИО" --inputbox "Введите ФИО пользователя (минимум 5 символов):" 10 60 "$full_name" 3>&1 1>&2 2>&3)
                    [[ $? -ne 0 ]] && break
                    if [[ ${#full_name} -ge 5 && "$full_name" =~ [А-Яа-яA-Za-z] ]]; then
                        break
                    else
                        whiptail --title "Ошибка" --msgbox "Ошибка: Введите корректное ФИО (минимум 5 символов, буквы)." 8 58
                    fi
                done
                while true; do
                    gecos_other=$(whiptail --title "Ввод должности" --inputbox "Введите должность / примечание:" 10 60 "$gecos_other" 3>&1 1>&2 2>&3)
                    [[ $? -ne 0 ]] && break
                    if [[ ${#gecos_other} -ge 2 && "$gecos_other" =~ [А-Яа-яA-Za-z] ]]; then
                        break
                    else
                        whiptail --title "Ошибка" --msgbox "Ошибка: Должность введена некорректно." 8 58
                    fi
                done
                gecos="${full_name},,,${gecos_other}"
                ;;
            3)
                select_groups_tui
                ;;
            4)
                select_levels_tui
                ;;
            5)
                select_mic_tui
                ;;
        esac
    done

    # Создание пользователя
    if "$USERADD_BIN" -m -g users -c "$gecos" -G "$final_groups" "$username"; then
        UIDN=$(id -u "$username")
        # Запись MACDB
        MAC_LINE="${username}:${MIN_LVL}:${sel_cats}:${MAX_LVL}:${sel_cats}:${SEL_MIC}:0x0"
        echo "$MAC_LINE" > "${MAC_DB_DIR}/${UIDN}"
        chmod 600 "${MAC_DB_DIR}/${UIDN}"
        chown root:root "${MAC_DB_DIR}/${UIDN}"
        
        whiptail --title "Успех" --msgbox "Пользователь $username успешно создан!\n\nЗапись MACDB создана: ${MAC_DB_DIR}/${UIDN}" 10 65
    else
        whiptail --title "Ошибка" --msgbox "Критическая ошибка при создании пользователя." 8 58
        continue
    fi

    # Задание пароля
    whiptail --title "Установка пароля" --yesno "Желаете установить пароль для пользователя $username?" 8 58
    if [ $? -eq 0 ]; then
        policy_msg=$(show_password_policy_text)
        whiptail --title "Требования к сложности" --msgbox "$policy_msg" 14 65
        
        while true; do
            my_password=$(whiptail --title "Ввод пароля" --passwordbox "Введите пароль для $username (или нажмите Cancel для отмены):" 10 60 3>&1 1>&2 2>&3)
            if [[ $? -ne 0 || -z "$my_password" ]]; then
                whiptail --title "Отмена" --msgbox "Установка пароля отменена. Пользователь создан без пароля." 8 58
                break
            fi

            if echo "${username}:${my_password}" | chpasswd; then
                whiptail --title "Успех" --msgbox "Пароль для пользователя $username успешно установлен." 8 58
                break
            else
                whiptail --title "Ошибка" --msgbox "Система отклонила пароль. Пожалуйста, убедитесь, что он удовлетворяет политикам безопасности." 10 58
            fi
        done
    fi

    # Спрашиваем о создании еще одного
    whiptail --title "Продолжить?" --yesno "Желаете создать еще одного пользователя?" 8 58
    [[ $? -eq 0 ]] || exit 0
done

exit 0
