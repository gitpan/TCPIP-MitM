#!perl -T
use 5.006;
use strict;
use warnings FATAL => 'all';
use Test::More tests => 1;

BEGIN {
    use_ok( 'TCPIP::MitM' ) || print "Bail out!\n";
}

diag( "Testing TCPIP::MitM $TCPIP::MitM::VERSION, Perl $], $^X" );
