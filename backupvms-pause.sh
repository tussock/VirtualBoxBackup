#!/bin/bash
# set -x

# OVERVIEW
# This script will find all VMs in VirtualBox and back them up 
# to a given folder.
# Backups are compressed, encrypted and rotated (i.e. the last <n> are kept).
# The results are emailed to you.
# 
# Author: Paul Reddy <paul@kereru.org>

# NOTES
# - All VMs are backed up. If they are running, they are paused first,
# backed up, then resumed. Otherwise they are just backed up.
# - The backup is a tar,gzip,encrypted copy of the VM folder. This is 
# more reliable than snapshots or exporting (as above). But we cannot backup
# a VM that is running - the VM must be paused for the duration
# of the backup. We minimise downtime as much as possible.
# - 4/June/2019 We now PAUSE rather than shutdown. This means that there is
# no power off requirement and no shutdown. It also means that we must 
# FSCK repair the VDI. This also means the script MUST be running as 
# root, and that we need to know the VBox user name


##### Configuration settings for backing up VMs

# Who $VBOXMANAGE commands should be run as
VBOXUSER=<user who owns VMs>

# How to run $VBOXMANAGE
VBOXMANAGE="sudo -H -u $VBOXUSER VBoxManage"

# Backups will be stored here and rotated.
EXPORTDIR=<folder to store backups>

# How many copies of the backup are kept.
BACKUPVERSIONS=20

# The tmp dir should be FAST and have plenty of space (at least as much as
# the largest compressed backup file. 
# We want to minimise downtime of the VM
# so we write to tmp first and then restart the VM. 
# Later we move the backup to the slower EXPORT disk and rotate.
# You could change the tar|pigz|opessl command to instead send the
# backup to S3 - speed doesn't matter at that point.
# I'm using parallel gzip for performance. Experimentation has shown
# that --best is many times slower than --fast, but only 5% smaller for
# my VMs. YMMV. I use --fast.
TMPDIR=/tmp

# Log - kept between runs (in case email fails), but deleted at run start
LOGFILE=<folder to store log>/backup.log

# Where the VM folders are stored. NOTE that we assume the VM folder
# has the same name as the name of the VM.
# (There isn't a clean and reliable way to get the base VM folder from $VBOXMANAGE).
VMFOLDER="<VM root folder>"

# A password file holding password used to encrypt backups. Should be chmod 600
# This script will fail if access is not 600
PASSFILE=<password file path>

# Who to send backup reports to
MYMAIL=<your email address>

# Who to send backup reports from
FROMMAIL=<sendfrom email address>

# Seconds to delay before sending the result email.
# You might use this if one of the servers you are backing up is email
# Otherwise set it to 0.
MAILDELAY=0

# Mail server to deliver results via
MAILSERVER=<mail server>

##### End of configuration

if [ -e $LOGFILE ]; then rm $LOGFILE; fi
touch $LOGFILE

GetState() {
	state=$($VBOXMANAGE showvminfo $1 --machinereadable | grep "VMState=" | cut -f 2 -d "=" | tr -d '"')
	echo $state
}

FatalError() {
	echo "$1. Exiting" >> $LOGFILE
	exit 1
}

# Pre-run checks
# Must be root (for modprobe)
if ! [ $(id -u) = 0 ]; then
	FatalError "Must be run as root"
fi

# Check we have access to all the files
[[ ! -f $PASSFILE ]] && FatalError "$PASSFILE is missing"
perm=`stat --print %a $PASSFILE`
[[ $perm = "600" ]] || FatalError "Passfile has unsafe permissions"
$(hash VBoxManage) || FatalError "VBoxManage is missing"
$(hash savelog) || FatalError "savelog is missing"
$(hash sendemail) || FatalError "sendemail is missing"
$(hash openssl) || FatalError "openssl is missing"
$(hash pigz) || FatalError "parallel gzip (pigz) is missing"
$(dpkg --verify qemu-utils) || FatalError "qemu-utils required for nbd driver"

echo "$(date +'%X') Pre-backup checks all passed." >> $LOGFILE

# Load the nbd driver (so we can FSCK the VDI file)
rmmod nbd
modprobe nbd max_part=16

for VMNAME in $($VBOXMANAGE list vms | cut -d' ' -f1 | tr -d '"' | sort)
do
	SECONDS=0

	echo "=============================" >> $LOGFILE
	date >> $LOGFILE
	echo "Starting backup of $VMNAME"  >> $LOGFILE

	# Get the vm state
	VMSTATE=$(GetState $VMNAME)
	ORIGSTATE=$VMSTATE
	echo "$(date +'%X') $VMNAME state is: $VMSTATE." >> $LOGFILE

	# If the VM's state is running, pause it
	if [[ "$VMSTATE" == running ]]; then
		echo "$(date +'%X') $VMNAME being paused" >> $LOGFILE
		$VBOXMANAGE controlvm "$VMNAME" pause
		#	Wait until the VM shuts down
		until [[ $VMSTATE == paused ]]; do
			sleep 1
			VMSTATE=$(GetState $VMNAME)
		done
		echo "$(date +'%X') $VMNAME has been paused" >> $LOGFILE
	fi
	# Copy and encrypt the folder to a local tmp for max performance
	# We need to get this VM back up and running ASAP
	# We use parallel gzip (pigz) for speed
	# We also use --fast gzip/pigz (or -1). Testing has shown its about 2x faster
	# than the default (-6), and only slightly bigger.
	# NOTE: this is compute bound, but pigz helps a log.
	# If you have the space, copy ONLY, then zip and encrypt later.
	echo "$(date +'%X') Copying the folder" >> $LOGFILE
	
	# Grab a copy of the VM
	if [ -e "$TMPDIR/$VMNAME" ]; then rm -rf "$TMPDIR/$VMNAME"; fi
	cp -r "$VMFOLDER/$VMNAME" /tmp	

	# If the VM was running... restart it
	if [[ "$ORIGSTATE" == running ]]; then
		echo "$(date +'%X') Resuming $VMNAME" >> $LOGFILE
		$VBOXMANAGE controlvm $VMNAME resume
	fi

	# Mount, repair the disk, unmount
	echo "$(date +'%X') Repairing the disk" >> $LOGFILE
	qemu-nbd -c /dev/nbd0 "$TMPDIR/$VMNAME/"*.vdi
	fsck -y /dev/nbd0p2
	qemu-nbd -d /dev/nbd0

	# Compress and encrypt
	echo "$(date +'%X') compressing, encrypting and exporting $VMNAME" >> $LOGFILE
	tar -cvf - "$TMPDIR/$VMNAME" | pigz --fast - | openssl enc -e -aes256 -pass "file:$PASSFILE" -out "$EXPORTDIR/$VMNAME.tgz.enc" 2>> $LOGFILE
	FILESIZE=$(du -h "$EXPORTDIR/$VMNAME.tgz.enc" | cut -f 1)

	# Cleanup
	rm -rf "$TMPDIR/$VMNAME"

	echo "$(date +'%X') $VMNAME - Rolling backups" >> $LOGFILE
	savelog -c 20 -l "$EXPORTDIR/$VMNAME.tgz.enc"

	VMSTATE=$(GetState $VMNAME)
	echo "$(date +'%X') $VMNAME state on completion: $VMSTATE" >> $LOGFILE

	# Calculate duration
	duration=$SECONDS
	echo "$(date +'%X') Backup of $VMNAME took $(($duration / 60)) minutes, $(($duration % 60)) seconds." >> $LOGFILE
	echo "$(date +'%X') Backup file size is $FILESIZE" >> $LOGFILE
done

# Unload the driver
rmmod nbd

MAILBODY=$(cat $LOGFILE)
MAILSUBJECT="VM Backups have run"

# If restarting a mail server - it might need time to resume before it can
# accept mail. So lets wait a few seconds
sleep $MAILDELAY

# Send the mail
echo "$MAILBODY" | sendemail -f $FROMMAIL -t $MYMAIL -u "$MAILSUBJECT" -s $MAILSERVER >> $LOGFILE 2>&1

exit 0
