# Icinga2 plugins - BareOS

Source: https://github.com/NETWAYS/check_bareos

## Local divergence

Our copy is upstream 1.0.x (imported 2022-03-07) and stays **Python 2**: the Bareos
director runs CentOS 7, where `psycopg2` exists only for Python 2. Upstream v2.x requires
Python 3 + psycopg2 and cannot run there, so useful changes are backported instead.

Local version 1.0.3 backports from upstream v2.1.1:

- `--password-file` and `CHECK_BAREOS_DATABASE_PASSWORD` - keep the password out of argv
  and `ps`. `-p/--password` still works but is insecure.
- `-P/--port` for the database port.
- `MySQLdb` imported only when `-d mysql` is used, so psql-only hosts need no MySQL module.
- `--version` reports the real version (upstream 1.0.x reported 1.0.0 with a 1.0.2 header).

## Known blind spot

No subcommand answers "how old is the last successful backup for client X", and none checks
that the director is alive - `status --failedBackups` counts *failed* jobs, so a dead
director (zero jobs, zero failures) reports `OK`. This is inherited from upstream and is
still true in v2.1.1. It kept 21 days without backups (2026-10-21 .. 2026-11-11) invisible.
Director liveness belongs in a separate process/port check, backup absence in a separate
per-client check.
