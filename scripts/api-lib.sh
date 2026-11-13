#!/bin/sh
# Caller uses set -eu and sources profile-lib.sh first.
fetch_inbounds() {
    response=$(curl -fsS --connect-timeout 10 --max-time 30 -b "$COOKIE_FILE" "${API_BASE}panel/api/inbounds/list")
    printf '%s' "$response" | jq -e '.success == true and (.obj | type == "array")' >/dev/null \
        || fail 'Не удалось получить список inbound.'
}

load_inbounds() {
    fetch_inbounds
    matches=$(printf '%s' "$response" | jq -c --arg remark "$INBOUND_REMARK" --arg port "$NETWORK_PORT" \
        '[.obj[] | select(.remark == $remark or (.port | tostring) == $port)]')
    match_count=$(printf '%s' "$matches" | jq 'length')
    [ "$match_count" -le 1 ] || fail 'Найдено несколько inbound по INBOUND_REMARK или NETWORK_PORT.'
    inbound=$(printf '%s' "$matches" | jq -c '.[0]')
}

require_inbound() {
    load_inbounds
    [ "$match_count" = 1 ] || fail 'Inbound не найден.'
}

api_post() {
    # Do not retry a mutation after an ambiguous network/API error.
    api_response=$(curl -fsS --connect-timeout 10 --max-time 30 -b "$COOKIE_FILE" \
        -H "X-Csrf-Token: $(cat "$CSRF_TOKEN_FILE")" -H 'Content-Type: application/json' \
        -d "$2" "${API_BASE}panel/api/inbounds/$1")
    printf '%s' "$api_response" | jq -e '.success == true' >/dev/null \
        || fail "API: $(printf '%s' "$api_response" | jq -r '.msg // "операция не выполнена"')"
}
