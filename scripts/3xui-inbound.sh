#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/profile-lib.sh"
. "$script_dir/api-lib.sh"
validate_profile_env
action=${1:-check}
if [ "$action" = list ]; then
    fetch_inbounds
    printf 'ID\tPORT\tTRANSPORT\tCLIENTS\tREMARK\n'
    printf '%s' "$response" | jq -r '
        def decoded: if type == "string" then fromjson else . end;
        .obj[] | [.id, .port, (.streamSettings|decoded|.network),
            (.settings|decoded|.clients // []|length), .remark] | @tsv'
    exit 0
fi
load_inbounds

case "$action" in
    ensure|create)
        if [ "$match_count" = 1 ]; then
            validate_inbound
            [ "$action" = ensure ] || fail 'Inbound уже существует.'
            printf 'Inbound соответствует конфигурации.\n'
            exit 0
        fi
        if [ "$action" = ensure ] && [ "$(printf '%s' "$response" | jq '.obj | length')" -gt 0 ]; then
            fail 'В панели уже есть inbound, но ни один не совпал с NETWORK_PORT/INBOUND_REMARK. Выполните make 3xui-list-inbounds и выберите существующий вход для миграции. Для отдельного нового входа используйте make 3xui-create-inbound.'
        fi
        uuid=$(cat /proc/sys/kernel/random/uuid)
        payload=$(jq -nc --arg remark "$INBOUND_REMARK" --argjson port "$NETWORK_PORT" \
            --arg uuid "$uuid" --arg subId "$(printf '%s' "$uuid" | tr -d '-')" \
            --argjson stream "$(transport_settings)" '
            {enable:true, remark:$remark, listen:"", port:$port, protocol:"vless",
             settings:({clients:[{id:$uuid,email:("user-"+$uuid),subId:$subId,enable:true,flow:"",
                limitIp:0,totalGB:0,expiryTime:0,tgId:0,reset:0}],decryption:"none",fallbacks:[]}|tojson),
             streamSettings:($stream|tojson), sniffing:({enabled:false}|tojson), tag:("inbound-"+($port|tostring))}')
        api_post add "$payload"
        printf 'Inbound создан: %s.\n' "$NETWORK_TRANSPORT"
        ;;
    check)
        [ "$match_count" = 1 ] || fail 'Inbound не найден.'
        validate_inbound
        ;;
    migrate)
        [ "$match_count" = 1 ] || fail 'Inbound не найден.'
        # Only migrate the plain WS/XHTTP endpoint owned by this project.
        printf '%s' "$inbound" | jq -e --argjson port "$NETWORK_PORT" --arg path "/$NETWORK_PATH" '
            def decoded: if type == "string" then fromjson else . end;
            .protocol == "vless" and .enable == true and .port == $port and
            (.streamSettings|decoded| (.security // "none") == "none" and
                ((.network == "ws" and .wsSettings.path == $path) or
                 (.network == "xhttp" and .xhttpSettings.path == ($path+"/"))))
        ' >/dev/null || fail 'Миграция разрешена только для активного VLESS WS/XHTTP этого проекта без внутреннего TLS.'
        inbound_id=$(printf '%s' "$inbound" | jq -er '.id | select(type == "number")')
        umask 077
        backup_dir=${BACKUP_DIR:-/etc/x-ui/transport-backups}
        mkdir -p "$backup_dir"
        backup=$(mktemp "$backup_dir/inbound-$inbound_id.XXXXXX")
        printf '%s\n' "$inbound" > "$backup"
        # Preserve clients, UUIDs, limits, counters and other inbound fields.
        payload=$(printf '%s' "$inbound" | jq -c --argjson stream "$(transport_settings)" '.streamSettings=($stream|tojson)')
        api_post "update/$inbound_id" "$payload"
        printf 'Транспорт изменён на %s. Резервная копия: %s\n' "$NETWORK_TRANSPORT" "$backup"
        ;;
    *) fail 'Использование: 3xui-inbound.sh [list|ensure|create|check|migrate]';;
esac
