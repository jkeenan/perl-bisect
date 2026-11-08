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
    process_hunk
    ud2cd
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

sub process_hunk {
    my ($from_out, $to_out, $has_from, $has_to, $delete, $add) = @_;
    ++$$has_from if $delete;
    ++$$has_to if $add;

    if ($delete && $add) {
        $$from_out .= "! $_\n" foreach @$delete;
        $$to_out .= "! $_\n" foreach @$add;
    } elsif ($delete) {
        $$from_out .= "- $_\n" foreach @$delete;
    } elsif ($add) {
         $$to_out .= "+ $_\n" foreach @$add;
    }
}

# This isn't quite general purpose, as it can't cope with
# '\ No newline at end of file'
sub ud2cd {
    my $diff_in = shift;
    my $diff_out = '';

    # Stuff before the diff
    while ($diff_in =~ s/\A(?!\*\*\* )(?!--- )([^\n]*\n?)//ms && length $1) {
        $diff_out .= $1;
    }

    if (!length $diff_in) {
        die_255("That didn't seem to be a diff");
    }

    if ($diff_in =~ /\A\*\*\* /ms) {
        warn "Seems to be a context diff already\n";
        return $diff_out . $diff_in;
    }

    # Loop for files
 FILE: while (1) {
        if ($diff_in =~ s/\A((?:diff |index )[^\n]+\n)//ms) {
            $diff_out .= $1;
            next;
        }
        if ($diff_in !~ /\A--- /ms) {
            # Stuff after the diff;
            return $diff_out . $diff_in;
        }
        $diff_in =~ s/\A([^\n]+\n?)//ms;
        my $line = $1;
        die_255("Can't parse '$line'") unless $line =~ s/\A--- /*** /ms;
        $diff_out .= $line;
        $diff_in =~ s/\A([^\n]+\n?)//ms;
        $line = $1;
        die_255("Can't parse '$line'") unless $line =~ s/\A\+\+\+ /--- /ms;
        $diff_out .= $line;

        # Loop for hunks
        while (1) {
            next FILE
                unless $diff_in =~ s/\A\@\@ (-([0-9]+),([0-9]+) \+([0-9]+),([0-9]+)) \@\@[^\n]*\n?//;
            my ($hunk, $from_start, $from_count, $to_start, $to_count)
                = ($1, $2, $3, $4, $5);
            my $from_end = $from_start + $from_count - 1;
            my $to_end = $to_start + $to_count - 1;
            my ($from_out, $to_out, $has_from, $has_to, $add, $delete);
            while (length $diff_in && ($from_count || $to_count)) {
                die_255("Confused in $hunk")
                    unless $diff_in =~ s/\A([^\n]*)\n//ms;
                my $line = $1;
                $line = ' ' unless length $line;
                if ($line =~ /^ .*/) {
                    process_hunk(\$from_out, \$to_out, \$has_from, \$has_to,
                                 $delete, $add);
                    undef $delete;
                    undef $add;
                    $from_out .= " $line\n";
                    $to_out .= " $line\n";
                    --$from_count;
                    --$to_count;
                } elsif ($line =~ /^-(.*)/) {
                    push @$delete, $1;
                    --$from_count;
                } elsif ($line =~ /^\+(.*)/) {
                    push @$add, $1;
                    --$to_count;
                } else {
                    die_255("Can't parse '$line' as part of hunk $hunk");
                }
            }
            process_hunk(\$from_out, \$to_out, \$has_from, \$has_to,
                         $delete, $add);
            die_255("No lines in hunk $hunk")
                unless length $from_out || length $to_out;
            die_255("No changes in hunk $hunk")
                unless $has_from || $has_to;
            $diff_out .= "***************\n";
            $diff_out .= "*** $from_start,$from_end ****\n";
            $diff_out .= $from_out if $has_from;
            $diff_out .= "--- $to_start,$to_end ----\n";
            $diff_out .= $to_out if $has_to;
        }
    }
}
1;


