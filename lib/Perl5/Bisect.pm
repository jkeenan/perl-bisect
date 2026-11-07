package Perl5::Bisect;
use strict;
use warnings;
# The default, auto_abbrev will treat -e as an abbreviation of --end
# Which isn't what we want.
use Getopt::Long qw(:config pass_through no_auto_abbrev);
use File::Spec;
#use File::Path qw(mkpath);
use Data::Dump qw(dd pp);

#BEGIN {
#    use Exporter ();
#    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
#    $VERSION     = '0.01';
#    @ISA         = qw(Exporter);
#    @EXPORT      = qw();
#    @EXPORT_OK   = qw(
#        preliminary_check
#    );
#    %EXPORT_TAGS = ();
#}

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

None.

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

1;

