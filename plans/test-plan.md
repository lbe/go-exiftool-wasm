# Test Plan for go-exiftool

## Overview

This plan outlines comprehensive test coverage for the go-exiftool project, including:
- Unit tests for all Go code
- Integration tests requiring actual ExifTool installation
- Image-based testing to exercise the ExifTool Perl code

## Current Coverage Analysis

### Existing Tests
| File | Coverage | Notes |
|------|----------|-------|
| [`server_test.go`](../server_test.go) | Partial | Tests basic server lifecycle, version command, shutdown |
| [`cmd_test.go`](../cmd_test.go) | Minimal | Only tests version command |
| [`printer_test.go`](../printer_test.go) | Partial | Tests print function, not close or error paths |
| [`init_test.go`](../init_test.go) | Setup | Configures Exec path for tests |

### Code Files Needing Tests
| File | Functions/Types | Current Coverage |
|------|-----------------|------------------|
| [`decode.go`](../decode.go) | `Unmarshal()` | **None** |
| [`printer.go`](../printer.go) | `printer.print()`, `printer.close()` | Partial |
| [`cmd.go`](../cmd.go) | `Command()`, `CommandContext()`, `commandArgs()` | Minimal |
| [`server.go`](../server.go) | `NewServer()`, `Command()`, `Close()`, `Shutdown()`, `restart()`, `start()`, `splitReadyToken()` | Partial |
| [`init.go`](../init.go) | Config vars | N/A (config) |

---

## Test Fixtures

### Image Files Required

Create `testdata/` directory with the following test images:

```
testdata/
├── sample.jpg          # JPEG with standard EXIF data
├── sample.tiff         # TIFF image with EXIF
├── sample.png          # PNG without EXIF (for negative tests)
├── sample_heic.heic    # HEIC format (if ExifTool supports)
├── sample_noexif.jpg   # JPEG without EXIF data
├── sample_gps.jpg      # JPEG with GPS data
└── sample_maker.jpg    # JPEG with MakerNotes
```

### Creating Test Images

Option 1: Use ExifTool to create test images:
```bash
# Create a minimal JPEG with known EXIF data
exiftool -create -Artist="Test Artist" -Copyright="Test Copyright" -testdata/sample.jpg

# Add GPS data
exiftool -GPSLatitude=37.7749 -GPSLongitude=-122.4194 -testdata/sample_gps.jpg
```

Option 2: Download public domain test images from:
- https://github.com/ianare/exif-samples
- https://exiftool.org/sample_images.html

---

## Unit Tests

### 1. decode_test.go - Unmarshal Function

```go
// Test cases for Unmarshal()
```

| Test Name | Description | Input | Expected |
|------------|-------------|-------|----------|
| `TestUnmarshalStandard` | Standard ExifTool output format | `"Artist : John Doe\nCopyright : CC\n"` | Map with 2 entries |
| `TestUnmarshalShort` | Short format (-s) | `"Artist: John\n"` | Map with 1 entry |
| `TestUnmarshalVeryShort` | Very short format (-S) | `"Artist=John\n"` | Map with 1 entry |
| `TestUnmarshalEmpty` | Empty input | `""` | Empty map, no error |
| `TestUnmarshalNoNewline` | Missing trailing newline | `"Artist : John"` | Error: unexpected end |
| `TestUnmarshalNoSeparator` | Missing colon separator | `"Artist John\n"` | Error: missing separator |
| `TestUnmarshalMultibyte` | UTF-8 values | `"Artist : 日本語\n"` | Correct UTF-8 handling |
| `TestUnmarshalCarriageReturn` | Windows line endings | `"Artist : John\r\n"` | Correct handling |
| `TestUnmarshalMultipleValues` | Multiple tags | 10+ tags | All parsed correctly |
| `TestUnmarshalColonInValue` | Colon in value | `"Description : Time: 12:00\n"` | Correct parsing |
| `TestUnmarshalEmptyValue` | Empty value | `"Artist : \n"` | Empty byte slice |

### 2. printer_test.go - Additional Coverage

| Test Name | Description | Focus |
|------------|-------------|-------|
| `TestPrinterClose` | Test close function | `printer.close()` returns nil on success |
| `TestPrinterCloseError` | Close with error | Error propagated correctly |
| `TestPrinterErrorPersist` | Error persists | After error, subsequent calls return same error |
| `TestPrinterBufferGrowth` | Buffer growth | Large inputs handled correctly |
| `TestPrinterNilWriter` | Nil writer | Panic or error handling |

### 3. cmd_test.go - Command Functions

| Test Name | Description | Focus |
|------------|-------------|-------|
| `TestCommandWithStdin` | Command with stdin | Pipe data to ExifTool |
| `TestCommandContext` | Context cancellation | Context timeout works |
| `TestCommandContextCancel` | Manual cancellation | Cancel before completion |
| `TestCommandArgs` | Argument building | `commandArgs()` produces correct args |
| `TestCommandWithConfig` | Custom config file | Config flag included |
| `TestCommandArg1` | Custom Arg1 | Arg1 included in command |
| `TestCommandError` | ExifTool error | Invalid arguments handled |
| `TestCommandStdinPipe` | Stdin to ExifTool | `-` filename reads stdin |
| `TestCommandMultipleFiles` | Multiple file args | Batch processing |

### 4. server_test.go - Server Operations

| Test Name | Description | Focus |
|------------|-------------|-------|
| `TestServerCommonArgs` | Server with common args | Args passed to all commands |
| `TestServerRestart` | Server restart | `restart()` recovers from error |
| `TestServerConcurrentCommands` | Concurrent access | Thread safety |
| `TestServerClose` | Force close | `Close()` terminates immediately |
| `TestServerShutdownWait` | Graceful shutdown | `Shutdown()` waits for command |
| `TestServerStderrOutput` | Error handling | Stderr returned as error |
| `TestServerStdoutScanError` | Scan failure | EOF and other errors handled |
| `TestServerStderrScanError` | Stderr scan failure | Error handling |
| `TestServerMultipleCommands` | Sequential commands | State maintained correctly |
| `TestServerBoundaryToken` | Boundary parsing | `{ready...}` token handled |
| `TestSplitReadyToken` | Token splitting | `splitReadyToken()` function |
| `TestSplitReadyTokenEOF` | Token at EOF | Final token handling |
| `TestServerProcessKill` | Process killed externally | Recovery behavior |

---

## Integration Tests

### 5. exiftool_test.go - ExifTool Operations

These tests require ExifTool to be installed and test actual Perl code execution.

#### Read Operations

| Test Name | Description | Command |
|------------|-------------|---------|
| `TestReadVersion` | Get ExifTool version | `-ver` |
| `TestReadAllTags` | Read all tags from JPEG | `-json sample.jpg` |
| `TestReadSpecificTag` | Read specific tag | `-Artist sample.jpg` |
| `TestReadShortFormat` | Short output format | `-s -Artist sample.jpg` |
| `TestReadVeryShortFormat` | Very short format | `-S -Artist sample.jpg` |
| `TestReadGPS` | Read GPS coordinates | `-GPSLatitude -GPSLongitude sample_gps.jpg` |
| `TestReadMakerNotes` | Read maker notes | `-MakerNotes sample_maker.jpg` |
| `TestReadNoEXIF` | File without EXIF | `-json sample_noexif.jpg` |
| `TestReadNonexistent` | Nonexistent file | Error handling |
| `TestReadBinary` | Binary data extraction | `-b -ThumbnailImage sample.jpg` |

#### Write Operations

| Test Name | Description | Command |
|------------|-------------|---------|
| `TestWriteArtist` | Write Artist tag | `-Artist=NewArtist sample.jpg` |
| `TestWriteCopyright` | Write Copyright | `-Copyright=2024 sample.jpg` |
| `TestWriteDateTime` | Write DateTime | `-DateTimeOriginal=2024:01:01 sample.jpg` |
| `TestWriteMultiple` | Write multiple tags | Multiple `-Tag=Value` args |
| `TestWriteDelete` | Delete tag | `-Artist= sample.jpg` |
| `TestWriteAll` | Write all from JSON | `-json=-` with stdin |
| `TestWriteProtected` | Write protected tag | Error handling |

#### Copy Operations

| Test Name | Description | Command |
|------------|-------------|---------|
| `TestCopyTags` | Copy tags between files | `-TagsFromFile src.jpg dst.jpg` |
| `TestCopySpecific` | Copy specific tag | `-TagsFromFile src.jpg -Artist dst.jpg` |

#### Batch Operations

| Test Name | Description | Command |
|------------|-------------|---------|
| `TestBatchRead` | Read multiple files | `-json *.jpg` |
| `TestBatchWrite` | Write to multiple files | Multiple file args |

#### Format Tests

| Test Name | Description | Command |
|------------|-------------|---------|
| `TestFormatJSON` | JSON output | `-json` |
| `TestFormatXML` | XML/RDF output | `-X` |
| `TestFormatCSV` | CSV output | `-csv` |
| `TestFormatHTML` | HTML output | `-htmlDump` |

---

## Error Handling Tests

### 6. error_test.go

| Test Name | Description | Expected Behavior |
|------------|-------------|-------------------|
| `TestErrorInvalidFile` | Nonexistent file | Error with message |
| `TestErrorInvalidArg` | Invalid argument | Error from ExifTool |
| `TestErrorCorruptImage` | Corrupted image file | Error or partial read |
| `TestErrorPermissionDenied` | No read permission | OS error |
| `TestErrorDiskFull` | Write to full disk | OS error |
| `TestErrorBrokenPipe` | Broken pipe | Error recovery |
| `TestErrorProcessKilled` | ExifTool killed | Server restart |
| `TestErrorStderrOutput` | ExifTool stderr | Error returned |
| `TestErrorTimeout` | Command timeout | Context deadline |

---

## Concurrency Tests

### 7. concurrent_test.go

| Test Name | Description | Focus |
|------------|-------------|-------|
| `TestConcurrentCommands` | Multiple goroutines | Thread safety |
| `TestConcurrentReadWrite` | Read and write concurrently | No race conditions |
| `TestConcurrentServers` | Multiple servers | Independent operation |
| `TestConcurrentClose` | Close during command | Safe shutdown |
| `TestRaceConditions` | Race detection | Run with -race flag |

---

## Context Tests

### 8. context_test.go

| Test Name | Description | Focus |
|------------|-------------|-------|
| `TestContextTimeout` | Short timeout | Context deadline exceeded |
| `TestContextCancel` | Manual cancel | Cancellation propagated |
| `TestContextDeadline` | Specific deadline | Deadline respected |
| `TestContextBackground` | No cancellation | Normal completion |

---

## Test Execution Strategy

### Test Tags

Use Go build tags to separate test types:

```go
//go:build integration
// +build integration
```

### Running Tests

```bash
# Unit tests only (no ExifTool required)
go test -v -short ./...

# Integration tests (requires ExifTool)
go test -v -tags=integration ./...

# All tests
go test -v -tags=all ./...

# With race detection
go test -race -v ./...

# Coverage report
go test -coverprofile=coverage.out ./...
go tool cover -html=coverage.out
```

### CI/CD Integration

```yaml
# Example GitHub Actions
- name: Run unit tests
  run: go test -short ./...

- name: Setup ExifTool
  run: sudo apt-get install libimage-exiftool-perl

- name: Run integration tests
  run: go test -tags=integration ./...
```

---

## Test Implementation Order

1. **Phase 1: Unit Tests (No External Dependencies)**
   - [ ] `decode_test.go` - Unmarshal function
   - [ ] `printer_test.go` - Complete coverage
   - [ ] `cmd_test.go` - commandArgs function

2. **Phase 2: Server Unit Tests**
   - [ ] `server_test.go` - splitReadyToken function
   - [ ] Server mock tests

3. **Phase 3: Integration Tests**
   - [ ] Create test fixtures (testdata/)
   - [ ] Read operation tests
   - [ ] Write operation tests
   - [ ] Copy operation tests

4. **Phase 4: Error and Edge Cases**
   - [ ] Error handling tests
   - [ ] Concurrent access tests
   - [ ] Context cancellation tests

---

## Coverage Goals

| Package | Target Coverage |
|---------|-----------------|
| `decode.go` | 100% |
| `printer.go` | 100% |
| `cmd.go` | 90%+ |
| `server.go` | 90%+ |
| **Overall** | **90%+** |

---

## Test Data Generation

### Script to Generate Test Images

```bash
#!/bin/bash
# scripts/generate_testdata.sh

mkdir -p testdata

# Create a minimal 1x1 pixel JPEG
convert -size 1x1 xc:white testdata/base.jpg

# Add standard EXIF data
exiftool -overwrite_original \
  -Artist="Test Artist" \
  -Copyright="Test Copyright" \
  -Title="Test Title" \
  -Description="Test Description" \
  -DateTimeOriginal="2024:01:15 12:00:00" \
  testdata/sample.jpg

# Create GPS variant
cp testdata/sample.jpg testdata/sample_gps.jpg
exiftool -overwrite_original \
  -GPSLatitude="37.7749" \
  -GPSLatitudeRef="N" \
  -GPSLongitude="122.4194" \
  -GPSLongitudeRef="W" \
  testdata/sample_gps.jpg

# Create no-EXIF variant
cp testdata/base.jpg testdata/sample_noexif.jpg

# Create PNG without EXIF
convert -size 1x1 xc:red testdata/sample.png
```

---

## Questions for Consideration

1. Should tests clean up modified files, or use temporary directories?
2. What is the minimum ExifTool version to support?
3. Should tests skip if ExifTool is not installed, or fail?
4. Are there specific ExifTool features or file formats to prioritize?
