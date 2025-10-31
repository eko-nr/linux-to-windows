#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_VERSION="3.0"
LOG_FILE="/var/log/disk-mount-$(date +%Y%m%d_%H%M%S).log"

# Global variables for multi-partition
declare -a PARTITIONS=()
declare -a MOUNT_POINTS=()
declare -a SIZES=()
declare -a FILESYSTEMS=()

# Logging function
log() {
    echo -e "$1" | tee -a "$LOG_FILE"
}

print_header() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  Universal Disk Partition & Mount Script v${SCRIPT_VERSION}         ║${NC}"
    echo -e "${CYAN}║  Single & Multi-Partition Support                        ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}\n"
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

# Detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
        log "${GREEN}✓ Detected OS: $OS $VER${NC}"
    else
        log "${YELLOW}⚠ Cannot detect OS, assuming generic Linux${NC}"
        OS="Unknown"
    fi
}

# Install dependencies
install_dependencies() {
    local missing=()
    
    for pkg in rsync parted; do
        if ! command -v "$pkg" &> /dev/null; then
            missing+=("$pkg")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        print_section "Installing dependencies: ${missing[*]}"
        
        if command -v apt-get &> /dev/null; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq && apt-get install -y -qq "${missing[@]}" 2>/dev/null
        elif command -v yum &> /dev/null; then
            yum install -y -q "${missing[@]}" 2>/dev/null
        elif command -v dnf &> /dev/null; then
            dnf install -y -q "${missing[@]}" 2>/dev/null
        else
            log "${RED}✗ Error: Cannot install dependencies${NC}"
            exit 1
        fi
        log "${GREEN}✓ Dependencies installed!${NC}"
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

# Display available disks
show_disks() {
    print_section "Available Disks"
    echo -e "${YELLOW}┌──────────────────────────────────────────────────────────────────────┐${NC}"
    printf "  ${CYAN}%-12s %-10s %-10s %-20s${NC}\n" "DEVICE" "SIZE" "TYPE" "MODEL"
    echo -e "${YELLOW}├──────────────────────────────────────────────────────────────────────┤${NC}"
    
    while IFS= read -r line; do
        if [[ $line != NAME* ]]; then
            printf "  %-12s %-10s %-10s %-20s\n" $line
        fi
    done < <(lsblk -d -n -o NAME,SIZE,TYPE,MODEL | grep disk)
    
    echo -e "${YELLOW}└──────────────────────────────────────────────────────────────────────┘${NC}\n"
    
    echo -e "${CYAN}Currently mounted:${NC}"
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
        printf "  ${GREEN}[%d]${NC} %-10s (%s) - %s\n" $((i+1)) "$disk" "$size" "$model"
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
    DISK_SIZE_BYTES=$(lsblk -d -n -b -o SIZE "$DISK_PATH")
    DISK_SIZE_GB=$((DISK_SIZE_BYTES / 1024 / 1024 / 1024))
}

# Validate disk
validate_disk() {
    if [ ! -b "$DISK_PATH" ]; then
        log "${RED}✗ Error: Disk $DISK_PATH not found!${NC}"
        exit 1
    fi
    
    if mount | grep -q "^$DISK_PATH"; then
        log "${RED}✗ Error: Disk partitions are mounted!${NC}"
        mount | grep "^$DISK_PATH"
        exit 1
    fi
    
    if lsblk "$DISK_PATH" | grep -q part; then
        log "${YELLOW}⚠ Warning: Disk has existing partitions:${NC}"
        lsblk "$DISK_PATH"
        echo ""
        read -p "Continue? ALL DATA WILL BE LOST! (yes/no): " CONFIRM
        [ "$CONFIRM" != "yes" ] && exit 0
    fi
    
    log "${GREEN}✓ Disk validated: $DISK_PATH (${DISK_SIZE_GB}GB)${NC}"
}

# Select partition mode
select_partition_mode() {
    echo -e "\n${YELLOW}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  Select Partitioning Mode                        ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════╝${NC}\n"
    
    echo -e "  ${GREEN}[1]${NC} ${CYAN}Single Partition${NC}"
    echo -e "      Mount entire disk to ONE directory"
    echo -e "      Example: 500GB → /data"
    echo ""
    echo -e "  ${GREEN}[2]${NC} ${MAGENTA}Multi-Partition${NC}"
    echo -e "      Split disk into MULTIPLE partitions"
    echo -e "      Example: 20%→/root, 30%→/var, 50%→/opt"
    echo ""
    
    while true; do
        read -p "Enter choice (1-2) [default: 1]: " mode_choice
        mode_choice=${mode_choice:-1}
        
        case $mode_choice in
            1) 
                PARTITION_MODE="single"
                log "${GREEN}✓ Selected: Single Partition${NC}"
                break 
                ;;
            2) 
                PARTITION_MODE="multi"
                log "${GREEN}✓ Selected: Multi-Partition${NC}"
                break 
                ;;
            *) echo -e "${RED}Invalid selection!${NC}" ;;
        esac
    done
}

# Select filesystem type
select_filesystem() {
    local prompt_msg="${1:-Select filesystem type}"
    
    echo -e "\n${YELLOW}${prompt_msg}:${NC}"
    echo "  ${GREEN}[1]${NC} ext4 (recommended, stable)"
    echo "  ${GREEN}[2]${NC} xfs (better for large files)"
    echo "  ${GREEN}[3]${NC} btrfs (advanced features)"
    echo "  ${GREEN}[4]${NC} ext3 (legacy compatibility)"
    
    while true; do
        read -p "Choice (1-4) [default: 1]: " fs_choice
        fs_choice=${fs_choice:-1}
        
        case $fs_choice in
            1) FS_TYPE="ext4"; break ;;
            2) FS_TYPE="xfs"; break ;;
            3) FS_TYPE="btrfs"; break ;;
            4) FS_TYPE="ext3"; break ;;
            *) echo -e "${RED}Invalid!${NC}" ;;
        esac
    done
}

# Validate mountpoint
validate_mountpoint() {
    local mp=$1
    
    # Check empty
    if [ -z "$mp" ]; then
        echo "empty"
        return 1
    fi
    
    # Check absolute path
    if [[ ! "$mp" =~ ^/ ]]; then
        echo "not_absolute"
        return 1
    fi
    
    # Check critical paths
    local critical=("/" "/boot" "/etc" "/usr" "/bin" "/sbin" "/lib" "/lib64" "/sys" "/proc" "/dev")
    for cpath in "${critical[@]}"; do
        if [ "$mp" = "$cpath" ]; then
            echo "critical"
            return 1
        fi
    done
    
    # Check if already in list
    for existing in "${MOUNT_POINTS[@]}"; do
        if [ "$existing" = "$mp" ]; then
            echo "duplicate"
            return 1
        fi
    done
    
    # Check if already mounted
    if mountpoint -q "$mp" 2>/dev/null; then
        echo "mounted"
        return 1
    fi
    
    echo "valid"
    return 0
}

# Get mountpoint input
get_mountpoint_input() {
    local prompt_msg="$1"
    
    while true; do
        read -p "$prompt_msg" mp_input
        
        local validation=$(validate_mountpoint "$mp_input")
        
        case $validation in
            "valid")
                MOUNTPOINT="$mp_input"
                return 0
                ;;
            "empty")
                log "${RED}✗ Mountpoint cannot be empty!${NC}"
                ;;
            "not_absolute")
                log "${RED}✗ Must be absolute path (start with /)${NC}"
                ;;
            "critical")
                log "${RED}✗ Cannot use critical system path!${NC}"
                ;;
            "duplicate")
                log "${RED}✗ Already in partition list!${NC}"
                ;;
            "mounted")
                log "${RED}✗ Already mounted!${NC}"
                ;;
        esac
    done
}

# Configure single partition
configure_single_partition() {
    print_section "Single Partition Configuration"
    
    echo -e "${CYAN}Disk size: ${GREEN}${DISK_SIZE_GB}GB${NC}\n"
    
    # Show common examples
    echo -e "${YELLOW}Common mountpoint examples:${NC}"
    echo "  • /data        - General data storage"
    echo "  • /mnt/storage - External storage mount"
    echo "  • /opt         - Optional software"
    echo "  • /srv         - Service data"
    echo "  • /backup      - Backup storage"
    echo "  • Any custom path you want"
    echo ""
    
    # Get mountpoint
    get_mountpoint_input "Enter mountpoint (e.g., /data): "
    
    # Select filesystem
    select_filesystem
    
    # Store configuration
    PARTITIONS=("$(get_partition_name $DISK_PATH 1)")
    MOUNT_POINTS=("$MOUNTPOINT")
    SIZES=("100")
    FILESYSTEMS=("$FS_TYPE")
    
    log "${GREEN}✓ Configuration: ${DISK_SIZE_GB}GB → $MOUNTPOINT ($FS_TYPE)${NC}"
}

# Configure multi-partition
configure_multi_partition() {
    print_section "Multi-Partition Configuration"
    
    echo -e "${CYAN}Total disk size: ${GREEN}${DISK_SIZE_GB}GB${NC}\n"
    
    # Show presets
    echo -e "${YELLOW}Quick Presets (or choose Custom):${NC}"
    echo -e "  ${GREEN}[1]${NC} Docker:    20%→/root, 30%→/var, 50%→/opt"
    echo -e "  ${GREEN}[2]${NC} Web:       15%→/root, 25%→/var, 40%→/srv, 20%→/data"
    echo -e "  ${GREEN}[3]${NC} Database:  10%→/root, 20%→/var, 60%→/data, 10%→/backup"
    echo -e "  ${GREEN}[4]${NC} General:   20%→/root, 30%→/var, 30%→/opt, 20%→/data"
    echo -e "  ${GREEN}[5]${NC} ${CYAN}Custom (define your own)${NC}"
    echo ""
    
    read -p "Select (1-5) [default: 5]: " preset
    preset=${preset:-5}
    
    case $preset in
        1) apply_preset "/root:20:ext4" "/var:30:ext4" "/opt:50:ext4" ;;
        2) apply_preset "/root:15:ext4" "/var:25:ext4" "/srv:40:ext4" "/data:20:xfs" ;;
        3) apply_preset "/root:10:ext4" "/var:20:ext4" "/data:60:xfs" "/backup:10:ext4" ;;
        4) apply_preset "/root:20:ext4" "/var:30:ext4" "/opt:30:ext4" "/data:20:xfs" ;;
        5) configure_custom_partitions ;;
        *) log "${RED}Invalid, using custom${NC}"; configure_custom_partitions ;;
    esac
}

# Apply preset configuration
apply_preset() {
    local configs=("$@")
    
    for config in "${configs[@]}"; do
        IFS=':' read -r mp size fs <<< "$config"
        MOUNT_POINTS+=("$mp")
        SIZES+=("$size")
        FILESYSTEMS+=("$fs")
    done
    
    for i in "${!MOUNT_POINTS[@]}"; do
        PARTITIONS+=("$(get_partition_name $DISK_PATH $((i+1)))")
    done
    
    log "${GREEN}✓ Preset applied${NC}"
}

# Configure custom partitions
configure_custom_partitions() {
    echo -e "\n${CYAN}═══ Custom Multi-Partition Setup ═══${NC}"
    echo -e "${YELLOW}Define each partition manually${NC}\n"
    
    local remaining=100
    local part_num=1
    
    while true; do
        if [ $remaining -le 0 ]; then
            log "${GREEN}✓ All space allocated!${NC}"
            break
        fi
        
        echo -e "\n${MAGENTA}━━━ Partition #$part_num ━━━${NC}"
        echo -e "Remaining: ${GREEN}${remaining}%${NC} (≈$((DISK_SIZE_GB * remaining / 100))GB)"
        
        # Ask if user wants to add partition
        if [ $part_num -gt 1 ]; then
            read -p "Add another partition? (yes/no): " add_more
            if [ "$add_more" != "yes" ]; then
                # Use remaining space for last partition
                if [ ${#MOUNT_POINTS[@]} -gt 0 ]; then
                    SIZES[$((${#SIZES[@]}-1))]=$((${SIZES[$((${#SIZES[@]}-1))]} + remaining))
                    log "${GREEN}✓ Remaining ${remaining}% added to last partition${NC}"
                fi
                break
            fi
        fi
        
        # Get mountpoint
        echo ""
        echo -e "${YELLOW}Examples: /root, /var, /opt, /data, /backup, /home, /srv${NC}"
        get_mountpoint_input "Mountpoint: "
        
        # Get size percentage
        while true; do
            read -p "Size in % (1-${remaining}): " size_input
            if [[ "$size_input" =~ ^[0-9]+$ ]] && [ "$size_input" -ge 1 ] && [ "$size_input" -le "$remaining" ]; then
                SIZE_PERCENT=$size_input
                break
            fi
            echo -e "${RED}Invalid! Must be 1-${remaining}${NC}"
        done
        
        # Select filesystem
        select_filesystem "Filesystem for $MOUNTPOINT"
        
        # Store configuration
        MOUNT_POINTS+=("$MOUNTPOINT")
        SIZES+=("$SIZE_PERCENT")
        FILESYSTEMS+=("$FS_TYPE")
        PARTITIONS+=("$(get_partition_name $DISK_PATH $part_num)")
        
        remaining=$((remaining - SIZE_PERCENT))
        size_gb=$((DISK_SIZE_GB * SIZE_PERCENT / 100))
        
        log "${GREEN}✓ Added: ${size_gb}GB → $MOUNTPOINT ($FS_TYPE)${NC}"
        
        part_num=$((part_num + 1))
    done
    
    if [ ${#MOUNT_POINTS[@]} -eq 0 ]; then
        log "${RED}✗ No partitions configured!${NC}"
        exit 1
    fi
}

# Show summary
show_summary() {
    print_section "Configuration Summary"
    
    echo -e "${YELLOW}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  Disk: ${DISK_PATH} (${DISK_SIZE_GB}GB)${NC}"
    echo -e "${YELLOW}╠═══════════════════════════════════════════════════════╣${NC}"
    
    for i in "${!PARTITIONS[@]}"; do
        local size_gb=$((DISK_SIZE_GB * ${SIZES[$i]} / 100))
        printf "${YELLOW}║${NC}  ${GREEN}%-15s${NC} → %-15s %5dGB  %-8s ${YELLOW}║${NC}\n" \
            "${PARTITIONS[$i]}" "${MOUNT_POINTS[$i]}" "$size_gb" "${FILESYSTEMS[$i]}"
    done
    
    echo -e "${YELLOW}╚═══════════════════════════════════════════════════════╝${NC}"
    
    echo -e "\n${RED}⚠  WARNING: ALL DATA ON $DISK_PATH WILL BE DELETED! ⚠${NC}\n"
    
    read -p "Proceed? (yes/no): " confirm
    [ "$confirm" != "yes" ] && exit 0
}

# Create partitions
create_partitions() {
    print_section "Creating Partitions"
    
    log "  Wiping disk..."
    wipefs -af "$DISK_PATH" &>/dev/null || true
    dd if=/dev/zero of="$DISK_PATH" bs=512 count=1 &>/dev/null
    
    log "  Creating GPT partition table..."
    parted -s "$DISK_PATH" mklabel gpt
    
    local start=0
    for i in "${!PARTITIONS[@]}"; do
        local size=${SIZES[$i]}
        local end=$((start + size))
        local fs=${FILESYSTEMS[$i]}
        
        log "  Creating partition $((i+1)): ${size}% ($fs)"
        parted -s "$DISK_PATH" mkpart primary "$fs" "${start}%" "${end}%"
        
        start=$end
    done
    
    sleep 3
    partprobe "$DISK_PATH" 2>/dev/null || true
    sleep 2
    
    log "${GREEN}✓ Partitions created${NC}"
}

# Format partitions
format_partitions() {
    print_section "Formatting Partitions"
    
    for i in "${!PARTITIONS[@]}"; do
        local part="${PARTITIONS[$i]}"
        local fs="${FILESYSTEMS[$i]}"
        local label=$(basename "${MOUNT_POINTS[$i]}")
        
        log "  Formatting $part as $fs..."
        
        case $fs in
            ext4) mkfs.ext4 -F -L "$label" "$part" &>/dev/null ;;
            ext3) mkfs.ext3 -F -L "$label" "$part" &>/dev/null ;;
            xfs) mkfs.xfs -f -L "$label" "$part" &>/dev/null ;;
            btrfs) mkfs.btrfs -f -L "$label" "$part" &>/dev/null ;;
        esac
        
        if [ $? -ne 0 ]; then
            log "${RED}✗ Format failed for $part!${NC}"
            exit 1
        fi
    done
    
    log "${GREEN}✓ All partitions formatted${NC}"
}

# Backup and mount
backup_and_mount() {
    print_section "Mounting Partitions"
    
    for i in "${!PARTITIONS[@]}"; do
        local part="${PARTITIONS[$i]}"
        local mp="${MOUNT_POINTS[$i]}"
        
        # Backup if directory exists with data
        if [ -d "$mp" ] && [ "$(ls -A $mp 2>/dev/null)" ]; then
            local backup="${mp}.backup.$(date +%Y%m%d_%H%M%S)"
            log "  Backing up $mp → $backup"
            mv "$mp" "$backup"
        else
            rm -rf "$mp" 2>/dev/null || true
        fi
        
        # Create and mount
        mkdir -p "$mp"
        mount "$part" "$mp"
        
        if [ $? -eq 0 ]; then
            log "${GREEN}✓ Mounted: $part → $mp${NC}"
        else
            log "${RED}✗ Mount failed: $part${NC}"
            exit 1
        fi
    done
}

# Update fstab
update_fstab() {
    print_section "Updating /etc/fstab"
    
    cp /etc/fstab /etc/fstab.backup.$(date +%Y%m%d_%H%M%S)
    
    for i in "${!PARTITIONS[@]}"; do
        local part="${PARTITIONS[$i]}"
        local mp="${MOUNT_POINTS[$i]}"
        local fs="${FILESYSTEMS[$i]}"
        local uuid=$(blkid -s UUID -o value "$part")
        
        if grep -q " $mp " /etc/fstab; then
            log "${YELLOW}⚠ $mp already in fstab, skipping${NC}"
            continue
        fi
        
        if [ -n "$uuid" ]; then
            echo "UUID=$uuid    $mp    $fs    defaults    0    2" >> /etc/fstab
            log "${GREEN}✓ Added to fstab: $mp${NC}"
        else
            log "${YELLOW}⚠ No UUID for $part, using device path${NC}"
            echo "$part    $mp    $fs    defaults    0    2" >> /etc/fstab
        fi
    done
}

# Show final status
show_status() {
    print_section "Installation Complete!"
    
    echo -e "\n${GREEN}✓ All operations completed successfully!${NC}\n"
    
    echo -e "${CYAN}Mounted Partitions:${NC}"
    for mp in "${MOUNT_POINTS[@]}"; do
        df -h "$mp" | tail -1
    done
    
    echo -e "\n${CYAN}Partition Layout:${NC}"
    lsblk "$DISK_PATH"
    
    echo -e "\n${GREEN}🎉 Done! Disk ready to use.${NC}"
    echo -e "Log: ${LOG_FILE}"
}

# Main execution
main() {
    print_header
    check_root
    detect_os
    install_dependencies
    
    show_disks
    select_disk
    validate_disk
    select_partition_mode
    
    if [ "$PARTITION_MODE" = "single" ]; then
        configure_single_partition
    else
        configure_multi_partition
    fi
    
    show_summary
    create_partitions
    format_partitions
    backup_and_mount
    update_fstab
    show_status
}

main "$@"