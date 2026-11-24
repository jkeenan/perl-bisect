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
    prepare_for_bisection
    cleanup_after_bisection
|);
use Carp;
use Cwd;
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

sub prepare_for_bisection {
    my $startdir = cwd();

    (-d 'lib') or croak "Unable to locate the 'lib' directory";
    (-d 'bin') or croak "Unable to locate the 'bin' directory";
    my $bisector = File::Spec->catfile('bin', 'bisect.pl');
    my $brunner  = File::Spec->catfile('bin', 'bisect-runner.pl');
    (-f $bisector) or croak "Unable to locate $bisector";
    (-f $brunner) or croak "Unable to locate $brunner";
    (-e $bisector) or croak "$bisector is not executable";
    (-e $brunner) or croak "$brunner is not executable";

    my $checkout_dir = $ENV{SECONDARY_CHECKOUT_DIR};
    (-d $checkout_dir) or croak "Unable to locate $checkout_dir";
    croak "Unable to locate checkout of Perl 5" unless (
        -d $checkout_dir &&
        -d "$checkout_dir/.git"
    );
    chdir $checkout_dir or croak "Unable to change to $checkout_dir";

    system(qq|git stash -q|)
        and croak "Unable to do git-stash on $checkout_dir";
    system(qq|git bisect reset|)
        and croak "Unable to do git bisect reset on $checkout_dir";
    system(qq|git clean -dfxq|)
        and croak "Unable to do git-clean on $checkout_dir";

    chdir $startdir or croak "Unable to return to $startdir";
    return (
        $startdir,
        $checkout_dir,
        $bisector,
        $brunner,
    );
}

sub cleanup_after_bisection {
    my ($startdir, $checkout_dir) = @_;
    chdir $checkout_dir or die "Unable to change to $checkout_dir: $!";
    system(qq|git stash -q|)
        and die "Unable to do git-stash on $checkout_dir:$!";
    system(qq|git clean -dfxq|)
        and die "Unable to do git-clean on $checkout_dir:$!";
    system(qq|git checkout -q blead|)
        and die "Unable to do git-checkout in $checkout_dir:$!";

    # We stash, clean and go back to blead
    # But we don't say 'git bisect reset' because the user may well want to
    # inspect the output of bisection in $checkout_dir/.git.

    chdir $startdir or die "Unable to return to $startdir";
}

1;
