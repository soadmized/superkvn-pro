.PHONY: check-env check-3xui up down logs nginx-http ssl-init ssl-renew cron-install cron-remove restart gen-pass 3xui-settings 3xui-login 3xui-create-inbound 3xui-inbound-exists 3xui-ensure-inbound 3xui-export-creds 3xui-add-client 3xui-init deploy xray-up nginx-https 3xui-export-links 3xui-migrate-transport 3xui-list-inbounds test

-include .env
export

NETWORK_TRANSPORT ?= xhttp
TLS_FINGERPRINT ?= chrome
XUI_EXEC = docker exec -e API_BASE -e COOKIE_FILE -e CSRF_TOKEN_FILE -e DOMAIN -e NETWORK_PORT -e NETWORK_PATH -e NETWORK_TRANSPORT -e TLS_FINGERPRINT -e INBOUND_REMARK -e CLIENT_NAME $(XUI_CONTAINER) sh

.NOTPARALLEL:

XUI_PASS_FILE=$(HOME)/creds.txt
CREDS_FILE=$(HOME)/creds.txt
XUI_CONTAINER=xray
INBOUND_REMARK ?= $(DOMAIN)-$(NETWORK_PORT)
CRON_CMD=cd $(PWD) && $(MAKE) ssl-renew >> /var/log/ssl-renew.log 2>&1
CRON_JOB=0 3 * * * $(CRON_CMD)

check-env:
	@sh -ec '. scripts/profile-lib.sh; validate_profile_env'
	@sh -ec 'case "$$UI_PORT" in ""|*[!0-9]*) exit 1;; esac; \
		{ [ "$$UI_PORT" -gt 0 ] && [ "$$UI_PORT" -le 65535 ] && [ "$$UI_PORT" != "$$NETWORK_PORT" ]; } || exit 1; \
		case "$$UI_DUMMY_PATH/$$UI_PATH" in /*|*/|*[!a-zA-Z0-9_/-]*) exit 1;; esac' \
		|| { echo 'Проверьте UI_PORT и пути панели; UI_PORT и NETWORK_PORT должны различаться.'; exit 1; }
	@if [ -z "$(DOMAIN)" ]; then \
		echo "DOMAIN не задан в .env"; exit 1; \
	fi
	@if [ -z "$(EMAIL)" ]; then \
		echo "EMAIL не задан в .env"; exit 1; \
	fi

check-3xui:
	@docker ps | grep -q xray || (echo "xray container not running" && exit 1)

xray-up: check-env
	docker compose up -d xray

# Validate or create the inbound before switching nginx to the selected transport.
up: check-env
	$(MAKE) xray-up
	$(MAKE) 3xui-init
	$(MAKE) nginx-https

nginx-https: check-env
	@set -eu; tmp=$$(mktemp -d nginx/.check.XXXXXX); trap 'rm -f "$$tmp/default.conf"; rmdir "$$tmp"' EXIT; \
		sh scripts/render-nginx.sh https > "$$tmp/default.conf"; \
		docker compose run --rm --no-deps --build -v "$$PWD/$$tmp:/etc/nginx/conf.d:ro" nginx nginx -t; \
		mv "$$tmp/default.conf" nginx/default.conf
	docker compose up -d --build --force-recreate nginx

down:
	docker compose down

logs:
	docker compose logs -f nginx

nginx-http: check-env
	@set -eu; tmp=$$(mktemp nginx/default.conf.XXXXXX); trap 'rm -f "$$tmp"' EXIT; \
		sh scripts/render-nginx.sh http > "$$tmp"; mv "$$tmp" nginx/default.conf
	docker compose up -d --force-recreate --build nginx

ssl-init: check-env
	@echo "🔐 Выпуск SSL-сертификата для $(DOMAIN)"
	docker compose run --rm certbot certonly \
		--webroot \
		--webroot-path=/var/www/certbot \
		--email $(EMAIL) \
		--agree-tos \
		--no-eff-email \
		-d $(DOMAIN) -d www.$(DOMAIN)

ssl-renew:
	@echo "♻️ Обновление SSL-сертификатов"
	docker compose run --rm certbot renew
	docker compose restart nginx

cron-install:
	@echo "⏱ Установка cron-задачи для SSL"
	@if ! command -v crontab >/dev/null 2>&1; then \
		echo "❌ Ошибка: crontab не установлен. Установите его (например, 'apt-get install cron') и попробуйте снова."; \
		exit 1; \
	fi
	@crontab -l 2>/dev/null | grep -v 'make ssl-renew' > /tmp/cron.tmp || true
	@echo "$(CRON_JOB)" >> /tmp/cron.tmp
	@crontab /tmp/cron.tmp
	@rm /tmp/cron.tmp
	@echo "✅ Cron-задача установлена"

cron-remove:
	@if ! command -v crontab >/dev/null 2>&1; then \
		echo "❌ Ошибка: crontab не установлен."; \
		exit 1; \
	fi
	@crontab -l 2>/dev/null | grep -v 'make ssl-renew' | crontab - || true

restart:
	$(MAKE) up

# Read only the first line: connection links follow it in the same file.
gen-pass:
	@set -eu; umask 077; \
	if [ ! -f "$(CREDS_FILE)" ]; then \
		printf 'admin:%s\n' "$$(openssl rand -base64 24)" > "$(CREDS_FILE)"; \
	fi; chmod 600 "$(CREDS_FILE)"; \
	PASS=$$(sed -n '1s/^admin://p' "$(CREDS_FILE)"); \
	[ -n "$$PASS" ] && [ "$${#PASS}" -le 72 ] || { echo 'Некорректная первая строка CREDS_FILE: ожидается admin:пароль (до 72 символов).'; exit 1; }

3xui-settings: gen-pass check-3xui
	docker exec $(XUI_CONTAINER) apk add --no-cache jq curl
	@XUI_PASSWORD=$$(sed -n '1s/^admin://p' "$(CREDS_FILE)") \
	docker exec -e XUI_PASSWORD $(XUI_CONTAINER) sh -c 'exec /app/x-ui setting \
		-username admin -password "$$XUI_PASSWORD" \
		-port $(UI_PORT) -webBasePath /$(UI_DUMMY_PATH)/$(UI_PATH)/'
	docker compose restart xray
	@docker exec $(XUI_CONTAINER) sh -c 'i=0; until curl -fsS -o /dev/null "$(API_BASE)"; do \
		i=$$((i+1)); [ "$$i" -lt 30 ] || exit 1; sleep 1; done'

# Вспомогательные переменные для API
COOKIE_FILE=/tmp/3xui_cookie.txt
CSRF_TOKEN_FILE=/tmp/3xui_csrf.txt
API_BASE=http://127.0.0.1:$(UI_PORT)/$(UI_DUMMY_PATH)/$(UI_PATH)/

# Авторизация в API
3xui-login: check-3xui
	@echo "🔑 Авторизация в API 3x-ui..."
	@docker exec $(XUI_CONTAINER) apk add --no-cache curl jq > /dev/null 2>&1
	@# Получаем CSRF токен и начальную куку
	@docker exec $(XUI_CONTAINER) sh -ec 'umask 077; PAGE=$$(curl -fsS --connect-timeout 5 --max-time 15 -L -c $(COOKIE_FILE) $(API_BASE)); \
		printf "%s" "$$PAGE" | sed -n "s/.*<meta name=\"csrf-token\" content=\"\([^\"]*\)\".*/\1/p" > $(CSRF_TOKEN_FILE)'
	@# Логинимся
	@XUI_PASSWORD=$$(sed -n '1s/^[^:]*://p' "$(CREDS_FILE)") \
	docker exec -e XUI_PASSWORD $(XUI_CONTAINER) sh -ec 'CSRF=$$(cat $(CSRF_TOKEN_FILE)); \
		RESPONSE=$$(curl -fsS --connect-timeout 5 --max-time 15 -b $(COOKIE_FILE) -c $(COOKIE_FILE) -X POST $(API_BASE)login \
		-H "X-Csrf-Token: $$CSRF" \
		-H "Referer: $(API_BASE)" \
		--data-urlencode "username=admin" \
		--data-urlencode "password=$$XUI_PASSWORD"); \
		printf "%s" "$$RESPONSE" | jq -e ".success == true" >/dev/null || { echo "Ошибка авторизации в 3x-ui"; exit 1; }'
	@echo "✅ Авторизация успешна"

# Shared API checks distinguish missing inbound from authentication/server failures.
3xui-list-inbounds: 3xui-login
	@$(XUI_EXEC) /opt/superkvn/3xui-inbound.sh list

3xui-create-inbound: 3xui-login
	@$(XUI_EXEC) /opt/superkvn/3xui-inbound.sh create

3xui-inbound-exists: 3xui-login
	@$(XUI_EXEC) /opt/superkvn/3xui-inbound.sh check

3xui-ensure-inbound: 3xui-login
	@$(XUI_EXEC) /opt/superkvn/3xui-inbound.sh ensure

3xui-export-links: 3xui-login
	@$(XUI_EXEC) /opt/superkvn/3xui-export-links.sh

3xui-export-creds: 3xui-login
	@set -eu; umask 077; \
	links=$$($(XUI_EXEC) /opt/superkvn/3xui-export-links.sh); \
	printf '\nConnection links (%s):\n%s\n' "$(NETWORK_TRANSPORT)" "$$links" >> "$(CREDS_FILE)"; \
	chmod 600 "$(CREDS_FILE)"; echo 'Ссылки сохранены в $(CREDS_FILE)'

3xui-add-client: 3xui-login
	@$(XUI_EXEC) /opt/superkvn/3xui-add-client.sh

# Explicit cutover; preserves UUIDs. Change NETWORK_TRANSPORT in .env first.
3xui-migrate-transport: check-env
	$(MAKE) xray-up
	$(MAKE) 3xui-settings
	$(MAKE) 3xui-login
	@$(XUI_EXEC) /opt/superkvn/3xui-inbound.sh migrate
	$(MAKE) nginx-https
	$(MAKE) 3xui-export-creds
	@echo 'Импортируйте новые ссылки на всех устройствах. UUID сохранены.'

# Настройка 3x-ui
3xui-init: check-3xui
	$(MAKE) 3xui-settings
	$(MAKE) 3xui-ensure-inbound
	$(MAKE) 3xui-export-creds

# Поднятие всего и сразу
deploy:
	$(MAKE) nginx-http
	$(MAKE) ssl-init
	$(MAKE) cron-install
	$(MAKE) up
	@echo "🔍 Проверка логов xray для диагностики:"
	@docker compose logs --tail=20 $(XUI_CONTAINER)
	@echo "Установка завершена! Ссылка подключения и креды для админки в $(CREDS_FILE)"
