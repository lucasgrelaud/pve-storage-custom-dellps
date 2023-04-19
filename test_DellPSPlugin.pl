use strict;
use warnings;
use Module::Load;
use Data::Dumper;

load './DellPSPlugin.pm';
use PVE::Storage::Custom::DellPSPlugin;

print "Test script for DellPSPlugin\n";

print "Configure plugin\n";
my $scfg = {
    login => "pve",
    password => "3lectroPV3",
    adminaddr => "172.16.50.42",
    groupaddr => "172.16.7.28",
    chaplogin => "pve-electrolab",
    #allowedaddr => "172.16.7.42 172.16.7.43",
    multipath => "0",
    pool => "default",
    content => "images",
    shared => "1",
};
print Dumper($scfg);

#################################
#                               #
#   Test primitives functions   #
#                               #
#################################
print "Initialize connection to the Dell PS\n";
my $cache;
$cache->{telnet} = PVE::Storage::Custom::DellPSPlugin::dell_connect($scfg);

print "Get Dell PS storage status\n";
my @status = @{PVE::Storage::Custom::DellPSPlugin::dell_status($scfg, $cache)};

print "Status:\n";
printf("\t- Total space: %d GB\n", int($status[0]) / PVE::Storage::Custom::DellPSPlugin::getmultiplier('GB'));
printf("\t- Free space: %d GB\n", int($status[1]) / PVE::Storage::Custom::DellPSPlugin::getmultiplier('GB'));
printf("\t- Used space: %d GB\n", int($status[2]) / PVE::Storage::Custom::DellPSPlugin::getmultiplier('GB'));
printf("\t- Active : %s\n", $status[3]);

print "Create the Volume (LUN) : vm-20-disk-1\n";
#PVE::Storage::Custom::DellPSPlugin::dell_create_lun($scfg, $cache, 'vm-20-disk-1', '1GB');

print "Allow PVE nodes to access Volumes (LUN)\n";
PVE::Storage::Custom::DellPSPlugin::dell_configure_lun($scfg, $cache, 'vm-20-disk-1');