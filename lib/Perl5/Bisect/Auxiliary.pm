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

1;


