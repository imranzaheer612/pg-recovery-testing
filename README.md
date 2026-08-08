Running PostgreSQL WAL recovery with different workloads.

```
Usage:
  ./run_test.sh							  Run recoveries using existing backup + acrhive
  ./run_test.sh -i						Run new workload and create new archive before recovery.

Optional flags:
  --init-only					      Only init the clusters for recoveries.
  --pgbench-builtin NAME		Use biultin (i.e. simple-update) pgbench script for creating a workload (applies only with -i)
  --test-dir DIR       			Override default test dir.
  --pg-bin DIR       			  Override default postgresql bins
  --help               			Show help

Examples:
  ./run_test.sh -i
  ./run_test.sh --pg-bin "/home/user/pg18/bin" --test-dir "/tmp/wal-test"


Defaults:

    PGHOME="/usr/lib/postgresql/18/bin"
    TEST_DIR="/tmp/pg_waltest"

Configurable:

* You can change the defaults from `config/env.conf`
* You can pg conf for primary cluster `config/primary.conf`
* You can pg conf for recovery cluster `config/recovery.conf`
* You can add a new workload/init file or may edit the existing one.


```

Examples

Following will run pgbench workload and will archive the wal logs. The a seperate
command can be used to recover the database using the archived wal.

```
./run_test.sh -i --pgbench-builtin simple-update --init-only

./run_test.sh
```