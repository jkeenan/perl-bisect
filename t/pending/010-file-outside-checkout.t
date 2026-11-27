# t/010-file-outside-checkout.t
# https://github.com/jkeenan/perl-bisect/issues/6
use 5.14.0;
use warnings;

use Test::More;
use Carp;
use Cwd;
use File::Spec;
use File::Temp qw(tempdir tempfile);
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

    # When did this test program start crashing (any signal or coredump)?
     .../Porting/bisect.pl --crash -- ./perl -Ilib ../test_prog.pl


=cut

my $tdir = tempdir();
#my $tdir = tempdir(CLEANUP => 1);
#chdir $tdir or croak "Unable to change to $tdir";

SKIP: {
    skip "'module_true' requires perl-5.42", 4
        unless $] >= 5.042000;

    my $module = File::Spec->catfile($tdir, 'Noofoo.pm');
    open my $OUT1, '>', $module or croak "Unable to open $module for writing";
    print $OUT1 <<~EOF;
    # https://github.com/Perl/perl5/issues/23435
    use experimental 'class';
    use feature 'module_true';
    class Noofoo;
    ADJUST {}
    EOF
    close $OUT1 or croak "Unable to close $module after writing";
    ok(-f $module, "Module created");
    
    my $script = File::Spec->catfile($tdir, 'foo.pl');
    open my $OUT2, '>', $script or croak "Unable to open $script for writing";
    print $OUT2 <<~EOG;
    use strict;
    use warnings;
    use Noofoo;
    print "Hello world!\n";
    EOG
    close $OUT2 or croak "Unable to close $script after writing";
    ok(-f $script, "Module created");

    SKIP: {
        skip "Lengthy run: configures and builds perl", 2
            unless $ENV{RUN_LONG_RUNNING_TESTS};
        note("Test requires configure/build perl; this will take some time ...");
    
        my @switches = (
            '--one-liner'   => './perl -Ilib -I$tdir $script',
            '--start'       => 'v5.43.3',
            '--end'         => 'v5.43.4',
            '--expect-fail',
            '--verbose',
        );
        my $expected = '1f5204da4ee3fb2de8b84ae0ad56365b1d5bbc08';
    
        my $rv = system($^X, $bisector, @switches);
        is($rv, 0, "system call returned 0, as expected");
        my $sha = get_breaking_sha($checkout_dir);
        is($sha, $expected, "Got expected breaking commit: $expected")
            or diag("Instead, got <$sha>");
    }
}

=pod

VVV: @ARGV in fall-through case: ./perl -Ilib -e ./perl -Ilib -I$tdir $script
syntax error at -e line 1, near "."
Execution of -e aborted due to compilation errors.
HEAD is now at 1b96d25e5a Add new release to perlhist
good - non-zero exit from ./perl -Ilib -e ./perl -Ilib -I$tdir $script
Runner returned 0 for end revision at bin/bisect.pl line 367.
That took 76 seconds.
not ok 3 - system call returned 0, as expected

#   Failed test 'system call returned 0, as expected'
#   at t/010-file-outside-checkout.t line 77.
#          got: '65280'
#     expected: '0'
Unable to locate BISECT_RUN in checkout directory: No such file or directory at t/lib/Testing.pm line 26.
# Tests were run but no plan was declared and done_testing() was not seen.

=cut

done_testing();

