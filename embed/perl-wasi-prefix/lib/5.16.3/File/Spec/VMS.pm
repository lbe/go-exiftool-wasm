package File::Spec::VMS;

use strict;
use vars qw(@ISA $VERSION);
require File::Spec::Unix;

$VERSION = '3.39_02';
$VERSION =~ tr/_//;

@ISA = qw(File::Spec::Unix);

use File::Basename;
use VMS::Filespec;


my $use_feature;

BEGIN {
    if ( eval { local $SIG{__DIE__}; require VMS::Feature; } ) {
        $use_feature = 1;
    }
}

sub _unix_rpt {
    my $unix_rpt;
    if ($use_feature) {
        $unix_rpt = VMS::Feature::current("filename_unix_report");
    }
    else {
        my $env_unix_rpt = $ENV{'DECC$FILENAME_UNIX_REPORT'} || '';
        $unix_rpt = $env_unix_rpt =~ /^[ET1]/i;
    }
    return $unix_rpt;
}


sub canonpath {
    my ( $self, $path ) = @_;

    return undef unless defined $path;

    my $unix_rpt = $self->_unix_rpt;

    if ( $path =~ m|/| ) {
        my $pathify = $path =~ m|/\Z(?!\n)|;
        $path = $self->SUPER::canonpath($path);

        return $path if $unix_rpt;
        $path = $pathify ? vmspath($path) : vmsify($path);
    }

    $path =~ s/(?<!\^)</[/;
    $path =~ s/(?<!\^)>/]/;
    $path =~ s/(?<!\^)\]\[\./\.\]\[/g;
    $path =~ s/(?<!\^)\[000000\.\]\[/\[/g;
    $path =~ s/(?<!\^)\[000000\./\[/g;
    $path =~ s/(?<!\^)\.\]\[000000\]/\]/g;
    $path =~ s/(?<!\^)\.\]\[/\./g;
    1 while ( $path =~ s/(?<!\^)([\[\.])(-+)\.(-+)([\.\]])/$1$2$3$4/ );
    1 while ( $path =~ s/(?<!\^)([\[\.])[^\]\.]+\.-(-+)([\]\.])/$1$2$3/ );
    $path  =~ s/(?<!\^)\[\.-/[-/;
    $path  =~ s/(?<!\^)\.[^\]\.]+\.-\./\./g;
    $path  =~ s/(?<!\^)\[[^\]\.]+\.-\./\[/g;
    $path  =~ s/(?<!\^)\.[^\]\.]+\.-\]/\]/g;
     $path =~ s/(?<!\^)\[[^\]\.]+\.-\]/\[000000\]/g;
    $path  =~ s/(?<!\^)\[\]// unless $path eq '[]';
    return $unix_rpt ? unixify($path) : $path;
}


sub catdir {
    my $self = shift;
    my $dir  = pop;

    my $unix_rpt = $self->_unix_rpt;

    my @dirs = grep { defined() && length() } @_;

    my $rslt;
    if (@dirs) {
        my $path = ( @dirs == 1 ? $dirs[0] : $self->catdir(@dirs) );
        my ( $spath, $sdir ) = ( $path, $dir );
        $spath =~ s/\.dir\Z(?!\n)//i;
        $sdir  =~ s/\.dir\Z(?!\n)//i;

        if ($unix_rpt) {
            $spath = unixify($spath) unless $spath =~ m#/#;
            $sdir  = unixify($sdir)  unless $sdir  =~ m#/#;
            return $self->SUPER::catdir( $spath, $sdir );
        }

        $sdir = $self->eliminate_macros($sdir)
          unless $sdir =~ /^[\w\-]+\Z(?!\n)/s;
        $rslt = $self->fixpath( $self->eliminate_macros($spath) . "/$sdir", 1 );

        if ( $spath =~ /^[\[<][^.\-]/s ) { $rslt =~ s/^[^\[<]+//s; }

    }
    else {

        if ( not defined $dir or not length $dir ) {
            $rslt = '';
        }
        else {
            $rslt = $unix_rpt ? $dir : vmspath($dir);
        }
    }
    return $self->canonpath($rslt);
}


sub catfile {
    my $self  = shift;
    my $tfile = pop();
    my $file  = $self->canonpath($tfile);
    my @files = grep { defined() && length() } @_;

    my $unix_rpt = $self->_unix_rpt;

    my $rslt;
    if (@files) {
        my $path = ( @files == 1 ? $files[0] : $self->catdir(@files) );
        my $spath = $path;

        $spath =~ s/\.dir\Z(?!\n)//i;

        if ( $spath =~ /^(?<!\^)[^\)\]\/:>]+\)\Z(?!\n)/s
            && basename($file) eq $file )
        {
            $rslt = "$spath$file";
        }
        else {
            $rslt = $self->eliminate_macros($spath);
            $rslt .=
              ( defined($rslt) && length($rslt) ? '/' : '' ) . unixify($file);
            $rslt = vmsify($rslt) unless $unix_rpt;
        }
    }
    else {
        my $xfile = ( defined($file) && length($file) ) ? $file : '';

        $rslt = $unix_rpt ? $file : vmsify($file);
    }
    return $self->canonpath($rslt) unless $unix_rpt;

    return $rslt;
}


sub curdir {
    my $self = shift @_;
    return '.' if ( $self->_unix_rpt );
    return '[]';
}


sub devnull {
    my $self = shift @_;
    return '/dev/null' if ( $self->_unix_rpt );
    return "_NLA0:";
}


sub rootdir {
    my $self = shift @_;
    if ( $self->_unix_rpt ) {
        my $try = '/';
        my ( $dev1, $ino1 ) = stat('/');
        my ( $dev2, $ino2 ) = stat('.');

        if ( ( $dev1 != $dev2 ) || ( $ino1 != $ino2 ) ) {
            return $try;
        }
        return '/sys$disk/';
    }
    return 'SYS$DISK:[000000]';
}


my $tmpdir;

sub tmpdir {
    my $self = shift @_;
    return $tmpdir if defined $tmpdir;
    if ( $self->_unix_rpt ) {
        $tmpdir = $self->_tmpdir( '/tmp', '/sys$scratch', $ENV{TMPDIR} );
        return $tmpdir;
    }

    $tmpdir = $self->_tmpdir( 'sys$scratch:', $ENV{TMPDIR} );
}


sub updir {
    my $self = shift @_;
    return '..' if ( $self->_unix_rpt );
    return '[-]';
}


sub case_tolerant {
    return 1;
}


sub path {
    my ( @dirs, $dir, $i );
    while ( $dir = $ENV{ 'DCL$PATH;' . $i++ } ) { push( @dirs, $dir ); }
    return @dirs;
}


sub file_name_is_absolute {
    my ( $self, $file ) = @_;
    $file = $ENV{$file} while $file =~ /^[\w\$\-]+\Z(?!\n)/s && $ENV{$file};
    return
      scalar($file =~ m!^/!s
          || $file =~ m![<\[][^.\-\]>]!
          || $file =~ /:[^<\[]/ );
}


sub splitpath {
    my ( $self, $path, $nofile ) = @_;
    my ( $dev, $dir, $file ) = ( '', '', '' );
    my $vmsify_path = vmsify($path);

    if ($nofile) {
        if ( $vmsify_path =~ /(.*)\](.+)/ ) {
            $vmsify_path = $1 . '.' . $2 . ']';
        }
        $vmsify_path =~ /(.+:)?(.*)/s;
        $dir = defined $2 ? $2 : '';
        return ( $1 || '', $dir, $file );
    }
    else {
        $vmsify_path =~ /(.+:)?([\[<].*[\]>])?(.*)/s;
        return ( $1 || '', $2 || '', $3 );
    }
}


sub splitdir {
    my ( $self, $dirspec ) = @_;
    my @dirs = ();
    return @dirs if ( ( !defined $dirspec ) || ( '' eq $dirspec ) );

    $dirspec =~ s/(?<!\^)</[/;
    $dirspec =~ s/(?<!\^)>/]/;
    $dirspec =~ s/(?<!\^)\]\[\./\.\]\[/g;
    $dirspec =~ s/(?<!\^)\[000000\.\]\[/\[/g;
    $dirspec =~ s/(?<!\^)\[000000\./\[/g;
    $dirspec =~ s/(?<!\^)\.\]\[000000\]/\]/g;
    $dirspec =~ s/(?<!\^)\.\]\[/\./g;
    while ( $dirspec =~ s/(^|[\[\<\.])\-(\-+)($|[\]\>\.])/$1-.$2$3/g ) { }
    $dirspec = "[$dirspec]" unless $dirspec =~ /(?<!\^)[\[<]/;
    $dirspec =~ s/^(\[|<)\./$1/;
    @dirs = split /(?<!\^)\./, vmspath($dirspec);
    $dirs[0]  =~ s/^[\[<]//s;
    $dirs[-1] =~ s/[\]>]\Z(?!\n)//s;
    @dirs;
}


sub catpath {
    my ( $self, $dev, $dir, $file ) = @_;

    my ( $dir_volume, $dir_dir, $dir_file ) = $self->splitpath($dir);
    $dev = $dir_volume unless length $dev;
    $dir = length $dir_file ? $self->catfile( $dir_dir, $dir_file ) : $dir_dir;

    if ( $dev =~ m|^(?<!\^)/+([^/]+)| ) { $dev = "$1:"; }
    else { $dev .= ':' unless $dev eq '' or $dev =~ /:\Z(?!\n)/; }
    if ( length($dev) or length($dir) ) {
        $dir = "[$dir]" unless $dir =~ /(?<!\^)[\[<\/]/;
        $dir = vmspath($dir);
    }
    $dir = '' if length($dev) && ( $dir eq '[]' || $dir eq '<>' );
    "$dev$dir$file";
}


sub abs2rel {
    my $self = shift;
    return vmspath( File::Spec::Unix::abs2rel( $self, @_ ) )
      if grep m{/}, @_;

    my ( $path, $base ) = @_;
    $base = $self->_cwd() unless defined $base and length $base;

    for ( $path, $base ) { $_ = $self->canonpath($_) }

    my ( $path_volume, $path_directories, $path_file ) =
      $self->splitpath($path);
    my ( $base_volume, $base_directories, $base_file ) =
      $self->splitpath($base);
    return $path unless lc($path_volume) eq lc($base_volume);

    for ( $path, $base ) { $_ = $self->rel2abs($_) }

    my @pathchunks = $self->splitdir($path_directories);
    my $pathchunks = @pathchunks;
    unshift( @pathchunks, '000000' ) unless $pathchunks[0] eq '000000';
    my @basechunks = $self->splitdir($base_directories);
    my $basechunks = @basechunks;
    unshift( @basechunks, '000000' ) unless $basechunks[0] eq '000000';

    while (@pathchunks
        && @basechunks
        && lc( $pathchunks[0] ) eq lc( $basechunks[0] ) )
    {
        shift @pathchunks;
        shift @basechunks;
    }

    if ( ( @basechunks > 0 ) || ( $basechunks != $pathchunks ) ) {
        $path_directories = join '.', ( '-' x @basechunks, @pathchunks );
    }
    else {
        $path_directories = join '.', @pathchunks;
    }
    $path_directories = '[' . $path_directories . ']';
    return $self->canonpath(
        $self->catpath( '', $path_directories, $path_file ) );
}


sub rel2abs {
    my $self = shift;
    my ( $path, $base ) = @_;
    return undef unless defined $path;
    if ( $path =~ m/\// ) {
        $path =
          ( -d $path || $path =~ m/\/\z/ ? vmspath($path) : vmsify($path) );
    }
    $base = vmspath($base) if defined $base && $base =~ m/\//;

    if ( !$self->file_name_is_absolute($path) ) {
        if ( !defined($base) || $base eq '' ) {
            $base = $self->_cwd;
        }
        elsif ( !$self->file_name_is_absolute($base) ) {
            $base = $self->rel2abs($base);
        }
        else {
            $base = $self->canonpath($base);
        }

        my ( $path_directories, $path_file ) =
          ( $self->splitpath($path) )[ 1, 2 ];

        my ( $base_volume, $base_directories ) = $self->splitpath($base);

        $path_directories = ''
          if $path_directories eq '[]'
          || $path_directories eq '<>';
        my $sep = '';
        $sep = '.'
          if ( $base_directories =~ m{[^.\]>]\Z(?!\n)}
            && $path_directories =~ m{^[^.\[<]}s );
        $base_directories = "$base_directories$sep$path_directories";
        $base_directories =~ s{\.?[\]>][\[<]\.?}{.};

        $path = $self->catpath( $base_volume, $base_directories, $path_file );
    }

    return $self->canonpath($path);
}

sub eliminate_macros {
    my ( $self, $path ) = @_;
    return '' unless ( defined $path ) && ( $path ne '' );
    $self = {} unless ref $self;

    if ( $path =~ /\s/ ) {
        return join ' ', map { $self->eliminate_macros($_) } split /\s+/, $path;
    }

    my $npath = unixify($path);
    $npath =~ s{\0$}{};

    my ($complex) = 0;
    my ( $head, $macro, $tail );

    while ( $npath =~ m#(.*?)\$\((\S+?)\)(.*)#gs ) {
        if ( defined $self->{$2} ) {
            ( $head, $macro, $tail ) = ( $1, $2, $3 );
            if ( ref $self->{$macro} ) {
                if ( ref $self->{$macro} eq 'ARRAY' ) {
                    $macro = join ' ', @{ $self->{$macro} };
                }
                else {
                    print "Note: can't expand macro \$($macro) containing ",
                      ref( $self->{$macro} ),
"\n\t(using MMK-specific deferred substitutuon; MMS will break)\n";
                    $macro   = "\cB$macro\cB";
                    $complex = 1;
                }
            }
            else { ( $macro = unixify( $self->{$macro} ) ) =~ s#/\Z(?!\n)##; }
            $npath = "$head$macro$tail";
        }
    }
    if ($complex) { $npath =~ s#\cB(.*?)\cB#\${$1}#gs; }
    $npath;
}

sub fixpath {
    my ( $self, $path, $force_path ) = @_;
    return '' unless $path;
    $self = bless {}, $self unless ref $self;
    my ( $fixedpath, $prefix, $name );

    if ( $path =~ /\s/ ) {
        return join ' ', map { $self->fixpath( $_, $force_path ) }
          split /\s+/, $path;
    }

    if ( $path =~ m#^\$\([^\)]+\)\Z(?!\n)#s || $path =~ m#[/:>\]]# ) {
        if ( $force_path or $path =~ /(?:DIR\)|\])\Z(?!\n)/ ) {
            $fixedpath = vmspath( $self->eliminate_macros($path) );
        }
        else {
            $fixedpath = vmsify( $self->eliminate_macros($path) );
        }
    }
    elsif ( ( ( $prefix, $name ) = ( $path =~ m#^\$\(([^\)]+)\)(.+)#s ) )
        && $self->{$prefix} )
    {
        my ($vmspre) = $self->eliminate_macros("\$($prefix)");
        $vmspre =
          ( $vmspre =~ m|/| or $prefix =~ /DIR\Z(?!\n)/ )
          ? vmspath($vmspre)
          : '';
        $fixedpath = ( $vmspre ? $vmspre : $self->{$prefix} ) . $name;
        $fixedpath = vmspath($fixedpath) if $force_path;
    }
    else {
        $fixedpath = $path;
        $fixedpath = vmspath($fixedpath) if $force_path;
    }
    if ( !defined($force_path) and $fixedpath !~ /[:>(.\]]/ ) {
        $fixedpath = vmspath($fixedpath) if -d $fixedpath;
    }

    $fixedpath =~ s/\.000000([\]>])/$1/;
    if ( $path =~ /^[\[>][^.\-]/ ) { $fixedpath =~ s/^[^\[<]+//; }
    $fixedpath;
}


1;
