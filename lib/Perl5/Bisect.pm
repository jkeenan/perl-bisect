package Perl5::Bisect;
use strict;
use warnings;
# The default, auto_abbrev will treat -e as an abbreviation of --end
# Which isn't what we want.
use Getopt::Long qw(:config pass_through no_auto_abbrev);
use File::Spec;
#use File::Path qw(mkpath);
use Data::Dump qw(dd pp);

=head1 NAME

Perl5::Bisect - Bisection of the Perl core distribution, modularized

=head1 COMMAND LINE OPTIONS

I'll be documenting here the command-line options currently used by F<Porting/bisect.pl> and F<Porting/bisect-runner.pl> in the Perl 5 core distribution as I write code using them.

=over 4

=item * --start I<commit-ish>

Earliest revision to test, as a I<commit-ish> (a tag, commit or anything
else C<git> understands as a revision). If not specified, F<bisect.pl> will
search stable .0 perl releases until it finds one where the test case
passes. The default is to search from 5.002 to the most recent tagged stable
release (v5.18.0 at the time of writing). If F<bisect.pl> detects that the
checkout is on a case insensitive file system, it will search from 5.005 to
the most recent tagged stable release. Only .0 stable releases are used
because these are the only stable releases that are parents of blead, and
hence suitable for a bisect run.

=item * --end I<commit-ish>

Most recent revision to test, as a I<commit-ish>. If not specified, defaults
to I<blead>.

=item * --jobs I<jobs> -j I<jobs>

Number of C<make> jobs to run in parallel. A value of 0 suppresses
parallelism. If F</proc/cpuinfo> exists and can be parsed, or F</sbin/sysctl>
exists and reports C<hw.ncpu>, or F</usr/bin/getconf> exists and reports
C<_NPROCESSORS_ONLN> defaults to 1 + I<number of CPUs>. On HP-UX with the
system make defaults to 0, otherwise defaults to 2.

=item *

--module module1,module2,...

Install this (or these) module(s), die when it (the last of those)
cannot be updated to the current version.

Misnomer. the argument can be any argument that can be passed to CPAN
shell's install command. B<But>: since we only have the uptodate
command to verify that an install has taken place, we are unable to
determine success for arguments like
MSCHWERN/Test-Simple-1.005000_005.tar.gz.

In so far, it is not such a misnomer.

Note that this and I<--with-module> will both require a C<CPAN::MyConfig>.
If F<$ENV{HOME}/.cpan/CPAN/MyConfig.pm> does not exist, a CPAN shell will
be started up for you so you can configure one. Feel free to let
CPAN pick defaults for you. Enter 'quit' when you are done, and
then everything should be all set. Alternatively, you may
specify a custom C<CPAN::MyConfig> by using I<--cpan-config-dir>.

Also, if you want to bisect a module that needs a display (like
TK) and you don't want random screens appearing and disappearing
on your computer while you're working, you can do something like
this:

In a terminal:

 $ while true; do date ; if ! ps auxww | grep -v grep \
   | grep -q Xvfb; then Xvfb :121 & fi; echo -n 'sleeping 60 '; \
   sleep 60; done

And then:

  DISPLAY=":121" .../Porting/bisect.pl --module=TK

(Some display alternatives are vncserver and Xnest.)

=item *

--with-module module1,module2,...

Like I<--module> above, except this simply installs the requested
modules and they can then be used in other tests.

For example:

  .../Porting/bisect.pl --with-module=Moose -e 'use Moose; ...'

=back

=head1 METHODS

=head2 C<new()>

=over 4

=item * Purpose

Perl5::Bisect constructor.  Begins processing of command-line switches up to
the point where the "runner" first appears in F<Porting/bisect.pl>, but does
so by keeping track of command-line arguments internally rather than
manipulation of global variable C<@ARGV>.

=item * Arguments

    my $self = Perl5::Bisect->new();

None, as it simply processes the arguments and switches provided on the
command-line (C<@ARGV>).

=item * Return Value

Perl5::Bisect object.

=item * Comment

TK

=back

=cut

sub new {
    my $class = shift;

    # replacing $need_cpan_config with more accurate variable name
    my $check_for_cpan_config;

    my %h = (); # store command-line options
    my $bad = !GetOptions(\%h, qw(
        start=s
        end=s
        jobs|j=i
        make=s
        gold=s
        validate
        usage|help|?
        module=s
        with-module=s
        cpan-config-dir=s
    ));

# Options not yet ready
#        check-args
#        check-shebang!

    my @XARGV = map { $_ } @ARGV;
    unshift @XARGV, '--help'     if $bad || $h{usage};
    unshift @XARGV, '--validate' if $h{validate};

    if ($h{module} || $h{with_module}) {
        unshift @XARGV, '--module', $h{module} if defined $h{module};
        unshift @XARGV, '--with-module', $h{with_module} if defined $h{with_module};

        if ($h{cpan_config_dir}) {
            my $c = File::Spec->catfile($h{cpan_config_dir}, 'CPAN', 'MyConfig.pm');
            die "--cpan-config-dir: $c does not exist\n" unless -e $c;

            unshift @XARGV, '--cpan-config-dir', $h{cpan_config_dir};
        }
        else {
            $check_for_cpan_config = 1;
        }
    }
    my $data = {
        h => \%h,
        argv => \@XARGV,
        bad => $bad,
        check_for_cpan_config => $check_for_cpan_config,
    };
    return bless $data, $class;
}

=head2 C<get_argv()>, C<get_argv_as_string()>, C<get_options()>

=over 4

=item * Purpose

Three accessors returning the I<current> state of various data in the object.

=item * Arguments

    my $argv_arrayref   = $self->get_argv();

    my $argv_string     = $self->get_argv_as string();

    my options_hashref  = $self->get_options();

=item * Return Value

As suggested by the names of variables above.

=item * Comment

In the core distribution, F<Porting/bisect.pl> and F<Porting/bisect-runner.pl>
communicate by unshifting/pushing arguments onto global C<@ARGV> or
shifting/popping arguments off that array.  Furthermore, the two programs, in
effect, "share" C<@ARGV> via the clever trick of starting off in F<bisect.pl>
and then assigning F<bisect-runner.pl> to C<$^X>.  Here in Perl5::Bisect we
hope to make the code more understandable by undoing some of that cleverness
and keeping all the state within one program.

C<get_argv_as_string()> reports the same data as C<get_argv()>, only
stringified with single wordspace separators (C<' '>).

=back

=cut

sub get_argv {
    my $self = shift;
    return $self->{argv};
}

sub get_argv_as_string {
    my $self = shift;
    return join ' ' => @{$self->{argv}};
}

sub get_options {
    my $self = shift;
    return $self->{h};
}

=pod

Next: Write code for the functionality expressed in these 3 lines from
bisect.pl, which in turn are provided by bisect-runner.pl:  (BUT WHAT DO THEY
MEAN?)

system $^X, $runner, '--check-args', '--check-shebang', @ARGV and exit 255;
exit 255 if $bad;
exit 0 if $usage;

=cut

1;

