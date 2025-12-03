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


##############################################
# USAGE
##############################################
usage() {
cat <<EOF
Usage:
  ./run_test.sh                   Run recoveries using existing backup + WAL
  ./run_test.sh -i                Initialize primary + workload + recovery
  ./run_test.sh -i --workload SQL Run full test with custom workload file

Optional flags:
  --workload PATH      Use custom pgbench script (applies only with -i)
  --pipeline-on        Force pipeline=on (runs recovery once)
  --pipeline-off       Force pipeline=off (runs recovery once)
  --test-dir DIR       Override default test dir.
  --pg-bin DIR       Override default postgresql bins
  --help               Show help

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

if [[ -n "$OVERRIDE_WORKLOAD" && "$INIT_PRIMARY" -ne 1 ]]; then
    echo "ERROR: --workload can only be used together with -i"
    echo "Example:"
    echo "  ./run_test.sh -i --workload sql/myload.sql"
    exit 1
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

	cat >> "$RECOVERY/postgresql.conf" <<EOF

# --- Recovery settings ---
archive_mode = off
enable_wal_pipeline = $PIPE
EOF

	local start=$(date +%s)
	echo "[+] Starting recovery..."

 	# perf record -F 999 -g -- $PGHOME/postgres -D "$RECOVERY"
	$PGHOME/pg_ctl -D "$RECOVERY" start

	local end=$(date +%s)
	echo ">>> Recovery finished in $((end-start)) seconds"

	stop_existing_postgres
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

	cat >> "$PRIMARY/postgresql.conf" <<EOF
wal_level = replica
archive_mode = on
archive_command = 'cp %p "$ARCHIVE/%f"'
EOF

	echo "[+] Starting primary"
	$PGHOME/pg_ctl -D "$PRIMARY" -l "$RESULTS/primary.log" start
	sleep 2

	echo "[+] Running DB init script"
	$PGHOME/psql postgres -f "$DB_INIT"

	echo "[+] Taking base backup"
	$PGHOME/pg_basebackup -D "$BACKUP" -X none -h localhost

	echo "[+] Running workload:"
	echo "    $WORKLOAD_FILE"
	$PGHOME/pgbench -n -c $CLIENTS -j $THREADS \
		-T $WORKLOAD_DURATION -f "$WORKLOAD_FILE" postgres

	echo "[!] Stopping primary"
	$PGHOME/pg_ctl -D "$PRIMARY" stop

	echo "[+] Running recovery tests"
	run_recovery_pair
}


##############################################
# RECOVERY-ONLY MODE
##############################################
process_recovery_only() {
	echo "== RECOVERY ONLY MODE =="

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
