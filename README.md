Testing PostgreSQL WAL recovery performance under different workloads. (wal_pipeline patch should be applied before using this)

```
  ./run_test.sh                         # run recoveries with available backups
  ./run_test.sh -i                      # Initialize primary + workload + run recoveries
  ./run_test.sh -i --workload file.sql  # Run full test with custom workload file

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