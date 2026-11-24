# t/008-expect-fail.t
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

    # When did this stop being an error?
    .../Porting/bisect.pl --expect-fail -e '1 // 2'

$ perl Porting/bisect.pl --start=perl-5.8.0 --end=v5.10.0 --target=miniperl --expect-fail -e '1 // 2'

c963b151157dab5813a32fc6004b63916ad155e8 is the first bad commit
commit c963b151157dab5813a32fc6004b63916ad155e8
Author: Brent Dax <brentdax@cpan.org>
Date:   Thu Jul 25 22:41:52 2002 -0700

    Defined-or patch (cleaned up)
    From: "Brent Dax" <brentdax@cpan.org>
    Message-id: <000001c234a1$d1ca72c0$6501a8c0@deepblue>

$ export MYLIB=/home/jkeenan/gitwork/noncore/perl-bisect &&  \
perl -I$MYLIB/lib bin/bisect.pl \
--target=miniperl \
--start=c963b151157dab5813a32fc6004b63916ad155e8^ \
--end=e55ac0fa2de97f387f14e72ecb12931a1e26d2c6 \
--expect-fail \
-e '1 // 2' \
2>&1 | tee $P5P_DIR/bisection/bisection-20261121-double-slash.log

=cut


SKIP: {
    skip "Lengthy: configures and builds perl", 1
        unless $ENV{RUN_LONG_RUNNING_TESTS};
    note("Test requires configure/build perl; this will take some time ...");

    my @switches = (
        '--target'      => 'miniperl',
        '--one-liner'   => '1 // 2',
        '--start'       => 'c963b151157dab5813a32fc6004b63916ad155e8^',
        '--end'         => 'e55ac0fa2de97f387f14e72ecb12931a1e26d2c6',
        '--expect-fail',
        '--verbose',
    );
    my $expected = 'c963b151157dab5813a32fc6004b63916ad155e8';

    my $rv = system($^X, $bisector, @switches);
    is($rv, 0, "system call returned 0, as expected");
    my $sha = get_breaking_sha($checkout_dir);
    is($sha, $expected, "Got expected breaking commit: $expected")
        or diag("Instead, got <$sha>");
};

done_testing();

