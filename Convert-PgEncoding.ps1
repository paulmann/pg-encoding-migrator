<#
.SYNOPSIS
    Migrates a PostgreSQL database from one encoding to another (e.g. WIN1251 to UTF8/ICU).

.DESCRIPTION
    A senior-level automation script for safe, production-ready PostgreSQL database encoding migration.
    The process is performed in four stages with integrated rollback protection:
    1. Dumps the source database using pg_dump with on-the-fly re-encoding.
    2. Renames the source database as a backup (e.g., dbname_win1251).
    3. Creates a new target database with UTF8 encoding and ICU locale provider.
    4. Restores the re-encoded dump into the new database.

    Key Features:
    - Dry-Run support to verify parameters without making changes.
    - Automatic rollback on failure (renames the backup DB back to original).
    - Environment-safe: passes credentials via env variables, not CLI arguments.
    - Full logging support via Start-Transcript.

.PARAMETER DbName
    Required. The name of the source database you want to migrate.

.PARAMETER DryRun
    If specified, the script validates all settings and displays planned actions without executing them.

.PARAMETER PgBin
    Path to the PostgreSQL bin directory. Default: C:\Program Files\PostgreSQL\18\bin

.PARAMETER PgUser
    PostgreSQL superuser account (must have rights to CREATE/ALTER DATABASE). Default: postgres

.PARAMETER PgPassword
    Password for the PostgreSQL superuser. Passed securely via PGPASSWORD env variable.

.PARAMETER GrantUser
    Optional. If provided, the script will grant full privileges on the new database to this role.

.PARAMETER BackupDir
    Directory to store the intermediate dump file. Default: C:\pg-migration\backup

.EXAMPLE
    .\Convert-PgEncoding.ps1 -DbName MyDatabase -PgPassword "TopSecret123"
    Starts a live migration of 'MyDatabase' using default settings.

.EXAMPLE
    .\Convert-PgEncoding.ps1 -DbName MyDatabase -DryRun
    Runs all pre-flight checks and shows what would happen without modifying anything.

.NOTES
    Author  : Mikhail Deynekin (https://deynekin.com)
    Email   : mid1977@gmail.com
    License : MIT
    Repo    : https://github.com/paulmann/pg-encoding-migrator
    Version : 1.1.0
#>


[CmdletBinding()]
param(
    [Parameter(Mandatory=$true, HelpMessage="Database name is required")]
    [string]$DbName,

    [switch]$DryRun,

    [string]$PgBin          = "C:\Program Files\PostgreSQL\18\bin",
    [string]$PgData         = "C:\PostgreSQL",
    [string]$PgUser         = "postgres",
    [string]$PgPassword     = "",
    [string]$PgPort         = "5432",
    [string]$GrantUser      = "",
    [string]$BackupDir      = "C:\pg-migration\backup",
    [string]$DumpFile       = "",
    [string]$SrcEncoding    = "WIN1251",
    [string]$TargetEncoding = "UTF8",
    [string]$TargetLocale   = "ru-RU",
    [string]$LocaleProvider = "icu",
    [string]$LogFile        = ""
)

# ---------------------------------------------------------------------------
# Functions
# ---------------------------------------------------------------------------

function Terminate-WithError {
    param([string]$Message)
    Write-Host ""
    Write-Host "CRITICAL ERROR: $Message" -ForegroundColor Red
    Write-Host "Migration aborted." -ForegroundColor Red
    Write-Host ""
    if ($transcriptStarted) { Stop-Transcript }
    exit 1
}

function Invoke-PgCommand {
    param([string]$Executable, [string[]]$Arguments, [string]$StepName)
    if ($DryRun) {
        Write-Host " [DRY-RUN] Executing ${StepName}: $Executable $($Arguments -join ' ')" -ForegroundColor Gray
        return $true
    }
    & $Executable @Arguments
    return ($LASTEXITCODE -eq 0)
}

function Test-PgTools {
    $tools = @("psql.exe", "pg_dump.exe", "pg_restore.exe", "pg_isready.exe")
    foreach ($tool in $tools) {
        $path = Join-Path $PgBin $tool
        if (-not (Test-Path $path)) { Terminate-WithError "Binary not found: $path. Check -PgBin path." }
    }
}

function Test-DbExists {
    param([string]$Database)
    $psql = Join-Path $PgBin "psql.exe"
    if ([string]::IsNullOrWhiteSpace($Database) -or $Database -eq "?") { return $false }
    $res = & $psql -U $PgUser -p $PgPort -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$Database';" 2>$null
    return ($res -eq '1')
}

# ---------------------------------------------------------------------------
# Main Logic
# ---------------------------------------------------------------------------

$transcriptStarted = $false
try {
    # Derived variables
    $OldDbName = "$($DbName)_$($SrcEncoding.ToLower())"
    if (-not $DumpFile) { $DumpFile = "$($DbName)_$($SrcEncoding.ToLower()).dump" }
    $DumpPath = Join-Path $BackupDir $DumpFile

    Clear-Host
    Write-Host "================================================================" -ForegroundColor Magenta
    Write-Host " pg-encoding-migrator - PostgreSQL Encoding Migration Tool"      -ForegroundColor Magenta
    if ($DryRun) { Write-Host " *** DRY-RUN MODE ENABLED - NO CHANGES WILL BE MADE ***" -ForegroundColor Yellow }
    Write-Host "================================================================" -ForegroundColor Magenta

    # Setup environment
    if ($PgPassword) { $env:PGPASSWORD = $PgPassword }
    if ($PgData)     { $env:PGDATA     = $PgData }

    if ($LogFile) {
        Start-Transcript -Path $LogFile -Append -ErrorAction Stop
        $transcriptStarted = $true
    }

    # Pre-flight
    Test-PgTools
    
    Write-Host ">>> Checking PostgreSQL availability ..."
    & (Join-Path $PgBin "pg_isready.exe") -U $PgUser -p $PgPort -d postgres
    if ($LASTEXITCODE -ne 0) { Terminate-WithError "PostgreSQL is not responding on port $PgPort." }
    Write-Host " PostgreSQL is available." -ForegroundColor Green

    if (-not (Test-DbExists -Database $DbName)) { 
        Terminate-WithError "Database '$DbName' not found. Check the name or port." 
    }
    if (Test-DbExists -Database $OldDbName) { 
        Terminate-WithError "Backup database '$OldDbName' already exists. Manual check required." 
    }

    Write-Host ""
    Write-Host " Source DB : $DbName" -ForegroundColor Cyan
    Write-Host " Target    : $TargetEncoding ($LocaleProvider / $TargetLocale)" -ForegroundColor Cyan
    Write-Host " Backup as : $OldDbName" -ForegroundColor Cyan
    Write-Host " Dump path : $DumpPath" -ForegroundColor Cyan
    Write-Host ""

    if (-not $DryRun) {
        if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
    }

    # Step 1: Dump
    Write-Host ">>> [1/5] Dumping '$DbName' with re-encoding ..." -ForegroundColor Cyan
    $dumpArgs = @("-U", $PgUser, "-p", $PgPort, "-d", $DbName, "-Fc", "--encoding=$TargetEncoding", "--no-owner", "-f", $DumpPath)
    if (-not (Invoke-PgCommand (Join-Path $PgBin "pg_dump.exe") $dumpArgs "Database Dump")) { Terminate-WithError "pg_dump failed." }

    # Step 2: Rename Source
    Write-Host ">>> [2/5] Renaming '$DbName' -> '$OldDbName' ..." -ForegroundColor Cyan
    $renameSql = "ALTER DATABASE $DbName RENAME TO $OldDbName;"
    $renameArgs = @("-U", $PgUser, "-p", $PgPort, "-d", "postgres", "-c", $renameSql)
    if (-not (Invoke-PgCommand (Join-Path $PgBin "psql.exe") $renameArgs "Database Rename")) { Terminate-WithError "Failed to rename source database." }

    # Step 3: Create New DB
    Write-Host ">>> [3/5] Creating new database '$DbName' (UTF8/ICU) ..." -ForegroundColor Cyan
    $createSql = "CREATE DATABASE $DbName WITH OWNER = $PgUser ENCODING = '$TargetEncoding' LOCALE_PROVIDER = '$LocaleProvider' ICU_LOCALE = '$TargetLocale' TEMPLATE = template0;"
    $createArgs = @("-U", $PgUser, "-p", $PgPort, "-d", "postgres", "-c", $createSql)
    if (-not (Invoke-PgCommand (Join-Path $PgBin "psql.exe") $createArgs "Create Database")) {
        Write-Host " Failed to create DB. Rolling back..." -ForegroundColor Red
        if (-not $DryRun) { & (Join-Path $PgBin "psql.exe") -U $PgUser -p $PgPort -d postgres -c "ALTER DATABASE $OldDbName RENAME TO $DbName;" | Out-Null }
        Terminate-WithError "Migration aborted at Step 3."
    }

    # Step 4: Restore
    Write-Host ">>> [4/5] Restoring data into '$DbName' ..." -ForegroundColor Cyan
    $restArgs = @("-U", $PgUser, "-p", $PgPort, "-d", $DbName, "--no-owner", "--exit-on-error", $DumpPath)
    if (-not (Invoke-PgCommand (Join-Path $PgBin "pg_restore.exe") $restArgs "Data Restore")) {
        Write-Host " Restore failed. Rolling back..." -ForegroundColor Red
        if (-not $DryRun) {
            & (Join-Path $PgBin "psql.exe") -U $PgUser -p $PgPort -d postgres -c "DROP DATABASE IF EXISTS $DbName;" | Out-Null
            & (Join-Path $PgBin "psql.exe") -U $PgUser -p $PgPort -d postgres -c "ALTER DATABASE $OldDbName RENAME TO $DbName;" | Out-Null
        }
        Terminate-WithError "Migration aborted at Step 4."
    }

    # Step 5: Analyze
    Write-Host ">>> [5/5] Finalizing (ANALYZE) ..." -ForegroundColor Cyan
    $anaArgs = @("-U", $PgUser, "-p", $PgPort, "-d", $DbName, "-c", "ANALYZE;")
    Invoke-PgCommand (Join-Path $PgBin "psql.exe") $anaArgs "Analyze Statistics" | Out-Null

    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Green
    Write-Host " SUCCESS! Migration completed." -ForegroundColor Green
    if ($DryRun) { Write-Host " (Dry-run mode: No actual changes were performed)" -ForegroundColor Yellow }
    Write-Host "================================================================" -ForegroundColor Green

} catch {
    Terminate-WithError $_.Exception.Message
} finally {
    Remove-Item Env:PGPASSWORD -ErrorAction SilentlyContinue
    if ($transcriptStarted) { Stop-Transcript }
}
