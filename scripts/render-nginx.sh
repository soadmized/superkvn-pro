#!/bin/sh
set -eu
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/profile-lib.sh"
validate_profile_env
project_dir=$(dirname "$script_dir")
case "${1:-https}" in
    http) template="$project_dir/nginx/no_ssl.conf.template"; TRANSPORT_LOCATION=;;
    https)
        template="$project_dir/nginx/main.conf.template"
        TRANSPORT_LOCATION=$(envsubst '$NETWORK_PATH $NETWORK_PORT' < "$project_dir/nginx/transports/$NETWORK_TRANSPORT.conf.template")
        ;;
    *) fail 'Использование: render-nginx.sh [http|https]';;
esac
export TRANSPORT_LOCATION
# Do not expand nginx variables such as $host or $request_uri.
envsubst '$DOMAIN $TRANSPORT_LOCATION' < "$template"
