#!/usr/bin/env bash

# shellcheck source=/dev/null
source "$CCO_INSTALLATION_DIR/lib/agents/codex.sh"
# shellcheck source=/dev/null
source "$CCO_INSTALLATION_DIR/lib/agents/droid.sh"
# shellcheck source=/dev/null
source "$CCO_INSTALLATION_DIR/lib/agents/opencode.sh"
# shellcheck source=/dev/null
source "$CCO_INSTALLATION_DIR/lib/agents/pi.sh"
# shellcheck source=/dev/null
source "$CCO_INSTALLATION_DIR/lib/agents/gemini.sh"

configure_agent_subcommand() {
	local agent="$1"
	case "$agent" in
	codex)
		command_flag="codex"
		configure_codex_mode_paths
		;;
	droid)
		command_flag="droid"
		configure_droid_mode_paths
		;;
	opencode)
		command_flag="opencode"
		configure_opencode_mode_paths
		;;
	pi)
		command_flag="pi"
		configure_pi_mode_paths
		;;
	gemini)
		command_flag="gemini --yolo"
		configure_gemini_mode_paths
		;;
	*)
		error "Unknown agent subcommand: $agent"
		exit 1
		;;
	esac
}

apply_agent_arg_policies() {
	local cmd_str
	cmd_str=$(get_command)
	local cmd_array=()
	read -ra cmd_array <<<"$cmd_str"
	if [[ ${#cmd_array[@]} -eq 0 ]]; then
		return
	fi

	case "${cmd_array[0]}" in
	codex)
		apply_codex_arg_policies
		;;
	droid)
		apply_droid_arg_policies
		;;
	opencode)
		apply_opencode_arg_policies
		;;
	pi)
		apply_pi_arg_policies
		;;
	gemini)
		apply_gemini_arg_policies
		;;
	esac
}
