# t/011-crash-script.t
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

In core:

    ../perl/Porting/bisect.pl \
        -DDEBUGGING \
       --target miniperl \
       --start 21195f4d7c569ffbbfc383cb731fb11abd237028 \
       --end   0b2df18fd3736ebdac552d596b8976109f9f4643 \
       --crash \
       --verbose \
       -- ./miniperl -Ilib -DXv -e '{ my $n=1; *foo= sub () { $n }; }' \

    ... pointed to:

    1567c65ac069266bfe65959430c185babd476538 is the first bad commit
    commit 1567c65ac069266bfe65959430c185babd476538
    Author: Father Chrysostomos <sprout@cpan.org>
    Date:   Fri Oct 31 22:08:52 2014 -0700

=cut


SKIP: {
    skip "Lengthy: configures and builds perl", 1
        unless $ENV{RUN_LONG_RUNNING_TESTS};
    note("Test requires configure/build perl; this will take some time ...");

    my @switches = (
        '-DDEBUGGING',
       '--target'       => 'miniperl',
       '--start'        => '21195f4d7c569ffbbfc383cb731fb11abd237028',
       '--end'          => ' 0b2df18fd3736ebdac552d596b8976109f9f4643',
       '--crash',
       '--verbose',
       "-- ./miniperl -Ilib -DXv -e '{ my $n=1; *foo= sub () { $n }; }'",
    );
    my $expected = '1567c65ac069266bfe65959430c185babd476538';

    my $rv = system($^X, $bisector, @switches);
    is($rv, 0, "system call returned 0, as expected");
    my $sha = get_breaking_sha($checkout_dir);
    is($sha, $expected, "Got expected breaking commit: $expected")
        or diag("Instead, got <$sha>");
};

done_testing();

