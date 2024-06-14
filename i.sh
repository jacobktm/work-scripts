#!/bin/bash

cp -rvf check-images.sh $HOME/Documents
cp -rvf update-images.sh $HOME/Documents
cp -rvf verify-images.sh $HOME/Documents
cp -rvf sync-images.sh $HOME/Documents

cd /home/oem/Documents
chmod +x check-images.sh
chmod +x update-images.sh
chmod +x verify-images.sh
chmod +x sync-images.sh

cd /usr/sbin
sudo rm -rvf check-images
sudo rm -rvf update-images
sudo rm -rvf verify-images
sudo rm -rvf sync-images
sudo cp -s $HOME/Documents/check-images.sh check-images
sudo cp -s $HOME/Documents/update-images.sh update-images
sudo cp -s $HOME/Documents/verify-images.sh verify-images
sudo cp -s $HOME/Documents/sync-images.sh sync-images

CRON_JOB="0 18 * * * /home/oem/Documents/sync-images.sh"

# Check if the cron job already exists
(sudo crontab -u root -l | grep -q "$CRON_JOB") || (sudo crontab -u root -l; echo "$CRON_JOB") | sudo crontab -u root -

check-images
