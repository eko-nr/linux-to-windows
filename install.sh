#!/bin/bash

echo "Select the Windows version you want to install:"
echo "1) Windows 10 LTSC"
echo "2) Windows 10 Atlas"
read -p "Enter your choice (1 or 2): " choice

case $choice in
  1)
    echo "Starting installation for Windows 10 LTSC..."
    bash scripts/install_win10ltsc.sh
    ;;
  2)
    echo "Starting installation for Windows 10 Atlas..."
    bash scripts/install_win10atlas.sh
    ;;
  *)
    echo "Invalid choice. Please run the script again and select either 1 or 2."
    exit 1
    ;;
esac