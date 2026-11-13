#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/profile-lib.sh"
. "$script_dir/api-lib.sh"
validate_profile_env
require_inbound
validate_inbound
clients=$(printf '%s' "$inbound" | jq -c '
    .settings | if type == "string" then fromjson else . end |
    [.clients[]? | select(.enable != false)]')
[ "$(printf '%s' "$clients" | jq 'length')" -gt 0 ] || fail 'Нет включённых клиентов для экспорта.'
# A failed client must fail the complete export; the Make target saves only on success.
printf '%s' "$clients" | jq -c '.[]' | while IFS= read -r client; do
    profile_link "$(printf '%s' "$client" | jq -er '.id')" "$(printf '%s' "$client" | jq -r '.email // "client"')"
done
