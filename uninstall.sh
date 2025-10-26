#!/bin/bash

echo "Select the Windows version you want to uninstall:"
echo "1) Windows 10 LTSC"
echo "2) Windows 10 Tiny"
echo "3) Windows 10 Atlas"

read -p "Enter your choice: " choice

case $choice in
  1)
    echo "Uninstall for Windows 10 LTSC..."
    bash scripts/uninstall_win10ltsc.sh
    ;;
  2)
    echo "Uninstall for Windows 10 Tiny..."
    bash scripts/uninstall_win10tiny.sh
    ;;
  3)
    echo "Uninstall for Windows 10 Atlas..."
    bash scripts/uninstall_win10atlas.sh
    ;;
  *)
    echo "Invalid choice. Please run the script again"
    exit 1
    ;;
esac