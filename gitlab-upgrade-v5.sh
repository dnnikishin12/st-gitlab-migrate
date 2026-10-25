#!/bin/bash

# Строгий режим: выход при ошибках, использование неинициализированных переменных, ошибки в конвейерах
set -Eeuo pipefail

# Отключаем интерактивные запросы при установке пакетов
export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/gitlab-upgrade-$(date +%Y%m%d-%H%M%S).log"
STATE_DIR="/var/lib/gitlab-upgrade-state"

# --- КОНФИГУРАЦИЯ ОЖИДАНИЯ МИГРАЦИЙ ---
# Максимальное время ожидания миграций на одном шаге (48 часов)
MAX_MIGRATION_WAIT_SECONDS=172800
# Количество повторных попыток при ошибке команды gitlab-rake
RAKE_RETRY_MAX=5
# Интервал между проверками миграций (5 минут)
MIGRATION_CHECK_INTERVAL=300

# Список версий для последовательного обновления
VERSIONS=(
    "18.8.11-ce.0"
    "18.11.13-ce.0"
)

log() {
    echo -e "$(date +'%Y-%m-%d %H:%M:%S') - $*" | tee -a "$LOG_FILE"
}

# Логирование ошибки с указанием строки
trap 'log "❌ ERROR: скрипт остановлен на строке $LINENO, код ошибки $?"; exit 1' ERR

if [[ "$EUID" -ne 0 ]]; then
    echo "Пожалуйста, запустите скрипт от имени root (sudo -i)."
    exit 1
fi

mkdir -p "$STATE_DIR"

log "=== ЗАПУСК ПРОЦЕССА ОБНОВЛЕНИЯ GITLAB ДО 18.11.13 ==="

# Создаём файл пропуска автоматического бэкапа
if [[ ! -f /etc/gitlab/skip-auto-backup ]]; then
    log "Создаем файл /etc/gitlab/skip-auto-backup..."
    touch /etc/gitlab/skip-auto-backup
fi

# --- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ---

# Получение текущей установленной версии GitLab
get_installed_version() {
    dpkg-query --showformat='${Version}' --show gitlab-ce 2>/dev/null || echo "0"
}

# Проверка наличия всех целевых версий в apt-репозитории перед началом
check_versions_in_repo() {
    log "Проверяем наличие всех целевых версий в apt-репозитории..."

    local available
    available=$(apt-cache madison gitlab-ce 2>/dev/null | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')

    local v
    for v in "${VERSIONS[@]}"; do
        if ! grep -Fxq "$v" <<< "$available"; then
            log "❌ Версия $v не найдена в репозитории."
            log "Проверьте вывод: apt-cache madison gitlab-ce"
            exit 1
        fi
        log "Версия $v найдена в репозитории."
    done
}

# Ожидание завершения фоновых миграций с таймаутом и обработкой известных ошибок
wait_for_migrations() {
    log "Начинаем ожидание завершения фоновых миграций..."

    local output
    local rc
    local waited=0
    local errors=0
    local interval="$MIGRATION_CHECK_INTERVAL"

    while true; do
        # Гарантируем, что Sidekiq запущен, так как он выполняет миграции
        gitlab-ctl start sidekiq >/dev/null 2>&1 || true

        # Корректное получение кода возврата без срабатывания set -e
        if output=$(gitlab-rake gitlab:background_migrations:status 2>&1); then
            rc=0
        else
            rc=$?
        fi

        if [[ "$rc" -ne 0 ]]; then
            errors=$((errors + 1))
            log "⚠️ gitlab-rake завершилась с кодом $rc, попытка $errors/$RAKE_RETRY_MAX."
            echo "$output" | tee -a "$LOG_FILE"

            if [[ "$errors" -ge "$RAKE_RETRY_MAX" ]]; then
                log "❌ КРИТИЧЕСКАЯ ОШИБКА: слишком много ошибок при проверке миграций."
                exit 1
            fi

            sleep 60
            waited=$((waited + 60))
        else
            errors=0

            if echo "$output" | grep -Eq '(^|[[:space:]|])(active|paused)([[:space:]|]|$)'; then
                log "Миграции еще выполняются. Ожидание $interval секунд..."
                sleep "$interval"
                waited=$((waited + interval))
            elif echo "$output" | grep -q "There are no background migrations"; then
                log "✅ Фоновых миграций нет."
                break
            elif echo "$output" | grep -Eq '(^|[[:space:]|])failed([[:space:]|]|$)'; then
                log "❌ ОШИБКА: Обнаружены проваленные миграции (failed). Требуется ручное вмешательство."
                echo "$output" | tee -a "$LOG_FILE"
                exit 1
            else
                log "✅ Все фоновые миграции успешно завершены."
                break
            fi
        fi

        if [[ "$MAX_MIGRATION_WAIT_SECONDS" -gt 0 && "$waited" -ge "$MAX_MIGRATION_WAIT_SECONDS" ]]; then
            log "❌ Превышен лимит ожидания фоновых миграций: $waited секунд."
            exit 1
        fi
    done
}

# --- ПРЕДВАРИТЕЛЬНЫЕ ПРОВЕРКИ ---

CURRENT_INSTALLED_VERSION="$(get_installed_version)"
log "Текущая установленная версия: $CURRENT_INSTALLED_VERSION"

# Убедимся, что стартуем с правильной версии
if dpkg --compare-versions "$CURRENT_INSTALLED_VERSION" lt "15.4.6-ce.0"; then
    log "❌ Текущая версия ниже 15.4.6. Скрипт рассчитан на старт с 15.4.6."
    exit 1
fi

log "Использование диска:"
df -h / /var /var/opt/gitlab || true

log "Обновление списка пакетов..."
apt-get update

check_versions_in_repo

# --- ОСНОВНОЙ ЦИКЛ ОБНОВЛЕНИЯ ---

for VERSION in "${VERSIONS[@]}"; do
    log "======================================================"
    log "НАЧАЛО ОБНОВЛЕНИЯ ДО ВЕРСИИ: $VERSION"

    # Пропускаем уже выполненные шаги (защита от повторного запуска)
    if [[ -f "$STATE_DIR/$VERSION.done" ]]; then
        log "⏭️ Версия $VERSION уже отмечена как завершенная. Пропускаем."
        continue
    fi

    # Защита от понижения версии
    INSTALLED="$(get_installed_version)"
    if dpkg --compare-versions "$INSTALLED" gt "$VERSION"; then
        log "⚠️ Установленная версия ($INSTALLED) выше целевой ($VERSION). Пропускаем этот шаг."
        continue
    fi

    # 1. Ждем завершения миграций ПЕРЕД остановкой служб (Sidekiq работает)
    wait_for_migrations

    # 2. Останавливаем Puma и Sidekiq для безопасной установки
    log "Остановка Puma и Sidekiq..."
    gitlab-ctl stop puma || true
    gitlab-ctl stop sidekiq || true

    # 3. Установка пакета
    log "Установка пакета gitlab-ce=$VERSION..."
    apt-get install -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        "gitlab-ce=$VERSION"

    # 4. Переконфигурация
    log "Выполнение gitlab-ctl reconfigure..."
    gitlab-ctl reconfigure

    # 5. Принудительно останавливаем Puma, если reconfigure запустил его раньше времени
    gitlab-ctl stop puma || true

    # 6. Запускаем Sidekiq для выполнения миграций новой версии
    log "Запуск Sidekiq..."
    gitlab-ctl start sidekiq

    # 7. Ждем завершения миграций новой версии
    wait_for_migrations

    # 8. Запускаем Puma (теперь можно открывать веб-интерфейс)
    log "Запуск Puma..."
    gitlab-ctl start puma

    # Отмечаем версию как успешно завершенную
    touch "$STATE_DIR/$VERSION.done"

    log "✅ ВЕРСИЯ $VERSION УСПЕШНО УСТАНОВЛЕНА И НАСТРОЕНА."
    log "======================================================"
done

log "🎉 ЭТАП ОБНОВЛЕНИЯ GITLAB ДО 18.11.13 УСПЕШНО ЗАВЕРШЕН!"
log ""
log "⚠️ СЛЕДУЮЩИЙ ШАГ: ВАМ НЕОБХОДИМО ОБНОВИТЬ ОПЕРАЦИОННУЮ СИСТЕМУ."
log "Текущая ОС — Ubuntu 20.04, которая не поддерживается GitLab 19.x."
log ""
log "1. Убедитесь, что GitLab работает нормально."
log "2. Выполните обновление ОС: sudo do-release-upgrade (до 22.04)"
log "3. Перезагрузите сервер."
log "4. После перезагрузки и проверки работы GitLab, продолжите обновление до 19.x вручную."
log ""
log "Скрипт завершает работу."
