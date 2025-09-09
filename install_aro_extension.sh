#!/bin/bash

# Azure Red Hat OpenShift Extension Installation Script
# Author: vermacodes
# Description: Download and install the Azure Red Hat OpenShift (ARO) extension for Azure CLI

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# Configuration
readonly SHORTLINK_URL="https://aka.ms/az-aroext-latest"
readonly DOWNLOAD_DIR="/tmp/aro-extension"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/tmp/aro-extension-install.log"

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
    fi
    # Clean up download directory
    if [[ -d "$DOWNLOAD_DIR" ]]; then
        rm -rf "$DOWNLOAD_DIR" 2>/dev/null || true
    fi
    exit $exit_code
}

trap cleanup EXIT

# Check if running as root and adapt accordingly
check_root() {
    if [[ $EUID -eq 0 ]]; then
        warn "Running as root (likely in Docker container)"
        info "Using direct commands without sudo"
        export RUNNING_AS_ROOT=true
        export SUDO_CMD=""
    else
        info "Running as regular user"
        export RUNNING_AS_ROOT=false
        export SUDO_CMD="sudo"
    fi
}

# Install required utilities
install_utilities() {
    info "Checking and installing required utilities..."
    
    local utilities_needed=()
    local packages_to_install=()
    
    # Check for curl
    if ! command -v curl >/dev/null 2>&1; then
        utilities_needed+=("curl")
        packages_to_install+=("curl")
    fi
    
    # Check for du (should be available, but just in case)
    if ! command -v du >/dev/null 2>&1; then
        utilities_needed+=("du")
        packages_to_install+=("coreutils")
    fi
    
    # Check for basename (should be available, but just in case)
    if ! command -v basename >/dev/null 2>&1; then
        utilities_needed+=("basename")
        if [[ ! " ${packages_to_install[*]} " =~ " coreutils " ]]; then
            packages_to_install+=("coreutils")
        fi
    fi
    
    if [[ ${#utilities_needed[@]} -eq 0 ]]; then
        success "All required utilities are available"
        return 0
    fi
    
    info "Missing utilities: ${utilities_needed[*]}"
    info "Installing packages: ${packages_to_install[*]}"
    
    # Update package list first
    info "Updating package list..."
    ${SUDO_CMD} apt-get update -qq >/dev/null 2>&1 || {
        error "Failed to update package list"
        exit 1
    }
    
    # Install missing packages
    for package in "${packages_to_install[@]}"; do
        info "Installing $package..."
        if ! ${SUDO_CMD} apt-get install -y "$package" >/dev/null 2>&1; then
            error "Failed to install $package"
            exit 1
        fi
    done
    
    # Verify installation
    for utility in "${utilities_needed[@]}"; do
        if ! command -v "$utility" >/dev/null 2>&1; then
            error "Utility $utility still not available after installation"
            exit 1
        fi
    done
    
    success "All required utilities installed successfully"
}

# Check if Azure CLI is installed
check_azure_cli() {
    info "Checking for Azure CLI installation..."
    
    if ! command -v az >/dev/null 2>&1; then
        error "Azure CLI is not installed or not in PATH"
        error "Please install Azure CLI first before installing extensions"
        exit 1
    fi
    
    local az_version
    az_version=$(az version --output tsv --query '"azure-cli"' 2>/dev/null) || {
        error "Failed to get Azure CLI version"
        exit 1
    }
    
    success "Azure CLI version ${az_version} found"
}

# Check if ARO extension is already installed
check_existing_aro_extension() {
    info "Checking for existing ARO extension..."
    
    if az extension list --output tsv --query '[?name==`aro`].name' | grep -q "aro"; then
        local current_version
        current_version=$(az extension list --output tsv --query '[?name==`aro`].version' | head -n1)
        warn "ARO extension is already installed (version: ${current_version})"
        
        read -p "Do you want to update/reinstall the extension? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            info "Installation cancelled by user."
            exit 0
        fi
        
        info "Removing existing ARO extension..."
        if ! az extension remove --name aro 2>/dev/null; then
            warn "Failed to remove existing ARO extension, continuing..."
        fi
    else
        info "No existing ARO extension found"
    fi
}

# Create download directory
setup_download_directory() {
    info "Setting up download directory..."
    
    mkdir -p "$DOWNLOAD_DIR" || {
        error "Failed to create download directory: $DOWNLOAD_DIR"
        exit 1
    }
    
    success "Download directory created: $DOWNLOAD_DIR"
}

# Resolve shortlink and get actual download URL and filename
resolve_download_url() {
    info "Resolving download URL from shortlink..."
    
    # Follow redirects and get the final URL
    local final_url
    final_url=$(curl -sLI -o /dev/null -w '%{url_effective}' "$SHORTLINK_URL") || {
        error "Failed to resolve shortlink: $SHORTLINK_URL"
        exit 1
    }
    
    if [[ -z "$final_url" ]]; then
        error "Could not resolve final download URL"
        exit 1
    fi
    
    info "Final download URL: $final_url"
    
    # Extract filename from URL
    local filename
    filename=$(basename "$final_url")
    
    # Validate that it's a wheel file
    if [[ ! "$filename" =~ \.whl$ ]]; then
        error "Downloaded file is not a wheel file: $filename"
        exit 1
    fi
    
    success "Resolved wheel filename: $filename"
    
    # Export for use in other functions
    export DOWNLOAD_URL="$final_url"
    export WHEEL_FILENAME="$filename"
    export WHEEL_PATH="$DOWNLOAD_DIR/$filename"
}

# Download the ARO extension wheel file
download_aro_extension() {
    info "Downloading ARO extension wheel file..."
    info "Source: $DOWNLOAD_URL"
    info "Destination: $WHEEL_PATH"
    
    # Download with progress and error handling
    if ! curl -L --fail --show-error --progress-bar \
         -o "$WHEEL_PATH" \
         "$DOWNLOAD_URL"; then
        error "Failed to download ARO extension wheel file"
        exit 1
    fi
    
    # Verify download
    if [[ ! -f "$WHEEL_PATH" ]]; then
        error "Downloaded file does not exist: $WHEEL_PATH"
        exit 1
    fi
    
    if [[ ! -s "$WHEEL_PATH" ]]; then
        error "Downloaded file is empty: $WHEEL_PATH"
        exit 1
    fi
    
    local file_size
    file_size=$(du -h "$WHEEL_PATH" | cut -f1)
    success "Downloaded ARO extension wheel file (${file_size}): $WHEEL_FILENAME"
}

# Install the ARO extension
install_aro_extension() {
    info "Installing ARO extension from wheel file..."
    
    # Install the extension using the downloaded wheel file
    if ! az extension add --source "$WHEEL_PATH" --yes 2>/dev/null; then
        error "Failed to install ARO extension from wheel file"
        error "Wheel file: $WHEEL_PATH"
        exit 1
    fi
    
    success "ARO extension installed successfully"
}

# Verify the installation
verify_installation() {
    info "Verifying ARO extension installation..."
    
    # Check if extension is listed
    if ! az extension list --output tsv --query '[?name==`aro`].name' | grep -q "aro"; then
        error "ARO extension not found after installation"
        exit 1
    fi
    
    # Get extension details
    local extension_version
    local extension_preview
    extension_version=$(az extension list --output tsv --query '[?name==`aro`].version' | head -n1)
    extension_preview=$(az extension list --output tsv --query '[?name==`aro`].preview' | head -n1)
    
    success "ARO extension verification successful"
    info "Extension: aro"
    info "Version: $extension_version"
    info "Preview: $extension_preview"
    
    # Test basic functionality
    info "Testing ARO extension functionality..."
    if az aro --help >/dev/null 2>&1; then
        success "ARO extension is functional and ready to use"
        info "You can now use 'az aro' commands to manage Azure Red Hat OpenShift clusters"
    else
        warn "ARO extension installed but help command failed"
    fi
    
    # Show available commands
    info "Available ARO commands:"
    az aro --help 2>/dev/null | grep -E "^\s+[a-z]" | head -5 || true
    info "Use 'az aro --help' for complete command list"
}

# Main execution function
main() {
    info "Starting Azure Red Hat OpenShift extension installation..."
    info "Log file: ${LOG_FILE}"
    
    check_root
    install_utilities
    check_azure_cli
    check_existing_aro_extension
    setup_download_directory
    resolve_download_url
    download_aro_extension
    install_aro_extension
    verify_installation
    
    success "Azure Red Hat OpenShift extension installation completed successfully!"
    success "Downloaded file: $WHEEL_FILENAME"
    info "Installation log saved to: ${LOG_FILE}"
}

# Run main function
main "$@"