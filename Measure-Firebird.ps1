[CmdletBinding()]
param (
  [string]
  $DatabaseFolder,

  [switch]
  $UseLocalProtocol
)


#
# Configuration
#

# Shim for PowerShell Core cross-platform support
if ($PSVersionTable.PSVersion.Major -lt 6) {
  $IsWindows = $true
}

if ($UseLocalProtocol -and (-not $IsWindows)) {
  throw 'Local protocol (XNET) is only supported on Windows.'
}

$recordsToInsert = 5 * 1000 * 1000    # 5 million records

$defaultUser = 'SYSDBA'
$defaultPassword = 'masterkey'

$defaultFirebirdEnvironment = '/opt/firebird'
if ($IsWindows) {
  # ToDo: Detect instances from Windows registry.
  $defaultFirebirdEnvironment = 'C:/Program Files/Firebird/Firebird_3_0'
}


#
# Initialization
#
$user = if ($env:FIREBIRD_USER) { $env:FIREBIRD_USER } elseif ($env:ISC_USER) { $env:ISC_USER } else { $defaultUser }
$password = if ($env:FIREBIRD_PASSWORD) { $env:FIREBIRD_PASSWORD } elseif ($env:ISC_PASSWORD) { $env:ISC_PASSWORD } else { $defaultPassword }
$firebirdEnvironment = if ($env:FIREBIRD_ENVIRONMENT) { $env:FIREBIRD_ENVIRONMENT } else { $defaultFirebirdEnvironment }

# Determine isql location
$isql = if ($IsWindows) {
  Join-Path $firebirdEnvironment 'isql.exe'
} else {
  Join-Path $firebirdEnvironment 'bin/isql'
}
if (-not (Test-Path $isql)) {
  throw "isql not found at '$isql'. Set FIREBIRD_ENVIRONMENT environment variable to the Firebird installation path."
}


#
# Functions
#
function Invoke-Isql(
  [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
  [string]$Sql,

  [string]$Database = $null
) {
  $Sql | & $isql -b -q -pag 0 -user $user -password $password $Database > $null
  if ($LASTEXITCODE -ne 0) {
    throw 'Failed to execute SQL.'
  }
}

function Measure-Isql(
  [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
  [string]$Sql,

  [Parameter(Mandatory = $true)]
  [string]$Database
) {
  $elapsed = Measure-Command {
    Invoke-Isql -Sql $Sql -Database $Database
  }

  return [math]::Round($elapsed.TotalMilliseconds)
}

function Read-Isql(
  [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
  [string]$Sql,

  [Parameter(Mandatory = $true)]
  [string]$Database
) {
  $stdoutAndErr = "SET LIST ON; $Sql" | & $isql -b -q -pag 0 -user $user -password $password $Database 2>&1
  # Split stdout and stderr -- https://stackoverflow.com/a/68106198/33244
  #   The [string[]] cast converts the [ErrorRecord] instances to strings too.
  $stdout, [string[]]$stderr = $stdoutAndErr.Where({ $_ -is [string] }, 'Split')

  if ($LASTEXITCODE -ne 0) {
    throw 'Failed to execute SQL.'
  }

  # Parse isql list output. Discard first 2 lines, stop at first blank line.
  $result = [ordered]@{}

  $resultLines = $stdout | Select-Object -Skip 2
  foreach ($line in $resultLines) {
    if ($line.Trim() -eq '') { break }
    if ($line -match '^(\S+)\s+(.*)$') {
      $key = $Matches[1]
      $value = $Matches[2].Trim()
      $result[$key] = $value
    }
  }

  return $result
}


#
# Main
#
$ErrorActionPreference = 'Stop'

# Create test database
if (-not $DatabaseFolder) {
  $DatabaseFolder = [System.IO.Path]::GetTempPath()
} else {
  if (-not (Test-Path $DatabaseFolder)) {
    throw "Database folder '$DatabaseFolder' does not exist."
  }
}

$testDatabaseFile = Join-Path $DatabaseFolder '.firebird-benchmark.fdb'
Write-Verbose "Creating test database: $testDatabaseFile"

if (Test-Path $testDatabaseFile) {
  Write-Verbose "  Removing existing test database: $testDatabaseFile"
  Remove-Item $testDatabaseFile -Force    # -Force required to delete hidden files (!)
}

@"
CREATE DATABASE '$testDatabaseFile'
USER 'SYSDBA' PASSWORD 'masterkey'
PAGE_SIZE 8192;
"@ | Invoke-Isql

if ($UseLocalProtocol) {
  $testDatabase = "xnet://$testDatabaseFile"
  Write-Verbose "  Using xnet (local) protocol."
} else {
  $testDatabase = $testDatabaseFile
  Write-Verbose "  Using inet protocol."
}

# Create test table
Write-Verbose "Creating test table..."
@'
CREATE TABLE perf_test (
    id INTEGER NOT NULL PRIMARY KEY,
    data1 VARCHAR(100),
    data2 VARCHAR(100),
    data3 INTEGER,
    created_at TIMESTAMP
);
'@ | Invoke-Isql -Database $testDatabase

# Insert test data
Write-Verbose "Inserting $recordsToInsert records..."
$insertMs = @"
SET TERM ^^ ;
EXECUTE BLOCK
AS
DECLARE VARIABLE i INTEGER;
BEGIN
  i = 0;
  WHILE (i < $recordsToInsert) DO
  BEGIN
    INSERT INTO perf_test (id, data1, data2, data3, created_at)
    VALUES (:i,
            'Test Data ' || :i,
            'More Data ' || (:i * 2),
            MOD(:i, 1000),
            CURRENT_TIMESTAMP);
    i = i + 1;
  END
END
^^
SET TERM ; ^^
"@ | Measure-Isql -Database $testDatabase
Write-Verbose "  ${insertMs}ms"

# Random reads
Write-Verbose "Performing random reads..."
$selectMs = @'
SELECT COUNT(*) FROM perf_test WHERE data3 = 500;
SELECT * FROM perf_test WHERE id = 12345;
SELECT AVG(data3) FROM perf_test;
SELECT * FROM perf_test WHERE id BETWEEN 1000 AND 2000;
'@ | Measure-Isql -Database $testDatabase
Write-Verbose "  ${selectMs}ms"

# Random writes
Write-Verbose "Performing random writes..."
$updateMs = @'
UPDATE perf_test SET data3 = data3 + 1 WHERE MOD(id, 100) = 0;
'@ | Measure-Isql -Database $testDatabase
Write-Verbose "  ${updateMs}ms"

# Create index
Write-Verbose "Creating index..."
$indexMs = @'
CREATE INDEX idx_data3 ON perf_test(data3);
'@ | Measure-Isql -Database $testDatabase
Write-Verbose "  ${indexMs}ms"

# Query Firebird info
Write-Verbose "Collecting system information..."
$firebirdInfo = @'
SELECT
  rdb$get_context('SYSTEM', 'ENGINE_VERSION') "EngineVersion",
  mon$remote_protocol "RemoteProtocol",
  mon$client_version "ClientVersion"
FROM
  mon$attachments
WHERE
  mon$attachment_id = CURRENT_CONNECTION;
'@ | Read-Isql -Database $testDatabase

# Query system and disk info
if ($IsWindows) {
  $qualifier = Split-Path -Path ([System.IO.Path]::GetTempPath()) -Qualifier
  $physicalDisk = Get-Partition -DriveLetter $qualifier[0] | Get-Disk | Get-PhysicalDisk
  $storageProperties = $physicalDisk | Get-StorageAdvancedProperty
  $storageInfo = $physicalDisk | Select-Object FriendlyName, LogicalSectorSize, PhysicalSectorSize, @{Name = 'IsDeviceCacheEnabled'; Expression = { $storageProperties.IsDeviceCacheEnabled } }, @{Name = 'IsPowerProtected'; Expression = { $storageProperties.IsPowerProtected } }

  $computerInfo = Get-ComputerInfo | Select-Object CsName, @{Name = 'CsProcessorName'; Expression = { $_.CsProcessors[0].Name.Trim() } }, CsTotalPhysicalMemory, WindowsProductName, WindowsBuildLabEx
} else {
  # ToDo: Implement for Linux.
  $storageInfo = $null

  # Get Linux system info
  $cpuInfo = Get-Content '/proc/cpuinfo' -ErrorAction SilentlyContinue | Select-String '^model name\s*:\s*(.+)$' | Select-Object -First 1
  $memInfo = Get-Content '/proc/meminfo' -ErrorAction SilentlyContinue | Select-String '^MemTotal\s*:\s*(.+)'
  $osRelease = Get-Content '/etc/os-release' -ErrorAction SilentlyContinue | Select-String '^PRETTY_NAME=(.+)$'
  
  $computerInfo = [PSCustomObject]@{
    Hostname = hostname
    ProcessorName = if ($cpuInfo) { $cpuInfo.Matches.Groups[1].Value.Trim() } else { $null }
    TotalMemory = if ($memInfo) { $memInfo.Matches.Groups[1].Value } else { $null }
    OSName = if ($osRelease) { $osRelease.Matches.Groups[1].Value.Trim('"') } else { $null }
    KernelInfo = uname -a
  }
}

# Cleanup
Write-Verbose "Removing test database: $testDatabaseFile"
Remove-Item $testDatabaseFile -ErrorAction SilentlyContinue

# Build result
Write-Verbose "Benchmark completed."
[PSCustomObject]@{
  'insertMs'      = $insertMs
  'selectMs'      = $selectMs
  'updateMs'      = $updateMs
  'createIndexMs' = $indexMs
  'storage'       = $storageInfo
  'system'        = $computerInfo
  'firebird'      = $firebirdInfo
} | ConvertTo-Json
