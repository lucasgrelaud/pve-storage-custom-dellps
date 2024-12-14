# Proxmox VE plugin to deal with Dell Equallogic PS-series SAN.

This plugin expose the Dell Equallogic PS-series SAN cluster capabilities to Provmox VE.

## Features :
 - Create LUN as a drive from the PVE dashboard
 - Create offline snapshot of drives
 - Create online snapshot of drives
 - Clone offline drive
 - Clone online drive
 - Resize drive
 - Shared storage (live migration in a cluster)

## Installation
_⚠️ The tasks described in this section must be performed on each node of a PVE Cluster in order to work properly._  


### Requirements
Couple debian packages must be installed on the PVE node :
  - build-essentials
  - debhelper
  - devscripts
  - open-iscsi
  - lsscsi
  - make
  - lintian
  - (optional) multipath-tools

Couple perl libraries must be installed on the PVE node: 
 - Net::Telnet module

Couple configuration must be performed on the SAN :
 - Enable the telnet service
 - Create a volume administrator account
 - (optional) Create a CHAP account
 - (optional) Create access policies

The `multipath-tools` package only need to be installed if you plan to used this capability.
  
### Build and install the plugin
To package the plugin as a `.deb` follow the inscructions bellow.
```bash
$: cd <project_path>
$: make clean && make deb
$: make dinstall
```

The generated `.deb` can later be uploaded to the other nodes of the cluster and be installed with the command `dpkg -i <plugin.deb>` .

### Configure the plugin

#### Configure `open-iscsi`
This plugin have a partial support the CHAP authentication protocol.
To protect the access of your PVE LUNs with CHAP, please configure the `open-iscsi` deamon as described bellow.

Edit `/etc/iscsi/iscsid.conf` : 
```
node.startup = manual
node.leading_login = No
node.session.auth.authmethod = CHAP

# Authentication of the PVE initiator
node.session.auth.username = <CHAP_initiator_login>
node.session.auth.password = <CHAP_initiator_password>

# Authentication of the Equallogic SAN
node.session.auth.username_in = <CHAP_san_login>
node.session.auth.password_in = <CHAP_san_password>
```

Then restart the `open-iscsi` daemon with the command : `systemctl restart open-iscsi.service`.

#### Configure multipath
For this plugin, you need to set "uid_attribute ID_PATH" in multipatch.conf.
To do it only for Dell SANs (if you are using also some other multipath
SANs here), you may use per-device definition like this:

Edit `/etc/multipath.conf`
```
devices {
        device {
                vendor          "EQLOGIC"
                product         "100E-00"
                uid_attribute   ID_PATH
                path_checker    tur
        }
}
```

## Configure the storage
_⚠️ The tasks described in this section should be performed and validated on the master before adding node to the PVEcluster._  

PVE currently does not provide interface to add custom storage plugins,
so you need to add it manually into `/etc/pve/storage.cfg`.

Edit to add to `/etc/pve/storage.cfg` :
```
dellps: eq-pve
        adminaddr <ipv4/ipv6>
        groupaddr <ipv4/ipv6>
        login <login>
        multipath 0
        password <password>
        pool default
        chaplogin <CHAP_initiator_login>
        content images
        shared 1
```

## Additional informations

Info how to set up iSCSI multipath at system and open-iscsi levels, see
https://linux.dell.com/files/whitepapers/iSCSI_Multipathing_in_Ubuntu_Server.pdf
(but do not set node startup to automatic).

Also, Debian multipath-tools currently have bug 
https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=799781
which will lead to long volumes activation times. To workaround it, comment-out
(or delete) rule in /lib/udev/rules.d/60-multipath.rules WARNING: this way may
be dangerous if you are using multipath boot.

## References
This project is build on code structure and ideas of various project : 
 - https://github.com/mityarzn/pve-storage-custom-dellps/
 - https://git.proxmox.com/?p=pve-storage.git
 - https://github.com/LINBIT/linstor-proxmox