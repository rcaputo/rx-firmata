#!/usr/bin/env perl

use warnings;
use strict;

use Firmata;
use Device::SerialPort;
use Symbol qw(gensym);

opendir(D, "/dev") or die $!;
my @modems = grep /^cu.usbmodem/, readdir(D);
closedir(D);

die "Can't find a modem in /dev ...\n" if @modems < 1;
die "Found too many modems in /dev: @modems\n" if @modems > 1;

my $handle = gensym();
my $port = tie(*$handle, "Device::SerialPort", "/dev/$modems[0]") or die(
	"can't open port: $!"
);

$port->datatype("raw");
$port->baudrate(57600);
$port->databits(8);
$port->parity("none");
$port->stopbits(1);
$port->write_settings();

$|=1;

my $device = Firmata->new(handle => $handle);

while (defined( my $e = $device->next() )) {

	if ($e->{name} eq "version") {
		# Request capabilities.
		$device->put_handle("\xF0\x6B\xF7");
		next;
	}

	if ($e->{name} eq "capabilities") {
		$device->analog_in( 1 );
		$device->analog_report( 1, 1 );
		$device->sample(100);
		next;
	}

	print "--- $e->{name}\n";
	foreach my $key (sort keys %{$e->{arg}}) {
		next if $key eq "_sender";
		print "$key: $e->{arg}{$key}\n";
	}
}
