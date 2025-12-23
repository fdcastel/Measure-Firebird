# Measure-Firebird

A PowerShell script for benchmarking Firebird SQL database performance.

## Overview

This script creates a test database, performs various database operations (inserts, reads, updates, and indexing), and measures their execution times.

It also collects system, storage, and Firebird configuration information to provide a comprehensive performance profile.

### Quickstart

```powershell
iwr https://tinyurl.com/Measure-Firebird -UseBasicParsing | iex
```

## Features

- **Automated Benchmarking**: Tests 5 million record inserts, queries, updates, and index creation
- **Performance Metrics**: Measures execution time for each operation in milliseconds
- **System Information**: Collects CPU, memory, and Windows version details
- **Storage Details**: Gathers disk information including sector sizes and cache settings
- **Firebird Configuration**: Reports engine version, protocol, and client version
- **JSON Output**: Returns results in structured JSON format for easy analysis

## Prerequisites

- **Powershell**: Requires PowerShell 5.1+
- **Firebird SQL**: Must have Firebird 3.0 or later installed
- **Permissions**: Administrator rights may be required for disk information queries

## Configuration

### Environment Variables

The script respects the following environment variables:

| Variable                              | Description                | Default                                                   |
|---------------------------------------|----------------------------|-----------------------------------------------------------|
| `FIREBIRD_USER` or `ISC_USER`         | Database username          | `SYSDBA`                                                  |
| `FIREBIRD_PASSWORD` or `ISC_PASSWORD` | Database password          | `masterkey`                                               |
| `FIREBIRD_ENVIRONMENT`                | Firebird installation path | `/opt/firebird` or default instance location (on Windows) |

### Script Parameters

```powershell
.\Measure-Firebird.ps1 [[-DatabaseFolder] <string>] [-UseLocalProtocol]
```

**Parameters:**

- `-DatabaseFolder` (optional): Existing folder where the test database will be created. If not provided, the system temporary folder is used.
- `-UseLocalProtocol` (optional): Use local protocol (`xnet`) instead of network protocol (`inet`).

## Usage

### Basic Usage

Run the benchmark with default settings:

```powershell
.\Measure-Firebird.ps1
```

### Specify a database test location

Test on a different drive (e.g., D:):

```powershell
.\Measure-Firebird.ps1 -DatabaseFolder D:\
```

### Use Local Protocol

Run without network protocol overhead:

```powershell
.\Measure-Firebird.ps1 -UseLocalProtocol
```
