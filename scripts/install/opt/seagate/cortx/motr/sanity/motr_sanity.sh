#!/bin/bash
#
# Copyright (c) 2019-2020 Seagate Technology LLC and/or its Affiliates
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# For any questions about this software or licensing,
# please email opensource@seagate.com or cortx-questions@seagate.com.
#


# set -x

# This script starts and stops motr singlenode and performs some Object and
# KV Litmus tests.
# This script is heavily influenced by "motr-sample-apps/scripts/c0appzrcgen"
# This script should only be run before bootstrap (that does mkfs),
# and it will never be started after Motr mkfs is complete

M0_SRC_DIR=$(readlink -f "${BASH_SOURCE[0]}")
M0_SRC_DIR="${M0_SRC_DIR%/*/*/*/*/*/*/*/*}"

. "$M0_SRC_DIR"/utils/functions # m0_local_nid_get, m0_default_xprt

conf="/etc/motr/conf.xc"
user_config=/etc/sysconfig/motr
currdir=$(pwd)
timestamp=$(date +%d_%b_%Y_%H_%M)
SANITY_SANDBOX_DIR="/var/motr/sanity_$timestamp"
XPRT=$(m0_default_xprt)
if [ "$XPRT" = "lnet" ]; then
	base_port=301
else
	base_port=3301
fi
IP=""
port=""
local_endpoint=""
ha_endpoint=""
profile_fid=""
ios1_fid=""
process_fid=""
systemd_left_err=false
readonly systemd_services_regex='
 ^m0d@[A-Za-z0-9\:\-]*\.service
 ^m0t1fs@[A-Za-z0-9\:\-]*\.service
 ^motr-kernel\.service
 ^motr-server[A-Za-z0-9\:\@\-]*\.service
 ^motr\.service
 ^motr-client\.service
 ^motr-singlenode\.service
 ^motr-free-space-monitor\.service
 ^motr-mkfs[A-Za-z0-9\:\@\-]*\.service
 ^motr-trace@[A-Za-z0-9\:\-]*\.service
 ^motr-cleanup\.service
'

[[ -r $user_config   ]] && source $user_config

start_singlenode()
{
	mkdir -p "$SANITY_SANDBOX_DIR"
	cd "$SANITY_SANDBOX_DIR"

	# setup motr singlenode
	m0singlenode activate
	m0setup -cv -d "$SANITY_SANDBOX_DIR" -m "$SANITY_SANDBOX_DIR"
	m0setup -N 1 -K 0 -S 0 -P 8 -s 8 -Mv -d "$SANITY_SANDBOX_DIR" \
		-m "$SANITY_SANDBOX_DIR" --no-m0t1fs

	# start motr
	m0singlenode start
}

check_sys_state()
{
	# check for presence of kernel modules
	kernel_modules=$(lsmod | grep m0)
	if [[ ! -z "$kernel_modules" ]]
	then
		echo "[ERROR]: Motr kernel modules present even after cleanup"
		echo -e "Kernel modules:\n$kernel_modules"
		exit 1
	fi

	#check for presence of motr systemd services
	motr_systemd=($(systemctl list-units --all | grep -v ".slice" | awk '{print $1}'))
	for service in "${motr_systemd[@]}"
	do
		for regex in $systemd_services_regex
		do
			if [[ $service =~ $regex ]]
			then
				systemd_left_err=true
				echo "$service"
				break
			fi
		done
	done
	if $systemd_left_err
	then
		echo "[ERROR]: Motr systemd services present even after cleanup"
		exit 1
	fi
}

stop_singlenode()
{
	# stop motr
	m0singlenode stop
	m0setup -cv -d "$SANITY_SANDBOX_DIR" -m "$SANITY_SANDBOX_DIR"
	cd "$currdir"

	# cleanup remaining motr-services
	systemctl start motr-cleanup

	# remove sanity test sandbox directory
	if [[ "$1" == "cleanup" ]]
	then
		rm -rf "$SANITY_SANDBOX_DIR"
	fi

	check_sys_state
}

ip_generate()
{
	IP=$(m0_local_nid_get "new")

	if [[ ! ${IP} ]]; then
		(>&2 echo 'error! m0singlenode not running.')
		(>&2 echo 'start m0singlenode')
		exit
	fi
}

node_sanity_check()
{
	if [ ! -f "$conf" ]
	then
		echo "Error: $conf is missing, it should already be created by m0setup"
		return 1
	fi
	if [ "$XPRT" = "lnet" ]; then
		string=$(grep "$IP" "$conf" | cut -d '"' -f 2 | cut -d ':' -f 1 | head -n 1)
	else
		string=$(grep "$IP" "$conf" | cut -d '"' -f 2 | cut -d '@' -f 1 | head -n 1)
	fi
	set -- "$string"
	ip=$1
	if [ "$ip" != "$IP" ]
	then
		echo "$ip"
		echo "$IP"
		echo "Change in configuration format"
		return 1
	fi
	return 0
}

unused_port_get()
{
	hint=$1
	port_list=$(grep "$IP" "$conf" | cut -d '"' -f 2 | cut -d ':' -f 4)
	while [[ $port_list = *"$hint"* ]]
	do
		hint=$(($hint+1))
	done
	port="$hint"
}

generate_endpoints()
{
	ip_generate
	node_sanity_check

	if [ $? -ne 0 ]
	then
		return 1
	fi

	unused_port_get "$base_port"
	if [ "$XPRT" = "lnet" ]; then
		local_endpoint="${IP}:12345:44:$port"
		ha_endpoint="${IP}:12345:45:1"
	else
		local_endpoint="${IP}@$port"
		ha_endpoint="${IP}@2001"
	fi

	echo "Local endpoint: $local_endpoint"
	echo "HA endpoint: $ha_endpoint"

	profile_fid='0x7000000000000001:0'
	echo "Profile FID: $profile_fid"

	ios1_fid='0x7200000000000001:3'
	echo "Ioservice 1 FID: $ios1_fid"

	process_fid='0x7200000000000001:5'
	echo "Process FID: $process_fid"
}

error_handling()
{
	echo "$1 with rc = $2"
	stop_singlenode
	exit "$2"
}

object_io_test()
{
	echo "***** Running Object IO tests *****"

	obj_id1="20:20"
	obj_id2="20:22"
	blk_size="4k"
	blk_count="200"
	src_file="$SANITY_SANDBOX_DIR/src"
	dest_file="$SANITY_SANDBOX_DIR/dest"

	echo "----- Size: $blk_size, Count: $blk_count -----"

	echo "Creating source file $src_file"
	eval "dd if=/dev/urandom of=$src_file bs=$blk_size count=$blk_count" || {
		error_handling "dd command failed" $?
	}

	endpoint_opts="-l $local_endpoint -H $ha_endpoint -p $profile_fid \
		       -P $process_fid"

	rm -f "$dest_file"

	echo "Writing to object $obj_id1....."
	eval "m0cp -G $endpoint_opts -o $obj_id1 -s $blk_size -c $blk_count \
	      $src_file" || {
		error_handling "Failed to write object $obj_id1" $?
	}

	echo "Reading from object $obj_id1 ....."
	eval "m0cat -G $endpoint_opts -o $obj_id1 -s $blk_size -c $blk_count \
	      $dest_file" || {
		error_handling "Failed to read object $obj_id1" $?
	}

	echo "Comparing files $src_file and $dest_file ....."
	eval "diff $src_file $dest_file" || {
		error_handling "Files differ" $?
	}

	echo "Deleting object $obj_id1 ....."
	eval "m0unlink $endpoint_opts -o $obj_id1" || {
		error_handling "Failed to delete object $obj_id1" $?
	}
	rm -f "$dest_file"

	echo "Creating object $obj_id2 ....."
	eval "m0touch $endpoint_opts -o $obj_id2" || {
		error_handling "Failed to create object $obj_id2" $?
	}

	echo "Writing to object $obj_id2....."
	eval "m0cp -G $endpoint_opts -o $obj_id2 -s $blk_size -c $blk_count \
	      $src_file -u" || {
		error_handling "Failed to write object $obj_id2" $?
	}

	echo "Reading from object $obj_id2 ....."
	eval "m0cat -G $endpoint_opts -o $obj_id2 -s $blk_size -c $blk_count \
	      $dest_file" || {
		error_handling "Failed to read object $obj_id2" $?
	}

	echo "Comparing files $src_file and $dest_file ....."
	eval "diff $src_file $dest_file" || {
		error_handling "Files differ" $?
	}

	echo "Deleting object $obj_id2 ....."
	eval "m0unlink $endpoint_opts -o $obj_id2" || {
		error_handling "Failed to delete object $obj_id2" $?
	}

	rm -f "$dest_file" "$src_file"

	blk_size_dd="1M"
	blk_size="1m"
	blk_count="16"
	src_file="$SANITY_SANDBOX_DIR/src_1M"
	dest_file="$SANITY_SANDBOX_DIR/dest"

	echo "----- Size: $blk_size, Count: $blk_count -----"

	echo "Created source file $src_file"
	eval "dd if=/dev/urandom of=$src_file bs=$blk_size_dd count=$blk_count" || {
		error_handling "dd command failed" $?
	}

	echo "Writing to object $obj_id1....."
	eval "m0cp -G $endpoint_opts -o $obj_id1 -s $blk_size -c $blk_count \
	      $src_file -L 9" || {
		error_handling "Failed to write object $obj_id1" $?
	}

	echo "Reading from object $obj_id1 ....."
	eval "m0cat -G $endpoint_opts -o $obj_id1 -s $blk_size -c $blk_count \
	      -L 9 $dest_file" || {
		error_handling "Failed to read object $obj_id1" $?
	}

	echo "Comparing files $src_file and $dest_file ....."
	eval "diff $src_file $dest_file" || {
		error_handling "Files differ" $?
	}

	echo "Deleting object $obj_id1 ....."
	eval "m0unlink $endpoint_opts -o $obj_id1" || {
		error_handling "Failed to delete object $obj_id1" $?
	}

	rm -f "$dest_file" "$src_file"
}

kv_test()
{
	local keys_file="keys.txt"
	local vals_file="vals.txt"

	echo "***** Running KV tests *****"

	index_id1="0x780000000000000b:1"
	index_id2="0x780000000000000b:2"
	index_id3="0x780000000000000b:3"
	endpoint_opts="-l $local_endpoint -h $ha_endpoint -p $profile_fid \
		       -f $process_fid"
	rm -f keys.txt vals.txt

	echo "----- m0kv -----"

	echo "Generate files ${keys_file} and ${vals_file}"
	eval "m0kv $endpoint_opts index genv 10 20 ${keys_file}" &> "/dev/null"
	eval "m0kv $endpoint_opts index genv 10 20 ${vals_file}" &> "/dev/null"

	echo "Create index $index_id1 ....."
	eval "m0kv $endpoint_opts index create $index_id1" || {
		error_handling "Failed to create index $index_id1" $?
	}

	echo "Create index $index_id2 ....."
	eval "m0kv $endpoint_opts index create $index_id2" || {
		error_handling "Failed to create index $index_id2" $?
	}

	echo "Create index $index_id3 ....."
	eval "m0kv $endpoint_opts index create $index_id3" || {
		error_handling "Failed to create index $index_id3" $?
	}

	echo "List indices from $index_id1 ....."
	eval "m0kv $endpoint_opts index list $index_id1" 3 || {
		error_handling "Failed to list indexes" $?
	}

	echo "Lookup index $index_id2 ....."
	eval "m0kv $endpoint_opts index lookup $index_id2" || {
		error_handling "Failed to lookup index $index_id2" $?
	}

	echo "Drop index $index_id1 ....."
	eval "m0kv $endpoint_opts index drop $index_id1" || {
		error_handling "Failed to drop index $index_id1" $?
	}

	echo "Drop index $index_id2 ....."
	eval "m0kv $endpoint_opts index drop $index_id2" || {
		error_handling "Failed to drop index $index_id2" $?
	}

	echo "Put records in index $index_id3 ....."
	eval "m0kv $endpoint_opts index put $index_id3 @${keys_file} \
	      @${vals_file}" || {
		error_handling "Failed to put KV on index $index_id3" $?
	}

	echo "Get records from index $index_id3 ....."
	eval "m0kv $endpoint_opts index get $index_id3 @${keys_file}" || {
		error_handling "Failed to get KV on index $index_id3" $?
	}

	echo "Get next record from index $index_id3 ....."
	eval "m0kv $endpoint_opts index next $index_id3 \"$(head -n 1 \
	      ${keys_file} | cut -f 2- -d ' ')\" 1" || {
		error_handling "Failed to get next KV on index $index_id3" $?
	}

	echo "Delete records from index $index_id3 ....."
	eval "m0kv $endpoint_opts index del $index_id3 @${keys_file}" || {
		error_handling "Failed to delete KV on $index_id3" $?
	}

	echo "Delete index $index_id3 ....."
	eval "m0kv $endpoint_opts index drop $index_id3" || {
		error_handling "Failed to drop index $index_id3" $?
	}

	rm -f keys.txt vals.txt

	echo
	echo "----- m0mt test -----"
        eval "m0mt $endpoint_opts" || {
		error_handling "m0mt failed" $?
	}
}

m0spiel_test()
{
	local spiel_client_ep
	local rc

	if [ "$XPRT" = "lnet" ]; then
		spiel_client_ep="${IP}:12345:45:1000"
	else
		spiel_client_ep="${IP}@20010"
	fi

	echo "m0_filesystem_stats"
	libmotr_sys_path="/usr/lib64/libmotr.so"
	[[ -n "$MOTR_DEVEL_WORKDIR_PATH" ]] && \
        	libmotr_path="$MOTR_DEVEL_WORKDIR_PATH"/motr/.libs/libmotr.so
	[[ ! -s "$libmotr_path" ]] && libmotr_path="$libmotr_sys_path"
	format_profile_fid=$(echo "$profile_fid" | sed 's/.*<\(.*\)>/\1/' | sed 's/:/,/')
	/usr/bin/m0_filesystem_stats -s "$ha_endpoint" -p "$format_profile_fid" \
		-c "$spiel_client_ep" -l "$libmotr_path"
	rc=$?
	if [ $rc -ne 0 ] ; then
		error_handling "Failed to run m0_filesystem_stats " $rc
	fi
	format_process_fid=$(echo "$ios1_fid" | sed 's/.*<\(.*\)>/\1/' | sed 's/:/,/')
	/usr/bin/m0_bytecount_stats -s "$ha_endpoint" -p "$format_profile_fid" \
		-P "$format_process_fid" -l "$libmotr_path"
	rc=$?
        if [ $rc -ne 0 ] ; then
		error_handling "Failed to run m0_bytecount_stats " $rc
	fi
}

run_tests()
{
	# Run litmus test
	object_io_test
	kv_test
	m0spiel_test
}

main()
{
	start_singlenode
	generate_endpoints
	if [ $? -ne 0 ]
	then
		return 1
	fi
	run_tests
	stop_singlenode "cleanup"
}

main
