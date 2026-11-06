package Perl5::Bisect;
use strict;
use warnings;
# The default, auto_abbrev will treat -e as an abbreviation of --end
# Which isn't what we want.
use Getopt::Long qw(:config pass_through no_auto_abbrev);
use File::Spec;
#use File::Path qw(mkpath);
use Data::Dump qw(dd pp);

BEGIN {
    use Exporter ();
    our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
    $VERSION     = '0.01';
    @ISA         = qw(Exporter);
    @EXPORT      = qw();
    @EXPORT_OK   = qw(
        preliminary_check
    );
    %EXPORT_TAGS = ();
}

=head1 NAME

Perl5::Bisect - Bisection of the Perl core distribution, modularized

=head1 SUBROUTINES

We'll eventually transform these subroutines into methods, but for now just
make them importable on request only.

=head2 C<preliminary_check()>

=over 4

=item * Purpose

Do what the first code in F<Porting/bisect.pl> does up until the introduction
of the "runner" -- but keep track of command-line arguments internally.

=item * Arguments

=item * Return Value

=item * Comment

=back

=cut

sub preliminary_check {
    my $data = {};

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
    $data->{h} = \%h;
    $data->{argv} = \@XARGV;
    $data->{bad} = $bad;
    $data->{check_for_cpan_config} = $check_for_cpan_config;
    return $data;
}

1;
# The preceding line will help the module return a true value

