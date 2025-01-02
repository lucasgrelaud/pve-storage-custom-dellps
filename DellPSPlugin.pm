package PVE::Storage::Custom::DellPSPlugin;

use strict;
use warnings;

use PVE::Storage::Plugin;
use base qw(PVE::Storage::Plugin);

use Data::Dumper;
use Carp qw( confess );
use IO::File;
use POSIX qw(ceil);
use Net::Telnet;
use Storable qw(lock_store lock_retrieve);

use PVE::Tools      qw(run_command trim file_read_firstline dir_glob_regex);
use PVE::JSONSchema qw(get_standard_option);
use PVE::Cluster    qw(cfs_read_file cfs_write_file cfs_lock_file);

use DELLPS::DellPS;
use DELLPS::PluginHelper
  qw(getmultiplier valid_vm_name valid_base_name valid_snap_name valid_cloudinit_name valid_state_name valid_pvc_name valid_fleece_name valid_name);

my $PLUGIN_VERSION = '2.0.0';

# Configuration

my $default_groupaddr    = "";
my $default_adminaddr    = "";
my $default_login        = "";
my $default_password     = "";
my $default_allowedaddr  = "";
my $default_chaplogin    = "";
my $default_status_cache = 60;
my $default_multipath    = 0;
my $default_pool         = "default";

sub api {
    return 10;
}

sub type {
    return 'dellps';
}

sub plugindata {
    return {
        content =>
          [ { images => 1, rootdir => 1, none => 1 }, { images => 1 } ],
        format => [ { raw => 1 }, 'raw' ],
    };
}

sub properties {
    return {
        groupaddr => {
            description => "Group IP (or DNS name) of storage for iscsi mounts",
            type        => 'string',
            format      => 'pve-storage-portal-dns',
            default     => $default_groupaddr,
        },

        # TODO : rename adminaddr to mgntaddre
        adminaddr => {
            description => "Management IP (or DNS name) of storage.",
            type        => 'string',
            format      => 'pve-storage-portal-dns',
            default     => $default_adminaddr,
        },
        login => {
            description => "Volume admin login",
            type        => 'string',
            default     => $default_login,
        },
        allowedaddr => {
            description => "Allowed ISCSI client IP list (space separated)",
            type        => 'string',
            default     => $default_allowedaddr,
        },
        chaplogin => {
            description => "CHAP login used in iscsi.conf",
            type        => 'string',
            default     => $default_chaplogin,
        },
        multipath => {
            description => "Volume admin password",
            type        => 'boolean',
            default     => $default_multipath,
        },

    };
}

sub options {
    return {
        groupaddr   => { optional => 1 },
        pool        => { optional => 1 },
        login       => { optional => 1 },
        password    => { optional => 1 },
        adminaddr   => { optional => 1 },
        chaplogin   => { optional => 1 },
        allowedaddr => { optional => 1 },
        multipath   => { optional => 1 },
        nodes       => { optional => 1 },
        disable     => { optional => 1 },
        content     => { optional => 1 },
        shared      => { optional => 1 },
    };
}

# helpers (default bound)

sub cache_needs_update {
    my ( $cache_file, $max_cache_age ) = @_;
    my $mtime = ( stat($cache_file) )[9] || 0;

    return time - $mtime >= $max_cache_age;
}

sub get_group_address {
    my ($scfg) = @_;
    return $scfg->{groupaddr} || $default_groupaddr;
}

sub get_managment_address {
    my ($scfg) = @_;
    return $scfg->{adminaddr} || $default_adminaddr;
}

sub get_login {
    my ($scfg) = @_;
    return $scfg->{login} || $default_login;
}

sub get_passwod {
    my ($scfg) = @_;
    return $scfg->{password} || $default_password;
}

sub get_allowed_address {
    my ($scfg) = @_;
    return $scfg->{allowedaddr} || $default_allowedaddr;
}

sub get_chap_login {
    my ($scfg) = @_;
    return $scfg->{chaplogin} || $default_chaplogin;
}

sub get_multipath {
    my ($scfg) = @_;
    return $scfg->{multipath} || $default_multipath;
}

sub get_pool {
    my ($scfg) = @_;
    return $scfg->{pool} || $default_pool;
}

sub get_status_cache {
    my ($scfg) = @_;
    return $scfg->{status_cache} || $default_status_cache;
}

sub dellps {
    my ($scfg) = @_;

    my $group_address      = get_group_address($scfg);
    my $management_address = get_managment_address($scfg);
    my $login              = get_login($scfg);
    my $password           = get_passwod($scfg);
    my $allowed_address    = get_allowed_address($scfg);
    my $chap_login         = get_chap_login($scfg);
    my $multipath          = get_multipath($scfg);
    my $pool               = get_pool($scfg);

    my $cli = DELLPS::DellPS::dell_connect(
        {
            management_address => $management_address,
            login              => $login,
            password           => $password,
            multipath          => $multipath,
        }
    );

    if ( defined($cli) ) {
        return DELLPS::DellPS->new(
            {
                cli             => $cli,
                pool            => $pool,
                allowed_address => $allowed_address,
                group_address   => $group_address,
                chap_login      => $chap_login,
                multipath       => $multipath,
            }
        );
    }

    die("Could not connect to the Dell PS storage");

}

# Storage implementation

sub parse_volname {
    warn "DEBUG: parse_volname";
    my ( $class, $volname ) = @_;

    if ( $volname =~ m/^((vm|base)-(\d+)-\S+)$/ ) {
        return ( 'images', $1, $3, undef, undef, $2 eq 'base', 'raw' );
    }

    die "unable to parse PVE volume name '$volname'\n";
}

sub filesystem_path {
    warn "DEBUG: filesystem_path";
    my ( $class, $scfg, $volname, $snapname ) = @_;

    my $dellps = dellps($scfg);
    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);
    my $target = '';
    if ($snapname) {
        $target = $dellps->get_lun_target( $name, $snapname )
          || die "Cannot get iscsi tagret name";

    }
    else {
        $target = $dellps->get_lun_target($name)
          || die "Cannot get iscsi tagret name";

    }

    my $path;
    if ( $scfg->{multipath} eq '0' ) {
        $path =
            "/dev/disk/by-path/ip-"
          . $scfg->{'groupaddr'}
          . ":3260-iscsi-"
          . $target
          . "-lun-0";
    }
    else {
        $path =
            "/dev/disk/by-id/dm-uuid-mpath-ip-"
          . $scfg->{'groupaddr'}
          . ":3260-iscsi-"
          . $target
          . "-lun-0";
    }

    return wantarray ? ( $path, $vmid, $vtype ) : $path;
}

# TODO : Implement create_base
# See LVMThinPlugin.pm implem
sub create_base {
    warn "DEBUG: create_base";
    my ( $class, $storeid, $scfg, $volname ) = @_;

    my ( $vtype, $parsedname, $parsedvmid, $basename, $basevmid, $isBase,
        $format )
      = $class->parse_volname($volname);

    die "create_base not possible with base image\n" if $isBase;

    my $dellps = dellps($scfg);
    my $luns   = $dellps->get_luns();

    # Reject conversion to base if volume has snapshots
    die "unable to create base volume - found snaphost \n"
      if $luns->{$parsedname}->{snapshot_count} gt 0;

    # Convert to template
    eval { $dellps->convert_lun_to_template($parsedname);};
    confess $@ if $@;

    # Rename volume to base
    my $newname = $parsedname;
    $newname =~ s/^vm-/base-/;
    eval { $dellps->rename_lun( $parsedname, $newname ); };
    confess $@ if $@;
    
    return $newname;
}

# TODO
sub clone_image {
    warn "DEBUG: clone_image";
    my ( $class, $scfg, $storeid, $volname, $vmid, $snap ) = @_;

    my ( $vtype, $parsedname, $parsedvmid, undef, undef, $isBase, $format ) =
      $class->parse_volname($volname);

    die "clone_image on wrong vtype '$vtype'\n" if $vtype ne 'images';

    my $newname = $class->find_free_diskname( $storeid, $scfg, $vmid );

    my $dellps = dellps($scfg);
    if ($snap) {
        $dellps->clone_lun( $volname, $newname, $snap );
    }
    else {
        $dellps->clone_lun( $volname, $newname );
    }
    return $newname;
}

sub alloc_image {
    warn "DEBUG: alloc_image";
    my ( $class, $storeid, $scfg, $vmid, $fmt, $name, $size ) = @_;
    
    # Size is given in kib;
    my $min_kib = 3 * 1024;
    $size = $min_kib unless $size > $min_kib;

    die "unsupported format '$fmt'" if $fmt ne 'raw';

    my $dellps_name;

    my $dellps = dellps($scfg);
    my $luns   = $dellps->get_luns();

    if ($name) {
        if (   valid_vm_name($name)
            or valid_base_name($name)
            or valid_state_name($name)
            or valid_pvc_name($name)
            or valid_fleece_name($name) )
        {
            $dellps_name = $name;
        }
        elsif ( valid_cloudinit_name($name) ) {
            $dellps_name = $name;

            # If cloudinit image already exist in the pool, no need to recreate
            return $dellps_name if exists $luns->{$dellps_name};
        }
        else {
            die
"allocated name ('$name') has to be a valid vm, base, state, or cloud-init name";
        }

        die "volume '$dellps_name' already exists\n"
          if exists $luns->{$dellps_name};
    }
    else {
        $dellps_name =
          $class->find_free_diskname( $storeid, $scfg, $vmid, $fmt );
    }

    die "unable to allocate an image name for VM $vmid in storage '$storeid'\n"
      if !defined($dellps_name);

    eval {
        # Convert to megabytes and grow on one megabyte boundary if needed
        my $adjusted_size = ceil( $size * 0.001024 );
        $dellps->create_lun( $dellps_name, $adjusted_size . 'MB' );
        $dellps->configure_lun($dellps_name);
    };
    confess $@ if $@;
    return $dellps_name;
}

sub free_image {
    warn "DEBUG: free_image";
    my ( $class, $storeid, $scfg, $volname, $isBase ) = @_;

    my $dellps      = dellps($scfg);
    my $is_online   = 1;
    my $dellps_name = $volname;

    $dellps->set_offline($dellps_name);

    for ( 0 .. 9 ) {
        $is_online = $dellps->is_online( $dellps_name, undef );
        last if ( !$is_online );
        sleep(1);
    }

    warn "Resource $dellps_name still in use after giving it some time"
      if ($is_online);

    # volume should be offline
    eval {
        if ( $dellps->{multipath} eq '0' ) {
            $dellps->iscsi_disable($volname);
        }
        else {
            $dellps->multipath_disable($volname);
        }
        $dellps->delete_lun($volname);
    };
    confess $@ if $@;

    # Will free it in background
    return undef;
}

sub list_images {
    warn "DEBUG: list_images";
    my ( $class, $storeid, $scfg, $vmid, $vollist, $cache ) = @_;

    my $cache_key = 'dellps:lun';

    $cache->{$cache_key} = dellps($scfg)->get_luns()
      unless $cache->{$cache_key};

    my $dat = $cache->{$cache_key};
    return [] if !$dat;

    my $res = [];
    foreach my $volname ( keys %$dat ) {

        next if $volname !~ m/^(vm|base)-(\d+)-/;
        my $owner = $2;

        my $info = $dat->{$volname};

        my $volid = "$storeid:$volname";

        if ($vollist) {
            my $found = grep { $_ eq $volid } @$vollist;
            next if !$found;
        }
        else {
            next if defined($vmid) && ( $owner ne $vmid );
        }

        push @$res,
          {
            volid  => $volid,
            format => 'raw',
            size   => $info->{size},
            vmid   => $owner,
          };
    }
    return $res;
}

sub status {
    warn "DEBUG: status";
    my ( $class, $storeid, $scfg, $cache ) = @_;

    my $pool = get_pool();

    my $dellps = dellps($scfg);

    my $cache_key  = 'dellps:sizeinfos';
    my $info_cache = '/var/cache/dellps-proxmox/sizeinfos';

    unless ( $cache->{$cache_key} ) {
        my $max_age = get_status_cache($scfg);

        if ( $max_age and not cache_needs_update( $info_cache, $max_age ) ) {
            $cache->{$cache_key} = lock_retrieve($info_cache);
        }
        else {
            my $infos = $dellps->query_all_size_info();
            $cache->{$cache_key} = $infos;
            lock_store( $infos, $info_cache ) if $max_age;
        }
    }

    my $total = $cache->{$cache_key}->{$pool}->{total};
    my $avail = $cache->{$cache_key}->{$pool}->{avail};
    my $used  = $cache->{$cache_key}->{$pool}->{used};

    return undef
      unless defined($total)
      ;    # key/RG does not even exist, mark undef == "inactive"
    if ( $total == 0 ) {    # invalidate caches but continue
        my $infos = $dellps->query_all_size_info();
        $cache->{$cache_key} = $infos;
        lock_store( $infos, $info_cache );
    }
    return ( $total, $avail, $used, 1 );
}

sub activate_storage {
    warn "DEBUG: activate_storage";
    my ( $class, $storeid, $scfg, $cache ) = @_;

    return undef;
}

sub deactivate_storage {
    warn "DEBUG: deactivate_storage";
    my ( $class, $storeid, $scfg, $cache ) = @_;

    return undef;
}

sub activate_volume {
    warn "DEBUG: activate_volume";
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;

    my $dellps      = dellps($scfg);
    my $dellps_name = $volname;

    if ( $dellps->{multipath} eq '0' ) {
        if ($snapname) {
            $dellps->iscsi_enable( $dellps_name, $snapname );
        }
        else {
            $dellps->iscsi_enable($dellps_name);
        }
    }
    else {
        die "volume snapshot activation not possible on multipath device"
          if $snapname;
        $dellps->multipath_enable($dellps_name);
    }
    return undef;
}

sub deactivate_volume {
    warn "DEBUG: deactivate_volume";
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;

    my $dellps      = dellps($scfg);
    my $dellps_name = $volname;

    if ( $dellps->{multipath} eq '0' ) {
        if ($snapname) {
            $dellps->iscsi_disable( $dellps_name, $snapname );
        }
        else {
            $dellps->iscsi_disable($dellps_name);
        }
    }
    else {
        die "volume snapshot deactivation not possible on multipath device"
          if $snapname;
        $dellps->multipath_disable($dellps_name);
    }
    return undef;
}

sub volume_resize {
    warn "DEBUG: volume_resize";
    my ( $class, $scfg, $storeid, $volname, $size, $running ) = @_;

    my $dellps      = dellps($scfg);
    my $dellps_name = $volname;

    # Convert $size from B to MB
    my $new_size = ceil( $size / 1000 / 1000 );

    $dellps->resize_lun( $dellps_name, $new_size . 'MB' );

    my $target = $dellps->get_lun_target($dellps_name)
      || die "Cannot get iscsi tagret name";

    # rescan target for changes
    run_command(
        [
            '/usr/bin/iscsiadm', '-m', 'node', '--portal',
            $dellps->{group_address} . ':3260',
            '--target', $target, '-R'
        ]
    );

    return 1;
}

sub rename_volume {
    warn "DEBUG: rename_volume";
    my ( $class, $scfg, $storeid, $source_volname, $target_vmid,
        $target_volname )
      = @_;

    my $dellps = dellps($scfg);

    my ( undef, $source_image, $source_vmid, $base_name, $base_vmid, undef,
        $format )
      = $class->parse_volname($source_volname);
    $target_volname =
      $class->find_free_diskname( $storeid, $scfg, $target_vmid, $format )
      if !$target_volname;

    my $dat = $dellps->get_luns();
    die "target volume '${target_volname}' already exists\n"
      if ( $dat->{$target_volname} );

    eval { $dellps->rename_lun( $source_volname, $target_volname ); };
    confess $@ if $@;

    return "${storeid}:${target_volname}";

}

sub volume_snapshot {
    warn "DEBUG: volume_snapshot";
    my ( $class, $scfg, $storeid, $volname, $snap ) = @_;
    my $dellps = dellps($scfg);

    if ( $dellps->snapshot_exist( $volname, $snap ) ) {
        die "target snapshot name already exists.";
    }

    eval { $dellps->create_snapshot( $volname, $snap ); };
    confess $@ if $@;

    return 1;
}

sub volume_snapshot_rollback {
    warn "DEBUG: volume_snapshot_rollback";
    my ( $class, $scfg, $storeid, $volname, $snap ) = @_;
    my $dellps = dellps($scfg);

    eval {
        $dellps->rollback_snapshot( $volname, $snap );

        #size could be changed here? Check for device changes.
        my $target = $dellps->get_lun_target($volname)
          || die "Cannot get iscsi tagret name";

        sleep 5;

        # rescan target for changes
        # BUG : Use of uninitialized value in concatenation (.) or string
        run_command(
            [
                '/usr/bin/iscsiadm',             '-m',
                'node',                          '--portal',
                $dellps->{group_name} . ':3260', '--target',
                $target,                         '-R'
            ],
            noerr => 1
        );
    };
    confess $@ if $@;

    return 1;
}

sub volume_snapshot_delete {
    my ( $class, $scfg, $storeid, $volname, $snap, $running ) = @_;
    my $dellps = dellps($scfg);

    eval { $dellps->delete_snapshot( $volname, $snap ); };
    confess $@ if $@;

    return 1;
}

# TODO
sub volume_has_feature {
    my (
        $class,   $scfg,     $feature, $storeid,
        $volname, $snapname, $running, $opts
    ) = @_;

    my $features = {
        snapshot => { current => 1 },

        #clone => {base => 1}, # TODO, require template
        template   => { current => 1 },
        copy       => { base    => 1, current => 1, snap => 1 },
        sparseinit => { base    => 1, current => 1 },

        #replicate => {}, # Could not implement now (lacking a replication pool)
        rename => { current => 1 },
    };

    my ( $vtype, $name, $vmid, $basename, $basevmid, $isBase ) =
      $class->parse_volname($volname);

    my $key = undef;
    if ($snapname) {
        $key = 'snap';
    }
    else {
        $key = $isBase ? 'base' : 'current';
    }
    return 1 if $features->{$feature}->{$key};

    return undef;
}

1;
