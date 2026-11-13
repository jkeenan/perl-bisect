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
use Tie::File;
use Data::Dump qw(dd pp);
use File::Touch 0.12;
use Path::Tiny;

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

    # Now what happens when the MANIFEST lacks a file or directory/file?

    my @not_real = ( qw|
        ./foobar
        ./my/beloved/foobar
    | );

    my @lines = ();
    tie @lines, 'Tie::File', $mani or croak "Unable to tie to MANIFEST";
    my $manifest_lines_orig = scalar @lines;
    push @lines, $_ for @not_real;
    untie @lines or croak "Unable to untie from MANIFEST";

    ($missing, $created_dirs) = force_manifest();

    my $file = Path::Tiny::path($mani);
    my @manifest_lines_revised = $file->lines;
    is ( scalar @manifest_lines_revised,
        ($manifest_lines_orig + scalar @not_real),
        "MANIFEST has been augmented by " . scalar @not_real . " lines"
    );

    is(ref $missing, 'ARRAY', "force_manifest() returned array ref first");
    is(@$missing, 2, "2 files not found in MANIFEST");
    is(ref $created_dirs, 'ARRAY', "force_manifest() returned array ref second");
    is(@$created_dirs, 2, "2 subdirectories not represented in MANIFEST");

    # force_manifest_cleanup wants to call Auxiliary::skip and then wants to
    # perform a git-clean ... which will only work in a real git checkout
    # not a mock checkout like we have here.
    #force_manifest_cleanup($missing, $created_dirs);

    chdir $startdir or croak "Unable to change back to starting directory";
    my $removed_count = rmtree($repo, { verbose => 0, safe => 1 });
}

done_testing();

