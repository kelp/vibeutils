# GitHub Actions Workflows

This document describes the comprehensive CI/CD workflows implemented for the vibeutils project.

## Overview

The project includes five main workflow files that provide comprehensive automation for building, testing, and maintaining the codebase:

1. **CI (ci.yml)** - Core continuous integration
2. **Release (release.yml)** - Automated release management
3. **Security (security.yml)** - Security scanning and maintenance
4. **Compatibility (compatibility.yml)** - Cross-platform and version testing
5. **Documentation (docs.yml)** - Documentation building and deployment

## Workflow Details

### 1. CI Workflow (`ci.yml`)

**Triggers:** Push to main/githubactions branches, pull requests, manual dispatch

**Jobs:**
- **build-and-test**: Cross-platform building and testing (Linux, macOS)
  - Validates project structure
  - Checks code formatting with `zig fmt`
  - Builds debug and release versions
  - Runs unit tests
  - Tests basic utility functionality
  - Uploads build artifacts

- **privileged-tests**: Tests requiring elevated privileges
  - Linux: Uses fakeroot for privilege simulation
  - macOS: Limited privileged testing (graceful degradation)
  - Uses the project's smart test runner script
  - Uploads test results as artifacts

- **coverage**: Code coverage analysis
  - Runs tests with Zig native coverage
  - Uses kcov for detailed coverage reports
  - Merges coverage reports from all utilities
  - Uploads to Codecov and as artifacts

- **lint-and-format**: Code quality checks
  - Validates code formatting
  - Checks for TODOs and debug prints
  - Identifies common Zig code issues
  - Validates build configuration

- **benchmark-check**: Performance monitoring
  - Builds and runs benchmark suite
  - Analyzes performance results
  - Uploads benchmark data for tracking

- **windows-build**: Experimental Windows support
  - Cross-compilation for Windows
  - Basic functionality testing
  - Only runs on main branch pushes

- **integration-tests**: End-to-end testing
  - Downloads build artifacts
  - Runs integration test suite
  - Tests real-world usage scenarios

- **ci-summary**: Overall status reporting
  - Checks all job results
  - Generates comprehensive summary
  - Fails CI if required jobs fail

### 2. Release Workflow (`release.yml`)

**Triggers:** Version tags (v*), manual dispatch

**Jobs:**
- **build-release**: Multi-platform binary building
  - Targets: Linux (x86_64, ARM64), macOS (x86_64, ARM64), Windows (x86_64)
  - Optimized for release (ReleaseSafe)
  - Creates platform-specific packages (.tar.gz for Unix, .zip for Windows)
  - Includes version info, license, and documentation

- **create-release**: GitHub release management
  - Downloads all build artifacts
  - Generates comprehensive release notes
  - Creates GitHub release with all platform binaries
  - Lists all included utilities and platforms

- **validate-release**: Post-release testing
  - Downloads and tests release binaries
  - Validates functionality
  - Confirms successful deployment

### 3. Security Workflow (`security.yml`)

**Triggers:** Weekly schedule (Sundays 2 AM UTC), manual dispatch

**Jobs:**
- **check-zig-updates**: Dependency monitoring
  - Checks for new Zig versions
  - Creates GitHub issues for updates
  - Tracks version compatibility

- **security-scan**: Vulnerability analysis
  - CodeQL static analysis
  - Scans for unsafe patterns in Zig code
  - Checks C interop for security issues
  - Validates file operations and process execution

- **license-check**: Compliance verification
  - Validates LICENSE file presence
  - Checks for license headers in source files
  - Generates Software Bill of Materials (SBOM)

- **performance-regression**: Performance monitoring
  - Runs benchmark suite
  - Tracks performance over time
  - Identifies potential regressions

- **docs-freshness**: Documentation maintenance
  - Checks documentation currency
  - Validates man page coverage
  - Identifies stale TODO items

- **security-summary**: Overall status reporting
  - Checks all job results
  - Generates comprehensive security status summary
  - Fails workflow if critical security issues found

### 4. Compatibility Workflow (`compatibility.yml`)

**Triggers:** Monthly schedule, manual dispatch

**Jobs:**
- **zig-compatibility**: Multi-version testing
  - Tests against Zig 0.13.0, 0.14.1, and master
  - Cross-platform validation
  - Continues on error for development versions

- **libc-compatibility**: C library testing
  - Tests with glibc, musl, and system libc
  - Validates static linking for musl
  - Ensures broad compatibility

- **distro-compatibility**: Distribution testing
  - Tests on Ubuntu 20.04/22.04, Debian 11, Alpine
  - Container-based testing
  - Validates across different Linux distributions

- **resource-testing**: Resource constraint validation
  - Memory leak detection with Valgrind
  - Memory limit testing
  - CPU efficiency measurement
  - Large file handling validation

- **cross-compilation**: Build target validation
  - Tests cross-compilation to various targets
  - Validates binary generation
  - Ensures portability

- **performance-baseline**: Performance standards
  - Runs optimized benchmarks
  - Compares with GNU coreutils
  - Establishes performance baselines

### 5. Documentation Workflow (`docs.yml`)

**Triggers:** Push to main (docs changes), pull requests, manual dispatch

**Jobs:**
- **build-docs**: Documentation generation
  - Validates man page syntax with mandoc
  - Generates Zig source documentation
  - Converts man pages to HTML
  - Creates unified documentation website
  - Builds searchable utility index

- **deploy-docs**: GitHub Pages deployment
  - Deploys documentation to GitHub Pages
  - Only runs on main branch
  - Provides public documentation access

- **link-check**: Link validation
  - Checks README and documentation links
  - Uses markdown-link-check
  - Identifies broken references

- **docs-quality**: Quality assurance
  - Checks documentation completeness
  - Validates writing quality
  - Ensures consistency across docs

## Configuration Files

### Link Check Configuration (`.github/link-check-config.json`)
- Configures link checking behavior
- Ignores localhost and test URLs
- Sets appropriate timeouts and retry logic
- Handles common HTTP status codes

## Caching Strategy

The workflows implement comprehensive caching:
- **Zig Cache**: `zig-cache` and `zig-out` directories
- **Platform Cache**: OS-specific Zig cache directories
- **Dependency Cache**: Build dependencies and tools
- **Artifact Cache**: Build artifacts shared between jobs

Cache keys include:
- OS and Zig version
- Build file hashes (`build.zig`, `build.zig.zon`, `build/**/*.zig`)
- Job-specific identifiers

## Security Features

- **CodeQL Analysis**: Automated security scanning
- **Dependency Monitoring**: Tracks Zig version updates
- **License Compliance**: SBOM generation and license validation
- **Privilege Testing**: Secure testing with fakeroot simulation
- **Artifact Cleanup**: Automatic cleanup of old data

## Cross-Platform Support

- **Primary Platforms**: Linux, macOS
- **Secondary Platforms**: Windows (experimental)
- **Architecture Support**: x86_64, ARM64
- **Distribution Testing**: Ubuntu, Debian, Alpine
- **C Library Support**: glibc, musl, system libc

## Performance Monitoring

- **Benchmark Suite**: Automated performance testing
- **Regression Detection**: Tracks performance over time
- **Resource Testing**: Memory and CPU usage validation
- **Comparison Testing**: Performance vs. GNU coreutils

## Integration with Project Structure

The workflows are designed to work seamlessly with the project's existing structure:
- **Makefile Integration**: Uses existing `make` targets
- **Test Framework**: Leverages the existing test infrastructure
- **Privileged Testing**: Uses the project's privilege testing framework
- **Build System**: Works with the existing Zig build configuration

## Manual Workflow Triggers

All workflows support manual triggering with options:
- **CI**: Debug logging, benchmark control
- **Release**: Custom tag names, prerelease marking
- **Security**: Force scanning
- **Compatibility**: Version selection, comprehensive testing
- **Documentation**: On-demand rebuilding

## Artifact Management

- **Build Artifacts**: 7-day retention for development
- **Documentation**: 30-day retention
- **Coverage Reports**: 30-day retention
- **Benchmark Results**: 90-day retention
- **Release Assets**: Permanent retention

## Monitoring and Alerting

- **Job Status Reporting**: Comprehensive status summaries
- **Issue Creation**: Automatic issues for updates and problems
- **Warning Annotations**: Clear marking of non-critical issues
- **Performance Alerts**: Notification of regressions

This workflow setup provides comprehensive automation for the vibeutils project, ensuring code quality, security, performance, and maintainability while supporting the project's cross-platform and compatibility goals.