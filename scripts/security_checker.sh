#!/bin/bash

# ============================================================
#               LINUX & ASTRA SECURITY AUDITOR
# ============================================================
# Скрипт автоматического аудита безопасности АРМ
# Поддержка: Astra Linux (1.8+), Debian, Ubuntu, RHEL/CentOS
# Формирует полностью автономный HTML-отчет и скриншоты окон настроек.
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

# Проверка запуска от имени суперпользователя (root)
if [ "$EUID" -ne 0 ]; then
    whiptail --title "Ошибка" --msgbox "Ошибка: Этот скрипт должен быть запущен от root (sudo)." 8 58
    exit 1
fi

# Каталог скрипта и пути для выгрузки отчета
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPORT_FILE="$ROOT_DIR/report/security_report.html"
SCREENSHOT_DIR="$ROOT_DIR/report/screenshots"
CONFIG_FILE="$ROOT_DIR/service/screenshot_apps.list"
SOFTWARE_FILE="$ROOT_DIR/report/installed_software.txt"

# Определение типа операционной системы для аудита скриншотов (поддерживается только Astra Linux 1.8+)
OS_TYPE="generic"
if [ -f /etc/astra_version ] || grep -q -i 'astra' /etc/os-release 2>/dev/null; then
    OS_TYPE="astra18"
fi

# По умолчанию все модули аудита включены
AUDIT_SYS=true
AUDIT_USER=true
AUDIT_FS=true
AUDIT_NET=true
AUDIT_ASTRA=true
CAPTURE_SCREEN=false
if [ "$OS_TYPE" != "generic" ]; then
    CAPTURE_SCREEN=true
fi

# Функция поиска локальной графической сессии X11
detect_local_x11() {
    DETECTED_DISPLAY=""
    if [ -d /tmp/.X11-unix ]; then
        local disp_num
        disp_num=$(ls /tmp/.X11-unix/ | grep -E '^X' | head -n 1 | sed 's/^X//')
        if [ -n "$disp_num" ]; then
            DETECTED_DISPLAY=":$disp_num"
        fi
    fi
    DETECTED_DISPLAY=${DETECTED_DISPLAY:-":0"}
    
    local local_user=""
    local_user=$(ps aux 2>/dev/null | grep -E 'fly-wm|plasmashell|kwin|fly-dm' | grep -v 'grep' | awk '{print $1}' | grep -v 'root' | sort -u | head -n 1)
    if [ -z "$local_user" ]; then
        local_user=$(who 2>/dev/null | grep -E '(:0|tty7|tty1|console)' | awk '{print $1}' | head -n 1)
    fi
    if [ -z "$local_user" ] && [ -n "$SUDO_USER" ]; then
        local_user="$SUDO_USER"
    fi
    
    DETECTED_XAUTHORITY=""
    if [ -n "$local_user" ]; then
        local user_home
        user_home=$(eval echo "~$local_user")
        if [ -f "$user_home/.Xauthority" ]; then
            DETECTED_XAUTHORITY="$user_home/.Xauthority"
        fi
    fi
    
    if [ -z "$DETECTED_XAUTHORITY" ]; then
        DETECTED_XAUTHORITY=$(find /home -maxdepth 2 -name ".Xauthority" 2>/dev/null | head -n 1)
    fi
}

# Определение параметров X11 для локальной и SSH сессий
detect_local_x11
LOCAL_DISPLAY="$DETECTED_DISPLAY"
LOCAL_XAUTHORITY="$DETECTED_XAUTHORITY"

SSH_DISPLAY="$DISPLAY"
SSH_XAUTHORITY="$XAUTHORITY"

# По умолчанию настраиваем режим захвата скриншотов
SCREENSHOT_X11_MODE="none"
TARGET_DISPLAY=""
TARGET_XAUTHORITY=""
X11_AVAILABLE=false

if [ -n "$LOCAL_XAUTHORITY" ]; then
    SCREENSHOT_X11_MODE="local"
    TARGET_DISPLAY="$LOCAL_DISPLAY"
    TARGET_XAUTHORITY="$LOCAL_XAUTHORITY"
    X11_AVAILABLE=true
    CAPTURE_SCREEN=true
elif [ -n "$SSH_DISPLAY" ]; then
    SCREENSHOT_X11_MODE="ssh"
    TARGET_DISPLAY="$SSH_DISPLAY"
    if [ -n "$SUDO_USER" ]; then
        USER_HOME=$(eval echo "~$SUDO_USER")
        if [ -f "$USER_HOME/.Xauthority" ]; then
            TARGET_XAUTHORITY="$USER_HOME/.Xauthority"
        else
            TARGET_XAUTHORITY="$SSH_XAUTHORITY"
        fi
    else
        TARGET_XAUTHORITY="$SSH_XAUTHORITY"
    fi
    X11_AVAILABLE=true
    CAPTURE_SCREEN=true
fi

# Функция разворачивания графического окна во весь экран через EWMH и ctypes библиотеки X11
maximize_window() {
    local win_id="$1"
    if [ -n "$win_id" ]; then
        DISPLAY="$TARGET_DISPLAY" XAUTHORITY="$TARGET_XAUTHORITY" python3 - "$win_id" <<'PY'
import sys
import ctypes
import ctypes.util

win_id = int(sys.argv[1], 16)
lib = ctypes.util.find_library("X11")
if lib:
    X = ctypes.CDLL(lib)
    Display_p = ctypes.c_void_p
    Window = ctypes.c_ulong
    Atom = ctypes.c_ulong
    Bool = ctypes.c_int
    Status = ctypes.c_int

    X.XOpenDisplay.argtypes = [ctypes.c_char_p]
    X.XOpenDisplay.restype = Display_p
    X.XDefaultRootWindow.argtypes = [Display_p]
    X.XDefaultRootWindow.restype = Window
    X.XInternAtom.argtypes = [Display_p, ctypes.c_char_p, Bool]
    X.XInternAtom.restype = Atom
    X.XSendEvent.argtypes = [Display_p, Window, Bool, ctypes.c_long, ctypes.c_void_p]
    X.XSendEvent.restype = Status
    X.XFlush.argtypes = [Display_p]
    X.XFlush.restype = ctypes.c_int
    X.XCloseDisplay.argtypes = [Display_p]
    X.XCloseDisplay.restype = ctypes.c_int

    display = X.XOpenDisplay(None)
    if display:
        root = X.XDefaultRootWindow(display)
        def atom(name):
            return X.XInternAtom(display, name.encode("ascii"), False)

        _NET_WM_STATE = atom("_NET_WM_STATE")
        _MAX_HORZ = atom("_NET_WM_STATE_MAXIMIZED_HORZ")
        _MAX_VERT = atom("_NET_WM_STATE_MAXIMIZED_VERT")

        ClientMessage = 33
        SubstructureRedirectMask = 1 << 20
        SubstructureNotifyMask = 1 << 19

        class ClientMessageData(ctypes.Union):
            _fields_ = [
                ("b", ctypes.c_char * 20),
                ("s", ctypes.c_short * 10),
                ("l", ctypes.c_long * 5),
            ]

        class XClientMessageEvent(ctypes.Structure):
            _fields_ = [
                ("type", ctypes.c_int),
                ("serial", ctypes.c_ulong),
                ("send_event", Bool),
                ("display", Display_p),
                ("window", Window),
                ("message_type", Atom),
                ("format", ctypes.c_int),
                ("data", ClientMessageData),
            ]

        class XEvent(ctypes.Union):
            _fields_ = [
                ("xclient", XClientMessageEvent),
                ("pad", ctypes.c_long * 24),
            ]

        event = XEvent()
        event.xclient.type = ClientMessage
        event.xclient.serial = 0
        event.xclient.send_event = True
        event.xclient.display = display
        event.xclient.window = win_id
        event.xclient.message_type = _NET_WM_STATE
        event.xclient.format = 32
        event.xclient.data.l[0] = 1
        event.xclient.data.l[1] = _MAX_HORZ
        event.xclient.data.l[2] = _MAX_VERT
        event.xclient.data.l[3] = 1
        event.xclient.data.l[4] = 0

        mask = SubstructureRedirectMask | SubstructureNotifyMask
        X.XSendEvent(display, root, False, mask, ctypes.byref(event))
        X.XFlush(display)
        X.XCloseDisplay(display)
PY
    fi
}

# Предупреждение о необходимости настройки и автоматический запуск окна управления пользователями
if [ "$OS_TYPE" = "astra18" ] && [ "$X11_AVAILABLE" = true ] && command -v astra-systemsettings >/dev/null 2>&1; then
    whiptail --title "ВНИМАНИЕ" --msgbox "Для корректной автоматической съемки скриншотов сейчас будет автоматически открыто окно управления пользователями.\n\nВ появившемся окне с предупреждением о запуске от имени администратора ОБЯЗАТЕЛЬНО установите галочку «Не показывать больше это сообщение» и нажмите ОК.\n\nПосле этого закройте открывшуюся утилиту «Управление пользователями», чтобы продолжить аудит." 15 72
    
    # Запуск утилиты в фоновом режиме, чтобы мы могли найти и максимизировать ее окно
    DISPLAY="$TARGET_DISPLAY" XAUTHORITY="$TARGET_XAUTHORITY" HOME=/root XDG_RUNTIME_DIR="/tmp/runtime-root" astra-systemsettings astra_kcm_users >/dev/null 2>&1 3>&- &
    app_pid=$!
    
    # Поиск ID окна (до 20 попыток)
    win_id=""
    for attempt in $(seq 1 20); do
        win_id="$(
            for wid in $(DISPLAY="$TARGET_DISPLAY" XAUTHORITY="$TARGET_XAUTHORITY" xprop -root _NET_CLIENT_LIST_STACKING 2>/dev/null | grep -o '0x[0-9a-fA-F]\+'); do
                wname=$(DISPLAY="$TARGET_DISPLAY" XAUTHORITY="$TARGET_XAUTHORITY" xprop -id "$wid" WM_NAME 2>/dev/null)
                wclass=$(DISPLAY="$TARGET_DISPLAY" XAUTHORITY="$TARGET_XAUTHORITY" xprop -id "$wid" WM_CLASS 2>/dev/null)
                echo "$wid | $wname | $wclass"
            done | grep -Ei 'astra-systemsettings|Пользователи|пользовател' | tail -n 1 | awk '{print $1}'
        )"
        [ -n "$win_id" ] && break
        sleep 0.5
    done
    
    # Если окно успешно найдено, максимизируем его во весь экран через EWMH
    if [ -n "$win_id" ]; then
        maximize_window "$win_id"
    fi
    
    # Ожидаем закрытия окна пользователем
    wait $app_pid >/dev/null 2>&1
fi



# Поиск ID окна запущенного приложения по имени бинарника и PID
find_window_id() {
    local app_bin="$1"
    local app_pid="$2"
    
    # Нормализуем имя для сравнения классов окон
    local clean_app_bin
    clean_app_bin=$(echo "$app_bin" | tr '[:upper:]' '[:lower:]')
    local norm_app_bin
    norm_app_bin=$(echo "$clean_app_bin" | sed -E 's/^(astra-|fly-admin-|fly-)//')
    
    # 1. Попытка через wmctrl по PID процесса или его дочерних процессов
    if [ -n "$app_pid" ] && command -v wmctrl >/dev/null 2>&1; then
        local win_id
        win_id=$(sh -c 'DISPLAY="$1" XAUTHORITY="$2" wmctrl -lp 2>/dev/null' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" | awk -v pid="$app_pid" '$3 == pid {print $1}' | head -n 1)
        if [ -n "$win_id" ]; then
            echo "$win_id"
            return 0
        fi
        
        # Если wmctrl не нашел по основному PID, попробуем по PID дочерних процессов
        local child_pids
        child_pids=$(pgrep -P "$app_pid" 2>/dev/null)
        for cpid in $child_pids; do
            win_id=$(sh -c 'DISPLAY="$1" XAUTHORITY="$2" wmctrl -lp 2>/dev/null' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" | awk -v pid="$cpid" '$3 == pid {print $1}' | head -n 1)
            if [ -n "$win_id" ]; then
                echo "$win_id"
                return 0
            fi
        done
    fi
    
    # 2. Попытка через xprop (по классу окна WM_CLASS)
    if command -v xprop >/dev/null 2>&1; then
        local client_list
        client_list=$(sh -c 'DISPLAY="$1" XAUTHORITY="$2" xprop -root _NET_CLIENT_LIST 2>/dev/null' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY")
        for win_id in $(echo "$client_list" | grep -o -E '0x[0-9a-fA-F]+'); do
            local win_class
            win_class=$(sh -c 'DISPLAY="$1" XAUTHORITY="$2" xprop -id "$3" WM_CLASS 2>/dev/null' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" "$win_id")
            local clean_win_class
            clean_win_class=$(echo "$win_class" | cut -d'=' -f2 | tr -d '"' | tr ',' ' ' | tr '[:upper:]' '[:lower:]')
            
            # Сравниваем класс окна с именем бинарника
            if echo "$clean_win_class" | grep -q -F "$clean_app_bin" || \
               echo "$clean_win_class" | grep -q -F "$norm_app_bin" || \
               echo "$clean_app_bin" | grep -q -F "$clean_win_class" || \
               { [ "$clean_app_bin" = "astra-systemsettings" ] && echo "$clean_win_class" | grep -q -F "systemsettings"; }; then
                echo "$win_id"
                return 0
            fi
        done
    fi
    
    # 3. Попытка через xwininfo (поиск по совпадению имени в заголовке/классе окна)
    if command -v xwininfo >/dev/null 2>&1; then
        local win_id
        win_id=$(sh -c 'DISPLAY="$1" XAUTHORITY="$2" xwininfo -root -children 2>/dev/null' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" | grep -i -E "($clean_app_bin|$norm_app_bin)" | grep -o -E '0x[0-9a-fA-F]+' | head -n 1)
        if [ -n "$win_id" ]; then
            echo "$win_id"
            return 0
        fi
    fi
    
    return 1
}

# Функция ожидания появления и отрисовки окна приложения
wait_for_window() {
    local app_bin="$1"
    local app_pid="$2"
    local timeout=16  # Максимальное ожидание ~8 секунд (16 * 0.5)
    local elapsed=0
    
    while [ $elapsed -lt $timeout ]; do
        # Проверяем, жив ли процесс или его дети
        local is_alive=false
        if [ -n "$app_pid" ]; then
            if kill -0 "$app_pid" 2>/dev/null; then
                is_alive=true
            else
                local child_pids
                child_pids=$(pgrep -P "$app_pid" 2>/dev/null)
                if [ -n "$child_pids" ]; then
                    is_alive=true
                fi
            fi
        fi
        
        # Если процесс завершился и дочерних процессов нет, даем 2 секунды (4 итерации) буфера 
        # на случай DBus-активации или перехода в фоновый режим перед выходом из цикла.
        if [ "$is_alive" = false ] && [ $elapsed -gt 4 ]; then
            break
        fi
        
        # Пробуем получить ID окна
        local win_id
        win_id=$(find_window_id "$app_bin" "$app_pid")
        if [ -n "$win_id" ]; then
            # Окно найдено, спим дополнительно 3.5 секунды для отрисовки графики
            sleep 3.5
            return 0
        fi
        
        sleep 0.5
        elapsed=$((elapsed + 1))
    done
    
    # Запасное время ожидания, если окно не обнаружилось штатными средствами
    sleep 3
}

# Функция захвата скриншота активного окна настроек системы с фокусом и fallbacks
capture_active_window() {
    local outfile="$1"
    local app_bin="$2"
    local app_pid="$3"
    local temp_shot
    temp_shot=$(mktemp --suffix=.png)
    local success=false
    
    # Ожидаем появление и отрисовку окна приложения
    wait_for_window "$app_bin" "$app_pid"
    
    # Ищем ID окна нашего запущенного приложения
    local win_id
    win_id=$(find_window_id "$app_bin" "$app_pid")
    
    # Если окно найдено, разворачиваем его на весь экран, пробуем активировать его и вывести на передний план
    if [ -n "$win_id" ]; then
        maximize_window "$win_id"
        if command -v xdotool >/dev/null 2>&1; then
            sh -c 'DISPLAY="$1" XAUTHORITY="$2" xdotool windowactivate "$3" >/dev/null 2>&1' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" "$win_id"
            sleep 1.0
        elif command -v wmctrl >/dev/null 2>&1; then
            sh -c 'DISPLAY="$1" XAUTHORITY="$2" wmctrl -i -a "$3" >/dev/null 2>&1' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" "$win_id"
            sleep 1.0
        fi
    fi
    
    # Съемка активного окна
    if [ "$SCREENSHOT_TOOL" = "import" ] && [ -n "$win_id" ]; then
        sh -c 'DISPLAY="$1" XAUTHORITY="$2" import -window "$3" "$4" >/dev/null 2>&1' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" "$win_id" "$temp_shot" && success=true
    elif [ "$SCREENSHOT_TOOL" = "spectacle" ]; then
        sh -c 'DISPLAY="$1" XAUTHORITY="$2" spectacle -a -b -n -o "$3" >/dev/null 2>&1' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" "$temp_shot" && success=true
    elif [ "$SCREENSHOT_TOOL" = "scrot" ]; then
        sh -c 'DISPLAY="$1" XAUTHORITY="$2" scrot -u "$3" >/dev/null 2>&1' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" "$temp_shot" && success=true
    elif [ "$SCREENSHOT_TOOL" = "gnome-screenshot" ]; then
        sh -c 'DISPLAY="$1" XAUTHORITY="$2" gnome-screenshot -w -f "$3" >/dev/null 2>&1' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" "$temp_shot" && success=true
    elif [ "$SCREENSHOT_TOOL" = "import" ]; then
        # Если win_id не найден, но утилита import
        local active_win
        active_win=$(sh -c 'DISPLAY="$1" XAUTHORITY="$2" xprop -root _NET_ACTIVE_WINDOW 2>/dev/null' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" | grep -o -E '0x[0-9a-fA-F]+' | head -n 1)
        if [ -n "$active_win" ]; then
            sh -c 'DISPLAY="$1" XAUTHORITY="$2" import -window "$3" "$4" >/dev/null 2>&1' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" "$active_win" "$temp_shot" && success=true
        else
            sh -c 'DISPLAY="$1" XAUTHORITY="$2" import -window root "$3" >/dev/null 2>&1' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" "$temp_shot" && success=true
        fi
    fi
    
    # Если съемка активного окна не удалась (или вернула пустой/поврежденный файл), пробуем сделать снимок всего экрана в качестве fallback
    if [ "$success" = false ] || [ ! -f "$temp_shot" ] || [ ! -s "$temp_shot" ]; then
        rm -f "$temp_shot"
        temp_shot=$(mktemp --suffix=.png)
        if [ "$SCREENSHOT_TOOL" = "spectacle" ]; then
            sh -c 'DISPLAY="$1" XAUTHORITY="$2" spectacle -f -b -n -o "$3" >/dev/null 2>&1' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" "$temp_shot" && success=true
        elif [ "$SCREENSHOT_TOOL" = "scrot" ]; then
            sh -c 'DISPLAY="$1" XAUTHORITY="$2" scrot "$3" >/dev/null 2>&1' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" "$temp_shot" && success=true
        elif [ "$SCREENSHOT_TOOL" = "gnome-screenshot" ]; then
            sh -c 'DISPLAY="$1" XAUTHORITY="$2" gnome-screenshot -f "$3" >/dev/null 2>&1' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" "$temp_shot" && success=true
        elif [ "$SCREENSHOT_TOOL" = "import" ]; then
            sh -c 'DISPLAY="$1" XAUTHORITY="$2" import -window root "$3" >/dev/null 2>&1' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" "$temp_shot" && success=true
        fi
    fi
    
    if [ "$success" = true ] && [ -f "$temp_shot" ] && [ -s "$temp_shot" ]; then
        mv "$temp_shot" "$outfile"
        chmod 644 "$outfile" 2>/dev/null || true
        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
            chown "$SUDO_USER:$SUDO_USER" "$outfile" 2>/dev/null || true
        fi
        return 0
    else
        rm -f "$temp_shot"
        return 1
    fi
}

# Генерация списка приложений по умолчанию, если файла нет
generate_default_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "=== [ Формирование списка утилит для скриншотов ] ==="
        if [ "$OS_TYPE" = "astra18" ]; then
            cat << 'EOF' > "$CONFIG_FILE"
# Конфигурационный файл графических утилит для Astra Linux 1.8+
astra-systemsettings astra_kcm_policy_lockout:Политика блокировки учетных записей
astra-systemsettings astra_kcm_policy_history:История паролей
astra-systemsettings astra_kcm_policy_complexity:Сложность паролей
astra-systemsettings astra_kcm_policy_expiration:Срок действия паролей
astra-systemsettings astra_kcm_users:Управление пользователями
astra-systemsettings astra_kcm_groups:Управление группами
astra-systemsettings astra_kcm_mac:Мандатный контроль доступа (MAC)
astra-systemsettings astra_kcm_mic:Мандатный контроль целостности (MIC)
astra-systemsettings astra_kcm_policy_clean_memory:Очистка оперативной памяти
EOF
            echo "  [  OK  ] Записаны утилиты аудита безопасности для Astra Linux 1.8."
        else
            # Обычный Linux - список пуст, так как специфических утилит настройки нет
            touch "$CONFIG_FILE"
            echo "  [ INFO ] Generic Linux: список графических утилит пуст."
        fi
    fi
    if [ -f "$CONFIG_FILE" ]; then
        chmod 644 "$CONFIG_FILE" 2>/dev/null || true
        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
            chown "$SUDO_USER:$SUDO_USER" "$CONFIG_FILE" 2>/dev/null || true
        fi
    fi
}
generate_default_config

# Сбор списка установленного ПО в отдельный файл
collect_software_list() {
    echo "=== [ Сбор списка установленного ПО ] ==="
    echo "Сбор списка установленного ПО..."
    
    {
        echo "============================================================"
        echo "           СПИСОК УСТАНОВЛЕННОГО ПО НА АРМ"
        echo "============================================================"
        echo "Хост: $(hostname)"
        echo "Дата сбора: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "------------------------------------------------------------"
        echo
        
        if command -v dpkg >/dev/null 2>&1; then
            echo "Пакетный менеджер: dpkg (Astra Linux / Debian / Ubuntu)"
            echo "Формат вывода: Статус | Имя пакета | Версия | Архитектура | Описание"
            echo "------------------------------------------------------------"
            dpkg -l | grep -E "^ii|^rc"
        elif command -v rpm >/dev/null 2>&1; then
            echo "Пакетный менеджер: rpm (RedHat / CentOS / Fedora)"
            echo "Формат вывода: Имя пакета | Версия | Описание"
            echo "------------------------------------------------------------"
            rpm -qa --qf "%{NAME} | %{VERSION}-%{RELEASE} | %{SUMMARY}\n" | sort
        else
            echo "Не удалось обнаружить стандартный пакетный менеджер (dpkg / rpm)."
        fi
    } > "$SOFTWARE_FILE" 2>&1
    
    echo "  [  OK  ] Список ПО сохранен в: $SOFTWARE_FILE"
}

# Вспомогательные функции терминала
log_ok()  { echo -e "  [  OK  ]${1:+ $1}" >&2; }
log_warn() { echo -e "  [ WARN ]${1:+ $1}" >&2; }
log_crit() { echo -e "  [ CRIT ]${1:+ $1}" >&2; }
log_info() { echo -e "  [ INFO ]${1:+ $1}" >&2; }

# ------------------------------------------------------------
#                   ИНТЕРАКТИВНОЕ ASCII МЕНЮ
# ------------------------------------------------------------
# ------------------------------------------------------------
#                        ГЛАВНЫЙ МЕНЮ-ИНТЕРФЕЙС
# ------------------------------------------------------------

edit_config() {
    # Сначала проверяем, что мы в Astra Linux 1.8+ и утилита astra-systemsettings доступна
    if [ "$OS_TYPE" != "astra18" ] || ! command -v astra-systemsettings >/dev/null 2>&1; then
        whiptail --title "Предупреждение" --msgbox "Редактирование списка через checklist доступно только в Astra Linux 1.8+." 10 60
        return 0
    fi

    local list_out
    list_out=$(astra-systemsettings --list 2>/dev/null)

    # Считываем все модули из вывода команды
    local modules_cmd=()
    local modules_tag=()
    local modules_desc=()
    local modules_sel=()
    local count=0

    # Загружаем текущие активные настройки из CONFIG_FILE
    local active_cmds=()
    if [ -f "$CONFIG_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            [[ -z "$line" ]] && continue
            [[ "$line" =~ ^# ]] && continue
            local cmd
            cmd=$(echo "$line" | cut -d: -f1 | xargs)
            active_cmds+=("$cmd")
        done < "$CONFIG_FILE"
    fi

    # Читаем построчно вывод astra-systemsettings --list
    while IFS= read -r line || [ -n "$line" ]; do
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ - ]]; then
            local mod_name
            mod_name=$(echo "$line" | cut -d- -f1 | xargs)
            local mod_desc
            mod_desc=$(echo "$line" | cut -d- -f2- | xargs)
            
            # Пропускаем служебные заголовки
            [[ "$mod_name" =~ ^(retr0|Доступные|Available) ]] && continue
            [[ -z "$mod_name" ]] && continue
            
            # Формируем команду запуска
            local cmd=""
            if [[ "$mod_name" =~ ^fly-admin- ]]; then
                cmd="$mod_name"
            else
                cmd="astra-systemsettings $mod_name"
            fi
            
            modules_cmd+=("$cmd")
            modules_tag+=("$mod_name")
            modules_desc+=("$mod_desc")
            
            # Проверяем, был ли модуль активен ранее
            local is_active=0
            if [ ${#active_cmds[@]} -eq 0 ]; then
                # Если файл пуст или отсутствует, по умолчанию выбираем базовые модули безопасности
                if [[ "$mod_name" =~ (policy_lockout|policy_history|policy_complexity|policy_expiration|users|groups|mac|mic|policy_clean_memory) ]]; then
                    is_active=1
                fi
            else
                for act in "${active_cmds[@]}"; do
                    if [ "$act" = "$cmd" ]; then
                        is_active=1
                        break
                    fi
                done
            fi
            modules_sel+=($is_active)
            count=$((count + 1))
        fi
    done <<< "$list_out"

    if [ "$count" -eq 0 ]; then
        whiptail --title "Ошибка" --msgbox "Не удалось распарсить модули из вывода astra-systemsettings --list." 10 60
        return 1
    fi

    # Формируем аргументы для whiptail --checklist (используем описание как тег, описание оставляем пустым)
    local checklist_args=()
    for ((i=0; i<count; i++)); do
        local tag="${modules_desc[$i]}"
        local item=""
        local status="OFF"
        if [ "${modules_sel[$i]}" -eq 1 ]; then
            status="ON"
        fi
        checklist_args+=("$tag" "$item" "$status")
    done

    # Вычисляем размеры терминала для динамического изменения размеров окна
    local term_cols term_rows
    term_cols=$(tput cols 2>/dev/null || echo 80)
    term_rows=$(tput lines 2>/dev/null || echo 24)
    
    local win_width=$((term_cols - 6))
    local win_height=$((term_rows - 4))
    
    # Ограничения: ширина от 80 до 115, высота от 15 до 26
    [ "$win_width" -lt 80 ] && win_width=80
    [ "$win_width" -gt 115 ] && win_width=115
    [ "$win_height" -lt 15 ] && win_height=15
    [ "$win_height" -gt 26 ] && win_height=26
    
    local list_height=$((win_height - 8))
    [ "$list_height" -lt 5 ] && list_height=5

    # Показываем whiptail checklist
    local chosen_modules
    chosen_modules=$(whiptail --title "Выбор модулей скриншотов" \
                              --checklist "Выберите пробелом модули, скриншоты которых необходимо снять:" \
                              "$win_height" "$win_width" "$list_height" \
                              "${checklist_args[@]}" \
                              3>&1 1>&2 2>&3)
    local exit_status=$?

    if [ $exit_status -eq 0 ]; then
        # Сохраняем выбор
        {
            echo "# Конфигурационный файл графических утилит для Astra Linux 1.8+"
            for ((i=0; i<count; i++)); do
                local cmd="${modules_cmd[$i]}"
                local item="${modules_desc[$i]}"
                if echo "$chosen_modules" | grep -q -F "\"$item\""; then
                    echo "$cmd:$item"
                else
                    echo "# $cmd:$item"
                fi
            done
        } > "$CONFIG_FILE"
        
        chmod 644 "$CONFIG_FILE" 2>/dev/null || true
        if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
            chown "$SUDO_USER:$SUDO_USER" "$CONFIG_FILE" 2>/dev/null || true
        fi
        
        whiptail --title "Успех" --msgbox "Настройки успешно сохранены!" 8 45
    else
        whiptail --title "Отмена" --msgbox "Изменения отменены." 8 45
    fi
}


# ------------------------------------------------------------
#                  ГЛОБАЛЬНЫЙ БУФЕР ДАННЫХ HTML
# ------------------------------------------------------------
JSON_DATA=""
JSON_SCREENS=""

# Экранирование спецсимволов для JS template literals
escape_js() {
    echo -n "$1" | sed 's/\\/\\\\/g; s/`/\\`/g; s/\$/\\\$/g'
}

run_check() {
    local category="$1"
    local id="$2"
    local title="$3"
    local desc="$4"
    local command="$5"
    
    echo -n "  * $title ... " >&2
    
    local output
    output=$(eval "$command" 2>&1)
    local exit_code=$?
    
    local status="PASSED"
    case $exit_code in
        0)
            status="PASSED"
            log_ok
            ;;
        1)
            status="WARNING"
            log_warn
            ;;
        2)
            status="CRITICAL"
            log_crit
            ;;
        3)
            status="INFO"
            log_info
            ;;
        *)
            status="CRITICAL"
            log_crit
            ;;
    esac
    
    local esc_title
    esc_title=$(escape_js "$title")
    local esc_desc
    esc_desc=$(escape_js "$desc")
    local esc_output
    esc_output=$(escape_js "$output")
    local esc_command
    esc_command=$(escape_js "$command")
    
    JSON_DATA+="{
        category: '${category}',
        id: '${id}',
        title: \`${esc_title}\`,
        desc: \`${esc_desc}\`,
        command: \`${esc_command}\`,
        status: '${status}',
        output: \`${esc_output}\`
    },"
}

# ------------------------------------------------------------
#       ЗАХВАТ СКРИНШОТОВ ДЛЯ ПОЛЬЗОВАТЕЛЕЙ В ASTRA LINUX 1.8+
# ------------------------------------------------------------
capture_screenshots_astra18() {
    local app_cmd="$1"
    local app_name="$2"
    local app_bin="$3"
    local app_path="$4"
    local app_args="$5"
    
    # 1. Проверяем наличие софта и соответствие выводов (согласно patch.txt)
    local check1_ok=false
    local check2_ok=false
    local check3_ok=false
    local check4_ok=false
    
    local out1
    out1=$(which astra-systemsettings 2>/dev/null)
    [ "$out1" = "/usr/bin/astra-systemsettings" ] && check1_ok=true
    
    local out2
    out2=$(which acpi_fakekey 2>/dev/null)
    [ "$out2" = "/usr/bin/acpi_fakekey" ] && check2_ok=true
    
    local out3
    out3=$(which /usr/sbin/aspi_fakekeyd 2>/dev/null)
    if [ "$out3" = "/usr/sbin/aspi_fakekeyd" ]; then
        check3_ok=true
    else
        out3=$(which /usr/sbin/acpi_fakekeyd 2>/dev/null)
        [ "$out3" = "/usr/sbin/acpi_fakekeyd" ] && check3_ok=true
    fi
    
    local out4
    out4=$(ls -l /dev/uinput 2>/dev/null)
    if echo "$out4" | grep -q -E '^crw-------.*root.*root.*/dev/uinput$'; then
        check4_ok=true
    fi
    
    if [ "$check1_ok" = false ] || [ "$check2_ok" = false ] || [ "$check3_ok" = false ] || [ "$check4_ok" = false ]; then
        echo "    [ ERROR ] Проверки ПО для автопереключения пользователей в Astra 1.8 не пройдены!"
        echo "              Фактические выводы:"
        echo "              - which astra-systemsettings: ${out1:-<нет>}"
        echo "              - which acpi_fakekey: ${out2:-<нет>}"
        echo "              - which aspi_fakekeyd: ${out3:-<нет>}"
        echo "              - ls -l /dev/uinput: ${out4:-<нет>}"
        echo "              Сброс в fallback. Скриншоты пользователей не будут созданы."
        return 1
    fi

    # 2. Вычисляем количество пользователей в системе
    local user_list
    user_list=$(getent passwd | awk -F: '$3 >= 1000 && $1 != "nobody" {print $1}' | sort)
    local user_count
    user_count=$(echo "$user_list" | wc -l)
    
    if [ -z "$user_list" ] || [ "$user_count" -eq 0 ]; then
        echo "    [ WARN ] Пользователи с UID >= 1000 не найдены в системе."
        return 0
    fi
    
    # 3. Убедимся, что демон acpi_fakekeyd запущен
    if [ ! -p /var/run/acpi_fakekey ]; then
        echo "    [*] FIFO /var/run/acpi_fakekey не найден. Запускаю acpi_fakekeyd вручную..."
        pkill -f acpi_fakekeyd 2>/dev/null
        pkill -f aspi_fakekeyd 2>/dev/null
        rm -f /var/run/acpi_fakekey /tmp/acpi_fakekeyd.log /tmp/acpi_fakekeyd.pid
        
        nohup "$out3" -f >/tmp/acpi_fakekeyd.log 2>&1 3>&- &
        echo $! > /tmp/acpi_fakekeyd.pid
        sleep 1
    fi
    
    if [ ! -p /var/run/acpi_fakekey ]; then
        echo "    [ ERROR ] FIFO /var/run/acpi_fakekey так и не появился."
        echo "              Лог:"
        cat /tmp/acpi_fakekeyd.log 2>/dev/null
        return 1
    fi

    echo "    [*] Закрываю старые окна astra-systemsettings..."
    pkill -f 'astra-systemsettings astra_kcm_users' 2>/dev/null
    sleep 1

    echo "    [*] Открываю окно пользователей..."
    DISPLAY="$TARGET_DISPLAY" XAUTHORITY="$TARGET_XAUTHORITY" HOME=/root XDG_RUNTIME_DIR="/tmp/runtime-root" "$app_path" $app_args >/dev/null 2>&1 3>&- &
    local app_pid=$!

    # Ищем окно и разворачиваем через EWMH (согласно patch2.txt)
    echo "    [*] Ищу окно astra-systemsettings..."
    local win_id=""
    for attempt in $(seq 1 20); do
        win_id="$(
            for wid in $(DISPLAY="$TARGET_DISPLAY" XAUTHORITY="$TARGET_XAUTHORITY" xprop -root _NET_CLIENT_LIST_STACKING 2>/dev/null | grep -o '0x[0-9a-fA-F]\+'); do
                local wname wclass
                wname=$(DISPLAY="$TARGET_DISPLAY" XAUTHORITY="$TARGET_XAUTHORITY" xprop -id "$wid" WM_NAME 2>/dev/null)
                wclass=$(DISPLAY="$TARGET_DISPLAY" XAUTHORITY="$TARGET_XAUTHORITY" xprop -id "$wid" WM_CLASS 2>/dev/null)
                echo "$wid | $wname | $wclass"
            done | grep -Ei 'astra-systemsettings|Пользователи|пользовател' | tail -n 1 | awk '{print $1}'
        )"
        if [ -n "$win_id" ]; then
            break
        fi
        sleep 0.5
    done

    if [ -z "$win_id" ]; then
        echo "    [ ERROR ] Не удалось найти окно astra-systemsettings."
        kill $app_pid >/dev/null 2>&1
        wait $app_pid >/dev/null 2>&1
        return 1
    fi

    echo "    [*] Найдено окно: $win_id"
    echo "    [*] Разворачиваю окно через EWMH..."
    maximize_window "$win_id"

    sleep 1

    local is_first=true
    local has_focused_list=false
    for u in $user_list; do
        local app_file_name
        app_file_name=$(echo "${app_cmd}_${u}" | tr ' ' '_')
        local screenshot_file="${SCREENSHOT_DIR}/${app_file_name}.png"
        local shot_ok=false
        
        if [ "$is_first" = true ]; then
            is_first=false
            echo "  * Снятие скриншота для первого пользователя ($u)..."
        else
            # Переводим фокус и переключаем
            if [ "$has_focused_list" = false ]; then
                echo "    [*] Перевожу фокус в список пользователей: 3 x Tab..."
                for i in 1 2 3; do
                    "$out2" 15
                    sleep 0.3
                done
                has_focused_list=true
            fi
            echo "    [*] Переключаюсь на следующего пользователя ($u): Down..."
            "$out2" 108
            sleep 0.5
        fi
        
        # Делаем скриншот активного окна (быстрый захват)
        local temp_shot
        temp_shot=$(mktemp --suffix=.png)
        local success=false
        
        if [ -n "$win_id" ]; then
            if command -v xdotool >/dev/null 2>&1; then
                sh -c 'DISPLAY="$1" XAUTHORITY="$2" xdotool windowactivate "$3" >/dev/null 2>&1' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" "$win_id"
                sleep 0.2
            elif command -v wmctrl >/dev/null 2>&1; then
                sh -c 'DISPLAY="$1" XAUTHORITY="$2" wmctrl -i -a "$3" >/dev/null 2>&1' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" "$win_id"
                sleep 0.2
            fi
        fi
        
        if [ "$SCREENSHOT_TOOL" = "import" ] && [ -n "$win_id" ]; then
            sh -c 'DISPLAY="$1" XAUTHORITY="$2" import -window "$3" "$4" >/dev/null 2>&1' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" "$win_id" "$temp_shot" && success=true
        elif [ "$SCREENSHOT_TOOL" = "spectacle" ]; then
            sh -c 'DISPLAY="$1" XAUTHORITY="$2" spectacle -a -b -n -o "$3" >/dev/null 2>&1' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" "$temp_shot" && success=true
        elif [ "$SCREENSHOT_TOOL" = "scrot" ]; then
            sh -c 'DISPLAY="$1" XAUTHORITY="$2" scrot -u "$3" >/dev/null 2>&1' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" "$temp_shot" && success=true
        elif [ "$SCREENSHOT_TOOL" = "gnome-screenshot" ]; then
            sh -c 'DISPLAY="$1" XAUTHORITY="$2" gnome-screenshot -w -f "$3" >/dev/null 2>&1' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" "$temp_shot" && success=true
        fi
        
        # Fallback
        if [ "$success" = false ] || [ ! -f "$temp_shot" ] || [ ! -s "$temp_shot" ]; then
            rm -f "$temp_shot"
            temp_shot=$(mktemp --suffix=.png)
            if [ "$SCREENSHOT_TOOL" = "spectacle" ]; then
                sh -c 'DISPLAY="$1" XAUTHORITY="$2" spectacle -f -b -n -o "$3" >/dev/null 2>&1' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" "$temp_shot" && success=true
            elif [ "$SCREENSHOT_TOOL" = "scrot" ]; then
                sh -c 'DISPLAY="$1" XAUTHORITY="$2" scrot "$3" >/dev/null 2>&1' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" "$temp_shot" && success=true
            elif [ "$SCREENSHOT_TOOL" = "gnome-screenshot" ]; then
                sh -c 'DISPLAY="$1" XAUTHORITY="$2" gnome-screenshot -f "$3" >/dev/null 2>&1' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" "$temp_shot" && success=true
            elif [ "$SCREENSHOT_TOOL" = "import" ]; then
                sh -c 'DISPLAY="$1" XAUTHORITY="$2" import -window root "$3" >/dev/null 2>&1' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY" "$temp_shot" && success=true
            fi
        fi
        
        if [ "$success" = true ] && [ -f "$temp_shot" ] && [ -s "$temp_shot" ]; then
            mv "$temp_shot" "$screenshot_file"
            chmod 644 "$screenshot_file" 2>/dev/null || true
            if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
                chown "$SUDO_USER:$SUDO_USER" "$screenshot_file" 2>/dev/null || true
            fi
            shot_ok=true
        else
            rm -f "$temp_shot"
        fi
        
        if [ "$shot_ok" = true ]; then
            echo "    [  OK  ] Скриншот для пользователя $u успешно сохранен."
            JSON_SCREENS+="{
                cmd: '${app_cmd} ${u}',
                name: '${app_name} (${u})',
                file: 'screenshots/${app_file_name}.png'
            },"
        else
            echo "    [ WARN ] Не удалось снять скриншот для пользователя $u."
        fi
    done
    
    kill $app_pid >/dev/null 2>&1
    wait $app_pid >/dev/null 2>&1
}

# ------------------------------------------------------------
#                    ПРОЦЕСС АУДИТА БЕЗОПАСНОСТИ
# ------------------------------------------------------------
execute_audit() {
    # Сначала проверяем, что генератор отчетов на месте
    if [ ! -f "$ROOT_DIR/service/report_generator.sh" ]; then
        whiptail --title "Ошибка" --msgbox "Ошибка: Файл report_generator.sh не найден!\nГенерация отчета невозможна." 10 60
        return 1
    fi

    mkdir -p "$ROOT_DIR/report"

    JSON_DATA=""
    JSON_SCREENS=""

    # 1. Расчет количества шагов для прогресс-бара
    local test_dir="/usr/lib/parsec/tests"
    local astramode=""
    if command -v astra-modeswitch >/dev/null 2>&1; then
        astramode=$(astra-modeswitch get 2>/dev/null)
    fi
    
    local use_parsec_tests=false
    if [ -d "$test_dir" ] && [ "$astramode" != "0" ]; then
        use_parsec_tests=true
    fi
    
    local active_tests_to_run=()
    if [ "$use_parsec_tests" = true ]; then
        local tests_list=(
            "audit_file.sh:astra:Аудит файлов (audit_file.sh):Проверка механизмов аудита файловых операций PARSEC"
            "audit_proc.sh:astra:Аудит процессов (audit_proc.sh):Проверка механизмов аудита межпроцессного взаимодействия и операций процессов"
            "secdelrm.sh:filesystem:Гарантированное уничтожение (secdelrm.sh):Проверка функции гарантированного удаления файлов (очистка блоков на диске)"
            "rwx.sh:filesystem:Права RWX (rwx.sh):Проверка классических прав доступа к файлам и директориям (DAC)"
            "acl.sh:filesystem:Списки контроля доступа ACL (acl.sh):Проверка расширенных списков контроля доступа к файлам (POSIX ACL)"
            "mem_test:system:Очистка оперативной памяти (mem_test):Проверка механизма очистки освобождаемой оперативной памяти"
            "ipc_dac:system:Разграничение доступа IPC DAC (ipc_dac):Проверка прав доступа к объектам межпроцессного взаимодействия (Shared Memory, Semaphores, Message Queues)"
            "mictest.sh:astra:Контроль целостности MIC (mictest.sh):Проверка мандатного контроля целостности (MIC) PARSEC"
            "chlbl:astra:Изменение меток безопасности (chlbl):Проверка утилиты изменения мандатных меток файлов"
            "chlbl_attrs:astra:Атрибуты меток безопасности (chlbl_attrs):Проверка сохранения и обработки расширенных атрибутов мандатных меток"
            "setlbl:astra:Установка мандатных меток (setlbl):Проверка возможности установки мандатных меток на файлы и каталоги"
            "iterate_dir.sh:filesystem:Обход директорий (iterate_dir.sh):Проверка корректности прав при итерации и поиске файлов в директориях"
            "pdpl_test:astra:Мандатные уровни процессов (pdpl_test):Проверка работы процессов под различными мандатными уровнями (PDPL)"
            "cap_tests.sh:users:Привилегии Linux Capabilities (cap_tests.sh):Аудит системных привилегий процессов и файлов"
        )

        local tests_mac_list=(
            "fmac:astra:Мандатный контроль доступа файлов (fmac):Проверка мандатного контроля доступа к файловой системе (MAC)"
            "ipc_mac:astra:Мандатный контроль IPC (ipc_mac):Проверка мандатных правил при межпроцессном взаимодействии"
            "tcpip_mac.sh:network:Мандатный контроль сетевого трафика IPv4 (tcpip_mac.sh):Проверка разграничения доступа при передаче IPv4 пакетов с мандатными метками"
            "tcpip6_mac.sh:network:Мандатный контроль сетевого трафика IPv6 (tcpip6_mac.sh):Проверка разграничения доступа при передаче IPv6 пакетов с мандатными метками"
            "cap_mac:astra:Мандатные привилегии Capabilities (cap_mac):Проверка совместной работы Linux Capabilities и мандатного контроля доступа PARSEC"
        )

        local all_tests=("${tests_list[@]}")
        if astra-mac-control status >/dev/null 2>&1; then
            all_tests+=("${tests_mac_list[@]}")
        fi
        
        for item in "${all_tests[@]}"; do
            local test_file category title desc enabled
            IFS=':' read -r test_file category title desc <<< "$item"
            enabled=false
            case "$category" in
                system)     [ "$AUDIT_SYS" = true ] && enabled=true ;;
                users)      [ "$AUDIT_USER" = true ] && enabled=true ;;
                filesystem) [ "$AUDIT_FS" = true ] && enabled=true ;;
                network)    [ "$AUDIT_NET" = true ] && enabled=true ;;
                astra)      [ "$AUDIT_ASTRA" = true ] && enabled=true ;;
            esac
            if [ "$enabled" = true ]; then
                active_tests_to_run+=("$item")
            fi
        done
    fi

    local active_tests_count=${#active_tests_to_run[@]}

    local active_screenshot_apps=()
    local screenshot_steps=0
    local active_count=0
    if [ -f "$CONFIG_FILE" ]; then
        active_count=$(grep -v -E '^\s*#|^\s*$' "$CONFIG_FILE" | wc -l)
    fi
    if [ "$CAPTURE_SCREEN" = true ] && [ "$active_count" -gt 0 ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            [[ -z "$line" ]] && continue
            [[ "$line" =~ ^# ]] && continue
            active_screenshot_apps+=("$line")
            screenshot_steps=$((screenshot_steps + 1))
        done < "$CONFIG_FILE"
    fi

    # Итоговое количество шагов
    local total_steps=1
    if [ "$use_parsec_tests" = true ]; then
        total_steps=$((total_steps + active_tests_count))
    else
        total_steps=$((total_steps + 1))
    fi
    total_steps=$((total_steps + screenshot_steps))
    total_steps=$((total_steps + 1)) # Генерация HTML

    local current_step=0
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

    # Запускаем аудит с перенаправлением вывода в лог-файл, а прогресса в whiptail
    {
        # Сохраняем FD 1 (пайп к whiptail) в FD 3
        exec 3>&1
        
        # Перенаправляем стандартный вывод и ошибки этого подоболочечного процесса в лог-файл
        exec > /tmp/security_checker_raw.log 2>&1
        # 1. Сбор состава ПО
        update_progress "Сбор списка установленного ПО..."
        collect_software_list

        # 2. Выполнение тестов
        if [ "$use_parsec_tests" = true ]; then
            local execaps_command=""
            if [ -x /usr/bin/pscaps ]; then
                local current_caps
                current_caps=$(/usr/bin/pscaps 0 2>/dev/null)
                if [ "$current_caps" != "00000000 00000000 00000000" ] && [ -n "$current_caps" ] && [ -x /usr/sbin/execaps ]; then
                    execaps_command="/usr/sbin/execaps -c 0x0 -- "
                fi
            fi

            for item in "${active_tests_to_run[@]}"; do
                local test_file category title desc
                IFS=':' read -r test_file category title desc <<< "$item"
                update_progress "Тест: $title"
                if [ ! -r "$test_dir/$test_file" ]; then
                    run_check "$category" "$test_file" "$title" "$desc" "echo 'Файл теста $test_file не найден в $test_dir'; exit 2"
                else
                    run_check "$category" "$test_file" "$title" "$desc" "cd $test_dir && $execaps_command ./$test_file"
                fi
            done
        else
            if [ ! -d "$test_dir" ]; then
                update_progress "Ошибка: тесты PARSEC недоступны"
                run_check "astra" "parsec_tests_missing" "Тесты PARSEC недоступны" \
                    "Каталог $test_dir не найден в системе." \
                    "echo 'Установите пакет parsec-tests для запуска сертифицированных тестов PARSEC.'; exit 2"
            else
                update_progress "Ошибка: тестирование PARSEC неприменимо"
                run_check "astra" "parsec_not_applicable" "Тестирование PARSEC неприменимо" \
                    "Тесты parsec не применимы в режиме Orel (Common Edition)." \
                    "echo 'Переключите систему в режим Воронеж или Смоленск для работы PARSEC.'; exit 3"
            fi
        fi

        # Очистка временных ресурсов тестирования
        rm -rf "$TESTDIR_PATH"
        if [ -x /usr/sbin/pdp-init-fs ]; then
            /usr/sbin/pdp-init-fs --after-test >/dev/null 2>&1
        fi

        # 3. Снятие скриншотов
        if [ "$CAPTURE_SCREEN" = true ] && [ "$screenshot_steps" -gt 0 ]; then
            if [ "$X11_AVAILABLE" = false ]; then
                echo "  [ WARN ] Ошибка X11: Графическая сессия недоступна. Скриншоты пропущены." >&2
                for app_line in "${active_screenshot_apps[@]}"; do
                    update_progress "Пропуск скриншота: X11 недоступен"
                done
            else
                mkdir -p "$SCREENSHOT_DIR"
                mkdir -p /tmp/runtime-root && chmod 700 /tmp/runtime-root 2>/dev/null || true
                
                if [ -n "$TARGET_XAUTHORITY" ] && [ -f "$TARGET_XAUTHORITY" ]; then
                    xauth merge "$TARGET_XAUTHORITY" >/dev/null 2>&1
                    export XAUTHORITY="$TARGET_XAUTHORITY"
                fi
                export DISPLAY="$TARGET_DISPLAY"
                
                sh -c 'DISPLAY="$1" XAUTHORITY="$2" xset dpms force on >/dev/null 2>&1' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY"
                sh -c 'DISPLAY="$1" XAUTHORITY="$2" xset s reset >/dev/null 2>&1' _ "$TARGET_DISPLAY" "$TARGET_XAUTHORITY"
                
                local SCREENSHOT_TOOL=""
                if command -v spectacle >/dev/null 2>&1; then
                    SCREENSHOT_TOOL="spectacle"
                elif command -v scrot >/dev/null 2>&1; then
                    SCREENSHOT_TOOL="scrot"
                elif command -v import >/dev/null 2>&1; then
                    SCREENSHOT_TOOL="import"
                elif command -v gnome-screenshot >/dev/null 2>&1; then
                    SCREENSHOT_TOOL="gnome-screenshot"
                fi
                
                if [ -z "$SCREENSHOT_TOOL" ]; then
                    echo "  [ WARN ] Утилита скриншотов не найдена. Скриншоты пропущены." >&2
                    for app_line in "${active_screenshot_apps[@]}"; do
                        update_progress "Пропуск скриншота: нет утилиты"
                    done
                else
                    for app_line in "${active_screenshot_apps[@]}"; do
                        local app_cmd=$(echo "$app_line" | cut -d: -f1)
                        local app_name=$(echo "$app_line" | cut -d: -f2)
                        
                        update_progress "Снимок: $app_name"
                        
                        local app_bin
                        app_bin=$(echo "$app_cmd" | awk '{print $1}')
                        local app_args
                        app_args=$(echo "$app_cmd" | cut -d' ' -f2-)
                        if [ "$app_args" = "$app_cmd" ]; then
                            app_args=""
                        fi
                        
                        local app_path=""
                        if command -v "$app_bin" >/dev/null 2>&1; then
                            app_path=$(command -v "$app_bin")
                        elif [ -x "/usr/sbin/$app_bin" ]; then
                            app_path="/usr/sbin/$app_bin"
                        elif [ -x "/usr/bin/$app_bin" ]; then
                            app_path="/usr/bin/$app_bin"
                        elif [ -x "/sbin/$app_bin" ]; then
                            app_path="/sbin/$app_bin"
                        elif [ -x "/bin/$app_bin" ]; then
                            app_path="/bin/$app_bin"
                        fi
                        
                        if [ -z "$app_path" ]; then
                            echo "    [ -- ] Исполняемый файл $app_bin отсутствует в системе. Пропуск." >&2
                            continue
                        fi
                        
                        local is_user_tool=false
                        if [[ "$app_cmd" =~ astra_kcm_users ]]; then
                            is_user_tool=true
                        fi
                        
                        if [ "$is_user_tool" = true ]; then
                            capture_screenshots_astra18 "$app_cmd" "$app_name" "$app_bin" "$app_path" "$app_args"
                            continue
                        fi

                        echo "  * Запуск утилиты $app_cmd ($app_name)..." >&2
                        
                        DISPLAY="$TARGET_DISPLAY" XAUTHORITY="$TARGET_XAUTHORITY" HOME=/root XDG_RUNTIME_DIR="/tmp/runtime-root" "$app_path" $app_args >/dev/null 2>&1 3>&- &
                        local APP_PID=$!
                        
                        local app_file_name
                        app_file_name=$(echo "$app_cmd" | tr ' ' '_')
                        local screenshot_file="${SCREENSHOT_DIR}/${app_file_name}.png"
                        local shot_ok=false
                        
                        capture_active_window "$screenshot_file" "$app_bin" "$APP_PID" && shot_ok=true
                        
                        kill $APP_PID >/dev/null 2>&1
                        wait $APP_PID >/dev/null 2>&1
                        
                        if [ "$shot_ok" = true ]; then
                            echo "    [  OK  ] Скриншот успешно сохранен." >&2
                            JSON_SCREENS+="{
                                cmd: '${app_cmd}',
                                name: '${app_name}',
                                file: 'screenshots/${app_file_name}.png'
                            },"
                        else
                            echo "    [ WARN ] Не удалось снять скриншот для $app_cmd." >&2
                        fi
                    done
                fi
            fi
        fi

        # 4. Генерация HTML-отчета
        update_progress "Генерация HTML-отчета..."
        generate_html
    } | whiptail --gauge "Выполнение аудита безопасности..." 10 70 0

    if [ -n "$SUDO_UID" ] && [ -n "$SUDO_GID" ]; then
        chown -R "$SUDO_UID:$SUDO_GID" "$ROOT_DIR/report" 2>/dev/null
    fi

    whiptail --title "Аудит завершен" --msgbox "Аудит безопасности успешно завершен.\n\nОтчет сохранен в:\n$REPORT_FILE\n\nПодробный лог выполнения доступен в:\n/tmp/security_checker_raw.log" 14 76
}

# ------------------------------------------------------------
#                  ГЕНЕРАЦИЯ HTML-ОТЧЕТА (ОФЛАЙН)
# ------------------------------------------------------------
generate_html() {
    if [ -f "$ROOT_DIR/service/report_generator.sh" ]; then
        source "$ROOT_DIR/service/report_generator.sh" >> /tmp/security_checker_raw.log 2>&1
    else
        {
            echo "============================================================"
            echo "  [ !! ] Ошибка: Файл report_generator.sh не найден!"
            echo "         Генерация HTML-отчета невозможна."
            echo "============================================================"
        } >> /tmp/security_checker_raw.log 2>&1
    fi
}

# ------------------------------------------------------------
#                  ФУНКЦИИ КОНТРОЛЯ СООТВЕТСТВИЯ РД АС
# ------------------------------------------------------------
get_pwquality_param() {
    local key="$1"
    local file="/etc/security/pwquality.conf"
    [ ! -f "$file" ] && { echo "0"; return; }
    local val
    val=$(grep -E "^\s*${key}\s*=" "$file" | cut -d= -f2 | tr -d ' \t\r\n')
    if [ -z "$val" ]; then
        val=$(grep -E "^\s*#\s*${key}\s*=" "$file" | cut -d= -f2 | tr -d ' \t\r\n')
    fi
    echo "${val:-0}"
}

get_logindefs_param() {
    local key="$1"
    local file="/etc/login.defs"
    [ ! -f "$file" ] && { echo "0"; return; }
    local val
    val=$(grep -E "^\s*${key}\s+" "$file" | awk '{print $2}' | tr -d '\r\n')
    echo "${val:-0}"
}

get_faillock_param() {
    local key="$1"
    local file="/etc/security/faillock.conf"
    [ ! -f "$file" ] && { echo "0"; return; }
    local val
    val=$(grep -E "^\s*${key}\s*=" "$file" | cut -d= -f2 | tr -d ' \t\r\n')
    echo "${val:-0}"
}

get_password_history() {
    local file="/etc/pam.d/common-password"
    [ ! -f "$file" ] && { echo "0"; return; }
    local val
    val=$(grep -E "pam_unix.so" "$file" | grep -oE "remember=[0-9]+" | cut -d= -f2)
    echo "${val:-0}"
}

get_tmout() {
    local file="/etc/profile.d/tmout.sh"
    [ ! -f "$file" ] && { echo "0"; return; }
    local val
    val=$(grep -oE "TMOUT=[0-9]+" "$file" | cut -d= -f2)
    echo "${val:-0}"
}

get_astra_control_status() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        echo "Не установлено"
        return
    fi
    local status
    status=$("$cmd" status 2>/dev/null)
    if [[ "$status" == *"enabled"* || "$status" == *"активен"* || "$status" == *"включен"* ]]; then
        echo "Включен"
    else
        echo "Выключен"
    fi
}

apply_remediation_pwquality() {
    local req_val="$1"
    local file="/etc/security/pwquality.conf"
    [ ! -f "$file" ] && return 1
    if grep -qE "^\s*#?\s*minlen\s*=" "$file"; then
        sed -i -E "s/^\s*#?\s*minlen\s*=\s*.*/minlen = $req_val/" "$file"
    else
        echo "minlen = $req_val" >> "$file"
    fi
}

apply_remediation_pam_history() {
    local req_val="$1"
    local file="/etc/pam.d/common-password"
    [ ! -f "$file" ] && return 1
    if grep -q "pam_unix.so" "$file"; then
        if grep -qE "pam_unix.so.*remember=" "$file"; then
            sed -i -E "s/(pam_unix.so.*)remember=[0-9]+/\1remember=$req_val/" "$file"
        else
            sed -i -E "s/(pam_unix.so.*)/\1 remember=$req_val/" "$file"
        fi
    fi
}

apply_remediation_logindefs() {
    local key="$1"
    local req_val="$2"
    local file="/etc/login.defs"
    [ ! -f "$file" ] && return 1
    if grep -qE "^\s*#?\s*${key}\s+" "$file"; then
        sed -i -E "s/^\s*#?\s*${key}\s+[0-9]+/${key}   $req_val/" "$file"
    else
        echo "${key}   $req_val" >> "$file"
    fi
}

apply_remediation_faillock() {
    local key="$1"
    local req_val="$2"
    local file="/etc/security/faillock.conf"
    [ ! -f "$file" ] && return 1
    if grep -qE "^\s*#?\s*${key}\s*=" "$file"; then
        sed -i -E "s/^\s*#?\s*${key}\s*=\s*.*/${key} = $req_val/" "$file"
    else
        echo "${key} = $req_val" >> "$file"
    fi
}

apply_remediation_tmout() {
    local req_val="$1"
    local file="/etc/profile.d/tmout.sh"
    mkdir -p "$(dirname "$file")"
    echo "readonly TMOUT=$req_val" > "$file"
    echo "export TMOUT" >> "$file"
    chmod +x "$file"
}

apply_remediation_astra_control() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        return 1
    fi
    "$cmd" enable >/dev/null 2>&1
}

apply_remediation_auditd() {
    local target_class="$1"
    systemctl enable --now auditd >/dev/null 2>&1
    if [ "$target_class" = "1А" ]; then
        local rule_file="/etc/audit/rules.d/audit.rules"
        if [ ! -f "$rule_file" ]; then
            mkdir -p "$(dirname "$rule_file")"
            touch "$rule_file"
        fi
        if ! grep -q "time-change" "$rule_file"; then
            echo "-w /etc/localtime -p wa -k time-change" >> "$rule_file"
        fi
        if ! grep -q "identity" "$rule_file"; then
            echo "-w /etc/group -p wa -k identity" >> "$rule_file"
            echo "-w /etc/passwd -p wa -k identity" >> "$rule_file"
            echo "-w /etc/gshadow -p wa -k identity" >> "$rule_file"
            echo "-w /etc/shadow -p wa -k identity" >> "$rule_file"
            echo "-w /etc/security/opasswd -p wa -k identity" >> "$rule_file"
        fi
        service auditd restart >/dev/null 2>&1 || systemctl restart auditd >/dev/null 2>&1
    fi
}

check_class_compliance() {
    # Вопрос 1: Тип системы
    local sys_type
    sys_type=$(whiptail --title "Тип системы (Вопрос 1 из 3)" \
                        --cancel-button "Назад" \
                        --menu "Укажите тип автоматизированной системы:" \
                        15 76 2 \
                        "1" "Однопользовательская система (класс 3)" \
                        "2" "Многопользовательская система (класс 1 или 2)" \
                        3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && return
    
    # Вопрос 2: Права доступа (только если многопользовательская)
    local rights_type="1"
    if [ "$sys_type" = "2" ]; then
        rights_type=$(whiptail --title "Доступ к информации (Вопрос 2 из 3)" \
                              --cancel-button "Назад" \
                              --menu "Укажите распределение прав доступа пользователей:" \
                              15 76 2 \
                              "1" "Одинаковые права доступа ко всей информации (класс 2)" \
                              "2" "Разные права доступа к информации (класс 1)" \
                              3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && return
    fi
    
    # Вопрос 3: Максимальный уровень
    local lvl_options=()
    local has_mac_levels=false
    if [ -f "/etc/parsec/mac_levels" ]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            [[ "$line" =~ ^# ]] && continue
            [[ "$line" != *:* ]] && continue
            local name="${line%%:*}"
            local id="${line##*:}"
            id=$(echo "$id" | tr -d ' \t\r\n')
            if [[ "$id" =~ ^[0-9]+$ ]]; then
                lvl_options+=("$id" "$name")
                has_mac_levels=true
            fi
        done < "/etc/parsec/mac_levels"
    fi
    if [ "$has_mac_levels" = false ]; then
        lvl_options=(
            "0" "Несекретно"
            "1" "ДСП (Конфиденциально)"
            "2" "Секретно"
            "3" "Совершенно секретно"
        )
    fi
    
    local max_level
    max_level=$(whiptail --title "Максимальный гриф (Вопрос 3 из 3)" \
                        --cancel-button "Назад" \
                        --menu "Укажите максимальный гриф конфиденциальности информации в АС:" \
                        18 76 6 \
                        "${lvl_options[@]}" \
                        3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && return
    
    # Определение класса АС по РД 1992
    local target_class=""
    local class_desc=""
    
    if [ "$sys_type" = "1" ]; then
        if [ "$max_level" = "1" ]; then
            target_class="3Б"
            class_desc="Однопользовательская АС для конфиденциальной информации"
        else
            target_class="3А"
            class_desc="Однопользовательская АС для государственной тайны"
        fi
    elif [ "$rights_type" = "1" ]; then
        if [ "$max_level" = "1" ]; then
            target_class="2Б"
            class_desc="Многопользовательская АС с одинаковыми правами для конфиденциальной информации"
        else
            target_class="2А"
            class_desc="Многопользовательская АС с одинаковыми правами для государственной тайны"
        fi
    else
        if [ "$max_level" = "1" ]; then
            target_class="1Г"
            class_desc="Многопользовательская АС с разными правами для конфиденциальной информации"
        elif [ "$max_level" = "2" ]; then
            target_class="1В"
            class_desc="Многопользовательская АС для информации с грифом 'Секретно'"
        elif [ "$max_level" = "3" ]; then
            target_class="1Б"
            class_desc="Многопользовательская АС для информации с грифом 'Совершенно секретно'"
        else
            target_class="1А"
            class_desc="Многопользовательская АС для информации с грифом 'Особой важности'"
        fi
    fi
    
    # Инициализация целевых требований по классу (дефолтные значения)
    local req_len=0
    local req_hist=0
    local req_max_days=0
    local req_deny=0
    local req_unlock_time=0
    local req_tmout=0
    local req_secdel="optional"
    local req_swap="optional"
    local req_console="optional"
    local req_ptrace="optional"
    local req_interpreters="optional"
    local req_audit="optional"
    
    local config_file="$ROOT_DIR/service/compliance_standards.conf"
    local config_loaded=false
    
    if [ -f "$config_file" ]; then
        # Извлекаем строки из нужной секции в INI-файле
        # sed находит секцию [$target_class] и печатает строки до следующей секции [
        local section_content
        section_content=$(sed -n "/^\[$target_class\]/,/^\[/p" "$config_file" | tr -d '\r' | grep -v -E '^\[|^#|^\s*$')
        
        if [ -n "$section_content" ]; then
            config_loaded=true
            while IFS= read -r line; do
                [ -z "$line" ] && continue
                if [[ "$line" =~ ^[a-zA-Z_][a-zA-Z0-9_]*=.*$ ]]; then
                    local var_name="${line%%=*}"
                    local var_value="${line#*=}"
                    # Удаляем кавычки, если они есть
                    var_value="${var_value#\"}"
                    var_value="${var_value%\"}"
                    var_value="${var_value#\'}"
                    var_value="${var_value%\'}"
                    
                    case "$var_name" in
                        req_len) req_len="$var_value" ;;
                        req_hist) req_hist="$var_value" ;;
                        req_max_days) req_max_days="$var_value" ;;
                        req_deny) req_deny="$var_value" ;;
                        req_unlock_time) req_unlock_time="$var_value" ;;
                        req_tmout) req_tmout="$var_value" ;;
                        req_secdel) req_secdel="$var_value" ;;
                        req_swap) req_swap="$var_value" ;;
                        req_console) req_console="$var_value" ;;
                        req_ptrace) req_ptrace="$var_value" ;;
                        req_interpreters) req_interpreters="$var_value" ;;
                        req_audit) req_audit="$var_value" ;;
                    esac
                fi
            done <<< "$section_content"
        fi
    fi

    if [ "$config_loaded" = false ]; then
        # Если файл конфигурации отсутствует или пуст, используем жестко зашитые дефолтные требования
        case "$target_class" in
            "3Б"|"2Б"|"1Д"|"1Г")
                req_len=6
                req_hist=0
                req_max_days=180
                req_deny=5
                req_unlock_time=300
                req_tmout=1800
                ;;
            "3А"|"2А"|"1В")
                req_len=6
                req_hist=1
                req_max_days=90
                req_deny=5
                req_unlock_time=900
                req_tmout=600
                req_swap="Включен"
                req_console="Включен"
                req_ptrace="Включен"
                req_audit="Включен"
                ;;
            "1Б")
                req_len=8
                req_hist=1
                req_max_days=60
                req_deny=3
                req_unlock_time=1800
                req_tmout=300
                req_secdel="Включен"
                req_swap="Включен"
                req_console="Включен"
                req_ptrace="Включен"
                req_interpreters="Включен"
                req_audit="Включен"
                ;;
            "1А")
                req_len=8
                req_hist=1
                req_max_days=30
                req_deny=3
                req_unlock_time=3600
                req_tmout=300
                req_secdel="Включен"
                req_swap="Включен"
                req_console="Включен"
                req_ptrace="Включен"
                req_interpreters="Включен"
                req_audit="Включен (строгие правила)"
                ;;
        esac
    fi
    
    # ------------------------------------------------------------
    # ПЕРВЫЙ ЭТАП: Замер текущих показателей системы
    # ------------------------------------------------------------
    local status_len=false
    local status_hist=false
    local status_max_days=false
    local status_deny=false
    local status_unlock_time=false
    local status_tmout=false
    local status_secdel="optional"
    local status_swap="optional"
    local status_console="optional"
    local status_ptrace="optional"
    local status_interpreters="optional"
    local status_audit="optional"

    # Замер длины пароля
    local cur_len
    cur_len=$(get_pwquality_param "minlen")
    [ "$cur_len" -ge "$req_len" ] && status_len=true

    # Замер истории паролей
    local cur_hist
    cur_hist=$(get_password_history)
    [ "$cur_hist" -ge "$req_hist" ] && status_hist=true

    # Замер срока действия паролей
    local cur_max_days
    cur_max_days=$(get_logindefs_param "PASS_MAX_DAYS")
    [ "$cur_max_days" -le "$req_max_days" ] && [ "$cur_max_days" -gt 0 ] && status_max_days=true

    # Замер попыток и времени блокировки
    local cur_deny="0"
    local cur_time="0"
    if [ -f "/etc/security/faillock.conf" ]; then
        cur_deny=$(get_faillock_param "deny")
        cur_time=$(get_faillock_param "unlock_time")
    fi
    [ "$cur_deny" -le "$req_deny" ] && [ "$cur_deny" -gt 0 ] && status_deny=true
    ( [ "$cur_time" -eq 0 ] || [ "$cur_time" -ge "$req_unlock_time" ] ) && status_unlock_time=true

    # Замер таймаута сессии
    local cur_tmout
    cur_tmout=$(get_tmout)
    [ "$cur_tmout" -le "$req_tmout" ] && [ "$cur_tmout" -gt 0 ] && status_tmout=true

    # Замер блокировок Astra
    local cur_secdel="optional"
    if [ "$req_secdel" = "Включен" ]; then
        cur_secdel=$(get_astra_control_status "astra-secdel-control")
        if [ "$cur_secdel" = "Включен" ]; then status_secdel=true; else status_secdel=false; fi
    fi

    local cur_swap="optional"
    if [ "$req_swap" = "Включен" ]; then
        cur_swap=$(get_astra_control_status "astra-swapwiper-control")
        if [ "$cur_swap" = "Включен" ]; then status_swap=true; else status_swap=false; fi
    fi

    local cur_console="optional"
    if [ "$req_console" = "Включен" ]; then
        cur_console=$(get_astra_control_status "astra-console-lock")
        if [ "$cur_console" = "Включен" ]; then status_console=true; else status_console=false; fi
    fi

    local cur_ptrace="optional"
    if [ "$req_ptrace" = "Включен" ]; then
        cur_ptrace=$(get_astra_control_status "astra-ptrace-lock")
        if [ "$cur_ptrace" = "Включен" ]; then status_ptrace=true; else status_ptrace=false; fi
    fi

    local cur_interpreters="optional"
    if [ "$req_interpreters" = "Включен" ]; then
        cur_interpreters=$(get_astra_control_status "astra-interpreters-lock")
        if [ "$cur_interpreters" = "Включен" ]; then status_interpreters=true; else status_interpreters=false; fi
    fi

    # Замер auditd
    local cur_audit="optional"
    local audit_active=false
    local audit_rules_ok=false
    if [ "$req_audit" != "optional" ]; then
        systemctl is-active auditd &>/dev/null && audit_active=true
        if [ "$audit_active" = true ]; then
            if [ "$target_class" = "1А" ]; then
                local rule_file="/etc/audit/rules.d/audit.rules"
                if [ -f "$rule_file" ] && grep -q "time-change" "$rule_file" && grep -q "identity" "$rule_file"; then
                    audit_rules_ok=true
                    status_audit=true
                else
                    status_audit=false
                fi
            else
                status_audit=true
            fi
        else
            status_audit=false
        fi
    fi

    # ------------------------------------------------------------
    # ФОРМИРОВАНИЕ СПИСКА НЕСOОТВЕТСТВИЙ ДЛЯ ВЫБОРА (CHECKLIST)
    # ------------------------------------------------------------
    local failed_list=()
    
    if [ "$status_len" = false ]; then
        failed_list+=("minlen" "Минимальная длина пароля: $cur_len (требуется >= $req_len)" "ON")
    fi
    if [ "$status_hist" = false ]; then
        failed_list+=("remember" "История повторения паролей: $cur_hist (требуется >= $req_hist)" "ON")
    fi
    if [ "$status_max_days" = false ]; then
        failed_list+=("pass_max_days" "Макс. срок действия пароля: $cur_max_days дн. (требуется <= $req_max_days дн.)" "ON")
    fi
    if [ "$status_deny" = false ]; then
        failed_list+=("deny" "Попыток до блокировки: $cur_deny (требуется <= $req_deny)" "ON")
    fi
    if [ "$status_unlock_time" = false ]; then
        local display_time="${cur_time}с"
        [ "$cur_time" -eq 0 ] && display_time="permanent"
        failed_list+=("unlock_time" "Время блокировки при подборе: $display_time (требуется >= ${req_unlock_time}с)" "ON")
    fi
    if [ "$status_tmout" = false ]; then
        local status_tmout_disp="${cur_tmout}с"
        [ "$cur_tmout" -eq 0 ] && status_tmout_disp="Выключен"
        failed_list+=("tmout" "Таймаут бездействия терминала: $status_tmout_disp (требуется <= ${req_tmout}с)" "ON")
    fi
    if [ "$status_secdel" = false ]; then
        failed_list+=("secdel" "Включить безопасное удаление файлов (SecDel) (сейчас $cur_secdel)" "ON")
    fi
    if [ "$status_swap" = false ]; then
        failed_list+=("swap" "Включить очистку Swap при выключении (сейчас $cur_swap)" "ON")
    fi
    if [ "$status_console" = false ]; then
        failed_list+=("console" "Включить блокировку переключения TTY-консолей (сейчас $cur_console)" "ON")
    fi
    if [ "$status_ptrace" = false ]; then
        failed_list+=("ptrace" "Включить блокировку трассировки ptrace (сейчас $cur_ptrace)" "ON")
    fi
    if [ "$status_interpreters" = false ]; then
        failed_list+=("interpreters" "Включить ограничение интерпретаторов (сейчас $cur_interpreters)" "ON")
    fi
    if [ "$status_audit" = false ]; then
        local audit_desc="Включить и запустить службу аудит безопасности auditd"
        [ "$target_class" = "1А" ] && audit_desc="Настроить расширенные правила аудита для класса 1А"
        failed_list+=("auditd" "$audit_desc" "ON")
    fi

    # ------------------------------------------------------------
    # ПРИМЕНЕНИЕ АВТОИСПРАВЛЕНИЙ (ЕСЛИ ВЫБРАНО ПОЛЬЗОВАТЕЛЕМ)
    # ------------------------------------------------------------
    local selected_fixes=()
    local checklist_exit=1
    
    if [ ${#failed_list[@]} -gt 0 ]; then
        local response
        response=$(whiptail --title "Несоответствия классу $target_class" \
                            --checklist "Выявлены несоответствия требованиям безопасности.\nОтметьте параметры, которые необходимо исправить автоматически:" \
                            22 78 12 \
                            "${failed_list[@]}" \
                            3>&1 1>&2 2>&3)
        checklist_exit=$?
        if [ $checklist_exit -eq 0 ]; then
            local item
            for item in $response; do
                item="${item%\"}"
                item="${item#\"}"
                selected_fixes+=("$item")
            done
        fi
    fi

    local fix_len="none"
    local fix_hist="none"
    local fix_max_days="none"
    local fix_deny="none"
    local fix_unlock_time="none"
    local fix_tmout="none"
    local fix_secdel="none"
    local fix_swap="none"
    local fix_console="none"
    local fix_ptrace="none"
    local fix_interpreters="none"
    local fix_audit="none"

    has_element() {
        local el="$1"
        shift
        local e
        for e in "$@"; do
            [ "$e" = "$el" ] && return 0
        done
        return 1
    }

    if [ ${#selected_fixes[@]} -gt 0 ]; then
        if has_element "minlen" "${selected_fixes[@]}"; then
            if apply_remediation_pwquality "$req_len"; then fix_len="fixed"; else fix_len="error"; fi
        fi
        if has_element "remember" "${selected_fixes[@]}"; then
            if apply_remediation_pam_history "$req_hist"; then fix_hist="fixed"; else fix_hist="error"; fi
        fi
        if has_element "pass_max_days" "${selected_fixes[@]}"; then
            if apply_remediation_logindefs "PASS_MAX_DAYS" "$req_max_days"; then fix_max_days="fixed"; else fix_max_days="error"; fi
        fi
        if has_element "deny" "${selected_fixes[@]}"; then
            if apply_remediation_faillock "deny" "$req_deny"; then fix_deny="fixed"; else fix_deny="error"; fi
        fi
        if has_element "unlock_time" "${selected_fixes[@]}"; then
            if apply_remediation_faillock "unlock_time" "$req_unlock_time"; then fix_unlock_time="fixed"; else fix_unlock_time="error"; fi
        fi
        if has_element "tmout" "${selected_fixes[@]}"; then
            if apply_remediation_tmout "$req_tmout"; then fix_tmout="fixed"; else fix_tmout="error"; fi
        fi
        if has_element "secdel" "${selected_fixes[@]}"; then
            if ! command -v "astra-secdel-control" &>/dev/null; then
                fix_secdel="no_util"
            elif apply_remediation_astra_control "astra-secdel-control"; then
                fix_secdel="fixed"
            else
                fix_secdel="error"
            fi
        fi
        if has_element "swap" "${selected_fixes[@]}"; then
            if ! command -v "astra-swapwiper-control" &>/dev/null; then
                fix_swap="no_util"
            elif apply_remediation_astra_control "astra-swapwiper-control"; then
                fix_swap="fixed"
            else
                fix_swap="error"
            fi
        fi
        if has_element "console" "${selected_fixes[@]}"; then
            if ! command -v "astra-console-lock" &>/dev/null; then
                fix_console="no_util"
            elif apply_remediation_astra_control "astra-console-lock"; then
                fix_console="fixed"
            else
                fix_console="error"
            fi
        fi
        if has_element "ptrace" "${selected_fixes[@]}"; then
            if ! command -v "astra-ptrace-lock" &>/dev/null; then
                fix_ptrace="no_util"
            elif apply_remediation_astra_control "astra-ptrace-lock"; then
                fix_ptrace="fixed"
            else
                fix_ptrace="error"
            fi
        fi
        if has_element "interpreters" "${selected_fixes[@]}"; then
            if ! command -v "astra-interpreters-lock" &>/dev/null; then
                fix_interpreters="no_util"
            elif apply_remediation_astra_control "astra-interpreters-lock"; then
                fix_interpreters="fixed"
            else
                fix_interpreters="error"
            fi
        fi
        if has_element "auditd" "${selected_fixes[@]}"; then
            if apply_remediation_auditd "$target_class"; then fix_audit="fixed"; else fix_audit="error"; fi
        fi
    fi

    # ------------------------------------------------------------
    # ВТОРОЙ ЭТАП: Контрольные замеры итогового состояния
    # ------------------------------------------------------------
    local final_len
    final_len=$(get_pwquality_param "minlen")
    
    local final_hist
    final_hist=$(get_password_history)
    
    local final_max_days
    final_max_days=$(get_logindefs_param "PASS_MAX_DAYS")
    
    local final_deny="0"
    local final_time="0"
    if [ -f "/etc/security/faillock.conf" ]; then
        final_deny=$(get_faillock_param "deny")
        final_time=$(get_faillock_param "unlock_time")
    fi
    
    local final_tmout
    final_tmout=$(get_tmout)
    
    local final_secdel="optional"
    [ "$req_secdel" = "Включен" ] && final_secdel=$(get_astra_control_status "astra-secdel-control")
    
    local final_swap="optional"
    [ "$req_swap" = "Включен" ] && final_swap=$(get_astra_control_status "astra-swapwiper-control")
    
    local final_console="optional"
    [ "$req_console" = "Включен" ] && final_console=$(get_astra_control_status "astra-console-lock")
    
    local final_ptrace="optional"
    [ "$req_ptrace" = "Включен" ] && final_ptrace=$(get_astra_control_status "astra-ptrace-lock")
    
    local final_interpreters="optional"
    [ "$req_interpreters" = "Включен" ] && final_interpreters=$(get_astra_control_status "astra-interpreters-lock")
    
    local final_audit="optional"
    if [ "$req_audit" != "optional" ]; then
        local final_audit_active=false
        systemctl is-active auditd &>/dev/null && final_audit_active=true
        if [ "$final_audit_active" = true ]; then
            if [ "$target_class" = "1А" ]; then
                local final_rule_file="/etc/audit/rules.d/audit.rules"
                if [ -f "$final_rule_file" ] && grep -q "time-change" "$final_rule_file" && grep -q "identity" "$final_rule_file"; then
                    final_audit="Включен"
                else
                    final_audit="Не настроен"
                fi
            else
                final_audit="Включен"
            fi
        else
            final_audit="Выключен"
        fi
    fi

    # ------------------------------------------------------------
    # ГЕНЕРАЦИЯ ДВУХЭТАПНОГО ОТЧЕТА СООТВЕТСТВИЯ
    # ------------------------------------------------------------
    local reports_dir="$ROOT_DIR/report"
    mkdir -p "$reports_dir"
    if [ -n "$SUDO_UID" ] && [ -n "$SUDO_GID" ]; then
        chown "$SUDO_UID:$SUDO_GID" "$reports_dir" 2>/dev/null
    fi
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    local report_file="${reports_dir}/compliance_report_${target_class}_${timestamp}.txt"

    echo "========================================================================" > "$report_file"
    echo "         ОТЧЕТ КОНТРОЛЯ СООТВЕТСТВИЯ ТРЕБОВАНИЯМ РД АС (ГОСТЕХКОМИССИЯ)" >> "$report_file"
    echo "========================================================================" >> "$report_file"
    echo "Целевой класс защищенности АС: $target_class" >> "$report_file"
    echo "Описание: $class_desc" >> "$report_file"
    echo "------------------------------------------------------------------------" >> "$report_file"
    echo "" >> "$report_file"
    
    # 1. Длина пароля
    local label_len="[  !!  ]"
    if [ "$status_len" = true ]; then
        label_len="[  OK  ]"
    elif [ "$final_len" -ge "$req_len" ]; then
        label_len="[ИСПРАВЛЕНО]"
    fi
    echo -e "${label_len} Минимальная длина пароля: ${final_len} (требуется >= ${req_len})" >> "$report_file"
    if [ "$label_len" = "[  !!  ]" ]; then
        echo -e "         -> РЕКОМЕНДАЦИЯ: Измените параметр 'minlen = ${req_len}' в /etc/security/pwquality.conf\n            или в GUI: «Локальная политика безопасности» -> «Политика учетных записей» -> «Политика паролей» -> «Минимальная длина»" >> "$report_file"
    fi
    
    # 2. История паролей
    local label_hist="[  !!  ]"
    if [ "$status_hist" = true ]; then
        label_hist="[  OK  ]"
    elif [ "$final_hist" -ge "$req_hist" ]; then
        label_hist="[ИСПРАВЛЕНО]"
    fi
    echo -e "${label_hist} История повторения паролей: ${final_hist} (требуется >= ${req_hist})" >> "$report_file"
    if [ "$label_hist" = "[  !!  ]" ]; then
        echo -e "         -> РЕКОМЕНДАЦИЯ: Установите параметр 'remember=${req_hist}' для pam_unix.so в файле /etc/pam.d/common-password\n            или в GUI: «Локальная политика безопасности» -> «Политика учетных записей» -> «Политика паролей» -> «Хранить историю паролей»" >> "$report_file"
    fi
    
    # 3. Время действия пароля
    local label_max_days="[  !!  ]"
    if [ "$status_max_days" = true ]; then
        label_max_days="[  OK  ]"
    elif [ "$final_max_days" -le "$req_max_days" ] && [ "$final_max_days" -gt 0 ]; then
        label_max_days="[ИСПРАВЛЕНО]"
    fi
    echo -e "${label_max_days} Максимальный срок действия пароля: ${final_max_days} дн. (требуется <= ${req_max_days} дн.)" >> "$report_file"
    if [ "$label_max_days" = "[  !!  ]" ]; then
        echo -e "         -> РЕКОМЕНДАЦИЯ: Измените параметр 'PASS_MAX_DAYS ${req_max_days}' в файле /etc/login.defs\n            или в GUI: «Локальная политика безопасности» -> «Политика учетных записей» -> «Политика паролей» -> «Максимальный срок действия пароля»" >> "$report_file"
    fi
    
    # 4. Блокировка попыток
    local label_deny="[  !!  ]"
    if [ "$status_deny" = true ]; then
        label_deny="[  OK  ]"
    elif [ "$final_deny" -le "$req_deny" ] && [ "$final_deny" -gt 0 ]; then
        label_deny="[ИСПРАВЛЕНО]"
    fi
    echo -e "${label_deny} Попыток до блокировки аккаунта: ${final_deny} (требуется <= ${req_deny})" >> "$report_file"
    if [ "$label_deny" = "[  !!  ]" ]; then
        echo -e "         -> РЕКОМЕНДАЦИЯ: Установите параметр 'deny = ${req_deny}' в /etc/security/faillock.conf\n            или в GUI: «Локальная политика безопасности» -> «Политика учетных записей» -> «Блокировка учетных записей» -> «Попыток входа до блокировки»" >> "$report_file"
    fi
    
    # 5. Время блокировки
    local label_unlock_time="[  !!  ]"
    if [ "$status_unlock_time" = true ]; then
        label_unlock_time="[  OK  ]"
    elif [ "$final_time" -eq 0 ] || [ "$final_time" -ge "$req_unlock_time" ]; then
        label_unlock_time="[ИСПРАВЛЕНО]"
    fi
    local display_final_time="${final_time}с"
    [ "$final_time" -eq 0 ] && display_final_time="permanent (0)"
    echo -e "${label_unlock_time} Время блокировки при подборе: ${display_final_time} (требуется >= ${req_unlock_time}с)" >> "$report_file"
    if [ "$label_unlock_time" = "[  !!  ]" ]; then
        echo -e "         -> РЕКОМЕНДАЦИЯ: Установите параметр 'unlock_time = ${req_unlock_time}' (или 0 для бессрочной блокировки) в /etc/security/faillock.conf\n            или в GUI: «Локальная политика безопасности» -> «Политика учетных записей» -> «Блокировка учетных записей» -> «Время блокировки»" >> "$report_file"
    fi
    
    # 6. Таймаут неактивности сессии
    local label_tmout="[  !!  ]"
    if [ "$status_tmout" = true ]; then
        label_tmout="[  OK  ]"
    elif [ "$final_tmout" -le "$req_tmout" ] && [ "$final_tmout" -gt 0 ]; then
        label_tmout="[ИСПРАВЛЕНО]"
    fi
    local display_final_tmout="${final_tmout}с"
    [ "$final_tmout" -eq 0 ] && display_final_tmout="Выключен"
    echo -e "${label_tmout} Таймаут бездействия терминала: ${display_final_tmout} (требуется <= ${req_tmout}с)" >> "$report_file"
    if [ "$label_tmout" = "[  !!  ]" ]; then
        echo -e "         -> РЕКОМЕНДАЦИЯ: Пропишите 'readonly TMOUT=${req_tmout}; export TMOUT' в файл /etc/profile.d/tmout.sh\n            или в GUI: «Настройка экрана» -> «Хранитель экрана» -> «Блокировать экран через...» (для графических сессий)" >> "$report_file"
    fi
    
    # 7. Гарантированная очистка (SecDel)
    if [ "$req_secdel" = "Включен" ]; then
        local label_secdel="[  !!  ]"
        if [ "$status_secdel" = true ]; then
            label_secdel="[  OK  ]"
        elif [ "$fix_secdel" = "no_util" ]; then
            label_secdel="[  !!  ] (Утилита не установлена)"
        elif [ "$final_secdel" = "Включен" ]; then
            label_secdel="[ИСПРАВЛЕНО]"
        fi
        echo -e "${label_secdel} Безопасное удаление файлов (SecDel): ${final_secdel}" >> "$report_file"
        if [ "$label_secdel" = "[  !!  ]" ]; then
            echo -e "         -> РЕКОМЕНДАЦИЯ: Выполните команду 'sudo astra-secdel-control enable'\n            или в GUI: «Локальная политика безопасности» -> «Безопасность» -> «Очистка освобождаемых областей» -> «Безопасное удаление файлов»" >> "$report_file"
        elif [ "$label_secdel" = "[  !!  ] (Утилита не установлена)" ]; then
            echo -e "         -> РЕКОМЕНДАЦИЯ: Установите пакет astra-secdel-control с помощью APT." >> "$report_file"
        fi
    fi
    
    # 8. Очистка Swap
    if [ "$req_swap" = "Включен" ]; then
        local label_swap="[  !!  ]"
        if [ "$status_swap" = true ]; then
            label_swap="[  OK  ]"
        elif [ "$fix_swap" = "no_util" ]; then
            label_swap="[  !!  ] (Утилита не установлена)"
        elif [ "$final_swap" = "Включен" ]; then
            label_swap="[ИСПРАВЛЕНО]"
        fi
        echo -e "${label_swap} Гарантированная очистка Swap при выключении: ${final_swap}" >> "$report_file"
        if [ "$label_swap" = "[  !!  ]" ]; then
            echo -e "         -> РЕКОМЕНДАЦИЯ: Выполните команду 'sudo astra-swapwiper-control enable'\n            или в GUI: «Локальная политика безопасности» -> «Безопасность» -> «Очистка освобождаемых областей» -> «Очистка swap-раздела при выключении»" >> "$report_file"
        elif [ "$label_swap" = "[  !!  ] (Утилита не установлена)" ]; then
            echo -e "         -> РЕКОМЕНДАЦИЯ: Установите пакет astra-swapwiper-control с помощью APT." >> "$report_file"
        fi
    fi
    
    # 9. Блокировка консолей
    if [ "$req_console" = "Включен" ]; then
        local label_console="[  !!  ]"
        if [ "$status_console" = true ]; then
            label_console="[  OK  ]"
        elif [ "$fix_console" = "no_util" ]; then
            label_console="[  !!  ] (Утилита не установлена)"
        elif [ "$final_console" = "Включен" ]; then
            label_console="[ИСПРАВЛЕНО]"
        fi
        echo -e "${label_console} Блокировка переключения TTY-консолей: ${final_console}" >> "$report_file"
        if [ "$label_console" = "[  !!  ]" ]; then
            echo -e "         -> РЕКОМЕНДАЦИЯ: Выполните команду 'sudo astra-console-lock enable'\n            или в GUI: «Локальная политика безопасности» -> «Безопасность» -> «Режимы блокировки» -> «Блокировка переключения TTY-консолей»" >> "$report_file"
        elif [ "$label_console" = "[  !!  ] (Утилита не установлена)" ]; then
            echo -e "         -> РЕКОМЕНДАЦИЯ: Установите пакет astra-console-lock с помощью APT." >> "$report_file"
        fi
    fi
    
    # 10. Блокировка ptrace
    if [ "$req_ptrace" = "Включен" ]; then
        local label_ptrace="[  !!  ]"
        if [ "$status_ptrace" = true ]; then
            label_ptrace="[  OK  ]"
        elif [ "$fix_ptrace" = "no_util" ]; then
            label_ptrace="[  !!  ] (Утилита не установлена)"
        elif [ "$final_ptrace" = "Включен" ]; then
            label_ptrace="[ИСПРАВЛЕНО]"
        fi
        echo -e "${label_ptrace} Блокировка трассировки процессов (ptrace): ${final_ptrace}" >> "$report_file"
        if [ "$label_ptrace" = "[  !!  ]" ]; then
            echo -e "         -> РЕКОМЕНДАЦИЯ: Выполните команду 'sudo astra-ptrace-lock enable'\n            или в GUI: «Локальная политика безопасности» -> «Безопасность» -> «Режимы блокировки» -> «Блокировка трассировки процессов (ptrace)»" >> "$report_file"
        elif [ "$label_ptrace" = "[  !!  ] (Утилита не установлена)" ]; then
            echo -e "         -> РЕКОМЕНДАЦИЯ: Установите пакет astra-ptrace-lock с помощью APT." >> "$report_file"
        fi
    fi
    
    # 11. Блокировка интерпретаторов
    if [ "$req_interpreters" = "Включен" ]; then
        local label_interpreters="[  !!  ]"
        if [ "$status_interpreters" = true ]; then
            label_interpreters="[  OK  ]"
        elif [ "$fix_interpreters" = "no_util" ]; then
            label_interpreters="[  !!  ] (Утилита не установлена)"
        elif [ "$final_interpreters" = "Включен" ]; then
            label_interpreters="[ИСПРАВЛЕНО]"
        fi
        echo -e "${label_interpreters} Ограничение консольных интерпретаторов: ${final_interpreters}" >> "$report_file"
        if [ "$label_interpreters" = "[  !!  ]" ]; then
            echo -e "         -> РЕКОМЕНДАЦИЯ: Выполните команду 'sudo astra-interpreters-lock enable'\n            или в GUI: «Локальная политика безопасности» -> «Безопасность» -> «Режимы блокировки» -> «Ограничение консольных интерпретаторов»" >> "$report_file"
        elif [ "$label_interpreters" = "[  !!  ] (Утилита не установлена)" ]; then
            echo -e "         -> РЕКОМЕНДАЦИЯ: Установите пакет astra-interpreters-lock с помощью APT." >> "$report_file"
        fi
    fi
    
    # 12. Служба аудита auditd
    if [ "$req_audit" != "optional" ]; then
        local label_audit="[  !!  ]"
        if [ "$status_audit" = true ]; then
            label_audit="[  OK  ]"
        elif [ "$final_audit" = "Включен" ]; then
            label_audit="[ИСПРАВЛЕНО]"
        fi
        echo -e "${label_audit} Служба аудита безопасности auditd: ${final_audit}" >> "$report_file"
        if [ "$label_audit" = "[  !!  ]" ]; then
            echo -e "         -> РЕКОМЕНДАЦИЯ: Выполните: 'sudo systemctl enable --now auditd'\n            или в GUI: «Панель управления» -> «Аудит событий»" >> "$report_file"
        fi
        
        if [ "$target_class" = "1А" ]; then
            local label_rules="[  !!  ]"
            if [ "$audit_rules_ok" = true ]; then
                label_rules="[  OK  ]"
            elif [ "$final_audit" = "Включен" ]; then
                local check_rules_file="/etc/audit/rules.d/audit.rules"
                if [ -f "$check_rules_file" ] && grep -q "time-change" "$check_rules_file" && grep -q "identity" "$check_rules_file"; then
                    label_rules="[ИСПРАВЛЕНО]"
                fi
            fi
            echo -e "${label_rules} Расширенные правила аудита для класса 1А: $([ "$label_rules" = "[  OK  ]" -o "$label_rules" = "[ИСПРАВЛЕНО]" ] && echo "Соответствуют" || echo "Не настроены")" >> "$report_file"
            if [ "$label_rules" = "[  !!  ]" ]; then
                echo -e "         -> РЕКОМЕНДАЦИЯ: Настройте правила аудита для времени, ФС и учетных записей в /etc/audit/rules.d/audit.rules" >> "$report_file"
            fi
        fi
    fi
    
    echo "------------------------------------------------------------------------" >> "$report_file"
    echo "                 КОНЕЦ ОТЧЕТА КОМПЛАЕНС-КОНТРОЛЯ" >> "$report_file"
    echo "========================================================================" >> "$report_file"
    
    if [ -n "$SUDO_UID" ] && [ -n "$SUDO_GID" ]; then
        chown "$SUDO_UID:$SUDO_GID" "$report_file" 2>/dev/null
    fi
    
    local summary_msg="Отчет соответствия требованиям РД АС сохранен в:\n$report_file\n\n"
    if [ ${#selected_fixes[@]} -gt 0 ]; then
        summary_msg+="Применены автоматические исправления для выбранных параметров.\nПерепроверка завершена."
    else
        summary_msg+="Автоматические исправления не вносились."
    fi
    
    whiptail --title "Комплаенс-контроль завершен" --msgbox "$summary_msg" 14 76
}

# ------------------------------------------------------------
#                        ГЛАВНЫЙ ЦИКЛ
# ------------------------------------------------------------
default_choice="1"
while true; do
    status_sys="ВЫКЛ"
    [ "$AUDIT_SYS" = true ] && status_sys="ВКЛ"
    
    status_user="ВЫКЛ"
    [ "$AUDIT_USER" = true ] && status_user="ВКЛ"
    
    status_fs="ВЫКЛ"
    [ "$AUDIT_FS" = true ] && status_fs="ВКЛ"
    
    status_net="ВЫКЛ"
    [ "$AUDIT_NET" = true ] && status_net="ВКЛ"
    
    status_astra="ВЫКЛ"
    [ "$AUDIT_ASTRA" = true ] && status_astra="ВКЛ"
    
    status_screen="ВЫКЛ"
    if [ "$CAPTURE_SCREEN" = true ]; then
        status_screen="ВКЛ ($SCREENSHOT_X11_MODE)"
    fi
    
    choice=$(whiptail --title "АО НИИ \"РУБИН\"" \
                      --cancel-button "Назад" \
                      --default-item "$default_choice" \
                      --menu "   ───┤ Управление: ↑/↓ - переход, Enter - выбор, Tab - кнопки ├───\n\nНастройте объем аудита безопасности АРМ:" \
                      22 76 9 \
                      "Системная информация и S/N" "[$status_sys]" \
                      "Учетные записи и доступ" "[$status_user]" \
                      "Безопасность файловой системы" "[$status_fs]" \
                      "Сеть и брандмауэр" "[$status_net]" \
                      "Механизмы защиты Astra Linux" "[$status_astra]" \
                      "Скриншоты графических окон" "[$status_screen]" \
                      "Проверить соответствие классу защищенности" "" \
                      "Запустить проверку безопасности" "" \
                      "Выбрать окна для скриншотов" "" \
                      3>&1 1>&2 2>&3)
                      
    exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo "Выход..."
        exit 0
    fi
    
    default_choice="$choice"
    
    case "$choice" in
        "Системная информация и S/N")
            if [ "$AUDIT_SYS" = true ]; then AUDIT_SYS=false; else AUDIT_SYS=true; fi
            ;;
        "Учетные записи и доступ")
            if [ "$AUDIT_USER" = true ]; then AUDIT_USER=false; else AUDIT_USER=true; fi
            ;;
        "Безопасность файловой системы")
            if [ "$AUDIT_FS" = true ]; then AUDIT_FS=false; else AUDIT_FS=true; fi
            ;;
        "Сеть и брандмауэр")
            if [ "$AUDIT_NET" = true ]; then AUDIT_NET=false; else AUDIT_NET=true; fi
            ;;
        "Механизмы защиты Astra Linux")
            if [ "$AUDIT_ASTRA" = true ]; then AUDIT_ASTRA=false; else AUDIT_ASTRA=true; fi
            ;;
        "Скриншоты графических окон")
            if [ "$CAPTURE_SCREEN" = true ]; then
                if [ "$SCREENSHOT_X11_MODE" = "local" ] && [ -n "$SSH_DISPLAY" ]; then
                    SCREENSHOT_X11_MODE="ssh"
                    TARGET_DISPLAY="$SSH_DISPLAY"
                    if [ -n "$SUDO_USER" ]; then
                        USER_HOME=$(eval echo "~$SUDO_USER")
                        if [ -f "$USER_HOME/.Xauthority" ]; then
                            TARGET_XAUTHORITY="$USER_HOME/.Xauthority"
                        else
                            TARGET_XAUTHORITY="$SSH_XAUTHORITY"
                        fi
                    else
                        TARGET_XAUTHORITY="$SSH_XAUTHORITY"
                    fi
                else
                    CAPTURE_SCREEN=false
                fi
            else
                if [ -n "$LOCAL_XAUTHORITY" ]; then
                    CAPTURE_SCREEN=true
                    SCREENSHOT_X11_MODE="local"
                    TARGET_DISPLAY="$LOCAL_DISPLAY"
                    TARGET_XAUTHORITY="$LOCAL_XAUTHORITY"
                elif [ -n "$SSH_DISPLAY" ]; then
                    CAPTURE_SCREEN=true
                    SCREENSHOT_X11_MODE="ssh"
                    TARGET_DISPLAY="$SSH_DISPLAY"
                    if [ -n "$SUDO_USER" ]; then
                        USER_HOME=$(eval echo "~$SUDO_USER")
                        if [ -f "$USER_HOME/.Xauthority" ]; then
                            TARGET_XAUTHORITY="$USER_HOME/.Xauthority"
                        else
                            TARGET_XAUTHORITY="$SSH_XAUTHORITY"
                        fi
                    else
                        TARGET_XAUTHORITY="$SSH_XAUTHORITY"
                    fi
                else
                    whiptail --title "Ошибка" --msgbox "Ошибка: Ни локальная графическая сессия (:0), ни пересылка X11 по SSH не обнаружены. Снятие скриншотов невозможно!" 10 60
                fi
            fi
            ;;
        "Проверить соответствие классу защищенности")
            check_class_compliance
            ;;
        "Запустить проверку безопасности")
            execute_audit
            ;;
        "Выбрать окна для скриншотов")
            edit_config
            ;;
    esac
done
