#! /bin/bash

# This script sets up a full disc encrypted debian/ubuntu machine for
# unlocking during boot from the console, with a usbstick containing a key 
# or from a SSH connection.
#
# Author: Martin van Beurden <chadoe@gmail.com>
# crypto-usb-key.sh keyscript, based on http://wejn.org/how-to-make-passwordless-cryptsetup.html
#

set -e

KEYFILEPATH="$1"
if [ -z "$KEYFILEPATH" ]; then
    KEYFILEPATH=".keyfile"
    KEYFILE="$KEYFILEPATH"
    echo "Generating key \"$KEYFILE\", this should go on your USB stick."
    apt-get install -y sharutils
    head -c 2880 /dev/urandom | uuencode -m - | head -n 65 | tail -n 64 > "$KEYFILE"
elif [ ! -f "$KEYFILEPATH" ]; then
    echo "Keyfile \"$KEYFILEPATH\" not found, exiting."
    exit 1;
else
    KEYFILE=$(basename $KEYFILEPATH)
fi


#Add key to the cryptvolume
cryptUUID=$(blkid -t TYPE=crypto_LUKS -o value -s UUID)
cryptsetup luksAddKey UUID=$cryptUUID "$KEYFILEPATH"

#Add modules needed for usb reading
grep -q '^vfat$' /etc/initramfs-tools/modules || echo 'vfat' >> /etc/initramfs-tools/modules
grep -q '^fat$' /etc/initramfs-tools/modules || echo 'fat' >> /etc/initramfs-tools/modules
grep -q '^nls_cp437$' /etc/initramfs-tools/modules || echo 'nls_cp437' >> /etc/initramfs-tools/modules
grep -q '^nls_iso8859_1$' /etc/initramfs-tools/modules || echo 'nls_iso8859_1' >> /etc/initramfs-tools/modules
grep -q '^nls_utf8$' /etc/initramfs-tools/modules || echo 'nls_utf8' >> /etc/initramfs-tools/modules
grep -q '^nls_base$' /etc/initramfs-tools/modules || echo 'nls_base' >> /etc/initramfs-tools/modules

#Setup cryptkey
cp crypto-usb-key.sh /usr/local/sbin/
chmod a+x /usr/local/sbin/crypto-usb-key.sh
sed -i "/$cryptUUID/ s/$cryptUUID[ \t]*[^ \t]*/$cryptUUID $KEYFILE/g" /etc/crypttab
#remove any previous keyscript
sed -i "/$cryptUUID/ s/,keyscript=[^, \t]*//" /etc/crypttab
#add our keyscript
sed -i "/$cryptUUID/ s/\$/,keyscript=\/usr\/local\/sbin\/crypto-usb-key.sh/" /etc/crypttab

#Dropbear ssh unlock
apt-get install -y dropbear initramfs-tools busybox

#Add network drivers
ifaces=$(ip addr|egrep "^[0-9]*: "|egrep -v "^[0-9]*: lo:"|awk '{print $2}'|sed 's/:$//g')
for iface in $ifaces; do
    if [ -f /sys/class/net/$iface/device/uevent ]; then
        echo "Found interface $iface"
		ifacemod="$(grep DRIVER /sys/class/net/$iface/device/uevent |awk -F'=' '{print $2}')"
		grep -q "^$ifacemod$" /etc/initramfs-tools/modules || echo "$ifacemod" >> /etc/initramfs-tools/modules
    fi
done

#explicitely enable dropbear (=default behavior), won't touch existing setting if any
grep -q '^DROPBEAR=' /etc/initramfs-tools/initramfs.conf || echo 'DROPBEAR=y' >> /etc/initramfs-tools/initramfs.conf
#explicitely set ip to dhcp (=default behavior), won't touch existing setting if any
grep -q '^IP=' /etc/initramfs-tools/initramfs.conf || echo 'IP=dhcp' >> /etc/initramfs-tools/initramfs.conf
#disallow password logins (=non-default behavior), set port to 22 (=default behavior), won't touch existing setting if any
grep -q '^PKGOPTION_dropbear_OPTION=' /etc/initramfs-tools/initramfs.conf || echo 'PKGOPTION_dropbear_OPTION="-s -p 22"' >> /etc/initramfs-tools/initramfs.conf


#Private key of root needed to login to dropbear
echo "************************************************************************"
echo "Copy /etc/initramfs-tools/root/.ssh/id_rsa to your local machine. "
echo "This is the private key you need to log into dropbear (no password, root@machinename). "
echo "Or add you own public key to /etc/initramfs-tools/root/.ssh/authorized_keys "
echo "and rerun update-initramfs -u -k \`uname -r\` "
echo "************************************************************************"

#Write initramfs scripts
#
#Network won't be reconfigured after dropbear has initialized it in initramfs, reset it
#
cat <<EOF >/etc/initramfs-tools/scripts/local-bottom/reset_network
#!/bin/sh
#
# Initramfs script to reset all network devices after initramfs is done.
#
# Author: Martin van Beurden, https://martinvanbeurden.nl
#
# Usage:
# - Copy this script to /etc/initramfs-tools/scripts/local-bottom/reset_network
# - chmod +x /etc/initramfs-tools/scripts/local-bottom/reset_network
# - update-initramfs -u -k -all
#

PREREQ=""
prereqs()
{
    echo "$PREREQ"
}
case \$1 in
    prereqs)
        prereqs
        exit 0
    ;;
esac
#
# Begin real processing
#
ifaces=\$(ip addr|egrep "^[0-9]*: "|egrep -v "^[0-9]*: lo:"|awk '{print \$2}'|sed 's/:$//g')
for iface in \$ifaces; do
    echo "Flushing network interface \$iface"
    ip addr flush \$iface
done
EOF

chmod +x /etc/initramfs-tools/scripts/local-bottom/reset_network

#
#Just an extra, kills the dropbear connecton when done so the client 
#knows immediately it has been disconnected.
#
cat << EOF>/etc/initramfs-tools/scripts/local-bottom/kill_dropbear_connections
#!/bin/sh

# Initramfs script to kill all dropbear clientconnections after initramfs is done.
#
# Adopted from openwrt
# Author: Martin van Beurden, https://martinvanbeurden.nl
#
# Usage:
# - Copy this script to /etc/initramfs-tools/scripts/local-bottom/kill_dropbear_connections
# - chmod +x /etc/initramfs-tools/scripts/local-bottom/kill_dropbear_connections
# - update-initramfs -u -k -all
#
PREREQ=""
prereqs()
{
    echo "$PREREQ"
}
case \$1 in
    prereqs)
        prereqs
        exit 0
    ;;
esac
#
# Begin real processing
#
NAME=dropbear
PROG=/sbin/dropbear
# get all server pids that should be ignored
ignore=""
for server in \`cat /var/run/\${NAME}*.pid\`
do
    ignore="\${ignore} \${server}"
done
# get all running pids and kill client connections
for pid in \`pidof "\${NAME}"\`
do
    # check if correct program, otherwise process next pid
    grep -F -q -e "\${PROG}" "/proc/\${pid}/cmdline" || {
        continue
    }
    # check if pid should be ignored (servers)
    skip=0
    for server in \${ignore}
    do
        if [ "\${pid}" == "\${server}" ]
        then
            skip=1
            break
        fi
    done
    [ "\${skip}" -ne 0 ] && continue
    # kill process
    echo "\$0: Killing ${pid}..."
    kill \${pid}
done
EOF
chmod +x /etc/initramfs-tools/scripts/local-bottom/kill_dropbear_connections


update-initramfs -u -k $(uname -r)

echo "************************************************************************"
echo "DONE!"
echo "Make sure you have a safe boot option before rebooting."
echo "************************************************************************"
