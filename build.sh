#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob

source utils.sh
trap "abort" INT
[[ "${1-}" == "clean" ]] && { rm -rf "$TEMP_DIR" "$BUILD_DIR"; exit 0; }

set_prebuilts
_UA=$(ua)
export _UA

install_pkg jq
install_pkg java openjdk-25-jdk
install_pkg unzip

case "${1-}" in
	separate-config) separate_config "${@:2}"; exit 0 ;;
	combine-logs) combine_logs "${@:2}"; exit 0 ;;
	get-matrix) get_matrix "${@:2}"; exit 0 ;;
esac

vtf() { isoneof "$1" "true" "false" || abort "ERROR: '$1' is not a valid option for '$2': only true or false is allowed"; }

# -- Main config --
toml_prep "${1:-config.toml}" || abort "could not find config file '${1:-config.toml}'\n\tUsage: $0 <config.toml>"
main_config_t="$(toml_get_table_main)"
PARALLEL_JOBS="$(toml_get "$main_config_t" parallel-jobs)" || PARALLEL_JOBS="$(nproc)"
DEF_PATCHES_VER="$(toml_get "$main_config_t" patches-version)" || DEF_PATCHES_VER="latest"
DEF_CLI_VER="$(toml_get "$main_config_t" cli-version)" || DEF_CLI_VER="latest"
DEF_PATCHES_SRC="$(toml_get "$main_config_t" patches-source)" || DEF_PATCHES_SRC="MorpheApp/morphe-patches"
DEF_CLI_SRC="$(toml_get "$main_config_t" cli-source)" || DEF_CLI_SRC="MorpheApp/morphe-cli"
DEF_BRAND="$(toml_get "$main_config_t" brand)" || DEF_BRAND="Morphe"
DEF_DPI_LIST="$(toml_get "$main_config_t" dpi)" || DEF_DPI_LIST="nodpi anydpi 120-640dpi"
mkdir -p "$TEMP_DIR" "$BUILD_DIR"

: >build.md

for file in "$TEMP_DIR"/*/changelog.md; do
	[[ -f "$file" ]] && : >"$file"
done

idx=0
for table_name in $(toml_get_table_names); do
	[[ -z "$table_name" ]] && continue
	t="$(toml_get_table "$table_name")"
	enabled="$(toml_get "$t" enabled)" || enabled="true"
	vtf "$enabled" "enabled"
	[[ "$enabled" == "false" ]] && continue
	(( idx >= PARALLEL_JOBS )) && { wait -n; (( idx-- )); }

	declare -A app_args
	patches_src="$(toml_get "$t" patches-source)" || patches_src="$DEF_PATCHES_SRC"

	if [[ "${BUILD_MODE:-}" == "dev" ]]; then
		patches_ver="dev"
	else
		patches_ver="$(toml_get "$t" patches-version)" || patches_ver="$DEF_PATCHES_VER"
	fi

	cli_src="$(toml_get "$t" cli-source)" || cli_src="$DEF_CLI_SRC"
	cli_ver="$(toml_get "$t" cli-version)" || cli_ver="$DEF_CLI_VER"

	PREBUILTS="$(get_prebuilts "$cli_src" "$cli_ver" "$patches_src" "$patches_ver")" || { epr "Could not get prebuilts"; continue; }
	read -r cli_jar patches_mpp <<<"$PREBUILTS"
	app_args[cli]="$cli_jar"
	app_args[ptmpp]="$patches_mpp"
	app_args[brand]="$(toml_get "$t" brand)" || app_args[brand]="$DEF_BRAND"

	app_args[excluded_patches]="$(toml_get "$t" excluded-patches)" || app_args[excluded_patches]=""
	[[ -n "${app_args[excluded_patches]}" && "${app_args[excluded_patches]}" != *'"'* ]] && abort "patch names inside excluded-patches must be quoted"
	app_args[included_patches]="$(toml_get "$t" included-patches)" || app_args[included_patches]=""
	[[ -n "${app_args[included_patches]}" && "${app_args[included_patches]}" != *'"'* ]] && abort "patch names inside included-patches must be quoted"
	app_args[exclusive_patches]="$(toml_get "$t" exclusive-patches)" && vtf "${app_args[exclusive_patches]}" "exclusive-patches" || app_args[exclusive_patches]="false"
	app_args[version]="$(toml_get "$t" version)" || app_args[version]="auto"
	app_args[app_name]="$(toml_get "$t" app-name)" || app_args[app_name]="$table_name"
	app_args[patcher_args]="$(toml_get "$t" patcher-args)" || app_args[patcher_args]=""
	app_args[table]="$table_name"

	for dl_from in "${DL_SRCS[@]}"; do
		if dl_url="$(toml_get "$t" "${dl_from}-dlurl")"; then
			dl_url="${dl_url%/}";
			dl_url="${dl_url%download}";
			dl_url="${dl_url%/}"
			app_args[${dl_from}_dlurl]="$dl_url"
			app_args[dl_from]="$dl_from"
		else
			app_args[${dl_from}_dlurl]=""
		fi
	done
	[[ -z "${app_args[dl_from]-}" ]] && abort "ERROR: no 'dlurl' option was set for '$table_name'. (${DL_SRCS[*]})"
	app_args[arch]="$(toml_get "$t" arch)" || app_args[arch]="all"
	isoneof "${app_args[arch]}" "both" "all" "arm64-v8a" "arm-v7a" "x86_64" "x86" || abort "wrong arch '${app_args[arch]}' for '$table_name'"
	app_args[dpi]="$(toml_get "$t" dpi)" || app_args[dpi]="$DEF_DPI_LIST"

	if [[ "${app_args[arch]}" == "both" ]]; then
		app_args[table]="$table_name (arm64-v8a)"
		app_args[arch]="arm64-v8a"
		idx=$((idx + 1))
		build_uni "$(declare -p app_args)" &
		app_args[table]="$table_name (arm-v7a)"
		app_args[arch]="arm-v7a"
		(( idx >= PARALLEL_JOBS )) && { wait -n; (( idx-- )); }
		idx=$((idx + 1))
		build_uni "$(declare -p app_args)" &
	else
		isoneof "${app_args[arch]}" "all" || app_args[table]="${table_name} (${app_args[arch]})"
		idx=$((idx + 1))
		build_uni "$(declare -p app_args)" &
	fi
done
wait
rm -rf temp/tmp.*
[[ -z "$(ls -A1 "$BUILD_DIR")" ]] && abort "All builds failed."

log "\n- ▶️ » Install [MicroG-RE](https://github.com/MorpheApp/MicroG-RE/releases) for YouTube and YT Music APKs\n"
log "$(cat "$TEMP_DIR"/*/changelog.md)"

pr "Done"