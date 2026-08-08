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
RUN_WORKLOAD_INIT_ONLY=""
PGBENCH_BUILTIN="simple-update"


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
  --pgbench-builtin NAME		Use biultin (i.e. simple-update) pgbench script for creating a workload (applies only with -i)
  --test-dir DIR       			Override default test dir.
  --pg-bin DIR       			Override default postgresql bins
  --help               			Show help

Examples:
  ./run_test.sh -i
  ./run_test.sh
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


##############################################
# RUN RECOVERY
##############################################
run_recovery_generic() {

	mkdir -p "$RESULTS"

	echo "================================"
	echo "    RECOVERY"
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

	# append mandaotry configs
	cat >> "$RECOVERY/postgresql.conf" <<EOF

# --- Recovery settings ---
archive_mode = off

EOF

	echo "[+] Additional confs for the recovery cluster:"
	cat config/recovery.conf


	# delete old cluster logs
	rm -f recoverylog

	echo "[+] Starting recovery..."

	$PGHOME/pg_ctl -D "$RECOVERY" -t 9999999 start -l recoverylog -o "'-p$PG_PORT'"

	echo "Postgres is ready"
	stop_existing_postgres

	sleep 2		# need to wait for perf to exit
}


run_recovery_pair() {
	run_recovery_generic "off"
	return
}



##############################################
# INIT PRIMARY + WORKLOAD + BACKUP + ARCHIVE
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
	$PGHOME/pg_ctl -D "$PRIMARY" -l "$RESULTS/primary.log" start -o "'-p$PG_PORT'"
	sleep 2

if [[ -n "$PGBENCH_BUILTIN" ]]; then
	echo "[+] Running DB init: "
	MY_COMMAND="$PGHOME/pgbench -i -s $SCALE_FACTOR -F $FILL_FACTOR -p$PG_PORT postgres"
	echo "$MY_COMMAND"
	eval "$MY_COMMAND"
else
	echo "[+] Running DB init: $DB_INIT"
	$PGHOME/psql postgres -f "$DB_INIT" -p$PG_PORT
fi

	echo "[+] Check DB size"
	$PGHOME/psql postgres -p$PG_PORT -c "SELECT pg_size_pretty(pg_database_size(current_database()));"


	echo "[+] Taking base backup"
	$PGHOME/pg_basebackup -p$PG_PORT -D "$BACKUP" -X none -h 127.0.0.1 -c fast -P

	if [[ -n "$PGBENCH_BUILTIN" ]]; then
		echo "[+] Running built-in workload: $PGBENCH_BUILTIN"
		MY_COMMAND="$PGHOME/pgbench -n -c "$CLIENTS" -M prepared -j "$THREADS" -T "$WORKLOAD_DURATION" -b "$PGBENCH_BUILTIN" -p$PG_PORT postgres"

		echo "$MY_COMMAND"
		eval "$MY_COMMAND"
	else
		echo "[+] Use --pgbench-builtin to specify workload to run"
	fi

	echo "[!] Stopping primary"
	$PGHOME/pg_ctl -D "$PRIMARY" stop

	if [[ "$RUN_WORKLOAD_INIT_ONLY" == "true" ]]; then
		return
	fi

	echo "[+] Running recovery tests"
	run_recovery_generic
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

	run_recovery_generic
}



##############################################
# MAIN
##############################################
if [[ "$INIT_PRIMARY" == "1" ]]; then
	process_full
else
	process_recovery_only
fi
