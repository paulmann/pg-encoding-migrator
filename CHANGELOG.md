# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [1.0.0] - 2026-02-22

### Added
- Initial release
- WIN1251 to UTF8/ICU migration with on-the-fly re-encoding via pg_dump
- Auto-rollback on failure at any stage (rename back, drop new DB)
- Source database preserved as backup (never dropped automatically)
- Source encoding validation with user confirmation prompt if mismatch
- Backup database name auto-derived from DbName + SrcEncoding
- Dump file name auto-generated if not specified
- Optional transcript logging via Start-Transcript
- Optional GRANT for application database user with role existence check
- ANALYZE after restore for fresh query planner statistics
- Pre-flight checks: binary existence, PostgreSQL availability
- SQL temp file written without BOM to avoid Windows encoding issues
- PGPASSWORD passed via environment variable, cleared with Remove-Item after use
- PGDATA set via environment variable if PgData parameter is provided
