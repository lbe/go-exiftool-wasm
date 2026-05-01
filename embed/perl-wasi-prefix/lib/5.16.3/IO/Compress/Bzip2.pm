package IO::Compress::Bzip2;

use strict;
use warnings;
use bytes;
require Exporter;

use IO::Compress::Base 2.048;

use IO::Compress::Base::Common 2.048 qw(createSelfTiedObject);
use IO::Compress::Adapter::Bzip2 2.048;

our ( $VERSION, @ISA, @EXPORT_OK, %EXPORT_TAGS, $Bzip2Error );

$VERSION    = '2.048';
$Bzip2Error = '';

@ISA         = qw(Exporter IO::Compress::Base);
@EXPORT_OK   = qw( $Bzip2Error bzip2 );
%EXPORT_TAGS = %IO::Compress::Base::EXPORT_TAGS;
push @{ $EXPORT_TAGS{all} }, @EXPORT_OK;
Exporter::export_ok_tags('all');

sub new {
    my $class = shift;

    my $obj = createSelfTiedObject( $class, \$Bzip2Error );
    return $obj->_create( undef, @_ );
}

sub bzip2 {
    my $obj = createSelfTiedObject( undef, \$Bzip2Error );
    $obj->_def(@_);
}

sub mkHeader {
    my $self = shift;
    return '';

}

sub getExtraParams {
    my $self = shift;

    use IO::Compress::Base::Common 2.048 qw(:Parse);

    return (
        'BlockSize100K' => [ 0, 1, Parse_unsigned, 1 ],
        'WorkFactor'    => [ 0, 1, Parse_unsigned, 0 ],
        'Verbosity'     => [ 0, 1, Parse_boolean,  0 ],
    );
}

sub ckParams {
    my $self = shift;
    my $got  = shift;

    if ( $got->parsed('BlockSize100K') ) {
        my $value = $got->value('BlockSize100K');
        return $self->saveErrorString( undef,
            "Parameter 'BlockSize100K' not between 1 and 9, got $value" )
          unless defined $value && $value >= 1 && $value <= 9;

    }

    if ( $got->parsed('WorkFactor') ) {
        my $value = $got->value('WorkFactor');
        return $self->saveErrorString( undef,
            "Parameter 'WorkFactor' not between 0 and 250, got $value" )
          unless $value >= 0 && $value <= 250;
    }

    return 1;
}

sub mkComp {
    my $self = shift;
    my $got  = shift;

    my $BlockSize100K = $got->value('BlockSize100K');
    my $WorkFactor    = $got->value('WorkFactor');
    my $Verbosity     = $got->value('Verbosity');

    my ( $obj, $errstr, $errno ) =
      IO::Compress::Adapter::Bzip2::mkCompObject( $BlockSize100K, $WorkFactor,
        $Verbosity );

    return $self->saveErrorString( undef, $errstr, $errno )
      if !defined $obj;

    return $obj;
}

sub mkTrailer {
    my $self = shift;
    return '';
}

sub mkFinalTrailer {
    return '';
}

sub getInverseClass {
    return ('IO::Uncompress::Bunzip2');
}

sub getFileInfo {
    my $self   = shift;
    my $params = shift;
    my $file   = shift;

}

1;

__END__

