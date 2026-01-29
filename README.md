Testing PostgreSQL WAL recovery performance under different workloads. (wal_pipeline patch should be applied before using this)

```
Usage:
  ./run_test.sh							Run recoveries using existing backup + WAL
  ./run_test.sh -i						Initialize the clusters before running recoveries.
  ./run_test.sh -i --workload	<path> 	Run recoveries with custom workload file

Optional flags:
  --init-only					Only init the clusters for recoveries.
  --workload PATH      			Use custom pgbench script for cerating workload (applies only with -i)
  --pgbench-builtin NAME		Use biultin (i.e. simple-update) pgbench script for creating a workload (applies only with -i)
  --pipeline-on        			run pipeline=on (runs recovery once)
  --pipeline-off       			run pipeline=off (runs recovery once)
  --test-dir DIR       			Override default test dir.
  --pg-bin DIR       			Override default postgresql bins
  --help               			Show help

Examples:
  ./run_test.sh -i
  ./run_test.sh -i --workload sql/heavy_updates.sql
  ./run_test.sh --pipeline-on
  ./run_test.sh --pg-bin "/home/user/pg18/bin" --test-dir "/tmp/wal-test"


Defaults:

    WORKLOAD="sql/workloads/updates.sql"
    PGHOME="/usr/lib/postgresql/18/bin"
    TEST_DIR="/tmp/pg_waltest"

Configurable:

* You can change the defaults from `config/env.conf`
* You can pg conf for primary cluster `config/primary.conf`
* You can pg conf for recovery cluster `config/recovery.conf`
* You can add a new workload/init file or may edit the existing one.
```