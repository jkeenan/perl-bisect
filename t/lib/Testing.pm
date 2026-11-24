# t/lib/Testing.pm
package Testing;
use 5.14.0;
use warnings;
our ( $VERSION, @ISA, @EXPORT_OK );
$VERSION = "0.01";
require Exporter;
@ISA         = qw(Exporter);
@EXPORT_OK = ( qw|
    get_breaking_sha
|);
use File::Spec;
use Path::Tiny;

sub get_breaking_sha {
    my $checkout_dir = shift;

    # TODO: There's probably a more correct way to identify the breaking
    # commit than reading BISECT_RUN; find it.

    my $runfile = File::Spec->catfile($checkout_dir, '.git', 'BISECT_RUN');
    -f $runfile or die "Unable to locate BISECT_RUN in checkout directory: $!";
    my @lines = path($runfile)->lines_utf8;
    chomp @lines;
    my ($sha) = $lines[1] =~ m/^commit\s(.*)/;
    return $sha;
}

1;
