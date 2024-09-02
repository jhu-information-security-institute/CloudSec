#!/bin/sh

#
# This sets up linuxbridge networks (on neutron, the external and data
# networks).  The networkmanager and compute nodes' physical interfaces
# have to get moved into br-ex and br-int, respectively -- on the
# moonshots, that's eth0 and eth1.  The controller is special; it doesn't
# get an openvswitch setup, and gets eth1 10.0.0.3/8 .  The networkmanager
# is also special; it gets eth1 10.0.0.1/8, but its eth0 moves into br-ex,
# and its eth1 moves into br-int.  The compute nodes get IP addrs from
# 10.0.1.1/8 and up, but setup-ovs.sh determines that.
#

set -x

# Gotta know the rules!
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

logtstart "linuxbridge-node"

#
# Figure out which interfaces need to go where.  We already have 
# $EXTERNAL_NETWORK_INTERFACE from setup-lib.sh , and it and its configuration
# get applied to br-ex .  So, we need to find which interface corresponds to
# DATALAN on this node, if any, and move it (and its configuration OR its new
# new DATAIP iff USE_EXISTING_IPS was set) to br-int
#
EXTERNAL_NETWORK_BRIDGE="br-ex"

#
# If this is the controller, we don't have to do much network setup; just
# setup the data network with its IP.
#
#if [ "$HOSTNAME" = "$CONTROLLER" ]; then
#    if [ ${USE_EXISTING_IPS} -eq 0 ]; then
#	ifconfig ${DATA_NETWORK_INTERFACE} $DATAIP netmask 255.0.0.0 up
#    fi
#    exit 0;
#fi

#
# Grab our control net info before we change things around.
#
if [ ! -f $OURDIR/ctlnet.vars ]; then
    ctlip="$MYIP"
    ctlmac=`ip -o link show ${EXTERNAL_NETWORK_INTERFACE} | sed -n -e 's/^.*link\/ether \([0-9a-fA-F:]*\) .*$/\1/p'`
    ctlstrippedmac=`echo $ctlmac | sed -e 's/://g'`
    ctlnetmask=`ifconfig ${EXTERNAL_NETWORK_INTERFACE} | sed -n -e 's/^.*mask[: ]\([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/ip'`
    ctlgw=`ip route show default | sed -n -e 's/^default via \([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`
    ctlnet=`ip route show dev ${EXTERNAL_NETWORK_INTERFACE} | sed -n -e 's/^\([0-9]*.[0-9]*.[0-9]*.[0-9]*\/[0-9]*\) .*$/\1/p'`
    ctlprefix=`echo $ctlnet | cut -d/ -f2`

    echo "ctlip=\"$ctlip\"" > $OURDIR/ctlnet.vars
    echo "ctlmac=\"$ctlmac\"" >> $OURDIR/ctlnet.vars
    echo "ctlstrippedmac=\"$ctlstrippedmac\"" >> $OURDIR/ctlnet.vars
    echo "ctlnetmask=\"$ctlnetmask\"" >> $OURDIR/ctlnet.vars
    echo "ctlgw=\"$ctlgw\"" >> $OURDIR/ctlnet.vars
    echo "ctlnet=\"$ctlnet\"" >> $OURDIR/ctlnet.vars
    echo "ctlprefix=\"$ctlprefix\"" >> $OURDIR/ctlnet.vars
else
    . $OURDIR/ctlnet.vars
fi

modprobe bridge

#
# Setup the external network
#
brctl addbr ${EXTERNAL_NETWORK_BRIDGE}
brctl addif ${EXTERNAL_NETWORK_BRIDGE} ${EXTERNAL_NETWORK_INTERFACE}

#
# Now move the $EXTERNAL_NETWORK_INTERFACE and default route config to ${EXTERNAL_NETWORK_BRIDGE}
#
ifconfig ${EXTERNAL_NETWORK_INTERFACE} 0 up
ifconfig ${EXTERNAL_NETWORK_BRIDGE} $ctlip netmask $ctlnetmask up
route add default gw $ctlgw

#
# If systemd-resolved is enabled, tell it about the new default route.
#
grep -q systemd-resolved /etc/resolv.conf
if [ $? -eq 0 ]; then
    if [ -e /var/emulab/boot/bossip ]; then
	DNSSERVER=`cat /var/emulab/boot/bossip`
    else
	DNSSERVER=`resolvectl dns ${EXTERNAL_NETWORK_INTERFACE} | sed -nre 's/^.* ([0-9]*\.[0-9]*\.[0-9]*\.[0-9]*)$/\1/p'`
    fi
    resolvectl dns br-ex $DNSSERVER
else
    DNSSERVER=`cat /etc/resolv.conf | grep nameserver | head -1 | awk '{ print $2 }'`
fi

#
# We need to blow away the Emulab config -- no more dhcp
# This would definitely break experiment modify, of course
#
if [ $DISTRIB_MAJOR -lt 18 ]; then
    cat <<EOF > /etc/network/interfaces
#
# Openstack Network Node in Cloudlab/Emulab/Apt/Federation
#

# The loopback network interface
auto lo
iface lo inet loopback

auto ${EXTERNAL_NETWORK_INTERFACE}
iface ${EXTERNAL_NETWORK_INTERFACE} inet static
    address 0.0.0.0

auto ${EXTERNAL_NETWORK_BRIDGE}
iface ${EXTERNAL_NETWORK_BRIDGE} inet static
    bridge_ports ${EXTERNAL_NETWORK_INTERFACE}
    address $ctlip
    netmask $ctlnetmask
    gateway $ctlgw
    dns-search $OURDOMAIN
    dns-nameservers $DNSSERVER
    up echo "${EXTERNAL_NETWORK_BRIDGE}" > /var/run/cnet
    up echo "${EXTERNAL_NETWORK_INTERFACE}" > /var/emulab/boot/controlif
EOF
else
    mv /etc/udev/rules.d/99-emulab-networkd.rules \
        /etc/udev/rules.d/99-emulab-networkd.rules.NO
    systemctl disable emulab-udev-settle.service
    rm -fv \
        /lib/systemd/system/systemd-networkd.socket.requires/emulab-udev-settle-networkd.service \
        /lib/systemd/system/systemd-networkd.service.requires/emulab-udev-settle-networkd.service \
        /etc/systemd/system/systemd-networkd.socket.requires/emulab-udev-settle-networkd.service \
        /etc/systemd/system/systemd-networkd.service.requires/emulab-udev-settle-networkd.service
    cat <<EOF >/etc/systemd/system/testbed-pre-static-control-network.service
[Unit]
Description=Testbed Static Control Network Services
After=network.target network-online.target local-fs.target
Wants=network.target
Before=testbed.service
Before=pubsubd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$OURDIR/testbed-pre-static-control-network.sh
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
WantedBy=testbed.service
WantedBy=pubsubd.service
EOF
    cat <<EOF >$OURDIR/testbed-pre-static-control-network.sh
#!/bin/sh

#
# These are just the things we cannot do via hook from systemd-networkd,
# that were previously done in /etc/network/interfaces via "up" hook.
#
echo "${EXTERNAL_NETWORK_BRIDGE}" > /var/run/cnet
echo "${EXTERNAL_NETWORK_INTERFACE}" > /var/emulab/boot/controlif
EOF
    chmod 755 $OURDIR/testbed-pre-static-control-network.sh
    systemctl daemon-reload
    cat <<EOF >/etc/systemd/network/${EXTERNAL_NETWORK_BRIDGE}.netdev
[NetDev]
Name=${EXTERNAL_NETWORK_BRIDGE}
Kind=bridge
EOF
    cat <<EOF >/etc/systemd/network/${EXTERNAL_NETWORK_INTERFACE}.network
[Match]
Name=${EXTERNAL_NETWORK_INTERFACE}

[Network]
Bridge=${EXTERNAL_NETWORK_BRIDGE}
EOF
    cat <<EOF >/etc/systemd/network/${EXTERNAL_NETWORK_BRIDGE}.network
[Match]
Name=${EXTERNAL_NETWORK_BRIDGE}

[Network]
Description=OpenStack External Network Bridge
DHCP=no
Address=$ctlip/$ctlprefix
Gateway=$ctlgw
DNS=$DNSSERVER
Domains=$OURDOMAIN
IPForward=yes
EOF
fi

# Also restart slothd so it listens on the new control iface.
echo "${EXTERNAL_NETWORK_BRIDGE}" > /var/run/cnet
echo "${EXTERNAL_NETWORK_INTERFACE}" > /var/emulab/boot/controlif
/usr/local/etc/emulab/rc/rc.slothd stop
pkill slothd
sleep 1
/usr/local/etc/emulab/rc/rc.slothd start

#
# Add the management network config if necessary (if not, it's already a VPN)
#
if [ ! -z "$MGMTLAN" ]; then
    if [ $DISTRIB_MAJOR -lt 18 ]; then
	cat <<EOF >> /etc/network/interfaces

auto ${MGMT_NETWORK_INTERFACE}
iface ${MGMT_NETWORK_INTERFACE} inet static
    address $MGMTIP
    netmask $MGMTNETMASK
    up mkdir -p /var/run/emulab
    up echo "${MGMT_NETWORK_INTERFACE} $MGMTIP $MGMTMAC" > /var/run/emulab/interface-done-$MGMTMAC
EOF
    else
	cat <<EOF >/etc/systemd/network/${MGMT_NETWORK_INTERFACE}.network
[Match]
Name=${MGMT_NETWORK_INTERFACE}

[Network]
Description=OpenStack Management Network
DHCP=no
Address=$MGMTIP/$MGMTPREFIX
IPForward=yes
EOF
	cat <<EOF >>$OURDIR/testbed-pre-static-control-network.sh

mkdir -p /var/run/emulab
echo "${MGMT_NETWORK_INTERFACE} $MGMTIP $MGMTMAC" > /var/run/emulab/interface-done-$MGMTMAC
EOF
    fi
    
    if [ -n "$MGMTVLANDEV" ]; then
	if [ $DISTRIB_MAJOR -lt 18 ]; then
	    cat <<EOF >> /etc/network/interfaces
    vlan-raw-device ${MGMTVLANDEV}
EOF
	else
	    cat <<EOF >/etc/systemd/network/${MGMT_NETWORK_INTERFACE}.netdev
[NetDev]
Name=${MGMT_NETWORK_INTERFACE}
Kind=vlan

[VLAN]
Id=$MGMTVLANTAG
EOF
	    if [ ! -e /etc/systemd/network/${MGMTVLANDEV}.network ]; then
		cat <<EOF >/etc/systemd/network/${MGMTVLANDEV}.network
[Match]
Name=${MGMTVLANDEV}

[Network]
DHCP=no
VLAN=${MGMT_NETWORK_INTERFACE}
EOF
	    else
		cat <<EOF >>/etc/systemd/network/${MGMTVLANDEV}.network
VLAN=${MGMT_NETWORK_INTERFACE}
EOF
	    fi
	fi
    fi
fi

#
# (Maybe) Setup the flat data networks
#
for lan in $DATAFLATLANS ; do
    # suck in the vars we'll use to configure this one
    . $OURDIR/info.$lan

    NETINTVLANSTR=""
    if [ -n "$DATAVLANDEV" ]; then
	NETINTVLANSTR="vlan-raw-device ${DATAVLANDEV}"
    fi

    if [ $LINUXBRIDGE_STATIC -eq 1 ]; then
	brctl addbr ${DATABRIDGE}
	brctl addif ${DATABRIDGE} ${DATADEV}
	ifconfig ${DATADEV} 0 up
	ifconfig ${DATABRIDGE} $DATAIP netmask $DATANETMASK up
        # XXX!
        #route add -net 10.0.0.0/8 dev ${DATA_NETWORK_BRIDGE}

	if [ $DISTRIB_MAJOR -lt 18 ]; then
	    cat <<EOF >> /etc/network/interfaces

auto ${DATADEV}
iface ${DATADEV} inet static
    address 0.0.0.0
    $NETINTVLANSTR

auto ${DATABRIDGE}
iface ${DATABRIDGE} inet static
    bridge_ports ${DATADEV}
    address $DATAIP
    netmask $DATANETMASK
    up mkdir -p /var/run/emulab
    up echo "${DATABRIDGE} $DATAIP $DATAMAC" > /var/run/emulab/interface-done-$DATAMAC
EOF
	else
	    cat <<EOF >/etc/systemd/network/${DATABRIDGE}.netdev
[NetDev]
Name=${DATABRIDGE}
Kind=bridge
EOF
	    cat <<EOF >/etc/systemd/network/${DATADEV}.network
[Match]
Name=${DATADEV}

[Network]
Bridge=${DATABRIDGE}
EOF
	    cat <<EOF >/etc/systemd/network/${DATABRIDGE}.network
[Match]
Name=${DATABRIDGE}

[Network]
Description=OpenStack Network Bridge
DHCP=no
Address=$DATAIP/$DATAPREFIX
IPForward=yes
EOF
	    cat <<EOF >>$OURDIR/testbed-pre-static-control-network.sh

mkdir -p /var/run/emulab
echo "${DATABRIDGE} $DATAIP $DATAMAC" > /var/run/emulab/interface-done-$DATAMAC
EOF
	fi
    else
	if [ $DISTRIB_MAJOR -lt 18 ]; then
	    cat <<EOF >> /etc/network/interfaces

auto ${DATADEV}
iface ${DATADEV} inet static
    address $DATAIP
    netmask $DATANETMASK
    $NETINTVLANSTR
    up mkdir -p /var/run/emulab
    up echo "${DATADEV} $DATAIP $DATAMAC" > /var/run/emulab/interface-done-$DATAMAC
EOF
	else
	    cat <<EOF >/etc/systemd/network/${DATADEV}.network
[Match]
Name=${DATADEV}

[Network]
Address=$DATAIP/$DATAPREFIX
EOF
	    cat <<EOF >>$OURDIR/testbed-pre-static-control-network.sh

mkdir -p /var/run/emulab
echo "${DATABRIDGE} $DATAIP $DATAMAC" > /var/run/emulab/interface-done-$DATAMAC
EOF
	fi
    fi

    # Handle vlan dev for $DATAVLANDEV case
    if [ $DISTRIB_MAJOR -ge 18 -a -n "$DATAVLANDEV" ]; then
	cat <<EOF >/etc/systemd/network/${DATADEV}.netdev
[NetDev]
Name=${DATADEV}
Kind=vlan

[VLAN]
Id=${DATAVLANTAG}
EOF
	if [ ! -e /etc/systemd/network/${DATAVLANDEV}.network ]; then
	    cat <<EOF >/etc/systemd/network/${DATAVLANDEV}.network
[Match]
Name=${MGMTVLANDEV}

[Network]
DHCP=no
VLAN=${DATADEV}
EOF
	else
	    cat <<EOF >>/etc/systemd/network/${DATAVLANDEV}.network
VLAN=${DATADEV}
EOF
	fi
    fi
done

#
# (Maybe) Setup the VLAN data networks.
# Note, these are for the case where we're giving openstack the chance
# to manage these networks... so we delete the emulab-created vlan devices,
# create an openvswitch switch for the vlan device, and just add the physical
# device as a port.  Simple.
#
for lan in $DATAVLANS ; do
    # suck in the vars we'll use to configure this one
    . $OURDIR/info.$lan

    ifconfig $DATADEV down
    vconfig rem $DATADEV

    if [ $LINUXBRIDGE_STATIC -eq 1 ]; then
        # If the bridge exists, we've already done it (we might have
        # multiplexed (trunked) more than one vlan across this physical
        # device).
	brctl addbr ${DATABRIDGE}
	brctl addif ${DATABRIDGE} ${DATAVLANDEV}

	grep "^auto ${DATAVLANDEV}$" /etc/network/interfaces
	if [ ! $? -eq 0 ]; then
	    if [ $DISTRIB_MAJOR -lt 18 ]; then
		cat <<EOF >> /etc/network/interfaces
auto ${DATAVLANDEV}
iface ${DATAVLANDEV} inet static
    #address 0.0.0.0
    up mkdir -p /var/run/emulab
    # Just touch it, don't put iface/inet/mac into it; the vlans atop this
    # device are being used natively by openstack.  So just let Emulab setup
    # to not setup any of these vlans.
    up touch /var/run/emulab/interface-done-$DATAPMAC
EOF
	    else
		cat <<EOF >/etc/systemd/network/${DATAVLANDEV}.network
[Match]
Name=${DATAVLANDEV}

[Network]
Description=OpenStack Data VLAN Physical Interface
DHCP=no
EOF
	    fi
	fi
    fi
done

#else
#    ifconfig ${DATA_NETWORK_INTERFACE} $DATAIP netmask 255.0.0.0 up
#
#    cat <<EOF >> /etc/network/interfaces
#
#auto ${DATA_NETWORK_INTERFACE}
#iface ${DATA_NETWORK_INTERFACE} inet static
#    address $DATAIP
#    netmask $DATANETMASK
#EOF
#    if [ -n "$DATAVLANDEV" ]; then
#	cat <<EOF >> /etc/network/interfaces
#    vlan-raw-device ${DATAVLANDEV}
#EOF
#    fi
#fi

# Flush the routing cache
ip route flush cache

# Also re-run linkdelay setup; it got blown away.  However, it should be
# properly restored by rc.linkdelaysetup on future boots.
if [ -e /var/emulab/boot/rc.linkdelay ]; then
    echo "Restoring link shaping..."
    /var/emulab/boot/rc.linkdelay
fi

#
# Set the hostname for later after reboot!
#
(echo $NFQDN | tr '[:upper:]' '[:lower:]') > /etc/hostname

grep -q DYNRUNDIR /etc/emulab/paths.sh
if [ $? -eq 0 ]; then
    echo "*** Hooking Emulab rc.hostnames boot script..."
    mkdir -p $OURDIR/bin
    touch $OURDIR/bin/rc.hostnames-openstack
    chmod 755 $OURDIR/bin/rc.hostnames-openstack
    cat <<EOF >$OURDIR/bin/rc.hostnames-openstack
#!/bin/sh

cp -p $OURDIR/mgmt-hosts /var/run/emulab/hosts.head
exit 0
EOF

    RCMDIR=/usr/local/etc/emulab/run/rcmanifest.d
    if [ -d /usr/libexec/emulab ]; then
	RCMDIR=/etc/emulab/run/rcmanifest.d
    fi
    mkdir -p $RCMDIR
    touch $RCMDIR/0.openstack-rcmanifest.sh
    cat <<EOF >> $RCMDIR/0.openstack-rcmanifest.sh
HOOK SERVICE=rc.hostnames ENV=boot WHENCE=every OP=boot POINT=pre FATAL=0 FILE=$OURDIR/bin/rc.hostnames-openstack ARGV="" 
EOF
else
    echo "*** Nullifying Emulab rc.hostnames and rc.ifconfig services!"
    mv /usr/local/etc/emulab/rc/rc.hostnames /usr/local/etc/emulab/rc/rc.hostnames.NO
    mv /usr/local/etc/emulab/rc/rc.ifconfig /usr/local/etc/emulab/rc/rc.ifconfig.NO
fi

if [ ! ${HAVE_SYSTEMD} -eq 0 ] ; then
    # Maybe this is helpful too
    update-rc.d networking remove
    update-rc.d networking defaults
    # This seems to block systemd from doing its job...
    systemctl disable ifup-wait-emulab-cnet.service
    systemctl mask ifup-wait-emulab-cnet.service
    systemctl stop ifup-wait-emulab-cnet.service

    systemctl daemon-reload
fi

#
# Install a basic ARP reply filter that prevents us from sending ARP replies on
# the control net for anything we're not allowed to use (i.e., we can reply for
# ourselves, and any public addresses we're allowed to use).  Really, we only
# need the public address part on the network manager, but may as well let
# any node reply as any public address we're allowed to use).
#

# Cheat and use our IPADDR/NETMASK instead of NETWORK/NETMASK below...
OURNET=`ip addr show br-ex | sed -n -e 's/.*inet \([0-9\.\/]*\) .*/\1/p'`

#
# Ok, make the anti-ARP spoofing rules live, and ensure they get
# saved/loaded across reboot.
#
maybe_install_packages ebtables
service_enable ebtables
service_restart ebtables

ebtables -A FORWARD -p 0x0806 --arp-opcode 2 --arp-ip-src ${ctlip} -j ACCEPT
ebtables -A OUTPUT -p 0x0806 --arp-opcode 2 --arp-ip-src ${ctlip} -j ACCEPT

for addr in $PUBLICADDRS ; do
    ebtables -A FORWARD -p 0x0806 --arp-opcode 2 --arp-ip-src ${addr} -j ACCEPT
    ebtables -A OUTPUT -p 0x0806 --arp-opcode 2 --arp-ip-src ${addr} -j ACCEPT
done

# Allow any inbound ARP replies on the control network.
ebtables -A FORWARD -p 0x0806 --arp-opcode 2 --arp-ip-src ${OURNET} --in-interface ${EXTERNAL_NETWORK_INTERFACE} -j ACCEPT

# Drop any other control network addr ARP replies on the br-ex switch.
ebtables -A FORWARD -p 0x0806 --arp-opcode 2 --arp-ip-src ${OURNET} -j DROP
ebtables -A OUTPUT -p 0x0806 --arp-opcode 2 --arp-ip-src ${OURNET} -j DROP

# Also, drop Emulab vnode control network addr ARP replies on br-ex!
ebtables -A FORWARD -p 0x0806 --arp-opcode 2 --arp-ip-src 172.16.0.0/12 -j DROP
ebtables -A OUTPUT -p 0x0806 --arp-opcode 2 --arp-ip-src 172.16.0.0/12 -j DROP

# Setup the service to actually save/restore
cat <<EOF > /etc/default/ebtables
EBTABLES_MODULES_UNLOAD="yes"
EBTABLES_LOAD_ON_START="yes"
EBTABLES_SAVE_ON_STOP="yes"
EBTABLES_SAVE_ON_RESTART="yes"
EOF

#
# NB: but we can't use ebtables to block locally-generated ARP, apparently?
# So use arptables for that!
#
maybe_install_packages arptables
# But there is no save/restore service; so add one
if [ ! -f /etc/init.d/arptables ]; then
    cp $DIRNAME/etc/arptables-initscript /etc/init.d/arptables
    chmod 755 /etc/init.d/arptables
fi
if [ ! ${HAVE_SYSTEMD} -eq 0 ] ; then
    systemctl daemon-reload
fi
service_enable arptables
service_restart arptables

arptables -A OUTPUT --opcode 2 -s ${ctlip} -j ACCEPT

for addr in $PUBLICADDRS ; do
    arptables -A OUTPUT --opcode 2 -s ${addr} -j ACCEPT
done

# Drop any other control network addr ARP replies on the br-ex switch.
arptables -A OUTPUT --opcode 2 -s ${OURNET} -j DROP

# Also, drop Emulab vnode control network addr ARP replies on br-ex!
arptables -A OUTPUT --opcode 2 -s 172.16.0.0/12 -j DROP

# Setup the service to actually save/restore
cat <<EOF > /etc/default/arptables
ARPTABLES_MODULES_UNLOAD="yes"
ARPTABLES_LOAD_ON_START="yes"
ARPTABLES_SAVE_ON_STOP="yes"
ARPTABLES_SAVE_ON_RESTART="yes"
EOF

logtend "linuxbridge-node"

exit 0
