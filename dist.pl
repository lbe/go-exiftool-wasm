#!/usr/bin/env perl

# Build and stage a minimized ExifTool Perl distribution for WASI embedding.
#
# Actions performed:
# 1) Resolve an ExifTool version (from EXIFTOOL_VERSION or exiftool.org history).
# 2) Download and extract the matching source archive into tmp/.
# 3) Run Makefile.PL + make using install paths under embed/perl-wasi-prefix/.
# 4) Remove POD docs, minify Perl sources, and strip problematic signal handlers.
# 5) Run tests, install into the prefix, and verify the installed exiftool binary.

use v5.14;
use strict;
use warnings;
use autodie;
use Archive::Tar;
use Config;
use Cwd qw(getcwd abs_path);
use File::Basename qw(dirname);
use File::Find qw(find);
use File::Path qw(make_path remove_tree);
use File::Spec;
use Getopt::Long qw(GetOptions);
use HTTP::Tiny;
use Perl::Tidy;
use POSIX qw(WNOHANG sysconf);

# Minify a list of Perl source files in parallel using a bounded fork pool.
# Each worker runs Perl::Tidy on one file; the parent reaps children as slots
# free up and dies immediately if any worker exits non-zero.
sub minify_parallel {
    my ($files, $workers) = @_;
    $workers //= eval { sysconf(POSIX::_SC_NPROCESSORS_ONLN()) } || 4;

    my %children;  # pid => filename

    for my $f (@$files) {
        # Block until a worker slot is free, yielding CPU between polls
        while (keys(%children) >= $workers) {
            my $pid = waitpid(-1, WNOHANG);
            if ($pid > 0) {
                my $exit = $? >> 8;
                die "perltidy worker failed on $children{$pid} (exit $exit)\n" if $exit;
                delete $children{$pid};
            }
            else {
                select(undef, undef, undef, 0.005);
            }
        }

        my $pid = fork // die "fork failed: $!\n";
        if ($pid == 0) {
            # Child: tidy one file and exit
            my $err;
            Perl::Tidy::perltidy(
                source      => $f,
                destination => $f,
                argv        => '--noprofile --mangle --delete-all-comments',
                errorfile   => \$err,
            ) and do { warn "perltidy error for $f: $err\n"; exit 1 };
            exit 0;
        }
        $children{$pid} = $f;
    }

    # Reap all remaining workers
    while (%children) {
        my $pid = waitpid(-1, 0);
        next unless $pid > 0;
        my $exit = $? >> 8;
        die "perltidy worker failed on $children{$pid} (exit $exit)\n" if $exit;
        delete $children{$pid};
    }
}

sub usage {
    return <<'USAGE';
Usage: dist.pl [--exiftool-version VERSION]

Build and stage a minimized ExifTool Perl distribution for WASI embedding.

Version resolution order:
  1) --exiftool-version VERSION
  2) EXIFTOOL_VERSION environment variable
  3) Latest version parsed from https://exiftool.org/history.html
USAGE
}

my $cli_ver;
my $help;
GetOptions(
    'exiftool-version=s' => \$cli_ver,
    'help|h'             => \$help,
) or die usage();

if ($help) {
    print usage();
    exit 0;
}

my $root = dirname(abs_path($0));
# Keep all relative paths anchored at repository root.
chdir $root;

my $prefix = File::Spec->catdir(getcwd(), 'embed', 'perl-wasi-prefix');
my $tmp    = 'tmp';

# Determine ExifTool version from CLI or Environment
my $ver = $cli_ver || $ENV{EXIFTOOL_VERSION};
# If no version provided, fetch the history page and parse the latest version number.
unless ($ver) {
    my $r = HTTP::Tiny->new->get('https://exiftool.org/history.html');
    die "Failed to fetch version\n" unless $r->{success};
    $r->{content} =~ /Version\s+([\d.]+)/ or die "Could not parse version\n";
    $ver = $1;
}

# Construct the download URL for the specified version.
my $url = "https://github.com/exiftool/exiftool/archive/refs/tags/${ver}.tar.gz";

# Setup temporary build directory
remove_tree($tmp) if -d $tmp;
make_path($tmp);

# Download
my $tarball = File::Spec->catfile($tmp, 'exiftool.tar.gz');
{
    open my $fh, '>:raw', $tarball;
    my $r = HTTP::Tiny->new->get($url);
    die "Download failed: $r->{status} $r->{reason}\n" unless $r->{success};
    print $fh $r->{content};
    close $fh;
}

# Extract
{
    my $tar = Archive::Tar->new;
    $tar->read($tarball, 1) or die "Failed to read $tarball\n";
    my $cwd = getcwd();
    chdir $tmp;
    $tar->extract() or die "Failed to extract $tarball\n";
    chdir $cwd;
}

my $src = File::Spec->catdir($tmp, "exiftool-${ver}");
chdir $src;

# Build
my @mpl = (
    "INSTALLSITELIB=$prefix/lib/perl5",
    "INSTALLSITEARCH=$prefix/lib/perl5",
    "INSTALLSITEBIN=$prefix/bin",
    "INSTALLSITESCRIPT=$prefix/bin",
    "NO_PERLLOCAL=1",
    "NO_PACKLIST=1",
);
system('perl', 'Makefile.PL', @mpl) == 0 or die "Makefile.PL failed\n";

my $make = $Config{make} || 'make';
system($make) == 0 or die "make failed\n";

# Delete all POD docs in blib (case-insensitive, full-path safe traversal).
find(
    {
        no_chdir => 1,
        wanted   => sub {
            return unless -f $_;
            return unless $_ =~ /\.pod\z/i;
            unlink $_;
        },
    },
    'blib'
);

# Collect Perl files and the exiftool script
my @targets;
find(sub {
    return unless -f;
    push @targets, $File::Find::name if /\.(pm|pl)$/ || $_ eq 'exiftool';
}, 'blib');

# Make writable, minify via Perl::Tidy module (no subprocess overhead), then readonly
chmod(0644, @targets) if @targets;

say "Minifying Perl sources with perltidy...";
minify_parallel(\@targets);

# Remove signal handlers that cause issues in WASI
my $et = File::Spec->catfile('blib', 'script', 'exiftool');
if (-f $et) {
    local @ARGV = ($et);
    local $^I = '';
    while (my $line = <>) {
        print $line unless $line =~ /\$SIG\{(?:INT|CONT)\}\s*=\s*'Sig(?:Int|Cont)';/;
    }
}

chmod(0444, @targets) if @targets;

system($make, 'test') == 0 or die "make test failed\n";

remove_tree($prefix) if -d $prefix;
make_path($prefix);
system($make, 'install') == 0 or die "make install failed\n";

chdir $prefix;
system('perl', '-I', './lib/perl5', './bin/exiftool', '-ver', '-v') == 0
    or die "test run failed\n";

chdir $root;
remove_tree($tmp) if -d $tmp;

print "Done.\n";