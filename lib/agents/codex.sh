#!/usr/bin/env bash

is_codex_command_selected() {
	local cmd_str
	cmd_str=$(get_command)
	local cmd_array=()
	read -ra cmd_array <<<"$cmd_str"
	[[ ${#cmd_array[@]} -gt 0 && "${cmd_array[0]}" == "codex" ]]
}

codex_args_specify_sandbox() {
	local args=("$@")
	local idx
	for ((idx = 0; idx < ${#args[@]}; idx++)); do
		local arg="${args[$idx]}"
		case "$arg" in
		-s | --sandbox | --sandbox=*)
			return 0
			;;
		-c | --config)
			local next="${args[$((idx + 1))]:-}"
			if [[ "$next" == sandbox_mode=* ]]; then
				return 0
			fi
			;;
		esac
	done
	return 1
}

codex_args_contain_any() {
	local delimiter_seen=false
	local token
	local args=()
	local patterns=()

	for token in "$@"; do
		if [[ "$delimiter_seen" == false && "$token" == "--" ]]; then
			delimiter_seen=true
			continue
		fi
		if [[ "$delimiter_seen" == false ]]; then
			args+=("$token")
		else
			patterns+=("$token")
		fi
	done

	if [[ ${#patterns[@]} -eq 0 ]]; then
		return 1
	fi

	local arg
	local pattern
	for arg in "${args[@]}"; do
		for pattern in "${patterns[@]}"; do
			if [[ "$arg" == "$pattern" ]]; then
				return 0
			fi
		done
	done
	return 1
}

apply_codex_arg_policies() {
	if [[ "$codex_mode" != true ]]; then
		return
	fi

	if ! is_codex_command_selected; then
		return
	fi

	if [[ "$SANDBOX_BACKEND" == "docker" ]] && ! codex_args_contain_any "${claude_args[@]}" -- "--no-alt-screen"; then
		claude_args=("--no-alt-screen" "${claude_args[@]}")
		log "Added Codex Docker default argument '--no-alt-screen'"
	fi

	local requests_help_or_version=false
	if codex_args_contain_any "${claude_args[@]}" -- "-h" "--help" "-V" "--version"; then
		requests_help_or_version=true
	fi

	if [[ "$requests_help_or_version" == true ]]; then
		log "Codex help/version requested; skipping bypass flag injection"
		if [[ "$SANDBOX_BACKEND" == "docker" ]]; then
			log "Codex help/version requested; skipping Docker sandbox fallback injection"
		fi
		return
	fi

	if ! codex_args_contain_any "${claude_args[@]}" -- "--dangerously-bypass-approvals-and-sandbox"; then
		claude_args=("--dangerously-bypass-approvals-and-sandbox" "${claude_args[@]}")
		log "Added Codex bypass flag '--dangerously-bypass-approvals-and-sandbox'"
	fi

	if [[ "$SANDBOX_BACKEND" != "docker" ]]; then
		return
	fi

	if codex_args_specify_sandbox "${claude_args[@]}"; then
		log "Codex sandbox mode explicitly provided; leaving as-is"
		return
	fi

	claude_args=("--sandbox" "danger-full-access" "${claude_args[@]}")
	log "Added Codex fallback argument '--sandbox danger-full-access' for Docker backend"
}

configure_codex_mode_paths() {
	codex_mode=true
	# Mount Codex config/state directory.
	# Respect CODEX_HOME when set; otherwise use ~/.codex.
	local codex_home="${CODEX_HOME:-$HOME/.codex}"
	local resolved_codex_home
	resolved_codex_home=$(resolve_path "$codex_home")
	if [[ -e "$resolved_codex_home" && ! -d "$resolved_codex_home" ]]; then
		warn "Codex config path is not a directory: $resolved_codex_home"
		return
	fi
	if [[ ! -d "$resolved_codex_home" ]]; then
		mkdir -p "$resolved_codex_home"
	fi
	add_rw_path "$resolved_codex_home"
}

create_codex_mode_shim_dir() {
	local shim_dir
	shim_dir=$(mktemp -d "${TMPDIR:-/tmp}/cco-codex-shim.XXXXXX")

	cat >"$shim_dir/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
self_path="$self_dir/$(basename "${BASH_SOURCE[0]}")"
real_codex=""
IFS=':' read -r -a path_parts <<<"${PATH:-}"
for dir in "${path_parts[@]}"; do
	[[ -z "$dir" ]] && continue
	if [[ ! -d "$dir" ]]; then
		continue
	fi
	normalized_dir="$(cd "$dir" && pwd -P)"
	[[ "$normalized_dir" == "$self_dir" ]] && continue
	candidate="$normalized_dir/codex"
	if [[ -x "$candidate" ]]; then
		[[ "$candidate" == "$self_path" ]] && continue
		real_codex="$candidate"
		break
	fi
done

if [[ -z "$real_codex" ]]; then
	echo "cco codex-mode shim: could not locate real codex in PATH" >&2
	exit 127
fi

filtered_args=()
saw_bypass=false
requests_help_or_version=false

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help | -V | --version)
		requests_help_or_version=true
		filtered_args+=("$1")
		shift
		;;
	--dangerously-bypass-approvals-and-sandbox)
		saw_bypass=true
		shift
		;;
	-s | --sandbox)
		shift
		[[ $# -gt 0 ]] && shift
		;;
	--sandbox=*)
		shift
		;;
	-c | --config)
		if [[ $# -gt 1 && "$2" == sandbox_mode=* ]]; then
			shift 2
		else
			filtered_args+=("$1")
			shift
			if [[ $# -gt 0 ]]; then
				filtered_args+=("$1")
				shift
			fi
		fi
		;;
	*)
		filtered_args+=("$1")
		shift
		;;
	esac
done

cmd=("$real_codex")
if [[ "$saw_bypass" != true && "$requests_help_or_version" != true ]]; then
	cmd+=("--dangerously-bypass-approvals-and-sandbox")
fi
cmd+=("${filtered_args[@]}")
exec "${cmd[@]}"
EOF

	chmod +x "$shim_dir/codex"
	echo "$shim_dir"
}
