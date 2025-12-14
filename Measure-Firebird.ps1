[CmdletBinding()]
param ($DriveLetter = 'C')


#
# Configuration
#
$recordsToInsert = 5 * 1000 * 1000    # 5 million records

$user = 'SYSDBA'
$password = 'masterkey'

# ToDo: Detect Firebird path
$isql = 'C:/Program Files/Firebird/Firebird_3_0/isql.exe'


#
# Functions
#
function Invoke-Isql {
  param(
    [Parameter(ValueFromPipeline = $true)]
    [string]$Sql,

    [string]$Database = $null,

    [switch]$IgnoreErrors
  )

  if ($Database) {
    $Database = "localhost:$Database"
  }

  $Sql | & $isql -b -q -pag 0 -user $user -password $password $Database > $null
  if (($LASTEXITCODE -ne 0) -and (-not $IgnoreErrors)) {
    throw "Failed to execute SQL."
  }
}

function Measure-Isql() {
  [CmdletBinding()]
  param(
    [Parameter(ValueFromPipeline = $true)]
    [string]$Sql,

    [string]$Database = $null,

    [switch]$IgnoreErrors
  )

  $elapsed = Measure-Command {
    Invoke-Isql -Sql $Sql -Database $Database -IgnoreErrors:$IgnoreErrors
  }
  
  return [math]::Round($elapsed.TotalMilliseconds)
}


#
# Main
#
$ErrorActionPreference = 'Stop'

# Create test database
$testDbPath = "${DriveLetter}:/.firebird-benchmark.fdb"
Remove-Item $testDbPath -ErrorAction SilentlyContinue
@"
CREATE DATABASE '$testDbPath'
USER 'SYSDBA' PASSWORD 'masterkey'
PAGE_SIZE 8192;
"@ | Invoke-Isql

# Create test table
@'
CREATE TABLE perf_test (
    id INTEGER NOT NULL PRIMARY KEY,
    data1 VARCHAR(100),
    data2 VARCHAR(100),
    data3 INTEGER,
    created_at TIMESTAMP
);
'@ | Invoke-Isql -Database $testDbPath

# Insert test data
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
"@ | Measure-Isql -Database $testDbPath

# Random reads
$selectMs = @'
SELECT COUNT(*) FROM perf_test WHERE data3 = 500;
SELECT * FROM perf_test WHERE id = 12345;
SELECT AVG(data3) FROM perf_test;
SELECT * FROM perf_test WHERE id BETWEEN 1000 AND 2000;
'@ | Measure-Isql -Database $testDbPath

# Random writes
$updateMs = @'
UPDATE perf_test SET data3 = data3 + 1 WHERE MOD(id, 100) = 0;
'@ | Measure-Isql -Database $testDbPath

# Create index
$indexMs = @'
CREATE INDEX idx_data3 ON perf_test(data3);
'@ | Measure-Isql -Database $testDbPath

# Cleanup
Remove-Item $testDbPath -ErrorAction SilentlyContinue

# Query system and disk info
$computerInfo = Get-ComputerInfo | Select-Object CsName, @{Name="CsProcessorName"; Expression={$_.CsProcessors[0].Name.Trim()}}, CsTotalPhysicalMemory, WindowsProductName, WindowsBuildLabEx
$physicalDisk = Get-Partition -DriveLetter $DriveLetter | Get-Disk | Get-PhysicalDisk 
$storageProperties = $physicalDisk | Get-StorageAdvancedProperty
$storageInfo = $physicalDisk | Select-Object FriendlyName, LogicalSectorSize, PhysicalSectorSize, @{Name="IsDeviceCacheEnabled";Expression={$storageProperties.IsDeviceCacheEnabled}}, @{Name="IsPowerProtected";Expression={$storageProperties.IsPowerProtected}}

# Build result
[PSCustomObject]@{
  "insertMs" = $insertMs
  "selectMs" = $selectMs
  "updateMs" = $updateMs
  "createIndexMs" = $indexMs
  "storage" = $storageInfo
  "system" = $computerInfo
} | ConvertTo-Json
