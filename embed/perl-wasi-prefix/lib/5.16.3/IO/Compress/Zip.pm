package IO::Compress::Zip;

use strict;
use warnings;
use bytes;

use IO::Compress::Base::Common 2.048
  qw(:Status MAX32 isGeMax32 isaScalar createSelfTiedObject);
use IO::Compress::RawDeflate 2.048 ();
use IO::Compress::Adapter::Deflate 2.048;
use IO::Compress::Adapter::Identity 2.048;
use IO::Compress::Zlib::Extra 2.048;
use IO::Compress::Zip::Constants 2.048;

use File::Spec();
use Config;

use Compress::Raw::Zlib 2.048 ();

BEGIN {
    eval {
        require IO::Compress::Adapter::Bzip2;
        import IO::Compress::Adapter::Bzip2 2.048;
        require IO::Compress::Bzip2;
        import IO::Compress::Bzip2 2.048;
    };

    eval {
        require IO::Compress::Adapter::Lzma;
        import IO::Compress::Adapter::Lzma 2.048;
        require IO::Compress::Lzma;
        import IO::Compress::Lzma 2.048;
    };
}

require Exporter;

our ( $VERSION, @ISA, @EXPORT_OK, %EXPORT_TAGS, %DEFLATE_CONSTANTS, $ZipError );

$VERSION  = '2.048';
$ZipError = '';

@ISA         = qw(Exporter IO::Compress::RawDeflate);
@EXPORT_OK   = qw( $ZipError zip );
%EXPORT_TAGS = %IO::Compress::RawDeflate::DEFLATE_CONSTANTS;

push @{ $EXPORT_TAGS{all} }, @EXPORT_OK;

$EXPORT_TAGS{zip_method} =
  [qw( ZIP_CM_STORE ZIP_CM_DEFLATE ZIP_CM_BZIP2 ZIP_CM_LZMA)];
push @{ $EXPORT_TAGS{all} }, @{ $EXPORT_TAGS{zip_method} };

Exporter::export_ok_tags('all');

sub new {
    my $class = shift;

    my $obj = createSelfTiedObject( $class, \$ZipError );
    $obj->_create( undef, @_ );

}

sub zip {
    my $obj = createSelfTiedObject( undef, \$ZipError );
    return $obj->_def(@_);
}

sub isMethodAvailable {
    my $method = shift;

    return 1
      if $method == ZIP_CM_STORE || $method == ZIP_CM_DEFLATE;

    return 1
      if $method == ZIP_CM_BZIP2
      and defined $IO::Compress::Adapter::Bzip2::VERSION;

    return 1
      if $method == ZIP_CM_LZMA
      and defined $IO::Compress::Adapter::Lzma::VERSION;

    return 0;
}

sub beforePayload {
    my $self = shift;

    if ( *$self->{ZipData}{Sparse} ) {
        my $inc    = 1024 * 100;
        my $NULLS  = ( "\x00" x $inc );
        my $sparse = *$self->{ZipData}{Sparse};
        *$self->{CompSize}->add($sparse);
        *$self->{UnCompSize}->add($sparse);

        *$self->{FH}->seek( $sparse, IO::Handle::SEEK_CUR );

        *$self->{ZipData}{CRC32} =
          Compress::Raw::Zlib::crc32( $NULLS, *$self->{ZipData}{CRC32} )
          for 1 .. int $sparse / $inc;
        *$self->{ZipData}{CRC32} =
          Compress::Raw::Zlib::crc32( substr( $NULLS, 0, $sparse % $inc ),
            *$self->{ZipData}{CRC32} )
          if $sparse % $inc;
    }
}

sub mkComp {
    my $self = shift;
    my $got  = shift;

    my ( $obj, $errstr, $errno );

    if ( *$self->{ZipData}{Method} == ZIP_CM_STORE ) {
        ( $obj, $errstr, $errno ) =
          IO::Compress::Adapter::Identity::mkCompObject( $got->value('Level'),
            $got->value('Strategy') );
        *$self->{ZipData}{CRC32} = Compress::Raw::Zlib::crc32(undef);
    }
    elsif ( *$self->{ZipData}{Method} == ZIP_CM_DEFLATE ) {
        ( $obj, $errstr, $errno ) =
          IO::Compress::Adapter::Deflate::mkCompObject(
            $got->value('CRC32'), $got->value('Adler32'),
            $got->value('Level'), $got->value('Strategy')
          );
    }
    elsif ( *$self->{ZipData}{Method} == ZIP_CM_BZIP2 ) {
        ( $obj, $errstr, $errno ) = IO::Compress::Adapter::Bzip2::mkCompObject(
            $got->value('BlockSize100K'),
            $got->value('WorkFactor'),
            $got->value('Verbosity')
        );
        *$self->{ZipData}{CRC32} = Compress::Raw::Zlib::crc32(undef);
    }
    elsif ( *$self->{ZipData}{Method} == ZIP_CM_LZMA ) {
        ( $obj, $errstr, $errno ) =
          IO::Compress::Adapter::Lzma::mkRawZipCompObject(
            $got->value('Preset'), $got->value('Extreme'),
          );
        *$self->{ZipData}{CRC32} = Compress::Raw::Zlib::crc32(undef);
    }

    return $self->saveErrorString( undef, $errstr, $errno )
      if !defined $obj;

    if ( !defined *$self->{ZipData}{SizesOffset} ) {
        *$self->{ZipData}{SizesOffset} = 0;
        *$self->{ZipData}{Offset}      = new U64;
    }

    *$self->{ZipData}{AnyZip64} = 0
      if !defined *$self->{ZipData}{AnyZip64};

    return $obj;
}

sub reset {
    my $self = shift;

    *$self->{Compress}->reset();
    *$self->{ZipData}{CRC32} = Compress::Raw::Zlib::crc32('');

    return STATUS_OK;
}

sub filterUncompressed {
    my $self = shift;

    if ( *$self->{ZipData}{Method} == ZIP_CM_DEFLATE ) {
        *$self->{ZipData}{CRC32} = *$self->{Compress}->crc32();
    }
    else {
        *$self->{ZipData}{CRC32} =
          Compress::Raw::Zlib::crc32( ${ $_[0] }, *$self->{ZipData}{CRC32} );

    }
}

sub canonicalName {

    my $name     = shift;
    my $forceDir = shift;

    my ( $volume, $directories, $file ) =
      File::Spec->splitpath( File::Spec->canonpath($name), $forceDir );

    my @dirs = map { $_ =~ s{/}{_}g; $_ } File::Spec->splitdir($directories);

    if ( @dirs > 0 ) { pop(@dirs) if $dirs[-1] eq '' } push @dirs,
      defined($file) ? $file : '';

    my $normalised_path = join '/', @dirs;

    $normalised_path =~ s{^/}{};

    return $normalised_path;
}

sub mkHeader {
    my $self  = shift;
    my $param = shift;

    *$self->{ZipData}{LocalHdrOffset} = U64::clone( *$self->{ZipData}{Offset} );

    my $comment = '';
    $comment = $param->value('Comment') || '';

    my $filename = '';
    $filename = $param->value('Name') || '';

    $filename = canonicalName($filename)
      if length $filename && $param->value('CanonicalName');

    if ( defined *$self->{ZipData}{FilterName} ) {
        local *_ = \$filename;
        &{ *$self->{ZipData}{FilterName} }();
    }

    my $hdr = '';

    my $time = _unixToDosTime( $param->value('Time') );

    my $extra       = '';
    my $ctlExtra    = '';
    my $empty       = 0;
    my $osCode      = $param->value('OS_Code');
    my $extFileAttr = 0;

    $extFileAttr = 0100644 << 16
      if $osCode == ZIP_OS_CODE_UNIX;

    if ( *$self->{ZipData}{Zip64} ) {
        $empty = MAX32;

        my $x = '';
        $x .= pack "V V", 0, 0;
        $x .= pack "V V", 0, 0;
        $extra .=
          IO::Compress::Zlib::Extra::mkSubField( ZIP_EXTRA_ID_ZIP64, $x );
    }

    if ( !$param->value('Minimal') ) {
        if ( $param->parsed('MTime') ) {
            $extra .= mkExtendedTime(
                $param->value('MTime'),
                $param->value('ATime'),
                $param->value('CTime')
            );

            $ctlExtra .= mkExtendedTime( $param->value('MTime') );
        }

        if ( $osCode == ZIP_OS_CODE_UNIX ) {
            if ( $param->value('want_exUnixN') ) {
                my $ux3 = mkUnixNExtra( @{ $param->value('want_exUnixN') } );
                $extra    .= $ux3;
                $ctlExtra .= $ux3;
            }

            if ( $param->value('exUnix2') ) {
                $extra .= mkUnix2Extra( @{ $param->value('exUnix2') } );
                $ctlExtra .= mkUnix2Extra();
            }
        }

        $extFileAttr = $param->value('ExtAttr')
          if defined $param->value('ExtAttr');

        $extra .= $param->value('ExtraFieldLocal')
          if defined $param->value('ExtraFieldLocal');

        $ctlExtra .= $param->value('ExtraFieldCentral')
          if defined $param->value('ExtraFieldCentral');
    }

    my $method = *$self->{ZipData}{Method};
    my $gpFlag = 0;
    $gpFlag |= ZIP_GP_FLAG_STREAMING_MASK
      if *$self->{ZipData}{Stream};

    $gpFlag |= ZIP_GP_FLAG_LZMA_EOS_PRESENT
      if $method == ZIP_CM_LZMA;

    my $version = $ZIP_CM_MIN_VERSIONS{$method};
    $version = ZIP64_MIN_VERSION
      if ZIP64_MIN_VERSION > $version && *$self->{ZipData}{Zip64};

    my $madeBy  = ( $param->value('OS_Code') << 8 ) + $version;
    my $extract = $version;

    *$self->{ZipData}{Version} = $version;
    *$self->{ZipData}{MadeBy}  = $madeBy;

    my $ifa = 0;
    $ifa |= ZIP_IFA_TEXT_MASK
      if $param->value('TextFlag');

    $hdr .= pack "V", ZIP_LOCAL_HDR_SIG;
    $hdr .= pack 'v', $extract;
    $hdr .= pack 'v', $gpFlag;
    $hdr .= pack 'v', $method;
    $hdr .= pack 'V', $time;
    $hdr .= pack 'V', 0;
    $hdr .= pack 'V', $empty;
    $hdr .= pack 'V', $empty;
    $hdr .= pack 'v', length $filename;
    $hdr .= pack 'v', length $extra;

    $hdr .= $filename;

    if ( *$self->{ZipData}{Zip64} ) {
        *$self->{ZipData}{SizesOffset} =
          *$self->{ZipData}{Offset}->get64bit() + length($hdr) + 4;
    }
    else {
        *$self->{ZipData}{SizesOffset} =
          *$self->{ZipData}{Offset}->get64bit() + 18;
    }

    $hdr .= $extra;

    my $ctl = '';

    $ctl .= pack "V", ZIP_CENTRAL_HDR_SIG;
    $ctl .= pack 'v', $madeBy;
    $ctl .= pack 'v', $extract;
    $ctl .= pack 'v', $gpFlag;
    $ctl .= pack 'v', $method;
    $ctl .= pack 'V', $time;
    $ctl .= pack 'V', 0;
    $ctl .= pack 'V', $empty;
    $ctl .= pack 'V', $empty;
    $ctl .= pack 'v', length $filename;

    *$self->{ZipData}{ExtraOffset} = length $ctl;
    *$self->{ZipData}{ExtraSize}   = length $ctlExtra;

    $ctl .= pack 'v', length $ctlExtra;
    $ctl .= pack 'v', length $comment;
    $ctl .= pack 'v', 0;
    $ctl .= pack 'v', $ifa;
    $ctl .= pack 'V', $extFileAttr;

    if ( *$self->{ZipData}{LocalHdrOffset}->is64bit() ) {
        $ctl .= pack 'V', MAX32;
    }
    else {
        $ctl .= *$self->{ZipData}{LocalHdrOffset}->getPacked_V32();
    }

    $ctl .= $filename;
    $ctl .= $ctlExtra;
    $ctl .= $comment;

    *$self->{ZipData}{Offset}->add( length $hdr );

    *$self->{ZipData}{CentralHeader} = $ctl;

    return $hdr;
}

sub mkTrailer {
    my $self = shift;

    my $crc32;
    if ( *$self->{ZipData}{Method} == ZIP_CM_DEFLATE ) {
        $crc32 = pack "V", *$self->{Compress}->crc32();
    }
    else {
        $crc32 = pack "V", *$self->{ZipData}{CRC32};
    }

    my $ctl = *$self->{ZipData}{CentralHeader};

    my $sizes;
    if ( !*$self->{ZipData}{Zip64} ) {
        $sizes .= *$self->{CompSize}->getPacked_V32();
        $sizes .= *$self->{UnCompSize}->getPacked_V32();
    }
    else {
        $sizes .= *$self->{CompSize}->getPacked_V64();
        $sizes .= *$self->{UnCompSize}->getPacked_V64();
    }

    my $data = $crc32 . $sizes;

    my $xtrasize = *$self->{UnCompSize}->getPacked_V64();
    $xtrasize .= *$self->{CompSize}->getPacked_V64();

    my $hdr = '';

    if ( *$self->{ZipData}{Stream} ) {
        $hdr = pack "V", ZIP_DATA_HDR_SIG;
        $hdr .= $data;
    }
    else {
        $self->writeAt( *$self->{ZipData}{LocalHdrOffset}->get64bit() + 14,
            $crc32 )
          or return undef;
        $self->writeAt( *$self->{ZipData}{SizesOffset},
            *$self->{ZipData}{Zip64} ? $xtrasize : $sizes )
          or return undef;
    }

    substr( $ctl, 16, length $crc32 ) = $crc32;

    my $x = '';

    if ( *$self->{UnCompSize}->isAlmost64bit() || *$self->{ZipData}{Zip64} > 1 )
    {
        $x .= *$self->{UnCompSize}->getPacked_V64();
    }
    else {
        substr( $ctl, 24, 4 ) = *$self->{UnCompSize}->getPacked_V32();
    }

    if ( *$self->{CompSize}->isAlmost64bit() || *$self->{ZipData}{Zip64} > 1 ) {
        $x .= *$self->{CompSize}->getPacked_V64();
    }
    else {
        substr( $ctl, 20, 4 ) = *$self->{CompSize}->getPacked_V32();
    }

    $x .= *$self->{ZipData}{LocalHdrOffset}->getPacked_V64()
      if *$self->{ZipData}{LocalHdrOffset}->is64bit();

    if ( length $x ) {
        my $xtra =
          IO::Compress::Zlib::Extra::mkSubField( ZIP_EXTRA_ID_ZIP64, $x );
        $ctl .= $xtra;
        substr( $ctl, *$self->{ZipData}{ExtraOffset}, 2 ) = pack 'v',
          *$self->{ZipData}{ExtraSize} + length $xtra;

        *$self->{ZipData}{AnyZip64} = 1;
    }

    *$self->{ZipData}{Offset}->add( length($hdr) );
    *$self->{ZipData}{Offset}->add( *$self->{CompSize} );
    push @{ *$self->{ZipData}{CentralDir} }, $ctl;

    return $hdr;
}

sub mkFinalTrailer {
    my $self = shift;

    my $comment = '';
    $comment = *$self->{ZipData}{ZipComment};

    my $cd_offset = *$self->{ZipData}{Offset}->get32bit();

    my $entries = @{ *$self->{ZipData}{CentralDir} };
    my $cd      = join '', @{ *$self->{ZipData}{CentralDir} };
    my $cd_len  = length $cd;

    my $z64e = '';

    if ( *$self->{ZipData}{AnyZip64} ) {

        my $v  = *$self->{ZipData}{Version};
        my $mb = *$self->{ZipData}{MadeBy};
        $z64e .= pack 'v', $mb;
        $z64e .= pack 'v', $v;
        $z64e .= pack 'V', 0;
        $z64e .= pack 'V', 0;
        $z64e .= U64::pack_V64 $entries ;
        $z64e .= U64::pack_V64 $entries ;
        $z64e .= U64::pack_V64 $cd_len ;
        $z64e .= *$self->{ZipData}{Offset}->getPacked_V64();

        $z64e =
          pack( "V",
            ZIP64_END_CENTRAL_REC_HDR_SIG )
          . U64::pack_V64( length $z64e )
          . $z64e;

        *$self->{ZipData}{Offset}->add( length $cd );

        $z64e .= pack "V", ZIP64_END_CENTRAL_LOC_HDR_SIG;
        $z64e .= pack 'V', 0;
        $z64e .= *$self->{ZipData}{Offset}->getPacked_V64();
        $z64e .= pack 'V', 1;

        $cd_offset = MAX32;
        $cd_len    = MAX32 if isGeMax32 $cd_len ;
        $entries   = 0xFFFF if $entries >= 0xFFFF;
    }

    my $ecd = '';
    $ecd .= pack "V", ZIP_END_CENTRAL_HDR_SIG;
    $ecd .= pack 'v', 0;
    $ecd .= pack 'v', 0;
    $ecd .= pack 'v', $entries;
    $ecd .= pack 'v', $entries;
    $ecd .= pack 'V', $cd_len;
    $ecd .= pack 'V', $cd_offset;
    $ecd .= pack 'v', length $comment;
    $ecd .= $comment;

    return $cd . $z64e . $ecd;
}

sub ckParams {
    my $self = shift;
    my $got  = shift;

    $got->value( 'CRC32' => 1 );

    if ( !$got->parsed('Time') ) {
        $got->value( 'Time' => time );
    }

    if ( $got->parsed('exTime') ) {
        my $timeRef = $got->value('exTime');
        if ( defined $timeRef ) {
            return $self->saveErrorString( undef,
                "exTime not a 3-element array ref" )
              if ref $timeRef ne 'ARRAY' || @$timeRef != 3;
        }

        $got->value( "MTime", $timeRef->[1] );
        $got->value( "ATime", $timeRef->[0] );
        $got->value( "CTime", $timeRef->[2] );
    }

    for my $name (qw(exUnix2 exUnixN)) {
        if ( $got->parsed($name) ) {
            my $idRef = $got->value($name);
            if ( defined $idRef ) {
                return $self->saveErrorString( undef,
                    "$name not a 2-element array ref" )
                  if ref $idRef ne 'ARRAY' || @$idRef != 2;
            }

            $got->value( "UID",        $idRef->[0] );
            $got->value( "GID",        $idRef->[1] );
            $got->value( "want_$name", $idRef );
        }
    }

    *$self->{ZipData}{AnyZip64} = 1
      if $got->value('Zip64');
    *$self->{ZipData}{Zip64}  = $got->value('Zip64');
    *$self->{ZipData}{Stream} = $got->value('Stream');

    my $method = $got->value('Method');
    return $self->saveErrorString( undef, "Unknown Method '$method'" )
      if !defined $ZIP_CM_MIN_VERSIONS{$method};

    return $self->saveErrorString( undef, "Bzip2 not available" )
      if $method == ZIP_CM_BZIP2
      and !defined $IO::Compress::Adapter::Bzip2::VERSION;

    return $self->saveErrorString( undef, "Lzma not available" )
      if $method == ZIP_CM_LZMA
      and !defined $IO::Compress::Adapter::Lzma::VERSION;

    *$self->{ZipData}{Method} = $method;

    *$self->{ZipData}{ZipComment} = $got->value('ZipComment');

    for my $name (qw( ExtraFieldLocal ExtraFieldCentral )) {
        my $data = $got->value($name);
        if ( defined $data ) {
            my $bad = IO::Compress::Zlib::Extra::parseExtraField( $data, 1, 0 );
            return $self->saveErrorString( undef,
                "Error with $name Parameter: $bad" )
              if $bad;

            $got->value( $name, $data );
        }
    }

    return undef
      if defined $IO::Compress::Bzip2::VERSION
      and !IO::Compress::Bzip2::ckParams( $self, $got );

    if ( $got->parsed('Sparse') ) {
        *$self->{ZipData}{Sparse} = $got->value('Sparse');
        *$self->{ZipData}{Method} = ZIP_CM_STORE;
    }

    if ( $got->parsed('FilterName') ) {
        my $v = $got->value('FilterName');
        *$self->{ZipData}{FilterName} = $v
          if ref $v eq 'CODE';
    }

    return 1;
}

sub outputPayload {
    my $self = shift;
    return 1 if *$self->{ZipData}{Sparse};
    return $self->output(@_);
}

sub getExtraParams {
    my $self = shift;

    use IO::Compress::Base::Common 2.048 qw(:Parse);
    use Compress::Raw::Zlib 2.048
      qw(Z_DEFLATED Z_DEFAULT_COMPRESSION Z_DEFAULT_STRATEGY);

    my @Bzip2 = ();

    @Bzip2 = IO::Compress::Bzip2::getExtraParams($self)
      if defined $IO::Compress::Bzip2::VERSION;

    return (
        $self->getZlibParams(),

        'Stream' => [ 1, 1, Parse_boolean,  1 ],
        'Method' => [ 0, 1, Parse_unsigned, ZIP_CM_DEFLATE ],

        'Minimal'       => [ 0, 1, Parse_boolean, 0 ],
        'Zip64'         => [ 0, 1, Parse_boolean, 0 ],
        'Comment'       => [ 0, 1, Parse_any,     '' ],
        'ZipComment'    => [ 0, 1, Parse_any,     '' ],
        'Name'          => [ 0, 1, Parse_any,     '' ],
        'FilterName'    => [ 0, 1, Parse_code,    undef ],
        'CanonicalName' => [ 0, 1, Parse_boolean, 0 ],
        'Time'          => [ 0, 1, Parse_any,     undef ],
        'exTime'        => [ 0, 1, Parse_any,     undef ],
        'exUnix2'       => [ 0, 1, Parse_any,     undef ],
        'exUnixN'       => [ 0, 1, Parse_any,     undef ],
        'ExtAttr'       => [
            0, 1, Parse_any,
            $Compress::Raw::Zlib::gzip_os_code == 3
            ? 0100644 << 16
            : 0
        ],
        'OS_Code' =>
          [ 0, 1, Parse_unsigned, $Compress::Raw::Zlib::gzip_os_code ],

        'TextFlag'          => [ 0, 1, Parse_boolean, 0 ],
        'ExtraFieldLocal'   => [ 0, 1, Parse_any,     undef ],
        'ExtraFieldCentral' => [ 0, 1, Parse_any,     undef ],

        'Preset'  => [ 0, 1, Parse_unsigned, 6 ],
        'Extreme' => [ 1, 1, Parse_boolean,  0 ],

        'Sparse' => [ 0, 1, Parse_unsigned, 0 ],

        @Bzip2,
    );
}

sub getInverseClass {
    return ( 'IO::Uncompress::Unzip', \$IO::Uncompress::Unzip::UnzipError );
}

sub getFileInfo {
    my $self     = shift;
    my $params   = shift;
    my $filename = shift;

    if ( isaScalar($filename) ) {
        $params->value( Zip64 => 1 )
          if isGeMax32 length( ${$filename} );

        return;
    }

    my ( $mode, $uid, $gid, $size, $atime, $mtime, $ctime );
    if ( $params->parsed('StoreLinks') ) {
        ( $mode, $uid, $gid, $size, $atime, $mtime, $ctime ) =
          ( lstat($filename) )[ 2, 4, 5, 7, 8, 9, 10 ];
    }
    else {
        ( $mode, $uid, $gid, $size, $atime, $mtime, $ctime ) =
          ( stat($filename) )[ 2, 4, 5, 7, 8, 9, 10 ];
    }

    $params->value( TextFlag => -T $filename )
      if !$params->parsed('TextFlag');

    $params->value( Zip64 => 1 )
      if isGeMax32 $size ;

    $params->value( 'Name' => $filename )
      if !$params->parsed('Name');

    $params->value( 'Time' => $mtime )
      if !$params->parsed('Time');

    if ( !$params->parsed('exTime') ) {
        $params->value( 'MTime' => $mtime );
        $params->value( 'ATime' => $atime );
        $params->value( 'CTime' => undef );
        ;
    }

    if ( !$params->parsed('ExtAttr') ) {
        use Fcntl qw(:mode);
        my $attr = $mode << 16;
        $attr |= ZIP_A_RONLY if ( $mode & S_IWRITE ) == 0;
        $attr |= ZIP_A_DIR   if ( $mode & S_IFMT ) == S_IFDIR;

        $params->value( 'ExtAttr' => $attr );
    }

    $params->value( 'want_exUnixN', [ $uid, $gid ] );
    $params->value( 'UID' => $uid );
    $params->value( 'GID' => $gid );

}

sub mkExtendedTime {

    my $times = '';
    my $bit   = 1;
    my $flags = 0;

    for my $time (@_) {
        if ( defined $time ) {
            $flags |= $bit;
            $times .= pack( "V", $time );
        }

        $bit <<= 1;
    }

    return IO::Compress::Zlib::Extra::mkSubField( ZIP_EXTRA_ID_EXT_TIMESTAMP,
        pack( "C", $flags ) . $times );
}

sub mkUnix2Extra {
    my $ids = '';
    for my $id (@_) {
        $ids .= pack( "v", $id );
    }

    return IO::Compress::Zlib::Extra::mkSubField( ZIP_EXTRA_ID_INFO_ZIP_UNIX2,
        $ids );
}

sub mkUnixNExtra {
    my $uid = shift;
    my $gid = shift;

    my $ids;
    $ids .= pack "C", 1;
    $ids .= pack "C", $Config{uidsize};
    $ids .= pack "V", $uid;
    $ids .= pack "C", $Config{gidsize};
    $ids .= pack "V", $gid;

    return IO::Compress::Zlib::Extra::mkSubField( ZIP_EXTRA_ID_INFO_ZIP_UNIXN,
        $ids );
}

sub _unixToDosTime {
    my $time_t = shift;

    my ( $sec, $min, $hour, $mday, $mon, $year ) = localtime($time_t);
    my $dt = 0;
    $dt += ( $sec >> 1 );
    $dt += ( $min << 5 );
    $dt += ( $hour << 11 );
    $dt += ( $mday << 16 );
    $dt += ( ( $mon + 1 ) << 21 );
    $dt += ( ( $year - 80 ) << 25 );
    return $dt;
}

1;

__END__

