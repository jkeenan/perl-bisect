# t/009-dot-equal-operator.t
use 5.14.0;
use warnings;

use Test::More;
use Cwd;
use File::Spec;
use lib ("./t/lib");
use Testing qw(
    get_breaking_sha
    prepare_for_bisection
    cleanup_after_bisection
);

my ($startdir, $checkout_dir, $bisector, $brunner) = prepare_for_bisection();

END { cleanup_after_bisection($startdir, $checkout_dir); }

=pod

From Porting/bisect-runner.pl SYNOPSIS

     # When did this become an error?
    .../Porting/bisect.pl -e 'my $a := 2;'

This functionality was deprecated between 5.10 and 5.12 but was not fully fatalized until 5.14.

    $ perlbrew use perl-5.12.5
    $ perl -e 'my $a := 2;'; echo $?
    Use of := for an empty attribute list is deprecated at -e line 1.
    0
    $ perlbrew use perl-5.14.4
    $ perl -e 'my $a := 2;'; echo $?
    Use of := for an empty attribute list is not allowed at -e line 1.
    255

Bisection used:

    export MYLIB=/home/jkeenan/gitwork/noncore/perl-bisect &&
    perl -I$MYLIB/lib bin/bisect.pl \
    --target miniperl \
    --start v5.12.0 \
    --end   v5.14.0 \
    --one-liner 'my $a := 2;' \
    2>&1 | tee $P5P_DIR/bisection/bisection-202611241552-dot-equals.log

Pointed to:

    2dc78664124f51814246e5b3da10c8a9f5fe2726 is the first bad commit
    commit 2dc78664124f51814246e5b3da10c8a9f5fe2726
    Author: Nicholas Clark <nick@ccl4.org>
    Date:   Fri Nov 26 15:53:56 2010 +0000
    Commit:     Father Chrysostomos <sprout@cpan.org>
    CommitDate: Sun Nov 28 13:17:06 2010 -0800

    Make my $pi := 4; a syntax error.

    Previously it interpreted := as an empty attribute list, and issued a
    deprecation warning. This change permits := to be used as a binding operator.

Ref: https://github.com/jkeenan/perl-bisect/issues/4

export MYLIB=/home/jkeenan/gitwork/noncore/perl-bisect &&
perl -I$MYLIB/lib bin/bisect.pl \
--target miniperl \
--start d42388159bbfea27efd2de1d76aa62e99f6c8240 \
--end   c2e0289ec9c3ceb8a52335bf8446b9abc61434bb \
--one-liner 'my $a := 2;'

=cut


SKIP: {
    skip "Lengthy: configures and builds perl", 1
        unless $ENV{RUN_LONG_RUNNING_TESTS};
    note("Test requires configure/build perl; this will take some time ...");

    my @switches = (
        '--target'      => 'miniperl',
        '--one-liner'   => 'my $a := 2;',
        '--start'       => 'd42388159bbfea27efd2de1d76aa62e99f6c8240 ',
        '--end'         => 'c2e0289ec9c3ceb8a52335bf8446b9abc61434bb ',
        '--verbose',
    );
    my $expected = '2dc78664124f51814246e5b3da10c8a9f5fe2726';

    my $rv = system($^X, $bisector, @switches);
    is($rv, 0, "system call returned 0, as expected");
    my $sha = get_breaking_sha($checkout_dir);
    is($sha, $expected, "Got expected breaking commit: $expected")
        or diag("Instead, got <$sha>");
};

done_testing();

