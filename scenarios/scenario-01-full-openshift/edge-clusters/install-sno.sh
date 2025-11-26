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
#   - kcli must be installed on the local machine
#   - SSH access to the target machine
#   - Target machine must have libvirt/kvm capabilities
#   - OpenShift pull secret (will prompt if not found)
#
# Environment Variables (optional):
#   SNO_VIP_BASE      - Base VIP IP for SNO clusters (default: TARGET_IP + 1)
#   SNO_MEMORY        - Memory in MB (default: 16384)
#   SNO_CPUS          - Number of CPUs (default: 8)
#   SNO_DISK_SIZE     - Disk size in GB (default: 120)
#   SNO_DOMAIN        - Domain for clusters (default: local)
#   OCP_VERSION       - OpenShift version (default: stable)
#
# VIP IP Assignment:
#   VIP IPs are automatically assigned sequentially starting from TARGET_IP + 1
#   Example: If TARGET_IP is 10.8.125.20, SNOs will get:
#     sno-01 -> 10.8.125.21
#     sno-02 -> 10.8.125.22
#     etc.
#   You can override with SNO_VIP_BASE environment variable
#
# Parallel Execution:
#   All SNO deployments run in parallel (background processes)
#   Each deployment logs to: /tmp/kcli-<vm_name>.log
#   Monitor progress: tail -f /tmp/kcli-sno-*.log
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

    # Check if kcli is installed
    if ! command_exists kcli; then
        print_error "kcli is not installed. Please install it first:"
        echo "  curl https://raw.githubusercontent.com/karmab/kcli/main/install.sh | sudo bash"
        exit 1
    fi

    print_success "kcli is installed: $(kcli version 2>/dev/null || echo 'version check failed')"

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

    # Check for coreos-installer locally (kcli may need it to copy to remote)
    print_info "Checking for coreos-installer locally..."
    if command_exists coreos-installer; then
        print_success "coreos-installer is available locally"
    else
        print_warning "coreos-installer not found locally"
        print_info "kcli will attempt to download it if needed, or you can install it:"
        echo "  Fedora/RHEL: sudo dnf install -y coreos-installer"
        echo "  Or download from: https://github.com/coreos/coreos-installer/releases"
    fi

    # Check for curl or wget (needed for downloads)
    if ! command_exists curl && ! command_exists wget; then
        print_warning "Neither curl nor wget is available. Some operations may fail."
    fi

    print_success "Local prerequisites check completed"
}

# Function to execute remote command
execute_remote() {
    local cmd="$1"
    if [ -n "$PASSWORD" ] && [ "$PASSWORD" != "none" ]; then
        sshpass -p "$PASSWORD" ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$USER@$TARGET_IP" "$cmd"
    else
        ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$USER@$TARGET_IP" "$cmd"
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
            case "$os_type" in
                fedora|rhel|centos|rocky|almalinux)
                    execute_remote "sudo dnf install -y $package" || execute_remote "sudo yum install -y $package"
                    ;;
                ubuntu|debian)
                    execute_remote "sudo apt-get update && sudo apt-get install -y $package"
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
                        execute_remote "sudo dnf install -y libvirt libvirt-daemon-driver-qemu qemu-kvm tar" || \
                        execute_remote "sudo yum install -y libvirt libvirt-daemon-driver-qemu qemu-kvm tar"
                        ;;
                    ubuntu|debian)
                        execute_remote "sudo apt-get update && sudo apt-get install -y libvirt-daemon-system libvirt-clients qemu-kvm tar"
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

    # Setup bridged network for VIP IP access
    print_info "=========================================="
    print_info "Setting up bridged network for VIP IPs"
    print_info "=========================================="

    # Extract network prefix from hypervisor IP
    local hypervisor_network=$(echo "$TARGET_IP" | cut -d'.' -f1-3)
    local bridge_name="br0"
    local libvirt_net_name="bridged"

    # Find the physical interface that has the hypervisor IP
    print_info "Detecting physical network interface..."
    local phys_iface=$(execute_remote "ip -4 addr show | grep -B2 '$TARGET_IP' | grep -oP '^[0-9]+: \\K[^:]+' | head -1" 2>/dev/null || echo "")

    if [ -z "$phys_iface" ]; then
        # Try alternative method
        phys_iface=$(execute_remote "ip route get 8.8.8.8 2>/dev/null | grep -oP 'dev \\K[^ ]+' | head -1" 2>/dev/null || echo "")
    fi

    if [ -z "$phys_iface" ]; then
        print_warning "Could not detect physical interface automatically"
        print_info "Attempting to use common interface names..."
        # Try common interface names
        for iface in eno3 eno1 eth0 ens3; do
            if execute_remote "ip link show $iface >/dev/null 2>&1" >/dev/null 2>&1; then
                phys_iface="$iface"
                print_info "Using interface: $phys_iface"
                break
            fi
        done
    else
        print_success "Detected physical interface: $phys_iface"
    fi

    if [ -z "$phys_iface" ]; then
        print_error "Could not determine physical interface. Bridged network setup may fail."
        print_info "Please manually configure the bridge and rerun the script."
    else
        # Check if bridge already exists
        local bridge_exists=false
        if execute_remote "ip link show $bridge_name >/dev/null 2>&1" >/dev/null 2>&1; then
            print_info "Bridge $bridge_name already exists"
            bridge_exists=true
        fi

        # Check if libvirt bridged network exists
        local libvirt_bridged_exists=false
        if execute_remote "virsh net-list --all 2>/dev/null | grep -q $libvirt_net_name" >/dev/null 2>&1; then
            print_info "Libvirt bridged network '$libvirt_net_name' already exists"
            libvirt_bridged_exists=true
        fi

        # Setup bridge if it doesn't exist
        if [ "$bridge_exists" = false ]; then
            print_info "Creating bridge $bridge_name..."

            # Check if NetworkManager is available
            if execute_remote "command -v nmcli >/dev/null 2>&1" >/dev/null 2>&1; then
                print_info "Using NetworkManager (nmcli) to create bridge..."

                # Get current IP configuration
                local current_ip=$(execute_remote "ip -4 addr show $phys_iface | grep -oP 'inet \\K[^/ ]+' | head -1" 2>/dev/null || echo "")
                local current_gw=$(execute_remote "ip route | grep default | grep $phys_iface | awk '{print \$3}' | head -1" 2>/dev/null || echo "")

                # Create bridge connection
                if execute_remote "sudo nmcli connection add type bridge con-name $bridge_name ifname $bridge_name ipv4.method manual ipv4.addresses ${current_ip:-$TARGET_IP}/24 ipv4.gateway ${current_gw} ipv4.dns '8.8.8.8 8.8.4.4' 2>&1" >/dev/null 2>&1; then
                    print_success "Bridge connection created"

                    # Add physical interface as bridge slave
                    print_info "Adding $phys_iface as bridge slave..."
                    if execute_remote "sudo nmcli connection add type bridge-slave con-name ${bridge_name}-slave ifname $phys_iface master $bridge_name 2>&1" >/dev/null 2>&1; then
                        print_success "Bridge slave added"

                        # Activate bridge connection
                        print_info "Activating bridge..."
                        # Get the connection name for the physical interface
                        local phys_conn=$(execute_remote "nmcli -t -f NAME,DEVICE connection show | grep '$phys_iface' | cut -d: -f1 | head -1" 2>/dev/null || echo "")
                        execute_remote "sudo nmcli connection up $bridge_name" >/dev/null 2>&1 || true
                        if [ -n "$phys_conn" ] && [ "$phys_conn" != "$bridge_name" ]; then
                            execute_remote "sudo nmcli connection down '$phys_conn'" >/dev/null 2>&1 || true
                        fi

                        # Wait a moment for bridge to come up
                        sleep 3

                        if execute_remote "ip link show $bridge_name | grep -q UP" >/dev/null 2>&1; then
                            print_success "Bridge $bridge_name is active"
                            bridge_exists=true
                        else
                            print_warning "Bridge created but may not be fully active yet"
                        fi
                    else
                        print_warning "Failed to add bridge slave. Bridge may need manual configuration."
                    fi
                else
                    print_warning "Failed to create bridge via nmcli. Trying alternative method..."
                    # Try alternative: use brctl (bridge-utils)
                    if execute_remote "command -v brctl >/dev/null 2>&1" >/dev/null 2>&1; then
                        print_info "Using brctl to create bridge..."
                        execute_remote "sudo brctl addbr $bridge_name" >/dev/null 2>&1 || true
                        execute_remote "sudo ip addr add $TARGET_IP/24 dev $bridge_name" >/dev/null 2>&1 || true
                        execute_remote "sudo brctl addif $bridge_name $phys_iface" >/dev/null 2>&1 || true
                        execute_remote "sudo ip link set $bridge_name up" >/dev/null 2>&1 || true
                        execute_remote "sudo ip link set $phys_iface up" >/dev/null 2>&1 || true

                        if execute_remote "ip link show $bridge_name | grep -q UP" >/dev/null 2>&1; then
                            print_success "Bridge $bridge_name created via brctl"
                            bridge_exists=true
                        fi
                    fi
                fi
            else
                print_warning "NetworkManager (nmcli) not available. Using brctl..."
                if execute_remote "command -v brctl >/dev/null 2>&1" >/dev/null 2>&1 || execute_remote "sudo dnf install -y bridge-utils" >/dev/null 2>&1; then
                    execute_remote "sudo brctl addbr $bridge_name" >/dev/null 2>&1 || true
                    execute_remote "sudo ip addr add $TARGET_IP/24 dev $bridge_name" >/dev/null 2>&1 || true
                    execute_remote "sudo brctl addif $bridge_name $phys_iface" >/dev/null 2>&1 || true
                    execute_remote "sudo ip link set $bridge_name up" >/dev/null 2>&1 || true
                    execute_remote "sudo ip link set $phys_iface up" >/dev/null 2>&1 || true

                    if execute_remote "ip link show $bridge_name | grep -q UP" >/dev/null 2>&1; then
                        print_success "Bridge $bridge_name created"
                        bridge_exists=true
                    fi
                else
                    print_error "Could not create bridge. Please configure manually."
                fi
            fi
        fi

        # Create libvirt bridged network if it doesn't exist
        if [ "$libvirt_bridged_exists" = false ] && [ "$bridge_exists" = true ]; then
            print_info "Creating libvirt bridged network '$libvirt_net_name'..."

            local bridge_net_xml="<network>
  <name>$libvirt_net_name</name>
  <forward mode=\"bridge\"/>
  <bridge name=\"$bridge_name\"/>
</network>"

            # Create network XML on remote
            execute_remote "cat > /tmp/bridged-network.xml <<'BRIDGEXML'
$bridge_net_xml
BRIDGEXML
" >/dev/null 2>&1

            if execute_remote "sudo virsh net-define /tmp/bridged-network.xml" >/dev/null 2>&1; then
                print_success "Libvirt bridged network defined"
                execute_remote "sudo virsh net-start $libvirt_net_name" >/dev/null 2>&1 || true
                execute_remote "sudo virsh net-autostart $libvirt_net_name" >/dev/null 2>&1 || true
                print_success "Libvirt bridged network '$libvirt_net_name' is active"
                libvirt_bridged_exists=true
            else
                print_warning "Failed to define libvirt bridged network"
            fi

            execute_remote "rm -f /tmp/bridged-network.xml" >/dev/null 2>&1 || true
        fi

        if [ "$bridge_exists" = true ] && [ "$libvirt_bridged_exists" = true ]; then
            print_success "Bridged network setup complete!"
            print_info "  - Bridge: $bridge_name"
            print_info "  - Libvirt network: $libvirt_net_name"
            print_info "  - Physical interface: $phys_iface"
            print_info "  - Network: $hypervisor_network.0/24"
        else
            print_warning "Bridged network setup incomplete. Some steps may have failed."
            print_info "You may need to configure the bridge manually."
        fi
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
                        # Try to install from EPEL or download directly
                        if execute_remote "sudo dnf install -y coreos-installer" 2>/dev/null; then
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

# Function to configure kcli host
configure_kcli_host() {
    local host_name="sno-hypervisor-$(echo $TARGET_IP | tr '.' '-')"

    print_info "Configuring kcli host: $host_name"

    # Check if host already exists
    if kcli list host 2>/dev/null | grep -q "^$host_name"; then
        print_warning "Host $host_name already exists. Skipping configuration."
        return 0
    fi

    # Ensure ~/.kcli directory exists
    mkdir -p ~/.kcli

    # Create kcli host configuration
    # For remote libvirt, kcli uses SSH protocol
    # kcli create host will prompt for SSH key setup if needed
    print_info "Creating kcli host configuration..."
    print_info "Note: kcli requires SSH key authentication for remote hosts."
    print_info "If SSH keys are not set up, you may need to run:"
    echo "  ssh-copy-id $USER@$TARGET_IP"
    echo ""

    # Try to create host - kcli will use SSH to connect
    # If user/password was provided, we might need to set up SSH keys first
    if [ -n "$PASSWORD" ] && [ "$PASSWORD" != "none" ]; then
        print_info "Setting up SSH keys for passwordless access..."
        # Try to copy SSH key if it doesn't exist or if we can't connect
        if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$USER@$TARGET_IP" "echo" >/dev/null 2>&1; then
            print_info "Attempting to copy SSH key (you may be prompted for password)..."
            if command_exists ssh-copy-id; then
                sshpass -p "$PASSWORD" ssh-copy-id -o StrictHostKeyChecking=no "$USER@$TARGET_IP" 2>/dev/null || {
                    print_warning "Could not automatically copy SSH key. Please set up SSH keys manually."
                }
            else
                print_warning "ssh-copy-id not available. Please set up SSH keys manually."
            fi
        fi
    fi

    # Create host with SSH connection
    # kcli will use SSH to connect to remote libvirt
    local create_output
    create_output=$(kcli create host kvm -H "$TARGET_IP" "$host_name" 2>&1) || true

    if echo "$create_output" | grep -qi "skipping\|already exists\|existing"; then
        print_info "Host $host_name already exists in configuration"
    elif echo "$create_output" | grep -qi "created\|success"; then
        print_success "Host $host_name created successfully"
    else
        print_info "Host creation command executed. Output: $create_output"
    fi

    # Verify host configuration - check multiple ways
    sleep 2  # Give kcli a moment to update config

    # Check if host exists in kcli list (try multiple patterns)
    local host_exists=false
    local host_list_output
    host_list_output=$(kcli list host 2>/dev/null || echo "")

    if echo "$host_list_output" | grep -qE "^$host_name[[:space:]]|^$host_name$"; then
        host_exists=true
    elif [ -f ~/.kcli/config.yml ] && grep -q "^$host_name:" ~/.kcli/config.yml; then
        # Host is in config file, verify it works
        host_exists=true
    fi

    if [ "$host_exists" = true ]; then
        # Test if the host is actually working
        print_info "Testing connection to kcli host $host_name..."
        if kcli -C "$host_name" list pool >/dev/null 2>&1 || \
           kcli -C "$host_name" list vm >/dev/null 2>&1 || \
           kcli -C "$host_name" list network >/dev/null 2>&1; then
            print_success "Host $host_name configured and verified (connection test passed)"
            return 0
        else
            print_warning "Host $host_name exists in config but connection test failed"
            print_info "This might be normal if libvirt is still initializing. Continuing..."
            # Don't exit, as the host might work for VM creation even if list commands fail
            return 0
        fi
    else
        print_warning "Host not found in kcli configuration. Attempting manual configuration..."

        # Try to manually add to config.yml
        if [ ! -f ~/.kcli/config.yml ]; then
            print_info "Creating ~/.kcli/config.yml..."
            cat > ~/.kcli/config.yml <<EOF
default:
  client: $host_name

$host_name:
  host: $TARGET_IP
  pool: default
  protocol: ssh
  user: $USER
EOF
            print_success "Created ~/.kcli/config.yml with host configuration"
        else
            # Check if host is already in config
            if ! grep -q "^$host_name:" ~/.kcli/config.yml; then
                print_info "Adding host to existing ~/.kcli/config.yml..."
                # Check if default section exists, add if not
                if ! grep -q "^default:" ~/.kcli/config.yml; then
                    # Create a temp file with default section
                    {
                        echo "default:"
                        echo "  client: $host_name"
                        echo ""
                        cat ~/.kcli/config.yml
                    } > ~/.kcli/config.yml.tmp && mv ~/.kcli/config.yml.tmp ~/.kcli/config.yml
                fi
                # Add host configuration
                cat >> ~/.kcli/config.yml <<EOF

$host_name:
  host: $TARGET_IP
  pool: default
  protocol: ssh
  user: $USER
EOF
                print_success "Added host to ~/.kcli/config.yml"
            else
                print_info "Host already exists in ~/.kcli/config.yml"
            fi
        fi

        # Verify again after manual configuration
        sleep 1
        if [ -f ~/.kcli/config.yml ] && grep -q "^$host_name:" ~/.kcli/config.yml; then
            print_success "Host $host_name added to configuration file"
            print_info "Note: Connection will be tested when deploying VMs"
            return 0
        else
            print_error "Failed to configure host. Please check:"
            echo "  1. SSH access: ssh $USER@$TARGET_IP"
            echo "  2. Libvirt is running on target: ssh $USER@$TARGET_IP 'systemctl status libvirtd'"
            echo "  3. Manual config: kcli create host kvm -H $TARGET_IP $host_name"
            echo "  4. Check config file: cat ~/.kcli/config.yml"
            exit 1
        fi
    fi
}

# Function to verify remote kcli connection
verify_remote_kcli_connection() {
    local host_name="sno-hypervisor-$(echo $TARGET_IP | tr '.' '-')"

    print_info "Verifying kcli can connect to remote host $TARGET_IP..."

    # Test basic connection
    if kcli -C "$host_name" list pool >/dev/null 2>&1; then
        print_success "Successfully connected to remote kcli host"
        # Show some info about the remote host
        local pool_info=$(kcli -C "$host_name" list pool 2>/dev/null | head -2 || echo "")
        if [ -n "$pool_info" ]; then
            print_info "Remote storage pools:"
            echo "$pool_info" | sed 's/^/  /'
        fi
        return 0
    elif kcli -C "$host_name" list network >/dev/null 2>&1; then
        print_success "Successfully connected to remote kcli host (via network check)"
        return 0
    else
        print_warning "Could not verify remote connection, but continuing..."
        print_info "kcli will attempt connection during VM creation"
        print_info "If deployment fails, check:"
        echo "  1. SSH access: ssh $USER@$TARGET_IP"
        echo "  2. kcli config: cat ~/.kcli/config.yml | grep -A 5 $host_name"
        return 0  # Don't fail, let deployment try
    fi
}

# Function to check for OpenShift pull secret
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
}

# Function to create VM from generated ISO
create_vm_from_iso() {
    local vm_name=$1
    local host_name=$2
    local memory=$3
    local numcpus=$4
    local disk_size=$5

    print_info "Creating VM $vm_name from generated ISO..."

    # Check if VM already exists
    if kcli -C "$host_name" list vm 2>/dev/null | grep -q "^$vm_name"; then
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
    create_output=$(kcli -C "$host_name" create vm \
        -P memory=$memory \
        -P numcpus=$numcpus \
        -P disksize=$disk_size \
        -P iso=$iso_name \
        "$vm_name" 2>&1)
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
        if execute_remote "sudo dnf install -y virt-install" >/dev/null 2>&1 || \
           execute_remote "sudo yum install -y virt-install" >/dev/null 2>&1 || \
           execute_remote "sudo apt-get install -y virtinst" >/dev/null 2>&1; then
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
        --network network=default \
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
        echo "    kcli -C $host_name create vm -P iso=$iso_name -P memory=$memory -P numcpus=$numcpus -P disksize=$disk_size $vm_name"
        echo ""
        echo "  Option 2 (virt-install on remote):"
        echo "    ssh $USER@$TARGET_IP 'sudo virt-install --name $vm_name --memory $memory --vcpus $numcpus --disk size=$disk_size,pool=default --cdrom $iso_path --network network=default --graphics none --console pty,target_type=serial --noautoconsole'"
        return 1
    fi
}

# Function to cleanup existing assets for a cluster
cleanup_cluster_assets() {
    local vm_name=$1
    local host_name=$2

    print_info "Cleaning up existing assets for $vm_name..."

    # Delete VM if it exists (this will also handle associated disks)
    if kcli -C "$host_name" list vm 2>/dev/null | grep -q "^$vm_name"; then
        print_info "Deleting existing VM: $vm_name"
        kcli -C "$host_name" delete vm "$vm_name" -y >/dev/null 2>&1 || true
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

    # Clean up local cluster directory (kcli stores configs and state locally)
    # This is CRITICAL - kcli checks .openshift_install_state.json and may skip steps if it exists
    # The state file can be 2MB+ and contains deployment state that confuses kcli
    local cluster_dir="$HOME/.kcli/clusters/$vm_name"
    if [ -d "$cluster_dir" ]; then
        print_info "Removing local cluster directory and all state files: $cluster_dir"
        print_info "  (This includes .openshift_install_state.json which can cause kcli to skip deployment)"
        # Remove the entire directory including all state files, logs, configs, auth files
        rm -rf "$cluster_dir" || true
        print_success "Removed cluster directory: $cluster_dir"
    fi

    # Also check for any related files in the clusters directory root
    local clusters_dir="$HOME/.kcli/clusters"
    for file in "${vm_name}-sno.ign" "${vm_name}.ign" "iso.ign"; do
        if [ -f "$clusters_dir/$file" ]; then
            print_info "Removing ignition file: $clusters_dir/$file"
            rm -f "$clusters_dir/$file" || true
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
    if [ -d "$cluster_dir" ]; then
        print_warning "Cluster directory still exists after cleanup attempt: $cluster_dir"
        print_info "Attempting force removal..."
        rm -rf "$cluster_dir" 2>/dev/null || {
            print_error "Could not remove cluster directory. You may need to remove it manually:"
            echo "  rm -rf $cluster_dir"
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
    local host_name="sno-hypervisor-$(echo $TARGET_IP | tr '.' '-')"

    print_info "Deploying SNO VM: $vm_name (${vm_index}/${SNO_COUNT})"

    # Cleanup any existing assets first (before deployment)
    cleanup_cluster_assets "$vm_name" "$host_name"

    # SNO deployment parameters
    # Adjust these based on your requirements
    local memory="${SNO_MEMORY:-16384}"      # 16GB default
    local numcpus="${SNO_CPUS:-8}"           # 8 CPUs default
    local disk_size="${SNO_DISK_SIZE:-120}"  # 120GB default
    local version="${OCP_VERSION:-stable}"   # OpenShift version
    local domain="${SNO_DOMAIN:-local}"      # Domain for cluster

    print_info "VM Configuration:"
    echo "  Name: $vm_name"
    echo "  Memory: ${memory}MB"
    echo "  CPUs: $numcpus"
    echo "  Disk: ${disk_size}GB"
    echo "  OpenShift Version: $version"
    echo "  Domain: $domain"

    # Calculate VIP IP for this SNO
    # Check if custom VIP was provided via environment variable
    # Replace hyphens with underscores in variable name (bash doesn't allow hyphens)
    local vip_ip=""
    local custom_vip_var="VIP_$(echo "$vm_name" | tr '-' '_')"

    if [ -n "${!custom_vip_var:-}" ]; then
        # Use custom VIP IP provided by user
        vip_ip="${!custom_vip_var}"
        print_info "Using custom VIP IP for $vm_name: $vip_ip"
    else
        # VIP IPs will be assigned sequentially starting from a base IP
        # Default: use target IP network with offset (e.g., if target is 10.8.125.20, start at 10.8.125.21)
        local base_vip_ip="${SNO_VIP_BASE:-}"
        if [ -z "$base_vip_ip" ]; then
            # Extract network from target IP and use next IP as base
            local ip_parts=($(echo "$TARGET_IP" | tr '.' ' '))
            base_vip_ip="${ip_parts[0]}.${ip_parts[1]}.${ip_parts[2]}.$((ip_parts[3] + 1))"
        fi

        # Calculate VIP IP for this specific SNO (increment by VM index)
        local vip_ip_parts=($(echo "$base_vip_ip" | tr '.' ' '))
        vip_ip="${vip_ip_parts[0]}.${vip_ip_parts[1]}.${vip_ip_parts[2]}.$((vip_ip_parts[3] + vm_index - 1))"
    fi

    # Store VIP IP for this VM
    echo "$vip_ip" > "/tmp/kcli-${vm_name}.vip"

    print_info "VIP IP for $vm_name: $vip_ip"

    # Deploy SNO cluster using kcli with correct command syntax
    # Use: kcli create kube openshift (not "create cluster openshift")
    # For SNO: ctlplanes=1, workers=0
    local log_file="/tmp/kcli-${vm_name}.log"

    # Add SSH host key to known_hosts to avoid prompts
    if [ -n "$PASSWORD" ] && [ "$PASSWORD" != "none" ]; then
        sshpass -p "$PASSWORD" ssh-keyscan -H "$TARGET_IP" >> ~/.ssh/known_hosts 2>/dev/null || true
    else
        ssh-keyscan -H "$TARGET_IP" >> ~/.ssh/known_hosts 2>/dev/null || true
    fi

    # Check if bridged network exists and use it
    local network_param=""
    if execute_remote "virsh net-list --all 2>/dev/null | grep -q bridged" >/dev/null 2>&1; then
        network_param="-P network=bridged"
        print_info "Using bridged network for VM deployment"
    fi

    print_info "Starting deployment (this may take a few moments to initiate)..."
    local deploy_cmd="kcli -C $host_name create kube openshift -P ctlplanes=1 -P workers=0 -P pull_secret=$PULL_SECRET_PATH -P cluster=$vm_name -P domain=$domain -P api_ip=$vip_ip -P ctlplane_memory=$memory -P numcpus=$numcpus -P disk_size=$disk_size"
    if [ -n "$network_param" ]; then
        deploy_cmd="$deploy_cmd $network_param"
    fi
    deploy_cmd="$deploy_cmd $vm_name"
    print_info "Deployment command: $deploy_cmd"

    # Execute deployment and save to log file
    # Run in background for parallel execution
    (
        kcli -C "$host_name" create kube openshift \
            -P ctlplanes=1 \
            -P workers=0 \
            -P pull_secret="$PULL_SECRET_PATH" \
            -P cluster="$vm_name" \
            -P domain="$domain" \
            -P api_ip="$vip_ip" \
            -P ctlplane_memory="$memory" \
            -P numcpus="$numcpus" \
            -P disk_size="$disk_size" \
            $network_param \
            "$vm_name" > "$log_file" 2>&1
        echo $? > "/tmp/kcli-${vm_name}.exit"
    ) &

    local deployment_pid=$!
    echo "$deployment_pid" > "/tmp/kcli-${vm_name}.pid"

    print_success "Deployment started in background (PID: $deployment_pid)"
    print_info "Log file: $log_file"
    print_info "VIP IP: $vip_ip"

    # Return immediately for parallel execution
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
        if kcli ssh -u root "$vm_name" "oc get nodes" >/dev/null 2>&1; then
            print_success "Cluster $vm_name is ready!"
            return 0
        fi

        print_info "Still waiting... (${elapsed}s / ${max_wait}s)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    print_warning "Cluster $vm_name may not be fully ready yet. Check manually with:"
    echo "  kcli ssh -u root $vm_name 'oc get nodes'"
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

    # Configure kcli host
    configure_kcli_host

    # Verify remote connection works before deployment
    verify_remote_kcli_connection

    # Check for pull secret
    check_pull_secret

    # Calculate and display VIP IP assignments before deployment
    print_info "=========================================="
    print_info "VIP IP Assignment Plan"
    print_info "=========================================="

    local host_name="sno-hypervisor-$(echo $TARGET_IP | tr '.' '-')"
    local base_vip_ip="${SNO_VIP_BASE:-}"
    if [ -z "$base_vip_ip" ]; then
        # Extract network from target IP and use next IP as base
        local ip_parts=($(echo "$TARGET_IP" | tr '.' ' '))
        base_vip_ip="${ip_parts[0]}.${ip_parts[1]}.${ip_parts[2]}.$((ip_parts[3] + 1))"
    fi

    print_info "Target Hypervisor: $TARGET_IP"
    print_info "Base VIP IP: $base_vip_ip"
    print_info ""
    print_info "VIP IP Assignments:"
    echo ""
    echo "  +--------+---------------+"
    echo "  |  SNO   |    VIP IP     |"
    echo "  +--------+---------------+"

    local vip_plan=()
    for i in $(seq 1 $SNO_COUNT); do
        local vm_name="sno-$(printf "%02d" $i)"
        local vip_ip_parts=($(echo "$base_vip_ip" | tr '.' ' '))
        local vip_ip="${vip_ip_parts[0]}.${vip_ip_parts[1]}.${vip_ip_parts[2]}.$((vip_ip_parts[3] + i - 1))"
        vip_plan+=("$vm_name:$vip_ip")
        printf "  | %-6s | %-13s |\n" "$vm_name" "$vip_ip"
    done
    echo "  +--------+---------------+"
    echo ""

    print_info "These VIP IPs will be used for API access to each SNO cluster."
    print_info "Make sure these IPs are:"
    echo "  - Available on the hypervisor network ($TARGET_IP network)"
    echo "  - Not already in use"
    echo "  - Accessible from your management network"
    echo ""
    print_warning "IMPORTANT: Network Configuration"
    echo "  - VIP IPs must be on the same network as the hypervisor ($TARGET_IP)"
    echo "  - VMs must be on a bridged network (not NAT) to use these VIP IPs"
    echo "  - If using default NAT network (192.168.122.0/24), VIP IPs won't be accessible"
    echo "  - kcli may handle network configuration automatically, but verify after deployment"
    echo ""

    if [ -n "${SNO_VIP_BASE:-}" ]; then
        print_info "Note: Using custom VIP base: $SNO_VIP_BASE (set via SNO_VIP_BASE env var)"
    else
        print_info "Note: VIP base calculated automatically from target IP + 1"
        print_info "      To customize, set SNO_VIP_BASE environment variable"
    fi
    echo ""

    read -p "Continue with these VIP IP assignments? (y/n) [y]: " confirm_vip
    confirm_vip=${confirm_vip:-y}

    # Function to validate IP address format
    validate_ip() {
        local ip=$1
        if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            IFS='.' read -ra ADDR <<< "$ip"
            for i in "${ADDR[@]}"; do
                if [[ $i -gt 255 ]]; then
                    return 1
                fi
            done
            return 0
        fi
        return 1
    }

    if [[ ! "$confirm_vip" =~ ^[Yy]$ ]]; then
        print_info "Please provide VIP IPs for each SNO:"
        echo ""

        # Prompt for each SNO's VIP IP
        for i in $(seq 1 $SNO_COUNT); do
            local vm_name="sno-$(printf "%02d" $i)"
            # Extract suggested IP from vip_plan array
            local suggested_vip=""
            for plan_entry in "${vip_plan[@]}"; do
                if [[ "$plan_entry" == "$vm_name:"* ]]; then
                    suggested_vip="${plan_entry#*:}"
                    break
                fi
            done

            local vip_ip=""

            while true; do
                read -p "  VIP IP for $vm_name [suggested: $suggested_vip]: " vip_ip
                vip_ip=${vip_ip:-$suggested_vip}  # Use suggested if empty

                if validate_ip "$vip_ip"; then
                    # Export VIP assignment as environment variable for deploy_sno_vm to use
                    # Replace hyphens with underscores in variable name (bash doesn't allow hyphens)
                    local vip_var_name="VIP_$(echo "$vm_name" | tr '-' '_')"
                    export "${vip_var_name}=${vip_ip}"
                    print_success "  $vm_name -> $vip_ip"
                    break
                else
                    print_error "  Invalid IP address format. Please enter a valid IP (e.g., 10.8.125.21)"
                fi
            done
        done

        echo ""
        print_info "Custom VIP IP assignments:"
        echo "  +--------+---------------+"
        echo "  |  SNO   |    VIP IP     |"
        echo "  +--------+---------------+"
        for i in $(seq 1 $SNO_COUNT); do
            local vm_name="sno-$(printf "%02d" $i)"
            local vip_var="VIP_$(echo "$vm_name" | tr '-' '_')"
            printf "  | %-6s | %-13s |\n" "$vm_name" "${!vip_var}"
        done
        echo "  +--------+---------------+"
        echo ""
    fi
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

                    # Get VIP IP
                    if [ -f "$vip_file" ]; then
                        local vip_ip=$(cat "$vip_file")
                        vip_assignments+=("$vm_name:$vip_ip")
                        print_info "  VIP IP: $vip_ip"
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

    # Summary
    print_info "=========================================="
    print_info "Deployment Summary"
    print_info "=========================================="
    print_success "Successful deployments: $successful_deployments"
    if [ $failed_deployments -gt 0 ]; then
        print_error "Failed deployments: $failed_deployments"
    fi
    echo ""

    # Display VIP IP assignments
    if [ ${#vip_assignments[@]} -gt 0 ]; then
        print_info "VIP IP Assignments:"
        for assignment in "${vip_assignments[@]}"; do
            local vm=$(echo "$assignment" | cut -d: -f1)
            local vip=$(echo "$assignment" | cut -d: -f2)
            echo "  $vm -> $vip"
        done
        echo ""
        print_info "Add these to /etc/hosts for local access:"
        for assignment in "${vip_assignments[@]}"; do
            local vm=$(echo "$assignment" | cut -d: -f1)
            local vip=$(echo "$assignment" | cut -d: -f2)
            local domain="${SNO_DOMAIN:-local}"
            echo "  $vip api.${vm}.${domain} console-openshift-console.apps.${vm}.${domain} oauth-openshift.apps.${vm}.${domain}"
        done
        echo ""
    fi

    # List deployed VMs on the remote host
    local host_name="sno-hypervisor-$(echo $TARGET_IP | tr '.' '-')"
    print_info "Deployed VMs on $TARGET_IP:"
    local existing_vms=$(kcli -C "$host_name" list vm 2>/dev/null | grep -E "^sno-" | awk '{print $1}' || echo "")

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
                local memory="${SNO_MEMORY:-16384}"
                local numcpus="${SNO_CPUS:-8}"
                local disk_size="${SNO_DISK_SIZE:-120}"

                if create_vm_from_iso "$vm_name" "$host_name" "$memory" "$numcpus" "$disk_size"; then
                    print_success "VM $vm_name created from existing ISO"
                else
                    print_warning "Failed to create VM $vm_name automatically"
                fi
            done

            # Check again after creation
            sleep 3
            existing_vms=$(kcli -C "$host_name" list vm 2>/dev/null | grep -E "^sno-" | awk '{print $1}' || echo "")
            if [ -n "$existing_vms" ]; then
                print_success "VMs now available:"
                echo "$existing_vms" | sed 's/^/  - /'
            fi
        else
            print_info "You can check manually with: kcli -C $host_name list vm"
            print_info "Or check on remote host: ssh $USER@$TARGET_IP 'virsh list --all'"
        fi
    fi

    print_info "=========================================="
    print_info "Next Steps:"
    print_info "=========================================="
    echo "1. Monitor deployment progress (on remote host $TARGET_IP):"
    echo "   kcli -C $host_name list vm"
    echo "   Or directly on remote: ssh $USER@$TARGET_IP 'virsh list --all'"
    echo ""
    echo "2. Check cluster status (once VM is running):"
    echo "   kcli -C $host_name ssh -u root sno-XX 'oc get nodes'"
    echo ""
    echo "3. Get kubeconfig:"
    echo "   kcli -C $host_name scp root@sno-XX:/root/auth/kubeconfig ./kubeconfig-sno-XX"
    echo ""
    echo "4. View deployment logs:"
    echo "   cat /tmp/kcli-sno-XX.log"
    echo ""
    echo "Note: VMs are being created on remote host: $TARGET_IP"
    echo "      All kcli commands must use: -C $host_name"
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
        echo "  - All local cluster directories (~/.kcli/clusters/sno-*)"
        echo "  - All ISO files and related resources"
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

    local host_name="sno-hypervisor-$(echo $target_ip | tr '.' '-')"

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

    print_info "Step 1: Listing all SNO clusters..."
    local sno_clusters=$(kcli get kube 2>/dev/null | grep -E "sno-|^sno[0-9]" | awk '{print $1}' || echo "")

    if [ -n "$sno_clusters" ]; then
        print_info "Found SNO clusters:"
        echo "$sno_clusters" | sed 's/^/  - /'
        echo ""

        print_info "Step 2: Deleting SNO kube clusters (using 'kcli delete kube')..."
        for cluster in $sno_clusters; do
            print_info "Deleting cluster: $cluster"
            # Use echo "y" to auto-confirm the deletion prompt
            echo "y" | kcli delete kube "$cluster" 2>&1 | while IFS= read -r line; do
                if echo "$line" | grep -q "Deleting directory"; then
                    print_success "  $line"
                else
                    echo "  $line"
                fi
            done
        done
        print_success "All SNO clusters deleted"
    else
        print_info "No SNO clusters found via 'kcli get kube'"
    fi
    echo ""

    print_info "Step 3: Deleting SNO VMs on remote host ($target_ip)..."
    local remote_vms=""

    # Try to get VMs via kcli first
    if kcli list host 2>/dev/null | grep -q "^$host_name"; then
        remote_vms=$(kcli -C "$host_name" list vm 2>/dev/null | grep -E "^sno-" | awk '{print $1}' || echo "")
    else
        # If kcli host not configured, try directly via virsh
        print_info "kcli host not configured, checking via virsh..."
        remote_vms=$(execute_remote_cmd "virsh list --all --name 2>/dev/null | grep -E '^sno-'" 2>/dev/null || echo "")
    fi

    if [ -n "$remote_vms" ]; then
        print_info "Found VMs on remote host:"
        echo "$remote_vms" | sed 's/^/  - /'
        echo ""

        for vm in $remote_vms; do
            print_info "Deleting VM: $vm"
            # Try kcli first if host is configured
            if kcli list host 2>/dev/null | grep -q "^$host_name"; then
                kcli -C "$host_name" delete vm "$vm" -y >/dev/null 2>&1 || {
                    print_warning "Failed to delete VM $vm via kcli, trying virsh..."
                    execute_remote_cmd "virsh destroy $vm" >/dev/null 2>&1 || true
                    execute_remote_cmd "virsh undefine $vm --remove-all-storage" >/dev/null 2>&1 || true
                }
            else
                # Use virsh directly
                execute_remote_cmd "virsh destroy $vm" >/dev/null 2>&1 || true
                execute_remote_cmd "virsh undefine $vm --remove-all-storage" >/dev/null 2>&1 || true
            fi
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

    print_info "Step 5: Cleaning up local cluster directories..."
    local local_clusters=$(find ~/.kcli/clusters -maxdepth 1 -type d -name "sno-*" -o -name "sno[0-9]*" 2>/dev/null | xargs -r basename -a || echo "")

    if [ -n "$local_clusters" ]; then
        print_info "Found local cluster directories:"
        echo "$local_clusters" | sed 's/^/  - /'
        echo ""

        for cluster in $local_clusters; do
            local cluster_dir="$HOME/.kcli/clusters/$cluster"
            if [ -d "$cluster_dir" ]; then
                print_info "Removing: $cluster_dir"
                rm -rf "$cluster_dir" || print_warning "Failed to remove $cluster_dir"
            fi
        done
    else
        print_info "No local SNO cluster directories found"
    fi
    echo ""

    print_info "Step 6: Cleaning up temporary files..."
    rm -f /tmp/kcli-sno-*.log
    rm -f /tmp/kcli-sno-*.pid
    rm -f /tmp/kcli-sno-*.exit
    rm -f /tmp/kcli-sno-*.vip
    rm -f /tmp/kcli-sno-*-params.yml
    print_success "Temporary files cleaned"
    echo ""

    print_info "Step 7: Final verification..."
    local remaining_clusters=$(kcli get kube 2>/dev/null | grep -E "sno-|^sno[0-9]" | awk '{print $1}' || echo "")
    local remaining_vms=$(kcli -C "$host_name" list vm 2>/dev/null | grep -E "^sno-" | awk '{print $1}' || echo "")

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

main "$@"

