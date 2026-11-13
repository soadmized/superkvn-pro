#!/bin/sh
# Shared by inbound creation, client addition and profile export.
fail() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }

validate_profile_env() {
    : "${DOMAIN:?DOMAIN не задан}" "${NETWORK_PORT:?NETWORK_PORT не задан}" "${NETWORK_PATH:?NETWORK_PATH не задан}"
    NETWORK_TRANSPORT=${NETWORK_TRANSPORT:-xhttp}
    TLS_FINGERPRINT=${TLS_FINGERPRINT:-chrome}
    case "$DOMAIN" in ''|*[!a-zA-Z0-9.-]*|.*|-*) fail 'DOMAIN должен быть DNS-именем без схемы и порта.';; esac
    case "$NETWORK_PATH" in ''|*[!a-zA-Z0-9_/-]*|/*|*/|*//*) fail 'NETWORK_PATH: относительный путь из букв, цифр, _, -, / без начального/конечного слеша.';; esac
    case "$NETWORK_PORT" in ''|*[!0-9]*) fail 'NETWORK_PORT должен быть числом.';; esac
    [ "$NETWORK_PORT" -gt 0 ] && [ "$NETWORK_PORT" -le 65535 ] || fail 'NETWORK_PORT вне диапазона 1–65535.'
    case "$NETWORK_TRANSPORT" in
        xhttp) PROFILE_PATH="/$NETWORK_PATH/"; PROFILE_ALPN=h2;;
        ws) PROFILE_PATH="/$NETWORK_PATH"; PROFILE_ALPN=http/1.1;;
        *) fail 'NETWORK_TRANSPORT: поддерживаются xhttp и ws.';;
    esac
    case "$TLS_FINGERPRINT" in chrome|firefox|safari) ;; *) fail 'TLS_FINGERPRINT: chrome, firefox или safari.';; esac
    export NETWORK_TRANSPORT TLS_FINGERPRINT PROFILE_PATH PROFILE_ALPN
}

validate_inbound() {
    printf '%s' "$inbound" | jq -e --arg transport "$NETWORK_TRANSPORT" \
        --arg path "$PROFILE_PATH" --arg domain "$DOMAIN" --argjson port "$NETWORK_PORT" '
        def decoded: if type == "string" then fromjson else . end;
        .protocol == "vless" and .enable == true and .port == $port and
        (.streamSettings | decoded | .network == $transport and
            (.security // "none") == "none" and
            (if $transport == "xhttp" then
                .xhttpSettings.path == $path and .xhttpSettings.mode == "stream-up" and
                ((.xhttpSettings.host // "") == "" or .xhttpSettings.host == $domain) and
                (.xhttpSettings.noGRPCHeader // false) == false
             else .wsSettings.path == $path end))
    ' >/dev/null || fail 'Inbound не соответствует .env (порт, VLESS, транспорт, путь, режим или TLS). Для смены ws/xhttp используйте make 3xui-migrate-transport.'
}

profile_link() {
    profile_uuid=$1
    profile_name=$2
    printf '%s' "$profile_uuid" | jq -Re 'test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")' >/dev/null \
        || fail 'Некорректный UUID клиента.'
    profile_query=$(jq -nr --arg transport "$NETWORK_TRANSPORT" --arg path "$PROFILE_PATH" \
        --arg domain "$DOMAIN" --arg fp "$TLS_FINGERPRINT" --arg alpn "$PROFILE_ALPN" '
        {type:$transport, encryption:"none", security:"tls", sni:$domain, host:$domain,
         path:$path, fp:$fp, alpn:$alpn} +
        (if $transport == "xhttp" then {mode:"stream-up"} else {} end) |
        to_entries | map((.key|@uri) + "=" + (.value|@uri)) | join("&")')
    profile_label=$(jq -nr --arg name "$profile_name" '$name | @uri')
    printf 'vless://%s@%s:443?%s#%s\n' "$profile_uuid" "$DOMAIN" "$profile_query" "$profile_label"
}

transport_settings() {
    jq -nc --arg transport "$NETWORK_TRANSPORT" --arg path "$PROFILE_PATH" --arg host "$DOMAIN" '
        {network:$transport, security:"none"} +
        (if $transport == "xhttp" then
            {xhttpSettings:{path:$path, host:$host, mode:"stream-up"}}
         else {wsSettings:{path:$path, headers:{}}} end)'
}
