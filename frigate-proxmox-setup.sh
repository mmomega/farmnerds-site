#!/usr/bin/env bash

# Frigate NVR - Proxmox Host Setup Script
# Run this on your Proxmox host to configure GPU passthrough and create VM

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

function msg_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

function msg_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

function msg_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   msg_error "This script must be run as root"
   exit 1
fi

# Check if running on Proxmox
if [ ! -f /etc/pve/.version ]; then
    msg_error "This script must be run on a Proxmox host"
    exit 1
fi

echo "============================================"
echo "Frigate NVR - Proxmox Host Setup"
echo "============================================"
echo ""

# Configuration variables
msg_info "Configuration:"
read -p "Enter VM ID [401]: " VMID
VMID=${VMID:-401}

read -p "Enter VM name [frigate-nvr]: " VMNAME
VMNAME=${VMNAME:-frigate-nvr}

read -p "Enter CPU cores [8]: " CORES
CORES=${CORES:-8}

read -p "Enter RAM in MB [16384]: " RAM
RAM=${RAM:-16384}

read -p "Enter boot disk size in GB [32]: " BOOT_SIZE
BOOT_SIZE=${BOOT_SIZE:-32}

read -p "Enter storage disk size in GB [2000]: " STORAGE_SIZE
STORAGE_SIZE=${STORAGE_SIZE:-2000}

read -p "Enter network bridge [vmbr0]: " BRIDGE
BRIDGE=${BRIDGE:-vmbr0}

read -p "Enter storage pool for VM disks [local-zfs]: " STORAGE
STORAGE=${STORAGE:-local-zfs}

echo ""
msg_info "Detecting NVIDIA GPUs..."
echo ""

# Find NVIDIA GPUs
mapfile -t GPU_LIST < <(lspci -nn | grep -i nvidia | grep -i vga)

if [ ${#GPU_LIST[@]} -eq 0 ]; then
    msg_error "No NVIDIA GPUs found!"
    exit 1
fi

echo "Found NVIDIA GPU(s):"
for i in "${!GPU_LIST[@]}"; do
    echo "  [$i] ${GPU_LIST[$i]}"
done
echo ""

read -p "Select GPU number to pass through [0]: " GPU_INDEX
GPU_INDEX=${GPU_INDEX:-0}

if [ $GPU_INDEX -ge ${#GPU_LIST[@]} ]; then
    msg_error "Invalid GPU selection"
    exit 1
fi

# Extract PCI address and IDs
GPU_LINE="${GPU_LIST[$GPU_INDEX]}"
PCI_ADDR=$(echo "$GPU_LINE" | awk '{print $1}')
GPU_ID=$(echo "$GPU_LINE" | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}(?=\])' | head -1)

msg_info "Selected GPU:"
echo "  PCI Address: $PCI_ADDR"
echo "  Device ID: $GPU_ID"

# Find audio controller for the same GPU
AUDIO_ID=$(lspci -nn | grep "$PCI_ADDR" | grep -i audio | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}(?=\])' | head -1)
if [ -n "$AUDIO_ID" ]; then
    msg_info "Found GPU audio controller: $AUDIO_ID"
else
    msg_warn "No audio controller found for this GPU"
fi

echo ""
read -p "Continue with this configuration? (y/n): " CONFIRM
if [[ ! $CONFIRM =~ ^[Yy]$ ]]; then
    msg_info "Setup cancelled"
    exit 0
fi

echo ""
msg_info "Step 1/7: Checking IOMMU configuration..."

# Check if IOMMU is enabled in GRUB
if grep -q "amd_iommu=on" /etc/default/grub && grep -q "iommu=pt" /etc/default/grub; then
    msg_info "IOMMU already enabled in GRUB"
else
    msg_warn "Enabling IOMMU in GRUB..."
    cp /etc/default/grub /etc/default/grub.backup
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet amd_iommu=on iommu=pt pcie_acs_override=downstream,multifunction video=efifb:off"/' /etc/default/grub
    update-grub
    msg_info "IOMMU enabled - reboot will be required"
    NEED_REBOOT=1
fi

msg_info "Step 2/7: Configuring VFIO modules..."

# Add VFIO modules
if ! grep -q "vfio" /etc/modules; then
    cat >> /etc/modules << EOF
vfio
vfio_iommu_type1
vfio_pci
vfio_virqfd
EOF
    msg_info "VFIO modules added"
    NEED_REBOOT=1
else
    msg_info "VFIO modules already configured"
fi

msg_info "Step 3/7: Blacklisting NVIDIA drivers on host..."

cat > /etc/modprobe.d/blacklist-nvidia.conf << EOF
blacklist nouveau
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidiafb
blacklist snd_hda_intel
EOF
msg_info "NVIDIA drivers blacklisted"

msg_info "Step 4/7: Binding GPU to VFIO..."

# Build VFIO IDs list
VFIO_IDS="$GPU_ID"
if [ -n "$AUDIO_ID" ]; then
    VFIO_IDS="$VFIO_IDS,$AUDIO_ID"
fi

cat > /etc/modprobe.d/vfio.conf << EOF
options vfio-pci ids=$VFIO_IDS
softdep nvidia pre: vfio-pci
EOF
msg_info "GPU bound to VFIO (IDs: $VFIO_IDS)"
NEED_REBOOT=1

msg_info "Step 5/7: Updating initramfs..."
update-initramfs -u -k all
msg_info "Initramfs updated"

msg_info "Step 6/7: Downloading Ubuntu ISO..."

ISO_DIR="/var/lib/vz/template/iso"
ISO_FILE="ubuntu-24.04.1-live-server-amd64.iso"
ISO_PATH="$ISO_DIR/$ISO_FILE"

if [ -f "$ISO_PATH" ]; then
    msg_info "Ubuntu ISO already exists"
else
    mkdir -p "$ISO_DIR"
    wget -O "$ISO_PATH" "https://releases.ubuntu.com/24.04/ubuntu-24.04.1-live-server-amd64.iso"
    msg_info "Ubuntu ISO downloaded"
fi

# Check if reboot is needed before creating VM
if [ "${NEED_REBOOT}" = "1" ]; then
    echo ""
    msg_warn "============================================"
    msg_warn "REBOOT REQUIRED"
    msg_warn "============================================"
    msg_warn "GPU passthrough configuration requires a reboot."
    echo ""
    echo "After reboot, run this script again to create the VM."
    echo "The script will detect the configuration is complete and skip to VM creation."
    echo ""
    read -p "Reboot now? (y/n): " REBOOT_NOW
    if [[ $REBOOT_NOW =~ ^[Yy]$ ]]; then
        msg_info "Rebooting..."
        reboot
    else
        msg_info "Please reboot manually and re-run this script"
        exit 0
    fi
fi

msg_info "Step 7/7: Creating Frigate VM..."

# Check if VM already exists
if qm status $VMID &>/dev/null; then
    msg_error "VM $VMID already exists!"
    read -p "Destroy and recreate? (y/n): " DESTROY
    if [[ $DESTROY =~ ^[Yy]$ ]]; then
        qm stop $VMID || true
        qm destroy $VMID
    else
        exit 1
    fi
fi

# Create VM
qm create $VMID \
  --name "$VMNAME" \
  --memory $RAM \
  --cores $CORES \
  --cpu host \
  --machine q35 \
  --bios ovmf \
  --net0 virtio,bridge=$BRIDGE \
  --ostype l26

# Add EFI disk
qm set $VMID --efidisk0 $STORAGE:1,efitype=4m,pre-enrolled-keys=0

# Add boot disk
qm set $VMID --scsi0 $STORAGE:$BOOT_SIZE,cache=writethrough,discard=on,ssd=1

# Add storage disk
qm set $VMID --scsi1 $STORAGE:$STORAGE_SIZE,cache=writethrough,discard=on,ssd=1

# Pass through GPU
qm set $VMID --hostpci0 $PCI_ADDR,pcie=1,x-vga=0

# Set boot order
qm set $VMID --boot order=scsi0

# Attach ISO
qm set $VMID --ide2 local:iso/$ISO_FILE,media=cdrom

# Add args for better GPU compatibility
VM_CONF="/etc/pve/qemu-server/${VMID}.conf"
if ! grep -q "^args:" "$VM_CONF"; then
    echo "args: -cpu host,kvm=off,hv_vendor_id=proxmox" >> "$VM_CONF"
fi

msg_info "VM created successfully!"

echo ""
echo "============================================"
echo "SETUP COMPLETE!"
echo "============================================"
echo ""
echo "VM Configuration:"
echo "  VM ID: $VMID"
echo "  Name: $VMNAME"
echo "  Cores: $CORES"
echo "  RAM: ${RAM}MB"
echo "  Boot disk: ${BOOT_SIZE}GB"
echo "  Storage disk: ${STORAGE_SIZE}GB"
echo "  GPU: $PCI_ADDR ($GPU_ID)"
echo ""
echo "Next Steps:"
echo "1. Start the VM: qm start $VMID"
echo "2. Open VM console and install Ubuntu"
echo "3. After Ubuntu install, run the VM setup script inside the VM"
echo ""
msg_info "Starting VM now..."
qm start $VMID

echo ""
msg_info "VM is starting. Open the Proxmox console to complete Ubuntu installation."
msg_info "After Ubuntu is installed, copy and run the 'frigate-vm-setup.sh' script inside the VM."
