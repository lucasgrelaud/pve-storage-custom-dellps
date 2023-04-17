use strict;
use warnings;
use Module::Load;
use PVE::CLIHandler;

load './DellPSPlugin.pm';

print "Test script for DellPSPlugin\n";

PVE::CLIHandler::setup_environment();
print "CLI initialized\n";