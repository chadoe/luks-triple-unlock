#!/bin/sh

# Part of passwordless cryptofs setup in Debian Etch.
# See: http://wejn.org/how-to-make-passwordless-cryptsetup.html
# Author: Wejn <wejn at box dot cz>
#
# Updated by Rodolfo Garcia (kix) <kix at kix dot com>
# For multiple partitions
# http://www.kix.es/
#
# Updated by TJ <linux@tjworld.net> 7 July 2008
# For use with Ubuntu Hardy, usplash, automatic detection of USB devices,
# detection and examination of *all* partitions on the device (not just partition #1),
# automatic detection of partition type, refactored, commented, debugging code.
#
# Updated by Hendrik van Antwerpen <hendrik at van-antwerpen dot net> 3 Sept 2008
# For encrypted key device support, also added stty support for not
# showing your password in console mode.
#
# Updated by Jan-Pascal van Best janpascal/at/vanbest/org 2009-12-07
# to support latest debian updates (vol_id missing, blkid used instead)
#
# Updated by Renaud Metrich renaud.metrich/at/laposte/net 2011-09-24
# to support Ubuntu 10.04 and onward.
# Explanation of the patch:
# The issue reported later against USB was due to the fact that devices in  
# /sys/block/*/device point to a relative path on Ubuntu instead of full  
# path name. The solution was to cd to that directory and issue a pwd.
# Also, I improved a bit the algorithm to speed up things, typically by  
# first checking whether the device (e.g. sdb) was a USB and removable  
# stuff, instead of doing the same test on every single partition of the  
# device (e.g. sdb1, sdb2, ...).
#
# 2012-03-29
# Updated by dgb for plymouth support in Ubuntu 10.04.3 LTS
#
# Updated by Travis Burtrum <admin@moparisthebest.com> 2013-01-24
# * Merged in MMC support originally by Cromwel Flores <cromwel dot flores at gmail dot com>
#   now the same script works with USB or MMC devices if they exist with complete code reuse.
# * Modified to loop while trying to detect USB/MMC devices, sleeping for only one
#   second at a time, in case they are ready earlier than expected, instead of just
#   sleeping for X seconds (previously 7) and trying once.  Significant speedup.
# * Fixed a bug where after finding the key on one device, it would continue looping
#   through the rest of the devices.  Now it breaks out earlier.
# * Changed a few minor cosmetic things, moved some global variables people might need
#   to modify up top, and changed script output to match exactly the standard cryptsetup
#   text as of Ubuntu 12.04

# define counter-intuitive shell logic values (based on /bin/true & /bin/false)
# NB. use FALSE only to *set* something to false, but don't test for
# equality, because a program might return any non-zero on error
TRUE=0
FALSE=1

# set DEBUG=$TRUE to display debug messages, DEBUG=$FALSE to be quiet
DEBUG=$TRUE

# default path to key-file on the USB/MMC disk
KEYFILE="$CRYPTTAB_KEY"

# maximum time to sleep waiting for devices to become ready before
# asking for passphrase
MAX_SECONDS=2

# is plymouth available? default false
PLYMOUTH=$FALSE
if [ -x /bin/plymouth ] && plymouth --ping; then
    PLYMOUTH=$TRUE
fi

# is usplash available? default false
USPLASH=$FALSE
# test for outfifo from Ubuntu Hardy cryptroot script, the second test
# alone proves not completely reliable.
if [ -p /dev/.initramfs/usplash_outfifo -a -x /sbin/usplash_write ]; then
    # use innocuous command to determine if usplash is running
    # usplash_write will return exit-code 1 if usplash isn't running
    # need to set a flag to tell usplash_write to report no usplash
    FAIL_NO_USPLASH=1
    # enable verbose messages (required to display messages if kernel boot option "quiet" is enabled
    /sbin/usplash_write "VERBOSE on"
    if [ $? -eq $TRUE ]; then
        # usplash is running
        USPLASH=$TRUE
        /sbin/usplash_write "CLEAR"
    fi
fi

# is stty available? default false
STTY=$FALSE
STTYCMD=false
# check for stty executable
if [ -x /bin/stty ]; then
    STTY=$TRUE
    STTYCMD=/bin/stty
elif [ `(busybox stty >/dev/null 2>&1; echo $?)` -eq $TRUE ]; then
    STTY=$TRUE
    STTYCMD="busybox stty"
fi

# print message to usplash or stderr
# usage: msg <command> "message" [switch]
# command: TEXT | STATUS | SUCCESS | FAILURE | CLEAR (see 'man usplash_write' for all commands)
# switch : switch used for echo to stderr (ignored for usplash)
# when using usplash the command will cause "message" to be
# printed according to the usplash <command> definition.
# using the switch -n will allow echo to write multiple messages
# to the same line
msg ()
{
    if [ $# -gt 0 ]; then
        # handle multi-line messages
        echo $2 | while read LINE; do
            if [ $PLYMOUTH -eq $TRUE ]; then
                # use plymouth
                plymouth message --text="$LINE"      
            elif [ $USPLASH -eq $TRUE ]; then
                # use usplash
                /sbin/usplash_write "$1 $LINE"      
            else
                # use stderr for all messages
                echo $3 "$2" >&2
            fi
        done
    fi
}

dbg ()
{
    if [ $DEBUG -eq $TRUE ]; then
        msg "$@"
    fi
}

plymouth_readpass ()
{
    PIPE=/lib/cryptsetup/passfifo
    mkfifo $PIPE
    plymouth ask-for-password --prompt "$1"  >$PIPE &
    PLPID=$!
    read PASS <$PIPE
    kill $PLPID >/dev/null 2>&1
    rm -f $PIPE
    echo "$PASS"
}


# read password from console or with usplash
# usage: readpass "prompt"
readpass ()
{
    if [ $# -gt 0 ]; then
        if [ $PLYMOUTH -eq $TRUE ]; then
            PASS=$(plymouth_readpass "$1")
        elif [ $USPLASH -eq $TRUE ]; then
            msg TEXT "WARNING No SSH unlock support available"
            usplash_write "INPUTQUIET $1"
            PASS="$(cat /dev/.initramfs/usplash_outfifo)"
        elif [ -f /lib/cryptsetup/askpass ]; then
            PASS=$(/lib/cryptsetup/askpass "$1")
        else
            msg TEXT "WARNING No SSH unlock support available"
            [ $STTY -ne $TRUE ] && msg TEXT "WARNING stty not found, password will be visible"
            echo -n "$1" >&2
            $STTYCMD -echo
            read -r PASS </dev/console >/dev/null
            [ $STTY -eq $TRUE ] && echo >&2
            $STTYCMD echo
        fi
    fi
    echo -n "$PASS"
}

dbg STATUS "Executing crypto-usb-key.sh ..."

# flag tracking key-file availability
OPENED=$FALSE

# temporary mount path for USB/MMC key
MD=/tmp-usb-mount

# If the file already exists use it.
# This is useful where an encrypted volume contains keyfile(s) for later
# volumes and is now mounted and accessible
if [ -f $KEYFILE ]; then
    dbg TEXT "Found $KEYFILE"
    cat $KEYFILE
    OPENED=$TRUE
    DEV="existing mount"
    LABEL=""
else
    # Is the USB driver loaded?
    cat /proc/modules | busybox grep usb_storage >/dev/null 2>&1
    USBLOAD=0$?
    if [ $USBLOAD -gt 0 ]; then
        dbg TEXT "Loading driver 'usb_storage'"
        modprobe usb_storage >/dev/null 2>&1
    fi
    
    # Is the MMC (SDcard) driver loaded?
    cat /proc/modules | busybox grep mmc >/dev/null 2>&1
    MMCLOAD=0$?
    if [ $MMCLOAD -gt 0 ]; then
        dbg TEXT "Loading drivers 'mmc_block' and 'sdhci'"
        modprobe mmc_block >/dev/null 2>&1
        modprobe sdhci >/dev/null 2>&1
    fi

    USB_LOADED=$FALSE

    mkdir -p $MD
    dbg TEXT "Trying to get key-file '$KEYFILE' ..."
    for SECONDS_SLEPT in $(seq 1 1 $MAX_SECONDS); do
        for SDB in $(ls -d /sys/block/sd* /sys/block/mmc* 2> /dev/null); do
            dbg TEXT "Examining $SDB" -n
            # is it a USB device?
            (cd ${SDB}/device && busybox pwd) | busybox grep 'usb\|mmc' >/dev/null 2>&1
            USB=0$?
            dbg TEXT ", USB/MMC=$USB" -n
            # Is the device removable? (usb devices have this flag set, but mmc devices don't, is it really needed?)
            #REMOVABLE=0`cat ${SDB}/removable`
            #dbg TEXT ", REMOVABLE=$REMOVABLE" -n
            #if [ $USB -ne $TRUE -o $REMOVABLE -ne 1 -o ! -f $SDB/dev ]; then
            if [ $USB -ne $TRUE -o ! -f $SDB/dev ]; then
                dbg TEXT ", device `busybox basename $SDB` ignored"
                continue # for SDB
            fi
            USB_LOADED=$TRUE
            for SFS in $(ls -d $SDB/sd* $SDB/mmc* 2> /dev/null); do
                dbg TEXT ", *possible key device*" -n
                DEV=`busybox basename $SFS`
                # Check if key device itself is encrypted
                /sbin/cryptsetup isLuks /dev/${DEV} >/dev/null 2>&1
                ENCRYPTED=0$?
                DECRYPTED=$FALSE
                # Open crypted partition and prepare for mount
                if [ $ENCRYPTED -eq $TRUE ]; then
                    dbg TEXT ", encrypted device" -n
                    # Use blkid to determine label
                    LABEL=$(/sbin/blkid -s LABEL -o value /dev/${DEV})
                    dbg TEXT ", label $LABEL" -n
                    TRIES=3
                    DECRYPTED=$FALSE
                    while [ $TRIES -gt 0 -a $DECRYPTED -ne $TRUE ]; do
                        TRIES=$(($TRIES-1))
                        PASS="`readpass \"Enter LUKS password for key device ${DEV} (${LABEL}) (or empty to skip): \"`"
                        if [ -z "$PASS" ]; then
                            dbg TEXT ", device skipped" -n
                            break
                        fi
                        echo $PASS | /sbin/cryptsetup luksOpen /dev/${DEV} bootkey >/dev/null 2>&1
                        DECRYPTED=0$?
                    done
                    # If open failed, skip this device
                    if [ $DECRYPTED -ne $TRUE ]; then
                        dbg TEXT "decrypting device failed" -n
                        break
                    fi
                    # Decrypted device to use
                    DEV=mapper/bootkey
                fi
                dbg TEXT ", device $DEV" -n
                # Use blkid to determine label
                LABEL=$(/sbin/blkid -s LABEL -o value /dev/${DEV})
                dbg TEXT ", label $LABEL" -n
                # Use blkid to determine fstype
                FSTYPE=$(/sbin/blkid -s TYPE -o value /dev/${DEV})
                dbg TEXT ", fstype $FSTYPE" -n
                # Is the file-system driver loaded?
                cat /proc/modules | busybox grep $FSTYPE >/dev/null 2>&1
                FSLOAD=0$?
                if [ $FSLOAD -gt 0 ]; then
                    dbg TEXT ", loading driver for $FSTYPE" -n
                    # load the correct file-system driver
                    modprobe $FSTYPE >/dev/null 2>&1
                fi
                dbg TEXT ", mounting /dev/$DEV on $MD" -n
                mount /dev/${DEV} $MD -t $FSTYPE -o ro >/dev/null 2>&1
                dbg TEXT ", (`mount | busybox grep $DEV`)" -n
                dbg TEXT ", checking for $MD/$KEYFILE" -n
                if [ -f $MD/$KEYFILE ]; then
                    dbg TEXT ", found $MD/$KEYFILE" -n
                    cat $MD/$KEYFILE
                    OPENED=$TRUE
                fi
                dbg TEXT ", umount $MD" -n
                umount $MD >/dev/null 2>&1
                # Close encrypted key device
                if [ $ENCRYPTED -eq $TRUE -a $DECRYPTED -eq $TRUE ]; then
                    dbg TEXT ", closing encrypted device" -n
                    /sbin/cryptsetup luksClose bootkey >/dev/null 2>&1
                fi
               dbg TEXT ", done"
                if [ $OPENED -eq $TRUE ]; then
                    break
                fi
                dbg CLEAR ""
            done
            # if we found the keyfile on one device, we don't want to process any more
            if [ $OPENED -eq $TRUE ]; then
                break
            fi
        done
        # didn't find the keyfile, if USB is loaded we must give up, otherwise sleep for a second
        if [ $USB_LOADED -eq $TRUE ]; then
           dbg TEXT "USB/MMC Device found in less than ${SECONDS_SLEPT}s"
           break
        elif [ $SECONDS_SLEPT -ne $MAX_SECONDS ]; then
           dbg TEXT "USB/MMC Device not found yet, sleeping for 1s and trying again"
           sleep 1
        else           
           dbg TEXT "USB/MMC Device not found, giving up after ${MAX_SECONDS}s... (increase MAX_SECONDS?)"
        fi
    done
fi

# clear existing usplash text and status messages
[ $USPLASH -eq $TRUE ] && msg STATUS "                               " && msg CLEAR ""

if [ $OPENED -ne $TRUE ]; then
    dbg TEXT "Failed to find USB/MMC key-file \"$KEYFILE\"..."
    readpass "$(printf "Unlocking the disk $CRYPTTAB_SOURCE ($CRYPTTAB_NAME)\nEnter passphrase: ")"
else
    dbg TEXT "Success loading key-file from $SFS ($LABEL)"
    msg TEXT "Unlocking the disk $CRYPTTAB_SOURCE ($CRYPTTAB_NAME)"
fi

#
[ $USPLASH -eq $TRUE ] && /sbin/usplash_write "VERBOSE default"
