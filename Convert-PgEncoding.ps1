<#
.SYNOPSIS
    Migrates a PostgreSQL database from one encoding to another (e.g. WIN1251 to UTF8/ICU).

.DESCRIPTION
    Performs a safe, rollback-capable encoding migration in four stages:
      1. Dumps the source database with on-the-fly re-encoding via pg_dump.
      2. Renames the source database as a backup (e.g. mydb_win1251).
      3. Creates a new database with the target encoding and ICU locale.
      4. Restores the dump into the new database.

    If any stage fails, the script automatically rolls back by renaming the
    backup database to its original name. The source database is never dropped
    automatically \u2014 cleanup is left to the operator after verification.

.PARAMETER PgBin
    Path to the PostgreSQL bin directory. Default: C:\\Program Files\\PostgreSQL\\18\\bin

.PARAMETER PgData
    Path to the PostgreSQL data directory (sets PGDATA). Default: C:\\PostgreSQL

.PARAMETER PgUser
    PostgreSQL superuser used to run all operations. Default: postgres

.PARAMETER PgPassword
    Password for PgUser. Passed via PGPASSWORD env variable (never as a CLI argument).

.PARAMETER PgPort
    PostgreSQL port. Default: 5432

.PARAMETER DbName
    Name of the source database to migrate. Default: hmailserver

.PARAMETER GrantUser
    Optional: an additional PostgreSQL role to receive full privileges on the
    migrated database (e.g. the application's DB user). Skipped if empty or
    equal to PgUser.

.PARAMETER BackupDir
    Directory where the pg_dump file will be stored. Default: C:\\pg-migration\\backup

.PARAMETER DumpFile
    Name of the dump file. Default: <DbName>_<SrcEncoding>.dump (auto-generated)

.PARAMETER SrcEncoding
    Expected encoding of the source database. Used for validation and backup naming.
    Default: WIN1251

.PARAMETER TargetEncoding
    Target encoding for the new database. Default: UTF8

.PARAMETER TargetLocale
    ICU locale for the new database. Default: ru-RU

.PARAMETER LocaleProvider
    Locale provider for the new database (icu or libc). Default: icu

.PARAMETER LogFile
    Optional path to a transcript log file. If empty, logging is disabled.

.EXAMPLE
    .\\Convert-PgEncoding.ps1 -DbName myapp -PgPassword \"s3cr3t\"

.EXAMPLE
    .\\Convert-PgEncoding.ps1 `
        -DbName        hmailserver `
        -PgPassword    \"s3cr3t\" `
        -GrantUser     hmailuser `
        -BackupDir     \"D:\\backups\" `
        -LogFile       \"D:\\backups\\migration.log\"

.NOTES
    Author  : Mikhail Deynekin (https://deynekin.com)
    Email   : mid1977@gmail.com
    License : MIT
    Repo    : https://github.com/paulmann/pg-encoding-migrator
    Requires: PowerShell 7+, PostgreSQL 15+ client tools (pg_dump, psql, pg_restore, pg_isready)
    Run as  : Administrator
    Launch  : Set-ExecutionPolicy Bypass -Scope Process -Force; .\\Convert-PgEncoding.ps1
#>

[CmdletBinding()]
param(
    [string]\$PgBin          = \"C:\\Program Files\\PostgreSQL\\18\\bin\",
    [string]\$PgData         = \"C:\\PostgreSQL\",
    [string]\$PgUser         = \"postgres\",
    [string]\$PgPassword     = \"\",
    [string]\$PgPort         = \"5432\",
    [string]\$DbName         = \"hmailserver\",
    [string]\$GrantUser      = \"\",
    [string]\$BackupDir      = \"C:\\pg-migration\\backup\",
    [string]\$DumpFile       = \"\",
    [string]\$SrcEncoding    = \"WIN1251\",
    [string]\$TargetEncoding = \"UTF8\",
    [string]\$TargetLocale   = \"ru-RU\",
    [string]\$LocaleProvider = \"icu\",
    [string]\$LogFile        = \"\"
)

# ---------------------------------------------------------------------------
# Derived paths
# ---------------------------------------------------------------------------
\$psqlExe      = Join-Path \$PgBin \"psql.exe\"
\$pgDumpExe    = Join-Path \$PgBin \"pg_dump.exe\"
\$pgRestoreExe = Join-Path \$PgBin \"pg_restore.exe\"
\$pgIsReadyExe = Join-Path \$PgBin \"pg_isready.exe\"

# Auto-generate dump file name if not specified
if (-not \$DumpFile) {
    \$DumpFile = \"\$(\$DbName)_\$(\$SrcEncoding.ToLower()).dump\"
}
\$DumpPath  = Join-Path \$BackupDir \$DumpFile
\$OldDbName = \"\$(\$DbName)_\$(\$SrcEncoding.ToLower())\"

# ---------------------------------------------------------------------------
# Environment setup
# ---------------------------------------------------------------------------
if (\$PgPassword) { \$env:PGPASSWORD = \$PgPassword }
if (\$PgData)     { \$env:PGDATA     = \$PgData     }

\$transcriptStarted = \$false
if (\$LogFile) {
    try {
        Start-Transcript -Path \$LogFile -Append -ErrorAction Stop
        \$transcriptStarted = \$true
        Write-Host \"Transcript logging enabled: \$LogFile\"
    } catch {
        Write-Warning \"Could not start transcript: \$_\"
    }
}

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

function Test-PgTools {
    foreach (\$exe in @(\$psqlExe, \$pgDumpExe, \$pgRestoreExe, \$pgIsReadyExe)) {
        if (-not (Test-Path \$exe)) {
            throw \"Binary not found: \$exe \u2014 check -PgBin parameter.\"
        }
    }
}

function Test-DbExists {
    param([string]\$Database)
    \$result = & \$psqlExe -U \$PgUser -p \$PgPort -d postgres -tAc `
        \"SELECT 1 FROM pg_database WHERE datname='\$Database';\" 2>\$null
    return (\$result -eq '1')
}

function Get-DbEncoding {
    param([string]\$Database)
    \$enc = & \$psqlExe -U \$PgUser -p \$PgPort -d postgres -tAc `
        \"SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname='\$Database';\" 2>\$null
    return (\$enc | Where-Object { \$_ -ne '' } | Select-Object -First 1)?.Trim()
}

function Remove-ActiveConnections {
    param([string]\$Database)
    Write-Host \"  Terminating active connections to: \$Database ...\" -ForegroundColor DarkYellow
    & \$psqlExe -U \$PgUser -p \$PgPort -d postgres -c `
        \"SELECT pg_terminate_backend(pid)
         FROM pg_stat_activity
         WHERE datname = '\$Database'
           AND pid <> pg_backend_pid();\" 2>\$null | Out-Null
}

function Invoke-Rollback {
    Write-Host \"  Rolling back: renaming backup database to original name ...\" -ForegroundColor Yellow
    Remove-ActiveConnections -Database \$OldDbName
    & \$psqlExe -U \$PgUser -p \$PgPort -d postgres -c `
        \"ALTER DATABASE \$OldDbName RENAME TO \$DbName;\" 2>\$null
    if (\$LASTEXITCODE -ne 0) {
        Write-Host \"  CRITICAL: Failed to restore original database name. Manual intervention required!\" `
            -ForegroundColor Red
    } else {
        Write-Host \"  Rollback successful. Database '\$DbName' restored.\" -ForegroundColor Green
    }
}

function Grant-DbPrivileges {
    param([string]\$Role)
    Write-Host \">>> Granting privileges to role '\$Role' ...\" -ForegroundColor Cyan
    \$roleExists = & \$psqlExe -U \$PgUser -p \$PgPort -d postgres -tAc `
        \"SELECT 1 FROM pg_roles WHERE rolname='\$Role';\"
    if (\$roleExists -eq '1') {
        & \$psqlExe -U \$PgUser -p \$PgPort -d \$DbName -c \"GRANT ALL PRIVILEGES ON DATABASE \$DbName TO \$Role;\"
        & \$psqlExe -U \$PgUser -p \$PgPort -d \$DbName -c \"GRANT ALL ON SCHEMA public TO \$Role;\"
        & \$psqlExe -U \$PgUser -p \$PgPort -d \$DbName -c \"GRANT ALL ON ALL TABLES IN SCHEMA public TO \$Role;\"
        & \$psqlExe -U \$PgUser -p \$PgPort -d \$DbName -c \"GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO \$Role;\"
        Write-Host \"  Privileges granted.\" -ForegroundColor Green
    } else {
        Write-Host \"  Role '\$Role' does not exist. GRANT skipped.\" -ForegroundColor Yellow
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Clear-Host
Write-Host \"================================================================\" -ForegroundColor Magenta
Write-Host \"  pg-encoding-migrator \u2014 PostgreSQL Encoding Migration Tool\"     -ForegroundColor Magenta
Write-Host \"  Author : Mikhail Deynekin (https://deynekin.com)\"              -ForegroundColor Magenta
Write-Host \"================================================================\" -ForegroundColor Magenta
Write-Host \"\"

# --- Pre-flight checks ---
Test-PgTools

Write-Host \">>> Checking PostgreSQL availability ...\"
& \$pgIsReadyExe -U \$PgUser -p \$PgPort -d postgres
if (\$LASTEXITCODE -ne 0) {
    throw \"PostgreSQL is not responding. Make sure the server is running.\"
}
Write-Host \"  PostgreSQL is available.\" -ForegroundColor Green

if (-not (Test-DbExists -Database \$DbName)) {
    throw \"Source database '\$DbName' not found. Check the -DbName parameter.\"
}
if (Test-DbExists -Database \$OldDbName) {
    throw \"Backup database '\$OldDbName' already exists. A previous migration may have run. Verify manually.\"
}

\$actualEncoding = Get-DbEncoding -Database \$DbName
if (\$actualEncoding -ne \$SrcEncoding) {
    Write-Host \"\"
    Write-Host \"WARNING: Source database encoding is '\$actualEncoding', expected '\$SrcEncoding'.\" `
        -ForegroundColor Yellow
    Write-Host \"         Proceeding may result in incorrect data conversion.\" -ForegroundColor Yellow
    \$confirm = Read-Host \"Continue anyway? (y/N)\"
    if (\$confirm -notin @('y', 'Y')) {
        Write-Host \"Migration cancelled by user.\" -ForegroundColor Red
        exit 0
    }
}

Write-Host \"\"
Write-Host \"  Source database : \$DbName (encoding: \$actualEncoding)\"         -ForegroundColor Cyan
Write-Host \"  Target database : \$DbName (\$TargetEncoding / \$LocaleProvider / \$TargetLocale)\" `
                                                                              -ForegroundColor Cyan
Write-Host \"  Backup name     : \$OldDbName\"                                   -ForegroundColor Cyan
Write-Host \"  Dump file       : \$DumpPath\"                                    -ForegroundColor Cyan
Write-Host \"\"

# --- Step 1: Create backup directory ---
if (-not (Test-Path \$BackupDir)) {
    New-Item -Path \$BackupDir -ItemType Directory -Force | Out-Null
}

# --- Step 2: Dump with re-encoding ---
Write-Host \">>> [1/5] Dumping '\$DbName' with re-encoding (\$SrcEncoding -> \$TargetEncoding) ...\" `
    -ForegroundColor Cyan
& \$pgDumpExe `
    -U \$PgUser `
    -p \$PgPort `
    -d \$DbName `
    -Fc `
    --encoding=\$TargetEncoding `
    --no-owner `
    --no-privileges `
    -f \$DumpPath

if (\$LASTEXITCODE -ne 0) { throw \"pg_dump failed. Check PostgreSQL logs.\" }
\$dumpSizeMB = [math]::Round((Get-Item \$DumpPath).Length / 1MB, 2)
Write-Host \"  Dump saved: \$DumpPath (\$dumpSizeMB MB)\" -ForegroundColor Green

# --- Step 3: Rename source database ---
Write-Host \">>> [2/5] Renaming '\$DbName' -> '\$OldDbName' ...\" -ForegroundColor Cyan
Remove-ActiveConnections -Database \$DbName
& \$psqlExe -U \$PgUser -p \$PgPort -d postgres -c `
    \"ALTER DATABASE \$DbName RENAME TO \$OldDbName;\"
if (\$LASTEXITCODE -ne 0) { throw \"Failed to rename database. Check for remaining active connections.\" }
Write-Host \"  Renamed successfully.\" -ForegroundColor Green

# --- Step 4: Create new UTF8/ICU database (SQL via temp file to avoid BOM/encoding issues) ---
Write-Host \">>> [3/5] Creating '\$DbName' (\$TargetEncoding / \$LocaleProvider / \$TargetLocale) ...\" `
    -ForegroundColor Cyan
\$sqlFile    = Join-Path \$env:TEMP \"pg_create_db_\$DbName.sql\"
\$sqlContent = @\"
CREATE DATABASE \$DbName
    WITH
    OWNER            = \$PgUser
    ENCODING         = '\$TargetEncoding'
    LOCALE_PROVIDER  = '\$LocaleProvider'
    ICU_LOCALE       = '\$TargetLocale'
    TEMPLATE         = template0
    CONNECTION LIMIT = -1
    IS_TEMPLATE      = False;
\"@
[System.IO.File]::WriteAllText(\$sqlFile, \$sqlContent, [System.Text.UTF8Encoding]::new(\$false))

& \$psqlExe -U \$PgUser -p \$PgPort -d postgres -f \$sqlFile
Remove-Item \$sqlFile -Force -ErrorAction SilentlyContinue

if (\$LASTEXITCODE -ne 0) {
    Write-Host \"Failed to create target database. Rolling back ...\" -ForegroundColor Red
    Invoke-Rollback
    throw \"Migration aborted at Step 3.\"
}
Write-Host \"  Database created.\" -ForegroundColor Green

# --- Step 5: Restore dump ---
Write-Host \">>> [4/5] Restoring data into '\$DbName' ...\" -ForegroundColor Cyan
& \$pgRestoreExe `
    -U \$PgUser `
    -p \$PgPort `
    -d \$DbName `
    --no-owner `
    --no-privileges `
    --exit-on-error `
    \$DumpPath

if (\$LASTEXITCODE -ne 0) {
    Write-Host \"Restore failed. Rolling back ...\" -ForegroundColor Red
    Remove-ActiveConnections -Database \$DbName
    & \$psqlExe -U \$PgUser -p \$PgPort -d postgres -c \"DROP DATABASE IF EXISTS \$DbName;\"
    Invoke-Rollback
    throw \"Migration aborted at Step 4. Original database has been restored.\"
}
Write-Host \"  Data restored successfully.\" -ForegroundColor Green

# --- Step 6: Update statistics ---
Write-Host \">>> [5/5] Running ANALYZE on '\$DbName' ...\" -ForegroundColor Cyan
& \$psqlExe -U \$PgUser -p \$PgPort -d \$DbName -c \"ANALYZE;\"
Write-Host \"  Statistics updated.\" -ForegroundColor Green

# --- Optional: grant privileges ---
if (\$GrantUser -and \$GrantUser -ne \$PgUser) {
    Grant-DbPrivileges -Role \$GrantUser
}

# --- Cleanup ---
Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
if (\$transcriptStarted) { Stop-Transcript }

# --- Summary ---
Write-Host \"\"
Write-Host \"================================================================\" -ForegroundColor Green
Write-Host \"  Migration completed successfully!\"                              -ForegroundColor Green
Write-Host \"================================================================\" -ForegroundColor Green
Write-Host \"  Original database (backed up) : \$OldDbName (\$SrcEncoding)\"    -ForegroundColor Yellow
Write-Host \"  Migrated database             : \$DbName (\$TargetEncoding/ICU)\" -ForegroundColor Yellow
Write-Host \"  Dump file                     : \$DumpPath\"                     -ForegroundColor Yellow
Write-Host \"\"
Write-Host \"  Next steps:\"
Write-Host \"    1. Verify your application connects and works correctly\"
Write-Host \"    2. Run a functional smoke test (read + write)\"
Write-Host \"    3. Once confirmed \u2014 drop the backup database:\"
Write-Host \"       psql -U \$PgUser -p \$PgPort -c `\"DROP DATABASE \$OldDbName;`\"\"
Write-Host \"    4. Optionally remove the dump file: \$DumpPath\"
Write-Host \"================================================================\" -ForegroundColor Green
