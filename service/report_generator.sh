#!/bin/bash
# ============================================================
#               REPORT GENERATOR HELPER SCRIPT
# ============================================================
# Этот файл автоматически загружается через source основным скриптом
# для генерации автономного HTML-отчета.
# ============================================================

echo "=== [ Формирование HTML-отчета ] ==="

# Метаданные отчета
local r_host
r_host=$(hostname)
local r_date
r_date=$(date "+%Y-%m-%d %H:%M:%S")
local r_os
if [ -f /etc/astra_version ]; then
    r_os=$(cat /etc/astra_version)
else
    r_os=$(grep "PRETTY_NAME" /etc/os-release | cut -d= -f2 | tr -d '"')
fi

# Сбор S/N для хедера
local r_sn
r_sn=$(cat /sys/class/dmi/id/product_serial 2>/dev/null)
if [ -z "$r_sn" ] || [ "$r_sn" = "System Serial Number" ] || [ "$r_sn" = "To be filled by O.E.M." ]; then
    r_sn=$(dmidecode -s system-serial-number 2>/dev/null)
fi
r_sn=${r_sn:-"Не определен"}

# Запись первой части HTML-файла
cat << EOF > "$REPORT_FILE"
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Отчет о защищенности АРМ - $r_host</title>
    <style>
        :root {
            --bg-main: #0f172a;
            --bg-card: #1e293b;
            --border: #334155;
            --text-main: #f8fafc;
            --text-muted: #94a3b8;
            --primary: #0ea5e9;
            --primary-hover: #38bdf8;
            
            --status-pass: #10b981;
            --status-warn: #f59e0b;
            --status-crit: #ef4444;
            --status-info: #3b82f6;
            
            --status-pass-bg: rgba(16, 185, 129, 0.1);
            --status-warn-bg: rgba(245, 158, 11, 0.1);
            --status-crit-bg: rgba(239, 68, 68, 0.1);
            --status-info-bg: rgba(37, 99, 235, 0.1);
        }

        .light-theme {
            --bg-main: #f8fafc;
            --bg-card: #ffffff;
            --border: #e2e8f0;
            --text-main: #0f172a;
            --text-muted: #64748b;
            --primary: #0284c7;
            --primary-hover: #0369a1;
            
            --status-pass: #059669;
            --status-warn: #d97706;
            --status-crit: #dc2626;
            --status-info: #2563eb;
            
            --status-pass-bg: rgba(5, 150, 105, 0.08);
            --status-warn-bg: rgba(217, 119, 6, 0.08);
            --status-crit-bg: rgba(220, 38, 38, 0.08);
            --status-info-bg: rgba(37, 99, 235, 0.08);
        }

        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
        }

        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            background-color: var(--bg-main);
            color: var(--text-main);
            line-height: 1.5;
            transition: background-color 0.3s, color 0.3s;
            padding: 2rem 1rem;
        }

        .container {
            max-width: 1200px;
            margin: 0 auto;
        }

        /* Header */
        header {
            background-color: var(--bg-card);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 1.5rem;
            margin-bottom: 2rem;
            box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1);
            position: relative;
        }

        .header-top {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 1rem;
        }

        h1 {
            font-size: 1.75rem;
            font-weight: 700;
            letter-spacing: -0.025em;
        }

        .theme-toggle, .print-btn {
            background-color: var(--bg-main);
            border: 1px solid var(--border);
            color: var(--text-main);
            padding: 0.5rem 1rem;
            border-radius: 6px;
            cursor: pointer;
            font-size: 0.875rem;
            font-weight: 500;
            transition: border-color 0.2s, background-color 0.2s;
            margin-left: 0.5rem;
        }

        .theme-toggle:hover, .print-btn:hover {
            border-color: var(--primary);
            background-color: var(--border);
        }

        .meta-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(220px, 1fr));
            gap: 1rem;
            font-size: 0.875rem;
            border-top: 1px solid var(--border);
            padding-top: 1rem;
        }

        .meta-item span {
            color: var(--text-muted);
            display: block;
            margin-bottom: 0.25rem;
        }

        .meta-item strong {
            font-weight: 600;
        }

        /* Dashboard Overview */
        .dashboard-grid {
            display: grid;
            grid-template-columns: 1fr;
            gap: 2rem;
            margin-bottom: 2rem;
        }

        .score-card {
            display: none;
        }

        .gauge-container {
            position: relative;
            width: 150px;
            height: 150px;
            margin-bottom: 1rem;
        }

        .gauge-circle-bg {
            fill: none;
            stroke: var(--border);
            stroke-width: 12;
        }

        .gauge-circle-fill {
            fill: none;
            stroke: var(--status-pass);
            stroke-width: 12;
            stroke-linecap: round;
            transform: rotate(-90deg);
            transform-origin: 50% 50%;
            transition: stroke-dasharray 0.5s ease;
        }

        .gauge-text {
            position: absolute;
            top: 50%;
            left: 50%;
            transform: translate(-50%, -50%);
            font-size: 2rem;
            font-weight: 800;
        }

        .stats-card {
            background-color: var(--bg-card);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 1.5rem;
            box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1);
            display: flex;
            flex-direction: column;
            justify-content: space-between;
        }

        .stats-title {
            font-size: 1.1rem;
            font-weight: 600;
            margin-bottom: 1rem;
            padding-bottom: 0.5rem;
            border-bottom: 1px solid var(--border);
        }

        .stats-row {
            display: grid;
            grid-template-columns: repeat(4, 1fr);
            gap: 1rem;
            text-align: center;
        }

        .stat-box {
            padding: 1rem;
            border-radius: 6px;
            border: 1px solid var(--border);
            background-color: var(--bg-main);
        }

        .stat-num {
            font-size: 1.75rem;
            font-weight: 800;
            margin-bottom: 0.25rem;
        }

        .stat-label {
            font-size: 0.75rem;
            color: var(--text-muted);
            font-weight: 500;
            text-transform: uppercase;
        }

        /* Controls */
        .controls-bar {
            background-color: var(--bg-card);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 1rem;
            margin-bottom: 2rem;
            box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1);
            display: flex;
            flex-wrap: wrap;
            gap: 1rem;
            align-items: center;
            justify-content: space-between;
        }

        .filters-group {
            display: flex;
            flex-wrap: wrap;
            gap: 0.5rem;
        }

        .filter-btn {
            background-color: var(--bg-main);
            border: 1px solid var(--border);
            color: var(--text-main);
            padding: 0.4rem 0.8rem;
            border-radius: 6px;
            cursor: pointer;
            font-size: 0.85rem;
            font-weight: 500;
            transition: all 0.2s;
        }

        .filter-btn:hover, .filter-btn.active {
            border-color: var(--primary);
            background-color: var(--primary);
            color: #ffffff;
        }

        .search-box {
            position: relative;
            flex-grow: 1;
            max-width: 400px;
        }

        .search-input {
            width: 100%;
            background-color: var(--bg-main);
            border: 1px solid var(--border);
            color: var(--text-main);
            padding: 0.5rem 1rem;
            border-radius: 6px;
            font-size: 0.875rem;
            outline: none;
            transition: border-color 0.2s;
        }

        .search-input:focus {
            border-color: var(--primary);
        }

        /* Checks Section */
        .checks-container {
            display: flex;
            flex-direction: column;
            gap: 1rem;
            margin-bottom: 2rem;
        }

        .check-card {
            background-color: var(--bg-card);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 1.25rem;
            box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1);
            transition: transform 0.2s, border-color 0.2s;
        }

        .check-card:hover {
            border-color: var(--border);
            transform: translateY(-2px);
        }

        .check-header {
            display: flex;
            justify-content: space-between;
            align-items: flex-start;
            gap: 1rem;
            margin-bottom: 0.5rem;
        }

        .check-title-group {
            display: flex;
            align-items: center;
            gap: 0.75rem;
        }

        .check-title {
            font-size: 1.1rem;
            font-weight: 600;
        }

        .check-badge {
            font-family: monospace;
            font-weight: bold;
            font-size: 0.75rem;
            padding: 0.25rem 0.5rem;
            border-radius: 4px;
            letter-spacing: 0.05em;
        }

        .badge-passed {
            background-color: var(--status-pass-bg);
            color: var(--status-pass);
            border: 1px solid var(--status-pass);
        }

        .badge-warning {
            background-color: var(--status-warn-bg);
            color: var(--status-warn);
            border: 1px solid var(--status-warn);
        }

        .badge-critical {
            background-color: var(--status-crit-bg);
            color: var(--status-crit);
            border: 1px solid var(--status-crit);
        }

        .badge-info {
            background-color: var(--status-info-bg);
            color: var(--status-info);
            border: 1px solid var(--status-info);
        }

        .check-category {
            font-size: 0.75rem;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            color: var(--text-muted);
            font-weight: 600;
            background-color: var(--bg-main);
            padding: 0.15rem 0.4rem;
            border-radius: 4px;
            border: 1px solid var(--border);
        }

        .check-desc {
            font-size: 0.9rem;
            color: var(--text-muted);
            margin-bottom: 1rem;
        }

        .check-toggle-btn {
            display: none;
        }

        .check-details {
            margin-top: 1rem;
            border-top: 1px dashed var(--border);
            padding-top: 1rem;
            display: block;
        }

        .console-label {
            font-size: 0.8rem;
            color: var(--text-muted);
            margin-bottom: 0.5rem;
            font-family: monospace;
        }

        .console-box {
            background-color: #0b0f19;
            border: 1px solid var(--border);
            border-radius: 6px;
            padding: 1rem;
            font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
            font-size: 0.85rem;
            overflow-x: auto;
            white-space: pre-wrap;
            color: #38bdf8;
            max-height: 350px;
            overflow-y: auto;
            margin-bottom: 1rem;
        }

        .console-cmd {
            color: #f43f5e;
            font-weight: 600;
            margin-bottom: 0.5rem;
            border-bottom: 1px solid #1e293b;
            padding-bottom: 0.25rem;
        }

        /* Screenshots Section */
        .screenshots-section {
            background-color: var(--bg-card);
            border: 1px solid var(--border);
            border-radius: 8px;
            padding: 1.5rem;
            margin-bottom: 2rem;
            box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1);
        }

        .screenshots-title {
            font-size: 1.25rem;
            font-weight: 700;
            margin-bottom: 1rem;
            border-bottom: 1px solid var(--border);
            padding-bottom: 0.5rem;
        }

        .screenshots-grid {
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
            gap: 1.5rem;
        }

        .screenshot-card {
            border: 1px solid var(--border);
            border-radius: 6px;
            background-color: var(--bg-main);
            overflow: hidden;
            cursor: pointer;
            transition: border-color 0.2s, transform 0.2s;
        }

        .screenshot-card:hover {
            border-color: var(--primary);
            transform: scale(1.02);
        }

        .screenshot-img-container {
            width: 100%;
            height: 160px;
            background-color: #0b0f19;
            display: flex;
            align-items: center;
            justify-content: center;
            overflow: hidden;
            position: relative;
        }

        .screenshot-img {
            max-width: 100%;
            max-height: 100%;
            object-fit: contain;
        }

        .screenshot-info {
            padding: 0.75rem;
            border-top: 1px solid var(--border);
        }

        .screenshot-name {
            font-weight: 600;
            font-size: 0.9rem;
            margin-bottom: 0.25rem;
        }

        .screenshot-cmd {
            font-family: monospace;
            font-size: 0.75rem;
            color: var(--text-muted);
        }

        /* Lightbox */
        .lightbox {
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            background-color: rgba(15, 23, 42, 0.95);
            z-index: 1000;
            display: none;
            align-items: center;
            justify-content: center;
            padding: 2rem;
        }

        .lightbox.active {
            display: flex;
        }

        .lightbox-content {
            max-width: 90%;
            max-height: 90%;
            position: relative;
        }

        .lightbox-img {
            max-width: 100%;
            max-height: 85vh;
            border: 2px solid var(--border);
            border-radius: 4px;
            box-shadow: 0 25px 50px -12px rgba(0, 0, 0, 0.5);
        }

        .lightbox-close {
            position: absolute;
            top: -2.5rem;
            right: 0;
            color: #ffffff;
            font-size: 1.5rem;
            font-weight: bold;
            cursor: pointer;
            font-family: monospace;
        }

        .lightbox-caption {
            color: #ffffff;
            text-align: center;
            margin-top: 0.75rem;
            font-weight: 600;
            font-size: 1rem;
        }

        /* No results message */
        .no-results {
            background-color: var(--bg-card);
            border: 1px dashed var(--border);
            border-radius: 8px;
            padding: 3rem;
            text-align: center;
            color: var(--text-muted);
            font-weight: 500;
            display: none;
        }

        /* Print modifications */
        @media print {
            body {
                background-color: #ffffff !important;
                color: #000000 !important;
                padding: 0 !important;
            }
            .theme-toggle, .print-btn, .controls-bar, .check-toggle-btn {
                display: none !important;
            }
            header, .score-card, .stats-card, .check-card, .screenshots-section {
                border: 1px solid #000000 !important;
                box-shadow: none !important;
                background-color: #ffffff !important;
                page-break-inside: avoid;
            }
            .check-details {
                display: block !important;
            }
            .console-box {
                background-color: #ffffff !important;
                color: #000000 !important;
                border: 1px solid #000000 !important;
                max-height: none !important;
                overflow: visible !important;
            }
            .screenshot-card {
                page-break-inside: avoid;
                border: 1px solid #000000 !important;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <!-- Header -->
        <header>
            <div class="header-top">
                <h1>ОТЧЕТ О ЗАЩИЩЕННОСТИ АРМ</h1>
                <div>
                    <button class="theme-toggle" id="themeBtn" onclick="toggleTheme()">[ СВЕТЛАЯ ТЕМА ]</button>
                    <button class="print-btn" onclick="window.print()">[ ПЕЧАТЬ В PDF ]</button>
                </div>
            </div>
            <div class="meta-grid">
                <div class="meta-item">
                    <span>Имя хоста компьютера:</span>
                    <strong>$r_host</strong>
                </div>
                <div class="meta-item">
                    <span>Операционная система:</span>
                    <strong>$r_os</strong>
                </div>
                <div class="meta-item">
                    <span>Серийный номер (S/N):</span>
                    <strong>$r_sn</strong>
                </div>
                <div class="meta-item">
                    <span>Дата/время аудита:</span>
                    <strong>$r_date</strong>
                </div>
            </div>
        </header>

        <!-- Dashboard -->
        <div class="dashboard-grid">
            <div class="stats-card">
                <div class="stats-title">Результаты проведенных проверок</div>
                <div class="stats-row">
                    <div class="stat-box" style="border-top: 3px solid var(--primary);">
                        <div class="stat-num" id="totalChecks">0</div>
                        <div class="stat-label">Всего</div>
                    </div>
                    <div class="stat-box" style="border-top: 3px solid var(--status-pass);">
                        <div class="stat-num" id="passedChecks" style="color: var(--status-pass);">0</div>
                        <div class="stat-label">Успешно</div>
                    </div>
                    <div class="stat-box" style="border-top: 3px solid var(--status-warn);">
                        <div class="stat-num" id="warningChecks" style="color: var(--status-warn);">0</div>
                        <div class="stat-label">Предупр.</div>
                    </div>
                    <div class="stat-box" style="border-top: 3px solid var(--status-crit);">
                        <div class="stat-num" id="criticalChecks" style="color: var(--status-crit);">0</div>
                        <div class="stat-label">Критично</div>
                    </div>
                </div>
            </div>
        </div>

        <!-- Controls -->
        <div class="controls-bar">
            <div class="filters-group" id="categoryFilters">
                <button class="filter-btn active" onclick="filterCategory('all')">Все категории</button>
                <button class="filter-btn" onclick="filterCategory('system')">Система</button>
                <button class="filter-btn" onclick="filterCategory('users')">Доступ</button>
                <button class="filter-btn" onclick="filterCategory('filesystem')">Файлы</button>
                <button class="filter-btn" onclick="filterCategory('network')">Сеть</button>
                <button class="filter-btn" onclick="filterCategory('astra')">Astra Linux</button>
            </div>
            
            <div class="filters-group" id="statusFilters">
                <button class="filter-btn active" onclick="filterStatus('all')">Все статусы</button>
                <button class="filter-btn" onclick="filterStatus('PASSED')" style="color: var(--status-pass)">[PASS]</button>
                <button class="filter-btn" onclick="filterStatus('WARNING')" style="color: var(--status-warn)">[WARN]</button>
                <button class="filter-btn" onclick="filterStatus('CRITICAL')" style="color: var(--status-crit)">[CRIT]</button>
                <button class="filter-btn" onclick="filterStatus('INFO')" style="color: var(--status-info)">[INFO]</button>
            </div>

            <div class="search-box">
                <input type="text" class="search-input" id="searchInput" placeholder="Поиск проверок..." oninput="handleSearch()">
            </div>
        </div>

        <!-- Checks Container -->
        <div class="checks-container" id="checksWrapper">
            <!-- Сюда рендерятся проверки через JavaScript -->
        </div>

        <!-- No Results -->
        <div class="no-results" id="noResultsBlock">
            Проверок, соответствующих заданным фильтрам, не обнаружено.
        </div>

        <!-- Screenshots Section -->
        <div class="screenshots-section" id="screenshotsBlock" style="display: none;">
            <div class="screenshots-title">Графические снимки экрана настроек безопасности</div>
            <div class="screenshots-grid" id="screenshotsWrapper">
                <!-- Сюда рендерятся скриншоты -->
            </div>
        </div>
    </div>

    <!-- Lightbox for Image zoom -->
    <div class="lightbox" id="lightbox" onclick="closeLightbox()">
        <div class="lightbox-content" onclick="event.stopPropagation()">
            <span class="lightbox-close" onclick="closeLightbox()">[X]</span>
            <img class="lightbox-img" id="lightboxImg" src="" alt="Zoomed Screenshot">
            <div class="lightbox-caption" id="lightboxCaption"></div>
        </div>
    </div>

    <script>
        // База данных проверок, генерируемая bash-скриптом
        const auditData = [
EOF

# Вставка данных проверок
echo "$JSON_DATA" >> "$REPORT_FILE"

cat << 'EOF' >> "$REPORT_FILE"
        ];

        // База данных скриншотов, генерируемая bash-скриптом
        const screenshotsData = [
EOF

# Вставка данных скриншотов
echo "$JSON_SCREENS" >> "$REPORT_FILE"

cat << 'EOF' >> "$REPORT_FILE"
        ];

        // Глобальные переменные активных фильтров
        let activeCategory = 'all';
        let activeStatus = 'all';
        let searchQuery = '';

        // Инициализация при загрузке страницы
        window.addEventListener('DOMContentLoaded', () => {
            renderDashboard();
            renderChecks();
            renderScreenshots();
        });

        // Функция рендеринга дашборда
        function renderDashboard() {
            const total = auditData.length;
            const passed = auditData.filter(c => c.status === 'PASSED').length;
            const warned = auditData.filter(c => c.status === 'WARNING').length;
            const critical = auditData.filter(c => c.status === 'CRITICAL').length;

            document.getElementById('totalChecks').innerText = total;
            document.getElementById('passedChecks').innerText = passed;
            document.getElementById('warningChecks').innerText = warned;
            document.getElementById('criticalChecks').innerText = critical;
        }

        // Функция отрисовки карточек проверок
        function renderChecks() {
            const wrapper = document.getElementById('checksWrapper');
            wrapper.innerHTML = '';

            let filtered = auditData;

            // Фильтр категории
            if (activeCategory !== 'all') {
                filtered = filtered.filter(c => c.category === activeCategory);
            }

            // Фильтр статуса
            if (activeStatus !== 'all') {
                filtered = filtered.filter(c => c.status === activeStatus);
            }

            // Фильтр поиска
            if (searchQuery.trim() !== '') {
                const query = searchQuery.toLowerCase();
                filtered = filtered.filter(c => 
                    c.title.toLowerCase().includes(query) || 
                    c.desc.toLowerCase().includes(query) || 
                    c.output.toLowerCase().includes(query)
                );
            }

            if (filtered.length === 0) {
                document.getElementById('noResultsBlock').style.display = 'block';
                return;
            } else {
                document.getElementById('noResultsBlock').style.display = 'none';
            }

            filtered.forEach((check, index) => {
                const card = document.createElement('div');
                card.className = 'check-card';

                let badgeClass = 'badge-info';
                let statusText = '[INFO]';
                if (check.status === 'PASSED') {
                    badgeClass = 'badge-passed';
                    statusText = '[PASS]';
                } else if (check.status === 'WARNING') {
                    badgeClass = 'badge-warning';
                    statusText = '[WARN]';
                } else if (check.status === 'CRITICAL') {
                    badgeClass = 'badge-critical';
                    statusText = '[CRIT]';
                }

                card.innerHTML = `
                    <div class="check-header">
                        <div class="check-title-group">
                            <span class="check-badge ${badgeClass}">${statusText}</span>
                            <span class="check-title">${check.title}</span>
                        </div>
                        <span class="check-category">${check.category}</span>
                    </div>
                    <div class="check-desc">${check.desc}</div>
                    <div class="check-details" id="details-${index}">
                        <div class="console-label">Команда выполнения:</div>
                        <div class="console-box console-cmd">$ ${check.command}</div>
                        <div class="console-label">Вывод терминала:</div>
                        <div class="console-box">${check.output || '[Нет вывода]'}</div>
                    </div>
                `;
                wrapper.appendChild(card);
            });
        }

        // Функция отрисовки скриншотов
        function renderScreenshots() {
            const block = document.getElementById('screenshotsBlock');
            const wrapper = document.getElementById('screenshotsWrapper');
            
            wrapper.innerHTML = '';
            
            if (screenshotsData.length === 0) {
                block.style.display = 'none';
                return;
            }

            block.style.display = 'block';

            screenshotsData.forEach(scr => {
                const card = document.createElement('div');
                card.className = 'screenshot-card';
                card.onclick = () => openLightbox(scr.file, scr.name);
                
                card.innerHTML = `
                    <div class="screenshot-img-container">
                        <img class="screenshot-img" src="${scr.file}" alt="${scr.name}" onerror="this.src='data:image/svg+xml;utf8,<svg xmlns=\'http://www.w3.org/2000/svg\' width=\'100\' height=\'100\' viewBox=\'0 0 100 100\'><text x=\'50%\' y=\'50%\' dominant-baseline=\'middle\' text-anchor=\'middle\' fill=\'%2364748b\' font-size=\'10\' font-family=\'monospace\'>[ Файл не найден ]</text></svg>'">
                    </div>
                    <div class="screenshot-info">
                        <div class="screenshot-name">${scr.name}</div>
                        <div class="screenshot-cmd">${scr.cmd}</div>
                    </div>
                `;
                wrapper.appendChild(card);
            });
        }

        // Фильтры категорий
        function filterCategory(category) {
            activeCategory = category;
            
            const btns = document.querySelectorAll('#categoryFilters .filter-btn');
            btns.forEach(btn => btn.classList.remove('active'));
            
            event.target.classList.add('active');
            renderChecks();
        }

        // Фильтры статусов
        function filterStatus(status) {
            activeStatus = status;
            
            const btns = document.querySelectorAll('#statusFilters .filter-btn');
            btns.forEach(btn => btn.classList.remove('active'));
            
            event.target.classList.add('active');
            renderChecks();
        }

        // Поиск проверок
        function handleSearch() {
            searchQuery = document.getElementById('searchInput').value;
            renderChecks();
        }

        // Переключение тем оформления
        function toggleTheme() {
            document.body.classList.toggle('light-theme');
            const btn = document.getElementById('themeBtn');
            if (document.body.classList.contains('light-theme')) {
                btn.innerText = '[ ТЕМНАЯ ТЕМА ]';
            } else {
                btn.innerText = '[ СВЕТЛАЯ ТЕМА ]';
            }
        }

        // Просмотр скриншота в полный экран (Lightbox)
        function openLightbox(src, name) {
            const lb = document.getElementById('lightbox');
            const lbImg = document.getElementById('lightboxImg');
            const lbCaption = document.getElementById('lightboxCaption');
            
            lbImg.src = src;
            lbCaption.innerText = name;
            lb.classList.add('active');
        }

        function closeLightbox() {
            document.getElementById('lightbox').classList.remove('active');
        }
    </script>
</body>
</html>
EOF

# Смена владельца и прав доступа, чтобы обычный пользователь мог просматривать отчет и скриншоты
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
    chown -R "$SUDO_USER:$SUDO_USER" "$REPORT_FILE" "$SCREENSHOT_DIR" "$SOFTWARE_FILE" 2>/dev/null || true
fi
chmod 644 "$REPORT_FILE" "$SOFTWARE_FILE" 2>/dev/null || true
if [ -d "$SCREENSHOT_DIR" ]; then
    chmod 755 "$SCREENSHOT_DIR" 2>/dev/null || true
    find "$SCREENSHOT_DIR" -type f -exec chmod 644 {} + 2>/dev/null || true
fi

echo "------------------------------------------------------------"
echo " Аудит завершен!"
echo " Отчет сгенерирован: $REPORT_FILE"
if [ "$CAPTURE_SCREEN" = true ]; then
    echo " Скриншоты сохранены в: $SCREENSHOT_DIR"
fi
echo "============================================================"
