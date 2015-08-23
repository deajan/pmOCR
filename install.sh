#!/bin/bash

SCRIPT_BUILD=2015082301

## Osync daemon install script
## Tested on RHEL / CentOS 6 & 7
## Please adapt this to fit your distro needs

if [ "$(whoami)" != "root" ]
then
  echo "Must be run as root."
  exit 1
fi

cp ./pmocr.sh /usr/local/bin
cp ./pmocr-srv /etc/init.d
chmod 755 /usr/local/bin/pmocr.sh
chown root:root /usr/local/bin/pmocr.sh
chmod 755 /etc/init.d/pmocr-srv
