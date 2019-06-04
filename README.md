# VirtualBoxBackup
Backup a set of VMs running in VirtualBox.

## Overview
Given a set of VMs running in virtualbox, this script will back them all up to a given folder by making a complete copy of the VM folder. This makes for the safest and simplest restore process. The backup files are compressed, encrypted and rotated.

## Process
The process is as follows:
- Get a list of the VMs
- For each one
-- shut it down (if required)
-- copy the VM folder to a temporary location, zipping and encrypting
-- restart the VM
-- copy the backup to its long term location (this could be S3 or a mounted drive).
-- Rotate the backups
- Finally, mail the results

## Shutdown vs Pause
Instead of a shutdown, you can save a minute or two of downtime by pausing the VM. However, this will generally leave the disk in an unclean state (since the OS will see it as an improper shutdown) requiring FSCK. I elected for safety, and using shutdown promises a clean file system.

NOTE that there is now a version that pauses the VMs, and cleans the VDIs afterwards. This avoids shutdowns, an removes the need to support the acpipowerbutton function.

## Copy and GZIP
The script will currently copy and zip the folder to a temp location. This is CPU bound (the ZIP) rather than IO bound. The VM could be restarted sooner if the script did not ZIP until later.

The reason it is done this way is that my temporary folders are not large enough to contain the unzipped VMs. 

I use pigz to speed up the zip operation. The results are fully backward compatible with gzip.
