# luks-triple-unlock
Set of shell scripts to allow unlocking of full disk encrypted Ubuntu and Debian installs through console, USB-key or SSH.

Use at your own risk, I'm not responsable for any damage this script might do to your system, make backups, make sure you have a safe boot option, test it in a VM first... etc. etc.

Tested on:
- Ubuntu server 14.10 (no desktop)
- Debian 7.8 (no desktop)

Usage:
- Install Ubuntu server or Debian with full disk encrypted LVM
- `sudo apt-get install -y git-core`
- `git clone --depth 1 https://github.com/chadoe/luks-triple-unlock.git && cd luks-triple-unlock`
- `chmod +x *.sh`
- `sudo ./install.sh [keyfile]`, it will ask you for the passphrase for the luks drive, keyfile is a path to a file you want to use as a key for the luks volume, this file will be read from an USB flash drive ext(2/3/4)/fat32/ntfs partition on boot. If no keyfile provided on the commandline a file `.keyfile` will be generated in the current directory. 
- `sudo reboot`

Ways to unlock your machine:
- from the console
- from SSH. Copy /etc/initramfs-tools/root/.ssh/id_rsa, this is the private key you need to log into dropbear (no password, root@machinename). When you connect it will ask you for the passphrase to unlock the machine.
- with an USB flash drive. Copy .keyfile (or the file you provided on the commandline to ./install.sh) to any ext(2/3/4)/fat32/ntfs partition on an USB flash drive. Stick it in the machine and boot, it should boot straight through.

Optional:
- edit /etc/initramfs-tools/initramfs.conf, edit `PKGOPTION_dropbear_OPTION="-s -p 22"`, -s disallows password logins, -p set the ssh port.
- the ip-address wil be set by dhcp, if you don't have your router configured to hand out semi-fixed ip's by mac or you have multiple network interfaces or just want to set a fixed ip you should probably edit /etc/initramfs-tools/initramfs.conf and change the IP value:
```DROPBEAR=y
  # See http://www.kernel.org/doc/Documentation/filesystems/nfs/nfsroot.txt.
  #IP=<client-ip>:<server-ip>:<gw-ip>:<netmask>:<hostname>:<device>:<autoconf>
  #IP=10.10.1.199::10.10.1.1:255.255.255.0::eth0:off
  #IP=192.168.1.99::192.168.1.1:255.255.255.0::wlan0:off
  #IP=192.168.1.99::192.168.1.1:255.255.255.0::wlan0:dhcp
  #IP=:::::wlan0:dhcp
  #IP=dhcp
```
- `sudo update-initramfs -u -k $(uname -r)` to apply the changes.
