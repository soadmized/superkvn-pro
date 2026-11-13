#!/bin/sh
# Runs inside the xray container after 3xui-login.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/profile-lib.sh"
. "$script_dir/api-lib.sh"
validate_profile_env
require_inbound
validate_inbound
inbound_id=$(printf '%s' "$inbound" | jq -er '.id | select(type == "number")')
uuid=$(cat /proc/sys/kernel/random/uuid)
client_name=${CLIENT_NAME:-client-$uuid}
case "$client_name" in
    .|..|*[!a-zA-Z0-9_@.-]*) fail 'CLIENT_NAME: используйте латинские буквы, цифры, _, @, точку или дефис (кроме . и ..).' ;;
esac
if printf '%s' "$response" | jq -e --arg name "$client_name" '
    .obj[] | .settings | if type == "string" then fromjson else . end |
    .clients[]? | select(.email == $name)
' >/dev/null; then
    fail "Клиент $client_name уже существует. Выберите другое имя."
fi
client=$(jq -nc --arg id "$uuid" --arg email "$client_name" --arg subId "$(printf '%s' "$uuid" | tr -d '-')" \
    '{id: $id, email: $email, subId: $subId, enable: true, flow: "", limitIp: 0, totalGB: 0, expiryTime: 0, tgId: 0, reset: 0}')
payload=$(jq -nc --argjson id "$inbound_id" --argjson client "$client" \
    '{id: $id, settings: ({clients: [$client]} | tojson)}')
csrf=$(cat "$CSRF_TOKEN_FILE")
umask 077
result_file=$(mktemp)
trap 'rm -f "$result_file"' EXIT HUP INT TERM
status=$(curl -sS --connect-timeout 10 --max-time 30 -o "$result_file" -w '%{http_code}' -b "$COOKIE_FILE" \
    -H "X-Csrf-Token: $csrf" -H 'Content-Type: application/json' \
    -d "$payload" "${API_BASE}panel/api/inbounds/addClient")
# New 3x-ui releases moved client creation to a separate endpoint.
# Retry only a missing route, never an ambiguous network/server failure.
if [ "$status" = 404 ]; then
    payload=$(jq -nc --argjson id "$inbound_id" --argjson client "$client" \
        '{inboundIds: [$id], client: $client}')
    status=$(curl -sS --connect-timeout 10 --max-time 30 -o "$result_file" -w '%{http_code}' -b "$COOKIE_FILE" \
        -H "X-Csrf-Token: $csrf" -H 'Content-Type: application/json' \
        -d "$payload" "${API_BASE}panel/api/clients/add")
fi
case "$status" in
    2??) ;;
    *) fail "API добавления клиента вернул HTTP $status." ;;
esac
jq -e '.success == true' "$result_file" >/dev/null \
    || fail "Клиент не создан: $(jq -r '.msg // "неизвестная ошибка API"' "$result_file")"
printf 'Клиент %s создан в inbound %s.\n' "$client_name" "$inbound_id"
profile_link "$uuid" "$client_name"
