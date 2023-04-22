package PVE::Storage::Custom::DellPSPlugin;

use strict;
use warnings;
use Data::Dumper;
use IO::File;
use POSIX qw(ceil);
use PVE::Tools qw(run_command trim file_read_firstline dir_glob_regex);
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);
use PVE::Cluster qw(cfs_read_file cfs_write_file cfs_lock_file);
use Net::Telnet;
use Data::Dumper;

use base qw(PVE::Storage::Plugin);

sub getmultiplier {
    my ($unit) = @_;
    my $mp;  # Multiplier for unit
    if ($unit eq 'MB') {
	$mp = 1000*1000;
    } elsif ($unit eq 'GB'){
	$mp = 1000*1000*1000;
    } elsif ($unit eq 'TB') {
	$mp = 1000*1000*1000*1000;
    } else {
	$mp = 1000*1000*1000;
	warn "Bad size suffix \"$4\", assuming gigabytes";
    }
    return $mp;
}

sub validate_config {
    my ($scfg) = @_;

    # Validate mutipath config
    my $multipath_service_state = run_command("systemctl list-units --all --state=active --type=service | grep multipath", noerr => 1, quiet => 1);
    $multipath_service_state = $multipath_service_state == 0 ? 1 : 0; # Grep retcode equal 0 if result found
    if ("$multipath_service_state" ne $scfg->{multipath}) {
        print "Mismatch between plugin config and service state for multipath.\n";
        print "Plugin config : ", $scfg->{multipath}, "\n";
        print "Service state : ", $multipath_service_state, "\n";

        return 0;
    };

    # Add check for autologin
    return 1;
}

sub dell_connect {
    my ($scfg) = @_;

    # Validate config before openning a connection
    my $isValid = validate_config($scfg);
    if (!$isValid) {
        die "dell_connect: Validation of the configuration failed.\n";
    };

    # Configure Telnet client
    my $obj = new Net::Telnet(
	Host => $scfg->{adminaddr},
    # Uncomment to activate logs (debug only)
	#Input_log  => "/tmp/dell.log",
	#Output_log => "/tmp/dell.log",
    );

    # Initialize session with credentials
    $obj->login($scfg->{login}, $scfg->{password});

    # Configure Dell PS cli for this telnet sessions
    $obj->cmd('cli-settings events off');
    $obj->cmd('cli-settings formatoutput off');
    $obj->cmd('cli-settings confirmation off');
    $obj->cmd('cli-settings displayinMB on');
    $obj->cmd('cli-settings idlelogout off');
    $obj->cmd('cli-settings paging off');
    $obj->cmd('cli-settings reprintBadInput off');
    $obj->cmd('stty hardwrap off');

    # Return telnet session
    return $obj;
}

sub dell_create_lun {
    my ($scfg, $cache, $name, $size) = @_;
    $cache->{telnet} = dell_connect($scfg) unless $cache->{telnet};
    my $tn = $cache->{telnet};

    $tn->cmd(sprintf('volume create %s %s pool %s thin-provision', $name, $size, $scfg->{'pool'}));
}

sub dell_configure_lun {
    my ($scfg, $cache, $name) = @_;

    $cache->{telnet} = dell_connect($scfg) unless $cache->{telnet};
    my $tn = $cache->{telnet};
    if ((!defined($scfg->{allowedaddr}) || $scfg->{allowedaddr} eq '') &&  (!defined($scfg->{chaplogin}) || $scfg->{chaplogin} eq '')) {
        # No allowedaddr nor chaplogin => unrestricted-access.
        $tn->cmd(sprintf("volume select %s access create ipaddress *.*.*.* authmethod none", $name));
    } elsif ((!defined($scfg->{allowedaddr}) || $scfg->{allowedaddr} eq '') &&  (defined($scfg->{chaplogin}) && $scfg->{chaplogin} ne '')) {
        # Only a chaplogin given => access through auth on any ip
        $tn->cmd(sprintf("volume select %s access create ipaddress *.*.*.* username %s authmethod chap", $name, $scfg->{chaplogin}));
    } elsif ((defined($scfg->{allowedaddr}) && $scfg->{allowedaddr} ne '')){
        my $usernamestr = '';
        if (defined($scfg->{chaplogin}) && $scfg->{chaplogin} ne '') {
            $usernamestr = "username " . $scfg->{chaplogin} . " authmethod chap ";
        };
        
        my @allowedaddr = split(' ', $scfg->{allowedaddr});
        foreach my $addr ( @allowedaddr ) {
            $tn->cmd(sprintf("volume select %s access create ipaddress %s %s", $name, $addr, $usernamestr));
        };
    };

    # PVE itself manages access to LUNs, so that's OK.
    $tn->cmd(sprintf("volume select %s multihost-access enable", $name));
}

sub dell_delete_lun {
    my ($scfg, $cache, $name) = @_;
    $cache->{telnet} = dell_connect($scfg) unless $cache->{telnet};
    my $tn = $cache->{telnet};
    
    # Snapshot must be offline in order to be deleted
    my @lines = $tn->cmd(sprintf("volume select %s offline", $name));
    if ($#lines > 1) {
        die 'Cannot set volume offline!';
        return 0;
    } else {
        # Delete the volume
        @lines = $tn->cmd(sprintf("volume delete %s", $name));
        if ($#lines > 1) {
            die 'Cannot set lun offline';
            return 0;
        };
    };

    return 1;
}

sub dell_resize_lun {
    my ($scfg, $cache, $name, $size) = @_;
    $cache->{telnet} = dell_connect($scfg) unless $cache->{telnet};
    my $tn = $cache->{telnet};

    $tn->cmd(sprintf("volume select %s size %s no-snap", $name, $size));
}

sub dell_create_snapshot {
    my ($scfg, $cache, $name, $snapname) = @_;
    $cache->{telnet} = dell_connect($scfg) unless $cache->{telnet};
    my $tn = $cache->{telnet};

    # Create a snapshot
    my @lines = $tn->cmd(sprintf("volume select %s snapshot create-now description %s", $name, $snapname));

    #print Dumper(@lines);
    if (!($lines[0] =~ m/succeeded/)) {
        die 'Cannot create snapshot for volume!';
        return 0;
    } else {
        # Rename the created snapshot to a predefined name
        my @lineparts = split(' ', $lines[1]);
        @lines = $tn->cmd(sprintf("volume select %s snapshot rename '%s' '%s'", $name, $lineparts[3], $snapname));
        if ($#lines > 1) {
            die 'Cannot create snapshot for volume!';
            return 0;
        };
    };

    return 1;
}

sub dell_delete_snapshot {
    my ($scfg, $cache, $name, $snapname) = @_;
    $cache->{telnet} = dell_connect($scfg) unless $cache->{telnet};
    my $tn = $cache->{telnet};

    # Snapshot must be offline in order to be deleted
    my @lines = $tn->cmd(sprintf("volume select %s snapshot select '%s' offline", $name, $snapname));
    if ($#lines > 1) {
        die 'Cannot set snapshot offline for volume!';
        return 0;
    } else {
        # Delete the snapshot
        @lines = $tn->cmd(sprintf("volume select %s snapshot delete '%s'", $name, $snapname));
        if ($#lines > 1) {
            die 'Cannot set snapshot offline for volume!';
            return 0;
        };
    };

    return 1;
    
}

sub dell_rollback_snapshot {
    my ($scfg, $cache, $name, $snapname) = @_;
    $cache->{telnet} = dell_connect($scfg) unless $cache->{telnet};
    my $tn = $cache->{telnet};

    # Volume and snapshot must be offline to perform a rollback
    $tn->cmd(sprintf("volume select %s offline", $name));

    # Perform the rollback
    my @lines = $tn->cmd(sprintf("volume select %s snapshot select %s restore", $name, $snapname));
    if ($#lines > 1) {
            die 'Cannot rollback snapshot for volume!';
            die 'Volume kept offline,  reactivate manually!';
            return 0;
    }
    
    sleep 5;

    # Remove geneated snapshot post rollback
    my $snaptoremove = '';
    my @partial;
    @lines = $tn->cmd(sprintf("volume select %s snapshot show", $name));
    for my $line (@lines) {
        # The snapshot name is lis
        if ($line =~ /^(vm-(\d+)-disk-\d+)/){
            @partial = split(' ', $line);
            $snaptoremove = $partial[0];
        } elsif ($snaptoremove ne '' && $line =~ /^\s{2}(\d\d)?:(\d\d:)/) {
            @partial = split(' ', $line);
            $snaptoremove = $snaptoremove . $partial[0];
            dell_delete_snapshot($scfg, $cache, $name, $snaptoremove);
            $snaptoremove = '';
        };
    };

    # Reset volume online
    $tn->cmd(sprintf("volume select %s online", $name));
    return 1;

}

sub dell_list_luns {
    my ($scfg, $cache, $vmid, $vollist) = @_;
    $cache->{telnet} = dell_connect($scfg) unless $cache->{telnet};
    my $tn = $cache->{telnet};
    my $res = [];

    my @out = $tn->cmd('volume show');

    # Variables for multiline state volume
    my $currvolname = '';
    my $currvmid = '';
    my $currvolsize = '';

    for my $line (@out) {
        if ($line =~ /^(vm-(\d+)-disk-\d+)\s+([\d\.]+)([GMT]B)/) {
                next if $vmid && $vmid != $2; # $vmid filter
                next if $vollist && !grep(/^$1$/,@$vollist); # $vollist filter
            my $mp = getmultiplier($4);
            push(@$res, {'volid' => $1, 'format' => 'raw', 'size' => $3*$mp, 'vmid' => $2});
        } elsif ($line =~ /^(vm-(\d+)-state-\w+)\s+([\d\.]+)([GMT]B)/) {
            $currvmid = $2;
            my $mp = getmultiplier($4);
            $currvolsize = $3*$mp;
            $currvolname = $1;
        } elsif ($currvolname ne '' && $line =~ /^\s{2}(\w+(-\w+)*)/) {
            $currvolname = $currvolname . $1;
            next if $vmid && $vmid != $currvmid; # $vmid filter
            next if $vollist && !grep(/^$currvolname$/,@$vollist); # $vollist filter
            push(@$res, {'volid' => $currvolname, 'format' => 'raw', 'size' => $currvolsize, 'vmid' => $currvmid});

            $currvolname = '';
            $currvmid = '';
            $currvolsize = '';
        }
    }
    return $res;
}

sub dell_get_lun_target {
    my ($scfg, $cache, $name) = @_;
    $cache->{telnet} = dell_connect($scfg) unless $cache->{telnet};
    my $tn = $cache->{telnet};

    my @out = $tn->cmd(sprintf("volume select %s show", $name));
    for my $line (@out) {
	next unless $line =~ m/^iSCSI Name: (.+)$/;
	return $1;
    }
    return 0;
}

sub dell_status {
    my ($scfg, $cache) = @_;
    $cache->{telnet} = dell_connect($scfg) unless $cache->{telnet};
    my $tn = $cache->{telnet};

    my @out = $tn->cmd('show pool');
    for my $line (@out) {
	next unless ($line =~ m/(\w+)\s+\w+\s+\d+\s+\d+\s+([\d\.]+)([MGT]B)\s+([\d\.]+)([MGT]B)/);
	next unless ($1 eq $scfg->{'pool'});

	my $total = int($2*getmultiplier($3));
	my $free  = int($4*getmultiplier($5));
	my $used = $total-$free;
	return [$total, $free, $used, 1];
    }
}

sub iscsi_enable {
    my ($class, $scfg, $cache, $name) = @_;

    my $target = dell_get_lun_target($scfg, $cache, $name) || die "Cannot get iscsi tagret name";
    if (-e "/dev/disk/by-path/ip-" . $scfg->{'groupaddr'} . ":3260-iscsi-" . $target . "-lun-0") {
        # Rescan target for changes (e.g. resize)
	    run_command(['/usr/bin/iscsiadm', '-m', 'node', '--targetname', $target, '--portal', $scfg->{'groupaddr'} .':3260', '--rescan']);
    } else {
        # Discover portal for new targets
	    run_command(['/usr/bin/iscsiadm', '-m', 'discovery','--type', 'sendtargets', '--portal', $scfg->{'groupaddr'} .':3260']);
        # Login to target. Will produce an error if already logged in.
	    run_command(['/usr/bin/iscsiadm', '-m', 'node', '--targetname', $target, '--portal', $scfg->{'groupaddr'} .':3260', '--login']);
    }

    sleep 1;

    # wait udev to settle divices
    run_command(['/usr/bin/udevadm', 'settle']);

}

sub iscsi_disable {
    my ($class, $scfg, $cache, $name) = @_;

    my $target = dell_get_lun_target($scfg, $cache, $name) || die "Cannot get iscsi tagret name";

    # give some time for runned process to free device
    sleep 5;

    run_command(['/usr/bin/iscsiadm', '-m', 'node', '--targetname', $target, '--portal', $scfg->{'groupaddr'} .':3260', '--logout'], noerr => 1);

    # wait udev to settle divices
    run_command(['/usr/bin/udevadm', 'settle']);
}
sub multipath_enable {
    my ($class, $scfg, $cache, $name) = @_;

    my $target = dell_get_lun_target($scfg, $cache, $name) || die "Cannot get iscsi tagret name";

    # If device exists
    if (-e "/dev/disk/by-id/dm-uuid-mpath-ip-". $scfg->{'groupaddr'} .":3260-iscsi-$target-lun-0") {
	# Rescan target for changes (e.g. resize)
	run_command(['/usr/bin/iscsiadm', '-m', 'node', '--targetname', $target, '--portal', $scfg->{'groupaddr'} .':3260', '--rescan']);
    } else {
	# Discover portal for new targets
	run_command(['/usr/bin/iscsiadm', '-m', 'discovery','--type', 'sendtargets', '--portal', $scfg->{'groupaddr'} .':3260']);

	# Login to target. Will produce warning if already logged in. But that's safe.
	run_command(['/usr/bin/iscsiadm', '-m', 'node', '--targetname', $target, '--portal', $scfg->{'groupaddr'} .':3260', '--login'], noerr => 1);
    }

    sleep 1;

    # wait udev to settle divices
    run_command(['/usr/bin/udevadm', 'settle']);
    #force devmap reload to connect new device.
    run_command(['/usr/sbin/multipath', '-r']);
}

sub multipath_disable {
    my ($class, $scfg, $cache, $name) = @_;

    my $target = dell_get_lun_target($scfg, $cache, $name) || die "Cannot get iscsi tagret name";

    # give some time for runned process to free device
    sleep 5;

    #disable selected target multipathing
    run_command(['/sbin/multipath', '-f', 'ip-'. $scfg->{'groupaddr'} .":3260-iscsi-$target-lun-0"]);

    # Logout from target
    run_command(['/usr/bin/iscsiadm', '-m', 'node', '--targetname', $target, '--portal', $scfg->{'groupaddr'} .':3260', '--logout']);

}

# Configuration

# API version
sub api {
    return 10;
}

sub type {
    return 'dellps';
}

sub plugindata {
    return {
	content => [ {images => 1, rootdir => 1, none => 1}, { images => 1 }],
    };
}

sub properties {
    return {
        groupaddr => {
            description => "Group IP (or DNS name) of storage for iscsi mounts",
            type => 'string', format => 'pve-storage-portal-dns',
        },
        adminaddr => {
            description => "Management IP (or DNS name) of storage.",
            type => 'string', format => 'pve-storage-portal-dns',
        },
        login => {
            description => "Volume admin login",
            type => 'string',
        },
        #password => {
        #    description => "Volume admin password",
        #    type => 'string',
        #},
        allowedaddr => {
            description => "Allowed ISCSI client IP list (space separated)",
            type => 'string',
        },
        chaplogin => {
            description => "CHAP login used in iscsi.conf",
            type => 'string',
        },
        multipath => {
            description => "Volume admin password",
            type => 'boolean',
        },
        
    };
}

sub options {
    return {
        groupaddr => { fixed => 1 },
        pool  => { fixed => 1 },
        login => { fixed => 1 },
        password => { fixed => 1 },
        adminaddr => { fixed => 1 },
        chaplogin => { optional => 1 },
        allowedaddr => { optional => 1 },
        multipath => { fixed => 1 },
        nodes   => { optional => 1 },
        disable => { optional => 1 },
        content => { optional => 1 },
        shared  => { optional => 1 },
    }
}

# Storage implementation

sub parse_volname {
    my ($class, $volname) = @_;

    if ($volname =~ m/vm-(\d+)-disk-\S+/ || $volname =~ m/^vm-(\d+)-state-\S+/) {
        # returns ($vtype, $name, $vmid, $basename, $basevmid, $isBase, $format)
	    return ('images', $volname, $1, undef, undef, undef, 'raw');
    } else {
	    die "Invalid volume $volname";
    }
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;

    # TODO: Implement direct attached device snapshot
    die "Direct attached device snapshot is not implemented" if defined($snapname);

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);
    my $target = dell_get_lun_target($scfg, undef, $name) || die "Cannot get iscsi tagret name";

    my $path;
    if ($scfg->{multipath} eq '0') {
        $path = "/dev/disk/by-path/ip-" . $scfg->{'groupaddr'} . ":3260-iscsi-" . $target . "-lun-0";
    } else {
        $path = "/dev/disk/by-id/dm-uuid-mpath-ip-". $scfg->{'groupaddr'} .":3260-iscsi-" . $target . "-lun-0";
    };

    return wantarray ? ($path, $vmid, $vtype) : $path;
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    die "Creating base image is currently unimplemented";
}

# TODO: Implement clone image feature
sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;

    die "Cloning image is currently unimplemented";
}

# Seems like this method gets size in kilobytes somehow,
# while listing methost return bytes. That's strange.
sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    my $volname = $name;

    if ($fmt eq 'raw') {
        # Validate volname
        die "illegal name '$volname' - should be 'vm-$vmid-* and max 28 character long'\n"
	    if $volname && $volname > 28 && $volname !~ m/^vm-$vmid-disk-/ && $volname !~ m/^vm-$vmid-state-/;

        # If volname not set, find one
        unless ($volname) {
            # List volumes (lun) from the EqualLogic
            my $luns = dell_list_luns($scfg, undef, $vmid);
            my $vols;
            for my $lun (@$luns) { # Fill a list with volume name
            $vols->{$lun->{'volid'}} = 1;
            }

            # Check the volname does not already exists
            for (my $i = 1; $i < 100; $i++) {
                if (!$vols->{"vm-$vmid-disk-$i"}) {
                    $volname = "vm-$vmid-disk-$i";
                    last;
                }
            }
        }

        my $cache; # Dell connection cache
        # Convert to megabytes and grow on one megabyte boundary if needed
        dell_create_lun($scfg, $cache, $volname, ceil($size/1000) . 'MB');
        dell_configure_lun($scfg, $cache, $volname);
    } else {
        die "unsupported format '$fmt'";
    }
    return $volname;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    # Will free it in background
    return sub {
        my $cache; # Dell connection cache
        if ($scfg->{multipath} eq '0') {
            $class->iscsi_disable($scfg, $cache, $volname);
        } else {
            $class->multipath_disable($scfg, $cache, $volname);
        }
        dell_delete_lun($scfg, $cache, $volname);
    };
}

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $res = dell_list_luns($scfg, $cache, $vmid, $vollist);

    foreach my $vol (@$res) {
        $vol->{volid} = "$storeid:" . $vol->{volid};
    }

    return $res;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    return @{dell_status($scfg, $cache)};
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    # Server's SCSI subsystem is always up, so there's nothing to do
    return 1;
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    # Server's SCSI subsystem is always up, so there's nothing to do
    return 1;
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    die "volume snapshot [de]activation not possible on multipath device" if $snapname;

    warn "Activating '$volname'\n";
    if ($scfg->{multipath} eq '0') {
        $class->iscsi_enable($scfg, $cache, $volname);
    } else {
        $class->multipath_enable($scfg, $cache, $volname);
    }

    return 1;
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    die "volume snapshot [de]activation not possible on multipath device" if $snapname;

    warn "Deactivating '$volname'\n";
    if ($scfg->{multipath} eq '0') {
        $class->iscsi_disable($scfg, $cache, $volname);
    } else {
        $class->multipath_disable($scfg, $cache, $volname);
    }

    return 1;
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;
    my $cache;
    dell_resize_lun($scfg, $cache, $volname, ceil($size/1000/1000) . 'MB');

    my $target = dell_get_lun_target($scfg, $cache, $volname) || die "Cannot get iscsi tagret name";
    # rescan target for changes
    run_command(['/usr/bin/iscsiadm', '-m', 'node', '--portal', $scfg->{'groupaddr'} .':3260', '--target', $target, '-R']);

    return undef;
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;
    my $cache;

    dell_create_snapshot($scfg, $cache, $volname, $snap);
    return undef;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;
    my $cache;

    dell_rollback_snapshot($scfg, $cache, $volname, $snap);

    #size could be changed here? Check for device changes.
    my $target = dell_get_lun_target($scfg, $cache, $volname) || die "Cannot get iscsi tagret name";

    sleep 5;
    # rescan target for changes
    run_command(['/usr/bin/iscsiadm', '-m', 'node', '--portal', $scfg->{'groupaddr'} .':3260', '--target', $target, '-R'], noerr => 1);

    return undef;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;
    my $cache;

    dell_delete_snapshot($scfg, $cache, $volname, $snap);
    return undef;
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running, , $opts) = @_;

    my $features = {
	snapshot => { current => 1, snap => 1 },
	sparseinit => { current => 1 },
    };

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase) =
	$class->parse_volname($volname);

    my $key = undef;
    if($snapname) {
	$key = 'snap';
    } else {
	$key =  $isBase ? 'base' : 'current';
    }
    return 1 if $features->{$feature}->{$key};

    return undef;
}

1;