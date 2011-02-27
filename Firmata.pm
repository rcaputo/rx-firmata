package Firmata;

use warnings;
use strict;

use Moose;
extends 'Reflex::Base';

use Carp qw(croak);

has handle => ( isa => 'FileHandle', is => 'rw' );

with 'Reflex::Role::Streaming' => { handle => 'handle' };

has buffer => ( isa => 'Str', is => 'rw', default => '' );

sub on_handle_data {
	my ($self, $args) = @_;

	my $data = $args->{data};
	print "<-- raw: ", $self->hexify($data), "\n";

	my $buffer = $self->buffer() . $data;

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

			my $string = $self->firmata_string_parse($2);
			print "<-- version $maj.$min ($string)\n";

			# Capabilities.
			$self->put_handle("\xF0\x6B\xF7");

			next;
		}

		# String SysEx.

		if ($buffer =~ s/^\xF0\x71(.*?)\xF7//s) {
			my $string = $self->firmata_string_parse($1);
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
			printf "<-- sysex %02.2X '%s'\n", $cmd, $self->hexify($2);
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
}

sub firmata_string_parse {
	my ($self, $raw_string) = @_;

	croak "string contains an odd number of octets" if length($raw_string) % 2;

	# Some things are better left to C, eh?
	my $cooked_string = "";
	my (@raw_octets) = ($raw_string =~ /(.)/sg);
	while (@raw_octets) {
		my ($lsb, $msb) = splice @raw_octets, 0, 2;
		$cooked_string .= chr( ((ord($msb) & 0x7f) << 7) | (ord($lsb) & 0x7F) );
	}

	return $cooked_string;
}

sub hexify {
	my ($self, $data) = @_;

	$data =~ s/(.)/sprintf("<%02.2x>", ord($1))/seg;
	$data =~ s/(<[89a-fA-F][0-9a-fA-F]>)/\e[1m$1\e[0m/g;

	return $data;
}

1;
