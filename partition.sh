#!/bin/bash

# Script for automatic disk partitioning and mounting
# Author: Assistant
# Warning: Run with caution, can delete data!

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Auto Disk Partition & Mount Script ===${NC}\n"

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Error: Script must be run as root!${NC}"
    echo "Use: sudo $0"
    exit 1
fi

# Check and install rsync if not available
if ! command -v rsync &> /dev/null; then
    echo -e "${YELLOW}rsync not installed, installing...${NC}"
    if command -v apt-get &> /dev/null; then
        apt-get update -qq && apt-get install -y rsync
    elif command -v yum &> /dev/null; then
        yum install -y rsync
    elif command -v dnf &> /dev/null; then
        dnf install -y rsync
    else
        echo -e "${RED}Error: Cannot install rsync automatically${NC}"
        echo "Install manually with: apt-get install rsync or yum install rsync"
        exit 1
    fi
    echo -e "${GREEN}rsync successfully installed!${NC}\n"
fi

# Display available disks
echo -e "${YELLOW}Available disks:${NC}"
lsblk -d -o NAME,SIZE,TYPE,MODEL | grep disk
echo ""

# Input disk to partition
read -p "Enter disk name (example: sdb): " DISK_NAME
DISK_PATH="/dev/${DISK_NAME}"

# Validate disk exists
if [ ! -b "$DISK_PATH" ]; then
    echo -e "${RED}Error: Disk $DISK_PATH not found!${NC}"
    exit 1
fi

# Warning if disk already has partitions
if lsblk "$DISK_PATH" | grep -q part; then
    echo -e "${YELLOW}Warning: This disk already has partitions!${NC}"
    lsblk "$DISK_PATH"
    read -p "Continue? All data will be LOST! (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "Cancelled."
        exit 0
    fi
fi

# Input mountpoint
echo -e "\n${YELLOW}Enter target mount directory:${NC}"
echo "Examples: /root, /var/lib/docker, /home, /opt"
read -p "Mountpoint: " MOUNTPOINT

# SAFETY CHECK: Reject if mounting to /
if [ "$MOUNTPOINT" = "/" ]; then
    echo -e "${RED}ERROR: Mounting to / (root filesystem) is NOT ALLOWED!${NC}"
    echo "Reasons:"
    echo "  - System will crash"
    echo "  - Risk of data loss"
    echo "  - Requires recovery mode to do this"
    echo ""
    echo "Use another mountpoint like: /root, /var/lib/docker, /home, etc."
    exit 1
fi

# Validate mountpoint
if [ -z "$MOUNTPOINT" ]; then
    echo -e "${RED}Error: Mountpoint cannot be empty!${NC}"
    exit 1
fi

# Check if mountpoint is already mounted
if mountpoint -q "$MOUNTPOINT" 2>/dev/null; then
    echo -e "${RED}Error: $MOUNTPOINT is already mounted!${NC}"
    echo "Unmount first with: umount $MOUNTPOINT"
    exit 1
fi

# Display summary
echo -e "\n${YELLOW}=== SUMMARY ===${NC}"
echo "Disk        : $DISK_PATH"
echo "Partition   : ${DISK_PATH}1"
echo "Mountpoint  : $MOUNTPOINT"
echo "Filesystem  : ext4"
echo ""
echo -e "${RED}WARNING: All data on $DISK_PATH will be DELETED!${NC}"
read -p "Continue? (yes/no): " FINAL_CONFIRM

if [ "$FINAL_CONFIRM" != "yes" ]; then
    echo "Cancelled."
    exit 0
fi

echo -e "\n${GREEN}Starting process...${NC}\n"

# 1. Create partition
echo "1. Creating partition on $DISK_PATH..."
(
echo n   # New partition
echo p   # Primary
echo 1   # Partition number
echo     # First sector (default)
echo     # Last sector (default)
echo w   # Write changes
) | fdisk "$DISK_PATH" > /dev/null 2>&1

# Wait for system to detect new partition
sleep 2
partprobe "$DISK_PATH" 2>/dev/null || true
sleep 1

PARTITION="${DISK_PATH}1"

# 2. Format partition
echo "2. Formatting partition $PARTITION with ext4..."
mkfs.ext4 -F "$PARTITION" > /dev/null 2>&1

# 3. Backup data if mountpoint exists
BACKUP_DIR=""
if [ -d "$MOUNTPOINT" ] && [ "$(ls -A $MOUNTPOINT)" ]; then
    echo "3. Backing up data from $MOUNTPOINT..."
    BACKUP_DIR="/mnt/backup_$(basename $MOUNTPOINT)_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    # Mount temporary
    TMP_MOUNT="/mnt/tmp_newdisk"
    mkdir -p "$TMP_MOUNT"
    mount "$PARTITION" "$TMP_MOUNT"
    
    # Copy data
    echo "   Copying data... (this may take a while)"
    rsync -avxHAX "${MOUNTPOINT}/" "$TMP_MOUNT/" --quiet
    
    # Unmount temporary
    umount "$TMP_MOUNT"
    rmdir "$TMP_MOUNT"
    
    # Backup original directory
    mv "$MOUNTPOINT" "${MOUNTPOINT}.old"
else
    echo "3. No data to backup."
    rm -rf "$MOUNTPOINT" 2>/dev/null || true
fi

# 4. Create mountpoint directory
echo "4. Creating directory $MOUNTPOINT..."
mkdir -p "$MOUNTPOINT"

# 5. Mount partition
echo "5. Mounting $PARTITION to $MOUNTPOINT..."
mount "$PARTITION" "$MOUNTPOINT"

# 6. Add to /etc/fstab for auto-mount
echo "6. Adding entry to /etc/fstab..."
if ! grep -q "$PARTITION" /etc/fstab; then
    echo "$PARTITION    $MOUNTPOINT    ext4    defaults    0    2" >> /etc/fstab
    echo "   Entry added to /etc/fstab"
else
    echo "   Entry already exists in /etc/fstab"
fi

# 7. Verify
echo -e "\n${GREEN}=== COMPLETED ===${NC}"
echo -e "\n${YELLOW}Verification:${NC}"
df -h "$MOUNTPOINT"
echo ""
lsblk "$DISK_PATH"

if [ -d "${MOUNTPOINT}.old" ]; then
    echo -e "\n${YELLOW}NOTE:${NC}"
    echo "Old data backed up to: ${MOUNTPOINT}.old"
    echo "If everything is OK, remove with: rm -rf ${MOUNTPOINT}.old"
fi

echo -e "\n${GREEN}Mounting successful!${NC}"