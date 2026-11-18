use 5.14.0;
use warnings;
# t/005-validate.t

use Perl5::Bisect::Subs qw(
    validate
);
use Test::More;
#use Carp;
use Cwd;
#use File::Copy;
#use File::Path qw(mkpath rmtree);
use File::Spec;
#use File::Temp qw(tempdir tempfile);
#use Tie::File;
use Capture::Tiny qw(:all);
#use Data::Dump qw(dd pp);
#use File::Touch 0.12;
#use Path::Tiny;

my $startdir = cwd();

ok(-d 'lib', "Able to locate the 'lib' directory");
ok(-d 'bin', "Able to locate the 'bin' directory");
my $bisector = File::Spec->catfile('bin', 'bisect.pl');
my $brunner  = File::Spec->catfile('bin', 'bisect-runner.pl');
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

{

#      argv => [
#    "--gold",
#    "v5.44.0",
#    "--jobs",
#    17,
#    "--validate",
#    "-le",
#    "print \"Hello from \$]\"",
#  ],
#  brunner => "/tmp/v3nQZbLMKk",
#  end => "177d9eae54b36af7dfdaa415db02071d928e9d61",
#  start => "f07bd7d3f9c7d8a65be39522b806ad2ac7fbb8f1",
#  verbose => undef,

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
    my $start   = "f07bd7d3f9c7d8a65be39522b806ad2ac7fbb8f1";
    my $end     = "177d9eae54b36af7dfdaa415db02071d928e9d61";
    my $verbose = undef;
    #Skipping v5.42.0, as it is earlier than f07bd7d3f9c7d8a65be39522b806ad2ac7fbb8f1

    my $args = {
        start   => $start,
        end     => $end,
        verbose => $verbose,
        brunner => $brunner,
        argv    => [@ARGV],
    };
    #local $@;
    my $rv;
    #eval { $rv = validate($commit, $args); };
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

chdir $startdir or die "Unable to return to $startdir";

done_testing();
