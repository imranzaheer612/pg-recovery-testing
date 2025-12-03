#!/bin/bash

# Modes:
#   full     → create cluster, workload, backup, run recovery
#   recovery → skip cluster creation and workload; only replay the existing archive

MODE="full"   
# MODE="recovery"

PGHOME="/home/imran/Desktop/work/pg/installs/pg18/bin"

PRIMARY="/media/imran/Local Disk/tmp/linux-work/pg-primary"
BACKUP="/media/imran/Local Disk/tmp/linux-work/pg-backup"
RECOVERY="/media/imran/Local Disk/tmp/linux-work/pg-recovery"      # cluster to recover using the wal archived from the primary
ARCHIVE="/media/imran/Local Disk/tmp/linux-work/pg-archive"

# pgbench settings
INIT_ROWS=5000000
WORKLOAD_DURATION=30
CLIENTS=8
THREADS=8
WORKLOAD="sql/workloads/updates.sql"
DB_INIT="sql/primary-init.sql"
# WORKLOAD="workloads/inserts.sql"
# WORKLOAD="workloads/nonhot.sql"

MAX_WAL_SIZE="1GB"
CHECKPOINT_TIMEOUT="5min"
FULL_PAGE_WRITES="on"


# Will rerun the recovery two time with 
# wal pipeline on and off
RERUN_RECOVERY="on"
# RERUN_RECOVERY="1"