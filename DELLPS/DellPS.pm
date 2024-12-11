package DELLPS::DellPS;

use strict;
use warnings;

use Net::Telnet;
use Data::Dumper;

use PVE::Tools      qw(run_command);
use PVE::JSONSchema qw(get_standard_option);

use DELLPS::PluginHelper qw(getmultiplier);

sub new {
    my ( $class, $args ) = @_;
    my $self = bless {
        cli             => $args->{cli},
        pool            => $args->{pool},
        allowed_address => $args->{allowed_address},
        group_address   => $args->{group_address},
        chap_login      => $args->{chap_login},
        multipath       => $args->{multipath},
    }, $class;

}

DESTROY {
    my $self = shift;

    # Close the cli session when object is destroyed
    $self->{cli}->close();
}

sub validate_config {
    my ($scfg) = @_;

    # Validate mutipath config
    my $multipath_service_state = run_command(
"systemctl list-units --all --state=active --type=service | grep multipath",
        noerr => 1,
        quiet => 1
    );
    $multipath_service_state =
      $multipath_service_state == 0
      ? 1
      : 0;    # Grep retcode equal 0 if result found
    if ( "$multipath_service_state" ne $scfg->{multipath} ) {
        print
          "Mismatch between plugin config and service state for multipath.\n";
        print "Plugin config : ", $scfg->{multipath},       "\n";
        print "Service state : ", $multipath_service_state, "\n";

        return 0;
    }

    # Add check for autologin
    return 1;
}

sub dell_connect {
    my ($scfg) = @_;

    # Validate config before openning a connection
    my $isValid = validate_config($scfg);
    if ( !$isValid ) {
        die "dell_connect: Validation of the configuration failed.\n";
    }

    # Configure Telnet client
    my $obj = new Net::Telnet(
        Host => $scfg->{management_address},

        # Uncomment to activate logs (debug only)
        #Input_log  => "/tmp/dell.log",
        #Output_log => "/tmp/dell.log",
    );

    # Initialize session with credentials
    $obj->login( $scfg->{login}, $scfg->{password} );

    # Configure Dell PS cli for this telnet sessions
    $obj->cmd('cli-settings events off');
    $obj->cmd('cli-settings formatoutput off');
    $obj->cmd('cli-settings confirmation off');
    $obj->cmd('cli-settings displayinMB on');
    $obj->cmd('cli-settings idlelogout off');
    $obj->cmd('cli-settings paging off');
    $obj->cmd('cli-settings reprintBadInput off');
    $obj->cmd('stty hardwrap off');
    $obj->cmd('stty columns 255');
    $obj->cmd('stty columns 10');

    # Return telnet session
    return $obj;
}

sub get_status {
    my $self = shift;

    my @out = $self->{cli}->cmd('show pool');
    for my $line (@out) {
        next
          unless ( $line =~
            m/(\w+)\s+\w+\s+\d+\s+\d+\s+([\d\.]+)([MGT]B)\s+([\d\.]+)([MGT]B)/
          );
        next unless ( $1 eq $self->{pool} );

        my $total = int( $2 * getmultiplier($3) );
        my $free  = int( $4 * getmultiplier($5) );
        my $used  = $total - $free;
        return [ $total, $free, $used, 1 ];
    }
}

sub list_luns {
    my $self = shift;

    # Execute the command
    my @out = $self->{cli}->cmd('volume show');

    # Process the results
    my $res              = {};
    my $volname          = '';
    my $size             = '';
    my $snapshot_count   = 0;
    my $status           = '';
    my $permissions      = 0;
    my $connection_count = '';
    my $thinprovisioned  = '';

    for my $line (@out) {

        # Match and get volume info from current line (might be multiline)
        if ( $line =~
/^((?:vm|base)\S*)\s+(\w+)\s+([\d\.]+)\s+(\w+)\s+(\S+)\s+([\d\.]+)\s+(\w+)/
          )
        {
            # Store previously processed info and clear variables
            if ( $volname ne '' ) {
                my $adjusted_size = 0;
                if ( $size =~ /^(\d+)(\w+)/ ) {
                    $adjusted_size = $1 * getmultiplier($2);
                }
                else {
                    die "Could not get size of volume";
                }

                $res->{$volname} = {
                    size             => $adjusted_size,
                    snapshot_count   => $snapshot_count,
                    status           => $status,
                    permissions      => $permissions,
                    connection_count => $connection_count,
                    thinprovisioned  => $thinprovisioned
                };

                $volname          = '';
                $size             = '';
                $snapshot_count   = '';
                $status           = '';
                $permissions      = '';
                $connection_count = '';
                $thinprovisioned  = '';
            }

            # Buffer gathered volume info
            $volname          = $1;
            $size             = $2;
            $snapshot_count   = int($3);
            $status           = $4;
            $permissions      = $5;
            $connection_count = int($6);
            $thinprovisioned  = $7;
        }
        elsif ( $line =~ /^\s{2}(\S+)\s/ ) {

            # In case of a multiline volume name, append th next part
            $volname = $volname . $1;
        }
        elsif ( $line =~ /^(?:\w*)/ ) {
            if ( $volname ne '' ) {

         # Store previously processed info and clear variables on command return
                my $adjusted_size = 0;
                if ( $size =~ /^(\d+)(\w+)/ ) {
                    $adjusted_size = $1 * getmultiplier($2);
                }
                else {
                    die "Could not get size of volume";
                }

                $res->{$volname} = {
                    size             => $adjusted_size,
                    snapshot_count   => $snapshot_count,
                    status           => $status,
                    permissions      => $permissions,
                    connection_count => $connection_count,
                    thinprovisioned  => $thinprovisioned
                };

                $volname          = '';
                $size             = '';
                $snapshot_count   = '';
                $status           = '';
                $permissions      = '';
                $connection_count = '';
                $thinprovisioned  = '';
            }
        }
    }
    return $res;
}

sub get_lun_target {
    my ( $self, $name, $snapname ) = @_;

    if ($snapname) {
        my @out = $self->{cli}->cmd(
            sprintf(
                "volume select %s snapshot select %s show ",
                $name, $snapname
            )
        );
        for my $line (@out) {
            next unless $line =~ m/^iSCSI Name: (.+)$/;
            return $1;
        }
    }
    else {
        my @out =
          $self->{cli}->cmd( sprintf( "volume select %s show", $name ) );
        for my $line (@out) {
            next unless $line =~ m/^iSCSI Name: (.+)$/;
            return $1;
        }
    }
    return 0;
}

sub create_lun {
    my ( $self, $name, $size ) = @_;

    my @out = $self->{cli}->cmd(
        sprintf(
            'volume create %s %s pool %s thin-provision',
            $name, $size, $self->{pool}
        )
    );

    for my $line (@out) {
        if ( $line =~ m/^% Error - (.+)$/ ) {
            die "LUN creation error : " . $1 . "\n";
        }
    }
}

sub configure_lun {
    my ( $self, $name ) = @_;
    my @out;

    if (
        (
            !defined( $self->{allowed_address} )
            || $self->{allowed_address} eq ''
        )
        && ( !defined( $self->{chap_login} ) || $self->{chap_login} eq '' )
      )
    {
        # No allowed_address nor chap_login => unrestricted-access.
        @out = $self->{cli}->cmd(
            sprintf(
"volume select %s access create ipaddress *.*.*.* authmethod none",
                $name )
        );
        for my $line (@out) {
            if ( $line =~ m/^% Error - (.+)$/ ) {
                die "LUN configuration error : " . $1 . "\n";
            }
        }
    }
    elsif (( !defined( $self->{allowed_address} ) || $self->{allowed_address} eq '' )
        && ( defined( $self->{chap_login} ) && $self->{chap_login} ne '' ) )
    {
        # Only a chap_login given => access through auth on any ip
        @out = $self->{cli}->cmd(
            sprintf(
"volume select %s access create ipaddress *.*.*.* username %s authmethod chap",
                $name, $self->{chap_login}
            )
        );
        for my $line (@out) {
            if ( $line =~ m/^% Error - (.+)$/ ) {
                die "LUN configuration error : " . $1 . "\n";
            }
        }

    }
    elsif ( ( defined( $self->{allowed_address} ) && $self->{allowed_address} ne '' ) )
    {
        my $usernamestr = '';
        if ( defined( $self->{chap_login} ) && $self->{chap_login} ne '' ) {
            $usernamestr =
              "username " . $self->{chap_login} . " authmethod chap ";
        }

        my @allowed_address = split( ' ', $self->{allowed_address} );
        foreach my $addr (@allowed_address) {
            @out = $self->{cli}->cmd(
                sprintf(
                    "volume select %s access create ipaddress %s %s",
                    $name, $addr, $usernamestr
                )
            );
            for my $line (@out) {
                if ( $line =~ m/^% Error - (.+)$/ ) {
                    die "LUN configuration error : " . $1 . "\n";
                }
            }
        }
    }

    # PVE itself manages access to LUNs, so that's OK.
    @out =
      $self->{cli}
      ->cmd( sprintf( "volume select %s multihost-access enable", $name ) );
    for my $line (@out) {
        if ( $line =~ m/^% Error - (.+)$/ ) {
            die "LUN configuration error : " . $1 . "\n";
        }
    }
}

sub delete_lun {
    my ( $self, $name ) = @_;

    # Snapshot must be offline in order to be deleted
    my @lines =
      $self->{cli}->cmd( sprintf( "volume select %s offline", $name ) );
    if ( $#lines > 1 ) {
        die 'Cannot set volume offline!';
        return 0;
    }
    else {
        # Delete the volume
        @lines = $self->{cli}->cmd( sprintf( "volume delete %s", $name ) );
        if ( $#lines > 1 ) {
            die 'Cannot set lun offline';
            return 0;
        }
    }

    return 1;
}

sub resize_lun {
    my ( $self, $name, $size ) = @_;

    my @out =
      $self->{cli}
      ->cmd( sprintf( "volume select %s size %s no-snap", $name, $size ) );
    for my $line (@out) {
        if ( $line =~ m/^% Error - (.+)$/ ) {
            die "LUN creation error : " . $1 . "\n";
        }
    }
}

sub rename_lun {
    my ( $self, $name, $newname ) = @_;

    my @lines =
      $self->{cli}
      ->cmd( sprintf( "volume select %s iscsi-alias %s", $name, $newname ) );
    for my $line (@lines) {
        if ( $line =~ m/^% Error - (.+)$/ ) {
            die "LUN rename error : " . $1 . "\n";
        }
    }
    return 1;
}

sub set_online {
    my ( $self, $name, $snapname ) = @_;

    if ($snapname) {
        my @lines = $self->{cli}->cmd(
            sprintf(
                "volume select %s snapshot select %s online",
                $name, $snapname
            )
        );
        for my $line (@lines) {
            if ( $line =~ m/^% Error - (.+)$/ ) {
                die "LUN set snapshot online error : " . $1 . "\n";
            }
        }
    }
    else {
        my @lines =
          $self->{cli}
          ->cmd( sprintf( "volume select %s online", $name, $snapname ) );
        for my $line (@lines) {
            if ( $line =~ m/^% Error - (.+)$/ ) {
                die "LUN set online error : " . $1 . "\n";
            }
        }
    }
    return 1;
}

sub set_offline {
    my ( $self, $name, $snapname ) = @_;

    if ($snapname) {
        my @lines = $self->{cli}->cmd(
            sprintf(
                "volume select %s snapshot select %s offline",
                $name, $snapname
            )
        );
        for my $line (@lines) {
            if ( $line =~ m/^% Error - (.+)$/ ) {
                die "LUN set snapshot offline error : " . $1 . "\n";
            }
        }
    }
    else {
        my @lines =
          $self->{cli}
          ->cmd( sprintf( "volume select %s offnline", $name, $snapname ) );

        for my $line (@lines) {
            if ( $line =~ m/^% Error - (.+)$/ ) {
                die "LUN set offline error : " . $1 . "\n";
            }
        }
    }
    return 1;
}

sub snapshot_exist {
    my ( $self, $name, $snapname ) = @_;

    # Create a snapshot
    my @out =
      $self->{cli}->cmd(
        sprintf( "volume select %s snapshot select %s show", $name, $snapname )
      );

    for my $line (@out) {
        if ( $line =~ m/does not exist/ ) {
            return 0;
        }
        elsif ( $line =~ m/^% Error - (.+)$/ ) {
            die "Snapshot exist error : " . $1 . "\n";
        }
    }
    return 1;
}

sub create_snapshot {
    my ( $self, $name, $snapname ) = @_;

    # Create a snapshot
    my @lines = $self->{cli}->cmd(
        sprintf(
            "volume select %s snapshot create-now description %s",
            $name, $snapname
        )
    );

    if ( !( $lines[0] =~ m/succeeded/ ) ) {
        for my $line (@lines) {
            if ( $line =~ m/^% Error - (.+)$/ ) {

                die "Snapshot creation error : " . $1 . "\n";
            }
        }
    }
    else {
        # Rename the created snapshot to a predefined name
        my @lineparts = split( ' ', $lines[1] );
        my @out       = $self->{cli}->cmd(
            sprintf(
                "volume select %s snapshot rename '%s' '%s'",
                $name, $lineparts[3], $snapname
            )
        );
        for my $line (@out) {
            if ( $line =~ m/^% Error - (.+)$/ ) {
                die "Snapshot renaming error : " . $1 . "\n";
            }
        }
    }

    return 1;
}

sub delete_snapshot {
    my ( $self, $name, $snapname ) = @_;

    # Snapshot must be offline in order to be deleted
    my @lines = $self->{cli}->cmd(
        sprintf(
            "volume select %s snapshot select '%s' offline",
            $name, $snapname
        )
    );
    if ( $#lines > 1 ) {
        die 'Cannot set snapshot offline for volume!';
        return 0;
    }
    else {
        # Delete the snapshot
        @lines = $self->{cli}->cmd(
            sprintf(
                "volume select %s snapshot delete '%s'", $name, $snapname
            )
        );
        if ( $#lines > 1 ) {
            die 'Cannot set snapshot offline for volume!';
            return 0;
        }
    }
    return 1;
}

sub clone_lun {
    my ( $self, $name, $newname, $snapname ) = @_;

    if ($snapname) {

        # Clone the snapshot to a new lun one
        my @lines = $self->{cli}->cmd(
            sprintf(
                "volume select %s snapshot select %s clone %s",
                $name, $snapname, $newname
            )
        );
        if ( $#lines > 1 ) {
            die 'Cannot clone volume !';
            return 0;
        }
    }
    else {
        # Clone the lun to a new one
        my @lines =
          $self->{cli}
          ->cmd( sprintf( "volume select %s clone %s", $name, $newname ) );
        if ( $#lines > 1 ) {
            die 'Cannot clone volume !';
            return 0;
        }
    }
    return 1;

}

sub rollback_snapshot {
    my ( $self, $name, $snapname ) = @_;

    # Volume and snapshot must be offline to perform a rollback
    $self->{cli}->cmd( sprintf( "volume select %s offline", $name ) );

    # Perform the rollback
    my @lines = $self->{cli}->cmd(
        sprintf(
            "volume select %s snapshot select %s restore",
            $name, $snapname
        )
    );
    if ( $#lines > 1 ) {
        die 'Cannot rollback snapshot for volume!';
        die 'Volume kept offline,  reactivate manually!';
        return 0;
    }

    sleep 5;

    # Remove geneated snapshot post rollback
    my $snaptoremove = '';
    my @partial;
    @lines =
      $self->{cli}->cmd( sprintf( "volume select %s snapshot show", $name ) );
    for my $line (@lines) {

        # The snapshot name is lis
        if ( $line =~ /^(vm-(\d+)-disk-\d+)/ ) {
            @partial      = split( ' ', $line );
            $snaptoremove = $partial[0];
        }
        elsif ( $snaptoremove ne '' && $line =~ /^\s{2}(\d\d)?:(\d\d:)/ ) {
            @partial      = split( ' ', $line );
            $snaptoremove = $snaptoremove . $partial[0];
            $self->delete_snapshot( $name, $snaptoremove );
            $snaptoremove = '';
        }
    }

    # Reset volume online
    $self->{cli}->cmd( sprintf( "volume select %s online", $name ) );
    return 1;

}

1;
