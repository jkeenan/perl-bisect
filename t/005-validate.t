use 5.14.0;
use warnings;
# t/005-validate.t

use Perl5::Bisect::Subs qw(
    validate
);
use Test::More;
use Cwd;
use File::Spec;
use Capture::Tiny qw(:all);
use Data::Dump qw(dd pp);

my $startdir = cwd();

ok(-d 'lib', "Able to locate the 'lib' directory");
ok(-d 'bin', "Able to locate the 'bin' directory");
my $bisector = File::Spec->catfile($startdir, 'bin', 'bisect.pl');
my $brunner  = File::Spec->catfile($startdir, 'bin', 'bisect-runner.pl');
ok(-f $bisector, "Able to locate $bisector");
ok(-e $bisector, "$bisector is executable");
ok(-f $brunner, "Able to locate $brunner");
ok(-e $brunner, "$brunner is executable");

my $checkout_dir = $ENV{SECONDARY_CHECKOUT_DIR};
ok(-d $checkout_dir, "Able to locate $checkout_dir");
die "Unable to locate checkout of Perl 5" unless (
    -d $checkout_dir &&
    -d "$checkout_dir/.git"
);
chdir $checkout_dir or die "Unable to change to $checkout_dir: $!";
system(qq|git clean -dfxq|)
    and die "Unable to do git-clean on $checkout_dir:$!";

END {
    chdir $checkout_dir or die "Unable to change to $checkout_dir: $!";
    system(qq|git clean -dfxq|)
        and die "Unable to do git-clean on $checkout_dir:$!";
    system(qq|git checkout blead|)
        and die "Unable to do git-checkout in $checkout_dir:$!";
    chdir $startdir or die "Unable to return to $startdir";
}

{
    my $commit  = 'v5.42.0';
    local @ARGV = (
        "--gold",
        "v5.44.0",
        "--jobs",
        17,
        "--validate",
        "-le",
        "print \"Hello from \$]\"",
    );
    my $start   = "f07bd7d3f9c7d8a65be39522b806ad2ac7fbb8f1"; # Nov 17 2026
    my $end     = "177d9eae54b36af7dfdaa415db02071d928e9d61"; # Nov 18 2026
    my $verbose = 1;

    my $args = {
        start   => $start,
        end     => $end,
        verbose => $verbose,
        brunner => $brunner,
        argv    => [@ARGV],
    };
    my $rv;
    my ($stdout, $stderr, $exit) = capture {
        $rv = validate($commit, $args);
    };
    like(
        $stdout,
        qr/Skipping $commit, as it is earlier than $start/,
        "Got expected message for 'start' commit earlier than requested commit",
    );
    ok(! defined $rv, "validate() returned undefined value");

}

{
    my $commit  = 'v5.44.0';
    local @ARGV = (
        "--gold",
        "v5.44.0",
        "--jobs",
        17,
        "--validate",
        "-le",
        "print \"Hello from \$]\"",
    );
    my $start   = undef;
    my $end   = "0ac24e81b144856829886668dee04f0368e9f6bb"; # one before v5.44.0
    my $verbose = 1;

    my $args = {
        start   => $start,
        end     => $end,
        verbose => $verbose,
        brunner => $brunner,
        argv    => [@ARGV],
    };
    my $rv;
    my ($stdout, $stderr, $exit) = capture {
        $rv = validate($commit, $args);
    };
    like(
        $stdout,
        qr/Skipping $commit, as it is more recent than $end/,
        "Got expected message for 'end' commit earlier than requested commit",
    );
    ok(! defined $rv, "validate() returned undefined value");
}

{
    my $commit  = 'v5.44.0';
    local @ARGV = (
        "--gold",
        "v5.44.0",
        "--jobs",
        17,
        "--validate",
        "-le",
        "print \"Hello from \$]\"",
    );
    my $start   = 'v5.42.0';
    my $end     = 'blead';
    my $verbose = 1;

    my $args = {
        start   => $start,
        end     => $end,
        verbose => $verbose,
        brunner => $brunner,
        argv    => [@ARGV],
    };
    my $rv;
    my ($stdout, $stderr, $exit) = capture {
        $rv = validate($commit, $args);
    };
    is($rv, $commit, "validate() returned original commit '$commit'");
}

chdir $startdir or die "Unable to return to $startdir";

done_testing();
