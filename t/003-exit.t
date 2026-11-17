use 5.14.0;
use warnings;
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
    my $args = '--check-args';
    my ($stdout, $stderr, $exit) = capture {
        system($^X, '-Ilib', $bisector, $args);
    };
    my @lines = split /\n/, $stderr;
    my $exp = qr/Exiting due to: none of no \@ARGV, test-build, defined one-line, module, etc\./;
    like($lines[-2], $exp,
        "Got expected exit message when calling '$args'");
    is($exit >> 8, 255, "--usage exited 255, as expected");
}

{
    my $args = '--l';
    my ($stdout, $stderr, $exit) = capture {
        system($^X, '-Ilib', $bisector, $args);
    };
    my @lines = split /\n/, $stderr;
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

