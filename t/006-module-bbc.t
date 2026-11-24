# t/006-module-bbc.t
use 5.14.0;
use warnings;

use Test::More;
use Cwd;
use File::Spec;
use lib ("./t/lib");
use Testing qw( 
    get_breaking_sha
);

# TODO: Encapsulate and modularize all this setup stuff; return $startdir,
# $bisector, $brunner, $checkout_dir.  Investigate whether the END block
# can/should go into such a subroutine.

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

# https://github.com/Perl/perl5/issues/24789 : Text-Beautify

export MYLIB=/home/jkeenan/gitwork/noncore/perl-bisect && 
perl -I$MYLIB/lib bin/bisect.pl \
--module=Text::Beautify \
--start=181e914ba2fe3eb39d6355b7216090ab35bd579d \
--end=39ab46e0f4bf28375998152104c7441f546cfc1f \
--verbose

6aef1e87c1ea274e225828cbc1a6044b54feec44 is the first bad commit
commit 6aef1e87c1ea274e225828cbc1a6044b54feec44
Author: Karl Williamson <khw@cpan.org>
Date:   Fri Jul 17 16:52:35 2026 -0600

    intuit_more: Pass context to it in another instance

    Fixes #24339

=cut

SKIP: {
    skip "Lengthy: configures and builds perl", 1
        unless $ENV{RUN_LONG_RUNNING_TESTS};
    note("Test requires configure/build perl; this will take some time ...");

    my @switches = (
        "--module"    => 'Text::Beautify',
        "--start"    => '181e914ba2fe3eb39d6355b7216090ab35bd579d',
        "--end"      => '39ab46e0f4bf28375998152104c7441f546cfc1f',
        "--verbose",
    );
    my $expected = '6aef1e87c1ea274e225828cbc1a6044b54feec44';
    my $rv = system($^X, $bisector, @switches);
    is($rv, 0, "system call returned 0, as expected");
    my $sha = get_breaking_sha($checkout_dir);
    is($sha, $expected, "Got expected breaking commit: $expected")
        or diag("Instead, got <$sha>");
};

done_testing();

