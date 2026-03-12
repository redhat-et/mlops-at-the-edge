#!/bin/bash

###############################################################################
# Script: install-sno.sh
# Description: Deploy multiple Single Node OpenShift (SNO) VMs using kcli
#
# Usage:
#   Deploy SNOs: ./install-sno.sh <target_ip> <user> <password> <sno_count>
#   Cleanup:     ./install-sno.sh --cleanup <target_ip> [user] [password]
#
# Parameters (for deployment):
#   target_ip   - IP address of the target machine (kcli hypervisor)
#   user        - Username for SSH access to target machine
#   password    - Password for SSH access (optional if SSH keys are configured)
#   sno_count   - Number of SNO machines to deploy
#
# Cleanup mode:
#   --cleanup   - Cleanup mode: removes all SNO deployments and resources
#   target_ip   - IP address of the target machine
#   user        - Username (optional, defaults to root)
#   password    - Password (optional, if SSH keys are configured)
#
# Prerequisites:
#   - SSH access to the target machine (hypervisor)
#   - Target machine must have libvirt/kvm capabilities
#   - OpenShift pull secret (will prompt if not found)
#   - kcli will be automatically installed on the hypervisor
#
# Environment Variables (optional):
#   SNO_MEMORY        - Memory in MB (default: 24576)
#   SNO_CPUS          - Number of CPUs (default: 8)
#   SNO_DISK_SIZE     - Disk size in GB (default: 120)
#   SNO_DOMAIN        - Domain for clusters (default: local)
#   OCP_VERSION       - OpenShift version (default: stable)
#
# Network Configuration:
#   - Uses custom NAT network: sno-hypervisor-network (192.168.150.0/24)
#   - VIP IPs are reserved: .21 to .(20 + SNO_COUNT) for OpenShift API/Ingress VIPs
#   - DHCP range: .100 to .200 (excludes reserved VIPs, used by VMs)
#   - VIPs are configured via api_ip parameter in kcli command
#   - VMs (bootstrap and ctlplane) get IPs from DHCP range automatically
#   - HAProxy is automatically configured on hypervisor to route to VIPs
#   - Access from laptop: laptop -> hypervisor HAProxy -> SNO VIPs -> clusters
#   - /etc/hosts entries point to hypervisor IP (not NAT IPs) for proper routing
#
# Parallel Execution:
#   All SNO deployments run in parallel (background processes)
#   Each deployment logs to: /tmp/kcli-<vm_name>.log (on hypervisor)
#   Logs are periodically copied to local machine: /tmp/kcli-<vm_name>.log
#   Monitor progress: tail -f /tmp/kcli-sno-*.log
#
# Architecture:
#   - kcli runs on the hypervisor (not locally)
#   - Architecture automatically matches hypervisor (x86_64 or ARM64)
#   - No architecture mismatch issues since openshift-install runs on hypervisor
###############################################################################

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored messages
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to validate inputs
validate_inputs() {
    if [ $# -ne 4 ]; then
        print_error "Invalid number of arguments"
        echo "Usage: $0 <target_ip> <user> <password> <sno_count>"
        echo ""
        echo "Example: $0 192.168.1.100 admin mypassword 3"
        exit 1
    fi

    TARGET_IP="$1"
    USER="$2"
    PASSWORD="$3"
    SNO_COUNT="$4"

    # Validate IP address format (basic check)
    if ! [[ $TARGET_IP =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        print_error "Invalid IP address format: $TARGET_IP"
        exit 1
    fi

    # Validate SNO count is a positive integer
    if ! [[ $SNO_COUNT =~ ^[1-9][0-9]*$ ]]; then
        print_error "SNO count must be a positive integer: $SNO_COUNT"
        exit 1
    fi

    print_success "Input validation passed"
}

# Function to check prerequisites
check_prerequisites() {
    print_info "Checking local prerequisites..."

    # Check if SSH is available
    if ! command_exists ssh; then
        print_error "SSH is not installed"
        exit 1
    fi

    # Check if sshpass is available (for password-based auth)
    if [ -n "$PASSWORD" ] && [ "$PASSWORD" != "none" ]; then
        if ! command_exists sshpass; then
            print_warning "sshpass is not installed. Installing..."
            if command_exists dnf; then
                sudo dnf install -y sshpass
            elif command_exists yum; then
                sudo yum install -y sshpass
            elif command_exists apt-get; then
                sudo apt-get update && sudo apt-get install -y sshpass
            else
                print_error "Cannot install sshpass automatically. Please install it manually."
                exit 1
            fi
        fi
    fi

    # Check for curl or wget (needed for downloads)
    if ! command_exists curl && ! command_exists wget; then
        print_warning "Neither curl nor wget is available. Some operations may fail."
    fi

    print_success "Local prerequisites check completed"
    print_info "Note: kcli will be installed on the hypervisor automatically"
}

# Function to execute remote command
execute_remote() {
    local cmd="$1"
    local timeout="${2:-300}"  # Default 5 minutes for long operations
    if [ -n "$PASSWORD" ] && [ "$PASSWORD" != "none" ]; then
        timeout "$timeout" sshpass -p "$PASSWORD" ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=60 -o ServerAliveCountMax=3 \
           "$USER@$TARGET_IP" "$cmd"
    else
        timeout "$timeout" ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ServerAliveInterval=60 -o ServerAliveCountMax=3 \
           "$USER@$TARGET_IP" "$cmd"
    fi
}

# Function to test SSH connection
test_ssh_connection() {
    print_info "Testing SSH connection to $USER@$TARGET_IP..."

    if [ -n "$PASSWORD" ] && [ "$PASSWORD" != "none" ]; then
        # Use sshpass for password authentication
        if sshpass -p "$PASSWORD" ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null "$USER@$TARGET_IP" "echo 'Connection successful'" >/dev/null 2>&1; then
            print_success "SSH connection successful"
        else
            print_error "Failed to connect via SSH. Please check credentials and network connectivity."
            exit 1
        fi
    else
        # Use SSH keys
        if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null "$USER@$TARGET_IP" "echo 'Connection successful'" >/dev/null 2>&1; then
            print_success "SSH connection successful (using SSH keys)"
        else
            print_error "Failed to connect via SSH. Please check SSH keys and network connectivity."
            exit 1
        fi
    fi
}

# Function to check and install prerequisites on target server
check_target_server_prerequisites() {
    print_info "Checking prerequisites on target server ($TARGET_IP)..."

    # Detect OS type on target server
    local os_type=$(execute_remote "if [ -f /etc/os-release ]; then . /etc/os-release && echo \$ID; else echo 'unknown'; fi" 2>/dev/null || echo "unknown")
    local os_version=$(execute_remote "if [ -f /etc/os-release ]; then . /etc/os-release && echo \$VERSION_ID; else echo 'unknown'; fi" 2>/dev/null || echo "unknown")

    print_info "Target server OS: $os_type $os_version"

    # Check if running as root or has sudo access
    local has_sudo=false
    if execute_remote "sudo -n true" >/dev/null 2>&1; then
        has_sudo=true
        print_success "User has sudo access"
    else
        print_warning "User may not have sudo access. Some checks/installs may fail."
    fi

    # Function to install package on target
    install_package_remote() {
        local package=$1
        print_info "Installing $package on target server..."

        if [ "$has_sudo" = true ]; then
            # Check for and remove dnf/yum locks
            case "$os_type" in
                fedora|rhel|centos|rocky|almalinux)
                    # Remove any existing dnf locks
                    execute_remote "sudo rm -f /var/lib/dnf/history.sqlite* /var/lib/rpm/__db* /var/cache/dnf/*.pid /var/run/dnf.pid 2>/dev/null || true" 30
                    # Kill any stuck dnf processes
                    execute_remote "sudo pkill -9 dnf || sudo pkill -9 yum || true" 30
                    sleep 2
                    # Install with extended timeout (10 minutes for package installation)
                    execute_remote "sudo dnf install -y --setopt=timeout=600 $package" 600 || \
                    execute_remote "sudo yum install -y $package" 600
                    ;;
                ubuntu|debian)
                    # Remove apt locks
                    execute_remote "sudo rm -f /var/lib/dpkg/lock* /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null || true" 30
                    execute_remote "sudo pkill -9 apt-get || sudo pkill -9 apt || true" 30
                    sleep 2
                    execute_remote "sudo DEBIAN_FRONTEND=noninteractive apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $package" 600
                    ;;
                *)
                    print_warning "Unknown OS type. Please install $package manually."
                    return 1
                    ;;
            esac
        else
            print_error "Cannot install $package: no sudo access"
            return 1
        fi
    }

    # Check for libvirt
    print_info "Checking for libvirt..."
    if execute_remote "command -v virsh >/dev/null 2>&1" >/dev/null 2>&1; then
        local libvirt_version=$(execute_remote "virsh version --short" 2>/dev/null || echo "unknown")
        print_success "libvirt is installed: $libvirt_version"
    else
        print_warning "libvirt is not installed"
        if [ "$has_sudo" = true ]; then
            read -p "Install libvirt on target server? (y/n) [y]: " install_libvirt
            install_libvirt=${install_libvirt:-y}
            if [[ "$install_libvirt" =~ ^[Yy]$ ]]; then
                case "$os_type" in
                    fedora|rhel|centos|rocky|almalinux)
                        # Remove dnf locks before installation
                        execute_remote "sudo rm -f /var/lib/dnf/history.sqlite* /var/lib/rpm/__db* /var/cache/dnf/*.pid /var/run/dnf.pid 2>/dev/null || true" 30
                        execute_remote "sudo pkill -9 dnf || sudo pkill -9 yum || true" 30
                        sleep 2
                        execute_remote "sudo dnf install -y --setopt=timeout=600 libvirt libvirt-daemon-driver-qemu qemu-kvm tar" 600 || \
                        execute_remote "sudo yum install -y libvirt libvirt-daemon-driver-qemu qemu-kvm tar" 600
                        ;;
                    ubuntu|debian)
                        execute_remote "sudo rm -f /var/lib/dpkg/lock* /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null || true" 30
                        execute_remote "sudo pkill -9 apt-get || sudo pkill -9 apt || true" 30
                        sleep 2
                        execute_remote "sudo DEBIAN_FRONTEND=noninteractive apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y libvirt-daemon-system libvirt-clients qemu-kvm tar" 600
                        ;;
                    *)
                        print_error "Cannot auto-install libvirt on this OS. Please install manually."
                        exit 1
                        ;;
                esac
                print_success "libvirt installed"
            else
                print_error "libvirt is required. Please install it manually."
                exit 1
            fi
        else
            print_error "libvirt is required but cannot be installed without sudo. Please install manually."
            exit 1
        fi
    fi

    # Check for qemu-kvm
    print_info "Checking for qemu-kvm..."
    if execute_remote "command -v qemu-system-x86_64 >/dev/null 2>&1 || command -v qemu-kvm >/dev/null 2>&1" >/dev/null 2>&1; then
        print_success "qemu-kvm is installed"
    else
        print_warning "qemu-kvm is not installed"
        if [ "$has_sudo" = true ]; then
            install_package_remote "qemu-kvm"
        fi
    fi

    # Check if user is in required groups
    print_info "Checking user groups..."
    local user_groups=$(execute_remote "groups" 2>/dev/null || echo "")
    local needs_groups=""

    if ! echo "$user_groups" | grep -q "qemu"; then
        needs_groups="$needs_groups qemu"
    fi
    if ! echo "$user_groups" | grep -q "libvirt"; then
        needs_groups="$needs_groups libvirt"
    fi

    if [ -n "$needs_groups" ]; then
        print_warning "User needs to be in groups:$needs_groups"
        if [ "$has_sudo" = true ]; then
            print_info "Adding user to required groups..."
            for group in $needs_groups; do
                execute_remote "sudo usermod -aG $group $USER" 2>/dev/null || true
            done
            print_warning "Groups updated. User may need to log out and back in for changes to take effect."
            print_info "Alternatively, run: newgrp libvirt"
        else
            print_warning "Cannot add user to groups without sudo. Please run manually:"
            echo "  sudo usermod -aG qemu,libvirt $USER"
        fi
    else
        print_success "User is in required groups (qemu, libvirt)"
    fi

    # Check if libvirtd service is running
    print_info "Checking libvirtd service status..."
    local service_status=$(execute_remote "systemctl is-active libvirtd 2>/dev/null || systemctl is-active libvirt-bin 2>/dev/null || echo 'inactive'" 2>/dev/null || echo "unknown")

    if [ "$service_status" = "active" ]; then
        print_success "libvirtd service is running"
    else
        print_warning "libvirtd service is not running (status: $service_status)"
        if [ "$has_sudo" = true ]; then
            print_info "Starting and enabling libvirtd service..."
            execute_remote "sudo systemctl enable --now libvirtd" 2>/dev/null || \
            execute_remote "sudo systemctl enable --now libvirt-bin" 2>/dev/null || true

            sleep 2
            service_status=$(execute_remote "systemctl is-active libvirtd 2>/dev/null || systemctl is-active libvirt-bin 2>/dev/null || echo 'inactive'" 2>/dev/null || echo "unknown")
            if [ "$service_status" = "active" ]; then
                print_success "libvirtd service is now running"
            else
                print_error "Failed to start libvirtd service"
                exit 1
            fi
        else
            print_error "Cannot start libvirtd service without sudo. Please start manually:"
            echo "  sudo systemctl enable --now libvirtd"
            exit 1
        fi
    fi

    # Check for default storage pool
    print_info "Checking for default storage pool..."
    if execute_remote "virsh pool-list --all 2>/dev/null | grep -q default" >/dev/null 2>&1; then
        local pool_status=$(execute_remote "virsh pool-info default 2>/dev/null | grep State | awk '{print \$2}'" 2>/dev/null || echo "unknown")
        print_success "Default storage pool exists (status: $pool_status)"

        if [ "$pool_status" != "running" ] && [ "$pool_status" != "active" ]; then
            print_info "Starting default storage pool..."
            execute_remote "virsh pool-start default" >/dev/null 2>&1 || true
        fi
    else
        print_warning "Default storage pool does not exist"
        if [ "$has_sudo" = true ]; then
            print_info "Creating default storage pool..."
            # Try to create default pool at standard location
            local pool_path="/var/lib/libvirt/images"
            execute_remote "sudo mkdir -p $pool_path" 2>/dev/null || true
            execute_remote "sudo setfacl -m u:$USER:rwx $pool_path" 2>/dev/null || true

            # Create pool using virsh
            execute_remote "virsh pool-define-as default dir - - - - $pool_path" >/dev/null 2>&1 || true
            execute_remote "virsh pool-build default" >/dev/null 2>&1 || true
            execute_remote "virsh pool-start default" >/dev/null 2>&1 || true
            execute_remote "virsh pool-autostart default" >/dev/null 2>&1 || true

            if execute_remote "virsh pool-list --all 2>/dev/null | grep -q default" >/dev/null 2>&1; then
                print_success "Default storage pool created"
            else
                print_warning "Could not create default pool automatically. You may need to create it manually:"
                echo "  kcli create pool -p $pool_path default"
            fi
        else
            print_warning "Cannot create default pool without sudo. You may need to create it manually."
        fi
    fi

    # Setup custom NAT network for SNO deployments
    print_info "=========================================="
    print_info "Setting up custom NAT network for SNOs"
    print_info "=========================================="

    local sno_net_name="sno-hypervisor-network"
    local sno_net_subnet="192.168.150.0/24"
    local sno_net_gateway="192.168.150.1"

    # Check if custom NAT network exists
    if execute_remote "virsh net-list --all 2>/dev/null | grep -q $sno_net_name" >/dev/null 2>&1; then
        local net_status=$(execute_remote "virsh net-info $sno_net_name 2>/dev/null | grep Active | awk '{print \$2}'" 2>/dev/null || echo "unknown")
        print_success "Custom NAT network '$sno_net_name' exists (status: $net_status)"

        if [ "$net_status" != "yes" ] && [ "$net_status" != "active" ]; then
            print_info "Starting custom NAT network..."
            execute_remote "virsh net-start $sno_net_name" >/dev/null 2>&1 || true
            execute_remote "virsh net-autostart $sno_net_name" >/dev/null 2>&1 || true
        fi
    else
        print_info "Creating custom NAT network: $sno_net_name"

        # Create network XML with default range (will be updated later with SNO_COUNT)
        # Default: reserve .21-.99 for VIPs, DHCP from .100 to .200
        local sno_net_xml="<network>
  <name>$sno_net_name</name>
  <bridge name=\"virbr1\"/>
  <forward/>
  <ip address=\"$sno_net_gateway\" netmask=\"255.255.255.0\">
    <dhcp>
      <range start=\"192.168.150.100\" end=\"192.168.150.200\"/>
    </dhcp>
  </ip>
</network>"

        # Create network XML file on remote
        execute_remote "cat > /tmp/sno-network.xml <<'SNONETXML'
$sno_net_xml
SNONETXML
" >/dev/null 2>&1

        if execute_remote "virsh net-define /tmp/sno-network.xml" >/dev/null 2>&1; then
            print_success "Custom NAT network defined"
            execute_remote "virsh net-start $sno_net_name" >/dev/null 2>&1 || true
            execute_remote "virsh net-autostart $sno_net_name" >/dev/null 2>&1 || true
            print_success "Custom NAT network '$sno_net_name' is active"
        else
            print_warning "Failed to create custom NAT network. Trying kcli..."
            if execute_remote "command -v kcli >/dev/null 2>&1" >/dev/null 2>&1; then
                execute_remote "kcli create network -c $sno_net_subnet $sno_net_name" >/dev/null 2>&1 || true
            fi
        fi

        execute_remote "rm -f /tmp/sno-network.xml" >/dev/null 2>&1 || true
    fi

    echo ""

    # Check for default network (for fallback or other VMs)
    print_info "Checking for default network..."
    if execute_remote "virsh net-list --all 2>/dev/null | grep -q default" >/dev/null 2>&1; then
        local net_status=$(execute_remote "virsh net-info default 2>/dev/null | grep Active | awk '{print \$2}'" 2>/dev/null || echo "unknown")
        print_success "Default network exists (status: $net_status)"

        if [ "$net_status" != "yes" ] && [ "$net_status" != "active" ]; then
            print_info "Starting default network..."
            execute_remote "virsh net-start default" >/dev/null 2>&1 || true
            execute_remote "virsh net-autostart default" >/dev/null 2>&1 || true
        fi
    else
        print_warning "Default network does not exist"
        print_info "Creating default network..."
        # Create default network with common subnet using virsh
        # First try using kcli if available, otherwise use virsh directly
        local network_xml='<network><name>default</name><bridge name="virbr0"/><forward/><ip address="192.168.122.1" netmask="255.255.255.0"><dhcp><range start="192.168.122.2" end="192.168.122.254"/></dhcp></ip></network>'

        # Try kcli first (simpler)
        if execute_remote "command -v kcli >/dev/null 2>&1" >/dev/null 2>&1; then
            execute_remote "kcli create network -c 192.168.122.0/24 default" >/dev/null 2>&1 || true
        fi

        # If kcli didn't work or isn't available, use virsh
        if ! execute_remote "virsh net-list --all 2>/dev/null | grep -q default" >/dev/null 2>&1; then
            # Create network XML file on remote and define it
            execute_remote "cat > /tmp/default-network.xml <<'NETXML'
$network_xml
NETXML
" >/dev/null 2>&1
            execute_remote "virsh net-define /tmp/default-network.xml" >/dev/null 2>&1 || true
            execute_remote "rm -f /tmp/default-network.xml" >/dev/null 2>&1 || true
        fi

        if execute_remote "virsh net-list --all 2>/dev/null | grep -q default" >/dev/null 2>&1; then
            execute_remote "virsh net-start default" >/dev/null 2>&1 || true
            execute_remote "virsh net-autostart default" >/dev/null 2>&1 || true
            print_success "Default network created"
        else
            print_warning "Could not create default network automatically. You may need to create it manually:"
            echo "  kcli create network -c 192.168.122.0/24 default"
            echo "  Or: virsh net-define <network-xml-file>"
        fi
    fi

    # Check virtualization support (optional but recommended)
    print_info "Checking virtualization support..."
    if execute_remote "grep -E 'vmx|svm' /proc/cpuinfo >/dev/null 2>&1" >/dev/null 2>&1; then
        print_success "CPU virtualization support detected"
    else
        print_warning "CPU virtualization support not detected (may be nested virtualization)"
    fi

    # Check for coreos-installer (required for SNO deployment)
    print_info "Checking for coreos-installer..."
    if execute_remote "command -v coreos-installer >/dev/null 2>&1" >/dev/null 2>&1; then
        local coreos_version=$(execute_remote "coreos-installer --version 2>/dev/null | head -1" 2>/dev/null || echo "installed")
        print_success "coreos-installer is installed: $coreos_version"
    else
        print_warning "coreos-installer is not installed (required for SNO deployment)"
        if [ "$has_sudo" = true ]; then
            read -p "Install coreos-installer on target server? (y/n) [y]: " install_coreos
            install_coreos=${install_coreos:-y}
            if [[ "$install_coreos" =~ ^[Yy]$ ]]; then
                case "$os_type" in
                    fedora|rhel|centos|rocky|almalinux)
                        # Remove dnf locks
                        execute_remote "sudo rm -f /var/lib/dnf/history.sqlite* /var/lib/rpm/__db* /var/cache/dnf/*.pid /var/run/dnf.pid 2>/dev/null || true" 30
                        execute_remote "sudo pkill -9 dnf || sudo pkill -9 yum || true" 30
                        sleep 2
                        # Try to install from EPEL or download directly
                        if execute_remote "sudo dnf install -y --setopt=timeout=600 coreos-installer" 600 2>/dev/null; then
                            print_success "coreos-installer installed via dnf"
                        else
                            print_info "coreos-installer not in repos, downloading from GitHub..."
                            # Download coreos-installer binary
                            execute_remote "curl -L -o /tmp/coreos-installer https://github.com/coreos/coreos-installer/releases/latest/download/coreos-installer" 2>/dev/null || \
                            execute_remote "wget -O /tmp/coreos-installer https://github.com/coreos/coreos-installer/releases/latest/download/coreos-installer" 2>/dev/null
                            if [ $? -eq 0 ]; then
                                execute_remote "sudo mv /tmp/coreos-installer /usr/local/bin/coreos-installer && sudo chmod +x /usr/local/bin/coreos-installer"
                                print_success "coreos-installer installed from GitHub"
                            else
                                print_error "Failed to download coreos-installer. Please install manually."
                                exit 1
                            fi
                        fi
                        ;;
                    ubuntu|debian)
                        # Download coreos-installer binary
                        print_info "Downloading coreos-installer from GitHub..."
                        execute_remote "curl -L -o /tmp/coreos-installer https://github.com/coreos/coreos-installer/releases/latest/download/coreos-installer" 2>/dev/null || \
                        execute_remote "wget -O /tmp/coreos-installer https://github.com/coreos/coreos-installer/releases/latest/download/coreos-installer" 2>/dev/null
                        if [ $? -eq 0 ]; then
                            execute_remote "sudo mv /tmp/coreos-installer /usr/local/bin/coreos-installer && sudo chmod +x /usr/local/bin/coreos-installer"
                            print_success "coreos-installer installed from GitHub"
                        else
                            print_error "Failed to download coreos-installer. Please install manually."
                            exit 1
                        fi
                        ;;
                    *)
                        print_warning "Unknown OS type. Please install coreos-installer manually:"
                        echo "  Download from: https://github.com/coreos/coreos-installer/releases"
                        exit 1
                        ;;
                esac
            else
                print_error "coreos-installer is required for SNO deployment. Please install it manually."
                exit 1
            fi
        else
            print_error "coreos-installer is required but cannot be installed without sudo. Please install manually."
            exit 1
        fi
    fi

    # Check for podman (required for ISO creation with ignition embedding)
    print_info "Checking for podman..."
    local podman_path=$(execute_remote "command -v podman 2>/dev/null || which podman 2>/dev/null || echo ''" 2>/dev/null || echo "")

    if [ -n "$podman_path" ]; then
        local podman_version=$(execute_remote "$podman_path --version 2>/dev/null" 2>/dev/null || echo "installed")
        print_success "podman is installed: $podman_version at $podman_path"

        # Ensure podman is accessible via full path and create symlink if needed
        # kcli may use non-interactive shells that don't have podman in PATH
        if [ "$podman_path" != "/usr/local/bin/podman" ] && [ "$podman_path" != "/usr/bin/podman" ]; then
            print_info "Creating symlink to ensure podman is accessible..."
            if [ "$has_sudo" = true ]; then
                execute_remote "sudo ln -sf $podman_path /usr/local/bin/podman 2>/dev/null || sudo ln -sf $podman_path /usr/bin/podman 2>/dev/null || true" >/dev/null 2>&1
            fi
        fi

        # Verify podman works in non-interactive shell (like kcli uses)
        # kcli uses non-interactive SSH sessions which may have minimal PATH
        if execute_remote "bash -c 'PATH=/usr/bin:/usr/local/bin:/bin:/usr/sbin:/sbin $podman_path --version >/dev/null 2>&1'" >/dev/null 2>&1; then
            print_success "podman is accessible (with explicit PATH)"
        fi

        # Ensure PATH is set in non-interactive shells for kcli
        # This helps kcli find podman when it SSH's to the remote host
        print_info "Ensuring PATH is set correctly for non-interactive SSH sessions..."
        if [ "$has_sudo" = true ]; then
            # Add PATH to /etc/environment if not already there
            if ! execute_remote "grep -q '^PATH=' /etc/environment 2>/dev/null" >/dev/null 2>&1; then
                execute_remote "echo 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' | sudo tee -a /etc/environment >/dev/null 2>&1" >/dev/null 2>&1 || true
            fi

            # Also ensure root's .bashrc exports PATH (for non-interactive shells that source it)
            if ! execute_remote "grep -q 'export PATH' /root/.bashrc 2>/dev/null" >/dev/null 2>&1; then
                execute_remote "echo 'export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH' | sudo tee -a /root/.bashrc >/dev/null 2>&1" >/dev/null 2>&1 || true
            fi

            print_success "PATH configuration updated for non-interactive shells"
        fi
    else
        print_warning "podman is not found (required for ISO creation with ignition embedding)"
        if [ "$has_sudo" = true ]; then
            read -p "Install podman on target server? (y/n) [y]: " install_podman
            install_podman=${install_podman:-y}
            if [[ "$install_podman" =~ ^[Yy]$ ]]; then
                install_package_remote "podman" || {
                    print_warning "Could not install podman automatically. Continuing anyway..."
                }
                # Verify installation
                podman_path=$(execute_remote "command -v podman 2>/dev/null || which podman 2>/dev/null || echo ''" 2>/dev/null || echo "")
                if [ -n "$podman_path" ]; then
                    print_success "podman installed and found at: $podman_path"
                fi
            else
                print_warning "Skipping podman installation. ISO creation with ignition embedding will fail."
            fi
        else
            print_warning "podman not found and cannot install without sudo. ISO creation may fail."
        fi
    fi

    print_success "Target server prerequisites check completed"
}

# Function to install kcli on hypervisor
install_kcli_on_hypervisor() {
    print_info "Checking for kcli on hypervisor..."

    # Check if kcli already exists
    if execute_remote "command -v kcli >/dev/null 2>&1" >/dev/null 2>&1; then
        local kcli_version=$(execute_remote "kcli version 2>/dev/null || echo 'installed'" 2>/dev/null || echo "installed")
        print_success "kcli already installed on hypervisor: $kcli_version"
        return 0
    fi

    print_info "kcli not found on hypervisor. Installing..."

    # Detect OS type
    local os_type=$(execute_remote "if [ -f /etc/os-release ]; then . /etc/os-release && echo \$ID; else echo 'unknown'; fi" 2>/dev/null || echo "unknown")
    local has_sudo=false
    if execute_remote "sudo -n true" >/dev/null 2>&1; then
        has_sudo=true
    fi

    if [ "$has_sudo" != "true" ]; then
        print_error "Cannot install kcli: no sudo access on hypervisor"
        exit 1
    fi

    # Install Python3 and pip if needed
    print_info "Checking for Python3..."
    if ! execute_remote "command -v python3 >/dev/null 2>&1" >/dev/null 2>&1; then
        print_info "Installing Python3..."
        case "$os_type" in
            fedora|rhel|centos|rocky|almalinux)
                execute_remote "sudo dnf install -y python3 python3-pip" 600 || \
                execute_remote "sudo yum install -y python3 python3-pip" 600
                ;;
            ubuntu|debian)
                execute_remote "sudo DEBIAN_FRONTEND=noninteractive apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-pip" 600
                ;;
            *)
                print_error "Cannot auto-install Python3 on this OS. Please install manually."
                exit 1
                ;;
        esac
    fi

    # Check for pip3 and install if needed
    print_info "Checking for pip3..."
    if ! execute_remote "command -v pip3 >/dev/null 2>&1" >/dev/null 2>&1; then
        print_info "pip3 not found, installing..."
        case "$os_type" in
            fedora|rhel|centos|rocky|almalinux)
                execute_remote "sudo dnf install -y python3-pip" 600 || \
                execute_remote "sudo yum install -y python3-pip" 600 || {
                    # Try alternative: install pip via get-pip.py
                    print_info "Trying alternative pip installation method..."
                    execute_remote "curl -sSL https://bootstrap.pypa.io/get-pip.py | sudo python3" 600 || {
                        print_error "Failed to install pip3"
                        exit 1
                    }
                }
                ;;
            ubuntu|debian)
                execute_remote "sudo DEBIAN_FRONTEND=noninteractive apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3-pip" 600 || {
                    # Try alternative: install pip via get-pip.py
                    print_info "Trying alternative pip installation method..."
                    execute_remote "curl -sSL https://bootstrap.pypa.io/get-pip.py | sudo python3" 600 || {
                        print_error "Failed to install pip3"
                        exit 1
                    }
                }
                ;;
            *)
                print_error "Cannot auto-install pip3 on this OS. Please install manually."
                exit 1
                ;;
        esac
    fi

    # Verify pip3 is available
    if ! execute_remote "command -v pip3 >/dev/null 2>&1" >/dev/null 2>&1; then
        print_error "pip3 is still not available after installation attempt"
        exit 1
    fi

    # Install kcli via pip
    print_info "Installing kcli via pip3..."
    execute_remote "sudo pip3 install kcli" 600 || {
        print_error "Failed to install kcli via pip3"
        print_info "Trying without sudo (user install)..."
        execute_remote "pip3 install --user kcli" 600 || {
            print_error "Failed to install kcli via pip3 (both sudo and user install failed)"
            exit 1
        }
        # Add user's local bin to PATH if needed
        local user_bin_path=$(execute_remote "python3 -m site --user-base 2>/dev/null | xargs -I {} echo {}/bin" 30 2>/dev/null || echo "$HOME/.local/bin")
        if ! execute_remote "echo \$PATH | grep -q $user_bin_path" 30 >/dev/null 2>&1; then
            print_info "Adding $user_bin_path to PATH..."
            execute_remote "echo 'export PATH=\$PATH:$user_bin_path' >> ~/.bashrc" 30 >/dev/null 2>&1 || true
        fi
    }

    # Verify installation
    if execute_remote "command -v kcli >/dev/null 2>&1" >/dev/null 2>&1; then
        local kcli_version=$(execute_remote "kcli version 2>/dev/null || echo 'installed'" 2>/dev/null || echo "installed")
        print_success "kcli installed successfully: $kcli_version"
        print_info "Note: kcli will automatically install openshift-install when needed"
    else
        print_error "kcli installation verification failed"
        exit 1
    fi
}

# Function to update NAT network DHCP range based on SNO count
update_network_dhcp_range() {
    local sno_count=$1
    local net_name="${2:-sno-hypervisor-network}"

    # Reserve VIP IPs for OpenShift: .21 to .(20 + sno_count)
    # These VIPs are used by OpenShift installer for API and ingress VIPs
    local vip_start="192.168.150.21"
    local vip_end="192.168.150.$((20 + sno_count))"

    # DHCP range starts at .100 to avoid any overlap with reserved VIPs
    # This ensures VMs (bootstrap and ctlplane) get IPs from DHCP, not the reserved VIPs
    local dhcp_start="192.168.150.100"
    local dhcp_end="192.168.150.200"

    print_info "Updating DHCP range for $net_name"
    print_info "  Reserved VIP range: $vip_start to $vip_end (for OpenShift API/Ingress VIPs)"
    print_info "  DHCP range: $dhcp_start to $dhcp_end (for VMs: bootstrap and ctlplane)"

    # Update DHCP range using virsh net-update
    local range_xml="<range start='$dhcp_start' end='$dhcp_end'/>"

    # First, try to update the range
    if execute_remote "virsh net-update $net_name modify ip-dhcp-range '$range_xml' --live --config" 60 >/dev/null 2>&1; then
        print_success "DHCP range updated successfully"
        return 0
    else
        # If net-update fails, dump XML, modify, and redefine
        print_info "net-update failed, using XML edit method..."
        local net_xml_path="/tmp/${net_name}-network-update.xml"

        # Dump current network XML
        if execute_remote "virsh net-dumpxml $net_name > $net_xml_path" 60 >/dev/null 2>&1; then
            # Replace the range line
            execute_remote "sed -i \"s|<range start='[^']*' end='[^']*'/>|<range start='$dhcp_start' end='$dhcp_end'/>|\" $net_xml_path" 60 >/dev/null 2>&1

            # Destroy and redefine network
            execute_remote "virsh net-destroy $net_name" 60 >/dev/null 2>&1 || true
            execute_remote "virsh net-undefine $net_name" 60 >/dev/null 2>&1 || true
            execute_remote "virsh net-define $net_xml_path" 60 >/dev/null 2>&1
            execute_remote "virsh net-start $net_name" 60 >/dev/null 2>&1 || true
            execute_remote "virsh net-autostart $net_name" 60 >/dev/null 2>&1 || true

            execute_remote "rm -f $net_xml_path" 30 >/dev/null 2>&1 || true
            print_success "DHCP range updated via XML edit"
            return 0
        else
            print_warning "Could not update DHCP range. VMs may get unpredictable IPs."
            return 1
        fi
    fi
}

# Function to setup HAProxy on hypervisor
setup_haproxy() {
    print_info "=========================================="
    print_info "Setting up HAProxy for SNO access"
    print_info "=========================================="

    # kcli runs on hypervisor, no host_name needed

    # Get OS type and sudo status (needed for installation)
    local os_type=$(execute_remote "if [ -f /etc/os-release ]; then . /etc/os-release && echo \$ID; else echo 'unknown'; fi" 2>/dev/null || echo "unknown")
    local has_sudo=false
    if execute_remote "sudo -n true" >/dev/null 2>&1; then
        has_sudo=true
    fi

    # Check if HAProxy is installed
    if ! execute_remote "command -v haproxy >/dev/null 2>&1" >/dev/null 2>&1; then
        print_info "Installing HAProxy..."
        if [ "$has_sudo" = true ]; then
            case "$os_type" in
                fedora|rhel|centos|rocky|almalinux)
                    # Remove dnf locks
                    execute_remote "sudo rm -f /var/lib/dnf/history.sqlite* /var/lib/rpm/__db* /var/cache/dnf/*.pid /var/run/dnf.pid 2>/dev/null || true" 30
                    execute_remote "sudo pkill -9 dnf || sudo pkill -9 yum || true" 30
                    sleep 2
                    execute_remote "sudo dnf install -y --setopt=timeout=600 haproxy" 600 || \
                    execute_remote "sudo yum install -y haproxy" 600
                    ;;
                ubuntu|debian)
                    execute_remote "sudo rm -f /var/lib/dpkg/lock* /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null || true" 30
                    execute_remote "sudo pkill -9 apt-get || sudo pkill -9 apt || true" 30
                    sleep 2
                    execute_remote "sudo DEBIAN_FRONTEND=noninteractive apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y haproxy" 600
                    ;;
                *)
                    print_error "Cannot auto-install HAProxy on this OS. Please install manually."
                    return 1
                    ;;
            esac
        else
            print_error "Cannot install HAProxy without sudo access"
            return 1
        fi
    fi

    print_success "HAProxy is installed"

    # Generate HAProxy configuration
    print_info "Generating HAProxy configuration..."

    local haproxy_config="/etc/haproxy/haproxy.cfg"
    local haproxy_config_backup="${haproxy_config}.backup.$(date +%Y%m%d_%H%M%S)"

    # Backup existing config if it exists
    execute_remote "sudo cp $haproxy_config $haproxy_config_backup 2>/dev/null || true" >/dev/null 2>&1

    # Build SNI rules and backends for each SNO
    # Each SNO gets its own backend for proper routing
    local api_sni_rules=""
    local console_sni_rules=""
    local oauth_sni_rules=""
    local prometheus_sni_rules=""
    local sno_backends=""
    local domain="${SNO_DOMAIN:-local}"

    for i in $(seq 1 $SNO_COUNT); do
        local vm_name="sno-$(printf "%02d" $i)"
        # Use VIP IP for HAProxy (configured by OpenShift installer)
        local sno_vip="192.168.150.$((20 + i))"

        # Try to get actual VM IP if VM exists (for verification, but HAProxy uses VIP)
        # Retry logic: During deployment, bootstrap VM appears first, then ctlplane VM
        local ctlplane_vm=""
        local max_retries=3
        local retry_count=0

        while [ $retry_count -lt $max_retries ] && [ -z "$ctlplane_vm" ]; do
            # Method 1: Try standard naming patterns (ctlplane or master)
            ctlplane_vm=$(execute_remote "kcli list vm 2>/dev/null | grep -E '^${vm_name}-ctlplane|^${vm_name}-master' | awk '{print \$1}' | head -1" 30 2>/dev/null || echo "")

            # Method 2: If not found, list all VMs and find by cluster name
            if [ -z "$ctlplane_vm" ]; then
                local all_vms=$(execute_remote "kcli list vm 2>/dev/null | grep -E '${vm_name}' | awk '{print \$1}'" 30 2>/dev/null || echo "")
                # Prefer ctlplane/master, exclude bootstrap
                ctlplane_vm=$(echo "$all_vms" | grep -E "ctlplane|master" | grep -v bootstrap | head -1 || echo "")
                if [ -z "$ctlplane_vm" ]; then
                    # Last resort: any VM with the cluster name (not bootstrap)
                    # But only if we've waited a bit (retry_count > 0)
                    if [ $retry_count -gt 0 ]; then
                        ctlplane_vm=$(echo "$all_vms" | grep -v bootstrap | head -1 || echo "")
                    fi
                fi
            fi

            if [ -z "$ctlplane_vm" ] && [ $retry_count -lt $((max_retries - 1)) ]; then
                sleep 2
                retry_count=$((retry_count + 1))
            else
                break
            fi
        done

        if [ -n "$ctlplane_vm" ]; then
            print_info "Found control plane VM for $vm_name: $ctlplane_vm"

            # Get actual IP - try virsh domifaddr first
            local actual_ip=$(execute_remote "virsh domifaddr $ctlplane_vm 2>/dev/null | grep -oP 'ipv4\s+\K[^/ ]+' | head -1" 30 2>/dev/null || echo "")

            # If that fails, try to get from VM's MAC address and DHCP leases
            if [ -z "$actual_ip" ]; then
                # Get VM's MAC address first
                local vm_mac=$(execute_remote "virsh domiflist $ctlplane_vm 2>/dev/null | grep sno-hypervisor-network | awk '{print \$5}' | head -1" 30 2>/dev/null || echo "")
                if [ -n "$vm_mac" ]; then
                    # Look up IP by MAC in DHCP leases
                    actual_ip=$(execute_remote "grep -i '$vm_mac' /var/lib/libvirt/dnsmasq/sno-hypervisor-network.leases 2>/dev/null | tail -1 | awk '{print \$3}'" 30 2>/dev/null || echo "")
                fi
            fi

            # Additional retry for IP detection (VM might not have IP yet)
            if [ -z "$actual_ip" ] && [ $retry_count -lt $max_retries ]; then
                sleep 3
                actual_ip=$(execute_remote "virsh domifaddr $ctlplane_vm 2>/dev/null | grep -oP 'ipv4\s+\K[^/ ]+' | head -1" 30 2>/dev/null || echo "")
            fi

            if [ -n "$actual_ip" ]; then
                print_info "Detected VM IP $actual_ip for $vm_name (VM: $ctlplane_vm)"
                print_info "  Note: HAProxy will use VIP $sno_vip (configured by OpenShift), not VM IP"
            else
                print_warning "Could not detect VM IP for $vm_name (VM: $ctlplane_vm)"
                print_info "  HAProxy will use VIP $sno_vip (configured by OpenShift)"
            fi
        else
            print_warning "Could not find control plane VM for $vm_name yet (may still be deploying)"
            print_info "  HAProxy will use VIP $sno_vip (configured by OpenShift installer)"
        fi

        # Build SNI ACL rules for API server (6443)
        api_sni_rules="${api_sni_rules}    acl ACL_${vm_name} req_ssl_sni -i api.${vm_name}.${domain}
    use_backend be_api_${vm_name}_6443 if ACL_${vm_name}
"

        # Build SNI ACL rules for Console (443)
        console_sni_rules="${console_sni_rules}    acl ACL_${vm_name}_console req_ssl_sni -m reg -i ^[^\.]+\.apps\.${vm_name}\.${domain}
    use_backend be_ingress_${vm_name}_443 if ACL_${vm_name}_console
"

        # Build SNI ACL rules for OAuth (443)
        oauth_sni_rules="${oauth_sni_rules}    acl ACL_${vm_name}_oauth req_ssl_sni -i oauth-openshift.apps.${vm_name}.${domain}
    use_backend be_ingress_${vm_name}_443 if ACL_${vm_name}_oauth
"

        # Build SNI ACL rules for Prometheus (9091) - using hostname pattern
        prometheus_sni_rules="${prometheus_sni_rules}    acl ACL_${vm_name}_prometheus req_ssl_sni -i prometheus-k8s-openshift-monitoring.apps.${vm_name}.${domain}
    use_backend be_prometheus_${vm_name}_9090 if ACL_${vm_name}_prometheus
"

        # Build backends for this SNO - use VIP IP (configured by OpenShift installer)
        sno_backends="${sno_backends}
# Backend for ${vm_name} API Server (using VIP)
backend be_api_${vm_name}_6443
    mode tcp
    balance source
    option ssl-hello-chk
    server master0 ${sno_vip}:6443 check inter 1s

# Backend for ${vm_name} Ingress (Console/OAuth) (using VIP)
backend be_ingress_${vm_name}_443
    mode tcp
    balance source
    option ssl-hello-chk
    server master0 ${sno_vip}:443 check inter 1s

# Backend for ${vm_name} Prometheus (using VIP)
backend be_prometheus_${vm_name}_9090
    mode tcp
    balance source
    option tcp-check
    server master0 ${sno_vip}:9090 check inter 1s
"
    done

    # Generate HAProxy config
    # Note: Not using chroot to avoid permission issues (matching example pattern)
    local haproxy_cfg="global
    log /dev/log local0
    log /dev/log local1 notice
    maxconn 4000
    daemon

defaults
    mode tcp
    log global
    retries 3
    timeout http-request 10s
    timeout queue 1m
    timeout connect 10s
    timeout client 1m
    timeout server 1m
    timeout http-keep-alive 10s
    timeout check 10s
    maxconn 3000

# OpenShift API Server (port 6443) - SNI based routing
frontend apis-6443
    bind ${TARGET_IP}:6443
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
${api_sni_rules}

# OpenShift Console and OAuth (port 443) - SNI based routing
frontend routers-https-443
    bind ${TARGET_IP}:443
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
${console_sni_rules}
${oauth_sni_rules}

# Prometheus (port 9091) - SNI based routing
# Note: Using 9091 instead of 9090 because 9090 is often used by systemd
frontend prometheus-9091
    bind ${TARGET_IP}:9091
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req_ssl_hello_type 1 }
${prometheus_sni_rules}
${sno_backends}

# Stats page (HTTP mode required for stats)
listen stats
    bind ${TARGET_IP}:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 30s
"

    # Write config to remote
    execute_remote "cat > /tmp/haproxy.cfg <<'HAPROXYCFG'
$haproxy_cfg
HAPROXYCFG
" >/dev/null 2>&1

    # Copy to final location
    if execute_remote "sudo cp /tmp/haproxy.cfg $haproxy_config" >/dev/null 2>&1; then
        print_success "HAProxy configuration written"

        # Set capabilities for HAProxy to bind to privileged ports
        print_info "Configuring HAProxy to bind to privileged ports..."

        # First, try to set capabilities
        execute_remote "sudo setcap 'cap_net_bind_service=+ep' /usr/sbin/haproxy" 60 >/dev/null 2>&1

        # Verify capabilities are set
        local caps_set=$(execute_remote "getcap /usr/sbin/haproxy 2>/dev/null | grep -q cap_net_bind_service && echo 'yes' || echo 'no'" 30 2>/dev/null || echo "no")

        if [ "$caps_set" != "yes" ]; then
            print_warning "Capabilities not set. Configuring HAProxy to run as root..."

            # Find and modify systemd service file
            local service_file=$(execute_remote "ls -1 /usr/lib/systemd/system/haproxy.service /etc/systemd/system/haproxy.service 2>/dev/null | head -1" 30 2>/dev/null || echo "")

            if [ -n "$service_file" ]; then
                # Create override directory if it doesn't exist
                execute_remote "sudo mkdir -p /etc/systemd/system/haproxy.service.d" 30 >/dev/null 2>&1 || true

                # Create override file to run as root
                execute_remote "cat > /tmp/haproxy-override.conf <<'OVERRIDEEOF'
[Service]
User=root
Group=root
OVERRIDEEOF
sudo cp /tmp/haproxy-override.conf /etc/systemd/system/haproxy.service.d/override.conf && sudo rm -f /tmp/haproxy-override.conf" 30 >/dev/null 2>&1

                # Also comment out User/Group in main service file if present
                execute_remote "sudo sed -i 's/^User=/#User=/' $service_file" 30 >/dev/null 2>&1 || true
                execute_remote "sudo sed -i 's/^Group=/#Group=/' $service_file" 30 >/dev/null 2>&1 || true

                # Reload systemd
                execute_remote "sudo systemctl daemon-reload" 30 >/dev/null 2>&1 || true
                print_success "Configured HAProxy to run as root (required for privileged ports)"
            else
                print_error "Could not find HAProxy service file. HAProxy may not start correctly."
                print_info "You may need to manually configure HAProxy to run as root or set capabilities."
            fi
        else
            print_success "HAProxy capabilities configured successfully"
        fi

        # Configure SELinux to allow HAProxy to bind to privileged ports
        print_info "Configuring SELinux for HAProxy..."
        if execute_remote "command -v getenforce >/dev/null 2>&1" >/dev/null 2>&1; then
            local selinux_status=$(execute_remote "getenforce 2>/dev/null" 30 2>/dev/null || echo "Disabled")
            if [ "$selinux_status" = "Enforcing" ]; then
                print_info "SELinux is enforcing, configuring ports..."
                # Enable haproxy_connect_any boolean
                execute_remote "setsebool -P haproxy_connect_any on" 30 >/dev/null 2>&1 || true

                # Add ports to SELinux (if semanage is available)
                if execute_remote "command -v semanage >/dev/null 2>&1" >/dev/null 2>&1; then
                    # Add ports to http_port_t (6443, 8404, 9091)
                    execute_remote "semanage port -a -t http_port_t -p tcp 6443 2>/dev/null || semanage port -m -t http_port_t -p tcp 6443 2>/dev/null || true" 30 >/dev/null 2>&1
                    execute_remote "semanage port -a -t http_port_t -p tcp 8404 2>/dev/null || semanage port -m -t http_port_t -p tcp 8404 2>/dev/null || true" 30 >/dev/null 2>&1
                    execute_remote "semanage port -a -t http_port_t -p tcp 9091 2>/dev/null || semanage port -m -t http_port_t -p tcp 9091 2>/dev/null || true" 30 >/dev/null 2>&1
                    print_success "SELinux ports configured"
                else
                    print_warning "semanage not available, SELinux ports may need manual configuration"
                fi
            else
                print_info "SELinux is not enforcing ($selinux_status), skipping SELinux configuration"
            fi
        fi

        # Validate config
        local config_validation=$(execute_remote "sudo haproxy -f $haproxy_config -c 2>&1" 60 2>&1)
        local config_valid=$?

        if [ $config_valid -eq 0 ]; then
            print_success "HAProxy configuration is valid"

            # Enable HAProxy
            execute_remote "sudo systemctl enable haproxy" >/dev/null 2>&1 || true

            # Restart HAProxy
            print_info "Restarting HAProxy service..."
            local restart_output=$(execute_remote "sudo systemctl restart haproxy 2>&1" 60 2>&1)
            local restart_status=$?

            if [ $restart_status -eq 0 ]; then
                # Wait a moment for service to start
                sleep 3

                # Check service status
                local service_status=$(execute_remote "systemctl is-active haproxy 2>/dev/null || echo 'inactive'" 30 2>/dev/null || echo "unknown")

                if [ "$service_status" = "active" ]; then
                    print_success "HAProxy service is running"

                    # Verify HAProxy is actually listening on the ports
                    local listening_ports=$(execute_remote "ss -tlnp 2>/dev/null | grep haproxy | grep -E ':(6443|443|9091|8404)' | awk '{print \$4}' | cut -d: -f2" 30 2>/dev/null || echo "")
                    if [ -n "$listening_ports" ]; then
                        print_info "HAProxy is listening on ports: $(echo $listening_ports | tr '\n' ' ')"
                    fi

                    print_info "HAProxy is configured to listen on ${TARGET_IP} for:"
                    echo "  - API Server: ${TARGET_IP}:6443"
                    echo "  - Console/OAuth: ${TARGET_IP}:443"
                    echo "  - Prometheus: ${TARGET_IP}:9091"
                    echo "  - Stats: ${TARGET_IP}:8404"
                else
                    print_error "HAProxy service is not active (status: $service_status)"
                    print_info "Checking HAProxy service status..."
                    local status_output=$(execute_remote "systemctl status haproxy --no-pager -l 2>&1 | head -20" 30 2>&1 || echo "")
                    if [ -n "$status_output" ]; then
                        echo "$status_output" | sed 's/^/  /'
                    fi
                    print_warning "HAProxy may have failed to start. Check logs: sudo journalctl -u haproxy -n 50"
                fi
            else
                print_error "Failed to restart HAProxy service"
                if [ -n "$restart_output" ]; then
                    echo "$restart_output" | sed 's/^/  /'
                fi
                print_warning "Check HAProxy logs: sudo journalctl -u haproxy -n 50"
            fi
        else
            print_error "HAProxy configuration validation failed!"
            if [ -n "$config_validation" ]; then
                echo "Validation errors:"
                echo "$config_validation" | sed 's/^/  /'
            fi
            print_warning "HAProxy configuration may have syntax errors. Please check manually."
        fi
    else
        print_error "Failed to write HAProxy configuration"
        return 1
    fi

    execute_remote "rm -f /tmp/haproxy.cfg" >/dev/null 2>&1 || true

    echo ""
}

# Function to diagnose and fix HAProxy issues
diagnose_haproxy() {
    local target_ip="${1:-}"
    local user="${2:-root}"
    local password="${3:-}"

    if [ -z "$target_ip" ]; then
        print_error "Usage: $0 --diagnose-haproxy <target_ip> [user] [password]"
        exit 1
    fi

    print_info "=========================================="
    print_info "HAProxy Diagnostic and Fix Tool"
    print_info "=========================================="
    echo ""

    # Function to execute remote command
    local execute_remote_cmd
    if [ -n "$password" ] && [ "$password" != "none" ]; then
        execute_remote_cmd() {
            sshpass -p "$password" ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$user@$target_ip" "$1"
        }
    else
        execute_remote_cmd() {
            ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$user@$target_ip" "$1"
        }
    fi

    print_info "Step 1: Checking HAProxy installation..."
    if execute_remote_cmd "command -v haproxy >/dev/null 2>&1" >/dev/null 2>&1; then
        local haproxy_version=$(execute_remote_cmd "haproxy -v 2>&1 | head -1" 2>/dev/null || echo "unknown")
        print_success "HAProxy is installed: $haproxy_version"
    else
        print_error "HAProxy is not installed!"
        exit 1
    fi
    echo ""

    print_info "Step 2: Checking HAProxy binary location and permissions..."
    local haproxy_bin=$(execute_remote_cmd "which haproxy" 2>/dev/null || echo "/usr/sbin/haproxy")
    print_info "HAProxy binary: $haproxy_bin"

    local file_info=$(execute_remote_cmd "ls -l $haproxy_bin" 2>/dev/null || echo "")
    echo "  $file_info"
    echo ""

    print_info "Step 3: Checking capabilities..."
    local caps=$(execute_remote_cmd "getcap $haproxy_bin 2>/dev/null" 2>/dev/null || echo "none")
    if echo "$caps" | grep -q "cap_net_bind_service"; then
        print_success "Capabilities are set: $caps"
    else
        print_warning "Capabilities NOT set: $caps"
        print_info "Attempting to set capabilities..."
        if execute_remote_cmd "sudo setcap 'cap_net_bind_service=+ep' $haproxy_bin" 2>&1; then
            print_success "Capabilities set successfully"
            local new_caps=$(execute_remote_cmd "getcap $haproxy_bin 2>/dev/null" 2>/dev/null || echo "none")
            print_info "New capabilities: $new_caps"
        else
            print_warning "Failed to set capabilities. Will configure to run as root instead."
        fi
    fi
    echo ""

    print_info "Step 4: Checking systemd service configuration..."
    local service_file=$(execute_remote_cmd "ls -1 /usr/lib/systemd/system/haproxy.service /etc/systemd/system/haproxy.service 2>/dev/null | head -1" 2>/dev/null || echo "")

    if [ -n "$service_file" ]; then
        print_info "Service file: $service_file"

        # Check for override file
        local override_file="/etc/systemd/system/haproxy.service.d/override.conf"
        if execute_remote_cmd "test -f $override_file" >/dev/null 2>&1; then
            print_info "Override file exists: $override_file"
            local override_content=$(execute_remote_cmd "cat $override_file" 2>/dev/null || echo "")
            echo "  Content:"
            echo "$override_content" | sed 's/^/    /'
        else
            print_warning "No override file found. Creating one to run HAProxy as root..."
            execute_remote_cmd "sudo mkdir -p /etc/systemd/system/haproxy.service.d" >/dev/null 2>&1 || true
            execute_remote_cmd "cat > /tmp/haproxy-override.conf <<'OVERRIDEEOF'
[Service]
User=root
Group=root
OVERRIDEEOF
sudo cp /tmp/haproxy-override.conf $override_file && sudo rm -f /tmp/haproxy-override.conf" 2>&1
            if execute_remote_cmd "test -f $override_file" >/dev/null 2>&1; then
                print_success "Override file created successfully"
            else
                print_error "Failed to create override file"
            fi
        fi

        # Check main service file for User/Group
        local user_line=$(execute_remote_cmd "grep '^User=' $service_file 2>/dev/null || echo ''" 2>/dev/null || echo "")
        local group_line=$(execute_remote_cmd "grep '^Group=' $service_file 2>/dev/null || echo ''" 2>/dev/null || echo "")

        if [ -n "$user_line" ] && ! echo "$user_line" | grep -q "^#"; then
            print_warning "Service file has User directive: $user_line"
            print_info "Commenting it out..."
            execute_remote_cmd "sudo sed -i 's/^User=/#User=/' $service_file" >/dev/null 2>&1 || true
        fi

        if [ -n "$group_line" ] && ! echo "$group_line" | grep -q "^#"; then
            print_warning "Service file has Group directive: $group_line"
            print_info "Commenting it out..."
            execute_remote_cmd "sudo sed -i 's/^Group=/#Group=/' $service_file" >/dev/null 2>&1 || true
        fi
    else
        print_error "Could not find HAProxy service file!"
        exit 1
    fi
    echo ""

    print_info "Step 5: Reloading systemd daemon..."
    if execute_remote_cmd "sudo systemctl daemon-reload" 2>&1; then
        print_success "Systemd daemon reloaded"
    else
        print_error "Failed to reload systemd daemon"
    fi
    echo ""

    print_info "Step 6: Checking HAProxy configuration..."
    local haproxy_config="/etc/haproxy/haproxy.cfg"
    if execute_remote_cmd "test -f $haproxy_config" >/dev/null 2>&1; then
        print_info "Configuration file exists: $haproxy_config"
        local config_check=$(execute_remote_cmd "sudo haproxy -f $haproxy_config -c 2>&1" 2>&1)
        if [ $? -eq 0 ]; then
            print_success "Configuration is valid"
        else
            print_error "Configuration has errors:"
            echo "$config_check" | sed 's/^/  /'
        fi
    else
        print_warning "Configuration file not found: $haproxy_config"
    fi
    echo ""

    print_info "Step 7: Checking if ports are already in use..."
    for port in 6443 443 9091 8404; do
        local port_check=$(execute_remote_cmd "ss -tlnp 2>/dev/null | grep ':$port ' || echo ''" 2>/dev/null || echo "")
        if [ -n "$port_check" ]; then
            print_warning "Port $port is in use:"
            echo "  $port_check" | sed 's/^/    /'
        else
            print_info "Port $port is available"
        fi
    done
    echo ""

    print_info "Step 8: Attempting to start HAProxy service..."
    execute_remote_cmd "sudo systemctl stop haproxy" >/dev/null 2>&1 || true
    sleep 2

    local start_output=$(execute_remote_cmd "sudo systemctl start haproxy 2>&1" 2>&1)
    local start_status=$?
    sleep 2

    if [ $start_status -eq 0 ]; then
        local service_status=$(execute_remote_cmd "systemctl is-active haproxy 2>/dev/null || echo 'inactive'" 2>/dev/null || echo "unknown")
        if [ "$service_status" = "active" ]; then
            print_success "HAProxy service is running!"

            # Check if it's listening on the ports
            print_info "Checking listening ports..."
            for port in 6443 443 9091 8404; do
                if execute_remote_cmd "ss -tlnp 2>/dev/null | grep -q ':$port '" >/dev/null 2>&1; then
                    print_success "HAProxy is listening on port $port"
                else
                    print_warning "HAProxy is NOT listening on port $port"
                fi
            done
        else
            print_error "HAProxy service is not active (status: $service_status)"
            local status_output=$(execute_remote_cmd "systemctl status haproxy --no-pager -l 2>&1 | head -30" 2>&1 || echo "")
            if [ -n "$status_output" ]; then
                echo "Service status:"
                echo "$status_output" | sed 's/^/  /'
            fi
        fi
    else
        print_error "Failed to start HAProxy service"
        if [ -n "$start_output" ]; then
            echo "Error output:"
            echo "$start_output" | sed 's/^/  /'
        fi

        # Show recent logs
        print_info "Recent HAProxy logs:"
        local logs=$(execute_remote_cmd "sudo journalctl -u haproxy -n 20 --no-pager 2>&1" 2>&1 || echo "")
        if [ -n "$logs" ]; then
            echo "$logs" | sed 's/^/  /'
        fi
    fi
    echo ""

    print_info "=========================================="
    print_info "Diagnostic Complete"
    print_info "=========================================="
}


# Function to check for OpenShift pull secret and copy to hypervisor
check_pull_secret() {
    local pull_secret_path="${PULL_SECRET_PATH:-$HOME/.pull-secret.json}"

    if [ ! -f "$pull_secret_path" ]; then
        print_warning "OpenShift pull secret not found at $pull_secret_path"
        print_info "You can download it from: https://console.redhat.com/openshift/install/pull-secret"
        read -p "Enter path to pull secret file (or press Enter to skip): " user_path

        if [ -n "$user_path" ] && [ -f "$user_path" ]; then
            PULL_SECRET_PATH="$user_path"
            print_success "Using pull secret: $PULL_SECRET_PATH"
        else
            print_error "Pull secret is required for OpenShift deployment"
            exit 1
        fi
    else
        PULL_SECRET_PATH="$pull_secret_path"
        print_success "Found pull secret: $PULL_SECRET_PATH"
    fi

    # Copy pull secret to hypervisor
    print_info "Copying pull secret to hypervisor..."
    local remote_pull_secret="/tmp/pull-secret.json"

    # Read pull secret content and copy to hypervisor
    if [ -n "$PASSWORD" ] && [ "$PASSWORD" != "none" ]; then
        sshpass -p "$PASSWORD" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "$PULL_SECRET_PATH" "$USER@$TARGET_IP:$remote_pull_secret" >/dev/null 2>&1 || {
            print_error "Failed to copy pull secret to hypervisor"
            exit 1
        }
    else
        scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            "$PULL_SECRET_PATH" "$USER@$TARGET_IP:$remote_pull_secret" >/dev/null 2>&1 || {
            print_error "Failed to copy pull secret to hypervisor"
            exit 1
        }
    fi

    # Set the remote path for use in deployment
    PULL_SECRET_PATH="$remote_pull_secret"
    print_success "Pull secret copied to hypervisor: $remote_pull_secret"
}

# Function to create VM from generated ISO
create_vm_from_iso() {
    local vm_name=$1
    local host_name=$2
    local memory=$3
    local numcpus=$4
    local disk_size=$5

    print_info "Creating VM $vm_name from generated ISO..."

    # Check if VM already exists (on hypervisor)
    if execute_remote "kcli list vm 2>/dev/null | grep -q '^$vm_name'" 30 >/dev/null 2>&1; then
        print_info "VM $vm_name already exists, skipping creation"
        return 0
    fi

    # Find the ISO file - kcli stores it in the pool
    # The ISO name should be ${vm_name}-sno.iso
    local iso_name="${vm_name}-sno.iso"

    # Try to find ISO location on remote host
    print_info "Looking for ISO file: $iso_name"
    local iso_path=$(execute_remote "find /var/lib/libvirt/images -name '$iso_name' 2>/dev/null | head -1" 2>/dev/null || echo "")

    if [ -z "$iso_path" ]; then
        # Try default pool location
        iso_path="/var/lib/libvirt/images/$iso_name"
        print_info "Assuming ISO at: $iso_path"
    else
        print_success "Found ISO at: $iso_path"
    fi

    # Create VM using kcli with ISO
    print_info "Creating VM with kcli..."
    local create_output
    create_output=$(execute_remote "kcli create vm -P memory=$memory -P numcpus=$numcpus -P disksize=$disk_size -P iso=$iso_name $vm_name" 300 2>&1)
    local create_exit=$?

    if [ $create_exit -eq 0 ]; then
        print_success "VM $vm_name created successfully using kcli"
        return 0
    fi

    # If kcli failed, try using virt-install on remote host
    print_info "kcli VM creation failed, trying virt-install on remote host..."

    # Check if virt-install is available
    if ! execute_remote "command -v virt-install >/dev/null 2>&1" >/dev/null 2>&1; then
        print_warning "virt-install not available on remote host"
        print_info "Installing virt-install..."
        # Remove package manager locks
        execute_remote "sudo rm -f /var/lib/dnf/history.sqlite* /var/lib/rpm/__db* /var/cache/dnf/*.pid /var/run/dnf.pid /var/lib/dpkg/lock* /var/cache/apt/archives/lock /var/lib/apt/lists/lock 2>/dev/null || true" 30
        execute_remote "sudo pkill -9 dnf || sudo pkill -9 yum || sudo pkill -9 apt-get || sudo pkill -9 apt || true" 30
        sleep 2
        if execute_remote "sudo dnf install -y --setopt=timeout=600 virt-install" 600 >/dev/null 2>&1 || \
           execute_remote "sudo yum install -y virt-install" 600 >/dev/null 2>&1 || \
           execute_remote "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y virtinst" 600 >/dev/null 2>&1; then
            print_success "virt-install installed"
        else
            print_error "Could not install virt-install. Please create VM manually."
            return 1
        fi
    fi

    # Create VM using virt-install
    print_info "Creating VM using virt-install..."
    local virt_cmd="sudo virt-install \
        --name $vm_name \
        --memory $memory \
        --vcpus $numcpus \
        --disk size=$disk_size,pool=default \
        --cdrom $iso_path \
        --network network=sno-hypervisor-network \
        --graphics none \
        --console pty,target_type=serial \
        --noautoconsole \
        --wait -1" 2>/dev/null

    if execute_remote "$virt_cmd" >/dev/null 2>&1; then
        print_success "VM $vm_name created using virt-install"
        return 0
    else
        print_warning "Could not automatically create VM. Manual creation required:"
        echo ""
        echo "  Option 1 (kcli):"
        echo "    ssh $USER@$TARGET_IP 'kcli create vm -P iso=$iso_name -P memory=$memory -P numcpus=$numcpus -P disksize=$disk_size $vm_name'"
        echo ""
        echo "  Option 2 (virt-install on remote):"
        echo "    ssh $USER@$TARGET_IP 'sudo virt-install --name $vm_name --memory $memory --vcpus $numcpus --disk size=$disk_size,pool=default --cdrom $iso_path --network network=sno-hypervisor-network --graphics none --console pty,target_type=serial --noautoconsole'"
        return 1
    fi
}

# Function to cleanup existing assets for a cluster
cleanup_cluster_assets() {
    local vm_name=$1
    local host_name=$2

    print_info "Cleaning up existing assets for $vm_name..."

    # Delete VM if it exists (on hypervisor)
    if execute_remote "kcli list vm 2>/dev/null | grep -q '^$vm_name'" 30 >/dev/null 2>&1; then
        print_info "Deleting existing VM: $vm_name"
        execute_remote "kcli delete vm $vm_name -y" 60 >/dev/null 2>&1 || true
        sleep 3  # Give it a moment to delete and clean up
    fi

    # Also try to delete via virsh if it still exists
    if execute_remote "virsh dominfo $vm_name >/dev/null 2>&1" >/dev/null 2>&1; then
        print_info "VM still exists in virsh, forcing deletion..."
        execute_remote "virsh destroy $vm_name" >/dev/null 2>&1 || true
        execute_remote "virsh undefine $vm_name --remove-all-storage" >/dev/null 2>&1 || true
        sleep 2
    fi

    # Delete ISO files from remote pool
    local iso_name="${vm_name}-sno.iso"
    print_info "Checking for existing ISO: $iso_name"

    # Check if ISO exists in pool and delete it
    if execute_remote "virsh vol-info $iso_name default >/dev/null 2>&1" >/dev/null 2>&1; then
        print_info "Deleting existing ISO from pool: $iso_name"
        execute_remote "virsh vol-delete $iso_name default" >/dev/null 2>&1 || true
    fi

    # Delete ISO file directly if it exists (in case it's not in the pool)
    if execute_remote "test -f /var/lib/libvirt/images/$iso_name" >/dev/null 2>&1; then
        print_info "Deleting ISO file: /var/lib/libvirt/images/$iso_name"
        execute_remote "rm -f /var/lib/libvirt/images/$iso_name" >/dev/null 2>&1 || true
    fi

    # Delete any disk volumes associated with the VM
    local disk_pattern="${vm_name}"
    local volumes=$(execute_remote "virsh vol-list default 2>/dev/null | grep '$disk_pattern' | awk '{print \$1}'" 2>/dev/null || echo "")
    if [ -n "$volumes" ]; then
        print_info "Deleting associated disk volumes..."
        for vol in $volumes; do
            if [ "$vol" != "$iso_name" ]; then  # Don't delete ISO again
                print_info "  Deleting volume: $vol"
                execute_remote "virsh vol-delete $vol default" >/dev/null 2>&1 || true
            fi
        done
    fi

    # Also delete disk image files directly (qcow2/img files) in case they're not in the pool
    print_info "Deleting disk image files (.img, .qcow2) for $vm_name..."
    execute_remote "rm -f /var/lib/libvirt/images/${vm_name}*.img /var/lib/libvirt/images/${vm_name}*.qcow2 /var/lib/libvirt/images/${vm_name}-*.img /var/lib/libvirt/images/${vm_name}-*.qcow2" >/dev/null 2>&1 || true
    # Also clean up bootstrap and ctlplane disk images
    execute_remote "rm -f /var/lib/libvirt/images/${vm_name}-bootstrap*.img /var/lib/libvirt/images/${vm_name}-bootstrap*.qcow2" >/dev/null 2>&1 || true
    execute_remote "rm -f /var/lib/libvirt/images/${vm_name}-ctlplane*.img /var/lib/libvirt/images/${vm_name}-ctlplane*.qcow2" >/dev/null 2>&1 || true

    # Clean up cluster directory on hypervisor (kcli stores configs and state there)
    # This is CRITICAL - kcli checks .openshift_install_state.json and may skip steps if it exists
    # The state file can be 2MB+ and contains deployment state that confuses kcli
    print_info "Removing cluster directory on hypervisor: ~/.kcli/clusters/$vm_name"
    print_info "  (This includes .openshift_install_state.json which can cause kcli to skip deployment)"
    execute_remote "rm -rf ~/.kcli/clusters/$vm_name" 30 >/dev/null 2>&1 || true
    print_success "Removed cluster directory on hypervisor: ~/.kcli/clusters/$vm_name"

    # Also check for any related files in the clusters directory root on hypervisor
    for file in "${vm_name}-sno.ign" "${vm_name}.ign" "iso.ign"; do
        if execute_remote "test -f ~/.kcli/clusters/$file" 30 >/dev/null 2>&1; then
            print_info "Removing ignition file: ~/.kcli/clusters/$file"
            execute_remote "rm -f ~/.kcli/clusters/$file" 30 >/dev/null 2>&1 || true
        fi
    done

    # Clean up any temporary parameter files
    if [ -f "/tmp/kcli-${vm_name}-params.yml" ]; then
        print_info "Removing parameter file: /tmp/kcli-${vm_name}-params.yml"
        rm -f "/tmp/kcli-${vm_name}-params.yml" || true
    fi

    # Clean up any log files from previous runs
    if [ -f "/tmp/kcli-${vm_name}.log" ]; then
        print_info "Removing previous log file: /tmp/kcli-${vm_name}.log"
        rm -f "/tmp/kcli-${vm_name}.log" || true
    fi

    # Verify cleanup was successful
    if execute_remote "test -d ~/.kcli/clusters/$vm_name" 30 >/dev/null 2>&1; then
        print_warning "Cluster directory still exists on hypervisor after cleanup attempt: ~/.kcli/clusters/$vm_name"
        print_info "Attempting force removal..."
        execute_remote "rm -rf ~/.kcli/clusters/$vm_name" 30 >/dev/null 2>&1 || {
            print_error "Could not remove cluster directory. You may need to remove it manually:"
            echo "  ssh $USER@$TARGET_IP 'rm -rf ~/.kcli/clusters/$vm_name'"
        }
    fi

    # Also check for any other related files
    local iso_ign="${vm_name}-sno.ign"
    if execute_remote "test -f /var/lib/libvirt/images/$iso_ign" >/dev/null 2>&1; then
        print_info "Deleting ignition file: $iso_ign"
        execute_remote "rm -f /var/lib/libvirt/images/$iso_ign" >/dev/null 2>&1 || true
    fi

    # Clean up any temporary files
    if execute_remote "test -f /tmp/${vm_name}*" >/dev/null 2>&1; then
        print_info "Cleaning up temporary files for $vm_name"
        execute_remote "rm -f /tmp/${vm_name}*" >/dev/null 2>&1 || true
    fi

    print_success "Cleanup completed for $vm_name"
}

# Function to deploy a single SNO VM
deploy_sno_vm() {
    local vm_index=$1
    local vm_name="sno-$(printf "%02d" $vm_index)"

    print_info "Deploying SNO VM: $vm_name (${vm_index}/${SNO_COUNT})"

    # Cleanup any existing assets first (before deployment)
    # Note: cleanup_cluster_assets expects host_name but we don't use it anymore
    cleanup_cluster_assets "$vm_name" ""

    # SNO deployment parameters
    local memory="${SNO_MEMORY:-24576}"      # 24GB default
    local numcpus="${SNO_CPUS:-8}"           # 8 CPUs default
    local disk_size="${SNO_DISK_SIZE:-120}"  # 120GB default
    local version="${OCP_VERSION:-stable}"   # OpenShift version (kcli will auto-detect)
    local domain="${SNO_DOMAIN:-local}"      # Domain for cluster

    # Calculate VIP IP for this SNO (reserved for OpenShift API/Ingress VIPs)
    # VIP IPs: 192.168.150.21, 192.168.150.22, etc. (starting from .21)
    # These are reserved and will be configured by OpenShift installer
    local vip_ip="192.168.150.$((20 + vm_index))"

    print_info "VM Configuration:"
    echo "  Name: $vm_name"
    echo "  Memory: ${memory}MB"
    echo "  CPUs: $numcpus"
    echo "  Disk: ${disk_size}GB"
    echo "  OpenShift Version: $version"
    echo "  Domain: $domain"
    echo "  Reserved VIP IP: $vip_ip (configured via api_ip parameter)"
    echo "  Note: VMs will get IPs from DHCP range (.100-.200), VIP is separate"

    # Store VIP IP for HAProxy configuration
    echo "$vip_ip" > "/tmp/kcli-${vm_name}.vip"

    # Log file on hypervisor
    local remote_log_file="/tmp/kcli-${vm_name}.log"
    local local_log_file="/tmp/kcli-${vm_name}.log"

    # Use custom NAT network
    local network_param="-P network=sno-hypervisor-network"

    print_info "Starting deployment (this may take a few moments to initiate)..."
    print_info "Using NAT network: sno-hypervisor-network"
    print_info "Reserved VIP IP: $vip_ip (will be configured via api_ip parameter)"
    print_info "Note: kcli runs on hypervisor, architecture will match hypervisor automatically"

    # Build kcli command to run on hypervisor
    # The VIP IP is passed via api_ip parameter to configure OpenShift API endpoint
    local deploy_cmd="kcli create kube openshift \
        -P ctlplanes=1 \
        -P workers=0 \
        -P pull_secret=$PULL_SECRET_PATH \
        -P cluster=$vm_name \
        -P domain=$domain \
        -P api_ip=$vip_ip \
        -P ctlplane_memory=$memory \
        -P numcpus=$numcpus \
        -P disk_size=$disk_size \
        $network_param \
        $vm_name"

    print_info "Deployment command (on hypervisor): $deploy_cmd"

    # Execute deployment on hypervisor and save to log file
    # Run in background for parallel execution
    (
        # Start kcli deployment on hypervisor in background
        execute_remote "$deploy_cmd > $remote_log_file 2>&1" 3600 &
        local kcli_pid=$!

        # Periodically copy log file from hypervisor to local machine
        while kill -0 $kcli_pid 2>/dev/null; do
            sleep 5
            # Copy log file from hypervisor
            if [ -n "$PASSWORD" ] && [ "$PASSWORD" != "none" ]; then
                sshpass -p "$PASSWORD" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                    "$USER@$TARGET_IP:$remote_log_file" "$local_log_file" >/dev/null 2>&1 || true
            else
                scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                    "$USER@$TARGET_IP:$remote_log_file" "$local_log_file" >/dev/null 2>&1 || true
            fi
        done

        # Wait for kcli to finish
        wait $kcli_pid
        local exit_code=$?

        # Final log copy
        if [ -n "$PASSWORD" ] && [ "$PASSWORD" != "none" ]; then
            sshpass -p "$PASSWORD" scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                "$USER@$TARGET_IP:$remote_log_file" "$local_log_file" >/dev/null 2>&1 || true
        else
            scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                "$USER@$TARGET_IP:$remote_log_file" "$local_log_file" >/dev/null 2>&1 || true
        fi

        echo $exit_code > "/tmp/kcli-${vm_name}.exit"
    ) &

    local deployment_pid=$!
    echo "$deployment_pid" > "/tmp/kcli-${vm_name}.pid"

    print_success "Deployment started in background (PID: $deployment_pid)"
    print_info "Log file (local): $local_log_file"
    print_info "Log file (remote): $remote_log_file"
    print_info "Reserved VIP IP: $vip_ip (configured via api_ip parameter)"
    print_info "Note: VIP is configured via api_ip parameter, HAProxy will use VIP"

    # Return immediately for parallel execution
    return 0
}

# Function to update /etc/hosts on local machine
update_local_hosts_file() {
    local sno_count=$1
    local target_ip=$2
    local domain="${SNO_DOMAIN:-local}"

    print_info "=========================================="
    print_info "Updating /etc/hosts on local machine"
    print_info "=========================================="

    local hosts_file="/etc/hosts"
    local hosts_backup="${hosts_file}.backup.$(date +%Y%m%d_%H%M%S)"

    # Check if we can write to /etc/hosts
    if [ ! -w "$hosts_file" ]; then
        # Try with sudo
        if command_exists sudo && sudo -n true 2>/dev/null; then
            local sudo_cmd="sudo"
        else
            print_warning "Cannot update /etc/hosts: no write permission and sudo not available"
            print_info "You will need to manually update /etc/hosts with these entries:"
            echo ""
            for i in $(seq 1 $sno_count); do
                local vm_name="sno-$(printf "%02d" $i)"
                echo "$target_ip api.${vm_name}.${domain} console-openshift-console.apps.${vm_name}.${domain} oauth-openshift.apps.${vm_name}.${domain} prometheus-k8s-openshift-monitoring.apps.${vm_name}.${domain}"
            done
            echo ""
            return 1
        fi
    else
        local sudo_cmd=""
    fi

    # Create backup
    print_info "Creating backup of $hosts_file..."
    $sudo_cmd cp "$hosts_file" "$hosts_backup" 2>/dev/null || {
        print_error "Failed to create backup of $hosts_file"
        return 1
    }
    print_success "Backup created: $hosts_backup"

    # Remove existing entries for SNO hostnames (regardless of IP)
    print_info "Removing existing SNO entries from $hosts_file..."
    local temp_hosts=$(mktemp)

    # Filter out existing SNO entries - match any line containing SNO hostnames
    # This removes entries added by kcli (which might have NAT IPs) or previous script runs
    $sudo_cmd grep -v -E "(api\.sno-[0-9]+\.${domain}|console-openshift-console\.apps\.sno-[0-9]+\.${domain}|oauth-openshift\.apps\.sno-[0-9]+\.${domain}|prometheus-k8s-openshift-monitoring\.apps\.sno-[0-9]+\.${domain})" "$hosts_file" > "$temp_hosts" 2>/dev/null || {
        print_warning "Could not filter existing entries, proceeding anyway..."
        $sudo_cmd cp "$hosts_backup" "$temp_hosts"
    }

    # Add new entries
    print_info "Adding new SNO entries pointing to hypervisor ($target_ip)..."
    echo "" >> "$temp_hosts"
    echo "# SNO clusters via HAProxy on hypervisor (added by install-sno.sh)" >> "$temp_hosts"
    echo "# Updated: $(date)" >> "$temp_hosts"

    for i in $(seq 1 $sno_count); do
        local vm_name="sno-$(printf "%02d" $i)"
        echo "$target_ip api.${vm_name}.${domain} console-openshift-console.apps.${vm_name}.${domain} oauth-openshift.apps.${vm_name}.${domain} prometheus-k8s-openshift-monitoring.apps.${vm_name}.${domain}" >> "$temp_hosts"
    done

    # Replace /etc/hosts
    $sudo_cmd cp "$temp_hosts" "$hosts_file" 2>/dev/null || {
        print_error "Failed to update $hosts_file"
        rm -f "$temp_hosts"
        return 1
    }

    rm -f "$temp_hosts"
    print_success "Updated $hosts_file with SNO hostnames pointing to $target_ip"

    # Display what was added
    print_info "Added entries:"
    for i in $(seq 1 $sno_count); do
        local vm_name="sno-$(printf "%02d" $i)"
        echo "  $target_ip -> api.${vm_name}.${domain}, console-openshift-console.apps.${vm_name}.${domain}, oauth-openshift.apps.${vm_name}.${domain}, prometheus-k8s-openshift-monitoring.apps.${vm_name}.${domain}"
    done
    echo ""

    return 0
}

# Function to wait for cluster to be ready (optional)
wait_for_cluster() {
    local vm_name=$1
    local max_wait=${CLUSTER_WAIT_TIME:-3600}  # 1 hour default
    local elapsed=0
    local interval=60  # Check every minute

    print_info "Waiting for cluster $vm_name to be ready (this may take 30-60 minutes)..."

    while [ $elapsed -lt $max_wait ]; do
        if execute_remote "kcli ssh -u root $vm_name 'oc get nodes'" 30 >/dev/null 2>&1; then
            print_success "Cluster $vm_name is ready!"
            return 0
        fi

        print_info "Still waiting... (${elapsed}s / ${max_wait}s)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    print_warning "Cluster $vm_name may not be fully ready yet. Check manually with:"
    echo "  ssh $USER@$TARGET_IP 'kcli ssh -u root $vm_name \"oc get nodes\"'"
}

# Main execution
main() {
    print_info "=========================================="
    print_info "Single Node OpenShift Deployment Script"
    print_info "=========================================="
    echo ""

    # Validate inputs
    validate_inputs "$@"

    # Check prerequisites
    check_prerequisites

    # Test SSH connection
    test_ssh_connection

    # Check and install prerequisites on target server
    check_target_server_prerequisites

    # Install kcli on hypervisor
    install_kcli_on_hypervisor

    # Check for pull secret
    check_pull_secret

    # Update NAT network DHCP range based on SNO count
    # This ensures predictable IP assignment: first VM gets .21, second gets .22, etc.
    print_info "Updating NAT network DHCP range for $SNO_COUNT SNOs..."
    update_network_dhcp_range "$SNO_COUNT" "sno-hypervisor-network"
    echo ""

    # Setup HAProxy for SNO access (after we know SNO_COUNT)
    # Note: HAProxy will be updated after VMs are created with actual IPs
    setup_haproxy

    # Display network configuration information
    print_info "=========================================="
    print_info "Network Configuration"
    print_info "=========================================="
    print_info "Target Hypervisor: $TARGET_IP"
    print_info "NAT Network: sno-hypervisor-network (192.168.150.0/24)"
    print_info ""
    print_info "SNO VIP Assignments (NAT network):"
    echo ""
    echo "  +--------+------------------+"
    echo "  |  SNO   |  Reserved VIP   |"
    echo "  +--------+------------------+"
    echo ""
    print_info "Reserved VIP Range: 192.168.150.21 to 192.168.150.$((20 + SNO_COUNT))"
    print_info "  (1 VIP per SNO: configured via api_ip parameter for API/Ingress)"
    print_info "DHCP Range: 192.168.150.100 to 192.168.150.200"
    print_info "  (VMs get IPs from DHCP: bootstrap and ctlplane VMs)"
    echo ""
    for i in $(seq 1 $SNO_COUNT); do
        local vm_name="sno-$(printf "%02d" $i)"
        local vip_ip="192.168.150.$((20 + i))"
        printf "  | %-6s | %-16s |\n" "$vm_name" "$vip_ip"
    done
    echo "  +--------+------------------+"
    echo ""
    print_info "Note: VIPs are reserved and configured via api_ip parameter"
    print_info "      HAProxy will route to VIPs, not VM IPs"
    echo ""
    print_info "Access via HAProxy on hypervisor:"
    echo "  - API Server: ${TARGET_IP}:6443"
    echo "  - Console: ${TARGET_IP}:443 (SNI-based routing)"
    echo "  - Prometheus: ${TARGET_IP}:9090"
    echo ""

    # Deploy SNO VMs in parallel
    print_info "Starting parallel deployment of $SNO_COUNT SNO VMs..."
    echo ""

    local deployment_pids=()
    local vm_names=()

    # Start all deployments in parallel
    for i in $(seq 1 $SNO_COUNT); do
        local vm_name="sno-$(printf "%02d" $i)"
        vm_names+=("$vm_name")

        if deploy_sno_vm $i; then
            local pid=$(cat "/tmp/kcli-${vm_name}.pid" 2>/dev/null || echo "")
            if [ -n "$pid" ]; then
                deployment_pids+=("$pid")
                print_info "Started deployment for $vm_name (PID: $pid)"
            fi
        else
            print_error "Failed to start deployment for $vm_name"
        fi
        echo ""
    done

    # Update /etc/hosts on local machine to point SNO hostnames to hypervisor IP
    # This ensures kcli and other tools can access the clusters via HAProxy
    print_info "Updating /etc/hosts on local machine..."
    update_local_hosts_file "$SNO_COUNT" "$TARGET_IP"
    echo ""

    # Wait for all deployments to complete and collect results
    print_info "Waiting for all deployments to complete..."
    print_info "You can monitor progress by checking log files:"
    for vm_name in "${vm_names[@]}"; do
        echo "  tail -f /tmp/kcli-${vm_name}.log"
    done
    echo ""

    local failed_deployments=0
    local successful_deployments=0
    local vip_assignments=()

    # Wait for all background processes
    for vm_name in "${vm_names[@]}"; do
        local pid_file="/tmp/kcli-${vm_name}.pid"
        local exit_file="/tmp/kcli-${vm_name}.exit"
        local vip_file="/tmp/kcli-${vm_name}.vip"

        if [ -f "$pid_file" ]; then
            local pid=$(cat "$pid_file")
            print_info "Waiting for $vm_name (PID: $pid)..."

            # Wait for process to complete
            wait "$pid" 2>/dev/null || true

            # Check exit code
            if [ -f "$exit_file" ]; then
                local exit_code=$(cat "$exit_file")
                if [ "$exit_code" = "0" ]; then
                    successful_deployments=$((successful_deployments + 1))
                    print_success "$vm_name deployment completed successfully"

                    # Get VIP IP (reserved for OpenShift, configured by installer)
                    local vip_ip=""
                    if [ -f "$vip_file" ]; then
                        vip_ip=$(cat "$vip_file")
                    fi

                    # Find actual control plane VM and its IP (for informational purposes)
                    # kcli creates VMs like: sno-01-ctlplane-0, sno-01-bootstrap, etc.
                    local actual_vm_name=""
                    local actual_vm_ip=""

                    # Method 1: Try standard naming patterns
                    local ctlplane_vm=$(execute_remote "kcli list vm 2>/dev/null | grep -E '^${vm_name}-ctlplane|^${vm_name}-master' | awk '{print \$1}' | head -1" 30 2>/dev/null || echo "")

                    # Method 2: If not found, list all VMs and find by cluster name
                    if [ -z "$ctlplane_vm" ]; then
                        local all_vms=$(execute_remote "kcli list vm 2>/dev/null | grep -E '${vm_name}' | awk '{print \$1}'" 30 2>/dev/null || echo "")
                        # Prefer ctlplane/master, exclude bootstrap
                        ctlplane_vm=$(echo "$all_vms" | grep -E "ctlplane|master" | grep -v bootstrap | head -1 || echo "")
                        if [ -z "$ctlplane_vm" ]; then
                            # Last resort: any VM with the cluster name (not bootstrap)
                            ctlplane_vm=$(echo "$all_vms" | grep -v bootstrap | head -1 || echo "")
                        fi
                    fi

                    if [ -n "$ctlplane_vm" ]; then
                        actual_vm_name="$ctlplane_vm"
                        print_info "  Found control plane VM: $ctlplane_vm"

                        # Get actual VM IP (for informational purposes only - HAProxy uses VIP)
                        sleep 2  # Give VM a moment to get IP
                        actual_vm_ip=$(execute_remote "virsh domifaddr $ctlplane_vm 2>/dev/null | grep -oP 'ipv4\s+\K[^/ ]+' | head -1" 30 2>/dev/null || echo "")

                        # If that fails, try to get from VM's MAC address and DHCP leases
                        if [ -z "$actual_vm_ip" ]; then
                            # Get VM's MAC address first
                            local vm_mac=$(execute_remote "virsh domiflist $ctlplane_vm 2>/dev/null | grep sno-hypervisor-network | awk '{print \$5}' | head -1" 30 2>/dev/null || echo "")
                            if [ -n "$vm_mac" ]; then
                                print_info "  VM MAC: $vm_mac, checking DHCP leases..."
                                # Look up IP by MAC in DHCP leases
                                actual_vm_ip=$(execute_remote "grep -i '$vm_mac' /var/lib/libvirt/dnsmasq/sno-hypervisor-network.leases 2>/dev/null | tail -1 | awk '{print \$3}'" 30 2>/dev/null || echo "")
                            fi
                        fi

                        # Last resort: check all VMs on the network and match by VM name pattern
                        if [ -z "$actual_vm_ip" ]; then
                            print_info "  Checking all VMs on network for IP assignment..."
                            local vm_list=$(execute_remote "for dom in \$(virsh list --name | grep ${vm_name} | grep -v bootstrap); do ip=\$(virsh domifaddr \$dom 2>/dev/null | grep -oP 'ipv4\s+\K[^/ ]+' | head -1); [ -n \"\$ip\" ] && echo \"\$dom:\$ip\"; done" 60 2>/dev/null || echo "")
                            actual_vm_ip=$(echo "$vm_list" | grep -E "${vm_name}" | grep -v bootstrap | cut -d: -f2 | head -1 || echo "")
                        fi
                    fi

                    # Use VIP IP for HAProxy (configured via api_ip parameter)
                    if [ -n "$vip_ip" ]; then
                        print_info "  Reserved VIP IP: $vip_ip (configured via api_ip parameter)"
                        if [ -n "$actual_vm_ip" ]; then
                            print_info "  Actual VM IP: $actual_vm_ip (from DHCP, informational only)"
                            print_info "  Note: HAProxy routes to VIP, not VM IP"
                        fi
                        vip_assignments+=("$vm_name:$vip_ip")
                    else
                        print_warning "  Could not determine VIP IP"
                        if [ -n "$actual_vm_ip" ]; then
                            print_warning "  Using VM IP $actual_vm_ip as fallback (VIP should be configured)"
                            vip_assignments+=("$vm_name:$actual_vm_ip")
                        fi
                    fi
                else
                    failed_deployments=$((failed_deployments + 1))
                    print_error "$vm_name deployment failed (exit code: $exit_code)"
                    print_info "  Check log: /tmp/kcli-${vm_name}.log"
                fi
            else
                print_warning "$vm_name deployment status unknown"
            fi

            # Clean up PID and exit files
            rm -f "$pid_file" "$exit_file"
        fi
    done

    # Update HAProxy with actual VM IPs after all deployments
    if [ $successful_deployments -gt 0 ]; then
        print_info "Updating HAProxy configuration with actual VM IPs..."
        setup_haproxy
    fi

    # Summary
    print_info "=========================================="
    print_info "Deployment Summary"
    print_info "=========================================="
    print_success "Successful deployments: $successful_deployments"
    if [ $failed_deployments -gt 0 ]; then
        print_error "Failed deployments: $failed_deployments"
    fi
    echo ""

    # Display VIP assignments and generate /etc/hosts entries
    if [ ${#vip_assignments[@]} -gt 0 ]; then
        print_info "VIP IP Assignments (configured via api_ip parameter):"
        for assignment in "${vip_assignments[@]}"; do
            local vm=$(echo "$assignment" | cut -d: -f1)
            local vip_ip=$(echo "$assignment" | cut -d: -f2)
            echo "  $vm -> $vip_ip (VIP, configured by OpenShift)"
        done
        echo ""
        print_info "=========================================="
        print_info "Add these entries to /etc/hosts on your laptop:"
        print_info "=========================================="
        echo ""
        echo "# SNO clusters via HAProxy on hypervisor"
        for assignment in "${vip_assignments[@]}"; do
            local vm=$(echo "$assignment" | cut -d: -f1)
            local domain="${SNO_DOMAIN:-local}"
            echo "${TARGET_IP} api.${vm}.${domain} console-openshift-console.apps.${vm}.${domain} oauth-openshift.apps.${vm}.${domain} prometheus-k8s-openshift-monitoring.apps.${vm}.${domain}"
        done
        echo ""
        print_info "Access clusters via HAProxy on hypervisor ($TARGET_IP):"
        for assignment in "${vip_assignments[@]}"; do
            local vm=$(echo "$assignment" | cut -d: -f1)
            local domain="${SNO_DOMAIN:-local}"
            echo "  - $vm:"
            echo "    API: https://api.${vm}.${domain}:6443"
            echo "    Console: https://console-openshift-console.apps.${vm}.${domain}"
            echo "    OAuth: https://oauth-openshift.apps.${vm}.${domain}"
        done
        echo ""
    fi

    # List deployed VMs on the remote host
    print_info "Deployed VMs on $TARGET_IP:"
    local existing_vms=$(execute_remote "kcli list vm 2>/dev/null | grep -E '^sno-' | awk '{print \$1}'" 30 2>/dev/null || echo "")

    if [ -n "$existing_vms" ]; then
        print_success "VMs found on remote host:"
        echo "$existing_vms" | sed 's/^/  - /'
    else
        print_warning "No SNO VMs found in list"

        # Check if ISOs exist but VMs don't (ISOs were generated but VMs not created)
        print_info "Checking for generated ISOs that need VMs created..."
        local missing_vms=""
        for i in $(seq 1 $SNO_COUNT); do
            local vm_name="sno-$(printf "%02d" $i)"
            local iso_name="${vm_name}-sno.iso"

            # Check if ISO exists on remote
            if execute_remote "test -f /var/lib/libvirt/images/$iso_name" >/dev/null 2>&1; then
                if ! echo "$existing_vms" | grep -q "^$vm_name"; then
                    missing_vms="$missing_vms $vm_name"
                fi
            fi
        done

        if [ -n "$missing_vms" ]; then
            print_warning "Found ISOs but no VMs for: $missing_vms"
            print_info "Creating VMs from existing ISOs..."
            for vm_name in $missing_vms; do
                local vm_index=$(echo "$vm_name" | sed 's/sno-0*//')
                local memory="${SNO_MEMORY:-24576}"
                local numcpus="${SNO_CPUS:-8}"
                local disk_size="${SNO_DISK_SIZE:-120}"

                if create_vm_from_iso "$vm_name" "" "$memory" "$numcpus" "$disk_size"; then
                    print_success "VM $vm_name created from existing ISO"
                else
                    print_warning "Failed to create VM $vm_name automatically"
                fi
            done

            # Check again after creation
            sleep 3
            existing_vms=$(execute_remote "kcli list vm 2>/dev/null | grep -E '^sno-' | awk '{print \$1}'" 30 2>/dev/null || echo "")
            if [ -n "$existing_vms" ]; then
                print_success "VMs now available:"
                echo "$existing_vms" | sed 's/^/  - /'
            fi
        else
            print_info "You can check manually with: ssh $USER@$TARGET_IP 'kcli list vm'"
            print_info "Or check on remote host: ssh $USER@$TARGET_IP 'virsh list --all'"
        fi
    fi

    print_info "=========================================="
    print_info "Next Steps:"
    print_info "=========================================="
    echo "1. Monitor deployment progress (on remote host $TARGET_IP):"
    echo "   ssh $USER@$TARGET_IP 'kcli list vm'"
    echo "   Or directly on remote: ssh $USER@$TARGET_IP 'virsh list --all'"
    echo ""
    echo "2. Check cluster status (once VM is running):"
    echo "   ssh $USER@$TARGET_IP 'kcli ssh -u root sno-XX \"oc get nodes\"'"
    echo ""
    echo "3. Get kubeconfig:"
    echo "   ssh $USER@$TARGET_IP 'kcli scp root@sno-XX:/root/auth/kubeconfig /tmp/kubeconfig-sno-XX'"
    echo "   scp $USER@$TARGET_IP:/tmp/kubeconfig-sno-XX ./kubeconfig-sno-XX"
    echo ""
    echo "4. View deployment logs:"
    echo "   cat /tmp/kcli-sno-XX.log (local copy)"
    echo "   ssh $USER@$TARGET_IP 'cat /tmp/kcli-sno-XX.log' (on hypervisor)"
    echo ""
    echo "Note: VMs are being created on remote host: $TARGET_IP"
    echo "      kcli runs on the hypervisor, so all commands execute there"
    echo ""
    print_success "Script execution completed!"
}

# Function to cleanup all SNO deployments
cleanup_all_snos() {
    local target_ip="${1:-}"
    local user="${2:-root}"
    local password="${3:-}"

    if [ -z "$target_ip" ]; then
        print_error "Usage: $0 --cleanup <target_ip> [user] [password]"
        echo ""
        echo "This will delete:"
        echo "  - All SNO VMs on the remote host"
        echo "  - All SNO kube clusters (kcli delete kube)"
        echo "  - All cluster directories on hypervisor (~/.kcli/clusters/sno-*)"
        echo "  - All ISO files and related resources"
        echo "  - HAProxy service (stops and disables HAProxy)"
        echo "  - HAProxy configuration (restores backup if available)"
        echo "  - Custom NAT network (sno-hypervisor-network)"
        echo "  - SNO entries from /etc/hosts on local machine"
        echo ""
        exit 1
    fi

    print_info "=========================================="
    print_info "SNO Environment Cleanup"
    print_info "=========================================="
    echo ""
    print_warning "This will DELETE all SNO deployments and related resources!"
    read -p "Are you sure you want to continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        print_info "Cleanup cancelled"
        exit 0
    fi
    echo ""

    # Function to execute remote command
    local execute_remote_cmd
    if [ -n "$password" ] && [ "$password" != "none" ]; then
        execute_remote_cmd() {
            sshpass -p "$password" ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$user@$target_ip" "$1"
        }
    else
        execute_remote_cmd() {
            ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
               -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$user@$target_ip" "$1"
        }
    fi

    print_info "Step 1: Listing all SNO clusters on hypervisor..."
    # Get clusters, filter out header lines and pipe separators, only get valid cluster names
    local sno_clusters=$(execute_remote_cmd "kcli get kube 2>/dev/null | grep -E '^sno-[0-9]+|^sno[0-9]+' | awk '{print \$1}' | grep -vE '^[| -]+$' | grep -v '^$'" 2>/dev/null || echo "")

    if [ -n "$sno_clusters" ]; then
        # Additional filtering: remove any lines that are just separators or invalid
        local valid_clusters=""
        while IFS= read -r cluster; do
            # Skip empty lines, pipe characters, dashes, or whitespace-only lines
            if [ -n "$cluster" ] && ! echo "$cluster" | grep -qE '^[| -]+$' && echo "$cluster" | grep -qE '^sno-[0-9]+|^sno[0-9]+'; then
                if [ -z "$valid_clusters" ]; then
                    valid_clusters="$cluster"
                else
                    valid_clusters="$valid_clusters
$cluster"
                fi
            fi
        done <<< "$sno_clusters"

        if [ -n "$valid_clusters" ]; then
            print_info "Found SNO clusters:"
            echo "$valid_clusters" | sed 's/^/  - /'
            echo ""

            print_info "Step 2: Deleting SNO kube clusters (using 'kcli delete kube')..."
            while IFS= read -r cluster; do
                if [ -n "$cluster" ] && echo "$cluster" | grep -qE '^sno-[0-9]+|^sno[0-9]+'; then
                    print_info "Deleting cluster: $cluster"
                    # Use echo "y" to auto-confirm the deletion prompt
                    execute_remote_cmd "echo 'y' | kcli delete kube '$cluster'" 2>&1 | while IFS= read -r line; do
                        if echo "$line" | grep -q "Deleting directory"; then
                            print_success "  $line"
                        else
                            echo "  $line"
                        fi
                    done
                fi
            done <<< "$valid_clusters"
            print_success "All SNO clusters deleted"
        else
            print_info "No valid SNO clusters found after filtering"
        fi
    else
        print_info "No SNO clusters found via 'kcli get kube'"
    fi
    echo ""

    print_info "Step 3: Deleting SNO VMs on remote host ($target_ip)..."
    local remote_vms=$(execute_remote_cmd "kcli list vm 2>/dev/null | grep -E '^sno-' | awk '{print \$1}'" 2>/dev/null || echo "")

    if [ -z "$remote_vms" ]; then
        # If kcli doesn't work, try directly via virsh
        print_info "kcli list failed, checking via virsh..."
        remote_vms=$(execute_remote_cmd "virsh list --all --name 2>/dev/null | grep -E '^sno-'" 2>/dev/null || echo "")
    fi

    if [ -n "$remote_vms" ]; then
        print_info "Found VMs on remote host:"
        echo "$remote_vms" | sed 's/^/  - /'
        echo ""

        for vm in $remote_vms; do
            print_info "Deleting VM: $vm"
            # Try kcli first
            execute_remote_cmd "kcli delete vm $vm -y" >/dev/null 2>&1 || {
                print_warning "Failed to delete VM $vm via kcli, trying virsh..."
                execute_remote_cmd "virsh destroy $vm" >/dev/null 2>&1 || true
                execute_remote_cmd "virsh undefine $vm --remove-all-storage" >/dev/null 2>&1 || true
            }
        done
        print_success "VMs deleted"
    else
        print_info "No SNO VMs found on remote host"
    fi
    echo ""

    print_info "Step 4: Cleaning up ISO files and volumes on remote host..."
    local iso_files=$(execute_remote_cmd "virsh vol-list default 2>/dev/null | grep -E 'sno.*iso' | awk '{print \$1}'" 2>/dev/null || echo "")
    if [ -n "$iso_files" ]; then
        for iso in $iso_files; do
            print_info "Deleting ISO volume: $iso"
            execute_remote_cmd "virsh vol-delete $iso default" >/dev/null 2>&1 || true
        done
    fi

    # Delete ISO files directly
    execute_remote_cmd "rm -f /var/lib/libvirt/images/*sno*.iso" >/dev/null 2>&1 || true
    execute_remote_cmd "rm -f /var/lib/libvirt/images/*sno*.ign" >/dev/null 2>&1 || true
    echo ""

    print_info "Step 4b: Cleaning up disk image files on remote host..."
    # Clean up any remaining disk image files (.img, .qcow2) for SNO VMs
    # This includes bootstrap, ctlplane, and any other related disk images
    execute_remote_cmd "rm -f /var/lib/libvirt/images/*sno*.img /var/lib/libvirt/images/*sno*.qcow2" >/dev/null 2>&1 || true
    execute_remote_cmd "rm -f /var/lib/libvirt/images/*sno-*.img /var/lib/libvirt/images/*sno-*.qcow2" >/dev/null 2>&1 || true
    execute_remote_cmd "rm -f /var/lib/libvirt/images/*sno-*-bootstrap*.img /var/lib/libvirt/images/*sno-*-bootstrap*.qcow2" >/dev/null 2>&1 || true
    execute_remote_cmd "rm -f /var/lib/libvirt/images/*sno-*-ctlplane*.img /var/lib/libvirt/images/*sno-*-ctlplane*.qcow2" >/dev/null 2>&1 || true
    print_success "Disk image files cleaned"
    echo ""

    print_info "Step 5: Cleaning up cluster directories on hypervisor..."
    local remote_clusters=$(execute_remote_cmd "find ~/.kcli/clusters -maxdepth 1 -type d -name 'sno-*' -o -name 'sno[0-9]*' 2>/dev/null | xargs -r basename -a" 2>/dev/null || echo "")

    if [ -n "$remote_clusters" ]; then
        print_info "Found cluster directories on hypervisor:"
        echo "$remote_clusters" | sed 's/^/  - /'
        echo ""

        for cluster in $remote_clusters; do
            print_info "Removing: ~/.kcli/clusters/$cluster"
            execute_remote_cmd "rm -rf ~/.kcli/clusters/$cluster" >/dev/null 2>&1 || print_warning "Failed to remove ~/.kcli/clusters/$cluster"
        done
    else
        print_info "No SNO cluster directories found on hypervisor"
    fi
    echo ""

    print_info "Step 5b: Cleaning up log files and temporary files on hypervisor..."
    execute_remote_cmd "rm -f /tmp/kcli-sno-*.log /tmp/kcli-sno-*.pid /tmp/kcli-sno-*.exit /tmp/kcli-sno-*.vip" >/dev/null 2>&1 || true
    execute_remote_cmd "rm -f /tmp/kcli-sno-*-params.yml" >/dev/null 2>&1 || true
    print_success "Log files and temporary files cleaned on hypervisor"
    echo ""

    print_info "Step 5c: Cleaning up pull secret file on hypervisor..."
    execute_remote_cmd "rm -f /tmp/pull-secret.json" >/dev/null 2>&1 || true
    print_success "Pull secret file cleaned"
    echo ""

    print_info "Step 6: Stopping HAProxy service..."
    if execute_remote_cmd "systemctl is-active haproxy >/dev/null 2>&1" >/dev/null 2>&1; then
        print_info "Stopping HAProxy..."
        execute_remote_cmd "systemctl stop haproxy" >/dev/null 2>&1 || true
        execute_remote_cmd "systemctl disable haproxy" >/dev/null 2>&1 || true
        print_success "HAProxy stopped and disabled"
    else
        print_info "HAProxy is not running"
    fi
    echo ""

    print_info "Step 7: Cleaning up HAProxy configuration..."
    # Restore HAProxy config backup if it exists
    local haproxy_config="/etc/haproxy/haproxy.cfg"
    local haproxy_backups=$(execute_remote_cmd "ls -t /etc/haproxy/haproxy.cfg.backup.* 2>/dev/null | head -1" 2>/dev/null || echo "")
    if [ -n "$haproxy_backups" ]; then
        print_info "Restoring HAProxy configuration from backup..."
        execute_remote_cmd "sudo cp $haproxy_backups $haproxy_config" >/dev/null 2>&1 || true
        print_success "HAProxy configuration restored"
    else
        print_info "No HAProxy backup found, leaving configuration as-is"
    fi
    echo ""

    print_info "Step 8: Cleaning up /etc/hosts entries on local machine..."
    local hosts_file="/etc/hosts"
    local domain="local"

    if [ -w "$hosts_file" ] || (command_exists sudo && sudo -n true 2>/dev/null); then
        local sudo_cmd=""
        [ ! -w "$hosts_file" ] && sudo_cmd="sudo"

        # Remove SNO entries from /etc/hosts
        if $sudo_cmd grep -q -E "(api\.sno-[0-9]+\.${domain}|console-openshift-console\.apps\.sno-[0-9]+\.${domain}|oauth-openshift\.apps\.sno-[0-9]+\.${domain}|prometheus-k8s-openshift-monitoring\.apps\.sno-[0-9]+\.${domain})" "$hosts_file" 2>/dev/null; then
            print_info "Removing SNO entries from $hosts_file..."
            local temp_hosts=$(mktemp)
            $sudo_cmd grep -v -E "(api\.sno-[0-9]+\.${domain}|console-openshift-console\.apps\.sno-[0-9]+\.${domain}|oauth-openshift\.apps\.sno-[0-9]+\.${domain}|prometheus-k8s-openshift-monitoring\.apps\.sno-[0-9]+\.${domain})" "$hosts_file" > "$temp_hosts" 2>/dev/null
            if [ -s "$temp_hosts" ]; then
                $sudo_cmd cp "$temp_hosts" "$hosts_file" 2>/dev/null && print_success "Removed SNO entries from $hosts_file" || print_warning "Could not update $hosts_file"
            fi
            rm -f "$temp_hosts"
        else
            print_info "No SNO entries found in $hosts_file"
        fi
    else
        print_warning "Cannot update $hosts_file: no write permission"
        print_info "You may need to manually remove SNO entries from $hosts_file"
    fi
    echo ""

    print_info "Step 9: Cleaning up temporary files on local machine..."
    rm -f /tmp/kcli-sno-*.log
    rm -f /tmp/kcli-sno-*.pid
    rm -f /tmp/kcli-sno-*.exit
    rm -f /tmp/kcli-sno-*.vip
    rm -f /tmp/kcli-sno-*-params.yml
    print_success "Temporary files cleaned on local machine"
    echo ""

    print_info "Step 10: Cleaning up custom NAT network (sno-hypervisor-network)..."
    if execute_remote_cmd "virsh net-info sno-hypervisor-network >/dev/null 2>&1" >/dev/null 2>&1; then
        print_info "Stopping and removing sno-hypervisor-network..."
        execute_remote_cmd "virsh net-destroy sno-hypervisor-network" >/dev/null 2>&1 || true
        execute_remote_cmd "virsh net-undefine sno-hypervisor-network" >/dev/null 2>&1 || true
        print_success "Custom NAT network removed"
    else
        print_info "Custom NAT network (sno-hypervisor-network) not found or already removed"
    fi
    echo ""

    print_info "Step 11: Final verification..."
    local remaining_clusters=$(execute_remote_cmd "kcli get kube 2>/dev/null | grep -E 'sno-|^sno[0-9]' | awk '{print \$1}'" 30 2>/dev/null || echo "")
    local remaining_vms=$(execute_remote_cmd "kcli list vm 2>/dev/null | grep -E '^sno-' | awk '{print \$1}'" 30 2>/dev/null || echo "")

    if [ -z "$remaining_clusters" ] && [ -z "$remaining_vms" ]; then
        print_success "=========================================="
        print_success "Cleanup completed successfully!"
        print_success "=========================================="
        print_info "All SNO deployments and resources have been removed"
    else
        print_warning "Some resources may still exist:"
        if [ -n "$remaining_clusters" ]; then
            print_warning "Remaining clusters: $remaining_clusters"
        fi
        if [ -n "$remaining_vms" ]; then
            print_warning "Remaining VMs: $remaining_vms"
        fi
        print_info "You may need to clean them up manually"
    fi
}

# Main execution
# Check if cleanup mode is requested
if [ "${1:-}" = "--cleanup" ] || [ "${1:-}" = "-c" ] || [ "${1:-}" = "cleanup" ]; then
    cleanup_all_snos "${2:-}" "${3:-root}" "${4:-}"
    exit 0
fi

# Check if diagnostic mode is requested
if [ "${1:-}" = "--diagnose-haproxy" ] || [ "${1:-}" = "--diagnose" ] || [ "${1:-}" = "-d" ]; then
    diagnose_haproxy "${2:-}" "${3:-root}" "${4:-}"
    exit 0
fi

main "$@"

