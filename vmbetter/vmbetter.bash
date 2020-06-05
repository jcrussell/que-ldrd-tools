#! /bin/bash

# Copyright 2019 National Technology & Engineering Solutions of Sandia, LLC
# (NTESS). Under the terms of Contract DE-NA0003525 with NTESS, the U.S.
# Government retains certain rights in this software.

# Build vmbetter images better with vmbetter.bash.
#
# Example:
#
#   bash vmbetter.bash que

level=info

function vmbetter {
	../../minimega/bin/vmbetter -branch stretch -level info $@
}

for i in "$@"; do
	case $i in
		que|que_host_ccc|que_host_carnac|que_physical)
			vmbetter $i.conf
			shift
			;;

		quefs)
			vmbetter -rootfs $i.conf
			mv quefs_rootfs quefs
			tar -cf - quefs | gzip > quefs.tar.gz
			shift
			;;
		*)
			echo "unknown vmbetter config"
			break 2
			;;
	esac
done

echo -e "\a"
