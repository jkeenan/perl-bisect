# t/007-one-liner.t
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

# https://github.com/Perl/perl5/issues/25083
# regex alternation drops a branch that starts with (?:)

export MYLIB=/home/jkeenan/gitwork/noncore/perl-bisect &&  \
perl -I$MYLIB/lib bin/bisect.pl \
--target=miniperl \
--verbose \
--start=v5.44.0 \
--end=1c97e98f03 \
--one-liner '("a" =~ /\A(?:|(?:)a)\z/) ? exit 0 : exit 1' \
2>&1 | tee $P5P_DIR/bisection/bisection-202611201609-gh-25083.log

=cut


SKIP: {
    skip "Lengthy: configures and builds perl", 1
        unless $ENV{RUN_LONG_RUNNING_TESTS};
    note("Test requires configure/build perl; this will take some time ...");

    my @switches = (
        '--target'      => 'miniperl',
        '--one-liner'   => '("a" =~ /\A(?:|(?:)a)\z/) ? exit 0 : exit 1',
        '--start'       => '8ca24e8429e06917221ce4a3858525ac40bbb80f',
        '--end'         => '3b3c7c138006d777656f4261deb730075c734558',
        '--verbose',
    );
    my $expected = 'bbf35a5118762c3ee3c08b2753bfbb372f67bf6b';
    my $rv = system($^X, $bisector, @switches);
    is($rv, 0, "system call returned 0, as expected");
    my $sha = get_breaking_sha($checkout_dir);
    is($sha, $expected, "Got expected breaking commit: $expected")
        or diag("Instead, got <$sha>");
};

done_testing();

