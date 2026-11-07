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

