#!/bin/bash
# Reads the app's stored options (JSON) on stdin. If export_folders uses the
# legacy names "addons"/"addon_configs", prints the POST /addons/self/options
# payload with them renamed to "local_apps"/"app_configs" (as the Samba add-on
# does). Prints nothing when there is nothing to migrate.
set -e

jq --compact-output '
    def migrate:
        map(if . == "addons" then "local_apps"
            elif . == "addon_configs" then "app_configs"
            else . end)
        | reduce .[] as $f ([]; if index([$f]) then . else . + [$f] end);
    select((.export_folders // []) | any(. == "addons" or . == "addon_configs"))
    | {options: (.export_folders |= migrate)}'
