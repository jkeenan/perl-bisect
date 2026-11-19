use 5.14.0;
use warnings;
# t/006-one-liner.t

use Perl5::Bisect::Subs qw(
);
use Test::More;
use Cwd;
use File::Spec;
use File::Temp qw(tempdir tempfile);
    #use Capture::Tiny qw(:all);
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
chdir $startdir or die "Unable to return to $startdir";

END {
    chdir $checkout_dir or die "Unable to change to $checkout_dir: $!";
    system(qq|git clean -dfxq|)
        and die "Unable to do git-clean on $checkout_dir:$!";
    system(qq|git checkout -q blead|)
        and die "Unable to do git-checkout in $checkout_dir:$!";
    chdir $startdir or die "Unable to return to $startdir";
}

SKIP: {
    skip "Lengthy: configures and builds perl", 1
        unless $ENV{RUN_LONG_RUNNING_TESTS};
    note("Test requires configure/build perl; this will take some time ...");

    #my $tdir = tempdir( CLEANUP => 1 );
    my $tdir = tempdir();
    my ($fh, $ERR) = tempfile( DIR => $tdir );

    local @ARGV = (
        '--target' => 'perl',
        '--start' => 'a1399808f7d0c25a44b5677fd6cafda57e658955',
        '--end' => 'e1711683d9d75ff4314d29ad0ca2e4268edcbaca',
        '--one-liner' => 'qq<system(qq|./perl -we "q{ab} =~ /.{-1,4}/" 2>$ERR|); die "See $ERR for warnings thrown" if -s $ERR;>',
    );
    print STDERR "AAAA: ", join ' ' => ($^X, $bisector, @ARGV), "\n";
    my $rv;
    $rv = system($^X, $bisector, @ARGV)
        and die "system call to $bisector failed with $rv: $!";
    is($rv, 0, "system call exited with 0");
}

chdir $startdir or die "Unable to return to $startdir";

done_testing();

=pod

Can't find bisect runner /home/jkeenan/gitwork/perl2/bin/bisect-runner.pl at /home/jkeenan/gitwork/noncore/perl-bisect/bin/bisect.pl line 42.
system call to /home/jkeenan/gitwork/noncore/perl-bisect/bin/bisect.pl failed with 512: Inappropriate ioctl for device at t/006-one-liner.t line 60.

=cut

