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

# Blink back and forth between digital pins 12 and 13.

my $pin = 0;
use Reflex::Interval;
my $blink = Reflex::Interval->new(
	interval => 1,
	auto_repeat => 1,
	on_tick => sub {
		$pin = !$pin || 0;
		$device->digital_set(1, 16 * ($pin + 1));
	},
);

while (defined( my $e = $device->next() )) {

	if ($e->_name() eq "version") {
		# Request capabilities.
		$device->put_handle("\xF0\x6B\xF7");
		next;
	}

	if ($e->_name() eq "capabilities") {
		#$device->analog_in( 1 );
		#$device->analog_report( 1, 1 );

		#$device->digital_report(0, 1);

		# Pins 12 and 13 are digital output.
		$device->digital_out(12);
		$device->digital_out(13);

		# Read digital input on pin 7.
		# Wire one of pins 12 or 13 to pin 7, and watch it register input
		# as that port lights up.

		$device->digital_in(7);
		$device->digital_report(0, 1 << 6);

		# Some silly sample rate.
		# It may only be for analog?
		$device->sample(100);

		next;
	}

	print $e->dump(), "\n";
}
