#!/bin/bash

echo "Select the Windows version you want to install:"
echo "1) Windows 10 LTSC"
echo "2) Windows 10 Tiny"
echo "2) Windows 10 Atlas"

read -p "Enter your choice: " choice

case $choice in
  1)
    echo "Starting installation for Windows 10 LTSC..."
    bash scripts/install_win10ltsc.sh
    ;;
  2)
    echo "Starting installation for Windows 10 Atlas..."
    bash scripts/install_win10atlas.sh
    ;;
  3)
    echo "Starting installation for Windows 10 Tiny..."
    bash scripts/install_win10tiny.sh
    ;;
  *)
    echo "Invalid choice. Please run the script again"
    exit 1
    ;;
esac