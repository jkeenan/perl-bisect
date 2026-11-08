package Perl5::Bisect::Auxiliary;
use strict;
use warnings;
use Data::Dump qw(dd pp);
our ( $VERSION, @ISA, @EXPORT_OK );
$VERSION = "0.01";
require Exporter;
@ISA         = qw(Exporter);
@EXPORT_OK = ( qw|
    croak_255
    die_255
    open_or_die
    close_or_die
    system_or_die
    run_with_options
    extract_from_file
    edit_file
|);

=head1 NAME

Perl5::Bisect::Auxiliary - Helper subroutines for Perl5::Bisect

=cut

# Ensure we always exit with 255, to cause git bisect to abort.
sub croak_255 {
    my $message = join '', @_;
    if ($message =~ /\n\z/) {
        print STDERR $message;
    } else {
        my (undef, $file, $line) = caller 1;
        print STDERR "@_ at $file line $line\n";
    }
    exit 255;
}

sub die_255 {
    croak_255(@_);
}

sub open_or_die {
    my $file = shift;
    my $mode = @_ ? shift : '<';
    open my $fh, $mode, $file or croak_255("Can't open $file: $!");
    ${*$fh{SCALAR}} = $file;
    return $fh;
}

sub close_or_die {
    my $fh = shift;
    return if close $fh;
    croak_255("Can't close: $!") unless ref $fh eq 'GLOB';
    croak_255("Can't close ${*$fh{SCALAR}}: $!");
}

sub system_or_die {
    my $command = '</dev/null ' . shift;
    system($command) and croak_255("'$command' failed, \$!=$!, \$?=$?");
}


sub run_with_options {
    my $options = shift;
    my $name = $options->{name};
    $name = "@_" unless defined $name;

    my $setgrp = $options->{setpgrp};
    if ($options->{timeout}) {
        # Unless you explicitly disabled it on the commandline, set it:
        $setgrp = 1 unless defined $setgrp;
    }
    my $pid = fork;
    die_255("Can't fork: $!") unless defined $pid;
    if (!$pid) {
        if (exists $options->{stdin}) {
            open STDIN, '<', $options->{stdin}
              or die "Can't open STDIN from $options->{stdin}: $!";
        }
        if ($setgrp) {
            setpgrp 0, 0
                or die "Can't setpgrp 0, 0: $!";
        }
        { exec @_ };
        die_255("Failed to start $name: $!");
    }
    my $start;
    if ($options->{timeout}) {
        require Errno;
        require POSIX;
        die_255("No POSIX::WNOHANG")
            unless &POSIX::WNOHANG;
        $start = time;
        $SIG{ALRM} = sub {
            my $victim = $setgrp ? -$pid : $pid;
            my $delay = 1;
            kill 'TERM', $victim;
            waitpid(-1, &POSIX::WNOHANG);
            while (kill 0, $victim) {
                sleep $delay;
                waitpid(-1, &POSIX::WNOHANG);
                $delay *= 2;
                if ($delay > 8) {
                    if (kill 'KILL', $victim) {
                        print STDERR "$0: Had to kill 'KILL', $victim\n"
                    } elsif (! $!{ESRCH}) {
                        print STDERR "$0: kill 'KILL', $victim failed: $!\n";
                    }
                    last;
                }
            }
            report_and_exit(0, 'No timeout', 'Timeout', "when running $name");
        };
        alarm $options->{timeout};
    }
    waitpid $pid, 0
      or die_255("wait for $name, pid $pid failed: $!");
    alarm 0;
    if ($options->{timeout}) {
        my $elapsed = time - $start;
        if ($elapsed / $options->{timeout} > 0.8) {
            print STDERR "$0: Beware, took $elapsed seconds of $options->{timeout} permitted to run $name\n";
        }
    }
    return $?;
}

sub extract_from_file {
    my ($file, $rx, $default) = @_;
    my $fh = open_or_die($file);
    while (<$fh>) {
	my @got = $_ =~ $rx;
	return wantarray ? @got : $got[0]
	    if @got;
    }
    return $default if defined $default;
    return;
}

sub edit_file {
    my ($file, $munger) = @_;
    my $fh = open_or_die($file);
    my $orig = do {
        local $/;
        <$fh>;
    };
    die_255("Can't read $file: $!") unless defined $orig && close $fh;
    my $new = $munger->($orig);
    return if $new eq $orig;
    $fh = open_or_die($file, '>');
    print $fh $new or die_255("Can't print to $file: $!");
    close_or_die($fh);
}

1;


