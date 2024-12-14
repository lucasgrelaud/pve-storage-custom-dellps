package DELLPS::PluginHelper;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK =
  qw(getmultiplier valid_vm_name valid_base_name valid_snap_name valid_cloudinit_name valid_state_name valid_pvc_name valid_fleece_name valid_name);

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

sub valid_vm_name {
    $_[0] =~ /^vm-\d+-disk-\d+\z/;
}

sub valid_base_name {
    $_[0] =~ /^base-\d+-disk-\d+\z/;
}

sub valid_snap_name {
    $_[0] =~ /^snap_.+_.+\z/;
}

sub valid_cloudinit_name {
    $_[0] =~ /^vm-\d+-cloudinit\z/;
}

sub valid_state_name {
    $_[0] =~ /^vm-\d+-state-.+\z/;
}

sub valid_pvc_name {
    $_[0] =~ /^vm-\d+-pvc-.+\z/;
}

sub valid_fleece_name {
    $_[0] =~ /^vm-\d+-fleece-.+\z/;
}

sub valid_name {
         valid_vm_name $_[0]
      or valid_base_name $_[0]
      or valid_cloudinit_name $_[0]
      or valid_state_name $_[0]
      or valid_pvc_name $_[0]
      or valid_fleece_name $_[0];
}


1;
