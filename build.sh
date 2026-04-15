#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob

# shellcheck disable=SC1091
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

vtf() { isoneof "$1" "true" "false" || abort "'$1' is not a valid option for '$2': only true or false is allowed"; }

# -- Main config --
toml_prep "${1:-config.toml}" || abort "Could not find config file '${1:-config.toml}'\n\tUsage: $0 <config.toml>"
main_config_t="$(toml_get_table_main)"
declare -A mconf
toml_load_table mconf "$main_config_t"
PARALLEL_JOBS="${mconf[parallel-jobs]:-$(nproc)}"
DEF_PATCHES_VER="${mconf[patches-version]:-latest}"
DEF_CLI_VER="${mconf[cli-version]:-latest}"
DEF_PATCHES_SRC="${mconf[patches-source]:-MorpheApp/morphe-patches}"
DEF_CLI_SRC="${mconf[cli-source]:-MorpheApp/morphe-cli}"
DEF_BRAND="${mconf[brand]:-Morphe}"
mkdir -p "$TEMP_DIR" "$BUILD_DIR"

: >build.md

for file in "$TEMP_DIR"/*/changelog.md; do
	[[ -f "$file" ]] && : >"$file"
done

idx=0
declare -A bconf
for table_name in $(toml_get_table_names); do
	[[ -z "$table_name" ]] && continue
	t="$(toml_get_table "$table_name")"
	bconf=()
	toml_load_table bconf "$t"
	enabled="${bconf[enabled]:-true}"
	vtf "$enabled" "enabled"
	[[ "$enabled" == "false" ]] && continue
	(( idx >= PARALLEL_JOBS )) && { 
		wait -n -p completed_pid || epr "Job $completed_pid failed"
		idx=$((idx - 1))
	}

	declare -A app_args
	patches_src="${bconf[patches-source]:-$DEF_PATCHES_SRC}"

	if [[ "${BUILD_MODE:-}" == "dev" ]]; then
		patches_ver="dev"
	else
		patches_ver="${bconf[patches-version]:-$DEF_PATCHES_VER}"
	fi

	cli_src="${bconf[cli-source]:-$DEF_CLI_SRC}"
	cli_ver="${bconf[cli-version]:-$DEF_CLI_VER}"

	PREBUILTS="$(get_prebuilts "$cli_src" "$cli_ver" "$patches_src" "$patches_ver")" || { epr "Could not get prebuilts"; continue; }
	read -r cli_jar patches_mpp <<<"$PREBUILTS"
	app_args[cli]="$cli_jar"
	app_args[ptmpp]="$patches_mpp"
	app_args[brand]="${bconf[brand]:-$DEF_BRAND}"

	app_args[excluded_patches]="${bconf[excluded-patches]:-}"
	[[ -n "${app_args[excluded_patches]}" && "${app_args[excluded_patches]}" != *"'"* ]] && abort "Patch names inside excluded-patches must be quoted"
	app_args[included_patches]="${bconf[included-patches]:-}"
	[[ -n "${app_args[included_patches]}" && "${app_args[included_patches]}" != *"'"* ]] && abort "Patch names inside included-patches must be quoted"
	app_args[exclusive_patches]="${bconf[exclusive-patches]:-false}"
	vtf "${app_args[exclusive_patches]}" "exclusive-patches"
	app_args[version]="${bconf[version]:-auto}"
	app_args[app_name]="${bconf[app-name]:-$table_name}"
	app_args[patcher_args]="${bconf[patcher-args]:-}"
	app_args[table]="$table_name"

	for dl_from in "${DL_SRCS[@]}"; do
		if [[ -n "${bconf[${dl_from}-dlurl]:-}" ]]; then
			dl_url="${bconf[${dl_from}-dlurl]}"
			dl_url="${dl_url%/}";
			dl_url="${dl_url%download}";
			dl_url="${dl_url%/}"
			app_args[${dl_from}_dlurl]="$dl_url"
			app_args[dl_from]="$dl_from"
		else
			app_args[${dl_from}_dlurl]=""
		fi
	done
	[[ -z "${app_args[dl_from]-}" ]] && abort "No 'dlurl' option was set for '$table_name' (${DL_SRCS[*]})"
	app_args[arch]="${bconf[arch]:-all}"
	isoneof "${app_args[arch]}" "both" "all" "arm64-v8a" "arm-v7a" "x86_64" "x86" || abort "Wrong arch '${app_args[arch]}' for '$table_name'"
	app_args[dpi]="${bconf[dpi]:-}"

	if [[ "${app_args[arch]}" == "both" ]]; then
		app_args[table]="$table_name (arm64-v8a)"
		app_args[arch]="arm64-v8a"
		idx=$((idx + 1))
		build_uni app_args &
		app_args[table]="$table_name (arm-v7a)"
		app_args[arch]="arm-v7a"
		(( idx >= PARALLEL_JOBS )) && { 
			wait -n -p completed_pid || epr "Job $completed_pid failed"
			idx=$((idx - 1))
		}
		idx=$((idx + 1))
		build_uni app_args &
	else
		isoneof "${app_args[arch]}" "all" || app_args[table]="${table_name} (${app_args[arch]})"
		idx=$((idx + 1))
		build_uni app_args &
	fi
done
wait
rm -rf temp/tmp.*
builds=("$BUILD_DIR"/*);
(( ${#builds[@]} == 0 )) && abort "All builds failed"

log "\n- ▶️ » Install [MicroG-RE](https://github.com/MorpheApp/MicroG-RE/releases) for YouTube and YT Music APKs\n"
changelogs=("$TEMP_DIR"/*/changelog.md)
if (( ${#changelogs[@]} > 0 )); then
    log "$(cat "${changelogs[@]}")"
fi

pr "Done"