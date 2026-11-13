use strict;
use warnings;
use Perl5::Bisect::Patching qw(
    force_manifest
    force_manifest_cleanup
);
use Test::More;
use Carp;
use File::Copy;
use File::Spec;
use File::Temp qw(tempdir tempfile);
use Data::Dump qw(dd pp);

my $checkout_dir = $ENV{SECONDARY_CHECKOUT_DIR};
croak "Unable to locate checkout of Perl 5" unless (
    -d $checkout_dir &&
    -d "$checkout_dir/.git"
);
ok(-d $checkout_dir, "Located git repository");

my $mani = 'MANIFEST';

{
    my $source_manifest = File::Spec->catfile($checkout_dir, $mani);
    ok(-f $source_manifest, "Located $mani in git repository $checkout_dir");

    my $tdir = tempdir(CLEANUP => 1);
    my $testing_manifest = File::Spec->catfile($tdir, $mani);
    copy $source_manifest => $testing_manifest
        or croak "Unable to copy $mani for testing";
    ok(-f $testing_manifest, "$mani copied to tempdir for testing");

    my ($missing, $created_dirs) = force_manifest();
    is(ref $missing, 'ARRAY', "force_manifest() returned array ref first");
    is(ref $created_dirs, 'ARRAY', "force_manifest() returned array ref second");
}

done_testing();

