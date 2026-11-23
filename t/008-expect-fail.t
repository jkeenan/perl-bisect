use 5.14.0;
use warnings;
# t/008-expect-fail.t

use Test::More;
use Cwd;
use File::Spec;
use Path::Tiny;

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
system(qq|git stash -q|)
    and die "Unable to do git-stash on $checkout_dir:$!";
system(qq|git clean -dfxq|)
    and die "Unable to do git-clean on $checkout_dir:$!";
system(qq|git clean -dfxq|)
    and die "Unable to do git-clean on $checkout_dir:$!";
chdir $startdir or die "Unable to return to $startdir";

END {
    chdir $checkout_dir or die "Unable to change to $checkout_dir: $!";
    system(qq|git stash -q|)
        and die "Unable to do git-stash on $checkout_dir:$!";
    system(qq|git clean -dfxq|)
        and die "Unable to do git-clean on $checkout_dir:$!";
    system(qq|git checkout -q blead|)
        and die "Unable to do git-checkout in $checkout_dir:$!";
    chdir $startdir or die "Unable to return to $startdir";
}

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
    # TODO: There's probably a more correct way to identify the breaking
    # commit than reading BISECT_RUN; find it.
    my $runfile = File::Spec->catfile($checkout_dir, '.git', 'BISECT_RUN');
    ok(-f $runfile, "Able to locate BISECT_RUN in checkout directory");
    my @lines = path($runfile)->lines_utf8;
    chomp @lines;
    my ($sha) = $lines[1] =~ m/^commit\s(.*)/;
    is($sha, $expected, "Got expected breaking commit: $expected")
        or diag("Instead, got <$sha>");
};

done_testing();

