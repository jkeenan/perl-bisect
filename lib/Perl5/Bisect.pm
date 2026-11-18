package Perl5::Bisect;
use 5.14.0;
use warnings;
use Data::Dump qw(dd pp);
our $VERSION = "0.01";
use lib ('blib/lib');
use Perl5::Bisect::Auxiliary qw(
);
use Perl5::Bisect::Patching qw(
);
use Perl5::Bisect::Subs qw(
);

=head1 NAME

Perl5::Bisect - Bisection of the Perl core distribution, modularized

=head1 DESCRIPTION

Nothing here yet.  Once we determine how to combine the functionality
currently found in F<bin/bisect.pl> and F<bin/bisect-runner.pl> into a single
production program, this package will hold the top-level subroutines and
methods implementing that functionality.

=cut

1;

