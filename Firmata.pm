package Firmata;

use Moose;
extends 'Reflex::Base';
use Reflex::Trait::EmitsOnChange qw(emits);

use Carp qw(croak);

# TODO - This would rock more as a role.

has handle => ( isa => 'FileHandle', is => 'rw' );

with 'Reflex::Role::Streaming' => { handle => 'handle' };

has buffer => ( isa => 'Str', is => 'rw', default => '' );

# Whee.
emits protocol_version => ( is => 'rw', isa => 'Num', default => 0 );

{
	package Firmata::Pin;
	use Moose;

	has id => ( is => 'ro', isa => 'Int' );
	has mode => ( is => 'rw', isa => 'Int' );
	has capabilities => ( is => 'rw', isa => 'ArrayRef[Int]' );
}

has pins => (
	is => 'rw',
	isa => 'ArrayRef[Maybe[Firmata::Pin]]',
	default => sub { [] },
);

before put_handle => sub {
	my ($self, $message) = @_;
	print "--> ", $self->hexify($message), "\n";
};

sub analog_report {
	my ($self, $port, $bool) = @_;
	my $message = chr(0xC0 | ($port & 0x0F)) . chr((!!$bool) || 0);
	$self->put_handle($message);
}

# TODO - Digital Report isn't supported by the UNO Firmata 2.2 driver.
# See the TODO in FirmataClass::sendDigital(byte pin, int value).

sub digital_report {
	my ($self, $port, $bool) = @_;
	my $message = chr(0xD0 | ($port & 0x0F)) . chr((!!$bool) || 0);
	$self->put_handle($message);
}


### Set Pin Mode

sub digital_in {
	my ($self, $pin) = @_;
	my $message = "\xF4" . chr($pin & 0x7F) . "\x00";
	$self->put_handle($message);
}

sub digital_out {
	my ($self, $pin) = @_;
	my $message = "\xF4" . chr($pin & 0x7F) . "\x01";
	$self->put_handle($message);
}

sub analog_in {
	my ($self, $pin) = @_;
	my $message = "\xF4" . chr($pin & 0x7F) . "\x02";
	$self->put_handle($message);
}

sub pwm_out {
	my ($self, $pin) = @_;
	my $message = "\xF4" . chr($pin & 0x7F) . "\x03";
	$self->put_handle($message);
}

sub servo_out {
	my ($self, $pin) = @_;
	my $message = "\xF4" . chr($pin & 0x7F) . "\x04";
	$self->put_handle($message);
}

### Sampling Interval

sub sample {
	my ($self, $interval) = @_;
	my $message = (
		"\xF0\x7A" .
		chr($interval & 0x7F) . chr( ($interval >> 7) & 0x7F) .
		"\xF7"
	);

	$self->put_handle($message);
}



sub digital_set {
	my ($self, $pin, $value) = @_;
	my $message = chr( 0x90 | ($pin & 0x0F) ) . ($value ? "\x7F\x7F" : "\x00\x00");
	$self->put_handle($message);
}

sub on_handle_data {
	my ($self, $args) = @_;

	my $buffer = $self->buffer() . $args->{data};

	# TODO - Cheezy, slow.  Do better.

	while (length $buffer) {

		# Discard leading non-command data.
		# This can occur on a framing error.
		next if $buffer =~ s/^[\x00-\x7f]//;

		# Protocol version.

		if ($buffer =~ s/^\xF9(..)//s) {
			my ($maj, $min) = unpack("CC", $1);
			$self->protocol_version("$maj.$min");
			next;
		}

		# SysEx?  Ogods!

		if ($buffer =~ s/^\xF0\x79(..)(.*?)\xF7//s) {
			my ($maj, $min) = unpack("CC", $1);

			my $string = $self->firmata_string_parse($2);
			$self->emit(
				event => "version",
				args => {
					version => "$maj.$min",
					firmware => $string,
				},
			);

			next;
		}

		# String SysEx.

		if ($buffer =~ s/^\xF0\x71(.*?)\xF7//s) {
			my $string = $self->firmata_string_parse($1);
			$self->emit(
				event => "string",
				args => {
					string => $string,
				},
			);
			next;
		}

		# Capability SysEx.

		if ($buffer =~ s/^\xF0\x6C(.*?)\xF7//s) {
			my $raw  = $1;
			my @pins = ($raw =~ m/([^\x7F]*)\x7F/g);

			my @new_pins;

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

					$new_pins[$pin] = Firmata::Pin->new(
						id           => $pin,
						mode         => 0,
						capabilities => [ ],
					);
				}

				$pin++;
			}

			$self->pins(\@new_pins);

			# TODO - It would be awesome to make the pins attribute-based
			# with emits/observes traits and all.  Problem is, we need to
			# build those attributes at runtime after the object has been
			# running for a little while.
			$self->emit(
				event => "capabilities",
				args  => { }, # TODO
			);

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

			$self->emit(
				event => "analog",
				args  => {
					pin   => $port,
					value => $value,
				},
			);
			next;
		}

		if ($buffer =~ s/^([\x90-\x9F])(..)//s) {
			my $port = ord($1) & 0x0F;
			my ($lsb, $msb) = unpack "CC", $2;
			my $value = (($msb & 0x7F) << 7) | ($lsb & 0x7F);

			$self->emit(
				event => "digital",
				args  => {
					pin   => $port,
					value => $value,
				},
			);
			next;
		}

		# TODO - These are Firmata commands.  Stuff we send to the device.
		# TODO - We could handle these if we wanted to emulate a device.
#		if ($buffer =~ s/^([\xC0-\xCF])(..)//s) {
#			my $port = ord($1) & 0x0F;
#			my ($lsb, $msb) = unpack "CC", $2;
#			my $value = $lsb & 0x01;
#			print "<-- a($port) set $value\n";
#			next;
#		}
#
#		if ($buffer =~ s/^([\xD0-\xDF])(..)//s) {
#			my $port = ord($1) & 0x0F;
#			my ($lsb, $msb) = unpack "CC", $2;
#			my $value = $lsb & 0x01;
#			print "<-- d($port) set $value\n";
#			next;
#		}

		last;
	}

	#print "<-- raw: ", $self->hexify($buffer), "\n" if length $buffer;
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
