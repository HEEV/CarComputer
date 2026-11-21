#!/bin/sh
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <interface>"
    exit 1
fi
sudo ip address add 192.168.7.1/24 dev $1
sudo ip link set $1 up
ssh 192.168.7.2 -l root