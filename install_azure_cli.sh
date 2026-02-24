#!/bin/bash

# Azure CLI 2.67 Installation Script with Comprehensive Checks
# Author: vermacodes
# Description: Fail-safe installation of Azure CLI version 2.67 with validation

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Configuration
readonly AZ_VERSION="2.83.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/tmp/azure-cli-install-${AZ_VERSION}.log"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "${LOG_FILE}"
}

info() { log "INFO" "${BLUE}$*${NC}"; }
warn() { log "WARN" "${YELLOW}$*${NC}"; }
error() { log "ERROR" "${RED}$*${NC}"; }
success() { log "SUCCESS" "${GREEN}$*${NC}"; }

# Cleanup function
cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        error "Installation failed. Check log file: ${LOG_FILE}"
        if [[ "$RUNNING_AS_ROOT" == "true" ]]; then
            error "You may need to run: apt-get autoremove && apt-get autoclean"
        else
            error "You may need to run: sudo apt-get autoremove && sudo apt-get autoclean"
        fi
    fi
    exit $exit_code
}

trap cleanup EXIT

# Check if running as root and adapt accordingly
check_root() {
    if [[ $EUID -eq 0 ]]; then
        warn "Running as root (likely in Docker container)"
        info "Skipping sudo checks and using direct commands"
        export RUNNING_AS_ROOT=true
        export SUDO_CMD=""
    else
        info "Running as regular user"
        export RUNNING_AS_ROOT=false
        export SUDO_CMD="sudo"
    fi
}

# Check if sudo is available (skip if root)
check_sudo() {
    if [[ "$RUNNING_AS_ROOT" == "true" ]]; then
        info "Running as root - skipping sudo checks"
        return 0
    fi
    
    if ! command -v sudo >/dev/null 2>&1; then
        error "sudo is required but not installed."
        exit 1
    fi
    
    # Test sudo access
    if ! sudo -n true 2>/dev/null; then
        info "Testing sudo access..."
        if ! sudo -v; then
            error "Unable to obtain sudo privileges."
            exit 1
        fi
    fi
    success "Sudo access confirmed"
}

# Check system requirements
check_system() {
    info "Checking system requirements..."
    
    # Check if it's a Debian/Ubuntu system
    if [[ ! -f /etc/debian_version ]]; then
        error "This script is designed for Debian/Ubuntu systems only."
        exit 1
    fi
    
    # Check architecture
    local arch=$(dpkg --print-architecture 2>/dev/null || echo "unknown")
    case "$arch" in
        amd64|arm64|armhf)
            info "Architecture: $arch (supported)"
            ;;
        *)
            error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
    
    # Check distribution
    if ! command -v lsb_release >/dev/null 2>&1; then
        warn "lsb_release not found, installing lsb-release..."
        ${SUDO_CMD} apt-get update -qq
        ${SUDO_CMD} apt-get install -y lsb-release
    fi
    
    local distro=$(lsb_release -cs 2>/dev/null)
    info "Distribution: $distro"
    
    # Check internet connectivity
    # Install nc (netcat) if not available
    if ! command -v nc >/dev/null 2>&1; then
        info "Installing netcat for connectivity testing..."
        ${SUDO_CMD} apt-get update -qq >/dev/null 2>&1 || true
        ${SUDO_CMD} apt-get install -y netcat-openbsd >/dev/null 2>&1 || {
            warn "Could not install netcat, skipping connectivity test"
            return 0
        }
    fi
    
    if ! nc -vz packages.microsoft.com 443 >/dev/null 2>&1; then
        error "Cannot reach packages.microsoft.com. Check internet connection."
        exit 1
    fi
    
    success "System requirements check passed"
}

# Check if Azure CLI is already installed
check_existing_installation() {
    info "Checking for existing Azure CLI installation..."
    
    if command -v az >/dev/null 2>&1; then
        local current_version=$(az version --output tsv --query '"azure-cli"' 2>/dev/null || echo "unknown")
        warn "Azure CLI is already installed (version: $current_version)"
        
        if [[ "$current_version" == "$AZ_VERSION" ]]; then
            success "Azure CLI ${AZ_VERSION} is already installed!"
            exit 0
        fi
        
        read -p "Do you want to continue and potentially upgrade/downgrade? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            info "Installation cancelled by user."
            exit 0
        fi
    else
        info "No existing Azure CLI installation found"
    fi
}

# Install prerequisites
install_prerequisites() {
    info "Installing prerequisites..."
    
    # Update package list
    info "Updating package list..."
    ${SUDO_CMD} apt-get update -qq || {
        error "Failed to update package list"
        exit 1
    }
    
    # Install required packages
    local packages=(
        "apt-transport-https"
        "ca-certificates"
        "curl"
        "gnupg"
        "lsb-release"
    )
    
    for package in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $package "; then
            info "Installing $package..."
            ${SUDO_CMD} apt-get install -y "$package" || {
                error "Failed to install $package"
                exit 1
            }
        else
            info "$package is already installed"
        fi
    done
    
    success "Prerequisites installed successfully"
}

# Setup Microsoft signing key
setup_microsoft_key() {
    info "Setting up Microsoft signing key..."
    
    # Create keyrings directory
    ${SUDO_CMD} mkdir -p /etc/apt/keyrings
    
    # Download and install Microsoft GPG key
    local key_file="/etc/apt/keyrings/microsoft.gpg"
    
    if [[ -f "$key_file" ]]; then
        info "Microsoft GPG key already exists"
    else
        info "Downloading Microsoft GPG key..."
        if ! curl -sLS https://packages.microsoft.com/keys/microsoft.asc | \
             gpg --dearmor | ${SUDO_CMD} tee "$key_file" > /dev/null; then
            error "Failed to download or install Microsoft GPG key"
            exit 1
        fi
        
        # Set proper permissions
        ${SUDO_CMD} chmod go+r "$key_file"
        success "Microsoft GPG key installed successfully"
    fi
    
    # Verify the key was installed correctly
    if [[ ! -s "$key_file" ]]; then
        error "Microsoft GPG key file is empty or missing"
        exit 1
    fi
}

# Add Azure CLI repository
add_azure_repository() {
    info "Adding Azure CLI repository..."
    
    local distro=$(lsb_release -cs 2>/dev/null)
    local arch=$(dpkg --print-architecture)
    local sources_file="/etc/apt/sources.list.d/azure-cli.sources"
    
    # Create repository configuration
    local repo_config="Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: ${distro}
Components: main
Architectures: ${arch}
Signed-by: /etc/apt/keyrings/microsoft.gpg"
    
    if [[ -f "$sources_file" ]]; then
        info "Azure CLI repository configuration already exists"
        # Backup existing configuration
        ${SUDO_CMD} cp "$sources_file" "${sources_file}.backup.$(date +%s)"
    fi
    
    echo "$repo_config" | ${SUDO_CMD} tee "$sources_file" > /dev/null || {
        error "Failed to create repository configuration"
        exit 1
    }
    
    success "Azure CLI repository added successfully"
}

# Update repository and check available versions
update_and_check_versions() {
    info "Updating repository information..."
    
    ${SUDO_CMD} apt-get update -qq || {
        error "Failed to update repository information"
        exit 1
    }
    
    info "Checking available Azure CLI versions..."
    if ! apt-cache policy azure-cli >/dev/null 2>&1; then
        error "Azure CLI package not found in repositories"
        exit 1
    fi
    
    # Check if specific version is available
    local distro=$(lsb_release -cs 2>/dev/null)
    local target_package="azure-cli=${AZ_VERSION}-1~${distro}"
    
    if ! apt-cache show "$target_package" >/dev/null 2>&1; then
        error "Azure CLI version ${AZ_VERSION} is not available for distribution ${distro}"
        info "Available versions:"
        apt-cache policy azure-cli | grep -A 10 "Version table" || true
        exit 1
    fi
    
    success "Azure CLI ${AZ_VERSION} is available for installation"
}

# Install specific Azure CLI version
install_azure_cli() {
    info "Installing Azure CLI version ${AZ_VERSION}..."
    
    local distro=$(lsb_release -cs 2>/dev/null)
    local target_package="azure-cli=${AZ_VERSION}-1~${distro}"
    
    # Install the specific version
    if ${SUDO_CMD} apt-get install -y "$target_package"; then
        success "Azure CLI ${AZ_VERSION} installed successfully"
    else
        error "Failed to install Azure CLI ${AZ_VERSION}"
        exit 1
    fi
    
    # Hold the package to prevent automatic updates
    ${SUDO_CMD} apt-mark hold azure-cli || warn "Failed to hold azure-cli package"
}

# Verify installation
verify_installation() {
    info "Verifying Azure CLI installation..."
    
    # Check if az command is available
    if ! command -v az >/dev/null 2>&1; then
        error "Azure CLI command 'az' not found in PATH"
        exit 1
    fi
    
    # Check version
    local installed_version
    installed_version=$(az version --output tsv --query '"azure-cli"' 2>/dev/null) || {
        error "Failed to get Azure CLI version"
        exit 1
    }
    
    if [[ "$installed_version" == "$AZ_VERSION" ]]; then
        success "Azure CLI ${AZ_VERSION} installed and verified successfully!"
        info "You can now use 'az' command"
        info "Run 'az login' to authenticate with Azure"
    else
        error "Version mismatch! Expected: ${AZ_VERSION}, Got: ${installed_version}"
        exit 1
    fi
    
    # Test basic functionality
    if az --help >/dev/null 2>&1; then
        success "Azure CLI basic functionality test passed"
    else
        warn "Azure CLI help command failed, but installation appears successful"
    fi
}

# Main execution function
main() {
    info "Starting Azure CLI ${AZ_VERSION} installation..."
    info "Log file: ${LOG_FILE}"
    
    check_root
    check_sudo
    check_system
    check_existing_installation
    install_prerequisites
    setup_microsoft_key
    add_azure_repository
    update_and_check_versions
    install_azure_cli
    verify_installation
    
    success "Azure CLI ${AZ_VERSION} installation completed successfully!"
    info "Installation log saved to: ${LOG_FILE}"
}

# Run main function
main "$@"