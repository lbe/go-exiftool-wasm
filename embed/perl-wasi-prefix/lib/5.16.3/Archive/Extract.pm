package Archive::Extract;

use strict;

use Cwd qw[cwd chdir];
use Carp qw[carp];
use IPC::Cmd qw[run can_run];
use FileHandle;
use File::Path qw[mkpath];
use File::Spec;
use File::Basename qw[dirname basename];
use Params::Check qw[check];
use Module::Load::Conditional qw[can_load check_install];
use Locale::Maketext::Simple Style => 'gettext';

use constant ON_SOLARIS => $^O eq 'solaris' ? 1 : 0;
use constant ON_NETBSD  => $^O eq 'netbsd'  ? 1 : 0;
use constant ON_FREEBSD => $^O eq 'freebsd' ? 1 : 0;
use constant FILE_EXISTS => sub { -e $_[0] ? 1 : 0 };

use constant ON_VMS => $^O eq 'VMS' ? 1 : 0;

use constant ON_WIN32 => $^O eq 'MSWin32' ? 1 : 0;

use constant METHOD_NA => [];

use constant TGZ  => 'tgz';
use constant TAR  => 'tar';
use constant GZ   => 'gz';
use constant ZIP  => 'zip';
use constant BZ2  => 'bz2';
use constant TBZ  => 'tbz';
use constant Z    => 'Z';
use constant LZMA => 'lzma';
use constant XZ   => 'xz';
use constant TXZ  => 'txz';

use vars qw[$VERSION $PREFER_BIN $PROGRAMS $WARN $DEBUG
  $_ALLOW_BIN $_ALLOW_PURE_PERL $_ALLOW_TAR_ITER
];

$VERSION          = '0.58';
$PREFER_BIN       = 0;
$WARN             = 1;
$DEBUG            = 0;
$_ALLOW_PURE_PERL = 1;
$_ALLOW_BIN       = 1;
$_ALLOW_TAR_ITER  = 1;

my @Types = ( TGZ, TAR, GZ, ZIP, BZ2, TBZ, Z, LZMA, XZ, TXZ );

local $Params::Check::VERBOSE = $Params::Check::VERBOSE = 1;


$PROGRAMS = {};
for my $pgm (qw[tar unzip gzip bunzip2 uncompress unlzma unxz]) {
    if ( $pgm eq 'unzip' and ( ON_NETBSD or ON_FREEBSD ) ) {
        local $IPC::Cmd::INSTANCES = 1;
        my @possibles = can_run($pgm);
        ( $PROGRAMS->{$pgm} ) =
          grep { ON_NETBSD ? m!/usr/pkg/! : m!/usr/local! } can_run($pgm);
        next;
    }
    $PROGRAMS->{$pgm} = can_run($pgm);
}

my $Mapping = { is_tgz => { bin => '_untar_bin', pp => '_untar_at' },
    is_tar  => { bin => '_untar_bin',      pp => '_untar_at' },
    is_gz   => { bin => '_gunzip_bin',     pp => '_gunzip_cz' },
    is_zip  => { bin => '_unzip_bin',      pp => '_unzip_az' },
    is_tbz  => { bin => '_untar_bin',      pp => '_untar_at' },
    is_bz2  => { bin => '_bunzip2_bin',    pp => '_bunzip2_bz2' },
    is_Z    => { bin => '_uncompress_bin', pp => '_gunzip_cz' },
    is_lzma => { bin => '_unlzma_bin',     pp => '_unlzma_cz' },
    is_xz   => { bin => '_unxz_bin',       pp => '_unxz_cz' },
    is_txz  => { bin => '_untar_bin',      pp => '_untar_at' }, };

{ my $tmpl = {
        archive    => sub { { required    => 1,  allow   => FILE_EXISTS } },
        type       => sub { { default     => '', allow   => [@Types] } },
        _error_msg => sub { { no_override => 1,  default => [] } },
        _error_msg_long => sub { { no_override => 1, default => [] } },
    };

    for
      my $method ( keys %$tmpl, qw[_extractor _gunzip_to files extract_path], )
    {
        no strict 'refs';
        *$method = sub {
            my $self = shift;
            $self->{$method} = $_[0] if @_;
            return $self->{$method};
          }
    }


    sub new {
        my $class = shift;
        my %hash  = @_;

        my %utmpl = map { $_ => $tmpl->{$_}->() } keys %$tmpl;

        my $parsed = check( \%utmpl, \%hash ) or return;

        my $ar = $parsed->{archive} = File::Spec->rel2abs( $parsed->{archive} );

        unless ( $parsed->{type} ) {
            $parsed->{type} =
                $ar =~ /.+?\.(?:tar\.gz|tgz)$/i       ? TGZ
              : $ar =~ /.+?\.gz$/i                    ? GZ
              : $ar =~ /.+?\.tar$/i                   ? TAR
              : $ar =~ /.+?\.(zip|jar|ear|war|par)$/i ? ZIP
              : $ar =~ /.+?\.(?:tbz2?|tar\.bz2?)$/i   ? TBZ
              : $ar =~ /.+?\.bz2$/i                   ? BZ2
              : $ar =~ /.+?\.Z$/                      ? Z
              : $ar =~ /.+?\.lzma$/                   ? LZMA
              : $ar =~ /.+?\.(?:txz|tar\.xz)$/i       ? TXZ
              : $ar =~ /.+?\.xz$/                     ? XZ
              :                                         '';

        }

        bless $parsed, $class;

        return $parsed->_error(
            loc( "Cannot determine file type for '%1'", $parsed->{archive} ) )
          unless $parsed->{type};
        return $parsed;
    }
}


sub extract {
    my $self = shift;
    my %hash = @_;

    $self->_error_msg(      [] );
    $self->_error_msg_long( [] );

    my $to;
    my $tmpl = { to => { default => '.', store => \$to } };

    check( $tmpl, \%hash ) or return;

    my $dir;
    { if (     $self->is_gz
            or $self->is_bz2
            or $self->is_Z
            or $self->is_lzma
            or $self->is_xz )
        {

            my $cp = $self->archive;
            $cp =~ s/\.(?:gz|bz2?|Z|lzma|xz)$//i;

            if ( -d $to ) {
                $dir = $to;
                $self->_gunzip_to( basename($cp) );

            }
            else {
                $dir = dirname($to);
                $self->_gunzip_to( basename($to) );
            }

        }
        else {
            $dir = $to;
        }
    }

    unless ( -d $dir ) {
        eval { mkpath($dir) };

        return $self->_error(
            loc( "Could not create path '%1': %2", $dir, $@ ) )
          if $@;
    }

    my $cwd = cwd();

    my $ok = 1;
  EXTRACT: {

        unless ( chdir $dir ) {
            $self->_error( loc( "Could not chdir to '%1': %2", $dir, $! ) );
            $ok = 0;
            last EXTRACT;
        }

        $self->files( [] );

        my ($map) = map { $Mapping->{$_} } grep { $self->$_ } keys %$Mapping;

        my @methods;
        push @methods, $map->{'pp'}  if $_ALLOW_PURE_PERL;
        push @methods, $map->{'bin'} if $_ALLOW_BIN;

        @methods = reverse @methods if $PREFER_BIN;

        my ( $na, $fail );
        for my $method (@methods) {
            $self->debug("# Extracting with ->$method\n");

            my $rv = $self->$method;

            if ( $rv and $rv ne METHOD_NA ) {
                $self->debug("# Extraction succeeded\n");
                $self->_extractor($method);
                last;

            }
            elsif ( $rv and $rv eq METHOD_NA ) {
                $self->debug("# Extraction method not available\n");
                $na++;
            }
            else {
                $self->debug("# Extraction method failed\n");
                $fail++;
            }
        }

        unless ( $self->_extractor ) {
            my $diag =
                $fail ? loc("Extract failed due to errors")
              : $na   ? loc("Extract failed; no extractors available")
              :         '';

            $self->_error($diag);
            $ok = 0;
        }
    }

    unless ( chdir $cwd ) {
        $self->_error(
            loc( "Could not chdir back to start dir '%1': %2'", $cwd, $! ) );
    }

    return $ok;
}


sub types { return @Types }


sub is_tgz  { return $_[0]->type eq TGZ }
sub is_tar  { return $_[0]->type eq TAR }
sub is_gz   { return $_[0]->type eq GZ }
sub is_zip  { return $_[0]->type eq ZIP }
sub is_tbz  { return $_[0]->type eq TBZ }
sub is_bz2  { return $_[0]->type eq BZ2 }
sub is_Z    { return $_[0]->type eq Z }
sub is_lzma { return $_[0]->type eq LZMA }
sub is_xz   { return $_[0]->type eq XZ }
sub is_txz  { return $_[0]->type eq TXZ }


sub bin_gzip    { return $PROGRAMS->{'gzip'}    if $PROGRAMS->{'gzip'} }
sub bin_unzip   { return $PROGRAMS->{'unzip'}   if $PROGRAMS->{'unzip'} }
sub bin_tar     { return $PROGRAMS->{'tar'}     if $PROGRAMS->{'tar'} }
sub bin_bunzip2 { return $PROGRAMS->{'bunzip2'} if $PROGRAMS->{'bunzip2'} }

sub bin_uncompress {
    return $PROGRAMS->{'uncompress'}
      if $PROGRAMS->{'uncompress'};
}
sub bin_unlzma { return $PROGRAMS->{'unlzma'} if $PROGRAMS->{'unlzma'} }
sub bin_unxz   { return $PROGRAMS->{'unxz'}   if $PROGRAMS->{'unxz'} }


sub have_old_bunzip2 {
    my $self = shift;

    return unless $self->bin_bunzip2;

    my $buffer;
    scalar run(
        command => [ $self->bin_bunzip2, '--version', 'NoSuchFile' ],
        verbose => 0,
        buffer  => \$buffer
    );

    return unless $buffer;

    my ($version) = $buffer =~ /version \s+ (\d+)/ix;

    return 1 if $version < 1;
    return;
}

{
    my @ExtraTarFlags;
    if ( ON_WIN32 and my $cmd = __PACKAGE__->bin_tar ) {

        push @ExtraTarFlags, '--force-local' if `$cmd --version` =~ /gnu tar/i;
    }

    sub _untar_bin {
        my $self = shift;

        {
            my $diag =
              not $self->bin_tar ? loc( "No '%1' program found", '/bin/tar' )
              : $self->is_tgz
              && !$self->bin_gzip ? loc( "No '%1' program found", '/bin/gzip' )
              : $self->is_tbz && !$self->bin_bunzip2
              ? loc( "No '%1' program found", '/bin/bunzip2' )
              : $self->is_txz
              && !$self->bin_unxz ? loc( "No '%1' program found", '/bin/unxz' )
              :                     '';

            if ($diag) {
                $self->_error($diag);
                return METHOD_NA;
            }
        }

        my $archive = $self->archive;
        $archive = VMS::Filespec::unixify($archive) if ON_VMS;

        {
            my $cmd =
              $self->is_tgz
              ? [
                $self->bin_gzip, '-cdf', $archive, '|',
                $self->bin_tar,  '-tf',  '-'
              ]
              : $self->is_tbz ? [
                $self->bin_bunzip2, '-cd', $archive, '|',
                $self->bin_tar,     '-tf', '-'
              ]
              : $self->is_txz ? [
                $self->bin_unxz, '-cd', $archive, '|',
                $self->bin_tar,  '-tf', '-'
              ]
              : [ $self->bin_tar, @ExtraTarFlags, '-tf', $archive ];

            my $buffer = '';
            my @out    = run(
                command => $cmd,
                buffer  => \$buffer,
                verbose => $DEBUG
            );

            unless ( $out[0] ) {
                return $self->_error(
                    loc(
                        "Error listing contents of archive '%1': %2",
                        $archive, $buffer
                    )
                );
            }

            if ( !IPC::Cmd->can_capture_buffer and !$buffer ) {
                $self->_error( $self->_no_buffer_files($archive) );

            }
            else {
                my @files = map {
                    chomp;
                    !ON_SOLARIS
                      ? $_
                      : (
                        m|^ x \s+  # 'xtract' -- sigh
                                                (.+?),  # the actual file name
                                                \s+ [\d,.]+ \s bytes,
                                                \s+ [\d,.]+ \s tape \s blocks
                                            |x ? $1 : $_
                      );

                } grep { length } map { split $/, $_ } join '', @{ $out[3] };

                $self->files( \@files );
            }
        }

        {
            my $cmd =
              $self->is_tgz
              ? [
                $self->bin_gzip, '-cdf', $archive, '|',
                $self->bin_tar,  '-xf',  '-'
              ]
              : $self->is_tbz ? [
                $self->bin_bunzip2, '-cd', $archive, '|',
                $self->bin_tar,     '-xf', '-'
              ]
              : $self->is_txz ? [
                $self->bin_unxz, '-cd', $archive, '|',
                $self->bin_tar,  '-xf', '-'
              ]
              : [ $self->bin_tar, @ExtraTarFlags, '-xf', $archive ];

            my $buffer = '';
            unless (
                scalar run(
                    command => $cmd,
                    buffer  => \$buffer,
                    verbose => $DEBUG
                )
              )
            {
                return $self->_error(
                    loc(
                        "Error extracting archive '%1': %2", $archive,
                        $buffer
                    )
                );
            }

            if ( $self->files ) {
                my $dir = $self->__get_extract_dir( $self->files );

                $self->extract_path($dir);
            }
        }

        return 1;
    }
}

sub _untar_at {
    my $self = shift;

    local $Archive::Tar::WARN = $Archive::Tar::WARN;

    {
        my $use_list = { 'Archive::Tar' => '0.0' };

        unless ( can_load( modules => $use_list ) ) {

            $self->_error(
                loc(
                    "You do not have '%1' installed - "
                      . "Please install it as soon as possible.",
                    'Archive::Tar'
                )
            );

            return METHOD_NA;
        }
    }

    my $fh_to_read = $self->archive;

    if ( $self->is_tgz ) {
        my $use_list = { 'Compress::Zlib' => '0.0' };
        $use_list->{'IO::Zlib'} = '0.0'
          if $Archive::Tar::VERSION >= '0.99';

        unless ( can_load( modules => $use_list ) ) {
            my $which = join '/', sort keys %$use_list;

            $self->_error(
                loc(
                    "You do not have '%1' installed - Please "
                      . "install it as soon as possible.",
                    $which
                )
            );

            return METHOD_NA;
        }

    }
    elsif ( $self->is_tbz ) {
        my $use_list = { 'IO::Uncompress::Bunzip2' => '0.0' };
        unless ( can_load( modules => $use_list ) ) {
            $self->_error(
                loc(
                    "You do not have '%1' installed - Please "
                      . "install it as soon as possible.",
                    'IO::Uncompress::Bunzip2'
                )
            );

            return METHOD_NA;
        }

        my $bz = IO::Uncompress::Bunzip2->new( $self->archive )
          or return $self->_error(
            loc(
                "Unable to open '%1': %2", $self->archive,
                $IO::Uncompress::Bunzip2::Bunzip2Error
            )
          );

        $fh_to_read = $bz;
    }
    elsif ( $self->is_txz ) {
        my $use_list = { 'IO::Uncompress::UnXz' => '0.0' };
        unless ( can_load( modules => $use_list ) ) {
            $self->_error(
                loc(
                    "You do not have '%1' installed - Please "
                      . "install it as soon as possible.",
                    'IO::Uncompress::UnXz'
                )
            );

            return METHOD_NA;
        }

        my $xz = IO::Uncompress::UnXz->new( $self->archive )
          or return $self->_error(
            loc(
                "Unable to open '%1': %2", $self->archive,
                $IO::Uncompress::UnXz::UnXzError
            )
          );

        $fh_to_read = $xz;
    }

    my @files;
    {
        $Archive::Tar::WARN = $Archive::Extract::WARN;

        my @read = ( $fh_to_read, ( $self->is_tgz ? 1 : 0 ) );

        local $Archive::Tar::CHOWN = 0;

        if ( $_ALLOW_TAR_ITER && Archive::Tar->can('iter') ) {

            my $next;
            unless ( $next = Archive::Tar->iter(@read) ) {
                return $self->_error(
                    loc(
                        "Unable to read '%1': %2", $self->archive,
                        $Archive::Tar::error
                    )
                );
            }

            while ( my $file = $next->() ) {
                push @files, $file->full_path;

                $file->extract
                  or return $self->_error(
                    loc(
                        "Unable to read '%1': %2", $self->archive,
                        $Archive::Tar::error
                    )
                  );
            }

        }
        else {

            my $tar = Archive::Tar->new();

            unless ( $tar->read(@read) ) {
                return $self->_error(
                    loc(
                        "Unable to read '%1': %2", $self->archive,
                        $Archive::Tar::error
                    )
                );
            }

            {
                no strict 'refs';
                local $^W;

                *Archive::Tar::chown = sub { };
            }

            {
                local $^W;
                
                $tar->extract
                  or return $self->_error(
                    loc(
                        "Unable to extract '%1': %2", $self->archive,
                        $Archive::Tar::error
                    )
                  );
            }

            @files = $tar->list_files;
        }
    }

    my $dir = $self->__get_extract_dir( \@files );

    $self->files( \@files );

    $self->extract_path($dir);

    return 1 if -d $self->extract_path;

    return $self->_error(
        loc(
            "Unable to extract '%1': %2", $self->archive,
            $Archive::Tar::error
        )
    );
}

sub _gunzip_bin {
    my $self = shift;

    unless ( $self->bin_gzip ) {
        $self->_error( loc( "No '%1' program found", '/bin/gzip' ) );
        return METHOD_NA;
    }

    my $fh = FileHandle->new( '>' . $self->_gunzip_to )
      or return $self->_error(
        loc( "Could not open '%1' for writing: %2", $self->_gunzip_to, $! ) );

    my $cmd = [ $self->bin_gzip, '-cdf', $self->archive ];

    my $buffer;
    unless (
        scalar run(
            command => $cmd,
            verbose => $DEBUG,
            buffer  => \$buffer
        )
      )
    {
        return $self->_error(
            loc( "Unable to gunzip '%1': %2", $self->archive, $buffer ) );
    }

    if ( !IPC::Cmd->can_capture_buffer and !$buffer ) {
        $self->_error( $self->_no_buffer_content( $self->archive ) );
    }

    $self->_print( $fh, $buffer ) if defined $buffer;

    close $fh;

    $self->files( [ $self->_gunzip_to ] );
    $self->extract_path( File::Spec->rel2abs( cwd() ) );

    return 1;
}

sub _gunzip_cz {
    my $self = shift;

    my $use_list = { 'Compress::Zlib' => '0.0' };
    unless ( can_load( modules => $use_list ) ) {
        $self->_error(
            loc(
                "You do not have '%1' installed - Please "
                  . "install it as soon as possible.",
                'Compress::Zlib'
            )
        );
        return METHOD_NA;
    }

    my $gz = Compress::Zlib::gzopen( $self->archive, "rb" )
      or return $self->_error(
        loc(
            "Unable to open '%1': %2", $self->archive,
            $Compress::Zlib::gzerrno
        )
      );

    my $fh = FileHandle->new( '>' . $self->_gunzip_to )
      or return $self->_error(
        loc( "Could not open '%1' for writing: %2", $self->_gunzip_to, $! ) );

    my $buffer;
    $self->_print( $fh, $buffer ) while $gz->gzread($buffer) > 0;
    $fh->close;

    $self->files( [ $self->_gunzip_to ] );
    $self->extract_path( File::Spec->rel2abs( cwd() ) );

    return 1;
}

sub _uncompress_bin {
    my $self = shift;

    unless ( $self->bin_uncompress ) {
        $self->_error( loc( "No '%1' program found", '/bin/uncompress' ) );
        return METHOD_NA;
    }

    my $fh = FileHandle->new( '>' . $self->_gunzip_to )
      or return $self->_error(
        loc( "Could not open '%1' for writing: %2", $self->_gunzip_to, $! ) );

    my $cmd = [ $self->bin_uncompress, '-c', $self->archive ];

    my $buffer;
    unless (
        scalar run(
            command => $cmd,
            verbose => $DEBUG,
            buffer  => \$buffer
        )
      )
    {
        return $self->_error(
            loc( "Unable to uncompress '%1': %2", $self->archive, $buffer ) );
    }

    if ( !IPC::Cmd->can_capture_buffer and !$buffer ) {
        $self->_error( $self->_no_buffer_content( $self->archive ) );
    }

    $self->_print( $fh, $buffer ) if defined $buffer;

    close $fh;

    $self->files( [ $self->_gunzip_to ] );
    $self->extract_path( File::Spec->rel2abs( cwd() ) );

    return 1;
}

sub _unzip_bin {
    my $self = shift;

    unless ( $self->bin_unzip ) {
        $self->_error( loc( "No '%1' program found", '/bin/unzip' ) );
        return METHOD_NA;
    }

    { my $opt = ON_VMS ? '"-Z"' : '-Z';
        my $cmd = [ $self->bin_unzip, $opt, '-1', $self->archive ];

        my $buffer = '';
        unless (
            scalar run(
                command => $cmd,
                verbose => $DEBUG,
                buffer  => \$buffer
            )
          )
        {
            return $self->_error(
                loc( "Unable to unzip '%1': %2", $self->archive, $buffer ) );
        }

        if ( !IPC::Cmd->can_capture_buffer and !$buffer ) {
            $self->_error( $self->_no_buffer_files( $self->archive ) );

        }
        else {
            local $/ = ON_WIN32 ? qr/\r?\n/ : "\n";
            $self->files( [ split $/, $buffer ] );
        }
    }

    {
        my $cmd = [ $self->bin_unzip, '-qq', '-o', $self->archive ];

        my $buffer;
        unless (
            scalar run(
                command => $cmd,
                verbose => $DEBUG,
                buffer  => \$buffer
            )
          )
        {
            return $self->_error(
                loc( "Unable to unzip '%1': %2", $self->archive, $buffer ) );
        }

        if ( scalar @{ $self->files } ) {
            my $files = $self->files;
            my $dir   = $self->__get_extract_dir($files);

            $self->extract_path($dir);
        }
    }

    return 1;
}

sub _unzip_az {
    my $self = shift;

    my $use_list = { 'Archive::Zip' => '0.0' };
    unless ( can_load( modules => $use_list ) ) {
        $self->_error(
            loc(
                "You do not have '%1' installed - Please "
                  . "install it as soon as possible.",
                'Archive::Zip'
            )
        );
        return METHOD_NA;
    }

    my $zip = Archive::Zip->new();

    unless ( $zip->read( $self->archive ) == &Archive::Zip::AZ_OK ) {
        return $self->_error( loc( "Unable to read '%1'", $self->archive ) );
    }

    my @files;

    my $extract_dir = cwd();

    for my $member ( $zip->members ) {
        push @files, $member->{fileName};

        my $to = File::Spec->catfile( $extract_dir, $member->{fileName} );

        unless ( $zip->extractMember( $member, $to ) == &Archive::Zip::AZ_OK ) {
            return $self->_error(
                loc(
                    "Extraction of '%1' from '%2' failed",
                    $member->{fileName},
                    $self->archive
                )
            );
        }
    }

    my $dir = $self->__get_extract_dir( \@files );

    $self->files( \@files );
    $self->extract_path( File::Spec->rel2abs($dir) );

    return 1;
}

sub __get_extract_dir {
    my $self = shift;
    my $files = shift || [];

    return unless scalar @$files;

    my ( $dir1, $dir2 );
    for my $aref ( [ \$dir1, 0 ], [ \$dir2, -1 ] ) {
        my ( $dir, $pos ) = @$aref;

        my $res =
          -d $files->[$pos]
          ? File::Spec->catdir( $files->[$pos], '' )
          : File::Spec->catdir( dirname( $files->[$pos] ) );

        $$dir = $res;
    }

    my $dir;

    if ( $dir1 eq $dir2 ) {
        $dir = $dir1;

    }
    else {
        my $base1 = [ File::Spec->splitdir($dir1) ]->[0];
        my $base2 = [ File::Spec->splitdir($dir2) ]->[0];

        $dir = File::Spec->rel2abs( $base1 eq $base2 ? $base1 : '.' );
    }

    return File::Spec->rel2abs($dir);
}

sub _bunzip2_bin {
    my $self = shift;

    unless ( $self->bin_bunzip2 ) {
        $self->_error( loc( "No '%1' program found", '/bin/bunzip2' ) );
        return METHOD_NA;
    }

    my $fh = FileHandle->new( '>' . $self->_gunzip_to )
      or return $self->_error(
        loc( "Could not open '%1' for writing: %2", $self->_gunzip_to, $! ) );

    if ( $self->have_old_bunzip2 and $self->archive !~ /\.bz2$/i ) {
        return $self->_error(
            loc(
                "Your bunzip2 version is too old and "
                  . "can only extract files ending in '%1'",
                '.bz2'
            )
        );
    }

    my $cmd = [ $self->bin_bunzip2, '-cd', $self->archive ];

    my $buffer;
    unless (
        scalar run(
            command => $cmd,
            verbose => $DEBUG,
            buffer  => \$buffer
        )
      )
    {
        return $self->_error(
            loc( "Unable to bunzip2 '%1': %2", $self->archive, $buffer ) );
    }

    if ( !IPC::Cmd->can_capture_buffer and !$buffer ) {
        $self->_error( $self->_no_buffer_content( $self->archive ) );
    }

    $self->_print( $fh, $buffer ) if defined $buffer;

    close $fh;

    $self->files( [ $self->_gunzip_to ] );
    $self->extract_path( File::Spec->rel2abs( cwd() ) );

    return 1;
}

sub _bunzip2_bz2 {
    my $self = shift;

    my $use_list = { 'IO::Uncompress::Bunzip2' => '0.0' };
    unless ( can_load( modules => $use_list ) ) {
        $self->_error(
            loc(
                "You do not have '%1' installed - Please "
                  . "install it as soon as possible.",
                'IO::Uncompress::Bunzip2'
            )
        );
        return METHOD_NA;
    }

    IO::Uncompress::Bunzip2::bunzip2( $self->archive => $self->_gunzip_to )
      or return $self->_error(
        loc(
            "Unable to uncompress '%1': %2", $self->archive,
            $IO::Uncompress::Bunzip2::Bunzip2Error
        )
      );

    $self->files( [ $self->_gunzip_to ] );
    $self->extract_path( File::Spec->rel2abs( cwd() ) );

    return 1;
}

sub _unxz_bin {
    my $self = shift;

    unless ( $self->bin_unxz ) {
        $self->_error( loc( "No '%1' program found", '/bin/unxz' ) );
        return METHOD_NA;
    }

    my $fh = FileHandle->new( '>' . $self->_gunzip_to )
      or return $self->_error(
        loc( "Could not open '%1' for writing: %2", $self->_gunzip_to, $! ) );

    my $cmd = [ $self->bin_unxz, '-cdf', $self->archive ];

    my $buffer;
    unless (
        scalar run(
            command => $cmd,
            verbose => $DEBUG,
            buffer  => \$buffer
        )
      )
    {
        return $self->_error(
            loc( "Unable to unxz '%1': %2", $self->archive, $buffer ) );
    }

    if ( !IPC::Cmd->can_capture_buffer and !$buffer ) {
        $self->_error( $self->_no_buffer_content( $self->archive ) );
    }

    $self->_print( $fh, $buffer ) if defined $buffer;

    close $fh;

    $self->files( [ $self->_gunzip_to ] );
    $self->extract_path( File::Spec->rel2abs( cwd() ) );

    return 1;
}

sub _unxz_cz {
    my $self = shift;

    my $use_list = { 'IO::Uncompress::UnXz' => '0.0' };
    unless ( can_load( modules => $use_list ) ) {
        $self->_error(
            loc(
                "You do not have '%1' installed - Please "
                  . "install it as soon as possible.",
                'IO::Uncompress::UnXz'
            )
        );
        return METHOD_NA;
    }

    IO::Uncompress::UnXz::unxz( $self->archive => $self->_gunzip_to )
      or return $self->_error(
        loc(
            "Unable to uncompress '%1': %2", $self->archive,
            $IO::Uncompress::UnXz::UnXzError
        )
      );

    $self->files( [ $self->_gunzip_to ] );
    $self->extract_path( File::Spec->rel2abs( cwd() ) );

    return 1;
}

sub _unlzma_bin {
    my $self = shift;

    unless ( $self->bin_unlzma ) {
        $self->_error( loc( "No '%1' program found", '/bin/unlzma' ) );
        return METHOD_NA;
    }

    my $fh = FileHandle->new( '>' . $self->_gunzip_to )
      or return $self->_error(
        loc( "Could not open '%1' for writing: %2", $self->_gunzip_to, $! ) );

    my $cmd = [ $self->bin_unlzma, '-c', $self->archive ];

    my $buffer;
    unless (
        scalar run(
            command => $cmd,
            verbose => $DEBUG,
            buffer  => \$buffer
        )
      )
    {
        return $self->_error(
            loc( "Unable to unlzma '%1': %2", $self->archive, $buffer ) );
    }

    if ( !IPC::Cmd->can_capture_buffer and !$buffer ) {
        $self->_error( $self->_no_buffer_content( $self->archive ) );
    }

    $self->_print( $fh, $buffer ) if defined $buffer;

    close $fh;

    $self->files( [ $self->_gunzip_to ] );
    $self->extract_path( File::Spec->rel2abs( cwd() ) );

    return 1;
}

sub _unlzma_cz {
    my $self = shift;

    my $use_list1 = { 'IO::Uncompress::UnLzma' => '0.0' };
    my $use_list2 = { 'Compress::unLZMA'       => '0.0' };

    if ( can_load( modules => $use_list1 ) ) {
        IO::Uncompress::UnLzma::unlzma( $self->archive => $self->_gunzip_to )
          or return $self->_error(
            loc(
                "Unable to uncompress '%1': %2", $self->archive,
                $IO::Uncompress::UnLzma::UnLzmaError
            )
          );
    }
    elsif ( can_load( modules => $use_list2 ) ) {

        my $fh = FileHandle->new( '>' . $self->_gunzip_to )
          or return $self->_error(
            loc( "Could not open '%1' for writing: %2", $self->_gunzip_to, $! )
          );

        my $buffer;
        $buffer = Compress::unLZMA::uncompressfile( $self->archive );
        unless ( defined $buffer ) {
            return $self->_error(
                loc( "Could not unlzma '%1': %2", $self->archive, $@ ) );
        }

        $self->_print( $fh, $buffer ) if defined $buffer;

        close $fh;
    }
    else {
        $self->_error(
            loc(
                "You do not have '%1' or '%2' installed - Please "
                  . "install it as soon as possible.",
                'Compress::unLZMA',
                'IO::Uncompress::UnLzma'
            )
        );
        return METHOD_NA;
    }

    $self->files( [ $self->_gunzip_to ] );
    $self->extract_path( File::Spec->rel2abs( cwd() ) );

    return 1;
}

sub _print {
    my $self = shift;
    my $fh   = shift;

    local ( $\, $", $, ) = ( undef, ' ', '' );
    return print $fh @_;
}

sub _error {
    my $self   = shift;
    my $error  = shift;
    my $lerror = Carp::longmess($error);

    push @{ $self->_error_msg },      $error;
    push @{ $self->_error_msg_long }, $lerror;

    if ($WARN) {
        carp $DEBUG ? $lerror : $error;
    }

    return;
}

sub error {
    my $self = shift;

    my $aref = do {
        shift()
          ? $self->_error_msg_long
          : $self->_error_msg;
      }
      || [];

    return join $/, @$aref;
}


sub debug {
    return unless $DEBUG;

    print $_[1];
}

sub _no_buffer_files {
    my $self = shift;
    my $file = shift or return;
    return loc(
        "No buffer captured, unable to tell "
          . "extracted files or extraction dir for '%1'",
        $file
    );
}

sub _no_buffer_content {
    my $self = shift;
    my $file = shift or return;
    return loc( "No buffer captured, unable to get content for '%1'", $file );
}
1;


