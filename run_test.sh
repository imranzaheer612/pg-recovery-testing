#!/bin/bash
set -e

source config/env.conf


##############################################
# DERIVED DIRECTORIES
##############################################
PRIMARY="$TEST_DIR/primary"
BACKUP="$TEST_DIR/backup"
RECOVERY="$TEST_DIR/recovery"
ARCHIVE="$TEST_DIR/archive"
RESULTS="$TEST_DIR/results"
BENCH_PERF_DATA_DIR="$TEST_DIR/perfdata"


##############################################
# RUNTIME OPTIONS
##############################################
INIT_PRIMARY=0
FORCE_PIPELINE=""
OVERRIDE_WORKLOAD=""
RUN_WORKLOAD_INIT_ONLY=""
DO_CRASH_RECOVERY=0


##############################################
# USAGE
##############################################
usage() {
cat <<EOF
Usage:
  ./run_test.sh				Run recoveries using existing backup + WAL
  ./run_test.sh -i			Initialize the clusters before running recoveries.
  ./run_test.sh -i --workload <path> 	Run recoveries with custom workload file

Optional flags:
  --init-only				Only init the clusters for recoveries.
  --workload PATH      			Use custom pgbench script for cerating workload (applies only with -i)
  --pgbench-builtin NAME		Use biultin (i.e. simple-update) pgbench script for creating a workload (applies only with -i)
  --pipeline-on        			Force pipeline=on (runs recovery once)
  --pipeline-off       			Force pipeline=off (runs recovery once)
  --test-dir DIR       			Override default test dir.
  --pg-bin DIR       			Override default postgresql bins
  --crash						Forces an crash recoviery, otherwise archive recovery by default
  --help               			Show help

Examples:
  ./run_test.sh -i
  ./run_test.sh -i --workload sql/heavy_updates.sql
  ./run_test.sh --pipeline-on
EOF
exit 0
}


##############################################
# ARGUMENT PARSER
##############################################

while [[ $# -gt 0 ]]; do
    case $1 in
        -i)
            INIT_PRIMARY=1
            shift
            ;;

        --pipeline-on)
            FORCE_PIPELINE="on"
            shift
            ;;

        --pipeline-off)
            FORCE_PIPELINE="off"
            shift
            ;;

        --workload)
            if [[ -z "$2" ]]; then
                echo "ERROR: --workload requires a file path"
                exit 1
            fi
            OVERRIDE_WORKLOAD="$2"
            shift 2
            ;;

        --init-only)
            RUN_WORKLOAD_INIT_ONLY="true"
            shift
            ;;

        --crash)
            DO_CRASH_RECOVERY=1
            shift
            ;;

		--pgbench-builtin)
			if [[ -z "$2" ]]; then
				echo "ERROR: --pgbench-builtin requires a name"
				exit 1
			fi
			PGBENCH_BUILTIN="$2"
			shift 2
			;;

        --pg-bin)
            if [[ -z "$2" ]]; then
                echo "ERROR: --pg-bin requires a path"
                exit 1
            fi
            PGHOME="$2"
            shift 2
            ;;

        --test-dir)
            if [[ -z "$2" ]]; then
                echo "ERROR: --test-dir requires a directory"
                exit 1
            fi
            TEST_DIR="$2"
            TEST_DIR_OVERRIDE=1

            # Recompute subdirectories
            PRIMARY="$TEST_DIR/primary"
            BACKUP="$TEST_DIR/backup"
            RECOVERY="$TEST_DIR/recovery"
            ARCHIVE="$TEST_DIR/archive"
            RESULTS="$TEST_DIR/results"
            shift 2
            ;;

        --help|-h)
            usage
            ;;

        *)
            echo "Unknown argument: $1"
            usage
            ;;
    esac
done

# Workload validation
if [[ $INIT_PRIMARY -eq 1 ]]; then
    if [[ -n "$OVERRIDE_WORKLOAD" && -n "$PGBENCH_BUILTIN" ]]; then
        echo "ERROR: Use either --workload or --pgbench-builtin, not both"
        exit 1
    fi
else
    if [[ -n "$OVERRIDE_WORKLOAD" || -n "$PGBENCH_BUILTIN" ]]; then
        echo "ERROR: workloads can only be specified with -i"
        exit 1
    fi
fi

# Final workload selection
WORKLOAD_FILE="${OVERRIDE_WORKLOAD:-$WORKLOAD}"


#
# STOP RUNNING POSTGRES (SAFELY)
#
stop_existing_postgres() {
	echo "[+] Checking for any running PostgreSQL instances"

	for DIR in "$PRIMARY" "$RECOVERY"; do
		if [[ -d "$DIR" && -f "$DIR/postmaster.pid" ]]; then
			echo "Stopping $DIR..."
			$PGHOME/pg_ctl -D "$DIR" stop -m fast || true
		fi
	done

	echo "[-] All clusters stopped."
	echo ""
}

start_postgres_attach_perf()
{
	mkdir -p "$BENCH_PERF_DATA_DIR"
		"$PGHOME/postgres" -D "$RECOVERY" &
		# "$PGHOME/postgres" -D "$RECOVERY" >> recoverylog 2>&1 &
		POSTMASTER_PID=$!
		echo "Postmaster PID: $POSTMASTER_PID"

		#
		# Wait for startup process
		#
		while true; do
			STARTUP_PID=$(ps -eo pid,cmd | \
				grep "startup recovering" | \
				grep -v grep | \
				awk '{print $1}')
			[ -n "$STARTUP_PID" ] && break
			sleep 0.1
		done
		echo "Startup PID: $STARTUP_PID"

		#
		# Wait for pipeline worker
		#
		PIPELINE_PID=""
		if [[ "$FORCE_PIPELINE" == "on" ]]; then
			while true; do
				PIPELINE_PID=$(ps -eo pid,cmd | \
					grep "wal pipeline producer" | \
					grep -v grep | \
					awk '{print $1}')
				[[ -n "$PIPELINE_PID" ]] && break
				sleep 0.1
			done
		fi
		echo "Pipeline PID: $PIPELINE_PID"

		#
		# Start perf
		#
		perf record -F 999 -g -p "$STARTUP_PID" \
			-o "$BENCH_PERF_DATA_DIR/startup-p-$FORCE_PIPELINE.data" &
		STARTUP_PERF_PID=$!

		PIPELINE_PERF_PID=""
		if [[ -n "$PIPELINE_PID" ]]; then
			perf record -F 999 -g -p "$PIPELINE_PID" \
				-o "$BENCH_PERF_DATA_DIR/pipeline-p-$FORCE_PIPELINE.data" &
			PIPELINE_PERF_PID=$!
		fi

		#
		# Wait until recovery completes
		#
		echo "[+] Waiting for recovery to fully complete"
		until "$PGHOME/pg_controldata" "$RECOVERY" 2>/dev/null | grep -q "Database cluster state:.*in production"; do
			sleep 2
		done
		echo "[+] Recovery complete."

		print_stats

		#
		# Stop postgres — was never shut down in benchmarking path
		#
		echo "Stopping postgres after benchmarking run"
		"$PGHOME/pg_ctl" -D "$RECOVERY" stop -m fast || \
			kill -TERM "$POSTMASTER_PID" 2>/dev/null || true
		wait "$POSTMASTER_PID" 2>/dev/null || true
}


print_stats()
{
		# check bgwirttr stats
		"$PGHOME/psql" -h 127.0.0.1 postgres \
				-c "SELECT * FROM pg_stat_bgwriter;" || true
		
		# check pg_stat_io
		"$PGHOME/psql" -h 127.0.0.1 postgres \
				-c "SELECT * FROM pg_stat_io
WHERE reads > 0
   OR writes > 0
   OR writebacks > 0
   OR fsyncs > 0
ORDER BY backend_type, object, context;" || true

		# check pg_wait_sampling
		"$PGHOME/psql" -h 127.0.0.1 postgres \
				-c "create extension pg_wait_sampling;" || true
		"$PGHOME/psql" -h 127.0.0.1 postgres \
				-c "SELECT 
    p.pid,
    p.event_type,
    p.event,
    p.queryid,
    p.count,
    a.backend_type AS process_name,
    a.usename AS username,
    a.datname AS database_name
FROM 
    pg_wait_sampling_profile p
LEFT JOIN 
    pg_stat_activity a ON p.pid = a.pid
ORDER BY 
    p.event_type, 
    p.count DESC;" || true
}


##############################################
# RUN RECOVERY (GENERIC)
##############################################
run_recovery_generic() {
	local PIPE="$1"

	mkdir -p "$RESULTS"

	echo "================================"
	echo "    RECOVERY (pipeline = $PIPE)"
	echo "================================"

	stop_existing_postgres

	rm -rf "$RECOVERY"
	mkdir -p "$RECOVERY/pg_wal"

	echo "[+] Copying base backup"
	cp -a "$BACKUP/." "$RECOVERY/"

	if [[ $DO_CRASH_RECOVERY -eq 1 ]]; then
		echo "[+] Copying WAL archive"
		cp -a "$ARCHIVE/." "$RECOVERY/pg_wal/"
	fi

	chmod -R 700 "$RECOVERY"

	# append user given configs
	cat config/recovery.conf >> "$RECOVERY/postgresql.conf"

	# append benchmarking configs if available
	if [[ -f tmp-recovery.conf ]]; then
	    cat tmp-recovery.conf >> "$RECOVERY/postgresql.conf"
	fi

	# append mandaotry configs
	cat >> "$RECOVERY/postgresql.conf" <<EOF

# --- Recovery settings ---
archive_mode = off
wal_pipeline = $PIPE
log_min_messages = warning

EOF

	# Only trigger archive recovery if configured
	if [[ $DO_CRASH_RECOVERY -eq 0 ]]; then
		touch "$RECOVERY/recovery.signal"
			cat >> "$RECOVERY/postgresql.conf" <<EOF
restore_command = 'cp "$ARCHIVE/%f" %p'

EOF
	fi

	echo "[+] Additional confs for the recovery cluster:"
	cat config/recovery.conf

	if [[ -f tmp-recovery.conf ]]; then
		echo "[+] Additional confs for the recovery cluster (benchmarking):"
		cat tmp-recovery.conf
	fi

	# delete old cluster logs
	rm -f recoverylog

	echo "[+] Starting recovery..."

	#
	# while benchmarking we may need to perf the target processes
	# so we have to implement waiting
	#
	if [[ "$PERF_PROFILING" == "on" ]]; then
		start_postgres_attach_perf
	else
		$PGHOME/pg_ctl -D "$RECOVERY" -t 9999999 start -l recoverylog
		
		# 
		# In case of archive recovery we have to wait until all wal in replayed
		# and should keep depending upon pg_ctl
		#
		if [[ $DO_CRASH_RECOVERY -eq 0 ]]; then
			echo "[+] Waiting for recovery to fully complete (promotion)..."
			until "$PGHOME/pg_controldata" "$RECOVERY" 2>/dev/null | grep -q "Database cluster state:.*in production"; do
				sleep 1
			done
			echo "[+] Recovery complete, cluster promoted."
		fi

	fi

	echo "Postgres is ready"
	stop_existing_postgres

	sleep 2		# need to wait for perf to exit
}


run_recovery_pair() {
	if [[ "$FORCE_PIPELINE" == "on" ]]; then
		run_recovery_generic "on"
		return
	fi
	if [[ "$FORCE_PIPELINE" == "off" ]]; then
		run_recovery_generic "off"
		return
	fi

	run_recovery_generic "off"
	run_recovery_generic "on"
}



##############################################
# INIT PRIMARY + WORKLOAD + BACKUP
##############################################
process_full() {
	echo "== FULL TEST MODE =="

	MY_COMMAND=""

	stop_existing_postgres

	echo "[+] Cleaning test directory"
	rm -rf "$PRIMARY" "$BACKUP" "$RECOVERY" "$ARCHIVE"
	mkdir -p "$PRIMARY" "$BACKUP" "$ARCHIVE" "$RESULTS"

	echo "[+] initdb"
	$PGHOME/initdb "$PRIMARY"

	echo "[+] Applying primary.conf"
	cat config/primary.conf >> "$PRIMARY/postgresql.conf"

	echo "[+] Additional confs for the primary cluster:"
	cat config/primary.conf


	cat >> "$PRIMARY/postgresql.conf" <<EOF
wal_level = replica
archive_mode = on
archive_command = 'cp %p "$ARCHIVE/%f"'
EOF

	echo "[+] Starting primary"
	$PGHOME/pg_ctl -D "$PRIMARY" -l "$RESULTS/primary.log" start
	sleep 2

if [[ -n "$PGBENCH_BUILTIN" ]]; then
	echo "[+] Running DB init: "
	MY_COMMAND="$PGHOME/pgbench -i -s $SCALE_FACTOR -F $FILL_FACTOR  postgres"
	echo "$MY_COMMAND"
	eval "$MY_COMMAND"
else
	echo "[+] Running DB init: $DB_INIT"
	$PGHOME/psql postgres -f "$DB_INIT"
fi

	echo "[+] Check DB size"
	$PGHOME/psql postgres -c "SELECT pg_size_pretty(pg_database_size(current_database()));"


	echo "[+] Taking base backup"
	$PGHOME/pg_basebackup -D "$BACKUP" -X none -h 127.0.0.1 -c fast -P

	if [[ -n "$PGBENCH_BUILTIN" ]]; then
		echo "[+] Running built-in workload: $PGBENCH_BUILTIN"
		MY_COMMAND="$PGHOME/pgbench -n -c "$CLIENTS" -M prepared -j "$THREADS" -T "$WORKLOAD_DURATION" -b "$PGBENCH_BUILTIN" postgres"

		echo "$MY_COMMAND"
		eval "$MY_COMMAND"
	else
		echo "[+] Running custom workload: $WORKLOAD_FILE"
		MY_COMMAND="$PGHOME/pgbench -n -c "$CLIENTS" -M prepared -j "$THREADS" -T "$WORKLOAD_DURATION" -f "$WORKLOAD_FILE" postgres"
		echo "$MY_COMMAND"
		eval "$MY_COMMAND"
	fi

	echo "[!] Stopping primary"
	$PGHOME/pg_ctl -D "$PRIMARY" stop

	if [[ "$RUN_WORKLOAD_INIT_ONLY" == "true" ]]; then
		return
	fi

	echo "[+] Running recovery tests"
	run_recovery_pair
}


##############################################
# RECOVERY-ONLY MODE
##############################################
process_recovery_only() {
	echo "== RECOVERY ONLY MODE =="
	echo "[+] Running recoveries on previously created archives and backups. If you want to run new test workload use -i"

	if [[ ! -d "$BACKUP" ]]; then
		echo "ERROR: No backup found at $BACKUP"
		echo "Run with -i first."
		exit 1
	fi

	run_recovery_pair
}



##############################################
# MAIN
##############################################
if [[ "$INIT_PRIMARY" == "1" ]]; then
	process_full
else
	process_recovery_only
fi
