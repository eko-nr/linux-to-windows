#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_VERSION="2.0"
LOG_FILE="/var/log/disk-mount-$(date +%Y%m%d_%H%M%S).log"

# Logging function
log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

print_header() {
    echo -e "${CYAN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  Auto Disk Partition & Mount Script v${SCRIPT_VERSION}        ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════╝${NC}\n"
}

print_section() {
    echo -e "\n${BLUE}▶ $1${NC}"
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then 
        log "${RED}✗ Error: Script must be run as root!${NC}"
        echo "Use: sudo $0"
        exit 1
    fi
}

# Install dependencies
install_dependencies() {
    local packages=("rsync" "parted" "blkid")
    local missing=()
    
    for pkg in "${packages[@]}"; do
        if ! command -v "$pkg" &> /dev/null; then
            missing+=("$pkg")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        print_section "Installing missing dependencies: ${missing[*]}"
        
        if command -v apt-get &> /dev/null; then
            apt-get update -qq && apt-get install -y "${missing[@]}"
        elif command -v yum &> /dev/null; then
            yum install -y "${missing[@]}"
        elif command -v dnf &> /dev/null; then
            dnf install -y "${missing[@]}"
        elif command -v pacman &> /dev/null; then
            pacman -Sy --noconfirm "${missing[@]}"
        else
            log "${RED}✗ Error: Cannot install dependencies automatically${NC}"
            exit 1
        fi
        log "${GREEN}✓ Dependencies installed successfully!${NC}"
    fi
}

# Detect partition naming convention
get_partition_name() {
    local disk=$1
    local part_num=$2
    
    if [[ $disk == *"nvme"* ]] || [[ $disk == *"mmcblk"* ]]; then
        echo "${disk}p${part_num}"
    else
        echo "${disk}${part_num}"
    fi
}

# Display available disks with detailed info
show_disks() {
    print_section "Available Disks"
    echo -e "${YELLOW}┌─────────────────────────────────────────────────────────────────┐${NC}"
    printf "%-10s %-10s %-12s %-10s %s\n" "DEVICE" "SIZE" "TYPE" "STATE" "MODEL"
    echo -e "${YELLOW}├─────────────────────────────────────────────────────────────────┤${NC}"
    
    while IFS= read -r line; do
        if [[ $line != NAME* ]]; then
            printf "%-10s %-10s %-12s %-10s %s\n" $line
        fi
    done < <(lsblk -d -n -o NAME,SIZE,TYPE,STATE,MODEL | grep disk)
    
    echo -e "${YELLOW}└─────────────────────────────────────────────────────────────────┘${NC}\n"
    
    # Show mounted disks
    echo -e "${CYAN}Currently mounted disks:${NC}"
    df -h | grep -E '^/dev/' | awk '{printf "  %s → %s (%s used)\n", $1, $6, $5}'
    echo ""
}

# Select disk interactively
select_disk() {
    local disks=()
    while IFS= read -r disk; do
        disks+=("$disk")
    done < <(lsblk -d -n -o NAME | grep -E '^(sd|nvme|vd|hd|mmcblk)')
    
    if [ ${#disks[@]} -eq 0 ]; then
        log "${RED}✗ No disks found!${NC}"
        exit 1
    fi
    
    echo -e "${YELLOW}Select disk:${NC}"
    for i in "${!disks[@]}"; do
        local disk="${disks[$i]}"
        local size=$(lsblk -d -n -o SIZE "/dev/$disk")
        local model=$(lsblk -d -n -o MODEL "/dev/$disk" | xargs)
        printf "  ${GREEN}[%d]${NC} %s (%s) - %s\n" $((i+1)) "$disk" "$size" "$model"
    done
    
    while true; do
        read -p "Enter number (1-${#disks[@]}): " selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#disks[@]} ]; then
            DISK_NAME="${disks[$((selection-1))]}"
            break
        fi
        echo -e "${RED}Invalid selection!${NC}"
    done
    
    DISK_PATH="/dev/${DISK_NAME}"
}

# Validate disk
validate_disk() {
    # Check if disk exists
    if [ ! -b "$DISK_PATH" ]; then
        log "${RED}✗ Error: Disk $DISK_PATH not found!${NC}"
        exit 1
    fi
    
    # Check if disk or any partition is mounted
    if mount | grep -q "^$DISK_PATH"; then
        log "${RED}✗ Error: Disk or its partitions are currently mounted!${NC}"
        mount | grep "^$DISK_PATH"
        echo -e "\nUnmount first with: umount <partition>"
        exit 1
    fi
    
    # Check if disk is in use
    if [ -n "$(lsof 2>/dev/null | grep "$DISK_PATH")" ]; then
        log "${YELLOW}⚠ Warning: Disk appears to be in use by some process${NC}"
        lsof 2>/dev/null | grep "$DISK_PATH"
        read -p "Continue anyway? (yes/no): " response
        [ "$response" != "yes" ] && exit 0
    fi
    
    # Show existing partitions
    if lsblk "$DISK_PATH" | grep -q part; then
        log "${YELLOW}⚠ Warning: This disk already has partitions:${NC}"
        lsblk "$DISK_PATH"
        read -p "Continue? All data will be LOST! (yes/no): " CONFIRM
        [ "$CONFIRM" != "yes" ] && exit 0
    fi
}

# Select filesystem type
select_filesystem() {
    echo -e "\n${YELLOW}Select filesystem type:${NC}"
    echo "  ${GREEN}[1]${NC} ext4 (recommended for Linux)"
    echo "  ${GREEN}[2]${NC} xfs (better for large files)"
    echo "  ${GREEN}[3]${NC} btrfs (advanced features, snapshots)"
    echo "  ${GREEN}[4]${NC} ext3 (older, more compatible)"
    
    while true; do
        read -p "Enter number (1-4) [default: 1]: " fs_choice
        fs_choice=${fs_choice:-1}
        
        case $fs_choice in
            1) FS_TYPE="ext4"; break ;;
            2) FS_TYPE="xfs"; break ;;
            3) FS_TYPE="btrfs"; break ;;
            4) FS_TYPE="ext3"; break ;;
            *) echo -e "${RED}Invalid selection!${NC}" ;;
        esac
    done
}

# Select partition scheme
select_partition_scheme() {
    echo -e "\n${YELLOW}Select partition scheme:${NC}"
    echo "  ${GREEN}[1]${NC} Single partition (use entire disk)"
    echo "  ${GREEN}[2]${NC} Custom partition size"
    
    while true; do
        read -p "Enter number (1-2) [default: 1]: " scheme_choice
        scheme_choice=${scheme_choice:-1}
        
        case $scheme_choice in
            1) 
                PARTITION_SCHEME="full"
                break 
                ;;
            2) 
                PARTITION_SCHEME="custom"
                local disk_size=$(lsblk -d -n -o SIZE -b "$DISK_PATH")
                local disk_size_gb=$((disk_size / 1024 / 1024 / 1024))
                echo -e "Available space: ${GREEN}${disk_size_gb}GB${NC}"
                read -p "Enter partition size (e.g., 50G, 500M) [default: all]: " PARTITION_SIZE
                PARTITION_SIZE=${PARTITION_SIZE:-100%}
                break
                ;;
            *) echo -e "${RED}Invalid selection!${NC}" ;;
        esac
    done
}

# Input and validate mountpoint
get_mountpoint() {
    echo -e "\n${YELLOW}Common mount points:${NC}"
    echo "  • /mnt/data - General data storage"
    echo "  • /var/lib/docker - Docker storage"
    echo "  • /home - User home directories"
    echo "  • /opt - Optional software"
    echo "  • Custom path"
    
    while true; do
        read -p "Enter mountpoint path: " MOUNTPOINT
        
        # Validate empty
        if [ -z "$MOUNTPOINT" ]; then
            log "${RED}✗ Mountpoint cannot be empty!${NC}"
            continue
        fi
        
        # Validate absolute path
        if [[ ! "$MOUNTPOINT" =~ ^/ ]]; then
            log "${RED}✗ Mountpoint must be an absolute path (start with /)${NC}"
            continue
        fi
        
        # Warn about critical paths
        local critical_paths=("/" "/boot" "/etc" "/usr" "/bin" "/sbin" "/lib" "/lib64" "/sys" "/proc" "/dev")
        local is_critical=false
        for cpath in "${critical_paths[@]}"; do
            if [ "$MOUNTPOINT" = "$cpath" ]; then
                log "${RED}✗ Cannot use critical system path: $cpath${NC}"
                is_critical=true
                break
            fi
        done
        [ "$is_critical" = true ] && continue
        
        # Check if already mounted
        if mountpoint -q "$MOUNTPOINT" 2>/dev/null; then
            log "${RED}✗ $MOUNTPOINT is already a mount point!${NC}"
            mount | grep "$MOUNTPOINT"
            continue
        fi
        
        # Check if in fstab
        if grep -q " $MOUNTPOINT " /etc/fstab; then
            log "${YELLOW}⚠ Warning: $MOUNTPOINT already in /etc/fstab${NC}"
            grep " $MOUNTPOINT " /etc/fstab
            read -p "Continue? (yes/no): " response
            [ "$response" != "yes" ] && continue
        fi
        
        break
    done
}

# Display configuration summary
show_summary() {
    print_section "Configuration Summary"
    echo -e "${YELLOW}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  Configuration Details                         ║${NC}"
    echo -e "${YELLOW}╠════════════════════════════════════════════════╣${NC}"
    printf "${YELLOW}║${NC}  %-20s : %-22s ${YELLOW}║${NC}\n" "Disk" "$DISK_PATH"
    printf "${YELLOW}║${NC}  %-20s : %-22s ${YELLOW}║${NC}\n" "Disk Size" "$(lsblk -d -n -o SIZE $DISK_PATH)"
    printf "${YELLOW}║${NC}  %-20s : %-22s ${YELLOW}║${NC}\n" "Partition" "$(get_partition_name $DISK_PATH 1)"
    printf "${YELLOW}║${NC}  %-20s : %-22s ${YELLOW}║${NC}\n" "Filesystem" "$FS_TYPE"
    printf "${YELLOW}║${NC}  %-20s : %-22s ${YELLOW}║${NC}\n" "Mount Point" "$MOUNTPOINT"
    printf "${YELLOW}║${NC}  %-20s : %-22s ${YELLOW}║${NC}\n" "Auto-mount" "Yes (via fstab)"
    echo -e "${YELLOW}╚════════════════════════════════════════════════╝${NC}"
    
    echo -e "\n${RED}⚠  WARNING: ALL DATA ON $DISK_PATH WILL BE PERMANENTLY DELETED! ⚠${NC}\n"
    
    read -p "Proceed with these settings? (yes/no): " FINAL_CONFIRM
    [ "$FINAL_CONFIRM" != "yes" ] && exit 0
}

# Create partition
create_partition() {
    print_section "Creating Partition"
    
    # Wipe existing partition table
    log "  Wiping existing partition table..."
    wipefs -af "$DISK_PATH" &>/dev/null || true
    dd if=/dev/zero of="$DISK_PATH" bs=512 count=1 &>/dev/null
    
    # Create new partition
    log "  Creating new partition..."
    if [ "$PARTITION_SCHEME" = "full" ]; then
        parted -s "$DISK_PATH" mklabel gpt
        parted -s "$DISK_PATH" mkpart primary "$FS_TYPE" 0% 100%
    else
        parted -s "$DISK_PATH" mklabel gpt
        parted -s "$DISK_PATH" mkpart primary "$FS_TYPE" 0% "$PARTITION_SIZE"
    fi
    
    # Wait for kernel to recognize partition
    sleep 2
    partprobe "$DISK_PATH" 2>/dev/null || true
    sleep 2
    
    PARTITION=$(get_partition_name "$DISK_PATH" 1)
    
    # Verify partition exists
    if [ ! -b "$PARTITION" ]; then
        log "${RED}✗ Failed to create partition!${NC}"
        exit 1
    fi
    
    log "${GREEN}✓ Partition created: $PARTITION${NC}"
}

# Format partition
format_partition() {
    print_section "Formatting Partition"
    
    log "  Formatting $PARTITION as $FS_TYPE..."
    
    case $FS_TYPE in
        ext4)
            mkfs.ext4 -F -L "$(basename $MOUNTPOINT)" "$PARTITION" &>/dev/null
            ;;
        ext3)
            mkfs.ext3 -F -L "$(basename $MOUNTPOINT)" "$PARTITION" &>/dev/null
            ;;
        xfs)
            mkfs.xfs -f -L "$(basename $MOUNTPOINT)" "$PARTITION" &>/dev/null
            ;;
        btrfs)
            mkfs.btrfs -f -L "$(basename $MOUNTPOINT)" "$PARTITION" &>/dev/null
            ;;
    esac
    
    if [ $? -ne 0 ]; then
        log "${RED}✗ Format failed!${NC}"
        exit 1
    fi
    
    log "${GREEN}✓ Partition formatted successfully${NC}"
}

# Backup and migrate data
backup_and_migrate() {
    if [ -d "$MOUNTPOINT" ] && [ "$(ls -A $MOUNTPOINT 2>/dev/null)" ]; then
        print_section "Backing Up Existing Data"
        
        local data_size=$(du -sh "$MOUNTPOINT" 2>/dev/null | awk '{print $1}')
        log "  Found existing data: ${YELLOW}${data_size}${NC}"
        
        read -p "Migrate data to new partition? (yes/no): " migrate
        
        if [ "$migrate" = "yes" ]; then
            # Mount to temporary location
            TMP_MOUNT="/mnt/tmp_newdisk_$$"
            mkdir -p "$TMP_MOUNT"
            mount "$PARTITION" "$TMP_MOUNT"
            
            log "  Copying data (this may take a while)..."
            rsync -avxHAX --info=progress2 "${MOUNTPOINT}/" "$TMP_MOUNT/"
            
            if [ $? -eq 0 ]; then
                log "${GREEN}✓ Data migration completed${NC}"
                umount "$TMP_MOUNT"
                rmdir "$TMP_MOUNT"
                
                # Backup original
                mv "$MOUNTPOINT" "${MOUNTPOINT}.old.$(date +%Y%m%d_%H%M%S)"
                log "  Original data backed up to: ${MOUNTPOINT}.old.*"
            else
                log "${RED}✗ Data migration failed!${NC}"
                umount "$TMP_MOUNT"
                rmdir "$TMP_MOUNT"
                exit 1
            fi
        else
            # Just rename
            mv "$MOUNTPOINT" "${MOUNTPOINT}.old.$(date +%Y%m%d_%H%M%S)"
            log "  Original directory renamed"
        fi
    else
        rm -rf "$MOUNTPOINT" 2>/dev/null || true
    fi
}

# Mount partition
mount_partition() {
    print_section "Mounting Partition"
    
    mkdir -p "$MOUNTPOINT"
    mount "$PARTITION" "$MOUNTPOINT"
    
    if [ $? -ne 0 ]; then
        log "${RED}✗ Mount failed!${NC}"
        exit 1
    fi
    
    log "${GREEN}✓ Partition mounted to $MOUNTPOINT${NC}"
}

# Add to fstab
update_fstab() {
    print_section "Updating /etc/fstab"
    
    # Get UUID
    UUID=$(blkid -s UUID -o value "$PARTITION")
    
    if [ -z "$UUID" ]; then
        log "${YELLOW}⚠ Warning: Could not get UUID, using device path${NC}"
        FSTAB_ENTRY="$PARTITION"
    else
        FSTAB_ENTRY="UUID=$UUID"
    fi
    
    # Check if entry exists
    if grep -q "$MOUNTPOINT" /etc/fstab; then
        log "${YELLOW}⚠ Entry already exists in /etc/fstab, skipping${NC}"
    else
        # Backup fstab
        cp /etc/fstab /etc/fstab.backup.$(date +%Y%m%d_%H%M%S)
        
        # Add entry
        echo "$FSTAB_ENTRY    $MOUNTPOINT    $FS_TYPE    defaults    0    2" >> /etc/fstab
        log "${GREEN}✓ Added to /etc/fstab (backup created)${NC}"
    fi
    
    # Test fstab
    if mount -a 2>/dev/null; then
        log "${GREEN}✓ /etc/fstab validation passed${NC}"
    else
        log "${YELLOW}⚠ /etc/fstab validation warning (mount may already be active)${NC}"
    fi
}

# Show final status
show_status() {
    print_section "Final Status"
    
    echo -e "${GREEN}✓ Operation completed successfully!${NC}\n"
    
    echo -e "${CYAN}Mount Information:${NC}"
    df -h "$MOUNTPOINT" | tail -1
    
    echo -e "\n${CYAN}Partition Details:${NC}"
    lsblk "$DISK_PATH"
    
    echo -e "\n${CYAN}Filesystem Info:${NC}"
    blkid "$PARTITION"
    
    if ls "${MOUNTPOINT}.old."* &>/dev/null; then
        echo -e "\n${YELLOW}Note:${NC} Old data backed up to: ${MOUNTPOINT}.old.*"
        echo "Remove with: rm -rf ${MOUNTPOINT}.old.*"
    fi
    
    echo -e "\n${GREEN}🎉 Disk successfully partitioned and mounted!${NC}"
    echo -e "Log file: ${LOG_FILE}"
}

# Main execution
main() {
    print_header
    
    check_root
    install_dependencies
    
    show_disks
    select_disk
    validate_disk
    
    select_filesystem
    select_partition_scheme
    get_mountpoint
    
    show_summary
    
    create_partition
    format_partition
    backup_and_migrate
    mount_partition
    update_fstab
    
    show_status
}

# Run main function
main "$@"