#!/usr/bin/env bash

set -euo pipefail

############################
# User-configurable inputs #
############################

# Number of measurements per command
NUM_REPETITIONS=${NUM_REPETITIONS:-30}

# Optional commands that are run once before starting the experiment.
# IN this example, building Docker images
PREPARE_COMMANDS=(
    "DISTRO=alpine docker-compose -f workloads/docker-compose.yml build"
    "DISTRO=ubuntu docker-compose -f workloads/docker-compose.yml build"
)

# Array of configurations to measure.
# Format:
#   "friendly-name:::command to execute"
# If no friendly name is provided, the whole string is treated as the command.
# EnergiBridge will measure from the beginning of each command until it exits.
COMMANDS=(
	"alpine:::DISTRO=alpine docker-compose -f workloads/docker-compose.yml up  --abort-on-container-exit"
	"ubuntu:::DISTRO=ubuntu docker-compose -f workloads/docker-compose.yml up  --abort-on-container-exit"
)

#########################
# Optional configuration #
#########################

WARMUP_SECONDS=${WARMUP_SECONDS:-10}
SAMPLE_INTERVAL_MS=${SAMPLE_INTERVAL_MS:-100}
PAUSE_BETWEEN_RUNS=${PAUSE_BETWEEN_RUNS:-30}
OUTPUT_ROOT=${OUTPUT_ROOT:-results}
EXPERIMENT_ID=${EXPERIMENT_ID:-"experiment-$(date +%Y%m%d-%H%M%S)"}
ENERGIBRIDGE_BIN=${ENERGIBRIDGE_BIN:-energibridge}

cpu_count() {
	if command -v nproc >/dev/null 2>&1; then
		nproc
	else
		sysctl -n hw.ncpu
	fi
}

sanitize_name() {
	local raw="$1"
	local cleaned
	cleaned="$(echo "$raw" | tr '[:space:]/' '__' | tr -cd '[:alnum:]_.-')"
	cleaned="$(echo "$cleaned" | sed -E 's/[_\.-]+$//; s/^[_\.-]+//')"
	cleaned="${cleaned:0:40}"
	if [[ -z "$cleaned" ]]; then
		cleaned="cmd"
	fi
	echo "$cleaned"
}

parse_config_entry() {
	local entry="$1"
	if [[ "$entry" == *":::"* ]]; then
		CONFIG_ENTRY_NAME="${entry%%:::*}"
		CONFIG_ENTRY_COMMAND="${entry#*:::}"
	else
		CONFIG_ENTRY_NAME=""
		CONFIG_ENTRY_COMMAND="$entry"
	fi
}

warmup_cpu() {
	local workers
	workers="$(cpu_count)"

	echo "Running CPU warmup for ${WARMUP_SECONDS}s using ${workers} worker(s)..."

	if command -v sysbench >/dev/null 2>&1; then
		sysbench cpu --time="$((WARMUP_SECONDS * workers))" --threads="$workers" run >/dev/null
		return
	fi

	if command -v openssl >/dev/null 2>&1; then
		openssl speed -seconds "$WARMUP_SECONDS" -multi "$workers" sha256 >/dev/null 2>&1
		return
	fi

	# Fallback warmup when sysbench/openssl are unavailable.
	local pids=()
	local i
	for ((i = 0; i < workers; i++)); do
		yes >/dev/null &
		pids+=("$!")
	done
	sleep "$WARMUP_SECONDS"
	for pid in "${pids[@]}"; do
		kill "$pid" >/dev/null 2>&1 || true
	done
}

shuffle_lines() {
	awk 'BEGIN{srand()} {printf "%.12f\t%s\n", rand(), $0}' | sort -k1,1n | cut -f2-
}

# Run preparation commands before starting the experiment.
for prep_cmd in "${PREPARE_COMMANDS[@]}"; do
    echo "Running preparation command: $prep_cmd"
    eval "$prep_cmd"
done

if [[ ${#COMMANDS[@]} -eq 0 ]]; then
	echo "Error: COMMANDS array is empty. Add at least one command at the top of this script."
	exit 1
fi

if ! command -v "$ENERGIBRIDGE_BIN" >/dev/null 2>&1; then
	echo "Error: $ENERGIBRIDGE_BIN not found in PATH."
	exit 1
fi

if ! [[ "$NUM_REPETITIONS" =~ ^[0-9]+$ ]] || [[ "$NUM_REPETITIONS" -lt 1 ]]; then
	echo "Error: NUM_REPETITIONS must be a positive integer."
	exit 1
fi

if ! [[ "$PAUSE_BETWEEN_RUNS" =~ ^[0-9]+$ ]]; then
	echo "Error: PAUSE_BETWEEN_RUNS must be a non-negative integer."
	exit 1
fi

RUN_ROOT="${OUTPUT_ROOT}/${EXPERIMENT_ID}"
mkdir -p "$RUN_ROOT"

declare -a CONFIG_DIRS=()
declare -a CONFIG_DISPLAY_NAMES=()
declare -a SCHEDULE=()

echo "Preparing experiment at: $RUN_ROOT"

for idx in "${!COMMANDS[@]}"; do
	parse_config_entry "${COMMANDS[$idx]}"
	cmd="$CONFIG_ENTRY_COMMAND"
	config_label="config-$(printf '%02d' "$((idx + 1))")"
	config_name="$CONFIG_ENTRY_NAME"
	if [[ -n "$config_name" ]]; then
		config_slug="$(sanitize_name "$config_name")"
		config_display_name="$config_name"
	else
		config_slug="$(sanitize_name "$cmd")"
		config_display_name="$config_label"
	fi
	config_dir="${RUN_ROOT}/${config_label}__${config_slug}"

	CONFIG_DIRS[idx]="$config_dir"
	CONFIG_DISPLAY_NAMES[idx]="$config_display_name"
	mkdir -p "$config_dir"

	{
		echo "CONFIG_INDEX=$idx"
		echo "CONFIG_NAME=$config_display_name"
		echo "COMMAND=$cmd"
		echo "NUM_REPETITIONS=$NUM_REPETITIONS"
		echo "PAUSE_BETWEEN_RUNS=$PAUSE_BETWEEN_RUNS"
		echo "SAMPLE_INTERVAL_MS=$SAMPLE_INTERVAL_MS"
	} >"${config_dir}/config.txt"

	for ((rep = 1; rep <= NUM_REPETITIONS; rep++)); do
		SCHEDULE+=("${idx}:${rep}")
	done
done

warmup_cpu

echo "Starting measurements with randomized run order..."

mapfile -t SHUFFLED_SCHEDULE < <(printf '%s\n' "${SCHEDULE[@]}" | shuffle_lines)

total_runs="${#SHUFFLED_SCHEDULE[@]}"
run_number=0

for item in "${SHUFFLED_SCHEDULE[@]}"; do
	run_number=$((run_number + 1))

	idx="${item%%:*}"
	rep="${item##*:}"
	cmd="${COMMANDS[$idx]}"
	config_dir="${CONFIG_DIRS[$idx]}"
	config_name="${CONFIG_DISPLAY_NAMES[$idx]}"
	csv_path="${config_dir}/run-$(printf '%03d' "$rep").csv"

	echo "[$run_number/$total_runs] config=${config_name} repetition=$rep"
	"$ENERGIBRIDGE_BIN" -i "$SAMPLE_INTERVAL_MS" -o "$csv_path" -- bash -lc "$cmd"

	if [[ "$run_number" -lt "$total_runs" ]] && [[ "$PAUSE_BETWEEN_RUNS" -gt 0 ]]; then
		echo "Pausing ${PAUSE_BETWEEN_RUNS}s before next run..."
		sleep "$PAUSE_BETWEEN_RUNS"
	fi
done

echo "Done. Results written to: $RUN_ROOT"
