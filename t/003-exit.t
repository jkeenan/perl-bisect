use 5.14.0;
use warnings;
# t/003-exit.t

#use Perl5::Bisect::Patching qw(
#    force_manifest
#    force_manifest_cleanup
#);
use Test::More;
#use Carp;
use Cwd;
use File::Spec;
#use File::Copy;
#use File::Path qw(mkpath rmtree);
#use File::Spec;
#use File::Temp qw(tempdir tempfile);
#use Tie::File;
use Capture::Tiny qw(:all);
use Data::Dump qw(dd pp);
#use File::Touch 0.12;
#use Path::Tiny;

my $startdir = cwd();

ok(-d 'lib', "Able to locate the 'lib' directory");
ok(-d 'bin', "Able to locate the 'bin' directory");
my $bisector = File::Spec->catfile('bin', 'bisect.pl');
ok(-f $bisector, "Able to locate $bisector");
ok(-e $bisector, "$bisector is executable");

{
    my $args = '--usage';
    my ($stdout, $stderr, $exit) = capture {
        system($^X, '-Ilib', $bisector, $args);
    };
    my @lines = split /\n/, $stderr;
    like($lines[-2], qr/Called --usage switch on command-line/,
        "Got expected exit message when calling '$args'");
    is($exit, 0, "--usage exited 0, as expected");
}

{
    # PROBLEM:  If the *only* thing I supply on the command-line is
    # '--check-args', then it will fail at the 'none of no ...' point, because
    # that is reached before the explicit check of 
    #   exit 0 if $options{'check-args'};
    # is reached inside the runner.  So I'll have to supply some valid args or
    # switches in order for the runner to get as far as above, at which point
    # it should exit 0 without proceeding to further bisection.

    # However, even in the core the following arguments cause bisection to
    # proceed to the point in the bisector:
    #   Runner returned 0 for end revision at Porting/bisect.pl line 233.
    # I wasn't expecting it to go so far.  That means I'm uncertain as to what
    # --check-args is supposed to do.  Intuitively, I *want* it to mean:
    # "Check that this combination of command-line switches (if not their
    # arguments) is valid, but don't actually start to run git on any commits.

    my $args = join ' ' => qw(
        --start=181e914ba2fe3eb39d6355b7216090ab35bd579d
        --end=39ab46e0f4bf28375998152104c7441f546cfc1f
        --module=Text::Beautify
        --check-args
    );

#    my $cmd = join ' ' => ($^X, '-Ilib', $bisector, $args);
#    say STDERR "XXX: <$cmd>\n";
#    my ($stdout, $stderr, $exit) = capture {
#        system($cmd);
#    };
#    pp $stdout;
#    pp $stderr;
#    say STDERR "vvv: $exit";
#    my @lines = split /\n/, $stderr;
#    my $exp = qr/Exiting due to: none of no \@ARGV, test-build, defined one-line, module, etc\./;
#    like($lines[-2], $exp,
#        "Got expected exit message when calling '$args'");
#    is($exit >> 8, 255, "--usage exited 255, as expected");
}

# Need test for '--check-shebang'

#{
#    my $args = '--check-shebang';
#    my ($stdout, $stderr, $exit) = capture {
#        system($^X, '-Ilib', $bisector, $args);
#    };
#    my @lines = split /\n/, $stderr;
#    my $exp = qr/Exiting due to: none of no \@ARGV, test-build, defined one-line, module, etc\./;
#    like($lines[-2], $exp,
#        "Got expected exit message when calling '$args'");
#    is($exit >> 8, 255, "--usage exited 255, as expected");
#}

# Need tests for the many ways we exit emitting "Exiting due to: none of no \@ARGV, test-build, defined one-line, module, etc\.";

{
    my $args = '--l';
    my ($stdout, $stderr, $exit) = capture {
        system($^X, '-Ilib', $bisector, $args);
    };
    my @lines = split /\n/, $stderr;
    # Actually, below was NOT what I was expecting
    # I should have said
    #   "Supplied --l or --w without -e clause or --one-liner",
    # But the error message emitted precedes this in bisect-runner.pl (215 vs
    # 225)
    my $exp = qr/Exiting due to: none of no \@ARGV, test-build, defined one-line, module, etc\./;
    like($lines[-2], $exp,
        "Got expected exit message when calling '$args'");
    is($exit >> 8, 255, "--usage exited 255, as expected");
}

{
    my $args = '--w';
    my ($stdout, $stderr, $exit) = capture {
        system($^X, '-Ilib', $bisector, $args);
    };
    my $exp = qr/Exiting due to: none of no \@ARGV, test-build, defined one-line, module, etc\./;
    my @lines = split /\n/, $stderr;
    # Actually, below was NOT what I was expecting
    # I should have said
    #   "Supplied --l or --w without -e clause or --one-liner",
    # But the error message emitted precedes this in bisect-runner.pl (215 vs
    # 225)
    like($lines[-2], $exp,
        "Got expected exit message when calling '$args'");
    is($exit >> 8, 255, "--usage exited 255, as expected");
}

{
    my $args = '--module=Text::Beautify --no-module-tests';

    # TODO: If I call 'system(LIST)' below, bisection begins in 
    # $SECONDARY_CHECKOUT_DIR -- which I do not want!
    # But it DWIMS provided I join the list elements into a string. Why?

    my $cmd = join ' ' => $^X, '-Ilib', $bisector, $args;
    my ($stdout, $stderr, $exit) = capture {
        #system($^X, '-Ilib', $bisector, $args);
        system($cmd);
    };
    my $exp = qr/Exiting due to: --module and --no-module-tests are mutually exclusive\./;
    my @lines = split /\n/, $stderr;
    like($lines[-2], $exp,
        "Got expected exit message when calling '$args'");
    is($exit >> 8, 255, "--usage exited 255, as expected");
}

{
    my $args = '--test-module=Text::Beautify --no-module-tests';

    # TODO: If I call 'system(LIST)' below, bisection begins in 
    # $SECONDARY_CHECKOUT_DIR -- which I do not want!
    # But it DWIMS provided I join the list elements into a string. Why?

    my $cmd = join ' ' => $^X, '-Ilib', $bisector, $args;
    my ($stdout, $stderr, $exit) = capture {
        #system($^X, '-Ilib', $bisector, $args);
        system($cmd);
    };
    my $exp = qr/Exiting due to: --test-module and --no-module-tests are mutually exclusive\./;
    my @lines = split /\n/, $stderr;
    like($lines[-2], $exp,
        "Got expected exit message when calling '$args'");
    is($exit >> 8, 255, "--usage exited 255, as expected");
}

{
    my $args = '--module=Text::Beautify --test-module=Text::Beautify';

    # TODO: If I call 'system(LIST)' below, bisection begins in 
    # $SECONDARY_CHECKOUT_DIR -- which I do not want!
    # But it DWIMS provided I join the list elements into a string. Why?

    my $cmd = join ' ' => $^X, '-Ilib', $bisector, $args;
    my ($stdout, $stderr, $exit) = capture {
        #system($^X, '-Ilib', $bisector, $args);
        system($cmd);
    };
    my $exp = qr/Exiting due to: --module and --test-module are mutually exclusive\./;
    my @lines = split /\n/, $stderr;
    like($lines[-2], $exp,
        "Got expected exit message when calling '$args'");
    is($exit >> 8, 255, "--usage exited 255, as expected");
}

done_testing();

