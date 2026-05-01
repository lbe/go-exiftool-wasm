package CPANPLUS::Internals::Utils;

use strict;

use CPANPLUS::Error;
use CPANPLUS::Internals::Constants;

use Cwd qw[chdir cwd];
use File::Copy;
use Params::Check qw[check];
use Module::Load::Conditional qw[can_load];
use Locale::Maketext::Simple Class => 'CPANPLUS', Style => 'gettext';
use version;

local $Params::Check::VERBOSE = 1;


sub _mkdir {
    my $self = shift;

    my %hash = @_;

    my $tmpl = { dir => { required => 1 }, };

    my $args = check( $tmpl, \%hash )
      or ( error( loc( Params::Check->last_error ) ), return );

    unless ( can_load( modules => { 'File::Path' => 0.0 } ) ) {
        error( loc("Could not use File::Path! This module should be core!") );
        return;
    }

    eval { File::Path::mkpath( $args->{dir} ) };

    if ($@) {
        chomp($@);
        error(
            loc( qq[Could not create directory '%1': %2], $args->{dir}, $@ ) );
        return;
    }

    return 1;
}


sub _chdir {
    my $self = shift;
    my %hash = @_;

    my $tmpl = { dir => { required => 1, allow => DIR_EXISTS }, };

    my $args = check( $tmpl, \%hash ) or return;

    unless ( chdir $args->{dir} ) {
        error( loc( q[Could not chdir into '%1'], $args->{dir} ) );
        return;
    }

    return 1;
}


sub _rmdir {
    my $self = shift;
    my %hash = @_;

    my $tmpl = { dir => { required => 1, allow => IS_DIR }, };

    my $args = check( $tmpl, \%hash ) or return;

    unless ( can_load( modules => { 'File::Path' => 0.0 } ) ) {
        error( loc("Could not use File::Path! This module should be core!") );
        return;
    }

    eval { File::Path::rmtree( $args->{dir} ) };

    if ($@) {
        chomp($@);
        error(
            loc( qq[Could not delete directory '%1': %2], $args->{dir}, $@ ) );
        return;
    }

    return 1;
}


sub _perl_version {
    my $self = shift;
    my %hash = @_;

    my $perl;
    my $tmpl = { perl => { required => 1, store => \$perl }, };

    check( $tmpl, \%hash ) or return;

    my $perl_version;
    if ( $perl eq $^X ) {
        require Config;
        $perl_version = $Config::Config{version};

    }
    else {
        my $cmd = $perl . ' -MConfig -eprint+Config::config_vars+version';
        ($perl_version) = ( `$cmd` =~ /version='(.*)'/ );
    }

    return $perl_version if defined $perl_version;
    return;
}


sub _version_to_number {
    my $self = shift;
    my %hash = @_;

    my $version;
    my $tmpl = { version => { default => '0.0', store => \$version }, };

    check( $tmpl, \%hash ) or return;

    $version =~ s!_!!g;
    return $version if $version =~ /^\d*(?:\.\d+)?$/;
    if ( my ($vers) = $version =~ /^(v?\d+(?:\.\d+(?:\.\d+)?)?)/ ) {
        return eval { version->parse($vers)->numify };
    }
    return '0.0';
}


sub _whoami { my $name = ( caller 1 )[3]; $name =~ s/.+:://; $name }


sub _get_file_contents {
    my $self = shift;
    my %hash = @_;

    my $file;
    my $tmpl = { file => { required => 1, store => \$file } };

    check( $tmpl, \%hash ) or return;

    my $fh = OPEN_FILE->($file) or return;
    my $contents = do { local $/; <$fh> };

    return $contents;
}


sub _move {
    my $self = shift;
    my %hash = @_;

    my $from;
    my $to;
    my $tmpl = {
        file => {
            required => 1,
            allow    => [ IS_FILE, IS_DIR ],
            store    => \$from
        },
        to => { required => 1, store => \$to }
    };

    check( $tmpl, \%hash ) or return;

    if ( File::Copy::move( $from, $to ) ) {
        return 1;
    }
    else {
        error( loc( "Failed to move '%1' to '%2': %3", $from, $to, $! ) );
        return;
    }
}


sub _copy {
    my $self = shift;
    my %hash = @_;

    my ( $from, $to );
    my $tmpl = {
        file => {
            required => 1,
            allow    => [ IS_FILE, IS_DIR ],
            store    => \$from
        },
        to => { required => 1, store => \$to }
    };

    check( $tmpl, \%hash ) or return;

    if ( File::Copy::copy( $from, $to ) ) {
        return 1;
    }
    else {
        error( loc( "Failed to copy '%1' to '%2': %3", $from, $to, $! ) );
        return;
    }
}


sub _mode_plus_w {
    my $self = shift;
    my %hash = @_;

    require File::stat;

    my $file;
    my $tmpl =
      { file => { required => 1, allow => IS_FILE, store => \$file }, };

    check( $tmpl, \%hash ) or return;

    my $x = File::stat::stat($file);
    my $mask = -d $file ? 0100 : 0200;

    if ( $x and chmod( $x->mode | $mask, $file ) ) {
        return 1;

    }
    else {
        error( loc( "Failed to '%1' '%2': '%3'", 'chmod +w', $file, $! ) );
        return;
    }
}


sub _host_to_uri {
    my $self = shift;
    my %hash = @_;

    my ( $scheme, $host, $path );
    my $tmpl = {
        scheme => { required => 1,           store => \$scheme },
        host   => { default  => 'localhost', store => \$host },
        path   => { default  => '',          store => \$path },
    };

    check( $tmpl, \%hash ) or return;

    $path =
      ON_VMS
      ? VMS::Filespec::unixify($path)
      : File::Spec::Unix->catdir( File::Spec->splitdir($path) );

    return "$scheme://" . File::Spec::Unix->catdir( $host, $path );
}


sub _vcmp {
    my $self = shift;
    my ( $x, $y ) = @_;

    $x = $self->_version_to_number( version => $x );
    $y = $self->_version_to_number( version => $y );

    return $x <=> $y;
}


sub _home_dir {
    my @os_home_envs = qw( APPDATA HOME USERPROFILE WINDIR SYS$LOGIN );

    for my $env (@os_home_envs) {
        next unless exists $ENV{$env};
        next unless defined $ENV{$env} && length $ENV{$env};
        return $ENV{$env} if -d $ENV{$env};
    }

    return cwd();
}


sub _safe_path {
    my $self = shift;

    my %hash = @_;

    my $path;
    my $tmpl = { path => { required => 1, store => \$path }, };

    check( $tmpl, \%hash ) or return;

    if (ON_WIN32) {
        return $path unless $path =~ /\s+/;

        return Win32::GetShortPathName($path) || $path;

    }
    elsif (ON_VMS) {

        return $path if $path =~ /\:|\]$/;

        $path .= '/' unless $path =~ m|/$|;

        $path = VMS::Filespec::vmsify($path);

        $path = File::Spec->catdir( File::Spec->splitdir($path) );
    }

    return $path;
}


{
    my $del_re = qr/[-_\+]/i;
    my $pkg_re = qr/[a-z]               # any letters followed by
                    [a-z\d]*            # any letters, numbers
                    (?i:\.pm)?          # followed by '.pm'--authors do this :(
                    (?:                 # optionally repeating:
                        $del_re         #   followed by a delimiter
                        [a-z]           #   any letters followed by
                        [a-z\d]*        #   any letters, numbers
                        (?i:\.pm)?      # followed by '.pm'--authors do this :(
                    )*
                /xi;

    my $ver_re = qr/[a-z]*\d*?[a-z]*    # contains a digit and possibly letters
                    (?:                 # however, some start with a . only :(
                        [-._]           # followed by a delimiter
                        [a-z\d]+        # and more digits and or letters
                    )*?
                /xi;

    my $ext_re = qr/[a-z]               # a letter, followed by
                    [a-z\d]*            # letters and or digits, optionally
                    (?:
                        \.              #   followed by a dot and letters
                        [a-z\d]+        #   and or digits (like .tar.bz2)
                    )?                  #   optionally
                /xi;

    my $ver_ext_re = qr/
                        ($ver_re+)      # version, optional
                        (?:
                            \.          # a literal .
                            ($ext_re)   # extension,
                        )?              # optional, but requires version
                /xi;

    my $full_re = qr/
                    ^
                    (                       # the whole thing
                        ($pkg_re+)          # package
                        (?:
                            $del_re         # delimiter
                            $ver_ext_re     # version + extension
                        )?
                    )
                    $
                /xi;

    my $perl    = PERL_CORE;
    my $perl_re = qr/
                    ^
                    (                       # the whole thing
                        ($perl)             # package name for 'perl'
                        (?:
                            $ver_ext_re     # version + extension
                        )?
                    )
                    $
                /xi;

    sub _split_package_string {
        my $self = shift;
        my %hash = @_;

        my $str;
        my $tmpl = { package => { required => 1, store => \$str } };
        check( $tmpl, \%hash ) or return;

        for my $re ( $full_re, $perl_re ) {

            $str =~ $re or next;

            my $full = $1 || '';
            my $pkg  = $2 || '';
            my $ver  = $3 || '';
            my $ext  = $4 || '';

            $pkg =~ s/$del_re$//;

            $pkg =~ s/\.pm$//i;

            return ( $pkg, $ver, $ext, $full );
        }

        return;
    }
}

{
    my %escapes = map { chr($_) => sprintf( "%%%02X", $_ ) } 0 .. 255;

    sub _uri_encode {
        my $self = shift;
        my %hash = @_;

        my $str;
        my $tmpl = { uri => { store => \$str, required => 1 } };

        check( $tmpl, \%hash ) or return;

        $str =~ s|([^A-Za-z0-9\-_.!~*'()])|$escapes{$1}|g;

        return $str;
    }

    sub _uri_decode {
        my $self = shift;
        my %hash = @_;

        my $str;
        my $tmpl = { uri => { store => \$str, required => 1 } };

        check( $tmpl, \%hash ) or return;

        $str =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/eg;

        return $str;
    }
}

sub _update_timestamp {
    my $self = shift;
    my %hash = @_;

    my $file;
    my $tmpl =
      { file => { required => 1, store => \$file, allow => FILE_EXISTS } };

    check( $tmpl, \%hash ) or return;

    my $now = time;
    unless ( chmod( 0644, $file ) && utime( $now, $now, $file ) ) {
        error( loc( "Couldn't touch %1", $file ) );
        return;
    }

    return 1;
}

1;

