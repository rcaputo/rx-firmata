package Firmata;

use warnings;
use strict;

use Moose;
extends 'Reflex::Base';

has handle => ( isa => 'FileHandle', is => 'rw' );

with 'Reflex::Role::Streaming' => { handle => 'handle' };

has buffer => ( isa => 'Str', is => 'rw', default => '' );

sub on_handle_data {
	my ($self, $args) = @_;

	my $data    = $args->{data};
	my $buffer  = $self->buffer() . $data;

	# TODO - Cheezy, slow.  Do better.

	while (1) {

		if ($buffer =~ s/^\xF9(..)//s) {
			my ($maj, $min) = unpack("CC", $1);
			print "<-- version $maj.$min\n";
			next;
		}

		# SysEx?  Ogods!

		if ($buffer =~ s/^\xF0\x79(..)(.*?)\xF7//s) {
			my ($maj, $min) = unpack("CC", $1);

			# TODO - See String SysEx discussion.
			my $string = $2;
			$string =~ tr[\x00][]d;
			print "<-- version $maj.$min ($string)\n";

			# Capabilities.
			$self->put_handle("\xF0\x6B\xF7");

			next;
		}

		# String SysEx.

		if ($buffer =~ s/^\xF0\x71(.*?)\xF7//s) {
			my $string = $1;

			# TODO - Actually the MSB of each string octet is in one of the
			# bytes.  We should convert these 16bit characters to 14bit
			# before displaying.  Ripping out the \x00s is just an expedient
			# hack.

			$string =~ tr[\x00][]d;
			print "<-- string: '$string'\n";
			next;
		}

		# Capability SysEx.

		if ($buffer =~ s/^\xF0\x6C(.*?)\xF7//s) {
			my $raw  = $1;
			my @pins = ($raw =~ m/([^\x7F]*)\x7F/g);

			my $pin = 0;
			foreach my $modes (@pins) {
				foreach my $mode ($modes =~ m/(..)/sg) {
					my ($m, $r) = unpack "CC", $mode;

					my $text = [
						qw(
							input
							output
							analog
							pwm
							servo
							shift
							i2c
						)
					]->[$m];

					print "<-- pin $pin can $text ($r)\n";
				}

				$pin++;
			}

			next;
		}

		# Unknown SysEx.

		if ($buffer =~ s/^\xF0(.)(.*?)\xF7//s) {
			my $cmd = ord($1);

			my $hex = $2;
			$hex =~ s/([^ -~])/sprintf("<%02.2x>", ord($1))/seg;

			printf "<-- sysex %02.2X '%s'\n", $cmd, $hex;
			next;
		}

		if ($buffer =~ s/^([\xE0-\xEF])(..)//s) {
			my $port = ord($1) & 0x0F;
			my ($lsb, $msb) = unpack "CC", $2;
			my $value = (($msb & 0x7F) << 7) | ($lsb & 0x7F);
			print "<-- a($port) = $value\n";
			next;
		}

		if ($buffer =~ s/^([\x90-\x9F])(..)//s) {
			my $port = ord($1) & 0x0F;
			my ($lsb, $msb) = unpack "CC", $2;
			my $value = (($msb & 0x7F) << 7) | ($lsb & 0x7F);
			print "<-- d($port) = $value\n";
			next;
		}

		if ($buffer =~ s/^([\xC0-\xCF])(..)//s) {
			my $port = ord($1) & 0x0F;
			my ($lsb, $msb) = unpack "CC", $2;
			my $value = $lsb & 0x01;
			print "<-- a($port) set $value\n";
			next;
		}

		if ($buffer =~ s/^([\xD0-\xDF])(..)//s) {
			my $port = ord($1) & 0x0F;
			my ($lsb, $msb) = unpack "CC", $2;
			my $value = $lsb & 0x01;
			print "<-- d($port) set $value\n";
			next;
		}

		last;
	}

	$self->buffer($buffer);

	if (length $buffer) {
		my $hex = $buffer;
		$hex =~ s/(.)/sprintf("<%02.2x>", ord($1))/seg;
		print "<-- raw: $hex\n";
	}
}

1;
