#!/usr/bin/env bash

TEMP_DIR="temp"
BIN_DIR="bin"
BUILD_DIR="build"
DL_SRCS=("direct" "archive" "apkmirror" "uptodown")
GH_HEADER=()
if [[ -n "${GITHUB_TOKEN-}" ]]; then
	CURL_HEADER="$(mktemp)"
	printf 'Authorization: token %s\n' "${GITHUB_TOKEN}" > "$CURL_HEADER"
	GH_HEADER=("-H" @"$CURL_HEADER")
fi

toml_prep() {
	[[ -f "$1" ]] || return 1
	case "${1##*.}" in
		toml) __TOML__="$("$TOML" --output json --file "$1" .)" ;;
		json) __TOML__="$(<"$1")" ;;
		*) abort "config extension not supported" ;;
	esac
}
toml_get_table_names() { jq -r -e 'to_entries[] | select(.value | type == "object") | .key' <<<"$__TOML__"; }
toml_get_table_main() { jq -r -e 'to_entries | map(select(.value | type != "object")) | from_entries' <<<"$__TOML__"; }
toml_get_table() { jq -r -e ".\"${1}\"" <<<"$__TOML__"; }
toml_get() {
	local op qp=$'\001'
	op="$(jq -r ".\"${2}\" | values" <<<"$1")"
	[[ -z "$op" ]] && return 1
	op="${op#"${op%%[![:space:]]*}"}"
	op="${op%"${op##*[![:space:]]}"}"
	op="${op//\\\'/$qp}"
	op="${op//"''"/$qp}"
	op="${op//"'"/'"'}"
	op="${op//$qp/$'\''}"
	printf '%s\n' "$op"
}

pr() { printf '\033[0;32m[+] %b\033[0m\n' "${1}" >&2; }
epr() {
	printf '\033[0;31m[-] %b\033[0m\n' "${1}" >&2
	[[ -n "${GITHUB_REPOSITORY-}" ]] && printf '::error::utils.sh [-] %b\n\n' "${1}" >&2
	return 0
}
wpr() {
	printf '\033[0;33m[!] %b\033[0m\n' "${1}" >&2
	[[ -n "${GITHUB_REPOSITORY-}" ]] && printf '::warning::utils.sh [!] %b\n\n' "${1}" >&2
	return 0
}
abort() {
	epr "ABORT: ${1-}"
	rm -rf "$TEMP_DIR"/*tmp.* "$TEMP_DIR"/*/*tmp.* "$TEMP_DIR"/*-temporary-files
	exit 1
}

install_pkg() {
	local cmd="$1" pkg="${2:-$1}"
	command -v "$cmd" >/dev/null 2>&1 && return 0
	pr "Installing $pkg..."

	local -a managers=("apt-get:install -y" "dnf:install -y" "yum:install -y" "pacman:-S --noconfirm" "apk:add")
	local pm args entry
	for entry in "${managers[@]}"; do
		pm="${entry%%:*}"
		if command -v "$pm" >/dev/null 2>&1; then
			read -r -a args <<<"${entry#*:}"
			sudo "$pm" "${args[@]}" "$pkg"
			break
		fi
	done
	command -v "$cmd" >/dev/null 2>&1 || abort "Failed to install $pkg"
}

get_prebuilts() {
	local cli_src="$1" cli_ver="$2" patches_src="$3" patches_ver="$4" src_ver
	local cl_dir="${patches_src%/*}"
	pr "Getting prebuilts (${cl_dir})"
	cl_dir="${TEMP_DIR}/${cl_dir,,}"
	mkdir -p "$cl_dir"

	for src_ver in "$cli_src CLI $cli_ver cli" "$patches_src Patches $patches_ver patches"; do
		local src tag ver fprefix
		read -r src tag ver fprefix <<<"$src_ver"

		local grab_cl="false"
		[[ "$tag" == "Patches" ]] && grab_cl="true"

		local dir="${src%/*}"
		dir="${TEMP_DIR}/${dir,,}"
		mkdir -p "$dir"

		local uni_rel="https://api.github.com/repos/${src}/releases" name_ver
		if [[ "$ver" == "dev" ]]; then
			ver="$(gh_req "$uni_rel" - | jq -e -r '.[] | .tag_name' | get_highest_ver)" || return 1
		fi
		if [[ "$ver" == "latest" ]]; then
			uni_rel+="/latest"
			name_ver="*"
		else
			uni_rel+="/tags/${ver}"
			name_ver="$ver"
		fi

		local ext="jar"
		[[ "$tag" == "Patches" ]] && ext="mpp"

		local url file tag_name matches count dev_args=()
		[[ "$ver" == "latest" ]] && dev_args=('!' -name '*dev*')
		file="$(find "$dir" -name "*${fprefix}-${name_ver#v}.${ext}" "${dev_args[@]}" -type f 2>/dev/null | head -n 1)"
		if [[ -z "$file" ]]; then
			local resp name
			resp="$(gh_req "$uni_rel" -)" || return 1
			tag_name="$(jq -r '.tag_name' <<<"$resp")" || return 1
			matches="$(jq -e ".assets | map(select(.name | endswith(\".${ext}\")))" <<<"$resp")" || return 1
			count="$(jq 'length' <<<"$matches")"
			if (( count > 1 )); then
				local matches_new
				matches_new="$(jq -e -r 'map(select(.name | contains("-dev") | not))' <<<"$matches")"
				(( $(jq 'length' <<<"$matches_new") == 1 )) && { matches="$matches_new"; count=1; }
			fi
			if (( count == 0 )); then
				epr "No asset was found"
				return 1
			elif (( count != 1 )); then
				wpr "More than 1 asset was found for this release. Falling back to the first one found..."
			fi
			read -r url name < <(jq -r '.[0] | "\(.url)\t\(.name)"' <<<"$matches")
			file="${dir}/${name}"
			gh_dl "$file" "$url" >&2 || return 1
			printf '> ⚙️ » %s: `%s/%s`  \n' "$tag" "${src%%/*}" "${name}" >>"${cl_dir}/changelog.md"
		else
			grab_cl="false"
			name="${file##*/}"
			tag_name="v${name#*-*-}"
			tag_name="${tag_name%.*}"
		fi
		[[ "$tag" == "Patches" && "$grab_cl" == "true" ]] && printf '[🔗 » Changelog](https://github.com/%s/releases/tag/%s)\n\n' "${src}" "${tag_name}" >>"${cl_dir}/changelog.md"
		printf '%s ' "$file"
	done
	printf '\n'
}
set_prebuilts() {
	APKSIGNER="${BIN_DIR}/apksigner.jar"
	HTMLQ="${BIN_DIR}/htmlq"
	TOML="${BIN_DIR}/tq"
}

_req() {
	local ip="$1" op="$2"
	shift 2
	local cookie="$TEMP_DIR/cookie.txt"
	local curl_args=(-L -c "$cookie" -b "$cookie" --connect-timeout 10 --retry 1 --fail -s -S "$@" "$ip")
	local dlp="$op"
	if [[ "$op" != "-" ]]; then
		[[ -f "$op" ]] && return 0
		dlp="${op%/*}/tmp.${op##*/}"
		if [[ -f "$dlp" ]]; then
			while [[ -f "$dlp" ]]; do sleep 1; done
			return 0
		fi
		curl_args+=(-o "$dlp")
	fi

	curl "${curl_args[@]}" || { epr "Request failed: $ip"; return 1; }
	[[ -z "$dlp" ]] && return 0
	[[ "$dlp" == "-" ]] || mv -f "$dlp" "$op"
}
ua() {
	local ver
	ver="$(curl -sf "https://product-details.mozilla.org/1.0/firefox_versions.json" | jq -re '.LATEST_FIREFOX_VERSION')" || ver="148.0"
	printf 'Mozilla/5.0 (X11; Linux x86_64; rv:%s.0) Gecko/20100101 Firefox/%s.0\n' "${ver%%.*}" "${ver%%.*}"
}
req() {
	[[ -z "${_UA:-}" ]] && _UA="$(ua)"
	_req "$1" "$2" --http2 --tlsv1.3 -A "$_UA"
}
gh_req() { _req "$1" "$2" "${GH_HEADER[@]}"; }
gh_dl() {
	[[ -f "$1" ]] && return 0
	pr "Getting '$1' from '$2'"
	_req "$2" "$1" "${GH_HEADER[@]}" -H "Accept: application/octet-stream"
}

log() { printf '%b\n' "$1" >>"build.md"; }
get_highest_ver() {
	local vers
	vers="$(cat)"
	if semver_validate "${vers%%$'\n'*}"; then sort -rV <<<"$vers" | head -n 1
	else head -n 1 <<<"$vers"; fi
}
semver_validate() {
	local a="${1%-*}"
	a="${a#v}"
	[[ -z "${a//[.0-9]/}" ]]
}
get_patch_last_supported_ver() {
	local list_patches="$1" pkg_name="$2" inc_sel="$3" _exc_sel="$4" _exclusive="$5" # TODO: resolve using all of these
	local op pcount
	if [[ -n "$inc_sel" ]]; then
		local ver vers=""
		while IFS= read -r line; do
			[[ -z "$line" ]] && continue
			line="${line:1:${#line}-2}"
			ver="$(sed -n "/^Name: $line\$/,/^\$/p" <<<"$list_patches" | sed -n "/^Compatible versions:\$/,/^\$/p" | tail -n +2)"
			vers+="${ver}"$'\n'
		done < <(list_args "$inc_sel")
		vers="$(awk '{$1=$1}1' <<<"$vers")"
		[[ -n "$vers" ]] && { get_highest_ver <<<"$vers"; return 0; }
	fi
	op="$(patches_list "$cli_jar" "$patches_mpp" "$pkg_name" versions)" || return 1
	[[ "$op" == *"Any"* ]] && return 0
	op="$(awk '/\(.* patch.*/,0 {$1=$1; print}' <<<"$op")"
	pcount="$(head -n 1 <<<"$op")" pcount="${pcount#*(}" pcount="${pcount% *}"
	[[ -n "$pcount" ]] || abort "No patches found for '$pkg_name' in patches '$patches_mpp'"
	grep -F "($pcount patch" <<<"$op" | sed 's/ (.* patch.*//' | get_highest_ver || return 1
}
patches_list() {
	local cli_jar="$1" patches_mpp="$2" pkg_name="$3" mode="${4:-patches}" op
	if [[ "$mode" == "versions" ]]; then
		op="$(java -jar "$cli_jar" list-versions "$patches_mpp" -f "$pkg_name" 2>&1)" || { epr "Could not list versions $cli_jar: '$op'"; return 1; }
	else
		op="$(java -jar "$cli_jar" list-patches --patches "$patches_mpp" -f "$pkg_name" -v -p 2>&1)" || { epr "Could not get patches list $cli_jar: '$op'"; return 1; }
	fi
	printf '%s\n' "$op"
}

isoneof() {
	local i="$1" v
	shift
	for v; do [[ "$v" == "$i" ]] && return 0; done
	return 1
}

# -------------------- apkmirror --------------------
apkmirror_search() {
	local resp="$1" dpi="$2" arch="$3" apk_bundle="$4"
	local dlurl="" node n lines

	local -a apparch=('universal' 'noarch' 'arm64-v8a + armeabi-v7a')
	[[ "$arch" != "all" ]] && apparch+=("$arch")
	local -a appdpi=("nodpi" "anydpi" "120-640dpi")
	[[ "$dpi" != "" ]] && appdpi+=("$dpi")

	for ((n = 1; n < 40; n++)); do
		node="$($HTMLQ "div.table-row.headerFont:nth-last-child($n)" -r "span:nth-child(n+3)" <<<"$resp")"
		[[ -z "$node" ]] && break
		dlurl="$($HTMLQ --base https://www.apkmirror.com --attribute href "div.table-cell:nth-child(1) > a:nth-child(1)" <<<"$node")"
		[[ -z "$dlurl" ]] && break
		mapfile -t lines <<<"$($HTMLQ --text --ignore-whitespace <<<"$node")"
		if [[ "${lines[2]}" == "$apk_bundle" ]] && isoneof "${lines[5]}" "${appdpi[@]}" && isoneof "${lines[3]}" "${apparch[@]}"; then
			printf '%s\n' "$dlurl"
			return 0
		fi
	done
	(( n == 2 )) && [[ -n "$dlurl" ]] && { printf '%s\n' "$dlurl"; return 0; }
	return 1
}
dl_apkmirror() {
	local url="$1" version="${2// /-}" output="$3" arch="$4" dpi="$5" is_bundle="false" suffix=""
	[[ -f "${output}.apkm" ]] && { req "$url" "${output}.apkm"; return; }
	[[ "$arch" == "arm-v7a" ]] && arch="armeabi-v7a"

	local resp node apkmname dlurl=""
	apkmname="$($HTMLQ "h1.marginZero" --text <<<"$__APKMIRROR_RESP__" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')"
	url="${url%/}/${apkmname}-${version//./-}-release/"
	resp="$(req "$url" -)" || return 1
	node="$($HTMLQ "div.table-row.headerFont:nth-last-child(1)" -r "span:nth-child(n+3)" <<<"$resp")"

	if [[ -n "$node" ]]; then
		local type
		for type in APK BUNDLE; do
			dlurl="$(apkmirror_search "$resp" "$dpi" "${arch}" "$type")" || continue
			[[ "$type" == "BUNDLE" ]] && is_bundle="true"
			break 2
		done
		[[ -z "$dlurl" ]] && return 1
		resp="$(req "$dlurl" -)"
	fi
	url="$(req "$($HTMLQ --base https://www.apkmirror.com --attribute href "a.btn" <<<"$resp")" - | $HTMLQ --base https://www.apkmirror.com --attribute href "span > a[rel = nofollow]")" || return 1

	[[ "$is_bundle" == "true" ]] && suffix=".apkm"
	req "$url" "${output}${suffix}" || return 1
}
get_apkmirror_vers() {
	local apkm_resp vers v r_vers=()
	apkm_resp="$(req "https://www.apkmirror.com/uploads/?appcategory=${__APKMIRROR_CAT__}" -)" || return 1
	vers="$(sed -n 's;.*Version:</span><span class="infoSlide-value">\(.*\) </span>.*;\1;p' <<<"$apkm_resp" | awk '{$1=$1}1')"
	[[ "$__AAV__" != "false" ]] && { printf '%s\n' "$vers"; return 0; }
	while IFS= read -r v; do
		[[ -z "$v" ]] && continue
		grep -iqE "${v} (beta|alpha)" <<<"$apkm_resp" || r_vers+=("$v")
	done < <(grep -ivE "(beta|alpha)" <<<"$vers")
	printf '%s\n' "${r_vers[@]}"
}
get_apkmirror_pkg_name() { sed -n 's;.*id=\(.*\)" class="accent_color.*;\1;p' <<<"$__APKMIRROR_RESP__"; }
get_apkmirror_resp() {
	__APKMIRROR_RESP__="$(req "${1}" -)" || return 1
	__APKMIRROR_CAT__="${1##*/}"
}

# -------------------- uptodown --------------------
dl_uptodown() {
	local uptodown_dlurl="$1" version="$2" output="$3" arch="$4" _dpi="$5" is_bundle="false" suffix=""

	[[ "$arch" == "arm-v7a" ]] && arch="armeabi-v7a"
	local -a apparch=('arm64-v8a, armeabi-v7a, x86_64' 'arm64-v8a, armeabi-v7a, x86, x86_64' 'arm64-v8a, armeabi-v7a')
	[[ "$arch" != "all" ]] && apparch+=("$arch")

	local i op resp data_code versionURL=""
	data_code="$($HTMLQ "#detail-app-name" --attribute data-code <<<"$__UPTODOWN_RESP__")" || return 1
	for i in {1..20}; do
		resp="$(req "${uptodown_dlurl}/apps/${data_code}/versions/${i}" -)" || continue
		op="$(jq -e -r ".data | map(select(.version == \"${version}\")) | .[0]" <<<"$resp")" || continue
		[[ "$(jq -e -r ".kindFile" <<<"$op")" == "xapk" ]] && is_bundle="true"
		versionURL="$(jq -e -r '.versionURL' <<<"$op")" && break || return 1
	done
	[[ -z "$versionURL" ]] && return 1
	versionURL="$(jq -e -r '.url + "/" + .extraURL + "/" + (.versionID | tostring)' <<<"$versionURL")"
	resp="$(req "$versionURL" -)" || return 1

	local data_version files node_arch="" data_file_id node_class file_type n
	data_version="$($HTMLQ '.button.variants' --attribute data-version <<<"$resp")" || return 1
	if [[ -n "$data_version" ]]; then
		files="$(req "${uptodown_dlurl%/*}/app/${data_code}/version/${data_version}/files" - | jq -e -r .content)" || return 1
		for ((n = 1; n < 12; n++)); do
			node_class="$($HTMLQ -w -t ".content > :nth-child($n)" --attribute class <<<"$files")" || return 1
			if [[ "$node_class" != "variant" ]]; then
				node_arch="$($HTMLQ -w -t ".content > :nth-child($n)" <<<"$files" | xargs)" || return 1
				continue
			fi
			[[ -z "$node_arch" ]] && return 1
			isoneof "$node_arch" "${apparch[@]}" || continue

			file_type="$($HTMLQ -w -t ".content > :nth-child($n) > .v-file > span" <<<"$files")" || return 1
			[[ "$file_type" == "xapk" ]] && is_bundle="true" || is_bundle="false"
			data_file_id="$($HTMLQ ".content > :nth-child($n) > .v-report" --attribute data-file-id <<<"$files")" || return 1
			resp="$(req "${uptodown_dlurl}/download/${data_file_id}-x" -)"
			break
		done
		(( n == 12 )) && return 1
	fi
	local data_url
	data_url="$($HTMLQ "#detail-download-button" --attribute data-url <<<"$resp")" || return 1
	[[ "$is_bundle" == "true" ]] && suffix=".apkm"
	req "https://dw.uptodown.com/dwn/${data_url}" "${output}${suffix}"
}
get_uptodown_vers() { $HTMLQ --text ".version" <<<"$__UPTODOWN_RESP__"; }
get_uptodown_pkg_name() { $HTMLQ --text "tr.full:nth-child(1) > td:nth-child(3)" <<<"$__UPTODOWN_RESP_PKG__"; }
get_uptodown_resp() {
	__UPTODOWN_RESP__="$(req "${1}/versions" -)" || return 1
	__UPTODOWN_RESP_PKG__="$(req "${1}/download" -)" || return 1
}

# -------------------- archive --------------------
dl_archive() {
	local url="$1" version="${2// /}" output="$3" arch="${4// /}" path is_bundle="false" suffix=""
	path="$(grep "${version#v}-${arch}" <<<"$__ARCHIVE_RESP__")" || return 1
	[[ "$path" =~ \.(apkm|xapk)$ ]] && is_bundle="true"
	[[ "$is_bundle" == "true" ]] && suffix=".apkm"
	req "${url}/${path}" "${output}${suffix}"
}
get_archive_vers() { sed 's/^[^-]*-//;s/-\(all\|arm64-v8a\|arm-v7a\)\.\(apk\|apkm\|xapk\)//g' <<<"$__ARCHIVE_RESP__"; }
get_archive_pkg_name() { printf '%s\n' "$__ARCHIVE_PKG_NAME__"; }
get_archive_resp() {
	local r
	r="$(req "$1" -)"
	[[ -z "$r" ]] && return 1
	__ARCHIVE_RESP__="$(sed -n 's;^<a href="\(.*\)"[^"]*;\1;p' <<<"$r")"
	__ARCHIVE_PKG_NAME__="${1##*/}"
}
# -------------------- direct --------------------
dl_direct() {
	local url="$1" version="${2// /-}" output="$3" arch="$4"
	req "$url" "${output}" || return 1
}
get_direct_vers() { cut -d- -f2 <<<"$__DIRECT_APKNAME__"; }
get_direct_pkg_name() { cut -d- -f1 <<<"$__DIRECT_APKNAME__"; }
get_direct_resp() { __DIRECT_APKNAME__="${1##*/}"; }
# --------------------------------------------------

patch_apk() {
	local stock_input="$1" patched_apk="$2" patcher_args="$3" cli_jar="$4" patches_mpp="$5"
	local cmd="java -jar '$cli_jar' patch '$stock_input' --purge -o '$patched_apk' -p '$patches_mpp'"
	local ks_pass="${KEYSTORE_PASS:-}"
	if [[ -n "$ks_pass" ]]; then
		cmd+=" --keystore=ks.keystore --keystore-entry-password='${ks_pass}' --keystore-password='${ks_pass}' --signer=krvstek --keystore-entry-alias=krvstek"
	elif [[ -f "morphe.keystore" ]]; then
		cmd+=" --keystore=morphe.keystore --keystore-entry-password=Morphe --signer=Morphe --keystore-entry-alias=Morphe"
	fi
	cmd+=" $patcher_args"
	pr "$cmd"
	eval "$cmd" && [[ -f "$patched_apk" ]] || { rm -f "$patched_apk"; return 1; }
}
check_sig() {
	local file="$1" pkg_name="$2" sig
	grep -q "$pkg_name" sig.txt || return 0
	sig="$(java -jar --enable-native-access=ALL-UNNAMED "$APKSIGNER" verify --print-certs "$file" | awk '/^Signer.*SHA-256/ {sig=$NF} END {print sig}')"
	[[ -z "$sig" ]] && return 1
	printf '%s signature: %s\n' "$pkg_name" "${sig}"
	grep -qFx "$sig $pkg_name" sig.txt
}
build_uni() {
	eval "declare -A args=${1#*=}"
	local version="" pkg_name=""
	local version_mode="${args[version]}"
	local app_name="${args[app_name]}"
	local -l app_name_l="${app_name// /-}"
	local table="${args[table]}"
	local dl_from="${args[dl_from]}"
	local arch="${args[arch]}"
	local arch_f="${arch// /}"

	local -a p_patcher_args=()
	[[ -n "${args[excluded_patches]}" ]] && p_patcher_args+=("$(join_args "${args[excluded_patches]}" -d)")
	[[ -n "${args[included_patches]}" ]] && p_patcher_args+=("$(join_args "${args[included_patches]}" -e)")
	[[ "${args[exclusive_patches]}" == "true" ]] && p_patcher_args+=("--exclusive")

	local tried_dl=() dl_p
	for dl_p in "${DL_SRCS[@]}"; do
		local p_url="${args[${dl_p}_dlurl]}"
		[[ -z "$p_url" ]] && continue
		if ! get_"${dl_p}"_resp "$p_url" || ! pkg_name="$(get_"${dl_p}"_pkg_name)"; then
			args[${dl_p}_dlurl]=""
			epr "ERROR: Could not find ${table} in ${dl_p}"
			continue
		fi
		tried_dl+=("$dl_p")
		dl_from="$dl_p"
		break
	done
	[[ -z "$pkg_name" ]] && { epr "empty pkg name, not building ${table}."; return 0; }
	pr "Package name of '${table}' is '$pkg_name'"
	local list_patches
	list_patches="$(patches_list "$cli_jar" "$patches_mpp" "$pkg_name")" || return 1

	local get_latest_ver="false"
	if [[ "$version_mode" == "auto" ]]; then
		version="$(get_patch_last_supported_ver "$list_patches" "$pkg_name" \
			"${args[included_patches]}" "${args[excluded_patches]}" "${args[exclusive_patches]}")" || {
			epr "get_patch_last_supported_ver failed '$list_patches'"
			return
		}
		[[ -z "$version" ]] && get_latest_ver="true"
	else
		p_patcher_args+=("-f")
		isoneof "$version_mode" latest beta && get_latest_ver="true" || version="$version_mode"
	fi
	if [[ "$get_latest_ver" == "true" ]]; then
		__AAV__="false"
		[[ "$version_mode" == "beta" ]] && __AAV__="true"
		local pkgvers
		pkgvers="$(get_"${dl_from}"_vers)"
		version="$(get_highest_ver <<<"$pkgvers")" || version="$(head -n 1 <<<"$pkgvers")"
	fi
	[[ -z "$version" ]] && { epr "empty version, not building ${table}."; return 0; }

	pr "Choosing version '${version}' for ${table}"
	local version_f="${version// /}"; version_f="${version_f#v}"
	local stock_apk="${TEMP_DIR}/${pkg_name}-${version_f}-${arch_f}.apk"
	if [[ ! -f "$stock_apk" && ! -f "${stock_apk}.apkm" ]]; then
		for dl_p in "${DL_SRCS[@]}"; do
			local p_url="${args[${dl_p}_dlurl]}"
			[[ -z "$p_url" ]] && continue
			pr "Downloading '${table}' from '${dl_p}'"
			if ! isoneof "$dl_p" "${tried_dl[@]}" && ! get_"${dl_p}"_resp "$p_url"; then
				epr "ERROR: Could not get '${table}' from '${dl_p}'"
				continue
			fi
			if ! dl_"${dl_p}" "$p_url" "$version" "$stock_apk" "$arch" "${args[dpi]}" "$get_latest_ver"; then
				epr "ERROR: Could not download '${table}' from '${dl_p}' with version '${version}', arch '${arch}', dpi '${args[dpi]}'"
				continue
			fi
			break
		done
		if [[ ! -f "$stock_apk" && ! -f "${stock_apk}.apkm" ]]; then
			epr "Stock apk not found ($stock_apk)"
			return 0
		fi
	fi
	local OP
	if [[ -f "${stock_apk}.apkm" ]]; then
		local tmp_base
		tmp_base="$(mktemp --suffix=.apk)"
		if ! unzip -p "${stock_apk}.apkm" base.apk > "$tmp_base" 2>/dev/null || [[ ! -s "$tmp_base" ]]; then
			unzip -p "${stock_apk}.apkm" "${pkg_name}.apk" > "$tmp_base" 2>/dev/null
		fi
		if [[ -s "$tmp_base" ]] && ! OP="$(check_sig "$tmp_base" "$pkg_name" 2>&1)"; then
			rm -f "$tmp_base"
			epr "Not building $table, apk signature mismatch in bundle '$stock_apk': $OP"
			return 0
		fi
		rm -f "$tmp_base"
	elif ! OP="$(check_sig "$stock_apk" "$pkg_name" 2>&1)" && ! grep -qFx "ERROR: Missing META-INF/MANIFEST.MF" <<<"$OP"; then
		epr "Not building $table, apk signature mismatch '$stock_apk': $OP"
		return 0
	fi
	log "🟢 » ${table}: \`${version}\`"

	local microg_patch disable_psu_patch _auto_patch
	microg_patch="$(grep -iE "^Name: .*(gmscore|microg)" <<<"$list_patches" || :)"; microg_patch="${microg_patch#*: }"
	disable_psu_patch="$(grep -i "^Name: .*disable play store updates" <<<"$list_patches" || :)"; disable_psu_patch="${disable_psu_patch#*: }"
	for _auto_patch in "$microg_patch" "$disable_psu_patch"; do
		[[ -z "$_auto_patch" ]] && continue
		if [[ "${p_patcher_args[*]}" =~ $_auto_patch ]]; then
			wpr "You can't include/exclude '$_auto_patch' patch as that's done by builder automatically."
			p_patcher_args=("${p_patcher_args[@]//-[de] \"${_auto_patch}\"/}")
		fi
	done

	local patcher_args patched_apk
	local -l brand_f="${args[brand]// /-}"
	[[ -n "${args[patcher_args]}" ]] && p_patcher_args+=("${args[patcher_args]}")
	patcher_args=("${p_patcher_args[@]}")
	pr "Building '${table}'"
	for _auto_patch in "$microg_patch" "$disable_psu_patch"; do
		[[ -n "$_auto_patch" ]] && patcher_args+=("-e \"${_auto_patch}\"")
	done
	patched_apk="${TEMP_DIR}/${app_name_l}-${brand_f}-${version_f}-${arch_f}.apk"

	local libs
	case "$arch" in
		"arm-v7a") libs="armeabi-v7a" ;;
		"arm64-v8a"|"x86"|"x86_64") libs="$arch" ;;
		*) libs="arm64-v8a,armeabi-v7a" ;;
	esac
	patcher_args+=("--striplibs $libs")
	local stock_apk_input="$stock_apk"
	[[ -f "${stock_apk}.apkm" ]] && stock_apk_input="${stock_apk}.apkm"
	if [[ "${NORB:-}" != "true" || ! -f "$patched_apk" ]]; then
		patch_apk "$stock_apk_input" "$patched_apk" "${patcher_args[*]}" "${args[cli]}" "${args[ptmpp]}" || {
			epr "Building '${table}' failed!"
			return 0
		}
	fi
	local apk_output="${BUILD_DIR}/${app_name_l}-${brand_f}-v${version_f}-${arch_f}.apk"
	mv -f "$patched_apk" "$apk_output"
	pr "Built ${table}: '${apk_output}'"
}

list_args() { grep -o '"[^"]*"' <<<"$1" || :; }
join_args() { list_args "$1" | sed "s/^/${2} /" | paste -sd " " - || :; }
separate_config() {
	local config="$1" key="$2" output="$3" arch="${4:-}" content
	content="$(awk -v key="$key" '
		BEGIN { print "[" key "]" }
		/^\[/ && tolower($1) == "[" tolower(key) "]" { in_section = 1; next }
		/^\[/ { in_section = 0 }
		in_section == 1
	' "$config")"
	[[ -z "$content" ]] && { printf "Key '%s' not found in the config file.\n" "$key" >&2; return 1; }
	if [[ -n "$arch" ]]; then
		if grep -q '^arch = ' <<<"$content"; then
			content="$(sed 's/^arch = .*/arch = "'"$arch"'"/' <<<"$content")"
		else
			content+=$'\narch = "'"$arch"'"'
		fi
	fi
	printf '%s\n' "$content" > "$output"
	printf "Section for '%s' written to %s\n" "$key" "$output"
}
combine_logs() {
	local -a logs
	local dir="${1:-logs}"
	mapfile -d '' logs < <(find "$dir" -name "build.md" -type f -print0 2>/dev/null | sort -z || true)
	(( ${#logs[@]} == 0 )) && return 0
	grep -h "^🟢" "${logs[@]}" 2>/dev/null || true
	printf '\n'
	cat "${logs[@]}" 2>/dev/null | grep -m 1 "^-.*MicroG" && printf '\n'

	local temp
	temp="$(mktemp)"
	trap 'rm -f "$temp"' RETURN
	awk '/^>.*CLI:/{p=1} p{print} /^\[.*Changelog\]/{print ""; p=0}' "${logs[@]}" 2>/dev/null > "$temp" || true
	[[ -s "$temp" ]] && awk '!seen[$0]++' "$temp"
}
get_matrix() {
	local config="${1:-config.toml}" source="${2:-morphe}"
	toml_prep "$config" || abort "could not find config file '$config'"

	local main_t def_brand
	main_t="$(toml_get_table_main)"
	def_brand="$(toml_get "$main_t" brand)" || def_brand="Morphe"

	local -a ids=()
	local table sourcel="${source,,}"
	while IFS= read -r table; do
		local table_t brand arch
		table_t="$(toml_get_table "$table")"
		brand="$(toml_get "$table_t" brand)" || brand="$def_brand"
		if [[ "${brand,,}" == "$sourcel" ]]; then
			arch="$(toml_get "$table_t" arch)" || arch="all"
			if [[ "$arch" == "both" ]]; then
				ids+=("{\"id\":\"${table}\",\"arch\":\"arm64-v8a\"}")
				ids+=("{\"id\":\"${table}\",\"arch\":\"arm-v7a\"}")
			else
				ids+=("{\"id\":\"${table}\"}")
			fi
		fi
	done < <(toml_get_table_names)

	(( ${#ids[@]} == 0 )) && abort "No apps found for patch source '$source'"
	local matrix
	printf -v matrix '%s,' "${ids[@]}"
	printf '{"include":[%s]}\n' "${matrix%,}"
}