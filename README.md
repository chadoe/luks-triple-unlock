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
- `sudo ./install.sh [keyfile]`, it will ask you for the passphrase for the luks drive, keyfile is a path to a file you want to use as a key for the luks volume, this file will be read from an USB flash drive fat32 partition on boot. If no keyfile provided on the commandline a file `.keyfile` will be generated in the current directory. 
- `sudo reboot`

Ways to unlock your machine:
- from the console
- from SSH. Copy /etc/initramfs-tools/root/.ssh/id_rsa, this is the private key you need to log into dropbear (no password, root@machinename), unlock the machine with the command `echo "yourlukspassphrase" >/lib/cryptsetup/passfifo`.
- with an USB flash drive. Copy .keyfile (or the file you provided on the commandline to ./install.sh) to a fat32 partition on an USB flash drive. Stick it in the machine and boot, it should boot straight through.

Optional:
- edit /etc/initramfs-tools/initramfs.conf, add `PKGOPTION_dropbear_OPTION="-s -p 22"`, -s to disallow password logins, -p to change port.
- `sudo update-initramfs -u -k $(uname -r)` to apply the changes.
