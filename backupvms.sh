#!/bin/bash

# OVERVIEW
# This script will find all VMs in VirtualBox and back them up 
# to a given folder.
# Backups are compressed, encrypted and rotated (i.e. the last <n> are kept).
# The results are emailed to you.
# 
# Author: Paul Reddy <paul@kereru.org>

# NOTES
# - All VMs are backed up. If they are running, they are shutdown first,
# backed up, then restarted. Otherwise they are just backed up.
# (Note: you could *pause* rather than shutdown, but that leaves the file system
# in what looks like an unclean state, requiring a fsck. It only takes an extra
# 30 seconds to minute for a clean shutdown, plus a few minutes for startup).
# - You MUST have implemented support for acpipowerbutton. This is 
# what we used to cleanly shutdown the VM (e.g.:
# https://askubuntu.com/questions/66723/how-do-i-modify-the-options-for-the-power-button)
# - The backup is a tar,gzip,encrypted copy of the VM folder. This is 
# more reliable than snapshots or exporting (as above). But we cannot backup
# a VM that is running - the VM must be stopped for the duration
# of the backup. We minimise downtime as much as possible.


##### Configuration settings for backing up VMs

# Backups will be stored here and rotated.
EXPORTDIR=<Directory>

# How many copies of the backup are kept.
BACKUPVERSIONS=20

# The tmp dir should be FAST and have plenty of space (at least as much as
# the largest compressed backup file. 
# We want to minimise downtime of the VM
# so we write to tmp first and then restart the VM. 
# Later we move the backup to the slower EXPORT disk and rotate.
# You could change the "mv" and "savelog" commands to instead send the
# backup to S3 - speed doesn't matter at that point.
# Note: in theory you could simply COPY the files to TMPDIR, then
# do the gzip later. I dont do that because my VM files are quite 
# large and I dont guarantee to have enough space. I'm using
# parallel gzip for performance.
TMPDIR=/tmp

# Log - kept between runs (in case email fails), but deleted at run start
# Should be a file name
LOGFILE=<Filename>

# Where the VM folders are stored. NOTE that we assume the VM folder
# has the same name as the name of the VM.
# (There isn't a clean and reliable way to get the base VM folder from VBoxManage).
VMFOLDER=<Folder>

# A password file holding password used to encrypt backups. Should be chmod 600
# This script will fail if access is not 600
PASSFILE=<File>

# Who to send backup reports to
MYMAIL=<email address>

# Who to send backup reports from
FROMMAIL=<email address>

# Seconds to delay before sending the result email.
# You might use this if one of the servers you are backing up is email
# Otherwise set it to 0.
MAILDELAY=300

# Mail server to deliver results via
MAILSERVER=<Server>

##### End of configuration


if [ -e $LOGFILE ]; then rm $LOGFILE; fi
touch $LOGFILE

GetState() {
	state=$(VBoxManage showvminfo $1 --machinereadable | grep "VMState=" | cut -f 2 -d "=" | tr -d '"')
	echo $state
}

FatalError() {
	echo "$1. Exiting" >> $LOGFILE
	exit 1
}

# Before we start, check we have access to all the files
[[ ! -f $PASSFILE ]] && FatalError "$PASSFILE is missing"
perm=`stat --print %a $PASSFILE`
[[ $perm = "600" ]] || FatalError "Passfile has unsafe permissions"
$(hash VBoxManage) || FatalError "VBoxManage is missing"
$(hash savelog) || FatalError "savelog is missing"
$(hash sendemail) || FatalError "sendemail is missing"
$(hash openssl) || FatalError "openssl is missing"
$(hash pigz) || FatalError "parallel gzip (pigz) is missing"
echo "$(date +'%X') Pre-backup checks all passed." >> $LOGFILE

for VMNAME in $(VBoxManage list vms | cut -d' ' -f1 | tr -d '"' | sort)
do
	SECONDS=0

	echo "=============================" >> $LOGFILE
	date >> $LOGFILE
	echo "Starting backup of $VMNAME"  >> $LOGFILE

        # Get the vm state
	VMSTATE=$(GetState $VMNAME)
	ORIGSTATE=$VMSTATE
        echo "$(date +'%X') $VMNAME state is: $VMSTATE." >> $LOGFILE

        # If the VM's state is running, shut it down
        if [[ "$VMSTATE" == running ]]; then
                echo "$(date +'%X') $VMNAME being powered off" >> $LOGFILE
                VBoxManage controlvm "$VMNAME" acpipowerbutton
		#	Wait until the VM shuts down
		until [[ $VMSTATE == poweroff ]]; do
			sleep 1
			VMSTATE=$(GetState $VMNAME)
		done
		echo "$(date +'%X') $VMNAME has been powered off" >> $LOGFILE
        fi
	#	Copy and encrypt the folder to a local tmp for max performance
	#	We need to get this VM back up and running ASAP
	#	We use parallel gzip (pigz) for speed
	#	We also use --fast gzip/pigz (or -1). Testing has shown its about 2x faster
	#	than the default (-6), and only slightly bigger.
	#	NOTE: this is compute bound, but pigz helps a log.
	#	If you have the space, copy ONLY, then zip and encrypt later.
	echo "$(date +'%X') Copying, compressing and encrypting $VMNAME" >> $LOGFILE
	tar -cvf - "$VMFOLDER/$VMNAME" | pigz --fast - | openssl enc -e -aes256 -pass "file:$PASSFILE" -out "$TMPDIR/$VMNAME.tgz.enc" 2>> $LOGFILE

	#	If the VM was running... restart it
	if [[ "$ORIGSTATE" == running ]]; then
		echo "$(date +'%X') Restarting $VMNAME" >> $LOGFILE
		VBoxManage startvm "$VMNAME" --type=headless
	fi
	FILESIZE=$(du -h "$TMPDIR/$VMNAME.tgz.enc" | cut -f 1)

	# Move the archive to the right place
	# IF you want to move the archive to S3 (for example), the next
	# 4 lines are all that you need to change.
	echo "$(date +'%X') Moving archive to $EXPORTDIR" >> $LOGFILE
	mv "$TMPDIR/$VMNAME.tgz.enc" "$EXPORTDIR"
	echo "$(date +'%X') $VMNAME - Rolling backups" >> $LOGFILE
	savelog -c 20 -l "$EXPORTDIR/$VMNAME.tgz.enc"

	VMSTATE=$(GetState $VMNAME)
	echo "$(date +'%X') $VMNAME state on completion: $VMSTATE" >> $LOGFILE

	# Calculate duration
	duration=$SECONDS
        echo "$(date +'%X') Backup of $VMNAME took $(($duration / 60)) minutes, $(($duration % 60)) seconds." >> $LOGFILE
	echo "$(date +'%X') Backup file size is $FILESIZE" >> $LOGFILE
done


MAILBODY=$(cat $LOGFILE)
MAILSUBJECT="VM Backups have run"

# If restarting a mail server - it might need time to restart before it can
# accept mail. So lets wait a few seconds
sleep $MAILDELAY

# Send the mail
echo "$MAILBODY" | sendemail -f $FROMMAIL -t $MYMAIL -u "$MAILSUBJECT" -s $MAILSERVER >> $LOGFILE 2>&1

exit 0
