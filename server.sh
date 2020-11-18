#!/usr/bin/env bash

# Copyright 2020 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -Eeuo pipefail

print_help() {
	echo -e 'github.com/shiftstack/shiftstack-ci'
	echo -e 'Spin a server on OpenStack'
	echo
	echo -e 'Usage:'
	echo -e "\t${0} [-p] -n <name> -f <flavor> -i <image> -n <external network> -k <key>"
	echo
	echo -e 'Required configuration:'
	echo -e '\t-n\tName of the Compute instance.'
	echo -e '\t-f\tFlavor of the Compute instance.'
	echo -e '\t-i\tImage of the Compute instance.'
	echo -e '\t-n\tName or ID of the public network where to create the floating IP.'
	echo -e '\t-k\tName or ID of the SSH public key to add to the server.'
	echo
	echo -e 'Options:'
	echo -e '\t-p\tDo not clean up the server after creation.'
}

declare \
	persistent=''    \
	name=''          \
	server_flavor='' \
	server_image=''  \
	key_name=''      \
	external_network='external'
while getopts pn:f:i:n:k:h opt; do
	case "$opt" in
		p) persistent='yes'           ;;
		n) name="$OPTARG"             ;;
		f) server_flavor="$OPTARG"    ;;
		i) server_image="$OPTARG"     ;;
		n) external_network="$OPTARG" ;;
		k) key_name="$OPTARG"         ;;
		h) print_help; exit 0         ;;
		*) exit 1                     ;;
	esac
done
shift "$((OPTIND-1))"
readonly \
	server_name   \
	server_flavor \
	server_image  \
	key_name      \
	external_network

declare \
	sg_id=''      \
	network_id='' \
	subnet_id=''  \
	router_id=''  \
	port_id=''    \
	server_id=''  \
	fip_id=''

cleanup() {
	>&2 echo
	>&2 echo
	>&2 echo 'Starting the cleanup...'
	if [ -n "$fip_id" ]; then
		openstack floating ip delete "$fip_id" || >&2 echo "Failed deleting FIP $fip_id"
	fi
	if [ -n "$server_id" ]; then
		openstack server delete "$server_id" || >&2 echo "Failed deleting server $server_id"
	fi
	if [ -n "$port_id" ]; then
		openstack port delete "$port_id" || >&2 echo "Failed deleting port $port_id"
	fi
	if [ -n "$router_id" ]; then
		openstack router remove subnet "$router_id" "$subnet_id" || >&2 echo 'Failed removing subnet from router'
		openstack router delete "$router_id" || >&2 echo "Failed deleting router $router_id"
	fi
	if [ -n "$subnet_id" ]; then
		openstack subnet delete "$subnet_id" || >&2 echo "Failed deleting subnet $subnet_id"
	fi
	if [ -n "$network_id" ]; then
		openstack network delete "$network_id" || >&2 echo "Failed deleting network $network_id"
	fi
	if [ -n "$sg_id" ]; then
		openstack security group delete "$sg_id" || >&2 echo "Failed deleting security group $sg_id"
	fi
	>&2 echo 'Cleanup done.'
}

trap cleanup EXIT

sg_id="$(openstack security group create -f value -c id "$name")"
>&2 echo "Created security group ${sg_id}"
openstack security group rule create --ingress --protocol tcp  --description "${name} ingress tcp" "$sg_id" >/dev/null
openstack security group rule create --ingress --protocol udp  --description "${name} ingress udp" "$sg_id" >/dev/null
openstack security group rule create --ingress --protocol icmp --description "${name} ingress ping" "$sg_id" >/dev/null
>&2 echo 'Security group rules created.'

network_id="$(openstack network create -f value -c id "$name")"
>&2 echo "Created network ${network_id}"

subnet_id="$(openstack subnet create -f value -c id \
		--network "$network_id" \
		--subnet-range '172.16.0.0/24' \
		"$name")"
>&2 echo "Created subnet ${subnet_id}"

router_id="$(openstack router create -f value -c id \
		"$name")"
>&2 echo "Created router ${router_id}"
openstack router add subnet "$router_id" "$subnet_id"
openstack router set --external-gateway "$external_network" "$router_id"

port_id="$(openstack port create -f value -c id \
		--network "$network_id" \
		--security-group "$sg_id" \
		"$name")"
>&2 echo "Created port ${port_id}"

server_id="$(openstack server create -f value -c id \
		--image "$server_image" \
		--flavor "$server_flavor" \
		--nic "port-id=$port_id" \
		--security-group "$sg_id" \
		--key-name "$key_name" \
		"$name")"
>&2 echo "Created server ${server_id}"

fip_id="$(openstack floating ip create -f value -c id \
		--description "$name FIP" \
		"$external_network")"
>&2 echo "Created floating IP ${fip_id} $(openstack floating ip show -f value -c floating_ip_address "$fip_id")"
openstack server add floating ip "$server_id" "$fip_id"

if [ "$persistent" == 'yes']; then
	>&2 echo "Server created."
	trap true EXIT
else
	>&2 echo "Server created. Press ENTER to tear down."
	read pause
fi
