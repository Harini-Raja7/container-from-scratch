#!/bin/bash

#Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with sudo"
    exit 1
fi

#Setup networking (bridge + veth pair ) - only if not already set up
if ! ip link show br0 &> /dev/null; then
    echo "Setting up bridge..."
    ip link add br0 type bridge
    ip addr add 10.0.0.1/24 dev br0
    ip link set br0 up
else
    echo "Bridge already exists, skipping..."
fi

#Setup cgroup with resource limits
echo "Setting up cgroup..."
mkdir -p /sys/fs/cgroup/mycontainer
echo "268435456" > /sys/fs/cgroup/mycontainer/memory.max
echo "50000 100000" > /sys/fs/cgroup/mycontainer/cpu.max
echo "20" > /sys/fs/cgroup/mycontainer/pids.max

#Generate a unique container ID and set up its overlay filesystem
CONTAINER_ID=$(date +%s)
echo "Container ID: $CONTAINER_ID"

mkdir -p overlay/$CONTAINER_ID/upper
mkdir -p overlay/$CONTAINER_ID/work
mkdir -p overlay/$CONTAINER_ID/merged
mount -t overlay overlay -o lowerdir=rootfs,upperdir=overlay/$CONTAINER_ID/upper,workdir=overlay/$CONTAINER_ID/work overlay/$CONTAINER_ID/merged

#Setup a unique veth pair for this container
VETH_HOST="v0-$CONTAINER_ID"
VETH_CONTAINER="v1-$CONTAINER_ID"
echo "Setting up veth pair: $VETH_HOST <-> $VETH_CONTAINER"
ip link add $VETH_HOST type veth peer name $VETH_CONTAINER
ip link set $VETH_HOST master br0
ip link set $VETH_HOST up

#Enable IP forwarding and set up NAT
echo "Enabling IP forwarding and NAT..."
sysctl -w net.ipv4.ip_forward=1 > /dev/null
if ! iptables -t nat -C POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE 2>/dev/null; then
    iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE
fi

#Get a unique IP address for this container
if [ ! -f ip_counter.txt ]; then
   echo "2" > ip_counter.txt
fi

CONTAINER_IP_NUM=$(cat ip_counter.txt)
CONTAINER_IP="10.0.0.$CONTAINER_IP_NUM"
echo "Container IP: $CONTAINER_IP"
NEXT_IP_NUM=$((CONTAINER_IP_NUM + 1))
echo "$NEXT_IP_NUM" > ip_counter.txt

#Clean up any old signal files from previous runs
rm -f overlay/$CONTAINER_ID/merged/tmp/ready overlay/$CONTAINER_ID/merged/tmp/go

#Start the container in the background
echo "Starting container..."
unshare --pid --fork --mount --net chroot overlay/$CONTAINER_ID/merged /bin/bash -c " 
mount -t proc proc /proc
touch /tmp/ready
while [ ! -f /tmp/go ]; do sleep 0.1;done
ip addr add $CONTAINER_IP/24 dev $VETH_CONTAINER
ip link set $VETH_CONTAINER up
ip route add default via 10.0.0.1
exec /bin/bash
" < /dev/tty > /dev/tty 2>&1 &

CONTAINER_BG_PID=$!
echo "Container starting with background job PID: $CONTAINER_BG_PID"

#Wait until the container signals it's ready
while [ ! -f overlay/$CONTAINER_ID/merged/tmp/ready ];do
    sleep 0.1
done
echo "Container is ready, configuring from host..."

#Move veth1 into the container's network namespace
ip link set $VETH_CONTAINER netns /proc/$CONTAINER_BG_PID/ns/net

#Attach the container to the cgroup
echo "$CONTAINER_BG_PID" > /sys/fs/cgroup/mycontainer/cgroup.procs

#Signal the container to continue
touch overlay/$CONTAINER_ID/merged/tmp/go

#Wait for the container's shell to finish (user interacts here)
wait $CONTAINER_BG_PID

echo "Container exited. Cleaning up..."
umount overlay/$CONTAINER_ID/merged
rm -rf overlay/$CONTAINER_ID
ip link delete $VETH_HOST 2>/dev/null
echo "Root Check Passes!"


