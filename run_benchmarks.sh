#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# Load environment / variables from env.conf
###############################################################################
source config/env.conf

###############################################################################
# Directories
###############################################################################
RECOVERY="$TEST_DIR/recovery"
RESULTS="$TEST_DIR/results"

RESULTS_DIR="$RESULTS"
LOG_DIR="$RESULTS_DIR/logs"
PERF_DIR="$RESULTS_DIR/perf"
CLUSTERS_INIT_DIR="$RESULTS_DIR/logs/init"
SUMMARY_FILE="$RESULTS_DIR/summary.txt"

mkdir -p "$LOG_DIR" "$PERF_DIR" "$CLUSTERS_INIT_DIR"
: > "$SUMMARY_FILE"

init_cluster_file=""

###############################################################################
# Configuration
###############################################################################
WORKLOADS=(
  "inserts.sql"
  "updates.sql"
  "nonhot.sql"
  "hot-updates.sql"
)

PGBENCH_WORKLOADS=(
  "simple-update"
  "tpcb-like"
#  "select-only"
)

RECOVERIES_PER_TEST=1

FLAMEGRAPH_DIR="/home/cybertec/work/installs/scripts/FlameGraph"
STACKCOLLAPSE="$FLAMEGRAPH_DIR/stackcollapse-perf.pl"
FLAMEGRAPH="$FLAMEGRAPH_DIR/flamegraph.pl"

###############################################################################
# Utility functions
###############################################################################
log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

fatal() {
    echo "FATAL: $*" >&2
    exit 1
}

###############################################################################
# helpers
###############################################################################
parse_elapsed_last() {
    grep -oE 'elapsed: [0-9.]+ s' "$1" | tail -n1 | awk '{print $2}'
}

parse_pgbench_cmd() {
    grep -oE 'pgbench .* (-b [^ ]+|-f [^ ]+\.sql).*' "$1" | head -n1
}

parse_db_size() {
    awk '
        $1 == "pg_size_pretty" {
            getline    # separator line
            getline    # value line
            print $1, $2
            exit
        }
    ' "$1"
}

generate_flamegraph() {
    local svg="$1"
    perf script | "$STACKCOLLAPSE" | "$FLAMEGRAPH" > "$svg"
}

is_pgbench_builtin() {
    local w="$1"
    for b in "${PGBENCH_WORKLOADS[@]}"; do
        [[ "$w" == "$b" ]] && return 0
    done
    return 1
}

###############################################################################
# Run a single recovery test
###############################################################################
run_recovery_test() {
    local pipeline_mode="$1"   # p0 | p1
    local workload="$2"        # inserts.sql
    local config_tag="$3"      # def | sbuff

    local workload_name="${workload%.sql}"
    local test_name="rec-${pipeline_mode}-${workload_name}-${config_tag}"
    local log_file="$LOG_DIR/${test_name}.log"

    rm -f "$log_file"

    log "Running test: $test_name"
    : > "$log_file"

    for ((run=1; run<=RECOVERIES_PER_TEST; run++)); do
        log "  Recovery $run/$RECOVERIES_PER_TEST"

        if [[ "$pipeline_mode" == "p1" ]]; then
            ./run_test.sh --pipeline-on >>"$log_file" 2>&1
        else
            ./run_test.sh --pipeline-off >>"$log_file" 2>&1
        fi
    done

    local elapsed
    elapsed="$(parse_elapsed_last "$log_file")"

    local pgbench_cmd
    pgbench_cmd="$(parse_pgbench_cmd "$init_cluster_file")"
    
    local db_size
    db_size="$(parse_db_size "$init_cluster_file")"

    echo
    echo "RESULT:"
    echo "  Test     : $test_name"
    echo "  Elapsed  : ${elapsed}s"
    echo "  Workload : $pgbench_cmd"
    echo "  Initial DB size : $db_size"
    echo

    local svg_file="${test_name}.svg"
    local svg_file_path="$PERF_DIR/$svg_file"
    generate_flamegraph "$svg_file_path"
    log "FlameGraph saved: $svg_file_path"

    echo "$test_name | ${elapsed}s | $pgbench_cmd | $db_size | $svg_file">> "$SUMMARY_FILE"
}


run_workload() {
    local workload="$1"

    log "============================================================"
    log "WORKLOAD: $workload"
    log "============================================================"

    ###########################################################################
    # INIT ONCE PER WORKLOAD
    ###########################################################################
    init_cluster_file="$CLUSTERS_INIT_DIR/workload_init_${workload}.log"
    rm -f "$init_cluster_file"

    log "Initializing cluster for workload: $workload"
    log "init logs: $init_cluster_file"

    if is_pgbench_builtin "$workload"; then
        ./run_test.sh \
            -i \
            --pgbench-builtin "$workload" \
            --init-only >>"$init_cluster_file" 2>&1
    else
        ./run_test.sh \
            -i \
            --workload "sql/workloads/$workload" \
            --init-only >>"$init_cluster_file" 2>&1
    fi

    ###########################################################################
    # DEFAULT CONFIG
    ###########################################################################
    run_recovery_test "p0" "$workload" "def"
    run_recovery_test "p1" "$workload" "def"

    ###########################################################################
    # shared_buffers OVERRIDE
    ###########################################################################
    log "Applying shared_buffers override"

    cat >>"tmp-recovery.conf" <<EOF
shared_buffers = 8GB
EOF

    run_recovery_test "p0" "$workload" "sbuff"
    run_recovery_test "p1" "$workload" "sbuff"


    ###########################################################################
    # work_mem  OVERRIDE
    ###########################################################################
    log "Applying shared_buffers override"

    cat >>"tmp-recovery.conf" <<EOF
shared_buffers = 8GB
maintenance_work_mem = 1GB
work_mem = 1GB
EOF

    run_recovery_test "p0" "$workload" "sbuff-m"
    run_recovery_test "p1" "$workload" "sbuff-m"

    ###########################################################################
    # RESET FOR NEXT WORKLOAD
    ###########################################################################
    log "Resetting cluster state"
	rm "tmp-recovery.conf"

    # sed -i '/shared_buffers = 10GB/d' "$RECOVERY/postgresql.conf"
    # ./run_test.sh --reset || true
}


for workload in "${PGBENCH_WORKLOADS[@]}"; do
    run_workload "$workload"
done


for workload in "${WORKLOADS[@]}"; do
  run_workload "$workload"
done

###############################################################################
# Done
###############################################################################
log "All benchmarks completed"
log "Summary file: $SUMMARY_FILE"
