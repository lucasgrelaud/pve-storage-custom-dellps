package DELLPS::PluginHelper;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK =
  qw(getmultiplier valid_legacy_name valid_snap_name valid_cloudinit_name valid_state_name valid_pvc_name valid_fleece_name valid_name volname_and_snap_to_snapname);

sub getmultiplier {
    my ($unit) = @_;
    my $mp;    # Multiplier for unit
    if ( $unit eq 'MB' ) {
        $mp = 1000 * 1000;
    }
    elsif ( $unit eq 'GB' ) {
        $mp = 1000 * 1000 * 1000;
    }
    elsif ( $unit eq 'TB' ) {
        $mp = 1000 * 1000 * 1000 * 1000;
    }
    else {
        $mp = 1000 * 1000 * 1000;
        warn "Bad size suffix \"$4\", assuming gigabytes";
    }
    return $mp;
}

# From : https://github.com/LINBIT/linstor-proxmox/blob/master/LINBIT/PluginHelper.pm
sub valid_legacy_name {
    $_[0] =~ /^vm-\d+-disk-\d+\z/;
}

# From : https://github.com/LINBIT/linstor-proxmox/blob/master/LINBIT/PluginHelper.pm
sub valid_snap_name {
    $_[0] =~ /^snap_.+_.+\z/;
}

# From : https://github.com/LINBIT/linstor-proxmox/blob/master/LINBIT/PluginHelper.pm
sub valid_cloudinit_name {
    $_[0] =~ /^vm-\d+-cloudinit\z/;
}

# From : https://github.com/LINBIT/linstor-proxmox/blob/master/LINBIT/PluginHelper.pm
sub valid_state_name {
    $_[0] =~ /^vm-\d+-state-.+\z/;
}

# From : https://github.com/LINBIT/linstor-proxmox/blob/master/LINBIT/PluginHelper.pm
sub valid_pvc_name {
    $_[0] =~ /^vm-\d+-pvc-.+\z/;
}

# From : https://github.com/LINBIT/linstor-proxmox/blob/master/LINBIT/PluginHelper.pm
sub valid_fleece_name {
    $_[0] =~ /^vm-\d+-fleece-.+\z/;
}

# From : https://github.com/LINBIT/linstor-proxmox/blob/master/LINBIT/PluginHelper.pm
sub valid_name {
         valid_legacy_name $_[0]
      or valid_cloudinit_name $_[0]
      or valid_state_name $_[0]
      or valid_pvc_name $_[0]
      or valid_fleece_name $_[0];
}

sub volname_and_snap_to_snapname {
    my ( $volname, $snap ) = @_;
    return "snap_${volname}_${snap}";
}

1;
