package IO::Compress::RawDeflate;

use strict;
use warnings;
use bytes;

use IO::Compress::Base 2.048;
use IO::Compress::Base::Common 2.048 qw(:Status createSelfTiedObject);
use IO::Compress::Adapter::Deflate 2.048;

require Exporter;

our ( $VERSION, @ISA, @EXPORT_OK, %DEFLATE_CONSTANTS, %EXPORT_TAGS,
    $RawDeflateError );

$VERSION         = '2.048';
$RawDeflateError = '';

@ISA       = qw(Exporter IO::Compress::Base);
@EXPORT_OK = qw( $RawDeflateError rawdeflate );
push @EXPORT_OK, @IO::Compress::Adapter::Deflate::EXPORT_OK;

%EXPORT_TAGS = %IO::Compress::Adapter::Deflate::DEFLATE_CONSTANTS;

{
    my %seen;
    foreach ( keys %EXPORT_TAGS ) {
        push @{ $EXPORT_TAGS{constants} },
          grep { !$seen{$_}++ } @{ $EXPORT_TAGS{$_} };
    }
    $EXPORT_TAGS{all} = $EXPORT_TAGS{constants};
}

%DEFLATE_CONSTANTS = %EXPORT_TAGS;

Exporter::export_ok_tags('all');

sub new {
    my $class = shift;

    my $obj = createSelfTiedObject( $class, \$RawDeflateError );

    return $obj->_create( undef, @_ );
}

sub rawdeflate {
    my $obj = createSelfTiedObject( undef, \$RawDeflateError );
    return $obj->_def(@_);
}

sub ckParams {
    my $self = shift;
    my $got  = shift;

    return 1;
}

sub mkComp {
    my $self = shift;
    my $got  = shift;

    my ( $obj, $errstr, $errno ) = IO::Compress::Adapter::Deflate::mkCompObject(
        $got->value('CRC32'), $got->value('Adler32'),
        $got->value('Level'), $got->value('Strategy')
    );

    return $self->saveErrorString( undef, $errstr, $errno )
      if !defined $obj;

    return $obj;
}

sub mkHeader {
    my $self = shift;
    return '';
}

sub mkTrailer {
    my $self = shift;
    return '';
}

sub mkFinalTrailer {
    return '';
}

sub getExtraParams {
    my $self = shift;
    return $self->getZlibParams();
}

sub getZlibParams {
    my $self = shift;

    use IO::Compress::Base::Common 2.048 qw(:Parse);
    use Compress::Raw::Zlib 2.048
      qw(Z_DEFLATED Z_DEFAULT_COMPRESSION Z_DEFAULT_STRATEGY);

    return (

        'Level'    => [ 0, 1, Parse_signed, Z_DEFAULT_COMPRESSION ],
        'Strategy' => [ 0, 1, Parse_signed, Z_DEFAULT_STRATEGY ],

        'CRC32'   => [ 0, 1, Parse_boolean, 0 ],
        'ADLER32' => [ 0, 1, Parse_boolean, 0 ],
        'Merge'   => [ 1, 1, Parse_boolean, 0 ],
    );

}

sub getInverseClass {
    return ( 'IO::Uncompress::RawInflate',
        \$IO::Uncompress::RawInflate::RawInflateError );
}

sub getFileInfo {
    my $self   = shift;
    my $params = shift;
    my $file   = shift;

}

use IO::Seekable qw(SEEK_SET);

sub createMerge {
    my $self     = shift;
    my $outValue = shift;
    my $outType  = shift;

    my ( $invClass, $error_ref ) = $self->getInverseClass();
    eval "require $invClass"
      or die "aaaahhhh";

    my $inf = $invClass->new(
        $outValue,
        Transparent => 0,
        AutoClose   => 0,
        Scan        => 1
      )
      or return $self->saveErrorString( undef,
        "Cannot create InflateScan object: $$error_ref" );

    my $end_offset = 0;
    $inf->scan()
      or return $self->saveErrorString( undef, "Error Scanning: $$error_ref",
        $inf->errorNo );
    $inf->zap($end_offset)
      or return $self->saveErrorString( undef, "Error Zapping: $$error_ref",
        $inf->errorNo );

    my $def = *$self->{Compress} = $inf->createDeflate();

    *$self->{Header}     = *$inf->{Info}{Header};
    *$self->{UnCompSize} = *$inf->{UnCompSize}->clone();
    *$self->{CompSize}   = *$inf->{CompSize}->clone();

    if ( $outType eq 'buffer' ) {
        substr( ${ *$self->{Buffer} }, $end_offset ) = '';
    }
    elsif ( $outType eq 'handle' || $outType eq 'filename' ) {
        *$self->{FH} = *$inf->{FH};
        delete *$inf->{FH};
        *$self->{FH}->flush();
        *$self->{Handle} = 1 if $outType eq 'handle';

        *$self->{FH}->seek( $end_offset, SEEK_SET )
          or return $self->saveErrorString( undef, $!, $! );
    }

    return $def;
}

sub deflateParams {
    my $self = shift;

    my $level    = shift;
    my $strategy = shift;

    my $status =
      *$self->{Compress}
      ->deflateParams( Level => $level, Strategy => $strategy );
    return $self->saveErrorString(
        0,
        *$self->{Compress}{Error},
        *$self->{Compress}{ErrorNo}
    ) if $status == STATUS_ERROR;

    return 1;
}

1;

__END__

