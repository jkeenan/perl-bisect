use 5.14.0;
use warnings;
use Perl5::Bisect::Patching qw(
    force_manifest
    force_manifest_cleanup
);
use Test::More;
use Carp;
use Cwd;
use File::Copy;
use File::Path qw(mkpath rmtree);
use File::Spec;
use File::Temp qw(tempdir tempfile);
use Data::Dump qw(dd pp);
use File::Touch 0.12;

my $startdir = cwd();
my $checkout_dir = $ENV{SECONDARY_CHECKOUT_DIR};
croak "Unable to locate checkout of Perl 5" unless (
    -d $checkout_dir &&
    -d "$checkout_dir/.git"
);
ok(-d $checkout_dir, "Located git repository");

my $mani = 'MANIFEST';

my @mock_files = (
    "./gitignore",
    "Artistic",
    "asan_ignore",
    "AUTHORS",
    "autodoc.pl",
    "av.c",
    "av.h",
    "builtin.c",
    "cpan/Archive-Tar/t/01_use.t",
    "MANIFEST",
);

sub mock_repository {
    my $mock_files = shift;
    my %seen = map { $_ => 1 } @{$mock_files};
    croak "List of mock files must include 'MANIFEST"
        unless $seen{MANIFEST};
    my $startdir = cwd();
    my $tdir = tempdir();
    chdir $tdir or croak "Unable to change to dir for mock repository";
    my $mani = File::Spec->catdir($tdir, 'MANIFEST');
    for my $el (sort @$mock_files) {
        my ($volume,$directories,$file) = File::Spec->splitpath($el);
        if (length $directories && $directories ne './') {
            my @created = mkpath($directories, 0, 0711);
        }
        touch $el;
    }
    open my $OUT, '>', $mani or croak "Unable to open for writing";
    say $OUT $_ for sort @{$mock_files};
    close $OUT or croak "Unable to close after writing";
    chdir $startdir or croak "Unable to return to starting dir";
    return $tdir;
}

{
    my $source_manifest = File::Spec->catfile($checkout_dir, $mani);
    ok(-f $source_manifest, "Located $mani in git repository $checkout_dir");

    my $repo = mock_repository(\@mock_files);
    note("Testing directory: $repo");
    chdir $repo or croak "Unable to change to tempdir for testing";

    my ($missing, $created_dirs) = force_manifest();
    is(ref $missing, 'ARRAY', "force_manifest() returned array ref first");
    is(@$missing, 0, "Clean MANIFEST should have no missing files");
    is(ref $created_dirs, 'ARRAY', "force_manifest() returned array ref second");
    is(@$created_dirs, 0, "Clean MANIFEST should have no created_dirs");

    chdir $startdir or croak "Unable to change back to starting directory";
    my $removed_count = rmtree($repo, { verbose => 0, safe => 1 });

}

done_testing();

