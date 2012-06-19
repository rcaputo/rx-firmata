package Firmata;

use Moose;
extends 'Reflex::Base';
use Reflex::Trait::EmitsOnChange qw(emits);
use Reflex::Callbacks qw(make_emitter make_terminal_emitter);

use Carp qw(croak);

# TODO - This would rock more as a role.

has handle => ( isa => 'FileHandle', is => 'rw' );
has active => ( is => 'ro', isa => 'Bool', default => 1 );

with 'Reflex::Role::Streaming' => {
	att_handle => 'handle',
	att_active => 'active',
	cb_error    => make_emitter(on_error => "error"),
	cb_closed   => make_terminal_emitter(on_closed => "closed"),
};

has init_wait => ( isa => 'Num', is => 'rw', default => 10 );
has init_wait_autostart => ( isa => 'Bool', is => 'ro', default => 0 );
with 'Reflex::Role::Timeout' => {
	att_delay      => 'init_wait',
	att_auto_start => 'init_wait_autostart',
};

has buffer => ( isa => 'Str', is => 'rw', default => '' );

# Whee.
emits protocol_version => ( is => 'rw', isa => 'Num' );
emits protocol_string  => ( is => 'rw', isa => 'Str' );

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

sub on_handle_error {
	my ($self, $arg) = @_;
	use YAML;
	warn YAML::Dump($arg);
}

before put_handle => sub {
	my ($self, $message) = @_;
	print "--> ", $self->hexify($message), "\n";
};

sub analog_report {
	my ($self, $port, $bool) = @_;
	my $message = chr(0xC0 | ($port & 0x0F)) . chr((!!$bool) || 0);
	$self->put_handle($message);
}

# XXX - digital_report() works on ATMEGA ports, not discrete pins.
# TODO - If we want a pin API, we need to remember which pins we're
# polling, manipulate them as bits, and write the resulting bytes.

sub digital_report {
	my ($self, $port, $bool) = @_;
	my $message = chr(0xD0 | ($port & 0x0F)) . chr($bool & 0x7F);
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
	my ($self, $port, $value) = @_;

	my $message = (
		chr( 0x90 | ($port & 0x0F) ) .
		chr($value & 0x7F) .
		chr(($value >> 7) & 0x7F)
	);

	$self->put_handle($message);
}

sub on_handle_data {
	my ($self, $args) = @_;

	my $buffer = $self->buffer() . ($args->octets());

	# TODO - Cheezy, slow.  Do better.

	while (length $buffer) {

		# Discard leading non-command data.
		# This can occur on a framing error.
		next if $buffer =~ s/^[\x00-\x7f]//;

		# Protocol version.

		if ($buffer =~ s/^\xF9(..)//s) {
			my ($maj, $min) = unpack("CC", $1);
			my $new_version = "$maj.$min";

			my $old_version = $self->protocol_version();
			if (defined $old_version) {
				next if $old_version == $new_version;
				warn "Version changed from $old_version to $new_version";
			}

			$self->protocol_version($new_version);
			next;
		}

		# SysEx?  Ogods!

		if ($buffer =~ s/^\xF0\x79(..)(.*?)\xF7//s) {
			my ($maj, $min) = unpack("CC", $1);
			my $new_string = $self->firmata_string_parse($2);

			my $new_version = "$maj.$min";

			my $old_version = $self->protocol_version();
			if (defined $old_version) {
				unless ($old_version == $new_version) {
					warn "Version changed from $old_version to $new_version";
					$self->protocol_version($new_version);
				}
			}
			else {
				# This one's silent.
				$self->protocol_version($new_version);
			}

			my $old_string = $self->protocol_string();
			if (defined $old_string) {
				unless ($old_string eq $new_string) {
					warn "Version string changed from '$old_string' to '$new_string'";
					$self->protocol_string($new_string);
				}
			}
			else {
				# This one's silent.
				$self->protocol_string($new_string);
			}

			next;
		}

		# String SysEx.

		if ($buffer =~ s/^\xF0\x71(.*?)\xF7//s) {
			my $string = $self->firmata_string_parse($1);
if (0) {
			$self->emit(
				event => "string",
				args => {
					string => $string,
				},
			);
}
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
				event => "initialized",
				args  => { }, # TODO - What?!
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
if (0) {
			$self->emit(
				event => "analog",
				args  => {
					pin   => $port,
					value => $value,
				},
			);
}
			next;
		}

		if ($buffer =~ s/^([\x90-\x9F])(..)//s) {
			my $port = ord($1) & 0x0F;
			my ($lsb, $msb) = unpack "CC", $2;
			my $value = (($msb & 0x7F) << 7) | ($lsb & 0x7F);
if (0) {
			$self->emit(
				event => "digital",
				args  => {
					pin   => $port,
					value => $value,
				},
			);
}
			next;
		}

		# TODO - These are Firmata commands.  Stuff we send to the device.
		# TODO - We could handle these if we wanted to emulate a device.
#    if ($buffer =~ s/^([\xC0-\xCF])(..)//s) {
#      my $port = ord($1) & 0x0F;
#      my ($lsb, $msb) = unpack "CC", $2;
#      my $value = $lsb & 0x01;
#      print "<-- a($port) set $value\n";
#      next;
#    }
#
#    if ($buffer =~ s/^([\xD0-\xDF])(..)//s) {
#      my $port = ord($1) & 0x0F;
#      my ($lsb, $msb) = unpack "CC", $2;
#      my $value = $lsb & 0x01;
#      print "<-- d($port) set $value\n";
#      next;
#    }

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

sub on_init_wait_done {
	my ($self, $timeout) = @_;
	$self->put_handle("\xFF");
	$self->emit(event => "has_reset");
}

sub initialize_from_device {
	my $self = shift;

	ATTEMPT: while (1) {
warn "attempt";

		# Wait for a protocol string.
		$self->start_init_wait();
		my $e = $self->next('protocol_string', 'has_reset');
		next ATTEMPT if $e->{name} eq 'has_reset';
		$self->stop_init_wait();

		# Request capabilities.
		$self->put_handle("\xF0\x6B\xF7");

		# Wait for initialization.
		$self->start_init_wait();
		$self->next('initialized', 'has_reset');
		next ATTEMPT if $e->{name} eq 'has_reset';
		$self->stop_init_wait();

		last ATTEMPT;
	}

	$self->stop_init_wait();
}

1;
