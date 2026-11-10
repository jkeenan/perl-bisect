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
    placate_patch_prog
    apply_patch
    patch_from_commit
    apply_commit
    revert_commit
    skip
    check_shebang
    checkout_file
    match_and_exit
    report_and_exit
    run_report_and_exit
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

# AIX supplies a pre-historic patch program, which certainly predates Linux
# and is probably older than NT. It can't cope with unified diffs. Meanwhile,
# it's hard enough to get git diff to output context diffs, let alone git show,
# and nearly all the patches embedded here are unified. So it seems that the
# path of least resistance is to convert unified diffs to context diffs:
# (Comment preceding definition on process_hunk, introduced in 6fe55cbde in
# 2011.)

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

{
    # FIXME: Why is this defined outside the subroutine where it's used?
    my $use_context;

    sub placate_patch_prog {
        my $patch = shift;

        if (!defined $use_context) {
            my $version = `patch -v 2>&1`;
            die_255("Can't run `patch -v`, \$?=$?, bailing out")
                unless defined $version;
            if ($version =~ /Free Software Foundation/) {
                $use_context = 0;
            } elsif ($version =~ /Header: patch\.c,v.*\blwall\b/) {
                # The system patch is older than Linux, and probably older than
                # Windows NT.
                $use_context = 1;
            } elsif ($version =~ /Header: patch\.c,v.*\babhinav\b/) {
                # Thank you HP. No, we have no idea *which* version this is:
                # $Header: patch.c,v 76.1.1.2.1.3 2001/12/03 12:24:52 abhinav Exp $
                $use_context = 1;
            } else {
                # Don't know.
                $use_context = 0;
            }
        }

        return $use_context ? ud2cd($patch) : $patch;
    }
}

sub apply_patch {
    my ($patch, $what, $files) = @_;
    $what = 'patch' unless defined $what;
    unless (defined $files) {
        # Handle context diffs (*** ---) and unified diffs (+++ ---)
        # and ignore trailing "garbage" after the filenames
        $patch =~ m!^[-*]{3} [ab]/(\S+)[^\n]*\n[-+]{3} [ba]/\1!sm;
        $files = " $1";
    }
    my $patch_to_use = placate_patch_prog($patch);
    open my $fh, '|-', 'patch', '-p1' or die_255("Can't run patch: $!");
    print $fh $patch_to_use;
    return if close $fh;
    print STDERR "Patch is <<'EOPATCH'\n${patch}EOPATCH\n";
    print STDERR "\nConverted to a context diff <<'EOCONTEXT'\n${patch_to_use}EOCONTEXT\n"
        if $patch_to_use ne $patch;
    die_255("Can't $what$files: $?, $!");
}

sub patch_from_commit {
    my ($revert, $commit, @files) = @_;
    my $flags = $revert ? '-R ' : '';
    my $patch = `git show --src-prefix=a/ --dst-prefix=b/ $flags$commit @files`;
    if (!defined $patch) {
        my $thing = $revert ? 'revert commit' : 'commit';
        die_255("Can't get $thing $commit for @files: $?") if @files;
        die_255("Can't get $thing $commit: $?");
    }
    return $patch;
}

sub apply_commit {
    my ($commit, @files) = @_;
    my $patch = patch_from_commit(undef, $commit, @files);
    apply_patch($patch, "patch $commit", @files ? " for @files" : '');
}

sub revert_commit {
    my ($commit, @files) = @_;
    my $patch = patch_from_commit('revert', $commit, @files);
    apply_patch($patch, "revert $commit", @files ? " for @files" : '');
}

sub skip {
    my $reason = shift;
    clean();
    warn "skipping - $reason";
    exit 125;
}

sub check_shebang {
    my ($file, $run_with_our_perl) = @_;
    return unless -e $file;
    my $fh = open_or_die($file);
    my $line = <$fh>;
    return if $line =~ $run_with_our_perl;
    if (!-x $file) {
        die_255("$file is not executable.
system($file, ...) is always going to fail.

Bailing out");
    }
    return unless $line =~ m{\A#!(/\S+/perl\S*)\s};
    die_255("$file will always be run by $1
It won't be tested by the ./perl we build.
If you intended to run it with that perl binary, please change your
test case to

    $1 @ARGV

If you intended to test it with the ./perl we build, please change your
test case to

    ./perl -Ilib @ARGV

[You may also need to add -- before ./perl to prevent that -Ilib as being
parsed as an argument to bisect.pl]

Bailing out");
}

sub checkout_file {
    my $args = shift;
    $args->{commit} ||= $args->{options}{gold} || 'blead';
    system "git show $args->{commit}:$args->{file} > $args->{file} </dev/null"
        and die_255("Could not extract $args->{file} at revision $args->{commit}");
}

sub match_and_exit {
    my ($target, $globs_ref, $match) = @_;
    my $matches = 0;
    my $re = qr/$match/;
    my @files;

    if (@{$globs_ref}) {
        require File::Glob;
        foreach (sort map { File::Glob::bsd_glob($_)} @{$globs_ref}) {
            if (!-f $_ || !-r _) {
                warn "Skipping matching '$_' as it is not a readable file\n";
            } else {
                push @files, $_;
            }
        }
    } else {
        local $/ = "\0";
        @files = defined $target ? `git ls-files -o -z`: `git ls-files -z`;
        chomp @files;
    }

    foreach my $file (@files) {
        my $fh = open_or_die($file);
        while (<$fh>) {
            if ($_ =~ $re) {
                ++$matches;
                if (/[^[:^cntrl:]\h\v]/) { # Matches non-spacing non-C1 controls
                    print "Binary file $file matches\n";
                } else {
                    $_ .= "\n" unless /\n\z/;
                    print "$file: $_";
                }
            }
        }
        close_or_die($fh);
    }
    report_and_exit($matches,
                    $matches == 1 ? '1 match for' : "$matches matches for",
                    'no matches for', $match);
}

# report_and_exit( {
#   good => '',
#   pass => '',
#   fail => '',
#   description => '',
#   options => \%options,
# } );

sub report_and_exit {
    my $args = shift;

    if ($args->{options}{clean}) {
        # Needed, because files that are build products in this checked out
        # version might be in git in the next desired version.
        system 'git clean -qdxf </dev/null';
        # Needed, because at some revisions the build alters checked out files.
        # (eg pod/perlapi.pod). Also undoes any changes to makedepend.SH
        system 'git reset --hard HEAD </dev/null';
    }

    my $got = ($args->{options}{'expect-pass'}
        ? $args->{good} : !$args->{good})
        ? 'good' : 'bad';
    if ($args->{good}) {
        print "$got - $args->{pass} $args->{description}\n";
    }
    else {
        print "$got - $args->{fail} $args->{description}\n";
    }

    exit($got eq 'bad');
}

sub run_report_and_exit {
    my $options = shift;
    my $ret = run_with_options({setprgp => $options->{setpgrp},
                                timeout => $options->{timeout},
                               }, @_);
    $ret &= 0xff if $options->{crash};
    report_and_exit( {
        good => !$ret,
        pass => 'zero exit from',
        fail => 'non-zero exit from',
        description => "@_",
        options => $options,
    } );
}

1;
