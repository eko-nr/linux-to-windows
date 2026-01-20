#!/bin/bash

echo "Select the Windows version you want to uninstall:"
echo "1) Windows 10 Tiny"

read -p "Enter your choice: " choice

case $choice in
  1)
    echo "Uninstalling for Windows 10 Tiny..."
    bash scripts/uninstall_win10tiny.sh
    ;;
  *)
    echo "Invalid choice. Please run the script again"
    exit 1
    ;;
esac