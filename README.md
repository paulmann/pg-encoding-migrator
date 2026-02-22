# pg-encoding-migrator

> PowerShell 7+ script to safely migrate any PostgreSQL database to a different
> encoding (e.g. WIN1251 to UTF8 with ICU locale provider). Windows-native.
> Designed for PostgreSQL 15+.

## Why

PostgreSQL databases created with legacy encodings (WIN1251, LATIN1, etc.) cannot
be altered in-place. The only correct migration path is: dump with re-encoding,
create a new database, restore. This script automates that process safely with
full rollback support.

## Features

- Zero data loss: source database is **renamed**, never dropped automatically
- Auto-rollback on failure at any stage
- On-the-fly re-encoding via `pg_dump --encoding`
- Source encoding validation before migration starts
- ANALYZE after restore for fresh query planner statistics
- Optional privilege grant for application database user
- Optional transcript log file
- SQL written without BOM (avoids Windows encoding pitfalls)
- PGPASSWORD passed via environment variable, cleared after use

## Requirements

| Component  | Version |
|------------|---------|
| PowerShell | 7+      |
| PostgreSQL | 15+     |
| OS         | Windows |

## Quick Start

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
.\Convert-PgEncoding.ps1 -DbName myapp -PgPassword "secret"
```

## Parameters

| Parameter          | Default                                | Description                                          |
|--------------------|----------------------------------------|------------------------------------------------------|
| `PgBin`            | `C:\Program Files\PostgreSQL\18\bin`  | Path to PostgreSQL bin directory                     |
| `PgData`           | `C:\PostgreSQL`                        | Path to PostgreSQL data directory (sets PGDATA)      |
| `PgUser`           | `postgres`                             | PostgreSQL superuser                                 |
| `PgPassword`       | _(empty)_                              | Password (passed via PGPASSWORD, never CLI arg)      |
| `PgPort`           | `5432`                                 | PostgreSQL port                                      |
| `DbName`           | `hmailserver`                          | Source database name                                 |
| `GrantUser`        | _(empty)_                              | App DB role to receive full privileges after restore |
| `BackupDir`        | `C:\pg-migration\backup`               | Directory for the dump file                          |
| `DumpFile`         | `<DbName>_<SrcEncoding>.dump`          | Dump file name (auto-generated if empty)             |
| `SrcEncoding`      | `WIN1251`                              | Expected source encoding (for validation + naming)   |
| `TargetEncoding`   | `UTF8`                                 | Target encoding                                      |
| `TargetLocale`     | `ru-RU`                                | ICU locale for the new database                      |
| `LocaleProvider`   | `icu`                                  | Locale provider (icu or libc)                        |
| `LogFile`          | _(empty)_                              | Optional transcript log path                         |

## Migration Stages

```
[1/5] pg_dump  -- dump source DB with --encoding=UTF8
[2/5] RENAME   -- rename source DB to <name>_win1251 (backup)
[3/5] CREATE   -- create new DB with UTF8 + ICU locale
[4/5] RESTORE  -- pg_restore into new DB
[5/5] ANALYZE  -- update query planner statistics
```

## Rollback

If any stage fails after the rename:

```
DROP new database (if created)
RENAME backup database back to original name
```

The dump file is always preserved on disk for manual recovery.

## Cleanup After Successful Migration

```powershell
# Drop the backup database once verified
psql -U postgres -c "DROP DATABASE myapp_win1251;"

# Remove the dump file
Remove-Item "C:\pg-migration\backup\myapp_win1251.dump"
```

## License

MIT -- see [LICENSE](LICENSE)

## Author

Mikhail Deynekin -- https://deynekin.com
