#!/usr/bin/env perl

use warnings;
use strict;

use Firmata;
use Device::SerialPort;
use Symbol qw(gensym);

my $handle = gensym();
my $port = tie(*$handle, "Device::SerialPort", "/dev/cu.usbmodem641") or die(
	"can't open port: $!"
);

$port->datatype("raw");
$port->baudrate(57600);
$port->databits(8);
$port->parity("none");
$port->stopbits(1);
$port->write_settings();

$|=1;

my $f = Firmata->new(handle => $handle);

#$f->put_handle("\x9C\x01\x00");

$f->run_all();
