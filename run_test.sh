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


##############################################
# RUNTIME OPTIONS
##############################################
INIT_PRIMARY=0
FORCE_PIPELINE=""
OVERRIDE_WORKLOAD=""
RUN_WORKLOAD_INIT_ONLY=""


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



##############################################
# STOP RUNNING POSTGRES (SAFELY)
##############################################
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

	echo "[+] Copying WAL archive"
	cp -a "$ARCHIVE/." "$RECOVERY/pg_wal/"

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

	echo "[+] Additional confs for the recovery cluster:"
	cat config/recovery.conf

	echo "[+] Starting recovery..."

	# while benchmarking we may need perf the `postgres` process
	# so we have to implement waiting
	if [[ "$BENCHMARKING" == "on" ]]; then
		perf record -F 999 -g -- "$PGHOME/postgres" -D "$RECOVERY" &
		PG_PID=$!

		echo "Postgres started (pid=$PG_PID), waiting until ready..."

		until "$PGHOME/pg_isready" -d postgres -q; do
			sleep 2
		done
		return
	else
		$PGHOME/pg_ctl -D "$RECOVERY" -t 9999999 start
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
	echo "[+] Running DB init: pgbench -i -s 300 -F 90 postgres"
	$PGHOME/pgbench -i -s 300 -F 90 postgres
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
		echo "$PGHOME/pgbench -n -c "$CLIENTS" -j "$THREADS" -T "$WORKLOAD_DURATION" -b "$PGBENCH_BUILTIN" postgres"

		$PGHOME/pgbench \
			-n \
			-c "$CLIENTS" \
			-j "$THREADS" \
			-T "$WORKLOAD_DURATION" \
			-b "$PGBENCH_BUILTIN" \
			postgres
	else
		echo "[+] Running custom workload: $WORKLOAD_FILE"
		echo "$PGHOME/pgbench -n -c "$CLIENTS" -j "$THREADS" -T "$WORKLOAD_DURATION" -f "$WORKLOAD_FILE" postgres"
		$PGHOME/pgbench \
			-n \
			-c "$CLIENTS" \
			-j "$THREADS" \
			-T "$WORKLOAD_DURATION" \
			-f "$WORKLOAD_FILE" \
			postgres
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
