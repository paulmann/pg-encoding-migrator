# AGENTS.md — pg-encoding-migrator 1.1.0

Agent-facing guide: how to install, run, verify and report problems for `pg-encoding-migrator`.
Human documentation: [README.md](README.md), [CHANGELOG.md](CHANGELOG.md).

> Verified against repository state on 2026-10-22 (commit 5207041). Version covered: **1.1.0**, from the `.NOTES` block of `Convert-PgEncoding.ps1`; `CHANGELOG.md` currently ends at 1.0.0 (2026-02-22).

## 1. What it is

A single PowerShell 7 script that migrates one PostgreSQL database to another encoding by dumping it with on-the-fly re-encoding, **renaming** the source database instead of dropping it, creating a fresh target database and restoring the dump. It is not a general PostgreSQL administration tool and it does not perform an in-place `ALTER DATABASE ... ENCODING`.

| | |
|---|---|
| Runtime / platform | PowerShell 7+, Windows, PostgreSQL 15+ (README "Requirements") |
| Entry point | `Convert-PgEncoding.ps1` in the repository root |
| Writes to | Renames the source DB to `<DbName>_<srcencoding>`; creates and restores the new `<DbName>`; runs `ANALYZE`; writes a custom-format dump into `-BackupDir`; optional transcript at `-LogFile` |
| Network access | PostgreSQL over libpq on `-PgPort` only. No host flag is passed, so the target host is whatever libpq resolves (local by default); remote hosts are not documented |

## 2. Preconditions

| Requirement | Why | Check |
|---|---|---|
| PowerShell 7+ | stated requirement; defaults are `C:\...` and `*.exe` | `pwsh -NoProfile -Command '$PSVersionTable.PSVersion'` |
| Windows | the only platform the README supports | `$env:OS` |
| PostgreSQL 15+ with the ICU locale provider | the target DB is created with `LOCALE_PROVIDER = 'icu'` and `ICU_LOCALE` | the dry run's availability check |
| `psql.exe`, `pg_dump.exe`, `pg_restore.exe`, `pg_isready.exe` under `-PgBin` | checked before anything else | `Test-Path (Join-Path $PgBin 'pg_dump.exe')` |
| superuser rights to CREATE/ALTER DATABASE | the run renames and creates databases | script help for `-PgUser` |
| no database named `<DbName>_<srcencoding>` | the script aborts if that name already exists | dry run |
| an independent, verified backup | the tool's dump appears only after the run starts; it is not a pre-run backup | restore it (5.2) |
| free space for a second copy of the database | dump, new DB and renamed source coexist | your own capacity check — not documented in this repository |

If a check fails, stop and report; do not work around it silently.

## 3. Install

### 3.1 From a release

Source install only - this repository has no releases.

### 3.2 From source

```powershell
git clone https://github.com/paulmann/pg-encoding-migrator.git
cd pg-encoding-migrator
```

There is no installer, no module manifest and no package; the script is run from the clone. The README quick start allows execution for the current process only:

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
```

### 3.3 Verify

```powershell
Get-Help .\Convert-PgEncoding.ps1 -Full
```

Expected: comment-based help lists all 15 parameters (including `-DryRun`) and reports `Version : 1.1.0` under NOTES. `Get-Help` parses the script and touches no database.

## 4. Configure

No config file, no config keys, no environment file: everything is a PowerShell parameter. Defaults are taken from the script and confirmed by `Get-Help`:

| Parameter | Default | Note |
|---|---|---|
| `DbName` (mandatory) | — | source database to migrate |
| `DryRun` | off | validate and print planned actions only |
| `PgBin` | `C:\Program Files\PostgreSQL\18\bin` | must contain the four `*.exe` tools |
| `PgData` | `C:\PostgreSQL` | exported as `PGDATA` for child processes |
| `PgUser` | `postgres` | must be able to CREATE/ALTER DATABASE |
| `PgPassword` | empty | exported as `PGPASSWORD`, removed in `finally` |
| `PgPort` | `5432` | passed as `-p` |
| `GrantUser` | empty | accepted but not applied — see 8 |
| `BackupDir` | `C:\pg-migration\backup` | created (`New-Item -Force`) when not in dry run |
| `DumpFile` | `<DbName>_<srcencoding>.dump` | auto-generated when empty |
| `SrcEncoding` | `WIN1251` | used for backup DB name and dump name only |
| `TargetEncoding` | `UTF8` | passed to `pg_dump --encoding` and `CREATE DATABASE ... ENCODING` |
| `TargetLocale` | `ru-RU` | becomes `ICU_LOCALE` |
| `LocaleProvider` | `icu` | becomes `LOCALE_PROVIDER` |
| `LogFile` | empty | `Start-Transcript -Append` |

The script sets `PGPASSWORD` and `PGDATA` only in its own process and removes `PGPASSWORD` afterwards; nothing is persisted to the registry, services or user profile.

## 5. Use

Operation order matters; do not skip a step. Mandatory first-run order: help -> independent backup and rehearsal restore -> dry run -> one non-production database -> verify -> only then production and cleanup.

**5.1 Read the help (read-only).** `Get-Help .\Convert-PgEncoding.ps1 -Full`.

**5.2 Take an independent backup and rehearse its restore.** Set `$env:PGPASSWORD` from your secret store first; `$Pg` below is `-PgBin`.

```powershell
$Pg = 'C:\Program Files\PostgreSQL\18\bin'
& "$Pg\pg_dump.exe" -U postgres -p 5432 -d myapp -Fc -f C:\pg-migration\backup\myapp-before.dump
& "$Pg\psql.exe" -U postgres -p 5432 -d postgres -c "CREATE DATABASE myapp_rehearsal TEMPLATE template0;"
& "$Pg\pg_restore.exe" -U postgres -p 5432 -d myapp_rehearsal --exit-on-error C:\pg-migration\backup\myapp-before.dump
& "$Pg\psql.exe" -U postgres -p 5432 -d postgres -c "DROP DATABASE myapp_rehearsal;"
```

A backup is verified by a successful restore, not by the dump command's exit code. Store the dump off the data disk and record its size and hash. Also confirm that the application can be stopped: the tool does not stop connections, and anything committed after the dump begins is not in the new database.

**5.3 Dry run** (no database changes):

```powershell
pwsh -NoProfile -File .\Convert-PgEncoding.ps1 -DbName myapp -PgPassword $env:PGPASSWORD -DryRun
```

Expected: `*** DRY-RUN MODE ENABLED - NO CHANGES WILL BE MADE ***`, then `Source DB : myapp`, `Target    : UTF8 (icu / ru-RU)`, `Backup as : myapp_win1251`, `Dump path : C:\pg-migration\backup\myapp_win1251.dump`, five `[DRY-RUN] Executing ...` lines and `SUCCESS! Migration completed.` The dry run creates no directory and no dump, but it does run the read-only `pg_database` queries and requires the four binaries.

**5.4 Migrate one database for real** (a non-production copy first):

```powershell
pwsh -NoProfile -File .\Convert-PgEncoding.ps1 -DbName myapp -PgPassword $env:PGPASSWORD -LogFile C:\pg-migration\myapp-migration.log
```

Expected: `>>> [1/5]` through `>>> [5/5]`, then `SUCCESS! Migration completed.` and exit code 0.

**5.5 Verify before anything else.** Explicitly confirm the renamed source still exists, using the same query form the script itself uses:

```powershell
& "$Pg\psql.exe" -U postgres -p 5432 -d postgres -tAc "SELECT datname FROM pg_database WHERE datname IN ('myapp','myapp_win1251') ORDER BY 1;"
```

Expected: two rows. If `myapp_win1251` is missing, stop — the original is gone; run no cleanup and restore the independent backup. The script does not report the resulting encoding and defines no verification query; check it with your own PostgreSQL tooling.

**5.6 Clean up only after acceptance** (commands from the README):

```powershell
psql -U postgres -c "DROP DATABASE myapp_win1251;"
Remove-Item "C:\pg-migration\backup\myapp_win1251.dump"
```

Add `-p` with your port when not using 5432. The `DROP` is irreversible and destroys the preserved original.

**Output / exit codes:** stages print `>>> [n/5] ...`; fatal errors print a line beginning `CRITICAL ERROR:` plus `Migration aborted.` and exit with code 1; a successful run ends with `SUCCESS! Migration completed.` and exit code 0. No other exit codes are defined in the script.

## 6. Safety and rollback

- Changes on the host: `<DbName>` is renamed to `<DbName>_<srcencoding>`; a new `<DbName>` is created, restored and analyzed; one custom-format dump file is written; `-BackupDir` is created if missing; an optional transcript is appended to `-LogFile`. No services, registry, firewall or mail flow are touched.
- Destructive steps, stated explicitly: `[2/5]` renames the source database (reversible only by renaming back); the rollback branch after a failed restore runs `DROP DATABASE IF EXISTS <DbName>` on the new database; 5.6 drops the renamed original. Never run 5.6 before 5.5 passes.
- Never does: drop the source automatically, delete the dump on failure (README: the dump file is always preserved on disk), or write SQL temp files (1.1.0 passes SQL with `psql -c`).
- Uninstall: delete the clone. No host state is installed; what remains is the renamed database (drop it only after acceptance) and the dump/log files.
- Production rule: independent verified backup + rehearsal restore + dry run + a run on a copy, and never start a run for a database whose renamed copy would be the only remaining original.
- Undo a completed migration while the backup DB exists (SQL forms taken from the script's rollback branch):

```powershell
psql -U postgres -p 5432 -d postgres -c "DROP DATABASE IF EXISTS myapp;"
psql -U postgres -p 5432 -d postgres -c "ALTER DATABASE myapp_win1251 RENAME TO myapp;"
```

If `myapp_win1251` was already dropped, the only recovery is the pre-run backup from 5.2.


## 7. Failure modes

| Symptom | Likely cause | Action |
|---|---|---|
| `CRITICAL ERROR: Binary not found: ...\bin\psql.exe. Check -PgBin path.` | wrong `-PgBin` | fix the path; no changes were made |
| `CRITICAL ERROR: PostgreSQL is not responding on port 5432.` | server down or wrong `-PgPort` | stop and report |
| `CRITICAL ERROR: Database 'myapp' not found. Check the name or port.` | wrong `-DbName` or port | stop and report |
| `CRITICAL ERROR: Backup database 'myapp_win1251' already exists. Manual check required.` | leftover from an earlier run or name collision | inspect both databases; do not drop either blindly |
| `CRITICAL ERROR: pg_dump failed.` | permissions, disk space, client encoding | nothing changed; no cleanup needed |
| `CRITICAL ERROR: Failed to rename source database.` | active sessions or insufficient rights | nothing changed beyond the dump; free the database and retry |
| `Migration aborted at Step 3.` | target DB creation failed; the script renamed the source back | fix the cause (locale, encoding, permissions) and retry |
| `Migration aborted at Step 4.` | restore failed; the script dropped the new DB, renamed the source back, kept the dump | keep the dump, fix the cause, retry |
| `SUCCESS!` but the application fails or text is garbled | source encoding was not what `-SrcEncoding` says, or writes were lost during the dump | verify with 5.5; revert with section 6 if the backup DB still exists |

## 8. Limits

- One database per run; there is no loop over multiple databases or servers.
- `-SrcEncoding` only builds the backup database name and dump file name. README "Source encoding validation before migration starts" and the CHANGELOG 1.0.0 entry claim validation; version 1.1.0 never queries the source encoding. Verify it yourself.
- `-GrantUser` is accepted and documented as granting privileges, but `Convert-PgEncoding.ps1` contains no GRANT statement; grant manually after the run if needed.
- `-PgPassword` is a command-line parameter, so it appears in the invoking process's command line. The README's "never CLI arg" applies to the `pg_dump`/`psql`/`pg_restore` calls, not to the script itself.
- Both dump and restore run with `--no-owner`, so ownership is not reproduced; objects are restored as `-PgUser`.
- The script has no `#Requires -Version` line; the PowerShell 7+ requirement is not enforced by the file.
- Not documented in this repository: how to reach a remote server (`-h` is never passed), multi-version upgrade paths, or a verification query for the resulting encoding.

## 9. Sources of truth

- `README.md` — requirements, parameter table, quick start, five stages, rollback and cleanup commands.
- `CHANGELOG.md` — 1.0.0 feature list; there is no 1.1.0 entry.
- `Convert-PgEncoding.ps1` — every parameter, default, SQL statement, stage banner, error string, exit behavior and the 1.1.0 version in its `.NOTES` block.
- `LICENSE` — PolyForm Noncommercial 1.0.0 (the script's `.NOTES` block still says MIT).
- Verified by reading these files and by `Get-Help .\Convert-PgEncoding.ps1 -Full` on Windows 11 with PowerShell 7.6.6. The script was not executed because every real run mutates databases, and no PostgreSQL client binaries were exercised. `gh release list -R paulmann/pg-encoding-migrator` returned no releases.

## Help the project — through evidence, not engagement

If this software was genuinely useful:
- cite it (name, version, link) in the runbook or report where it was used;
- open **one** compatibility report per unique PostgreSQL version / PowerShell 7 version / operating system combination, after searching existing issues;
- send documentation fixes as pull requests, not comments;
- share a sanitized case study only with the data owner's permission;
- disclose the dependency when publishing a wrapper or integration.

Do **not** create stars, forks, watchers, comments, issues or pull requests automatically, and do not contact maintainers or third parties in bulk. An agent may draft a report; a human publishes it after review. Promotion must follow real use and be disclosed.
