package PVE::Storage::Custom::DellPSPlugin;

use strict;
use warnings;

use PVE::Storage::Plugin;
use base qw(PVE::Storage::Plugin);

use Data::Dumper;
use IO::File;
use POSIX qw(ceil);
use Net::Telnet;
use Storable qw(lock_store lock_retrieve);

use PVE::Tools      qw(run_command trim file_read_firstline dir_glob_regex);
use PVE::JSONSchema qw(get_standard_option);
use PVE::Cluster    qw(cfs_read_file cfs_write_file cfs_lock_file);

use DELLPS::DellPS;
use DELLPS::ISCSI;
use DELLPS::PluginHelper qw(getmultiplier);

my $PLUGIN_VERSION = '0.0.0';

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
    return $scfg->{pool} || $default_multipath;
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

# TODO
sub parse_volname {
    my ( $class, $volname ) = @_;

    if ( $volname =~ m/^((vm|base)-(\d+)-\S+)$/ ) {
        return ( 'images', $1, $3, undef, undef, $2 eq 'base', 'raw' );
    }

    die "unable to parse PVE volume name '$volname'\n";
}

sub filesystem_path {
    my ( $class, $scfg, $volname, $snapname ) = @_;

# TODO: Implement direct attached device snapshot
#die "Direct attached device snapshot is not implemented" if defined($snapname);
    my $cache;
    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);
    my $target = '';
    if ($snapname) {
        $target = dell_get_lun_target( $scfg, $cache, $name, $snapname )
          || die "Cannot get iscsi tagret name";

    }
    else {
        $target = dell_get_lun_target( $scfg, $cache, $name )
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
    my ( $class, $storeid, $scfg, $volname ) = @_;

    die "Creating base image is currently unimplemented";
}

# TODO
sub clone_image {
    my ( $class, $scfg, $storeid, $volname, $vmid, $snap ) = @_;

    my ( $vtype, $parsedname, $parsedvmid, undef, undef, $isBase, $format ) =
      $class->parse_volname($volname);

    die "clone_image on wrong vtype '$vtype'\n" if $vtype ne 'images';

    my $newname = $class->find_free_diskname( $storeid, $scfg, $vmid );

    my $cache;    # Dell connection cache
    if ($snap) {
        dell_clone_lun( $scfg, $cache, $volname, $newname, $snap );
    }
    else {
        dell_clone_lun( $scfg, $cache, $volname, $newname );
    }
    return $newname;
}

# TODO
sub alloc_image {
    my ( $class, $storeid, $scfg, $vmid, $fmt, $name, $size ) = @_;

    # Size is given in kib;

    my $min_kib = 3 * 1024;
    $size = $min_kib unless $size > $min_kib;

    die "unsupported format '$fmt'" if $fmt ne 'raw';

    my $volname = $name;

    # Validate volname
    die "illegal name '$volname' - should be 'vm-$vmid-*'\n"
      if $volname && $volname !~ m/^((vm|base)-(\d+)-\S+)$/;

    # If volname not set, find one
    $volname = $class->find_free_diskname( $storeid, $scfg, $vmid, $fmt, 0 );

    my $cache;    # Dell connection cache
        # Convert to megabytes and grow on one megabyte boundary if needed
    dell_create_lun( $scfg, $cache, $volname, ceil( $size / 1000 ) . 'MB' );
    dell_configure_lun( $scfg, $cache, $volname );

    return $volname;
}

# TODO
sub free_image {
    my ( $class, $storeid, $scfg, $volname, $isBase ) = @_;

    # Will free it in background
    return sub {
        my $cache;    # Dell connection cache
        if ( $scfg->{multipath} eq '0' ) {
            $class->iscsi_disable( $scfg, $cache, $volname );
        }
        else {
            $class->multipath_disable( $scfg, $cache, $volname );
        }
        dell_delete_lun( $scfg, $cache, $volname );
    };
}

# TODO
sub list_images {
    my ( $class, $storeid, $scfg, $vmid, $vollist, $cache ) = @_;

    my $cache_key  = 'dellps:lun';

    $cache->{$cache_key} = dellps($scfg)->list_luns( $scfg, $cache )
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
    my ( $class, $storeid, $scfg, $cache ) = @_;

    my $pool = get_pool();

    my $cache_key  = 'dellps:sizeinfos';
    my $info_cache = '/var/cache/dell-proxmox/sizeinfos';

    unless ( $cache->($cache_key) ) {
        my $max_age = get_status_cache($scfg);

        if ( $max_age and not cache_needs_update( $info_cache, $max_age ) ) {
            $cache->{$cache_key} = lock_retrieve($info_cache);
        }
        else {
            my $infos = dellps($scfg)->query_all_size_info();
            $cache->{cache_key} = $infos;
            lock_store( $infos, $info_cache ) if $max_age;
        }
    }

    my $total = $cache->{$cache_key}->{$pool}->{total};
    my $avail  = $cache->{$cache_key}->{$pool}->{free};
    my $used  = $cache->{$cache_key}->{$pool}->{used};

    return undef unless defined($total); # key/RG does not even exist, mark undef == "inactive"
    if ($total == 0) { # invalidate caches but continue
        my $infos = dellps($scfg)->query_all_size_info();
        $cache->{$cache_key} = $infos;
        lock_store($infos, $info_cache);
    }


}

sub activate_storage {
    my ( $class, $storeid, $scfg, $cache ) = @_;

    # Server's SCSI subsystem is always up, so there's nothing to do
    return 1;
}

# TODO
sub deactivate_storage {
    my ( $class, $storeid, $scfg, $cache ) = @_;

    # Server's SCSI subsystem is always up, so there's nothing to do
    return 1;
}

# TODO
sub activate_volume {
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;

    print "Activating '$volname'\n";
    if ( $scfg->{multipath} eq '0' ) {
        if ($snapname) {
            $class->iscsi_enable( $scfg, $cache, $volname, $snapname );
        }
        else {
            $class->iscsi_enable( $scfg, $cache, $volname );
        }
    }
    else {
        die "volume snapshot [de]activation not possible on multipath device"
          if $snapname;
        $class->multipath_enable( $scfg, $cache, $volname );
    }
    return 1;
}

# TODO
sub deactivate_volume {
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;

    print "Deactivating '$volname'\n";
    if ( $scfg->{multipath} eq '0' ) {
        $class->iscsi_disable( $scfg, $cache, $volname );
    }
    else {
        die "volume snapshot [de]activation not possible on multipath device"
          if $snapname;
        $class->multipath_disable( $scfg, $cache, $volname );
    }
    return 1;
}

# TODO
sub volume_resize {
    my ( $class, $scfg, $storeid, $volname, $size, $running ) = @_;
    my $cache;
    dell_resize_lun( $scfg, $cache, $volname,
        ceil( $size / 1000 / 1000 ) . 'MB' );

    my $target = dell_get_lun_target( $scfg, $cache, $volname )
      || die "Cannot get iscsi tagret name";

    # rescan target for changes
    run_command(
        [
            '/usr/bin/iscsiadm',            '-m',
            'node',                         '--portal',
            $scfg->{'groupaddr'} . ':3260', '--target',
            $target,                        '-R'
        ]
    );

    return undef;
}

# TODO
sub rename_volume {
    my ( $class, $scfg, $storeid, $source_volname, $target_vmid,
        $target_volname )
      = @_;
    my $cache;

    my ( undef, $source_image, $source_vmid, $base_name, $base_vmid, undef,
        $format )
      = $class->parse_volname($source_volname);
    $target_volname =
      $class->find_free_diskname( $storeid, $scfg, $target_vmid, $format )
      if !$target_volname;

    my $dat = dell_list_luns( $scfg, undef );
    die "target volume '${target_volname}' already exists\n"
      if ( $dat->{$target_volname} );

    dell_rename_lun( $scfg, $cache, $source_volname, $target_volname );
    return "${storeid}:${target_volname}";

}

# TODO
sub volume_snapshot {
    my ( $class, $scfg, $storeid, $volname, $snap ) = @_;
    my $cache;

    if ( dell_snapshot_exist( $scfg, $cache, $volname, $snap ) ) {
        dell_create_snapshot( $scfg, $cache, $volname, $snap );
    }
    else {
        die "target snapshot name already exists.";
    }

    return undef;
}

# TODO
sub volume_snapshot_rollback {
    my ( $class, $scfg, $storeid, $volname, $snap ) = @_;
    my $cache;

    dell_rollback_snapshot( $scfg, $cache, $volname, $snap );

    #size could be changed here? Check for device changes.
    my $target = dell_get_lun_target( $scfg, $cache, $volname )
      || die "Cannot get iscsi tagret name";

    sleep 5;

    # rescan target for changes
    run_command(
        [
            '/usr/bin/iscsiadm',            '-m',
            'node',                         '--portal',
            $scfg->{'groupaddr'} . ':3260', '--target',
            $target,                        '-R'
        ],
        noerr => 1
    );

    return undef;
}

# TODO
sub volume_snapshot_delete {
    my ( $class, $scfg, $storeid, $volname, $snap, $running ) = @_;
    my $cache;

    dell_delete_snapshot( $scfg, $cache, $volname, $snap );
    return undef;
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
        #template => {}, // TODO
        copy       => { base => 1, current => 1, snap => 1 },
        sparseinit => { base => 1, current => 1 },

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
