package DELLPS::ISCSI;

use strict;
use warnings;

use PVE::Tools      qw(run_command);

use DELLPS::DellPS;


sub iscsi_enable {
    my ( $class, $scfg, $cache, $name, $snapname ) = @_;

    my $target = '';
    if ($snapname) {
        $target = dell_get_lun_target( $scfg, $cache, $name, $snapname )
          || die "Cannot get iscsi tagret name";
        dell_set_online( $scfg, $cache, $name, $snapname );
    }
    else {
        $target = dell_get_lun_target( $scfg, $cache, $name )
          || die "Cannot get iscsi tagret name";
    }
    if (  -e "/dev/disk/by-path/ip-"
        . $scfg->{'groupaddr'}
        . ":3260-iscsi-"
        . $target
        . "-lun-0" )
    {
        # Rescan target for changes (e.g. resize)
        run_command(
            [
                '/usr/bin/iscsiadm',            '-m',
                'node',                         '--targetname',
                $target,                        '--portal',
                $scfg->{'groupaddr'} . ':3260', '--rescan'
            ]
        );
    }
    else {
        # Discover portal for new targets
        run_command(
            [
                '/usr/bin/iscsiadm', '-m',
                'discovery',         '--type',
                'sendtargets',       '--portal',
                $scfg->{'groupaddr'} . ':3260'
            ]
        );

        # Login to target. Will produce an error if already logged in.
        run_command(
            [
                '/usr/bin/iscsiadm',            '-m',
                'node',                         '--targetname',
                $target,                        '--portal',
                $scfg->{'groupaddr'} . ':3260', '--login'
            ]
        );
    }

    sleep 1;

    # wait udev to settle divices
    run_command( [ '/usr/bin/udevadm', 'settle' ] );

}

sub iscsi_disable {
    my ( $class, $scfg, $cache, $name, $snapname ) = @_;

    my $target = '';
    if ($snapname) {
        $target = dell_get_lun_target( $scfg, $cache, $name, $snapname )
          || die "Cannot get iscsi tagret name";
        dell_set_offline( $scfg, $cache, $name, $snapname );
    }
    else {
        $target = dell_get_lun_target( $scfg, $cache, $name )
          || die "Cannot get iscsi tagret name";
    }

    # give some time for runned process to free device
    sleep 5;

    run_command(
        [
            '/usr/bin/iscsiadm',            '-m',
            'node',                         '--targetname',
            $target,                        '--portal',
            $scfg->{'groupaddr'} . ':3260', '--logout'
        ],
        noerr => 1
    );

    if ($snapname) {
        dell_set_offline( $scfg, $cache, $name, $snapname );
    }

    # wait udev to settle divices
    run_command( [ '/usr/bin/udevadm', 'settle' ] );
}

sub multipath_enable {
    my ( $class, $scfg, $cache, $name ) = @_;

    my $target = dell_get_lun_target( $scfg, $cache, $name )
      || die "Cannot get iscsi tagret name";

    # If device exists
    if (  -e "/dev/disk/by-id/dm-uuid-mpath-ip-"
        . $scfg->{'groupaddr'}
        . ":3260-iscsi-$target-lun-0" )
    {
        # Rescan target for changes (e.g. resize)
        run_command(
            [
                '/usr/bin/iscsiadm',            '-m',
                'node',                         '--targetname',
                $target,                        '--portal',
                $scfg->{'groupaddr'} . ':3260', '--rescan'
            ]
        );
    }
    else {
        # Discover portal for new targets
        run_command(
            [
                '/usr/bin/iscsiadm', '-m',
                'discovery',         '--type',
                'sendtargets',       '--portal',
                $scfg->{'groupaddr'} . ':3260'
            ]
        );

  # Login to target. Will produce warning if already logged in. But that's safe.
        run_command(
            [
                '/usr/bin/iscsiadm',            '-m',
                'node',                         '--targetname',
                $target,                        '--portal',
                $scfg->{'groupaddr'} . ':3260', '--login'
            ],
            noerr => 1
        );
    }

    sleep 1;

    # wait udev to settle divices
    run_command( [ '/usr/bin/udevadm', 'settle' ] );

    #force devmap reload to connect new device.
    run_command( [ '/usr/sbin/multipath', '-r' ] );
}

sub multipath_disable {
    my ( $class, $scfg, $cache, $name ) = @_;

    my $target = dell_get_lun_target( $scfg, $cache, $name )
      || die "Cannot get iscsi tagret name";

    # give some time for runned process to free device
    sleep 5;

    #disable selected target multipathing
    run_command(
        [
            '/sbin/multipath', '-f',
            'ip-' . $scfg->{'groupaddr'} . ":3260-iscsi-$target-lun-0"
        ]
    );

    # Logout from target
    run_command(
        [
            '/usr/bin/iscsiadm',            '-m',
            'node',                         '--targetname',
            $target,                        '--portal',
            $scfg->{'groupaddr'} . ':3260', '--logout'
        ]
    );

}

1;
